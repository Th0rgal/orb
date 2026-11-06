//! Reconcile rotated Anthropic OAuth tokens back into the `ai_providers.json`
//! store records — the missing half of the split-brain fix.
//!
//! Background: Anthropic rotates AND revokes the refresh token on every refresh,
//! so every persisted copy of a given account's token must move together. The
//! per-mission Claude Code harness refreshes the token inside its isolated HOME
//! and the runner syncs that back to the shared credential *tiers*
//! (`sync_oauth_to_all_tiers`) — but it never updates the multi-account
//! AIProviderStore *record*. The record then keeps a stale (already-rotated)
//! refresh token, and the proactive store-refresh pass tries to refresh it →
//! `invalid_grant` → Anthropic revokes the whole family → the freshly-rotated
//! tier token dies too. That's the recurring "account revoked" loop.
//!
//! The store is in-memory cached behind a single owner (the AppState
//! `AIProviderStore`), so a second instance can't safely write the file. This
//! module therefore splits the work:
//!   * the runner (which has no store handle) drops a small **pending-rotation
//!     sidecar** recording `old_refresh_token → new_*` (file-only);
//!   * the proactive loop (which owns the store) drains the sidecar and, in the
//!     same cycle, also propagates its own file-tier rotations — matching the
//!     account by its *old* refresh token (unambiguous at rotation time) and
//!     writing the rotated token into that record.
//!
//! Result: the store record always follows the tier, so the proactive pass
//! never refreshes a dead token, and the family is never revoked from under a
//! live mission.

use std::fs::{self, File, OpenOptions};
use std::future::Future;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ai_providers::{AIProviderStore, OAuthCredentials, ProviderType};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct PendingRotation {
    pub provider: String,
    pub old_refresh_token: String,
    pub new_refresh_token: String,
    pub new_access_token: String,
    pub expires_at: i64,
}

#[derive(Serialize, Deserialize)]
struct PendingEntry {
    #[serde(default)]
    generation: u64,
    #[serde(default)]
    rotation_id: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    expected_oauth_generation: Option<Uuid>,
    #[serde(flatten)]
    rotation: PendingRotation,
}

#[derive(Serialize, Deserialize, Default)]
struct PendingEnvelope {
    #[serde(default)]
    next_generation: u64,
    entries: Vec<PendingEntry>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum PendingFile {
    Envelope(PendingEnvelope),
    Entries(Vec<PendingEntry>),
    Legacy(PendingEntry),
}

pub fn sidecar_path(working_dir: &Path) -> PathBuf {
    working_dir
        .join(".sandboxed-sh")
        .join("anthropic_rotation_pending.json")
}

struct PendingLock(File);

impl Drop for PendingLock {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.0);
    }
}

fn lock_path(path: &Path) -> PathBuf {
    let mut os = path.as_os_str().to_os_string();
    os.push(".lock");
    PathBuf::from(os)
}

fn lock_pending(path: &Path) -> io::Result<PendingLock> {
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent)?;
    }
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(lock_path(path))?;
    fs2::FileExt::lock_exclusive(&file)?;
    Ok(PendingLock(file))
}

fn load_pending(path: &Path) -> io::Result<PendingEnvelope> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(PendingEnvelope::default()),
        Err(err) => return Err(err),
    };
    let mut envelope = match serde_json::from_slice(&bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "Invalid pending rotation file"))?
    {
        PendingFile::Envelope(env) => env,
        PendingFile::Entries(entries) => PendingEnvelope {
            next_generation: 0,
            entries,
        },
        PendingFile::Legacy(entry) => PendingEnvelope {
            next_generation: 0,
            entries: vec![entry],
        },
    };
    let max_generation = envelope
        .entries
        .iter()
        .map(|entry| entry.generation)
        .max()
        .unwrap_or(0);
    envelope.next_generation = envelope
        .next_generation
        .max(max_generation.saturating_add(1))
        .max(1);
    Ok(envelope)
}

fn parent_dir(path: &Path) -> &Path {
    path.parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
}

fn write_pending(path: &Path, envelope: &PendingEnvelope) -> io::Result<()> {
    let mut tmp = tempfile::NamedTempFile::new_in(parent_dir(path))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(tmp.path(), fs::Permissions::from_mode(0o600))?;
    }
    serde_json::to_writer_pretty(&mut tmp, envelope)
        .map_err(|_| io::Error::other("Failed to serialize pending rotations"))?;
    tmp.flush()?;
    tmp.as_file().sync_all()?;
    tmp.persist(path).map_err(|err| err.error)?;
    File::open(parent_dir(path))?.sync_all()
}

pub fn read_pending(path: &Path) -> Vec<PendingRotation> {
    let Ok(_lock) = lock_pending(path) else {
        return Vec::new();
    };
    load_pending(path)
        .unwrap_or_default()
        .entries
        .into_iter()
        .map(|entry| entry.rotation)
        .collect()
}

