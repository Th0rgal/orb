//! HTTP `Idempotency-Key` deduplication middleware and persistent SQLite cache.
//!
//! Eliminates duplicate writes (`POST /api/control/missions`, `POST /api/control/message`,
//! `POST /api/control/missions/:id/resume`, `POST /api/control/missions/:id/cancel`,
//! `POST /api/control/missions/:id/status`, etc.) when clients retry across transient
//! network drops, socket resets, or multi-endpoint failovers.
//!
//! Semantics:
//! - Scoped strictly per `(user_id, method, path, idempotency_key)` so keys cannot
//!   collide or leak responses across users or routes.
//! - Computes SHA-256 over the request body:
//!   - Same key + different body hash -> `409 Conflict` (`idempotency_conflict`).
//!   - Same key + same body hash currently executing -> waits up to 25s for the
//!     in-flight leader to finish, or returns `409 Conflict` (`idempotency_in_progress`).
//!   - Completed `2xx` responses (`<= 512 KiB`) are persisted in SQLite (`idempotency_keys.db`,
//!     24h TTL) with `X-Orb-Idempotent-Replay: true` on replay.
//!   - `4xx`/`5xx` responses release the in-flight claim without caching so legitimate
//!     retries after transient failures execute normally.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use std::time::Duration;

use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{HeaderName, HeaderValue, Method, Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};
use chrono::Utc;
use rusqlite::{params, OptionalExtension};
use sha2::{Digest, Sha256};
use tokio::sync::Notify;

use super::auth::AuthUser;
use super::routes::AppState;

pub const HEADER_NAME: &str = "idempotency-key";
pub const REPLAY_HEADER_NAME: &str = "x-orb-idempotent-replay";
const MAX_KEY_BYTES: usize = 200;
const MAX_BUFFERED_REQUEST_BYTES: usize = 2 * 1024 * 1024;
const MAX_CACHED_RESPONSE_BYTES: usize = 512 * 1024;
const TTL_SECS: i64 = 24 * 3600;
const INFLIGHT_WAIT: Duration = Duration::from_secs(25);

#[derive(Clone, Debug)]
struct StoredResponse {
    request_sha256: String,
    status: u16,
    content_type: Option<String>,
    body: Vec<u8>,
}

#[derive(Clone)]
struct InFlightClaim {
    request_sha256: String,
    notify: Arc<Notify>,
}

pub struct IdempotencyStore {
    db_path: PathBuf,
    conn: StdMutex<Option<rusqlite::Connection>>,
    inflight: StdMutex<HashMap<String, InFlightClaim>>,
}

static STORES: OnceLock<StdMutex<HashMap<PathBuf, Arc<IdempotencyStore>>>> = OnceLock::new();

pub fn store_for_state(state: &AppState) -> Arc<IdempotencyStore> {
    let db_path = state
        .config
        .working_dir
        .join(".sandboxed-sh")
        .join("idempotency_keys.db");
    let map_mutex = STORES.get_or_init(|| StdMutex::new(HashMap::new()));
    let mut guard = map_mutex.lock().unwrap_or_else(|e| e.into_inner());
    guard
        .entry(db_path.clone())
        .or_insert_with(|| Arc::new(IdempotencyStore::new(db_path)))
        .clone()
}

enum ClaimOutcome {
    Leader,
    Replay(StoredResponse),
    Conflict(&'static str),
    Wait(Arc<Notify>),
}

impl IdempotencyStore {
    pub fn new(db_path: PathBuf) -> Self {
        let conn = Self::open_db(&db_path).ok();
        Self {
            db_path,
            conn: StdMutex::new(conn),
            inflight: StdMutex::new(HashMap::new()),
        }
    }

    fn open_db(path: &PathBuf) -> rusqlite::Result<rusqlite::Connection> {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let conn = rusqlite::Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS http_idempotency_keys (
                scope_key TEXT PRIMARY KEY,
                request_sha256 TEXT NOT NULL,
                status INTEGER NOT NULL,
                content_type TEXT,
                body BLOB NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_http_idempotency_expires
                ON http_idempotency_keys(expires_at);",
        )?;
        Ok(conn)
    }

    fn with_conn<T>(
        &self,
        f: impl FnOnce(&rusqlite::Connection) -> rusqlite::Result<T>,
    ) -> Option<T> {
        let mut guard = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        if guard.is_none() {
            *guard = Self::open_db(&self.db_path).ok();
        }
        let conn = guard.as_ref()?;
        f(conn).ok()
    }

