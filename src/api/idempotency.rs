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
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use std::time::Duration;

use axum::{
    body::Body,
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
use tokio_util::io::ReaderStream;

use super::auth::AuthUser;
use super::routes::AppState;

pub const HEADER_NAME: &str = "idempotency-key";
pub const REPLAY_HEADER_NAME: &str = "x-orb-idempotent-replay";
pub const IDEMPOTENT_REPLAYED_HEADER_NAME: &str = "idempotent-replayed";
const MAX_KEY_BYTES: usize = 200;
const MAX_BUFFERED_REQUEST_BYTES: usize = 2 * 1024 * 1024;
const MAX_LARGE_REQUEST_BYTES: usize = 512 * 1024 * 1024;
const MAX_CACHED_RESPONSE_BYTES: usize = 512 * 1024;
const TTL_SECS: i64 = 24 * 3600;
const INFLIGHT_WAIT: Duration = Duration::from_secs(25);

#[derive(Clone, Debug)]
struct StoredResponse {
    request_sha256: String,
    status: u16,
    content_type: Option<String>,
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
    #[cfg(test)]
    after_inflight_insert_hook: StdMutex<Option<Arc<dyn Fn(&str) + Send + Sync>>>,
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
    Leader(LeaderGuard),
    Replay(StoredResponse),
    Conflict(&'static str),
    Wait(Arc<Notify>),
}

impl IdempotencyStore {
    pub fn new(db_path: PathBuf) -> Self {
        Self {
            db_path,
            conn: StdMutex::new(None),
            inflight: StdMutex::new(HashMap::new()),
            fallback_committed: StdMutex::new(HashMap::new()),
            #[cfg(test)]
            after_inflight_insert_hook: StdMutex::new(None),
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
                    "SELECT request_sha256, status, content_type, body, oversize, response_sha256
                     FROM http_idempotency_keys
                     WHERE scope_key = ?1 AND expires_at > ?2",
                    params![scope_key, now_ts],
                    |row| {
                        Ok(StoredResponse {
                            request_sha256: row.get(0)?,
                            status: row.get::<_, u16>(1)?,
                            content_type: row.get(2)?,
                            body: row.get(3)?,
                            oversize: row.get::<_, i64>(4)? != 0,
                            response_sha256: row.get(5)?,
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
                    "",
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

    fn persist_fallback_only(&self, scope_key: &str, entry: StoredResponse, now_ts: i64) {
        let expires_at = now_ts + TTL_SECS;
        let mut fallback = self
            .fallback_committed
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        fallback.retain(|_, (_, exp)| *exp > now_ts);
        fallback.insert(scope_key.to_string(), (entry, expires_at));
    }

    fn try_claim(self: &Arc<Self>, scope_key: &str, request_sha256: &str) -> ClaimOutcome {
        let guard = {
            let mut inflight = self.inflight.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(existing) = inflight.get(scope_key) {
                if existing.request_sha256 != request_sha256 {
                    return ClaimOutcome::Conflict(
                        "Idempotency-Key is currently in flight with a different request payload",
                    );
                }
                return ClaimOutcome::Wait(existing.notify.clone());
            }
            inflight.insert(
                scope_key.to_string(),
                InFlightClaim {
                    request_sha256: request_sha256.to_string(),
                    notify: Arc::new(Notify::new()),
                },
            );
            LeaderGuard {
                store: self.clone(),
                scope_key: scope_key.to_string(),
                fallback_on_drop: None,
                completed: false,
            }
        };
        #[cfg(test)]
        {
            let hook = self
                .after_inflight_insert_hook
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone();
            if let Some(hook) = hook {
                hook(scope_key);
            }
        }
        if let Some(stored) = self.lookup_persisted(scope_key, Utc::now().timestamp()) {
            if stored.request_sha256 != request_sha256 {
                return ClaimOutcome::Conflict(
                    "Idempotency-Key was already used with a different request payload",
                );
            }
            return ClaimOutcome::Replay(stored);
        }
        ClaimOutcome::Leader(guard)
    }

    fn release_leader(&self, scope_key: &str) {
        let removed = {
            let mut inflight = self.inflight.lock().unwrap_or_else(|e| e.into_inner());
            inflight.remove(scope_key)
        };
        if let Some(claim) = removed {
            claim.notify.notify_waiters();
        }
    }

    fn finish_leader(&self, scope_key: &str, stored: Option<StoredResponse>) {
        struct ReleaseOnDrop<'a> {
            store: &'a IdempotencyStore,
            scope_key: &'a str,
        }
        impl Drop for ReleaseOnDrop<'_> {
            fn drop(&mut self) {
                self.store.release_leader(self.scope_key);
            }
        }
        let _release = ReleaseOnDrop {
            store: self,
            scope_key,
        };
        if let Some(ref entry) = stored {
            self.persist(scope_key, entry, Utc::now().timestamp());
        }
    }
}

struct DisarmableRelease {
    store: Arc<IdempotencyStore>,
    scope_key: String,
    armed: bool,
}

impl DisarmableRelease {
    fn new(store: Arc<IdempotencyStore>, scope_key: String) -> Self {
        Self {
            store,
            scope_key,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for DisarmableRelease {
    fn drop(&mut self) {
        if self.armed {
            self.store.release_leader(&self.scope_key);
        }
    }
}

fn spawn_finish_leader(
    store: Arc<IdempotencyStore>,
    scope_key: String,
    stored: Option<StoredResponse>,
) {
    let Some(stored) = stored else {
        store.release_leader(&scope_key);
        return;
    };
    let mut safety = DisarmableRelease::new(store.clone(), scope_key.clone());
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        drop(handle.spawn_blocking(move || {
            let mut safety = safety;
            safety.disarm();
            store.finish_leader(&scope_key, Some(stored));
        }));
    } else if std::thread::Builder::new()
        .name("orb-idempotency-finish".to_string())
        .spawn({
            let store = store.clone();
            let scope_key = scope_key.clone();
            let stored = stored.clone();
            move || {
                store.finish_leader(&scope_key, Some(stored));
            }
        })
        .is_ok()
    {
        safety.disarm();
    } else {
        store.persist_fallback_only(&scope_key, stored, Utc::now().timestamp());
        safety.disarm();
        store.release_leader(&scope_key);
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
        let Some(stored) = stored else {
            store.release_leader(&scope_key);
            return;
        };
        if tokio::runtime::Handle::try_current().is_ok() {
            let task_safety = DisarmableRelease::new(store.clone(), scope_key.clone());
            let store_for_task = store.clone();
            let scope_for_task = scope_key.clone();
            if tokio::task::spawn_blocking(move || {
                let mut task_safety = task_safety;
                task_safety.disarm();
                store_for_task.finish_leader(&scope_for_task, Some(stored));
            })
            .await
            .is_err()
            {
                store.release_leader(&scope_key);
            }
        } else {
            let (tx, rx) = tokio::sync::oneshot::channel();
            if std::thread::Builder::new()
                .name("orb-idempotency-complete".to_string())
                .spawn({
                    let store = store.clone();
                    let scope_key = scope_key.clone();
                    let stored = stored.clone();
                    move || {
                        store.finish_leader(&scope_key, Some(stored));
                        let _ = tx.send(());
                    }
                })
                .is_ok()
            {
                if rx.await.is_err() {
                    store.release_leader(&scope_key);
                }
            } else {
                store.persist_fallback_only(&scope_key, stored, Utc::now().timestamp());
                store.release_leader(&scope_key);
            }
        }
    }
}

impl Drop for LeaderGuard {
    fn drop(&mut self) {
        if !self.completed {
            self.completed = true;
            let store = self.store.clone();
            let scope_key = self.scope_key.clone();
            let fallback = self.fallback_on_drop.take();
            spawn_finish_leader(store, scope_key, fallback);
        }
    }
}

fn is_valid_idempotency_key(raw: &str) -> bool {
    !raw.is_empty()
        && raw.len() <= MAX_KEY_BYTES
        && raw.bytes().all(|b| b.is_ascii_graphic() || b == b' ')
}

fn allows_large_request_body(path: &str) -> bool {
    path.starts_with("/api/uploads")
        || path.starts_with("/api/fs/upload")
        || path.contains("/import-chunks")
        || path.starts_with("/api/voice/")
        || path.starts_with("/api/settings/restore")
        || path.starts_with("/api/control/missions/import")
        || path.contains("/machine-transfer")
        || path.contains("/local-origins")
        || path.contains("/btw")
}

enum BufferedRequestBody {
    Memory(Bytes),
    Spilled(std::fs::File),
}

impl BufferedRequestBody {
    fn into_body(self) -> Body {
        match self {
            Self::Memory(bytes) => Body::from(bytes),
            Self::Spilled(file) => {
                Body::from_stream(ReaderStream::new(tokio::fs::File::from_std(file)))
            }
        }
    }
}

async fn read_and_hash_request_body(
    body: Body,
    max_bytes: usize,
) -> Result<(String, BufferedRequestBody), (StatusCode, &'static str)> {
    let mut stream = body.into_data_stream();
    let mut hasher = Sha256::new();
    let mut mem = BytesMut::new();
    let mut spilled: Option<std::fs::File> = None;
    let mut total: usize = 0;

    while let Some(chunk_res) = stream.next().await {
        let chunk =
            chunk_res.map_err(|_| (StatusCode::BAD_REQUEST, "Failed to read request body"))?;
        total = total.saturating_add(chunk.len());
        if total > max_bytes {
            let msg = if max_bytes == MAX_BUFFERED_REQUEST_BYTES {
                "Request with Idempotency-Key exceeds 2 MiB body limit"
            } else {
                "Request with Idempotency-Key exceeds maximum body limit"
            };
            return Err((StatusCode::PAYLOAD_TOO_LARGE, msg));
        }
        hasher.update(&chunk);
        if let Some(file) = spilled.take() {
            let file = tokio::task::spawn_blocking(move || -> std::io::Result<std::fs::File> {
                let mut file = file;
                file.write_all(&chunk)?;
                Ok(file)
            })
            .await
            .map_err(|_| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Failed to buffer large request body",
                )
            })?
            .map_err(|_| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Failed to write large request body",
                )
            })?;
            spilled = Some(file);
        } else if mem.len().saturating_add(chunk.len()) <= MAX_BUFFERED_REQUEST_BYTES {
            mem.extend_from_slice(&chunk);
        } else {
            let initial = mem.split().freeze();
            let file = tokio::task::spawn_blocking(move || -> std::io::Result<std::fs::File> {
                let mut file = tempfile::tempfile()?;
                if !initial.is_empty() {
                    file.write_all(&initial)?;
                }
                file.write_all(&chunk)?;
                Ok(file)
            })
            .await
            .map_err(|_| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Failed to create request spool",
                )
            })?
            .map_err(|_| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Failed to spill large request body",
                )
            })?;
            spilled = Some(file);
        }
    }

    let request_sha256 = hex::encode(hasher.finalize());
    if let Some(file) = spilled {
        let file = tokio::task::spawn_blocking(move || -> std::io::Result<std::fs::File> {
            let mut file = file;
            file.seek(SeekFrom::Start(0))?;
            Ok(file)
        })
        .await
        .map_err(|_| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Failed to rewind large request body",
            )
        })?
        .map_err(|_| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Failed to seek large request body",
            )
        })?;
        Ok((request_sha256, BufferedRequestBody::Spilled(file)))
    } else {
        Ok((request_sha256, BufferedRequestBody::Memory(mem.freeze())))
    }
}

