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

fn lock_pending(path: &Path) -> io::Result<PendingLock> {
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        fs::create_dir_all(parent)?;
    }
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path.with_extension("lock"))?;
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

pub fn record_pending_rotation(path: &Path, rot: PendingRotation) -> io::Result<()> {
    if rot.old_refresh_token == rot.new_refresh_token || rot.new_refresh_token.trim().is_empty() {
        return Ok(());
    }
    let _lock = lock_pending(path)?;
    let mut envelope = load_pending(path)?;
    let generation = envelope.next_generation.max(1);
    envelope.next_generation = generation.saturating_add(1);
    envelope.entries.retain(|entry| {
        entry.rotation.provider != rot.provider
            || entry.rotation.new_refresh_token != rot.new_refresh_token
    });
    envelope.entries.push(PendingEntry {
        generation,
        rotation_id: Uuid::new_v4(),
        rotation: rot,
    });
    write_pending(path, &envelope)
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
    let accounts: Vec<(Uuid, Option<String>)> = store
        .get_all_by_type(provider_type)
        .await
        .into_iter()
        .map(|a| (a.id, a.oauth.map(|o| o.refresh_token)))
        .collect();

    let id = match_account_by_old_token(&accounts, &rot.old_refresh_token)?;
    store
        .set_oauth_credentials(
            id,
            OAuthCredentials {
                access_token: rot.new_access_token.clone(),
                refresh_token: rot.new_refresh_token.clone(),
                expires_at: rot.expires_at,
            },
        )
        .await?;
    crate::api::ai_providers::oauth_refresh_clear_dead(id);
    tracing::info!(
        account_id = %id,
        provider = ?provider_type,
        new_expires_at = rot.expires_at,
        "Reconciled store record from out-of-band tier rotation"
    );
    Some(id)
}

fn snapshot_pending(path: &Path) -> io::Result<Vec<PendingEntry>> {
    let _lock = lock_pending(path)?;
    let mut envelope = load_pending(path)?;
    if envelope
        .entries
        .iter()
        .any(|entry| entry.rotation_id.is_nil() || entry.generation == 0)
    {
        let mut next = envelope.next_generation.max(1);
        for entry in &mut envelope.entries {
            if entry.generation == 0 {
                entry.generation = next;
                next = next.saturating_add(1);
            }
            if entry.rotation_id.is_nil() {
                entry.rotation_id = Uuid::new_v4();
            }
        }
        envelope.next_generation = envelope.next_generation.max(next);
        write_pending(path, &envelope)?;
    }
    Ok(envelope.entries)
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ApplyOutcome {
    Applied,
    StaleOrUnsupported,
}

async fn drain_pending_with<F, Fut>(path: &Path, mut apply: F) -> u32
where
    F: FnMut(PendingRotation) -> Fut,
    Fut: Future<Output = io::Result<ApplyOutcome>>,
{
    let snapshot = match snapshot_pending(path) {
        Ok(entries) => entries,
        Err(err) => {
            tracing::warn!(error = %err, "Failed to snapshot pending OAuth rotations");
            return 0;
        }
    };
    let mut applied_count = 0u32;
    let mut completed = Vec::with_capacity(snapshot.len());
    for entry in snapshot {
        match apply(entry.rotation).await {
            Ok(ApplyOutcome::Applied) => {
                applied_count += 1;
                completed.push((entry.generation, entry.rotation_id));
            }
            Ok(ApplyOutcome::StaleOrUnsupported) => {
                completed.push((entry.generation, entry.rotation_id));
            }
            Err(err) => {
                tracing::warn!(
                    generation = entry.generation,
                    rotation_id = %entry.rotation_id,
                    error = %err,
                    "Pending OAuth rotation retained for retry"
                );
            }
        }
    }
    if !completed.is_empty() {
        if let Err(err) = acknowledge_pending(path, &completed) {
            tracing::warn!(error = %err, "Failed to acknowledge pending OAuth rotations");
        }
    }
    applied_count
}

async fn apply_pending(
    store: &AIProviderStore,
    storage_path: &Path,
    rot: &PendingRotation,
) -> io::Result<ApplyOutcome> {
    if rot.provider != "anthropic" {
        return Ok(ApplyOutcome::StaleOrUnsupported);
    }
    let accounts = store.get_all_by_type(ProviderType::Anthropic).await;
    let Some(account) = accounts.iter().find(|account| {
        account.oauth.as_ref().is_some_and(|oauth| {
            oauth.refresh_token == rot.old_refresh_token
                || oauth.refresh_token == rot.new_refresh_token
        })
    }) else {
        return Ok(ApplyOutcome::StaleOrUnsupported);
    };
    fn has_persisted_creds(
        providers: &[crate::ai_providers::AIProvider],
        id: Uuid,
        rot: &PendingRotation,
    ) -> bool {
        providers.iter().any(|provider| {
            provider.id == id
                && provider.oauth.as_ref().is_some_and(|oauth| {
                    oauth.refresh_token == rot.new_refresh_token
                        && oauth.access_token == rot.new_access_token
                        && oauth.expires_at == rot.expires_at
                })
        })
    }

    let id = account.id;
    let already_persisted = tokio::fs::read(storage_path)
        .await
        .ok()
        .and_then(|bytes| {
            serde_json::from_slice::<Vec<crate::ai_providers::AIProvider>>(&bytes).ok()
        })
        .is_some_and(|persisted| has_persisted_creds(&persisted, id, rot));
    store
        .set_oauth_credentials(
            id,
            OAuthCredentials {
                access_token: rot.new_access_token.clone(),
                refresh_token: rot.new_refresh_token.clone(),
                expires_at: rot.expires_at,
            },
        )
        .await
        .ok_or_else(|| io::Error::other("OAuth account removed during reconciliation"))?;
    let bytes = tokio::fs::read(storage_path).await?;
    let persisted: Vec<crate::ai_providers::AIProvider> = serde_json::from_slice(&bytes)
        .map_err(|_| io::Error::other("Invalid persisted OAuth provider store"))?;
    if !has_persisted_creds(&persisted, id, rot) {
        return Err(io::Error::other("OAuth rotation not persisted"));
    }
    crate::api::ai_providers::oauth_refresh_clear_dead(id);
    if !already_persisted {
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
    let storage_path = parent_dir(path).join("ai_providers.json");
    drain_pending_with(path, |rot| {
        let storage_path = &storage_path;
        async move { apply_pending(store, storage_path, &rot).await }
    })
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
        let drain = drain_pending_with(&path, |rot| {
            let (started, release) = hook.take().unwrap();
            let store = &store;
            let storage_path = &storage_path;
            async move {
                started.send(()).unwrap();
                release.await.unwrap();
                apply_pending(store, storage_path, &rot).await
            }
        });
        let writer = async {
            started_rx.await.unwrap();
            record_pending_rotation(&path, rotation("gen1", "gen2")).unwrap();
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
    async fn legacy_single_and_array_apply_and_clean_up() {
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
            assert_eq!(drain_pending(&store, &path).await, 1);
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
    async fn persistence_failure_retries_even_after_memory_was_updated() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let storage_path = dir.path().join("ai_providers.json");
        let (store, id) = store_with_account(dir.path(), "old").await;
        record_pending_rotation(&path, rotation("old", "new")).unwrap();
        fs::remove_file(&storage_path).unwrap();
        fs::create_dir(&storage_path).unwrap();
        assert_eq!(drain_pending(&store, &path).await, 0);
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
