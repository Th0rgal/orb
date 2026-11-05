//! Proxy API key management — generate, list, and revoke long-lived API keys
//! for external tools to authenticate against the `/v1` proxy endpoint.
//!
//! Keys are persisted to `{working_dir}/.sandboxed-sh/proxy_api_keys.json`.
//! The internal `SANDBOXED_PROXY_SECRET` (used by mission_runner / OpenCode)
//! continues to work alongside user-generated keys.

use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use arc_swap::ArcSwap;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::Json,
    routing::{delete, get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;
use uuid::Uuid;

use super::routes::AppState;

/// Sentinel timestamp value representing `None` in `AtomicI64`.
const UNSET_TIMESTAMP_MS: i64 = i64::MIN;

/// Minimum interval between disk writes for `last_used_at` updates on a single key.
const TOUCH_PERSIST_INTERVAL_MS: i64 = 60_000;

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

/// A proxy API key record (persisted to disk).
///
/// The raw key value is only returned once at creation time. On disk we store
/// a SHA-256 hash so that a leaked JSON file does not expose usable keys.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyApiKey {
    pub id: Uuid,
    /// Human-readable label (e.g. "Cursor", "Windsurf", "CI").
    pub name: String,
    /// SHA-256 hex digest of the raw key value.
    pub key_hash: String,
    /// First 8 characters of the raw key for display (e.g. "sk-proxy-a1b2c3d4…").
    pub key_prefix: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    /// Last time this key successfully authenticated a proxy request.
    /// `None` for keys that predate usage tracking or were never used.
    #[serde(default)]
    pub last_used_at: Option<chrono::DateTime<chrono::Utc>>,
}

/// Request body for creating a new key.
#[derive(Debug, Deserialize)]
pub struct CreateKeyRequest {
    /// Human-readable label for the key.
    pub name: String,
}

/// Response returned when a key is created (includes the raw key once).
#[derive(Debug, Serialize)]
pub struct CreateKeyResponse {
    pub id: Uuid,
    pub name: String,
    /// The full API key — shown only at creation time.
    pub key: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

/// Summary returned when listing keys (no raw value, just metadata).
#[derive(Debug, Serialize)]
pub struct KeySummary {
    pub id: Uuid,
    pub name: String,
    pub key_prefix: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub last_used_at: Option<chrono::DateTime<chrono::Utc>>,
}

impl From<&ProxyApiKey> for KeySummary {
    fn from(k: &ProxyApiKey) -> Self {
        Self {
            id: k.id,
            name: k.name.clone(),
            key_prefix: k.key_prefix.clone(),
            created_at: k.created_at,
            last_used_at: k.last_used_at,
        }
    }
}

/// Request body for cleaning up unused keys.
#[derive(Debug, Deserialize)]
pub struct CleanupRequest {
    /// Keys with no activity for at least this many days are candidates.
    /// Defaults to 7.
    pub max_age_days: Option<u32>,
    /// When true, only report candidates without deleting anything.
    pub dry_run: Option<bool>,
}

/// Response for a cleanup request.
#[derive(Debug, Serialize)]
pub struct CleanupResponse {
    pub dry_run: bool,
    /// Keys whose last activity predates this instant were selected.
    pub cutoff: chrono::DateTime<chrono::Utc>,
    /// The candidate keys (dry run) or the keys that were deleted.
    pub keys: Vec<KeySummary>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Store
// ─────────────────────────────────────────────────────────────────────────────

pub type SharedProxyApiKeyStore = Arc<ProxyApiKeyStore>;

#[derive(Debug)]
struct ProxyKeyEntry {
    record: ProxyApiKey,
    last_used_ms: AtomicI64,
    persisted_ms: AtomicI64,
}

impl ProxyKeyEntry {
    fn from_record(record: ProxyApiKey) -> Self {
        let initial_ms = record
            .last_used_at
            .map(|dt| dt.timestamp_millis())
            .unwrap_or(UNSET_TIMESTAMP_MS);
        Self {
            record,
            last_used_ms: AtomicI64::new(initial_ms),
            persisted_ms: AtomicI64::new(initial_ms),
        }
    }