pub fn clear_pending(path: &Path) {
    if let Ok(_lock) = lock_pending(path) {
        let _ = fs::remove_file(path);
        if let Ok(dir) = File::open(parent_dir(path)) {
            let _ = dir.sync_all();
        }
    }
}

fn inferred_store_path(sidecar: &Path) -> PathBuf {
    let dir = parent_dir(sidecar);
    let candidate = dir.join("ai_providers.json");
    if candidate.exists() || dir.file_name().and_then(|name| name.to_str()) == Some(".sandboxed-sh")
    {
        candidate
    } else {
        dir.join(crate::util::AI_PROVIDERS_PATH)
    }
}

fn capture_expected_oauth_generation(sidecar: &Path, rot: &PendingRotation) -> Option<Uuid> {
    let provider_type = ProviderType::from_id(&rot.provider)?;
    AIProviderStore::oauth_generation_at_path(
        &inferred_store_path(sidecar),
        provider_type,
        &rot.old_refresh_token,
    )
}

pub async fn record_pending_rotation_with_generation_async(
    path: &Path,
    rot: PendingRotation,
    expected_oauth_generation: Option<Uuid>,
) -> io::Result<()> {
    if rot.old_refresh_token == rot.new_refresh_token || rot.new_refresh_token.trim().is_empty() {
        return Ok(());
    }
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        record_pending_rotation_with_generation(&path, rot, expected_oauth_generation)
    })
    .await
    .map_err(io::Error::other)?
}

fn record_pending_rotation_with_generation(
    path: &Path,
    rot: PendingRotation,
    expected_oauth_generation: Option<Uuid>,
) -> io::Result<()> {
    if rot.old_refresh_token == rot.new_refresh_token
        || rot.old_refresh_token.trim().is_empty()
        || rot.new_refresh_token.trim().is_empty()
    {
        return Ok(());
    }
    let _lock = lock_pending(path)?;
    let mut envelope = load_pending(path)?;
    let expected_oauth_generation = expected_oauth_generation
        .or_else(|| capture_expected_oauth_generation(path, &rot))
        .or_else(|| {
            envelope
                .entries
                .iter()
                .rev()
                .find(|entry| {
                    entry.rotation.provider == rot.provider
                        && entry.rotation.new_refresh_token == rot.old_refresh_token
                        && !entry.rotation_id.is_nil()
                        && entry.expected_oauth_generation.is_some()
                })
                .map(|entry| entry.rotation_id)
        });
    let generation = envelope.next_generation.max(1);
    envelope.next_generation = generation.saturating_add(1);
    envelope.entries.retain(|entry| {
        entry.rotation.provider != rot.provider
            || entry.rotation.new_refresh_token != rot.new_refresh_token
    });
    envelope.entries.push(PendingEntry {
        generation,
        rotation_id: Uuid::new_v4(),
        expected_oauth_generation,
        rotation: rot,
    });
    write_pending(path, &envelope)
}

pub fn record_pending_rotation(path: &Path, rot: PendingRotation) -> io::Result<()> {
    record_pending_rotation_with_generation(path, rot, None)
}

pub async fn record_pending_rotation_async(path: &Path, rot: PendingRotation) -> io::Result<()> {
    record_pending_rotation_with_generation_async(path, rot, None).await
}

pub fn match_account_by_old_token(accounts: &[(Uuid, Option<String>)], old: &str) -> Option<Uuid> {
    if old.trim().is_empty() {
        return None;
    }
    accounts
        .iter()
        .find(|(_, tok)| tok.as_deref() == Some(old))
        .map(|(id, _)| *id)
}

pub async fn apply_rotation(
    store: &AIProviderStore,
    provider_type: ProviderType,
    rot: &PendingRotation,
) -> Option<Uuid> {
    let accounts: Vec<(Uuid, Uuid, Option<String>)> = store
        .get_all_by_type(provider_type)
        .await
        .into_iter()
        .map(|a| (a.id, a.oauth_generation, a.oauth.map(|o| o.refresh_token)))
        .collect();

    if rot.old_refresh_token.trim().is_empty() {
        return None;
    }
    let (id, expected_generation, _) = accounts
        .into_iter()
        .find(|(_, _, tok)| tok.as_deref() == Some(rot.old_refresh_token.as_str()))?;
    match store
        .persist_oauth_credentials(
            id,
            &rot.old_refresh_token,
            Some(expected_generation),
            Uuid::new_v4(),
            OAuthCredentials {
                access_token: rot.new_access_token.clone(),
                refresh_token: rot.new_refresh_token.clone(),
                expires_at: rot.expires_at,
            },
        )
        .await
    {
        Ok(Some(applied)) => {
            crate::api::ai_providers::oauth_refresh_clear_dead(id);
            if applied {
                tracing::info!(
                    account_id = %id,
                    provider = ?provider_type,
                    new_expires_at = rot.expires_at,
                    "Reconciled store record from out-of-band tier rotation"
                );
            }
            Some(id)
        }
        Ok(None) => None,
        Err(err) => {
            tracing::warn!(
                account_id = %id,
                provider = ?provider_type,
                error = %err,
                "Failed to persist out-of-band tier rotation"
            );
            None
        }
    }
}