fn build_replay_response(stored: StoredResponse) -> Response {
    if stored.oversize {
        let mut payload = serde_json::json!({
            "error": "idempotent_response_too_large_to_replay",
            "committed_status": stored.status,
        });
        if let Some(sha) = stored.response_sha256 {
            payload["response_sha256"] = serde_json::Value::String(sha);
        }
        let mut resp = (StatusCode::CONFLICT, axum::Json(payload)).into_response();
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
    let path = req.uri().path().to_string();
    let max_req_bytes = if allows_large_request_body(&path) {
        MAX_LARGE_REQUEST_BYTES
    } else {
        MAX_BUFFERED_REQUEST_BYTES
    };
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
    let (request_sha256, buffered_body) =
        match read_and_hash_request_body(body, max_req_bytes).await {
            Ok(pair) => pair,
            Err(err_resp) => return err_resp.into_response(),
        };
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
            ClaimOutcome::Leader(guard) => break guard,
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

    let rebuilt_req = Request::from_parts(parts, buffered_body.into_body());
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

    if !status.is_success() || status == StatusCode::SWITCHING_PROTOCOLS {
        guard.complete(None).await;
        return resp;
    }

    let committed_sentinel = StoredResponse {
        request_sha256: request_sha256.clone(),
        status: status.as_u16(),
        content_type: content_type.clone(),
        body: Vec::new(),
        oversize: true,
        response_sha256: None,
    };
    guard.fence_committed(committed_sentinel.clone());

    if is_event_stream {
        guard.complete(Some(committed_sentinel)).await;
        return resp;
    }

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
        let expected_prefix_sha = hex::encode(Sha256::digest(
            &expected_payload[..MAX_CACHED_RESPONSE_BYTES + 1],
        ));
        let retry_json: serde_json::Value = retry_res.json().await.unwrap();
        assert_eq!(
            retry_json["error"],
            "idempotent_response_too_large_to_replay"
        );
        assert_eq!(retry_json["committed_status"], 200);
        assert_eq!(retry_json["response_sha256"], expected_prefix_sha);
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
        assert_eq!(post_restart_json["response_sha256"], expected_prefix_sha);
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
        let db_path = dir.path().join("idem.db");
        let store = Arc::new(IdempotencyStore::new(db_path.clone()));
        let calls = Arc::new(AtomicUsize::new(0));
        let headers_flushed = Arc::new(Notify::new());
        let calls_h = calls.clone();
        let headers_flushed_h = headers_flushed.clone();

        let app = router_with_store(
            store.clone(),
            move |Json(payload): Json<serde_json::Value>| {
                let calls = calls_h.clone();
                let headers_flushed = headers_flushed_h.clone();
                async move {
                    calls.fetch_add(1, Ordering::SeqCst);
                    if payload.get("mode").and_then(|v| v.as_str()) == Some("hang_body") {
                        let stalled = async_stream::stream! {
                            yield Ok::<Bytes, std::io::Error>(Bytes::from_static(b"partial-200-"));
                            headers_flushed.notify_waiters();
                            std::future::pending::<()>().await;
                        };
                        Response::builder()
                            .status(StatusCode::OK)
                            .body(Body::from_stream(stalled))
                            .unwrap()
                    } else {
                        let broken = async_stream::stream! {
                            yield Ok::<Bytes, std::io::Error>(Bytes::from_static(b"partial-200-"));
                            yield Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "boom"));
                        };
                        Response::builder()
                            .status(StatusCode::OK)
                            .body(Body::from_stream(broken))
                            .unwrap()
                    }
                }
            },
        );

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
        let retry_json: serde_json::Value = retry.json().await.unwrap();
        assert_eq!(
            retry_json["response_sha256"],
            hex::encode(Sha256::digest(b"partial-200-"))
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let flushed_wait = headers_flushed.notified();
        let c_drop = client.clone();
        let u_drop = url.clone();
        let drop_leader = tokio::spawn(async move {
            let _ = c_drop
                .post(&u_drop)
                .timeout(Duration::from_millis(60))
                .header("Idempotency-Key", "mid-body-cancel")
                .json(&serde_json::json!({"mode": "hang_body"}))
                .send()
                .await;
        });
        flushed_wait.await;
        let _ = drop_leader.await;

        let cancel_scope = "anonymous\nPOST\n/api/control/test-write\nmid-body-cancel";
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let settled = !store.inflight.lock().unwrap().contains_key(cancel_scope)
                    && store
                        .lookup_persisted(cancel_scope, Utc::now().timestamp())
                        .is_some();
                if settled {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();

        let retry_after_drop = client
            .post(&url)
            .header("Idempotency-Key", "mid-body-cancel")
            .json(&serde_json::json!({"mode": "hang_body"}))
            .send()
            .await
            .unwrap();
        assert_eq!(retry_after_drop.status(), reqwest::StatusCode::CONFLICT);
        assert_eq!(
            retry_after_drop
                .headers()
                .get(IDEMPOTENT_REPLAYED_HEADER_NAME)
                .unwrap(),
            "oversize-committed"
        );
        let drop_json: serde_json::Value = retry_after_drop.json().await.unwrap();
        assert_eq!(drop_json["committed_status"], 200);
        assert!(drop_json.get("response_sha256").is_none());
        assert_eq!(calls.load(Ordering::SeqCst), 2);

        server.abort();
        let _ = server.await;
        drop(store);

        let reopened = IdempotencyStore::new(db_path);
        let persisted = reopened
            .lookup_persisted(cancel_scope, Utc::now().timestamp())
            .expect("mid-body cancel after 2xx headers must be persisted in SQLite");
        assert!(persisted.oversize);
        assert_eq!(persisted.status, 200);
    }

    #[tokio::test]
    async fn pre_header_cancellation_releases_inflight_and_allows_retry_to_succeed() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(IdempotencyStore::new(dir.path().join("idem.db")));
        let calls = Arc::new(AtomicUsize::new(0));
        let entered = Arc::new(Notify::new());
        let calls_h = calls.clone();
        let entered_h = entered.clone();

        let app = router_with_store(
            store.clone(),
            move |Json(payload): Json<serde_json::Value>| {
                let calls = calls_h.clone();
                let entered = entered_h.clone();
                async move {
                    let n = calls.fetch_add(1, Ordering::SeqCst) + 1;
                    if n == 1 {
                        entered.notify_waiters();
                        std::future::pending::<Response>().await
                    } else {
                        Json(serde_json::json!({ "call": n, "echo": payload })).into_response()
                    }
                }
            },
        );

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
                .header("Idempotency-Key", "leader-cancel-pre-header")
                .json(&serde_json::json!({"mut": 1}))
                .send()
                .await;
        });
        entered_wait.await;
        let _ = leader.await;

        let scope = "anonymous\nPOST\n/api/control/test-write\nleader-cancel-pre-header";
        tokio::time::timeout(Duration::from_secs(5), async {
            while store.inflight.lock().unwrap().contains_key(scope) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert!(store
            .lookup_persisted(scope, Utc::now().timestamp())
            .is_none());

        let retry = client
            .post(&url)
            .header("Idempotency-Key", "leader-cancel-pre-header")
            .json(&serde_json::json!({"mut": 1}))
            .send()
            .await
            .unwrap();
        assert_eq!(retry.status(), reqwest::StatusCode::OK);
        assert!(retry.headers().get(REPLAY_HEADER_NAME).is_none());
        let retry_body: serde_json::Value = retry.json().await.unwrap();
        assert_eq!(retry_body["call"], 2);
        assert_eq!(calls.load(Ordering::SeqCst), 2);

        let replay = client
            .post(&url)
            .header("Idempotency-Key", "leader-cancel-pre-header")
            .json(&serde_json::json!({"mut": 1}))
            .send()
            .await
            .unwrap();
        assert_eq!(replay.status(), reqwest::StatusCode::OK);
        assert_eq!(replay.headers().get(REPLAY_HEADER_NAME).unwrap(), "true");
        assert_eq!(calls.load(Ordering::SeqCst), 2);

        server.abort();
    }

    #[tokio::test]
    async fn transient_5xx_or_4xx_releases_claim_so_retry_succeeds_and_replays() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(IdempotencyStore::new(dir.path().join("idem.db")));
        let calls = Arc::new(AtomicUsize::new(0));
        let calls_h = calls.clone();

        let app = router_with_store(store, move |Json(payload): Json<serde_json::Value>| {
            let calls = calls_h.clone();
            async move {
                let n = calls.fetch_add(1, Ordering::SeqCst) + 1;
                match n {
                    1 => (StatusCode::SERVICE_UNAVAILABLE, "try again").into_response(),
                    2 => (StatusCode::TOO_MANY_REQUESTS, "rate limited").into_response(),
                    _ => Json(serde_json::json!({ "attempt": n, "echo": payload })).into_response(),
                }
            }
        });

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = reqwest::Client::new();
        let url = format!("http://{addr}/api/control/test-write");

        let r1 = client
            .post(&url)
            .header("Idempotency-Key", "retry-5xx-key")
            .json(&serde_json::json!({"op": "run"}))
            .send()
            .await
            .unwrap();
        assert_eq!(r1.status(), reqwest::StatusCode::SERVICE_UNAVAILABLE);

        let r2 = client
            .post(&url)
            .header("Idempotency-Key", "retry-5xx-key")
            .json(&serde_json::json!({"op": "run"}))
            .send()
            .await
            .unwrap();
        assert_eq!(r2.status(), reqwest::StatusCode::TOO_MANY_REQUESTS);

        let r3 = client
            .post(&url)
            .header("Idempotency-Key", "retry-5xx-key")
            .json(&serde_json::json!({"op": "run"}))
            .send()
            .await
            .unwrap();
        assert_eq!(r3.status(), reqwest::StatusCode::OK);
        assert!(r3.headers().get(REPLAY_HEADER_NAME).is_none());
        let body3: serde_json::Value = r3.json().await.unwrap();
        assert_eq!(body3["attempt"], 3);

        let r4 = client
            .post(&url)
            .header("Idempotency-Key", "retry-5xx-key")
            .json(&serde_json::json!({"op": "run"}))
            .send()
            .await
            .unwrap();
        assert_eq!(r4.status(), reqwest::StatusCode::OK);
        assert_eq!(r4.headers().get(REPLAY_HEADER_NAME).unwrap(), "true");
        let body4: serde_json::Value = r4.json().await.unwrap();
        assert_eq!(body4["attempt"], 3);
        assert_eq!(calls.load(Ordering::SeqCst), 3);

        server.abort();
    }

    #[tokio::test]
    async fn unkeyed_bypass_paths_preserve_large_payloads_and_sse_streams() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("idem.db");
        let store = Arc::new(IdempotencyStore::new(db_path.clone()));
        let sse_calls = Arc::new(AtomicUsize::new(0));
        let large_calls = Arc::new(AtomicUsize::new(0));

        let sse_calls_h = sse_calls.clone();
        let large_calls_h = large_calls.clone();
        let store_mw = store.clone();
        let app = Router::new()
            .route(
                "/api/control/missions/123/ask/stream",
                post(move |body: Bytes| {
                    let sse_calls = sse_calls_h.clone();
                    async move {
                        let n = sse_calls.fetch_add(1, Ordering::SeqCst) + 1;
                        let s = async_stream::stream! {
                            yield Ok::<Bytes, std::convert::Infallible>(
                                Bytes::from(format!("data: event-{n}-{}\n\n", body.len()))
                            );
                        };
                        Response::builder()
                            .status(StatusCode::OK)
                            .header(axum::http::header::CONTENT_TYPE, "text/event-stream")
                            .body(Body::from_stream(s))
                            .unwrap()
                    }
                }),
            )
            .route(
                "/api/settings/restore",
                post({
                    let large_calls = large_calls_h.clone();
                    move |body: Bytes| {
                        let large_calls = large_calls.clone();
                        async move {
                            large_calls.fetch_add(1, Ordering::SeqCst);
                            Json(serde_json::json!({ "bytes": body.len() }))
                        }
                    }
                }),
            )
            .route(
                "/api/control/missions/import",
                post({
                    let large_calls = large_calls_h.clone();
                    move |body: Bytes| {
                        let large_calls = large_calls.clone();
                        async move {
                            large_calls.fetch_add(1, Ordering::SeqCst);
                            Json(serde_json::json!({ "bytes": body.len() }))
                        }
                    }
                }),
            )
            .route(
                "/api/control/machine-transfer/push",
                post({
                    let large_calls = large_calls_h.clone();
                    move |body: Bytes| {
                        let large_calls = large_calls.clone();
                        async move {
                            large_calls.fetch_add(1, Ordering::SeqCst);
                            Json(serde_json::json!({ "bytes": body.len() }))
                        }
                    }
                }),
            )
            .route(
                "/api/control/local-origins/sync",
                post({
                    let large_calls = large_calls_h.clone();
                    move |body: Bytes| {
                        let large_calls = large_calls.clone();
                        async move {
                            large_calls.fetch_add(1, Ordering::SeqCst);
                            Json(serde_json::json!({ "bytes": body.len() }))
                        }
                    }
                }),
            )
            .route(
                "/api/control/missions/123/btw",
                post({
                    let large_calls = large_calls_h.clone();
                    move |body: Bytes| {
                        let large_calls = large_calls.clone();
                        async move {
                            large_calls.fetch_add(1, Ordering::SeqCst);
                            Json(serde_json::json!({ "bytes": body.len() }))
                        }
                    }
                }),
            )
            .layer(axum::extract::DefaultBodyLimit::disable())
            .layer(axum::middleware::from_fn(
                move |req: Request<Body>, next: Next| {
                    handle_idempotency_with_store(store_mw.clone(), req, next)
                },
            ));

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = reqwest::Client::new();
        let large_body = vec![b'a'; MAX_BUFFERED_REQUEST_BYTES + 256 * 1024];

        for route in [
            "/api/settings/restore",
            "/api/control/missions/import",
            "/api/control/machine-transfer/push",
            "/api/control/local-origins/sync",
            "/api/control/missions/123/btw",
        ] {
            let unkeyed = client
                .post(format!("http://{addr}{route}"))
                .body(large_body.clone())
                .send()
                .await
                .unwrap();
            assert_eq!(unkeyed.status(), reqwest::StatusCode::OK, "route {route}");
            let unkeyed_json: serde_json::Value = unkeyed.json().await.unwrap();
            assert_eq!(unkeyed_json["bytes"], large_body.len());

            let keyed_first = client
                .post(format!("http://{addr}{route}"))
                .header("Idempotency-Key", "mobile-auto-key")
                .body(large_body.clone())
                .send()
                .await
                .unwrap();
            assert_eq!(
                keyed_first.status(),
                reqwest::StatusCode::OK,
                "route {route}"
            );
            assert!(keyed_first.headers().get(REPLAY_HEADER_NAME).is_none());
            let first_json: serde_json::Value = keyed_first.json().await.unwrap();
            assert_eq!(first_json["bytes"], large_body.len());

            let keyed_replay = client
                .post(format!("http://{addr}{route}"))
                .header("Idempotency-Key", "mobile-auto-key")
                .body(large_body.clone())
                .send()
                .await
                .unwrap();
            assert_eq!(
                keyed_replay.status(),
                reqwest::StatusCode::OK,
                "route {route}"
            );
            assert_eq!(
                keyed_replay.headers().get(REPLAY_HEADER_NAME).unwrap(),
                "true"
            );
            let replay_json: serde_json::Value = keyed_replay.json().await.unwrap();
            assert_eq!(replay_json["bytes"], large_body.len());
        }
        assert_eq!(large_calls.load(Ordering::SeqCst), 10);

        for expected_call in [1, 2] {
            let sse_unkeyed = client
                .post(format!("http://{addr}/api/control/missions/123/ask/stream"))
                .body(b"question".to_vec())
                .send()
                .await
                .unwrap();
            assert_eq!(sse_unkeyed.status(), reqwest::StatusCode::OK);
            let text = sse_unkeyed.text().await.unwrap();
            assert!(text.contains(&format!("event-{expected_call}-8")));
        }
        assert_eq!(sse_calls.load(Ordering::SeqCst), 2);

        let sse_keyed_first = client
            .post(format!("http://{addr}/api/control/missions/123/ask/stream"))
            .header("Idempotency-Key", "sse-same-key")
            .body(b"question".to_vec())
            .send()
            .await
            .unwrap();
        assert_eq!(sse_keyed_first.status(), reqwest::StatusCode::OK);
        let sse_first_text = sse_keyed_first.text().await.unwrap();
        assert!(sse_first_text.contains("event-3-8"));
        assert_eq!(sse_calls.load(Ordering::SeqCst), 3);

        let sse_keyed_retry = client
            .post(format!("http://{addr}/api/control/missions/123/ask/stream"))
            .header("Idempotency-Key", "sse-same-key")
            .body(b"question".to_vec())
            .send()
            .await
            .unwrap();
        assert_eq!(sse_keyed_retry.status(), reqwest::StatusCode::CONFLICT);
        assert_eq!(
            sse_keyed_retry
                .headers()
                .get(IDEMPOTENT_REPLAYED_HEADER_NAME)
                .unwrap(),
            "oversize-committed"
        );
        assert_eq!(sse_calls.load(Ordering::SeqCst), 3);

        server.abort();
        let _ = server.await;
        drop(store);

        let reopened_store = Arc::new(IdempotencyStore::new(db_path.clone()));
        let sse_calls_restart = sse_calls.clone();
        let large_calls_restart = large_calls.clone();
        let app_restart = Router::new()
            .route(
                "/api/control/missions/123/ask/stream",
                post(move |_body: Bytes| {
                    let sse_calls = sse_calls_restart.clone();
                    async move {
                        sse_calls.fetch_add(1, Ordering::SeqCst);
                        Response::builder()
                            .status(StatusCode::OK)
                            .header(axum::http::header::CONTENT_TYPE, "text/event-stream")
                            .body(Body::from("data: unexpected\n\n"))
                            .unwrap()
                    }
                }),
            )
            .route(
                "/api/settings/restore",
                post(move |body: Bytes| {
                    let large_calls = large_calls_restart.clone();
                    async move {
                        large_calls.fetch_add(1, Ordering::SeqCst);
                        Json(serde_json::json!({ "bytes": body.len() }))
                    }
                }),
            )
            .layer(axum::extract::DefaultBodyLimit::disable())
            .layer(axum::middleware::from_fn(
                move |req: Request<Body>, next: Next| {
                    handle_idempotency_with_store(reopened_store.clone(), req, next)
                },
            ));
        let listener2 = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr2 = listener2.local_addr().unwrap();
        let server2 = tokio::spawn(async move {
            let _ = axum::serve(listener2, app_restart).await;
        });

        let restore_after_restart = client
            .post(format!("http://{addr2}/api/settings/restore"))
            .header("Idempotency-Key", "mobile-auto-key")
            .body(large_body)
            .send()
            .await
            .unwrap();
        assert_eq!(restore_after_restart.status(), reqwest::StatusCode::OK);
        assert_eq!(
            restore_after_restart
                .headers()
                .get(REPLAY_HEADER_NAME)
                .unwrap(),
            "true"
        );
        assert_eq!(large_calls.load(Ordering::SeqCst), 10);

        let sse_after_restart = client
            .post(format!(
                "http://{addr2}/api/control/missions/123/ask/stream"
            ))
            .header("Idempotency-Key", "sse-same-key")
            .body(b"question".to_vec())
            .send()
            .await
            .unwrap();
        assert_eq!(sse_after_restart.status(), reqwest::StatusCode::CONFLICT);
        assert_eq!(
            sse_after_restart
                .headers()
                .get(IDEMPOTENT_REPLAYED_HEADER_NAME)
                .unwrap(),
            "oversize-committed"
        );
        assert_eq!(sse_calls.load(Ordering::SeqCst), 3);

        let count: i64 = rusqlite::Connection::open(&db_path)
            .unwrap()
            .query_row("SELECT COUNT(*) FROM http_idempotency_keys", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(count, 6);

        server2.abort();
    }

    #[tokio::test]
    async fn sensitive_response_headers_are_never_persisted_in_sqlite() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("idem.db");
        let store = Arc::new(IdempotencyStore::new(db_path.clone()));

        let app = router_with_store(
            store,
            move |Json(payload): Json<serde_json::Value>| async move {
                let secret_cookie = "session=super-secret-cookie-token-999; HttpOnly; Secure";
                let secret_auth = "Bearer top-secret-downstream-token";
                if payload.get("oversize").and_then(|v| v.as_bool()) == Some(true) {
                    Response::builder()
                        .status(StatusCode::OK)
                        .header(axum::http::header::CONTENT_TYPE, "application/octet-stream")
                        .header(axum::http::header::SET_COOKIE, secret_cookie)
                        .header("x-secret-token", secret_auth)
                        .body(Body::from(vec![b'q'; MAX_CACHED_RESPONSE_BYTES + 128]))
                        .unwrap()
                } else {
                    Response::builder()
                        .status(StatusCode::OK)
                        .header(axum::http::header::CONTENT_TYPE, "application/json")
                        .header(axum::http::header::SET_COOKIE, secret_cookie)
                        .header("x-secret-token", secret_auth)
                        .body(Body::from(r#"{"ok":true}"#))
                        .unwrap()
                }
            },
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = reqwest::Client::new();
        let url = format!("http://{addr}/api/control/test-write");

        let r1 = client
            .post(&url)
            .header("Idempotency-Key", "redact-normal")
            .json(&serde_json::json!({"oversize": false}))
            .send()
            .await
            .unwrap();
        assert_eq!(r1.status(), reqwest::StatusCode::OK);
        assert!(r1.headers().get(reqwest::header::SET_COOKIE).is_some());

        let r1_replay = client
            .post(&url)
            .header("Idempotency-Key", "redact-normal")
            .json(&serde_json::json!({"oversize": false}))
            .send()
            .await
            .unwrap();
        assert_eq!(r1_replay.status(), reqwest::StatusCode::OK);
        assert!(r1_replay
            .headers()
            .get(reqwest::header::SET_COOKIE)
            .is_none());

        let r2 = client
            .post(&url)
            .header("Idempotency-Key", "redact-oversize")
            .json(&serde_json::json!({"oversize": true}))
            .send()
            .await
            .unwrap();
        assert_eq!(r2.status(), reqwest::StatusCode::OK);
        let _ = r2.bytes().await.unwrap();

        server.abort();
        let _ = server.await;

        let conn = rusqlite::Connection::open(&db_path).unwrap();
        let mut stmt = conn
            .prepare("SELECT headers_json FROM http_idempotency_keys")
            .unwrap();
        let rows: Vec<Option<String>> = stmt
            .query_map([], |row| row.get(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(rows.len(), 2);
        for val in rows {
            assert_eq!(val.as_deref(), Some(""));
        }

        drop(stmt);
        let _ = conn.pragma_update(None, "wal_checkpoint", "TRUNCATE");
        drop(conn);
        let raw_db = std::fs::read(&db_path).unwrap();
        let raw_lossy = String::from_utf8_lossy(&raw_db);
        assert!(!raw_lossy.contains("super-secret-cookie-token-999"));
        assert!(!raw_lossy.contains("top-secret-downstream-token"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn leader_guard_drop_offloads_persistence_and_notifies_waiters_only_after_commit() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("idem.db");
        let store = Arc::new(IdempotencyStore::new(db_path));
        let scope = "u1\nPOST\n/api/control/test-write\ndrop-offload-key".to_string();
        let req_sha = hex::encode(Sha256::digest(b"{}"));

        let ClaimOutcome::Leader(mut guard) = store.try_claim(&scope, &req_sha) else {
            panic!("expected leader");
        };
        let notify = match store.try_claim(&scope, &req_sha) {
            ClaimOutcome::Wait(n) => n,
            _ => panic!("expected Wait outcome while leader is inflight"),
        };

        let notified = notify.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();

        let conn_lock = store.conn.lock().unwrap();
        guard.fence_committed(StoredResponse {
            request_sha256: req_sha.clone(),
            status: 200,
            content_type: Some("application/json".to_string()),
            body: Vec::new(),
            oversize: true,
            response_sha256: None,
        });

        drop(guard);

        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(store.inflight.lock().unwrap().contains_key(&scope));

        drop(conn_lock);

        tokio::time::timeout(Duration::from_secs(5), notified)
            .await
            .expect("waiter must be notified once spawn_blocking persistence completes");
        assert!(!store.inflight.lock().unwrap().contains_key(&scope));
        match store.try_claim(&scope, &req_sha) {
            ClaimOutcome::Replay(stored) => {
                assert!(stored.oversize);
                assert_eq!(stored.status, 200);
            }
            _ => panic!("expected durable Replay after drop persistence completed"),
        }
    }

    #[test]
    fn finish_leader_releases_inflight_and_wakes_waiter_even_outside_tokio() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(IdempotencyStore::new(dir.path().join("idem.db")));
        let scope = "u1\nPOST\n/api/control/test-write\noutside-tokio".to_string();
        let req_sha = hex::encode(Sha256::digest(b"{}"));

        let ClaimOutcome::Leader(mut guard) = store.try_claim(&scope, &req_sha) else {
            panic!("expected leader");
        };
        guard.fence_committed(StoredResponse {
            request_sha256: req_sha.clone(),
            status: 201,
            content_type: None,
            body: Vec::new(),
            oversize: true,
            response_sha256: None,
        });
        drop(guard);

        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while store.inflight.lock().unwrap().contains_key(&scope) {
            assert!(
                std::time::Instant::now() < deadline,
                "inflight never cleared outside tokio"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(store
            .lookup_persisted(&scope, Utc::now().timestamp())
            .is_some());
    }

    #[tokio::test]
    async fn complete_aborted_mid_await_still_persists_and_releases_inflight() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(IdempotencyStore::new(dir.path().join("idem.db")));
        let scope = "u1\nPOST\n/api/control/test-write\nabort-complete-key".to_string();
        let req_sha = hex::encode(Sha256::digest(b"{}"));

        let ClaimOutcome::Leader(guard) = store.try_claim(&scope, &req_sha) else {
            panic!("expected leader");
        };
        let notify = match store.try_claim(&scope, &req_sha) {
            ClaimOutcome::Wait(n) => n,
            _ => panic!("expected Wait outcome"),
        };
        let notified = notify.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();

        let conn_lock = store.conn.lock().unwrap();
        let sha_task = req_sha.clone();
        let task = tokio::spawn(async move {
            guard
                .complete(Some(StoredResponse {
                    request_sha256: sha_task,
                    status: 200,
                    content_type: None,
                    body: b"ok".to_vec(),
                    oversize: false,
                    response_sha256: None,
                }))
                .await;
        });

        tokio::time::sleep(Duration::from_millis(20)).await;
        task.abort();
        let _ = task.await;
        assert!(store.inflight.lock().unwrap().contains_key(&scope));

        drop(conn_lock);
        tokio::time::timeout(Duration::from_secs(5), notified)
            .await
            .expect("waiter must still be notified after complete() future abort");
        assert!(!store.inflight.lock().unwrap().contains_key(&scope));
        assert!(store
            .lookup_persisted(&scope, Utc::now().timestamp())
            .is_some());
    }

    #[tokio::test]
    async fn mutating_sse_route_fences_committed_2xx_across_restart_and_allows_non_2xx_retry() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("idem.db");
        let store = Arc::new(IdempotencyStore::new(db_path.clone()));
        let calls = Arc::new(AtomicUsize::new(0));

        let calls_h = calls.clone();
        let store_mw = store.clone();
        let app = Router::new()
            .route(
                "/api/control/custom-stream-mutation",
                post(move |Json(payload): Json<serde_json::Value>| {
                    let calls = calls_h.clone();
                    async move {
                        let n = calls.fetch_add(1, Ordering::SeqCst) + 1;
                        if payload.get("fail_once").and_then(|v| v.as_bool()) == Some(true)
                            && n == 1
                        {
                            return Response::builder()
                                .status(StatusCode::SERVICE_UNAVAILABLE)
                                .header(axum::http::header::CONTENT_TYPE, "text/event-stream")
                                .body(Body::from("data: transient-error\n\n"))
                                .unwrap();
                        }
                        let s = async_stream::stream! {
                            yield Ok::<Bytes, std::convert::Infallible>(
                                Bytes::from(format!("data: committed-{n}\n\n"))
                            );
                        };
                        Response::builder()
                            .status(StatusCode::OK)
                            .header(
                                axum::http::header::CONTENT_TYPE,
                                "text/event-stream; charset=utf-8",
                            )
                            .body(Body::from_stream(s))
                            .unwrap()
                    }
                }),
            )
            .layer(axum::middleware::from_fn(
                move |req: Request<Body>, next: Next| {
                    handle_idempotency_with_store(store_mw.clone(), req, next)
                },
            ));

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = reqwest::Client::new();
        let url = format!("http://{addr}/api/control/custom-stream-mutation");

        let failed = client
            .post(&url)
            .header("Idempotency-Key", "custom-sse-key")
            .json(&serde_json::json!({"fail_once": true}))
            .send()
            .await
            .unwrap();
        assert_eq!(failed.status(), reqwest::StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let committed = client
            .post(&url)
            .header("Idempotency-Key", "custom-sse-key")
            .json(&serde_json::json!({"fail_once": true}))
            .send()
            .await
            .unwrap();
        assert_eq!(committed.status(), reqwest::StatusCode::OK);
        let text = committed.text().await.unwrap();
        assert!(text.contains("committed-2"));
        assert_eq!(calls.load(Ordering::SeqCst), 2);

        let retry = client
            .post(&url)
            .header("Idempotency-Key", "custom-sse-key")
            .json(&serde_json::json!({"fail_once": true}))
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
        assert_eq!(calls.load(Ordering::SeqCst), 2);

        server.abort();
        let _ = server.await;
        drop(store);

        let reopened = Arc::new(IdempotencyStore::new(db_path));
        let calls_restart = calls.clone();
        let app_restart = Router::new()
            .route(
                "/api/control/custom-stream-mutation",
                post(move |Json(_): Json<serde_json::Value>| {
                    let calls = calls_restart.clone();
                    async move {
                        calls.fetch_add(1, Ordering::SeqCst);
                        Response::builder()
                            .status(StatusCode::OK)
                            .header(axum::http::header::CONTENT_TYPE, "text/event-stream")
                            .body(Body::from("data: duplicate\n\n"))
                            .unwrap()
                    }
                }),
            )
            .layer(axum::middleware::from_fn(
                move |req: Request<Body>, next: Next| {
                    handle_idempotency_with_store(reopened.clone(), req, next)
                },
            ));
        let listener2 = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr2 = listener2.local_addr().unwrap();
        let server2 = tokio::spawn(async move {
            let _ = axum::serve(listener2, app_restart).await;
        });

        let retry_after_restart = client
            .post(format!("http://{addr2}/api/control/custom-stream-mutation"))
            .header("Idempotency-Key", "custom-sse-key")
            .json(&serde_json::json!({"fail_once": true}))
            .send()
            .await
            .unwrap();
        assert_eq!(retry_after_restart.status(), reqwest::StatusCode::CONFLICT);
        assert_eq!(
            retry_after_restart
                .headers()
                .get(IDEMPOTENT_REPLAYED_HEADER_NAME)
                .unwrap(),
            "oversize-committed"
        );
        assert_eq!(calls.load(Ordering::SeqCst), 2);

        server2.abort();
    }

    #[tokio::test]
    async fn cancelled_claim_acquisition_after_inflight_insert_releases_without_orphan() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(IdempotencyStore::new(dir.path().join("idem.db")));
        let calls = Arc::new(AtomicUsize::new(0));

        let entered = Arc::new(std::sync::Barrier::new(2));
        let release = Arc::new(std::sync::Barrier::new(2));
        let entered_hook = entered.clone();
        let release_hook = release.clone();
        *store.after_inflight_insert_hook.lock().unwrap() = Some(Arc::new(move |_| {
            entered_hook.wait();
            release_hook.wait();
        }));

        let middleware_cancel_notify = Arc::new(Notify::new());
        let middleware_cancel_signal = middleware_cancel_notify.clone();
        let store_mw = store.clone();
        let calls_mw = calls.clone();
        let app1 = Router::new()
            .route(
                "/api/control/test-write",
                post(move |Json(payload): Json<serde_json::Value>| {
                    let calls = calls_mw.clone();
                    async move {
                        let n = calls.fetch_add(1, Ordering::SeqCst) + 1;
                        Json(serde_json::json!({ "call": n, "payload": payload }))
                    }
                }),
            )
            .layer(axum::middleware::from_fn(
                move |req: Request<Body>, next: Next| {
                    let store_mw = store_mw.clone();
                    let cancel = middleware_cancel_signal.clone();
                    async move {
                        tokio::select! {
                            resp = handle_idempotency_with_store(store_mw, req, next) => resp,
                            _ = cancel.notified() => StatusCode::REQUEST_TIMEOUT.into_response(),
                        }
                    }
                },
            ));
        let listener1 = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr1 = listener1.local_addr().unwrap();
        let server1 = tokio::spawn(async move {
            let _ = axum::serve(listener1, app1).await;
        });
        let client = reqwest::Client::new();
        let url1 = format!("http://{addr1}/api/control/test-write");
        let url1_req = url1.clone();
        let client_req = client.clone();
        let req_join = tokio::spawn(async move {
            client_req
                .post(&url1_req)
                .header("Idempotency-Key", "cancel-mid-claim")
                .json(&serde_json::json!({"op": "first"}))
                .send()
                .await
                .unwrap()
        });

        let entered_wait = entered.clone();
        tokio::task::spawn_blocking(move || {
            entered_wait.wait();
        })
        .await
        .unwrap();

        let scope = "anonymous\nPOST\n/api/control/test-write\ncancel-mid-claim";
        assert!(store.inflight.lock().unwrap().contains_key(scope));

        middleware_cancel_notify.notify_waiters();
        let cancelled_resp = req_join.await.unwrap();
        assert_eq!(
            cancelled_resp.status(),
            reqwest::StatusCode::REQUEST_TIMEOUT
        );

        *store.after_inflight_insert_hook.lock().unwrap() = None;
        tokio::task::spawn_blocking(move || {
            release.wait();
        })
        .await
        .unwrap();

        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while store.inflight.lock().unwrap().contains_key(scope) {
            assert!(
                tokio::time::Instant::now() < deadline,
                "cancelled claim left orphaned inflight entry"
            );
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert_eq!(calls.load(Ordering::SeqCst), 0);

        let retry = client
            .post(&url1)
            .header("Idempotency-Key", "cancel-mid-claim")
            .json(&serde_json::json!({"op": "first"}))
            .send()
            .await
            .unwrap();
        assert_eq!(retry.status(), reqwest::StatusCode::OK);
        let body: serde_json::Value = retry.json().await.unwrap();
        assert_eq!(body["call"], 1);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        server1.abort();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn sqlite_lock_contention_does_not_stall_tokio_tasks_followers_or_lazy_init() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("lazy-subdir").join("idem.db");
        let store = Arc::new(IdempotencyStore::new(db_path.clone()));
        assert!(!db_path.exists());

        let scope_blocked = "u1\nPOST\n/api/control/test-write\nsqlite-contended".to_string();
        let sha_blocked = hex::encode(Sha256::digest(b"{\"k\":1}"));
        let sha_conflict = hex::encode(Sha256::digest(b"{\"k\":2}"));

        let conn_guard = store.conn.lock().unwrap();

        let store_leader = store.clone();
        let scope_leader = scope_blocked.clone();
        let sha_leader = sha_blocked.clone();
        let leader_claim = tokio::spawn(async move {
            tokio::task::spawn_blocking(move || store_leader.try_claim(&scope_leader, &sha_leader))
                .await
                .unwrap()
        });

        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while !store.inflight.lock().unwrap().contains_key(&scope_blocked) {
            assert!(
                tokio::time::Instant::now() < deadline,
                "leader did not record inflight claim before blocking on SQLite"
            );
            tokio::time::sleep(Duration::from_millis(2)).await;
        }

        let heartbeat = tokio::time::timeout(
            Duration::from_millis(200),
            tokio::spawn(async { 42usize }),
        )
        .await
        .expect("tokio current_thread runtime must stay responsive under SQLite lock contention")
        .unwrap();
        assert_eq!(heartbeat, 42);

        let follower_same = tokio::time::timeout(Duration::from_millis(200), {
            let store_f = store.clone();
            let scope_f = scope_blocked.clone();
            let sha_f = sha_blocked.clone();
            async move {
                tokio::task::spawn_blocking(move || store_f.try_claim(&scope_f, &sha_f))
                    .await
                    .unwrap()
            }
        })
        .await
        .expect("same-payload follower check must not block on SQLite mutex");
        assert!(matches!(follower_same, ClaimOutcome::Wait(_)));

        let follower_conflict = tokio::time::timeout(Duration::from_millis(200), {
            let store_c = store.clone();
            let scope_c = scope_blocked.clone();
            async move {
                tokio::task::spawn_blocking(move || store_c.try_claim(&scope_c, &sha_conflict))
                    .await
                    .unwrap()
            }
        })
        .await
        .expect("conflicting follower check must not block on SQLite mutex");
        assert!(matches!(follower_conflict, ClaimOutcome::Conflict(_)));

        drop(conn_guard);

        let outcome = tokio::time::timeout(Duration::from_secs(5), leader_claim)
            .await
            .expect("leader claim must finish once SQLite mutex is released")
            .unwrap();
        let ClaimOutcome::Leader(mut guard) = outcome else {
            panic!("expected Leader outcome");
        };
        assert!(db_path.exists());

        let conn_guard2 = store.conn.lock().unwrap();
        guard.fence_committed(StoredResponse {
            request_sha256: sha_blocked.clone(),
            status: 200,
            content_type: None,
            body: Vec::new(),
            oversize: true,
            response_sha256: None,
        });
        let drop_started = std::time::Instant::now();
        drop(guard);
        assert!(drop_started.elapsed() < Duration::from_millis(100));

        let post_drop_tick =
            tokio::time::timeout(Duration::from_millis(200), tokio::spawn(async { "alive" }))
                .await
                .expect("LeaderGuard::drop must never block current_thread runtime")
                .unwrap();
        assert_eq!(post_drop_tick, "alive");

        drop(conn_guard2);
        let clear_deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while store.inflight.lock().unwrap().contains_key(&scope_blocked) {
            assert!(tokio::time::Instant::now() < clear_deadline);
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }
}