    fn lookup_persisted(&self, scope_key: &str, now_ts: i64) -> Option<StoredResponse> {
        self.with_conn(|conn| {
            conn.query_row(
                "SELECT request_sha256, status, content_type, body
                 FROM http_idempotency_keys
                 WHERE scope_key = ?1 AND expires_at > ?2",
                params![scope_key, now_ts],
                |row| {
                    Ok(StoredResponse {
                        request_sha256: row.get(0)?,
                        status: row.get::<_, u16>(1)?,
                        content_type: row.get(2)?,
                        body: row.get(3)?,
                    })
                },
            )
            .optional()
        })
        .flatten()
    }

    fn persist(&self, scope_key: &str, entry: &StoredResponse, now_ts: i64) {
        let expires_at = now_ts + TTL_SECS;
        let _ = self.with_conn(|conn| {
            // Opportunistically prune expired entries on writes.
            let _ = conn.execute(
                "DELETE FROM http_idempotency_keys WHERE expires_at <= ?1",
                params![now_ts],
            );
            conn.execute(
                "INSERT OR REPLACE INTO http_idempotency_keys
                    (scope_key, request_sha256, status, content_type, body, created_at, expires_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    scope_key,
                    entry.request_sha256,
                    entry.status,
                    entry.content_type,
                    entry.body,
                    now_ts,
                    expires_at,
                ],
            )
        });
    }

    fn try_claim(&self, scope_key: &str, request_sha256: &str) -> ClaimOutcome {
        let now_ts = Utc::now().timestamp();
        if let Some(stored) = self.lookup_persisted(scope_key, now_ts) {
            if stored.request_sha256 != request_sha256 {
                return ClaimOutcome::Conflict(
                    "Idempotency-Key was already used with a different request payload",
                );
            }
            return ClaimOutcome::Replay(stored);
        }

        let mut inflight = self.inflight.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(existing) = inflight.get(scope_key) {
            if existing.request_sha256 != request_sha256 {
                return ClaimOutcome::Conflict(
                    "Idempotency-Key is currently in flight with a different request payload",
                );
            }
            return ClaimOutcome::Wait(existing.notify.clone());
        }

        // Re-check persisted under the inflight lock so a leader finishing between
        // `lookup_persisted` and `inflight.lock()` is caught cleanly.
        if let Some(stored) = self.lookup_persisted(scope_key, now_ts) {
            if stored.request_sha256 != request_sha256 {
                return ClaimOutcome::Conflict(
                    "Idempotency-Key was already used with a different request payload",
                );
            }
            return ClaimOutcome::Replay(stored);
        }

        inflight.insert(
            scope_key.to_string(),
            InFlightClaim {
                request_sha256: request_sha256.to_string(),
                notify: Arc::new(Notify::new()),
            },
        );
        ClaimOutcome::Leader
    }