fn snapshot_pending(path: &Path) -> io::Result<Vec<PendingEntry>> {
    let _lock = lock_pending(path)?;
    let mut envelope = load_pending(path)?;
    let needs_upgrade = envelope.entries.iter().any(|entry| {
        entry.rotation_id.is_nil()
            || entry.generation == 0
            || entry.expected_oauth_generation.is_none()
    });
    if needs_upgrade {
        let mut next = envelope.next_generation.max(1);
        let mut changed = false;
        for entry in &mut envelope.entries {
            if entry.generation == 0 {
                entry.generation = next;
                next = next.saturating_add(1);
                changed = true;
            }
            if entry.rotation_id.is_nil() {
                entry.rotation_id = Uuid::new_v4();
                changed = true;
            }
        }
        envelope.next_generation = envelope.next_generation.max(next);
        if changed {
            write_pending(path, &envelope)?;
        }
    }
    Ok(envelope.entries)
}

async fn snapshot_pending_async(path: &Path) -> io::Result<Vec<PendingEntry>> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || snapshot_pending(&path))
        .await
        .map_err(io::Error::other)?
}

fn acknowledge_pending(path: &Path, completed: &[(u64, Uuid)]) -> io::Result<()> {
    let _lock = lock_pending(path)?;
    let mut envelope = load_pending(path)?;
    envelope.entries.retain(|entry| {
        !completed
            .iter()
            .any(|(gen, id)| entry.generation == *gen && entry.rotation_id == *id)
    });
    if envelope.entries.is_empty() {
        match fs::remove_file(path) {
            Ok(()) => File::open(parent_dir(path))?.sync_all(),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(err),
        }
    } else {
        write_pending(path, &envelope)
    }
}

async fn acknowledge_pending_async(path: &Path, completed: Vec<(u64, Uuid)>) -> io::Result<()> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || acknowledge_pending(&path, &completed))
        .await
        .map_err(io::Error::other)?
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ApplyOutcome {
    Applied,
    StaleOrUnsupported,
}

async fn drain_pending_with<F, Fut>(path: &Path, mut apply: F) -> u32
where
    F: FnMut(PendingEntry) -> Fut,
    Fut: Future<Output = io::Result<ApplyOutcome>>,
{
    let snapshot = match snapshot_pending_async(path).await {
        Ok(entries) => entries,
        Err(err) => {
            tracing::warn!(error = %err, "Failed to snapshot pending OAuth rotations");
            return 0;
        }
    };
    let mut applied_count = 0u32;
    let mut completed = Vec::with_capacity(snapshot.len());
    for entry in snapshot {
        let generation = entry.generation;
        let rotation_id = entry.rotation_id;
        match apply(entry).await {
            Ok(ApplyOutcome::Applied) => {
                applied_count += 1;
                completed.push((generation, rotation_id));
            }
            Ok(ApplyOutcome::StaleOrUnsupported) => {
                completed.push((generation, rotation_id));
            }
            Err(err) => {
                tracing::warn!(
                    generation,
                    rotation_id = %rotation_id,
                    error = %err,
                    "Pending OAuth rotation retained for retry"
                );
                break;
            }
        }
    }
    if !completed.is_empty() {
        if let Err(err) = acknowledge_pending_async(path, completed).await {
            tracing::warn!(error = %err, "Failed to acknowledge pending OAuth rotations");
        }
    }
    applied_count
}

async fn apply_pending(store: &AIProviderStore, entry: &PendingEntry) -> io::Result<ApplyOutcome> {
    let rot = &entry.rotation;
    if rot.provider != "anthropic"
        || rot.old_refresh_token.trim().is_empty()
        || rot.new_refresh_token.trim().is_empty()
    {
        return Ok(ApplyOutcome::StaleOrUnsupported);
    }
    let accounts = store.get_all_by_type(ProviderType::Anthropic).await;
    let id = accounts
        .iter()
        .find(|account| {
            !entry.rotation_id.is_nil() && account.oauth_rotation_id == Some(entry.rotation_id)
        })
        .map(|account| account.id)
        .or_else(|| {
            let token_pairs: Vec<(Uuid, Option<String>)> = accounts
                .iter()
                .map(|account| {
                    (
                        account.id,
                        account
                            .oauth
                            .as_ref()
                            .map(|oauth| oauth.refresh_token.clone()),
                    )
                })
                .collect();
            match_account_by_old_token(&token_pairs, &rot.old_refresh_token)
        });
    let Some(id) = id else {
        return Ok(ApplyOutcome::StaleOrUnsupported);
    };
    let expected_oauth_generation = entry.expected_oauth_generation;
    let outcome = store
        .persist_oauth_credentials(
            id,
            &rot.old_refresh_token,
            expected_oauth_generation,
            entry.rotation_id,
            OAuthCredentials {
                access_token: rot.new_access_token.clone(),
                refresh_token: rot.new_refresh_token.clone(),
                expires_at: rot.expires_at,
            },
        )
        .await?;
    let Some(applied) = outcome else {
        return Ok(ApplyOutcome::StaleOrUnsupported);
    };
    crate::api::ai_providers::oauth_refresh_clear_dead(id);
    if applied {
        tracing::info!(
            account_id = %id,
            provider = ?ProviderType::Anthropic,
            new_expires_at = rot.expires_at,
            "Reconciled store record from out-of-band tier rotation"
        );
        Ok(ApplyOutcome::Applied)
    } else {
        Ok(ApplyOutcome::StaleOrUnsupported)
    }
}

