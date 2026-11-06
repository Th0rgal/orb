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
//!   - Committed `2xx` responses exceeding `512 KiB` stream through intact to the leader
//!     and persist an `oversize = 1` sentinel so retries receive a deterministic `409 Conflict`
//!     receipt without re-executing the mutation.
//!   - `4xx`/`5xx` responses release the in-flight claim without caching so legitimate
//!     retries after transient failures execute normally.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use std::time::Duration;

use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{HeaderName, HeaderValue, Method, Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};
use bytes::{Bytes, BytesMut};
use chrono::Utc;
use futures::StreamExt;
use rusqlite::{params, OptionalExtension};
use sha2::{Digest, Sha256};
use tokio::sync::Notify;

use super::auth::AuthUser;
use super::routes::AppState;

pub const HEADER_NAME: &str = "idempotency-key";
pub const REPLAY_HEADER_NAME: &str = "x-orb-idempotent-replay";
pub const IDEMPOTENT_REPLAYED_HEADER_NAME: &str = "idempotent-replayed";
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
    headers_json: Option<String>,
    body: Vec<u8>,
    oversize: bool,
    response_sha256: Option<String>,
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
    fallback_committed: StdMutex<HashMap<String, (StoredResponse, i64)>>,
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
            fallback_committed: StdMutex::new(HashMap::new()),
        }
    }

    fn open_db(path: &Path) -> rusqlite::Result<rusqlite::Connection> {
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
                headers_json TEXT,
                body BLOB NOT NULL,
                oversize INTEGER NOT NULL DEFAULT 0,
                response_sha256 TEXT,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_http_idempotency_expires
                ON http_idempotency_keys(expires_at);",
        )?;
        Self::ensure_column(&conn, "headers_json", "TEXT")?;
        Self::ensure_column(&conn, "oversize", "INTEGER NOT NULL DEFAULT 0")?;
        Self::ensure_column(&conn, "response_sha256", "TEXT")?;
        Ok(conn)
    }

    fn ensure_column(
        conn: &rusqlite::Connection,
        col_name: &str,
        col_def: &str,
    ) -> rusqlite::Result<()> {
        let exists = {
            let mut stmt = conn.prepare("PRAGMA table_info(http_idempotency_keys)")?;
            let mut rows = stmt.query([])?;
            let mut found = false;
            while let Some(row) = rows.next()? {
                let name: String = row.get(1)?;
                if name == col_name {
                    found = true;
                    break;
                }
            }
            found
        };
        if !exists {
            conn.execute_batch(&format!(
                "ALTER TABLE http_idempotency_keys ADD COLUMN {col_name} {col_def};"
            ))?;
        }
        Ok(())
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
        if let Some(entry) = self
            .with_conn(|conn| {
                conn.query_row(
                    "SELECT request_sha256, status, content_type, headers_json, body, oversize, response_sha256
                     FROM http_idempotency_keys
                     WHERE scope_key = ?1 AND expires_at > ?2",
                    params![scope_key, now_ts],
                    |row| {
                        Ok(StoredResponse {
                            request_sha256: row.get(0)?,
                            status: row.get::<_, u16>(1)?,
                            content_type: row.get(2)?,
                            headers_json: row.get(3)?,
                            body: row.get(4)?,
                            oversize: row.get::<_, i64>(5)? != 0,
                            response_sha256: row.get(6)?,
                        })
                    },
                )
                .optional()
            })
            .flatten()
        {
            return Some(entry);
        }

        let mut fallback = self
            .fallback_committed
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if let Some((stored, expires_at)) = fallback.get(scope_key) {
            if *expires_at > now_ts {
                return Some(stored.clone());
            }
            fallback.remove(scope_key);
        }
        None
    }

    fn persist(&self, scope_key: &str, entry: &StoredResponse, now_ts: i64) {
        let expires_at = now_ts + TTL_SECS;
        let persisted = self.with_conn(|conn| {
            let _ = conn.execute(
                "DELETE FROM http_idempotency_keys WHERE expires_at <= ?1",
                params![now_ts],
            );
            conn.execute(
                "INSERT OR REPLACE INTO http_idempotency_keys
                    (scope_key, request_sha256, status, content_type, headers_json, body, oversize, response_sha256, created_at, expires_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    scope_key,
                    entry.request_sha256,
                    entry.status,
                    entry.content_type,
                    entry.headers_json,
                    entry.body,
                    i64::from(entry.oversize),
                    entry.response_sha256,
                    now_ts,
                    expires_at,
                ],
            )
        });

        let mut fallback = self
            .fallback_committed
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        fallback.retain(|_, (_, exp)| *exp > now_ts);
        if persisted.is_none() {
            fallback.insert(scope_key.to_string(), (entry.clone(), expires_at));
        } else {
            fallback.remove(scope_key);
        }
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
    fallback_on_drop: Option<StoredResponse>,
    completed: bool,
}