    fn current_last_used(&self) -> Option<chrono::DateTime<chrono::Utc>> {
        let ms = self.last_used_ms.load(Ordering::Relaxed);
        if ms == UNSET_TIMESTAMP_MS {
            None
        } else {
            chrono::DateTime::from_timestamp_millis(ms)
        }
    }

    fn to_record(&self) -> ProxyApiKey {
        let mut out = self.record.clone();
        out.last_used_at = self.current_last_used();
        out
    }

    fn to_summary(&self) -> KeySummary {
        KeySummary {
            id: self.record.id,
            name: self.record.name.clone(),
            key_prefix: self.record.key_prefix.clone(),
            created_at: self.record.created_at,
            last_used_at: self.current_last_used(),
        }
    }
}

#[derive(Debug)]
pub struct ProxyApiKeyStore {
    keys: ArcSwap<Vec<Arc<ProxyKeyEntry>>>,
    writer: Mutex<()>,
    storage_path: PathBuf,
}

impl ProxyApiKeyStore {
    pub async fn new(storage_path: PathBuf) -> Self {
        let store = Self {
            keys: ArcSwap::from_pointee(Vec::new()),
            writer: Mutex::new(()),
            storage_path,
        };
        if let Ok(loaded) = store.load_from_disk() {
            let entries = loaded
                .into_iter()
                .map(|k| Arc::new(ProxyKeyEntry::from_record(k)))
                .collect();
            store.keys.store(Arc::new(entries));
        }
        store
    }

    fn load_from_disk(&self) -> Result<Vec<ProxyApiKey>, std::io::Error> {
        if !self.storage_path.exists() {
            return Ok(Vec::new());
        }
        let contents = std::fs::read_to_string(&self.storage_path)?;
        serde_json::from_str(&contents)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
    }

    async fn save_entries_async(
        &self,
        entries: &[Arc<ProxyKeyEntry>],
    ) -> Result<(), std::io::Error> {
        let records: Vec<ProxyApiKey> = entries.iter().map(|e| e.to_record()).collect();
        let contents = serde_json::to_string_pretty(&records)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        crate::concurrency::write_atomic_async(&self.storage_path, contents.as_bytes(), None).await
    }

    /// Create a new API key. Returns the raw key value (only available once).
    pub async fn create(&self, name: String) -> Result<CreateKeyResponse, String> {
        let id = Uuid::new_v4();
        let raw_key = format!("sk-proxy-{}", Uuid::new_v4().as_simple());
        let key_hash = hex_sha256(&raw_key);
        let key_prefix = raw_key[..16].to_string();
        let now = chrono::Utc::now();

        let record = ProxyApiKey {
            id,
            name: name.clone(),
            key_hash,
            key_prefix,
            created_at: now,
            last_used_at: None,
        };

        let _guard = self.writer.lock().await;
        let mut next: Vec<Arc<ProxyKeyEntry>> = (*self.keys.load_full()).clone();
        next.push(Arc::new(ProxyKeyEntry::from_record(record)));
        self.save_entries_async(&next)
            .await
            .map_err(|e| format!("Failed to persist proxy API key: {}", e))?;
        self.keys.store(Arc::new(next));

        Ok(CreateKeyResponse {
            id,
            name,
            key: raw_key,
            created_at: now,
        })
    }

    /// List all keys (metadata only, no raw values).
    pub async fn list(&self) -> Vec<KeySummary> {
        self.keys
            .load()
            .iter()
            .map(|entry| entry.to_summary())
            .collect()
    }

    /// Delete a key by ID. Returns true if found and removed.
    pub async fn delete(&self, id: Uuid) -> Result<bool, String> {
        let _guard = self.writer.lock().await;
        let current = self.keys.load_full();
        let mut next: Vec<Arc<ProxyKeyEntry>> = current
            .iter()
            .filter(|e| e.record.id != id)
            .cloned()
            .collect();
        if next.len() == current.len() {
            return Ok(false);
        }
        next.shrink_to_fit();
        self.save_entries_async(&next)
            .await
            .map_err(|e| format!("Failed to persist proxy API key deletion: {}", e))?;
        self.keys.store(Arc::new(next));
        Ok(true)
    }