pub async fn drain_pending(store: &AIProviderStore, path: &Path) -> u32 {
    drain_pending_with(
        path,
        |entry| async move { apply_pending(store, &entry).await },
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rotation(old: &str, new: &str) -> PendingRotation {
        PendingRotation {
            provider: "anthropic".into(),
            old_refresh_token: old.into(),
            new_refresh_token: new.into(),
            new_access_token: format!("access-{new}"),
            expires_at: 999,
        }
    }

    async fn store_with_account(dir: &Path, token: &str) -> (AIProviderStore, Uuid) {
        let store = AIProviderStore::new(dir.join("ai_providers.json")).await;
        let mut account =
            crate::ai_providers::AIProvider::new(ProviderType::Anthropic, "Account".into());
        account.oauth = Some(OAuthCredentials {
            access_token: "old-access".into(),
            refresh_token: token.into(),
            expires_at: 1,
        });
        let id = store.add(account).await;
        (store, id)
    }

    #[test]
    fn match_by_old_token_finds_owner() {
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let accounts = vec![(a, None), (b, Some("token".into()))];
        assert_eq!(match_account_by_old_token(&accounts, "token"), Some(b));
        assert_eq!(match_account_by_old_token(&accounts, "missing"), None);
        assert_eq!(match_account_by_old_token(&accounts, ""), None);
    }

    #[test]
    fn sidecar_roundtrip_dedup_and_noop() {
        let dir = tempfile::tempdir().unwrap();
        let path = sidecar_path(dir.path());
        record_pending_rotation(&path, rotation("same", "same")).unwrap();
        assert!(!path.exists());
        record_pending_rotation(&path, rotation("old1", "new1")).unwrap();
        record_pending_rotation(&path, rotation("old2", "new2")).unwrap();
        let first_id = snapshot_pending(&path).unwrap()[0].rotation_id;
        record_pending_rotation(&path, rotation("old1b", "new1")).unwrap();
        let entries = snapshot_pending(&path).unwrap();
        assert_eq!(entries.len(), 2);
        assert!(entries.iter().all(|entry| entry.rotation_id != first_id));
        assert_eq!(entries[0].generation, 2);
        assert_eq!(entries[1].generation, 3);
        assert_eq!(entries[1].rotation.old_refresh_token, "old1b");
    }

    #[tokio::test]
    async fn concurrent_rotation_survives_inflight_drain() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let (store, id) = store_with_account(dir.path(), "old").await;
        record_pending_rotation(&path, rotation("old", "gen1")).unwrap();
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = tokio::sync::oneshot::channel();
        let mut hook = Some((started_tx, release_rx));
        let storage_path = dir.path().join("ai_providers.json");
        let drain = drain_pending_with(&path, |entry| {
            let (started, release) = hook.take().unwrap();
            let store = &store;
            async move {
                started.send(()).unwrap();
                release.await.unwrap();
                apply_pending(store, &entry).await
            }
        });
        let writer = async {
            started_rx.await.unwrap();
            record_pending_rotation_async(&path, rotation("gen1", "gen2"))
                .await
                .unwrap();
            release_tx.send(()).unwrap();
        };
        let (applied, ()) = tokio::join!(drain, writer);
        assert_eq!(applied, 1);
        assert_eq!(read_pending(&path), vec![rotation("gen1", "gen2")]);
        assert_eq!(drain_pending(&store, &path).await, 1);
        assert!(!path.exists());
        let reloaded = AIProviderStore::new(storage_path).await;
        assert_eq!(
            reloaded.get(id).await.unwrap().oauth.unwrap().refresh_token,
            "gen2"
        );
    }

    #[tokio::test]
    async fn rerecorded_rotation_is_not_acknowledged_by_old_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let rot = rotation("old", "new");
        record_pending_rotation(&path, rot.clone()).unwrap();
        let snapshot = snapshot_pending(&path).unwrap();
        record_pending_rotation(&path, rot.clone()).unwrap();
        acknowledge_pending(&path, &[(snapshot[0].generation, snapshot[0].rotation_id)]).unwrap();
        assert_eq!(read_pending(&path), vec![rot]);
    }

    #[tokio::test]
    async fn unfenced_legacy_single_and_array_are_discarded_without_mutation() {
        for array in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("pending.json");
            let (store, _) = store_with_account(dir.path(), "old").await;
            let rot = rotation("old", "new");
            let json = if array {
                serde_json::to_vec(&vec![rot]).unwrap()
            } else {
                serde_json::to_vec(&rot).unwrap()
            };
            fs::write(&path, json).unwrap();
            assert_eq!(drain_pending(&store, &path).await, 0);
            assert_eq!(
                store.list().await[0].oauth.as_ref().unwrap().refresh_token,
                "old"
            );
            assert!(!path.exists());
        }
    }

    #[tokio::test]
    async fn transient_apply_error_retains_entry_for_retry() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let (store, _) = store_with_account(dir.path(), "old").await;
        let rot = rotation("old", "new");
        record_pending_rotation(&path, rot.clone()).unwrap();
        assert_eq!(
            drain_pending_with(&path, |_| async { Err(io::Error::other("injected error")) }).await,
            0
        );
        assert_eq!(read_pending(&path), vec![rot]);
        assert_eq!(drain_pending(&store, &path).await, 1);
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn persistence_failure_keeps_memory_consistent_and_retries_cleanly() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let storage_path = dir.path().join("ai_providers.json");
        let (store, id) = store_with_account(dir.path(), "old").await;
        record_pending_rotation_async(&path, rotation("old", "new"))
            .await
            .unwrap();
        fs::remove_file(&storage_path).unwrap();
        fs::create_dir(&storage_path).unwrap();
        assert_eq!(drain_pending(&store, &path).await, 0);
        assert_eq!(
            store.get(id).await.unwrap().oauth.unwrap().refresh_token,
            "old"
        );
        assert_eq!(read_pending(&path).len(), 1);
        fs::remove_dir(&storage_path).unwrap();
        assert_eq!(drain_pending(&store, &path).await, 1);
        assert!(!path.exists());
        let reloaded = AIProviderStore::new(storage_path).await;
        assert_eq!(
            reloaded.get(id).await.unwrap().oauth.unwrap().refresh_token,
            "new"
        );
    }

    #[tokio::test]
    async fn chained_rotations_survive_persistence_failure_and_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let storage_path = dir.path().join("ai_providers.json");
        let backup_path = dir.path().join("ai_providers.backup");
        let (store, id) = store_with_account(dir.path(), "A").await;
        for (old, new) in [("A", "B"), ("B", "C")] {
            let expected = AIProviderStore::oauth_generation_at_path(
                &storage_path,
                ProviderType::Anthropic,
                old,
            );
            assert_eq!(expected.is_some(), old == "A");
            record_pending_rotation_with_generation_async(&path, rotation(old, new), expected)
                .await
                .unwrap();
        }
        let entries = snapshot_pending(&path).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(
            entries[1].expected_oauth_generation,
            Some(entries[0].rotation_id)
        );
        fs::rename(&storage_path, &backup_path).unwrap();
        fs::create_dir(&storage_path).unwrap();
        assert_eq!(drain_pending(&store, &path).await, 0);
        assert_eq!(
            read_pending(&path),
            vec![rotation("A", "B"), rotation("B", "C")]
        );
        assert_eq!(
            store.get(id).await.unwrap().oauth.unwrap().refresh_token,
            "A"
        );
        fs::remove_dir(&storage_path).unwrap();
        fs::rename(&backup_path, &storage_path).unwrap();
        let restarted = AIProviderStore::new(storage_path.clone()).await;
        assert_eq!(drain_pending(&restarted, &path).await, 2);
        assert!(!path.exists());
        let reloaded = AIProviderStore::new(storage_path).await;
        let saved = reloaded.get(id).await.unwrap();
        assert_eq!(saved.oauth_generation, entries[1].rotation_id);
        assert_eq!(saved.oauth_rotation_id, Some(entries[1].rotation_id));
        assert_eq!(saved.oauth.unwrap().refresh_token, "C");
    }

    #[tokio::test]
    async fn persistence_failure_acknowledges_only_successful_prefix() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let storage_path = dir.path().join("ai_providers.json");
        let backup_path = dir.path().join("ai_providers.backup");
        let (store, id) = store_with_account(dir.path(), "A").await;
        for (old, new) in [("A", "B"), ("B", "C"), ("C", "D")] {
            record_pending_rotation_async(&path, rotation(old, new))
                .await
                .unwrap();
        }
        let mut calls = 0;
        let applied = drain_pending_with(&path, |entry| {
            calls += 1;
            let fail = calls == 2;
            let store = &store;
            let storage_path = &storage_path;
            let backup_path = &backup_path;
            async move {
                if fail {
                    fs::rename(storage_path, backup_path).unwrap();
                    fs::create_dir(storage_path).unwrap();
                }
                apply_pending(store, &entry).await
            }
        })
        .await;
        assert_eq!(applied, 1);
        assert_eq!(calls, 2);
        assert_eq!(
            read_pending(&path),
            vec![rotation("B", "C"), rotation("C", "D")]
        );
        assert_eq!(
            store.get(id).await.unwrap().oauth.unwrap().refresh_token,
            "B"
        );
        fs::remove_dir(&storage_path).unwrap();
        fs::rename(&backup_path, &storage_path).unwrap();
        let restarted = AIProviderStore::new(storage_path.clone()).await;
        assert_eq!(drain_pending(&restarted, &path).await, 2);
        assert!(!path.exists());
        let reloaded = AIProviderStore::new(storage_path).await;
        assert_eq!(
            reloaded.get(id).await.unwrap().oauth.unwrap().refresh_token,
            "D"
        );
    }

    #[tokio::test]
    async fn chained_recovery_updates_only_exact_owner_without_account_inference() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let storage_path = dir.path().join("ai_providers.json");
        let (store, owner) = store_with_account(dir.path(), "A").await;
        let mut other =
            crate::ai_providers::AIProvider::new(ProviderType::Anthropic, "Other".into());
        other.oauth = Some(OAuthCredentials {
            access_token: "other-access".into(),
            refresh_token: "other-refresh".into(),
            expires_at: 123,
        });
        let other_id = store.add(other).await;
        let unchanged = store.get(other_id).await.unwrap();
        for (old, new) in [("A", "B"), ("B", "C"), ("unknown", "unowned")] {
            record_pending_rotation_async(&path, rotation(old, new))
                .await
                .unwrap();
        }
        fs::remove_file(&storage_path).unwrap();
        fs::create_dir(&storage_path).unwrap();
        assert_eq!(drain_pending(&store, &path).await, 0);
        assert_eq!(read_pending(&path).len(), 3);
        fs::remove_dir(&storage_path).unwrap();
        assert_eq!(drain_pending(&store, &path).await, 2);
        assert!(!path.exists());
        let reloaded = AIProviderStore::new(storage_path).await;
        assert_eq!(
            reloaded
                .get(owner)
                .await
                .unwrap()
                .oauth
                .unwrap()
                .refresh_token,
            "C"
        );
        let saved_other = reloaded.get(other_id).await.unwrap();
        assert_eq!(saved_other.oauth, unchanged.oauth);
        assert_eq!(saved_other.oauth_generation, unchanged.oauth_generation);
        assert_eq!(saved_other.oauth_rotation_id, unchanged.oauth_rotation_id);
    }

    #[tokio::test]
    async fn same_refresh_token_interactive_update_invalidates_stale_pending_replay() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let storage_path = dir.path().join("ai_providers.json");
        let (store, id) = store_with_account(dir.path(), "old").await;

        record_pending_rotation_async(&path, rotation("old", "new"))
            .await
            .unwrap();

        store
            .set_oauth_credentials(
                id,
                OAuthCredentials {
                    access_token: "fresh-access-b".into(),
                    refresh_token: "old".into(),
                    expires_at: 2_000,
                },
            )
            .await
            .unwrap();

        assert_eq!(drain_pending(&store, &path).await, 0);
        assert!(!path.exists());
        let saved = AIProviderStore::new(storage_path.clone())
            .await
            .get(id)
            .await
            .unwrap()
            .oauth
            .unwrap();
        assert_eq!(saved.refresh_token, "old");
        assert_eq!(saved.access_token, "fresh-access-b");
        assert_eq!(saved.expires_at, 2_000);

        record_pending_rotation_async(&path, rotation("old", "new"))
            .await
            .unwrap();
        let mut updated = store.get(id).await.unwrap();
        updated.oauth = Some(OAuthCredentials {
            access_token: "newer-access-c".into(),
            refresh_token: "new".into(),
            expires_at: 3_000,
        });
        store.update(id, updated).await.unwrap();

        assert_eq!(drain_pending(&store, &path).await, 0);
        assert!(!path.exists());
        let saved = AIProviderStore::new(storage_path)
            .await
            .get(id)
            .await
            .unwrap()
            .oauth
            .unwrap();
        assert_eq!(saved.refresh_token, "new");
        assert_eq!(saved.access_token, "newer-access-c");
        assert_eq!(saved.expires_at, 3_000);
    }

    #[tokio::test]
    async fn duplicate_idempotent_replay_acknowledges_without_reapplying_or_overwriting_newer_update(
    ) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let storage_path = dir.path().join("ai_providers.json");
        let (store, id) = store_with_account(dir.path(), "old").await;

        record_pending_rotation_async(&path, rotation("old", "new"))
            .await
            .unwrap();
        let sidecar_bytes = fs::read(&path).unwrap();

        assert_eq!(drain_pending(&store, &path).await, 1);
        let gen_after_first = store.get(id).await.unwrap().oauth_generation;

        fs::write(&path, &sidecar_bytes).unwrap();
        assert_eq!(drain_pending(&store, &path).await, 0);
        assert!(!path.exists());
        assert_eq!(
            store.get(id).await.unwrap().oauth_generation,
            gen_after_first
        );

        store
            .set_oauth_credentials(
                id,
                OAuthCredentials {
                    access_token: "access-b".into(),
                    refresh_token: "new".into(),
                    expires_at: 5_000,
                },
            )
            .await
            .unwrap();
        fs::write(&path, &sidecar_bytes).unwrap();
        assert_eq!(drain_pending(&store, &path).await, 0);
        assert!(!path.exists());

        let reloaded = AIProviderStore::new(storage_path).await;
        let saved = reloaded.get(id).await.unwrap().oauth.unwrap();
        assert_eq!(saved.refresh_token, "new");
        assert_eq!(saved.access_token, "access-b");
        assert_eq!(saved.expires_at, 5_000);
    }

    #[tokio::test]
    async fn unacknowledged_replay_repairs_only_unpersisted_matching_rotation_and_recovers_after_restart(
    ) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let storage_path = dir.path().join("ai_providers.json");
        let (store, id) = store_with_account(dir.path(), "old").await;

        record_pending_rotation_async(&path, rotation("old", "new"))
            .await
            .unwrap();
        let sidecar_bytes = fs::read(&path).unwrap();

        assert_eq!(drain_pending(&store, &path).await, 1);
        let applied_generation = store.get(id).await.unwrap().oauth_generation;

        fs::remove_file(&storage_path).unwrap();
        fs::write(&path, &sidecar_bytes).unwrap();
        assert_eq!(drain_pending(&store, &path).await, 1);
        assert!(!path.exists());
        assert_eq!(
            store.get(id).await.unwrap().oauth_generation,
            applied_generation
        );

        let restarted = AIProviderStore::new(storage_path.clone()).await;
        fs::write(&path, &sidecar_bytes).unwrap();
        assert_eq!(drain_pending(&restarted, &path).await, 0);
        assert!(!path.exists());
        let saved = restarted.get(id).await.unwrap().oauth.unwrap();
        assert_eq!(saved.refresh_token, "new");
        assert_eq!(saved.access_token, "access-new");
        assert_eq!(saved.expires_at, 999);

        restarted
            .set_oauth_credentials(
                id,
                OAuthCredentials {
                    access_token: "post-restart-access".into(),
                    refresh_token: "new".into(),
                    expires_at: 7_777,
                },
            )
            .await
            .unwrap();
        let restarted_again = AIProviderStore::new(storage_path).await;
        fs::write(&path, &sidecar_bytes).unwrap();
        assert_eq!(drain_pending(&restarted_again, &path).await, 0);
        assert!(!path.exists());
        let saved = restarted_again.get(id).await.unwrap().oauth.unwrap();
        assert_eq!(saved.access_token, "post-restart-access");
        assert_eq!(saved.expires_at, 7_777);
    }

    #[tokio::test]
    async fn concurrent_interactive_mutation_during_drain_fences_stale_rotation() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let storage_path = dir.path().join("ai_providers.json");
        let (store, id) = store_with_account(dir.path(), "old").await;

        record_pending_rotation_async(&path, rotation("old", "new"))
            .await
            .unwrap();

        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = tokio::sync::oneshot::channel();
        let mut hook = Some((started_tx, release_rx));
        let drain = drain_pending_with(&path, |entry| {
            let (started, release) = hook.take().unwrap();
            let store = &store;
            async move {
                started.send(()).unwrap();
                release.await.unwrap();
                apply_pending(store, &entry).await
            }
        });
        let interactive = async {
            started_rx.await.unwrap();
            store
                .set_oauth_credentials(
                    id,
                    OAuthCredentials {
                        access_token: "interactive-access".into(),
                        refresh_token: "old".into(),
                        expires_at: 8_888,
                    },
                )
                .await
                .unwrap();
            release_tx.send(()).unwrap();
        };
        let (applied, ()) = tokio::join!(drain, interactive);
        assert_eq!(applied, 0);
        assert!(!path.exists());
        let saved = AIProviderStore::new(storage_path)
            .await
            .get(id)
            .await
            .unwrap()
            .oauth
            .unwrap();
        assert_eq!(saved.refresh_token, "old");
        assert_eq!(saved.access_token, "interactive-access");
        assert_eq!(saved.expires_at, 8_888);
    }

    #[tokio::test]
    async fn empty_old_refresh_token_never_matches_or_mutates_blank_account() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let (store, id) = store_with_account(dir.path(), "").await;
        let legacy = PendingRotation {
            provider: "anthropic".into(),
            old_refresh_token: String::new(),
            new_refresh_token: "new".into(),
            new_access_token: "access-new".into(),
            expires_at: 999,
        };
        fs::write(&path, serde_json::to_vec(&legacy).unwrap()).unwrap();
        assert_eq!(drain_pending(&store, &path).await, 0);
        assert!(!path.exists());
        assert_eq!(
            store.get(id).await.unwrap().oauth.unwrap().access_token,
            "old-access"
        );
    }

    #[tokio::test]
    async fn store_fence_rechecks_generation_after_account_selection() {
        let dir = tempfile::tempdir().unwrap();
        let (store, id) = store_with_account(dir.path(), "old").await;
        let selected = store.get(id).await.unwrap();
        let first_entry = PendingEntry {
            generation: 1,
            rotation_id: Uuid::new_v4(),
            expected_oauth_generation: Some(selected.oauth_generation),
            rotation: rotation("old", "new"),
        };
        assert_eq!(
            apply_pending(&store, &first_entry).await.unwrap(),
            ApplyOutcome::Applied
        );
        let after_first = store.get(id).await.unwrap();
        let second_entry = PendingEntry {
            generation: 2,
            rotation_id: Uuid::new_v4(),
            expected_oauth_generation: Some(after_first.oauth_generation),
            rotation: rotation("new", "newer"),
        };
        assert_eq!(
            apply_pending(&store, &second_entry).await.unwrap(),
            ApplyOutcome::Applied
        );
        assert_eq!(
            store
                .persist_oauth_credentials(
                    selected.id,
                    "old",
                    Some(selected.oauth_generation),
                    Uuid::new_v4(),
                    OAuthCredentials {
                        refresh_token: "new".into(),
                        access_token: "access-new".into(),
                        expires_at: 999,
                    }
                )
                .await
                .unwrap(),
            None
        );
        let reloaded = AIProviderStore::new(dir.path().join("ai_providers.json")).await;
        assert_eq!(
            reloaded.get(id).await.unwrap().oauth.unwrap().refresh_token,
            "newer"
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn contended_sidecar_operations_leave_tokio_worker_responsive() {
        for operation in 0..3 {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("pending.json");
            record_pending_rotation(&path, rotation("old", "new")).unwrap();
            let snapshot = snapshot_pending(&path).unwrap();
            let completed = vec![(snapshot[0].generation, snapshot[0].rotation_id)];
            let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
            let (release_tx, release_rx) = std::sync::mpsc::channel();
            let lock_path = path.clone();
            let holder = std::thread::spawn(move || {
                let _lock = lock_pending(&lock_path).unwrap();
                ready_tx.send(()).unwrap();
                release_rx
                    .recv_timeout(std::time::Duration::from_secs(2))
                    .is_ok()
            });
            ready_rx.await.unwrap();
            let work = async {
                match operation {
                    0 => {
                        snapshot_pending_async(&path).await.unwrap();
                    }
                    1 => {
                        acknowledge_pending_async(&path, completed).await.unwrap();
                    }
                    _ => {
                        record_pending_rotation_async(&path, rotation("new", "newer"))
                            .await
                            .unwrap();
                    }
                }
            };
            let heartbeat = async {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                release_tx.send(()).unwrap();
            };
            tokio::join!(work, heartbeat);
            assert!(holder.join().unwrap());
        }
    }

    #[tokio::test]
    async fn async_sidecar_operations_propagate_io_errors() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        fs::write(&path, b"invalid").unwrap();
        assert_eq!(
            snapshot_pending_async(&path).await.err().unwrap().kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(
            acknowledge_pending_async(&path, vec![(1, Uuid::new_v4())])
                .await
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert!(record_pending_rotation_async(&path, rotation("old", "new"))
            .await
            .is_err());
        assert_eq!(fs::read(&path).unwrap(), b"invalid");
    }

    #[test]
    fn lock_path_appends_suffix_without_stem_collision() {
        let dir = tempfile::tempdir().unwrap();
        let json_path = dir.path().join("foo.json");
        let toml_path = dir.path().join("foo.toml");
        assert_eq!(lock_path(&json_path), dir.path().join("foo.json.lock"));
        assert_eq!(lock_path(&toml_path), dir.path().join("foo.toml.lock"));
        assert_ne!(lock_path(&json_path), lock_path(&toml_path));
        let _json_lock = lock_pending(&json_path).unwrap();
        let other_lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(lock_path(&toml_path))
            .unwrap();
        fs2::FileExt::try_lock_exclusive(&other_lock).unwrap();
    }

    #[test]
    fn concurrent_writers_preserve_distinct_accounts() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let barrier = std::sync::Barrier::new(8);
        std::thread::scope(|scope| {
            for n in 0..8 {
                let path = &path;
                let barrier = &barrier;
                scope.spawn(move || {
                    barrier.wait();
                    record_pending_rotation(
                        path,
                        rotation(&format!("old-{n}"), &format!("new-{n}")),
                    )
                    .unwrap();
                });
            }
        });
        assert_eq!(read_pending(&path).len(), 8);
    }

    #[test]
    fn malformed_queue_is_not_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        fs::write(&path, b"invalid").unwrap();
        assert!(record_pending_rotation(&path, rotation("old", "new")).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"invalid");
    }

    #[tokio::test]
    async fn stale_rotation_is_skipped_and_cleans_up_sidecar() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let (store, id) = store_with_account(dir.path(), "current").await;
        record_pending_rotation(&path, rotation("stale-old", "stale-new")).unwrap();
        assert_eq!(drain_pending(&store, &path).await, 0);
        assert!(!path.exists());
        assert_eq!(
            store.get(id).await.unwrap().oauth.unwrap().refresh_token,
            "current"
        );
    }
}