impl LeaderGuard {
    fn fence_committed(&mut self, sentinel: StoredResponse) {
        self.fallback_on_drop = Some(sentinel);
    }

    async fn complete(mut self, stored: Option<StoredResponse>) {
        self.completed = true;
        self.fallback_on_drop = None;
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
            let fallback = self.fallback_on_drop.take();
            store.finish_leader(&scope_key, fallback);
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

fn serialize_headers_json(headers: &axum::http::HeaderMap) -> Option<String> {
    let mut pairs = Vec::with_capacity(headers.len());
    for (name, value) in headers {
        if let Ok(val_str) = value.to_str() {
            pairs.push((name.as_str(), val_str));
        }
    }
    serde_json::to_string(&pairs).ok()
}

fn build_replay_response(stored: StoredResponse) -> Response {
    if stored.oversize {
        if stored.status == 0 {
            let mut resp = (
                StatusCode::CONFLICT,
                axum::Json(serde_json::json!({
                    "error": "idempotency_leader_interrupted",
                    "message": "Original request with this Idempotency-Key was interrupted before producing a deterministic outcome; inspect server state before issuing a new key",
                })),
            )
                .into_response();
            resp.headers_mut().insert(
                HeaderName::from_static(IDEMPOTENT_REPLAYED_HEADER_NAME),
                HeaderValue::from_static("interrupted-indeterminate"),
            );
            resp.headers_mut().insert(
                HeaderName::from_static(REPLAY_HEADER_NAME),
                HeaderValue::from_static("interrupted-indeterminate"),
            );
            return resp;
        }
        let mut resp = (
            StatusCode::CONFLICT,
            axum::Json(serde_json::json!({
                "error": "idempotent_response_too_large_to_replay",
                "committed_status": stored.status,
            })),
        )
            .into_response();
        resp.headers_mut().insert(
            HeaderName::from_static(IDEMPOTENT_REPLAYED_HEADER_NAME),
            HeaderValue::from_static("oversize-committed"),
        );
        resp.headers_mut().insert(
            HeaderName::from_static(REPLAY_HEADER_NAME),
            HeaderValue::from_static("oversize-committed"),
        );
        return resp;
    }

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

pub async fn handle_idempotency_key(
    State(state): State<Arc<AppState>>,
    req: Request<Body>,
    next: Next,
) -> Response {
    handle_idempotency_with_store(store_for_state(&state), req, next).await
}

async fn handle_idempotency_with_store(
    store: Arc<IdempotencyStore>,
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

    let mut guard = loop {
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
                    fallback_on_drop: None,
                    completed: false,
                };
            }
            ClaimOutcome::Replay(stored) => return build_replay_response(stored),
            ClaimOutcome::Conflict(msg) => return conflict_response(msg),
            ClaimOutcome::Wait(notify) => {
                let notified = notify.notified();
                tokio::pin!(notified);
                notified.as_mut().enable();
                {
                    let still_inflight = store
                        .inflight
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .get(&scope_key)
                        .is_some_and(|c| Arc::ptr_eq(&c.notify, &notify));
                    if !still_inflight {
                        continue;
                    }
                }
                if tokio::time::timeout(INFLIGHT_WAIT, notified).await.is_err() {
                    return conflict_response(
                        "Identical request with this Idempotency-Key is still in progress",
                    );
                }
            }
        }
    };

    guard.fence_committed(StoredResponse {
        request_sha256: request_sha256.clone(),
        status: 0,
        content_type: None,
        headers_json: None,
        body: Vec::new(),
        oversize: true,
        response_sha256: None,
    });
    let rebuilt_req = Request::from_parts(parts, Body::from(body_bytes));
    let resp = next.run(rebuilt_req).await;
    let status = resp.status();

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