    /// Check whether a bearer token matches any stored API key (constant-time).
    ///
    /// On a match, records the key's `last_used_at` atomically with zero locks
    /// on the hot `/v1` request path, persisting to disk at most once per minute
    /// per key via `tokio::fs`.
    pub async fn verify(&self, token: &str) -> bool {
        let token_hash = hex_sha256(token);
        let snapshot = self.keys.load();
        let mut matched: Vec<Arc<ProxyKeyEntry>> = Vec::new();
        // Compare against all key hashes to avoid timing leaks on which key
        // matched. We still iterate all entries even after a match.
        for entry in snapshot.iter() {
            if super::auth::constant_time_eq(&token_hash, &entry.record.key_hash) {
                matched.push(Arc::clone(entry));
            }
        }
        drop(snapshot);

        if matched.is_empty() {
            return false;
        }

        let now_ms = chrono::Utc::now().timestamp_millis();
        let mut should_persist = false;
        for entry in &matched {
            entry.last_used_ms.store(now_ms, Ordering::Relaxed);
            let prev_persisted = entry.persisted_ms.load(Ordering::Relaxed);
            let due = prev_persisted == UNSET_TIMESTAMP_MS
                || now_ms.saturating_sub(prev_persisted) >= TOUCH_PERSIST_INTERVAL_MS;
            if due
                && entry
                    .persisted_ms
                    .compare_exchange(prev_persisted, now_ms, Ordering::AcqRel, Ordering::Relaxed)
                    .is_ok()
            {
                should_persist = true;
            }
        }

        if should_persist {
            let _guard = self.writer.lock().await;
            let current = self.keys.load_full();
            if let Err(e) = self.save_entries_async(&current).await {
                tracing::warn!("Failed to persist proxy key usage timestamp: {}", e);
            }
        }
        true
    }

    /// Find the stored key matching a raw token, without recording usage.
    ///
    /// Used by infrastructure that re-reads its own provisioned key (e.g. the
    /// Hermes gateway env) to check it is still valid before reusing it.
    pub async fn find_by_token(&self, token: &str) -> Option<KeySummary> {
        let token_hash = hex_sha256(token);
        let keys = self.keys.load();
        let mut found = None;
        for entry in keys.iter() {
            if super::auth::constant_time_eq(&token_hash, &entry.record.key_hash) {
                found = Some(entry.to_summary());
            }
        }
        found
    }

    /// Delete every key whose name starts with `prefix`, except `keep`.
    /// Returns the deleted keys. Used to garbage-collect keys leaked by
    /// repeated provisioning runs (e.g. one "Hermes Assistant …" key per
    /// adopt invocation).
    pub async fn delete_named_except(
        &self,
        prefix: &str,
        keep: Option<Uuid>,
    ) -> Result<Vec<KeySummary>, String> {
        let doomed =
            |e: &ProxyKeyEntry| e.record.name.starts_with(prefix) && keep != Some(e.record.id);
        let _guard = self.writer.lock().await;
        let current = self.keys.load_full();
        let deleted: Vec<KeySummary> = current
            .iter()
            .filter(|e| doomed(e))
            .map(|e| e.to_summary())
            .collect();
        if deleted.is_empty() {
            return Ok(deleted);
        }
        let next: Vec<Arc<ProxyKeyEntry>> =
            current.iter().filter(|e| !doomed(e)).cloned().collect();
        self.save_entries_async(&next)
            .await
            .map_err(|e| format!("Failed to persist proxy API key cleanup: {}", e))?;
        self.keys.store(Arc::new(next));
        Ok(deleted)
    }