    fn finish_leader(&self, scope_key: &str, stored: Option<StoredResponse>) {
        if let Some(ref entry) = stored {
            self.persist(scope_key, entry, Utc::now().timestamp());
        }
        let removed = {
            let mut inflight = self.inflight.lock().unwrap_or_else(|e| e.into_inner());
            inflight.remove(scope_key)
        };
        if let Some(claim) = removed {
            claim.notify.notify_waiters();
        }
    }
}

struct LeaderGuard {
    store: Arc<IdempotencyStore>,
    scope_key: String,
    completed: bool,
}

impl LeaderGuard {
    async fn complete(mut self, stored: Option<StoredResponse>) {
        self.completed = true;
        let store = self.store.clone();
        let scope_key = self.scope_key.clone();
        let _ = tokio::task::spawn_blocking(move || {
            store.finish_leader(&scope_key, stored);
        })
        .await;
    }
}

impl Drop for LeaderGuard {
    fn drop(&mut self) {
        if !self.completed {
            let store = self.store.clone();
            let scope_key = self.scope_key.clone();
            if tokio::runtime::Handle::try_current().is_ok() {
                tokio::task::spawn_blocking(move || {
                    store.finish_leader(&scope_key, None);
                });
            } else {
                store.finish_leader(&scope_key, None);
            }
        }
    }
}

fn is_valid_idempotency_key(raw: &str) -> bool {
    !raw.is_empty()
        && raw.len() <= MAX_KEY_BYTES
        && raw.bytes().all(|b| b.is_ascii_graphic() || b == b' ')
}

fn should_bypass_path(path: &str) -> bool {
    path.starts_with("/api/uploads")
        || path.starts_with("/api/fs/upload")
        || path.contains("/import-chunks")
        || path.starts_with("/api/voice/")
}

fn build_replay_response(stored: StoredResponse) -> Response {
    let status = StatusCode::from_u16(stored.status).unwrap_or(StatusCode::OK);
    let mut resp = Response::new(Body::from(stored.body));
    *resp.status_mut() = status;
    if let Some(ct) = stored.content_type {
        if let Ok(val) = HeaderValue::from_str(&ct) {
            resp.headers_mut()
                .insert(axum::http::header::CONTENT_TYPE, val);
        }
    }
    resp.headers_mut().insert(
        HeaderName::from_static(REPLAY_HEADER_NAME),
        HeaderValue::from_static("true"),
    );
    resp
}

fn conflict_response(detail: &str) -> Response {
    (
        StatusCode::CONFLICT,
        axum::Json(serde_json::json!({
            "error": "idempotency_conflict",
            "message": detail,
        })),
    )
        .into_response()
}

/// Axum middleware enforcing `Idempotency-Key` on authenticated mutating requests.
pub async fn handle_idempotency_key(
    State(state): State<Arc<AppState>>,
    req: Request<Body>,
    next: Next,
) -> Response {
    if !matches!(
        *req.method(),
        Method::POST | Method::PUT | Method::PATCH | Method::DELETE
    ) {
        return next.run(req).await;
    }

    let path = req.uri().path().to_string();
    if should_bypass_path(&path) {
        return next.run(req).await;
    }

    let Some(raw_key) = req.headers().get(HEADER_NAME) else {
        return next.run(req).await;
    };
    let Ok(key_trimmed) = raw_key.to_str().map(str::trim) else {
        return (
            StatusCode::BAD_REQUEST,
            "Invalid Idempotency-Key header encoding",
        )
            .into_response();
    };
    if !is_valid_idempotency_key(key_trimmed) {
        return (
            StatusCode::BAD_REQUEST,
            "Idempotency-Key must be 1..=200 printable ASCII characters",
        )
            .into_response();
    }
    let key = key_trimmed.to_string();

    let user_id = req
        .extensions()
        .get::<AuthUser>()
        .map(|u| u.id.clone())
        .unwrap_or_else(|| "anonymous".to_string());
    let method_str = req.method().as_str().to_string();
    let full_uri = req
        .uri()
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or(&path)
        .to_string();

    let (parts, body) = req.into_parts();
    let body_bytes = match to_bytes(body, MAX_BUFFERED_REQUEST_BYTES).await {
        Ok(bytes) => bytes,
        Err(_) => {
            return (
                StatusCode::PAYLOAD_TOO_LARGE,
                "Request with Idempotency-Key exceeds 2 MiB body limit",
            )
                .into_response();
        }
    };

    let request_sha256 = hex::encode(Sha256::digest(&body_bytes));
    let scope_key = format!("{user_id}\n{method_str}\n{full_uri}\n{key}");
    let store = store_for_state(&state);

    let guard = loop {
        let store_claim = store.clone();
        let scope_claim = scope_key.clone();
        let sha_claim = request_sha256.clone();
        let outcome = match tokio::task::spawn_blocking(move || {
            store_claim.try_claim(&scope_claim, &sha_claim)
        })
        .await
        {
            Ok(outcome) => outcome,
            Err(_) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Idempotency claim task failed",
                )
                    .into_response();
            }
        };
        match outcome {
            ClaimOutcome::Leader => {
                break LeaderGuard {
                    store: store.clone(),
                    scope_key: scope_key.clone(),
                    completed: false,
                };
            }
            ClaimOutcome::Replay(stored) => return build_replay_response(stored),
            ClaimOutcome::Conflict(msg) => return conflict_response(msg),
            ClaimOutcome::Wait(notify) => {
                let notified = notify.notified();
                if tokio::time::timeout(INFLIGHT_WAIT, notified).await.is_err() {
                    return conflict_response(
                        "Identical request with this Idempotency-Key is still in progress",
                    );
                }
            }
        }
    };

    let rebuilt_req = Request::from_parts(parts, Body::from(body_bytes));
    let resp = next.run(rebuilt_req).await;
    let status = resp.status();

    // Only cache 2xx responses (never cache 101 upgrades, SSE streams, or 4xx/5xx errors).
    let content_type = resp
        .headers()
        .get(axum::http::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let is_event_stream = content_type
        .as_deref()
        .is_some_and(|ct| ct.to_ascii_lowercase().contains("text/event-stream"));

    if !status.is_success() || status == StatusCode::SWITCHING_PROTOCOLS || is_event_stream {
        guard.complete(None).await;
        return resp;
    }

    let (resp_parts, resp_body) = resp.into_parts();
    match to_bytes(resp_body, MAX_CACHED_RESPONSE_BYTES).await {
        Ok(resp_bytes) => {
            let stored = StoredResponse {
                request_sha256,
                status: status.as_u16(),
                content_type,
                body: resp_bytes.to_vec(),
            };
            guard.complete(Some(stored)).await;
            Response::from_parts(resp_parts, Body::from(resp_bytes))
        }
        Err(_) => {
            // Response larger than 512 KiB — release claim without caching.
            guard.complete(None).await;
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Idempotent response exceeded 512 KiB buffer cap",
            )
                .into_response()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{routing::post, Json, Router};
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[tokio::test]
    async fn idempotency_replays_identical_post_and_rejects_mismatched_body() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(IdempotencyStore::new(dir.path().join("idem.db")));
        let calls = Arc::new(AtomicUsize::new(0));
        let calls_handler = calls.clone();

        let store_mw = store.clone();
        let app = Router::new()
            .route(
                "/api/control/test-write",
                post(move |Json(payload): Json<serde_json::Value>| {
                    let calls = calls_handler.clone();
                    async move {
                        let n = calls.fetch_add(1, Ordering::SeqCst) + 1;
                        Json(serde_json::json!({ "call": n, "echo": payload }))
                    }
                }),
            )
            .layer(axum::middleware::from_fn(
                move |req: Request<Body>, next: Next| {
                    let store = store_mw.clone();
                    async move {
                        let key = req
                            .headers()
                            .get(HEADER_NAME)
                            .and_then(|v| v.to_str().ok())
                            .map(str::to_string);
                        let Some(key) = key else {
                            return next.run(req).await;
                        };
                        let (parts, body) = req.into_parts();
                        let bytes = to_bytes(body, 65536).await.unwrap();
                        let sha = hex::encode(Sha256::digest(&bytes));
                        let scope = format!("user1\nPOST\n/api/control/test-write\n{key}");
                        match store.try_claim(&scope, &sha) {
                            ClaimOutcome::Leader => {
                                let resp = next
                                    .run(Request::from_parts(parts, Body::from(bytes)))
                                    .await;
                                let status = resp.status().as_u16();
                                let (rparts, rbody) = resp.into_parts();
                                let rbytes = to_bytes(rbody, 65536).await.unwrap();
                                store.finish_leader(
                                    &scope,
                                    Some(StoredResponse {
                                        request_sha256: sha,
                                        status,
                                        content_type: Some("application/json".into()),
                                        body: rbytes.to_vec(),
                                    }),
                                );
                                Response::from_parts(rparts, Body::from(rbytes))
                            }
                            ClaimOutcome::Replay(s) => build_replay_response(s),
                            ClaimOutcome::Conflict(m) => conflict_response(m),
                            ClaimOutcome::Wait(_) => conflict_response("in progress"),
                        }
                    }
                },
            ));

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = reqwest::Client::new();
        let url = format!("http://{addr}/api/control/test-write");

        let res1 = client
            .post(&url)
            .header("Idempotency-Key", "idem-123")
            .json(&serde_json::json!({"msg": "hello"}))
            .send()
            .await
            .unwrap();
        assert_eq!(res1.status(), reqwest::StatusCode::OK);
        assert!(res1.headers().get(REPLAY_HEADER_NAME).is_none());
        let body1: serde_json::Value = res1.json().await.unwrap();
        assert_eq!(body1["call"], 1);

        // Exact retry returns cached response without executing handler a second time.
        let res2 = client
            .post(&url)
            .header("Idempotency-Key", "idem-123")
            .json(&serde_json::json!({"msg": "hello"}))
            .send()
            .await
            .unwrap();
        assert_eq!(res2.status(), reqwest::StatusCode::OK);
        assert_eq!(res2.headers().get(REPLAY_HEADER_NAME).unwrap(), "true");
        let body2: serde_json::Value = res2.json().await.unwrap();
        assert_eq!(body2["call"], 1);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        // Same key with different body returns 409 Conflict.
        let res3 = client
            .post(&url)
            .header("Idempotency-Key", "idem-123")
            .json(&serde_json::json!({"msg": "different"}))
            .send()
            .await
            .unwrap();
        assert_eq!(res3.status(), reqwest::StatusCode::CONFLICT);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        server.abort();
    }
}