    let headers_json = serialize_headers_json(resp.headers());
    let committed_sentinel = StoredResponse {
        request_sha256: request_sha256.clone(),
        status: status.as_u16(),
        content_type: content_type.clone(),
        headers_json: headers_json.clone(),
        body: Vec::new(),
        oversize: true,
        response_sha256: None,
    };
    guard.fence_committed(committed_sentinel);

    let (resp_parts, resp_body) = resp.into_parts();
    let mut stream = resp_body.into_data_stream();
    let mut prefix = BytesMut::new();
    let mut remainder = None;
    let mut stream_err = None;

    while let Some(chunk_res) = stream.next().await {
        match chunk_res {
            Ok(chunk) => {
                let cap_plus_one = MAX_CACHED_RESPONSE_BYTES + 1;
                let avail = cap_plus_one.saturating_sub(prefix.len());
                if chunk.len() > avail {
                    prefix.extend_from_slice(&chunk[..avail]);
                    remainder = Some(chunk.slice(avail..));
                    break;
                }
                prefix.extend_from_slice(&chunk);
                if prefix.len() > MAX_CACHED_RESPONSE_BYTES {
                    remainder = Some(Bytes::new());
                    break;
                }
            }
            Err(err) => {
                stream_err = Some(err);
                break;
            }
        }
    }

    if let Some(err) = stream_err {
        let prefix_sha = hex::encode(Sha256::digest(&prefix));
        let sentinel = StoredResponse {
            request_sha256,
            status: status.as_u16(),
            content_type,
            headers_json,
            body: Vec::new(),
            oversize: true,
            response_sha256: Some(prefix_sha),
        };
        guard.fence_committed(sentinel.clone());
        guard.complete(Some(sentinel)).await;
        let prefix_bytes = prefix.freeze();
        let out_stream = async_stream::stream! {
            if !prefix_bytes.is_empty() {
                yield Ok::<Bytes, axum::Error>(prefix_bytes);
            }
            yield Err(err);
        };
        return Response::from_parts(resp_parts, Body::from_stream(out_stream));
    }

    if let Some(rem) = remainder {
        let prefix_sha = hex::encode(Sha256::digest(&prefix));
        let sentinel = StoredResponse {
            request_sha256,
            status: status.as_u16(),
            content_type,
            headers_json,
            body: Vec::new(),
            oversize: true,
            response_sha256: Some(prefix_sha),
        };
        guard.fence_committed(sentinel.clone());
        guard.complete(Some(sentinel)).await;
        let prefix_bytes = prefix.freeze();
        let out_stream = async_stream::stream! {
            if !prefix_bytes.is_empty() {
                yield Ok::<Bytes, axum::Error>(prefix_bytes);
            }
            if !rem.is_empty() {
                yield Ok::<Bytes, axum::Error>(rem);
            }
            while let Some(item) = stream.next().await {
                yield item;
            }
        };
        return Response::from_parts(resp_parts, Body::from_stream(out_stream));
    }