    /// Find keys whose last activity is older than `cutoff`, optionally
    /// deleting them. A key's last activity is `last_used_at`, falling back to
    /// `created_at` for keys that have never authenticated a request (or
    /// predate usage tracking).
    pub async fn cleanup_unused(
        &self,
        cutoff: chrono::DateTime<chrono::Utc>,
        dry_run: bool,
    ) -> Result<Vec<KeySummary>, String> {
        let is_stale = |e: &ProxyKeyEntry| -> bool {
            e.current_last_used().unwrap_or(e.record.created_at) < cutoff
        };
        if dry_run {
            return Ok(self
                .keys
                .load()
                .iter()
                .filter(|e| is_stale(e))
                .map(|e| e.to_summary())
                .collect());
        }
        let _guard = self.writer.lock().await;
        let current = self.keys.load_full();
        let stale: Vec<KeySummary> = current
            .iter()
            .filter(|e| is_stale(e))
            .map(|e| e.to_summary())
            .collect();
        if stale.is_empty() {
            return Ok(stale);
        }
        let next: Vec<Arc<ProxyKeyEntry>> =
            current.iter().filter(|e| !is_stale(e)).cloned().collect();
        self.save_entries_async(&next)
            .await
            .map_err(|e| format!("Failed to persist proxy API key cleanup: {}", e))?;
        self.keys.store(Arc::new(next));
        Ok(stale)
    }
}

fn hex_sha256(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    format!("{:x}", hasher.finalize())
}

// ─────────────────────────────────────────────────────────────────────────────
// API Handlers
// ─────────────────────────────────────────────────────────────────────────────

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/", get(list_keys))
        .route("/", post(create_key))
        .route("/cleanup", post(cleanup_keys))
        .route("/:id", delete(delete_key))
}

async fn list_keys(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<KeySummary>>, StatusCode> {
    Ok(Json(state.proxy_api_keys.list().await))
}

async fn create_key(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateKeyRequest>,
) -> Result<(StatusCode, Json<CreateKeyResponse>), (StatusCode, String)> {
    let name = req.name.trim().to_string();
    if name.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "Name is required".to_string()));
    }
    // These prefixes bind a key to a principal (a mission, Hermes) for usage
    // attribution; only Core mints them.
    if reserved_key_name(&name) {
        return Err((
            StatusCode::BAD_REQUEST,
            "This key name is reserved for keys Core creates".to_string(),
        ));
    }
    match state.proxy_api_keys.create(name).await {
        Ok(resp) => Ok((StatusCode::CREATED, Json(resp))),
        Err(e) => Err((StatusCode::INTERNAL_SERVER_ERROR, e)),
    }
}

fn reserved_key_name(name: &str) -> bool {
    use crate::api::usage_attribution::{HERMES_KEY_PREFIX, REMOTE_LAUNCH_KEY_PREFIX};
    name.starts_with(REMOTE_LAUNCH_KEY_PREFIX) || name.starts_with(HERMES_KEY_PREFIX)
}