    let resp_bytes = prefix.freeze();
    let response_sha256 = Some(hex::encode(Sha256::digest(&resp_bytes)));
    let stored = StoredResponse {
        request_sha256,
        status: status.as_u16(),
        content_type,
        headers_json,
        body: resp_bytes.to_vec(),
        oversize: false,
        response_sha256,
    };
    guard.fence_committed(stored.clone());
    guard.complete(Some(stored)).await;
    Response::from_parts(resp_parts, Body::from(resp_bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{routing::post, Json, Router};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::sync::Barrier;

    fn router_with_store<F, Fut, Res>(store: Arc<IdempotencyStore>, handler: F) -> Router
    where
        F: Fn(Json<serde_json::Value>) -> Fut + Clone + Send + Sync + 'static,
        Fut: std::future::Future<Output = Res> + Send + 'static,
        Res: IntoResponse + 'static,
    {
        Router::new()
            .route("/api/control/test-write", post(handler))
            .layer(axum::middleware::from_fn(
                move |req: Request<Body>, next: Next| {
                    handle_idempotency_with_store(store.clone(), req, next)
                },
            ))
    }

    #[tokio::test]
    async fn idempotency_replays_identical_post_and_rejects_mismatched_body() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(IdempotencyStore::new(dir.path().join("idem.db")));
        let calls = Arc::new(AtomicUsize::new(0));
        let calls_handler = calls.clone();

        let app = router_with_store(store, move |Json(payload): Json<serde_json::Value>| {
            let calls = calls_handler.clone();
            async move {
                let n = calls.fetch_add(1, Ordering::SeqCst) + 1;
                Json(serde_json::json!({ "call": n, "echo": payload }))
            }
        });

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

    #[tokio::test]
    async fn oversize_2xx_response_streams_to_leader_and_fences_retries_across_restart() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("idem.db");
        let store = Arc::new(IdempotencyStore::new(db_path.clone()));
        let calls = Arc::new(AtomicUsize::new(0));
        let payload_len = 600 * 1024;
        let expected_payload = vec![b'x'; payload_len];
        let handler_payload = expected_payload.clone();
        let calls_handler = calls.clone();

        let app = router_with_store(store.clone(), move |Json(_): Json<serde_json::Value>| {
            let calls = calls_handler.clone();
            let body = handler_payload.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                (
                    StatusCode::OK,
                    [(axum::http::header::CONTENT_TYPE, "application/octet-stream")],
                    body,
                )
            }
        });

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = reqwest::Client::new();
        let url = format!("http://{addr}/api/control/test-write");

        let leader_res = client
            .post(&url)
            .header("Idempotency-Key", "oversize-key-1")
            .json(&serde_json::json!({"op": "create"}))
            .send()
            .await
            .unwrap();
        assert_eq!(leader_res.status(), reqwest::StatusCode::OK);
        let leader_bytes = leader_res.bytes().await.unwrap();
        assert_eq!(leader_bytes.len(), payload_len);
        assert_eq!(leader_bytes.as_ref(), expected_payload.as_slice());
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let retry_res = client
            .post(&url)
            .header("Idempotency-Key", "oversize-key-1")
            .json(&serde_json::json!({"op": "create"}))
            .send()
            .await
            .unwrap();
        assert_eq!(retry_res.status(), reqwest::StatusCode::CONFLICT);
        assert_eq!(
            retry_res
                .headers()
                .get(IDEMPOTENT_REPLAYED_HEADER_NAME)
                .unwrap(),
            "oversize-committed"
        );
        let retry_json: serde_json::Value = retry_res.json().await.unwrap();
        assert_eq!(
            retry_json["error"],
            "idempotent_response_too_large_to_replay"
        );
        assert_eq!(retry_json["committed_status"], 200);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let mismatch_res = client
            .post(&url)
            .header("Idempotency-Key", "oversize-key-1")
            .json(&serde_json::json!({"op": "different"}))
            .send()
            .await
            .unwrap();
        assert_eq!(mismatch_res.status(), reqwest::StatusCode::CONFLICT);
        let mismatch_json: serde_json::Value = mismatch_res.json().await.unwrap();
        assert_eq!(mismatch_json["error"], "idempotency_conflict");
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        server.abort();
        let _ = server.await;
        drop(store);

        let restarted_store = Arc::new(IdempotencyStore::new(db_path));
        let calls_after_restart = calls.clone();
        let handler_payload2 = expected_payload.clone();
        let app2 = router_with_store(restarted_store, move |Json(_): Json<serde_json::Value>| {
            let calls = calls_after_restart.clone();
            let body = handler_payload2.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                (StatusCode::OK, body)
            }
        });
        let listener2 = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr2 = listener2.local_addr().unwrap();
        let server2 = tokio::spawn(async move {
            let _ = axum::serve(listener2, app2).await;
        });
        let url2 = format!("http://{addr2}/api/control/test-write");