async fn delete_key(
    State(state): State<Arc<AppState>>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, StatusCode> {
    match state.proxy_api_keys.delete(id).await {
        Ok(true) => Ok(StatusCode::NO_CONTENT),
        Ok(false) => Err(StatusCode::NOT_FOUND),
        Err(_) => Err(StatusCode::INTERNAL_SERVER_ERROR),
    }
}

/// Delete (or, with `dry_run`, list) keys that have seen no activity for
/// `max_age_days` days (default 7).
async fn cleanup_keys(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CleanupRequest>,
) -> Result<Json<CleanupResponse>, (StatusCode, String)> {
    let max_age_days = req.max_age_days.unwrap_or(7);
    if max_age_days == 0 {
        return Err((
            StatusCode::BAD_REQUEST,
            "max_age_days must be at least 1".to_string(),
        ));
    }
    let dry_run = req.dry_run.unwrap_or(false);
    let cutoff = chrono::Utc::now() - chrono::Duration::days(i64::from(max_age_days));
    match state.proxy_api_keys.cleanup_unused(cutoff, dry_run).await {
        Ok(keys) => Ok(Json(CleanupResponse {
            dry_run,
            cutoff,
            keys,
        })),
        Err(e) => Err((StatusCode::INTERNAL_SERVER_ERROR, e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn key(name: &str, created_days_ago: i64, used_days_ago: Option<i64>) -> ProxyApiKey {
        let now = chrono::Utc::now();
        ProxyApiKey {
            id: Uuid::new_v4(),
            name: name.to_string(),
            key_hash: hex_sha256(name),
            key_prefix: "sk-proxy-test0000".to_string(),
            created_at: now - chrono::Duration::days(created_days_ago),
            last_used_at: used_days_ago.map(|d| now - chrono::Duration::days(d)),
        }
    }

    async fn store_with(keys: Vec<ProxyApiKey>) -> (ProxyApiKeyStore, TempDir) {
        let tmp = TempDir::new().unwrap();
        let store = ProxyApiKeyStore::new(tmp.path().join("proxy_api_keys.json")).await;
        let entries = keys
            .into_iter()
            .map(|k| Arc::new(ProxyKeyEntry::from_record(k)))
            .collect();
        store.keys.store(Arc::new(entries));
        (store, tmp)
    }

    #[tokio::test]
    async fn cleanup_selects_by_last_activity_with_created_fallback() {
        let (store, _tmp) = store_with(vec![
            // Old but recently used — kept.
            key("old-active", 100, Some(1)),
            // Old and last used long ago — stale.
            key("old-stale", 100, Some(30)),
            // Never used, created long ago — stale via created_at fallback.
            key("old-never-used", 30, None),
            // Never used but recent — kept.
            key("fresh", 2, None),
        ])
        .await;
        let cutoff = chrono::Utc::now() - chrono::Duration::days(7);

        // Dry run reports candidates without deleting.
        let candidates = store.cleanup_unused(cutoff, true).await.unwrap();
        let names: Vec<_> = candidates.iter().map(|k| k.name.as_str()).collect();
        assert_eq!(names, vec!["old-stale", "old-never-used"]);
        assert_eq!(store.list().await.len(), 4);

        // Real run deletes them and persists.
        let deleted = store.cleanup_unused(cutoff, false).await.unwrap();
        assert_eq!(deleted.len(), 2);
        let remaining: Vec<_> = store.list().await.into_iter().map(|k| k.name).collect();
        assert_eq!(remaining, vec!["old-active", "fresh"]);
        let on_disk = store.load_from_disk().unwrap();
        assert_eq!(on_disk.len(), 2);
    }

    #[tokio::test]
    async fn verify_records_last_used() {
        let (store, _tmp) = store_with(vec![ProxyApiKey {
            id: Uuid::new_v4(),
            name: "k".to_string(),
            key_hash: hex_sha256("sk-proxy-raw"),
            key_prefix: "sk-proxy-raw00000".to_string(),
            created_at: chrono::Utc::now() - chrono::Duration::days(10),
            last_used_at: None,
        }])
        .await;

        assert!(!store.verify("wrong-token").await);
        assert!(store.list().await[0].last_used_at.is_none());

        assert!(store.verify("sk-proxy-raw").await);
        assert!(store.list().await[0].last_used_at.is_some());
        // The first touch persists to disk.
        assert!(store.load_from_disk().unwrap()[0].last_used_at.is_some());
    }

    #[tokio::test]
    async fn find_by_token_does_not_record_usage() {
        let (store, _tmp) = store_with(vec![ProxyApiKey {
            id: Uuid::new_v4(),
            name: "k".to_string(),
            key_hash: hex_sha256("sk-proxy-raw"),
            key_prefix: "sk-proxy-raw00000".to_string(),
            created_at: chrono::Utc::now(),
            last_used_at: None,
        }])
        .await;

        assert!(store.find_by_token("nope").await.is_none());
        let found = store.find_by_token("sk-proxy-raw").await.unwrap();
        assert_eq!(found.name, "k");
        assert!(store.list().await[0].last_used_at.is_none());
    }

    #[tokio::test]
    async fn delete_named_except_keeps_the_kept_key_and_other_names() {
        let keep = key("Hermes Assistant (prod)", 1, None);
        let keep_id = keep.id;
        let (store, _tmp) = store_with(vec![
            key("Hermes Assistant 2026-05-29T13:02:50+00:00", 6, None),
            key("Hermes Assistant 2026-05-30T08:15:23+00:00", 5, None),
            keep,
            // Different prefix — must survive.
            key("Hermes debug smoke", 6, None),
            key("Cursor", 90, None),
        ])
        .await;

        let deleted = store
            .delete_named_except("Hermes Assistant", Some(keep_id))
            .await
            .unwrap();
        assert_eq!(deleted.len(), 2);

        let remaining: Vec<_> = store.list().await.into_iter().map(|k| k.name).collect();
        assert_eq!(
            remaining,
            vec!["Hermes Assistant (prod)", "Hermes debug smoke", "Cursor"]
        );
        // Persisted.
        assert_eq!(store.load_from_disk().unwrap().len(), 3);
    }
}