        let post_restart_res = client
            .post(&url2)
            .header("Idempotency-Key", "oversize-key-1")
            .json(&serde_json::json!({"op": "create"}))
            .send()
            .await
            .unwrap();
        assert_eq!(post_restart_res.status(), reqwest::StatusCode::CONFLICT);
        assert_eq!(
            post_restart_res
                .headers()
                .get(IDEMPOTENT_REPLAYED_HEADER_NAME)
                .unwrap(),
            "oversize-committed"
        );
        let post_restart_json: serde_json::Value = post_restart_res.json().await.unwrap();
        assert_eq!(
            post_restart_json["error"],
            "idempotent_response_too_large_to_replay"
        );
        assert_eq!(post_restart_json["committed_status"], 200);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let post_restart_mismatch = client
            .post(&url2)
            .header("Idempotency-Key", "oversize-key-1")
            .json(&serde_json::json!({"op": "mutated"}))
            .send()
            .await
            .unwrap();
        assert_eq!(
            post_restart_mismatch.status(),
            reqwest::StatusCode::CONFLICT
        );
        let post_restart_mismatch_json: serde_json::Value =
            post_restart_mismatch.json().await.unwrap();
        assert_eq!(post_restart_mismatch_json["error"], "idempotency_conflict");
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        server2.abort();
    }

    #[tokio::test]
    async fn concurrent_follower_on_oversize_2xx_receives_fenced_receipt_without_reexecuting() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(IdempotencyStore::new(dir.path().join("idem.db")));
        let calls = Arc::new(AtomicUsize::new(0));
        let entered = Arc::new(Notify::new());
        let release = Arc::new(Barrier::new(2));
        let payload_len = 600 * 1024;

        let calls_h = calls.clone();
        let entered_h = entered.clone();
        let release_h = release.clone();
        let app = router_with_store(store.clone(), move |Json(_): Json<serde_json::Value>| {
            let calls = calls_h.clone();
            let entered = entered_h.clone();
            let release = release_h.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                entered.notify_waiters();
                release.wait().await;
                (StatusCode::OK, vec![b'z'; payload_len])
            }
        });

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = reqwest::Client::new();
        let url = format!("http://{addr}/api/control/test-write");

        let entered_wait = entered.notified();
        let c1 = client.clone();
        let u1 = url.clone();
        let leader_task = tokio::spawn(async move {
            c1.post(&u1)
                .header("Idempotency-Key", "oversize-concurrent")
                .json(&serde_json::json!({"seq": 1}))
                .send()
                .await
                .unwrap()
        });

        entered_wait.await;

        let c2 = client.clone();
        let u2 = url.clone();
        let follower_task = tokio::spawn(async move {
            c2.post(&u2)
                .header("Idempotency-Key", "oversize-concurrent")
                .json(&serde_json::json!({"seq": 1}))
                .send()
                .await
                .unwrap()
        });

        let scope = "anonymous\nPOST\n/api/control/test-write\noversize-concurrent";
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let parked = store
                    .inflight
                    .lock()
                    .unwrap()
                    .get(scope)
                    .is_some_and(|c| Arc::strong_count(&c.notify) >= 2);
                if parked {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        release.wait().await;

        let r1 = leader_task.await.unwrap();
        let r2 = follower_task.await.unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let (ok_res, conflict_res) = if r1.status() == reqwest::StatusCode::OK {
            (r1, r2)
        } else {
            (r2, r1)
        };
        assert_eq!(ok_res.status(), reqwest::StatusCode::OK);
        assert_eq!(ok_res.bytes().await.unwrap().len(), payload_len);

        assert_eq!(conflict_res.status(), reqwest::StatusCode::CONFLICT);
        assert_eq!(
            conflict_res
                .headers()
                .get(IDEMPOTENT_REPLAYED_HEADER_NAME)
                .unwrap(),
            "oversize-committed"
        );
        let body: serde_json::Value = conflict_res.json().await.unwrap();
        assert_eq!(body["error"], "idempotent_response_too_large_to_replay");
        assert_eq!(body["committed_status"], 200);

        server.abort();
    }

    #[tokio::test]
    async fn legacy_sqlite_schema_migrates_seamlessly_and_preserves_existing_rows() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("legacy.db");
        {
            let conn = rusqlite::Connection::open(&db_path).unwrap();
            conn.execute_batch(
                "CREATE TABLE http_idempotency_keys (
                    scope_key TEXT PRIMARY KEY,
                    request_sha256 TEXT NOT NULL,
                    status INTEGER NOT NULL,
                    content_type TEXT,
                    body BLOB NOT NULL,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL
                );",
            )
            .unwrap();
            let req_bytes = br#"{"legacy":true}"#;
            let sha = hex::encode(Sha256::digest(req_bytes));
            let now = Utc::now().timestamp();
            conn.execute(
                "INSERT INTO http_idempotency_keys
                    (scope_key, request_sha256, status, content_type, body, created_at, expires_at)
                 VALUES (?1, ?2, 201, 'application/json', ?3, ?4, ?5)",
                params![
                    "anonymous\nPOST\n/api/control/test-write\nlegacy-key",
                    sha,
                    br#"{"ok":1}"#.to_vec(),
                    now,
                    now + 3600,
                ],
            )
            .unwrap();
        }

        let store = Arc::new(IdempotencyStore::new(db_path));
        let calls = Arc::new(AtomicUsize::new(0));
        let calls_h = calls.clone();
        let app = router_with_store(store, move |Json(_): Json<serde_json::Value>| {
            let calls = calls_h.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                StatusCode::OK
            }
        });

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = reqwest::Client::new();
        let res = client
            .post(format!("http://{addr}/api/control/test-write"))
            .header("Idempotency-Key", "legacy-key")
            .header("Content-Type", "application/json")
            .body(r#"{"legacy":true}"#)
            .send()
            .await
            .unwrap();
        assert_eq!(res.status(), reqwest::StatusCode::CREATED);
        assert_eq!(res.headers().get(REPLAY_HEADER_NAME).unwrap(), "true");
        assert_eq!(res.text().await.unwrap(), r#"{"ok":1}"#);
        assert_eq!(calls.load(Ordering::SeqCst), 0);

        server.abort();
    }

    #[tokio::test]
    async fn mid_body_drop_or_error_after_2xx_headers_still_fences_retries() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(IdempotencyStore::new(dir.path().join("idem.db")));
        let calls = Arc::new(AtomicUsize::new(0));
        let calls_h = calls.clone();

        let app = router_with_store(store, move |Json(_): Json<serde_json::Value>| {
            let calls = calls_h.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                let broken = async_stream::stream! {
                    yield Ok::<Bytes, std::io::Error>(Bytes::from_static(b"partial-200-"));
                    yield Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "boom"));
                };
                Response::builder()
                    .status(StatusCode::OK)
                    .body(Body::from_stream(broken))
                    .unwrap()
            }
        });

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = reqwest::Client::new();
        let url = format!("http://{addr}/api/control/test-write");

        if let Ok(res1) = client
            .post(&url)
            .header("Idempotency-Key", "mid-body-err")
            .json(&serde_json::json!({"a": 1}))
            .send()
            .await
        {
            let _ = res1.bytes().await;
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let retry = client
            .post(&url)
            .header("Idempotency-Key", "mid-body-err")
            .json(&serde_json::json!({"a": 1}))
            .send()
            .await
            .unwrap();
        assert_eq!(retry.status(), reqwest::StatusCode::CONFLICT);
        assert_eq!(
            retry
                .headers()
                .get(IDEMPOTENT_REPLAYED_HEADER_NAME)
                .unwrap(),
            "oversize-committed"
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        server.abort();
    }

    #[tokio::test]
    async fn dropped_leader_during_handler_execution_fences_retries_against_reexecution() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(IdempotencyStore::new(dir.path().join("idem.db")));
        let calls = Arc::new(AtomicUsize::new(0));
        let entered = Arc::new(Notify::new());
        let calls_h = calls.clone();
        let entered_h = entered.clone();

        let app = router_with_store(store, move |Json(_): Json<serde_json::Value>| {
            let calls = calls_h.clone();
            let entered = entered_h.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                entered.notify_waiters();
                std::future::pending::<StatusCode>().await
            }
        });

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = reqwest::Client::new();
        let url = format!("http://{addr}/api/control/test-write");

        let entered_wait = entered.notified();
        let c1 = client.clone();
        let u1 = url.clone();
        let leader = tokio::spawn(async move {
            let _ = c1
                .post(&u1)
                .timeout(Duration::from_millis(40))
                .header("Idempotency-Key", "leader-cancel-1")
                .json(&serde_json::json!({"mut": 1}))
                .send()
                .await;
        });
        entered_wait.await;
        let _ = leader.await;
        tokio::time::sleep(Duration::from_millis(30)).await;

        let retry = client
            .post(&url)
            .header("Idempotency-Key", "leader-cancel-1")
            .json(&serde_json::json!({"mut": 1}))
            .send()
            .await
            .unwrap();
        assert_eq!(retry.status(), reqwest::StatusCode::CONFLICT);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        server.abort();
    }
}
