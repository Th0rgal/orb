//! Durable ledger of in-flight async remote jobs.
//!
//! `dispatch_remote_job` records a handle after the node accepts a job and
//! removes it once the poll loop finalizes the mission. If the API process
//! restarts in between, the startup reconciler reads this file and either
//! re-attaches a poll loop to the still-Active mission or converges its
//! state — without it, the only copy of (node_id, job_id) died with the
//! in-memory task and the mission stayed Active forever.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock};

use arc_swap::ArcSwap;
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

use super::ArtifactEntry;

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobHandleKind {
    /// A raw remote mission whose terminal result finalizes the mission.
    #[default]
    Mission,
    /// A waited `/api/remote-build` request. Recovery only observes the node
    /// job and cleans up its handle; it must not finalize the agent mission.
    RemoteBuild,
    /// A submit request failed ambiguously after the node may have accepted
    /// the generated job id. Recovery must cancel/poll this handle, but must
    /// never finalize the owning mission from its result.
    Tentative,
}

/// Immutable identity of a remote validation. This deliberately stores a
/// credential-free repository identifier so the durable ledger can prove
/// exactly what was validated without persisting clone credentials.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemoteJobIdentity {
    /// Identity schema version. `0` = legacy (commit-keyed, no tree); such
    /// receipts are never replayed as success for a newer identity.
    #[serde(default)]
    pub version: u32,
    pub repository: String,
    pub commit: String,
    /// Root tree of `commit`. When present it, not the commit, is the content
    /// identity: the same tree under a different commit message is the same
    /// build.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_tree_sha: Option<String>,
    /// `false` means this identity predates cwd persistence. Such receipts are
    /// intentionally not equal to new root-cwd requests because their actual
    /// execution directory is unknowable after upgrade.
    #[serde(default)]
    pub cwd_rel_known: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd_rel: Option<String>,
    pub command: Vec<String>,
    /// Requested artifact digests are part of execution identity. Terminal
    /// receipt reuse is disabled when this is non-empty until receipts retain
    /// the resulting artifact entries as well.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub artifacts: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub toolchain: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_bundle_digest: Option<String>,
    /// Builder image / toolchain container digest, when the node runs one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub builder_image_digest: Option<String>,
    /// Wire/build protocol revision of the submitting wrapper.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub build_protocol_version: Option<String>,
    /// Digest of the allowlisted, behaviour-affecting, non-secret environment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub behavior_env_digest: Option<String>,
}

/// Current identity schema version written by core.
pub const IDENTITY_VERSION: u32 = 1;

impl RemoteJobIdentity {
    fn identity_digest_bytes(&self) -> [u8; 32] {
        use sha2::Digest;
        let mut artifacts = self.artifacts.clone();
        artifacts.sort();
        artifacts.dedup();
        let content = match self.base_tree_sha.as_deref().map(str::trim) {
            Some(tree) if !tree.is_empty() => format!("tree:{}", tree.to_ascii_lowercase()),
            _ => format!("commit:{}", self.commit.to_ascii_lowercase()),
        };
        let canonical = serde_json::json!({
            "v": self.version,
            "repository": self.repository,
            "content": content,
            "cwd_rel": self.cwd_rel,
            "cwd_rel_known": self.cwd_rel_known,
            "argv": self.command,
            "artifacts": artifacts,
            "toolchain": self.toolchain,
            "bundle": self.source_bundle_digest,
            "image": self.builder_image_digest,
            "protocol": self.build_protocol_version,
            "env": self.behavior_env_digest,
        });
        let mut hasher = sha2::Sha256::new();
        hasher.update(b"sandboxed-remote-job-identity\0");
        hasher.update(canonical.to_string().as_bytes());
        hasher.finalize().into()
    }

    fn identity_words(&self) -> [u64; 4] {
        let raw = self.identity_digest_bytes();
        [
            u64::from_le_bytes(raw[0..8].try_into().unwrap()),
            u64::from_le_bytes(raw[8..16].try_into().unwrap()),
            u64::from_le_bytes(raw[16..24].try_into().unwrap()),
            u64::from_le_bytes(raw[24..32].try_into().unwrap()),
        ]
    }

    /// Canonical, byte-stable hash of the identity. `base_tree_sha` replaces
    /// the commit when present; artifacts are sorted and de-duplicated; the
    /// version is part of the hash so a schema change can never alias.
    pub fn identity_hash(&self) -> String {
        hex::encode(self.identity_digest_bytes())
    }

    /// Same build for exclusion purposes. Two identities of the same version
    /// compare by hash. A legacy (v0) identity on either side falls back to
    /// the legacy field equality so an in-flight pre-upgrade job still
    /// blocks a duplicate — conservatively, never the other way round.
    pub fn excludes(&self, other: &RemoteJobIdentity) -> bool {
        if self.version == other.version {
            return crate::orb_spec::job_identity_eq256_step(
                self.identity_words(),
                other.identity_words(),
                true,
                false,
            ) == crate::orb_spec::JobIdentityVerdict::JoinActiveExecution;
        }
        self.repository == other.repository
            && self.commit.eq_ignore_ascii_case(&other.commit)
            && self.cwd_rel == other.cwd_rel
            && self.command == other.command
            && self.artifacts == other.artifacts
            && self.toolchain == other.toolchain
            && self.source_bundle_digest == other.source_bundle_digest
    }

    /// Whether a successful receipt with this identity may be replayed for a
    /// request with `other`: same version (never v0) and same hash.
    pub fn reusable_for(&self, other: &RemoteJobIdentity) -> bool {
        self.version >= 1
            && self.version == other.version
            && crate::orb_spec::job_identity_eq256_step(
                self.identity_words(),
                other.identity_words(),
                false,
                true,
            ) == crate::orb_spec::JobIdentityVerdict::ReplayTerminalReceipt
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobHandle {
    pub mission_id: Uuid,
    pub node_id: String,
    pub job_id: Uuid,
    pub started_at: chrono::DateTime<chrono::Utc>,
    /// Durable monotonic submission order assigned by the core ledger. This
    /// is authoritative when wall-clock timestamps collide. Legacy handles
    /// deserialize as zero and are treated conservatively when ambiguous.
    #[serde(default)]
    pub submission_sequence: u64,
    /// When the node acceptance response was observed. Tentative and legacy
    /// handles keep this empty and must remain conservatively reserved.
    #[serde(default)]
    pub accepted_at: Option<chrono::DateTime<chrono::Utc>>,
    /// Last successful observation of the durable node job. A stale value
    /// means reconciliation is needed; it does not authorize resubmission.
    #[serde(default)]
    pub heartbeat_at: Option<chrono::DateTime<chrono::Utc>>,
    /// Scratch capacity reserved for this job until it reaches terminal state.
    /// Older ledgers deserialize this as zero.
    #[serde(default)]
    pub disk_reservation_bytes: u64,
    #[serde(default)]
    pub kind: JobHandleKind,
    /// Present for immutable remote build/validation jobs. Legacy and raw
    /// command handles deserialize with no identity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<RemoteJobIdentity>,
    /// Whether the build owns a mission continuation. This is independent of
    /// the HTTP response mode: the bundled wrapper requests a job id
    /// asynchronously but keeps polling inside the harness tool. `None`
    /// denotes a legacy ledger entry; recovery treats it conservatively so an
    /// upgrade cannot discard an in-flight continuation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wait_for_completion: Option<bool>,
    /// The submitting harness no longer waits on the HTTP response, so the
    /// terminal receipt must wake the owning mission. Recovered remote builds
    /// are promoted to this mode because a restart severed any synchronous
    /// waiter that may have existed.
    #[serde(default)]
    pub wake_on_terminal: bool,
}

impl JobHandle {
    /// Request-level continuation intent, also available while a submission
    /// is still tentative and its node acceptance is ambiguous.
    pub fn continuation_requested(&self) -> bool {
        self.wake_on_terminal || self.wait_for_completion != Some(false)
    }

    /// True when this remote build owns a mission continuation. Newly written
    /// fire-and-forget handles carry `Some(false)` and are excluded. Legacy
    /// remote-build handles remain recoverable because their request mode was
    /// not recorded.
    pub fn expects_mission_continuation(&self) -> bool {
        self.kind == JobHandleKind::RemoteBuild && self.continuation_requested()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemoteJobReceipt {
    pub mission_id: Uuid,
    pub node_id: String,
    pub job_id: Uuid,
    pub started_at: chrono::DateTime<chrono::Utc>,
    #[serde(default)]
    pub submission_sequence: u64,
    pub finished_at: chrono::DateTime<chrono::Utc>,
    pub state: String,
    #[serde(default)]
    pub exit_status: Option<i32>,
    pub identity: RemoteJobIdentity,
    /// Content digests produced by the exact terminal execution. Older
    /// receipts deserialize empty and are not reused for artifact-bearing
    /// validations.
    #[serde(default)]
    pub artifacts: Vec<ArtifactEntry>,
    /// The accepted request owned a mission continuation even if its terminal
    /// wake had not yet been armed. This lets startup recover the narrow
    /// crash window after finalization but before a synchronous result reaches
    /// the harness. Legacy receipts default to false.
    #[serde(default)]
    pub continuation_expected: bool,
    /// Remote-build receipts are also a durable wake-up outbox. Legacy
    /// receipts predate that contract and default to `false`, so upgrading
    /// never replays old validations into missions.
    #[serde(default)]
    pub wake_required: bool,
    /// Set only after the owning mission has durably accepted the terminal
    /// continuation (live control queue or persisted deferred goal).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wake_delivered_at: Option<chrono::DateTime<chrono::Utc>>,
    /// A newer validation for the same mission made this terminal callback
    /// obsolete before it was delivered. The receipt remains immutable build
    /// evidence, but it must not close the newer wait lease or start a stale
    /// continuation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wake_suppressed_by: Option<Uuid>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalWakeDisposition {
    Ready,
    /// A newer ambiguous submission may have reached a node but has not yet
    /// produced an accepted validation handle. The terminal callback must
    /// wait until that job id is reconciled.
    Deferred,
    /// A later validation has taken ownership of the mission's continuation.
    SupersededBy(Uuid),
}

pub(crate) fn validation_order(
    sequence: u64,
    started_at: chrono::DateTime<chrono::Utc>,
) -> (u64, i64) {
    (sequence, started_at.timestamp_micros())
}

/// Immutable point-in-time snapshot of live job handles and terminal receipts
/// for a working directory, served wait-free via [`ArcSwap`].
#[derive(Debug, Clone, Default)]
pub struct JobLedgerSnapshot {
    pub handles: Vec<JobHandle>,
    pub receipts: Vec<RemoteJobReceipt>,
}

enum LedgerCmd {
    Record {
        handle: Box<JobHandle>,
        reply: oneshot::Sender<anyhow::Result<()>>,
    },
    Attach {
        job_id: Uuid,
        mission_id: Uuid,
        expects_continuation: bool,
        reply: oneshot::Sender<anyhow::Result<Option<JobHandle>>>,
    },
    Remove {
        job_id: Uuid,
        reply: oneshot::Sender<()>,
    },
    Heartbeat {
        job_id: Uuid,
        reply: oneshot::Sender<anyhow::Result<bool>>,
    },
    RequireTerminalWake {
        job_id: Uuid,
        mission_id: Uuid,
        reply: oneshot::Sender<anyhow::Result<bool>>,
    },
    RequireTerminalReceiptWake {
        job_id: Uuid,
        mission_id: Uuid,
        reply: oneshot::Sender<anyhow::Result<bool>>,
    },
    MarkTerminalWakeSuppressed {
        job_id: Uuid,
        mission_id: Uuid,
        superseding_job_id: Uuid,
        reply: oneshot::Sender<anyhow::Result<bool>>,
    },
    MarkTerminalWakeDelivered {
        job_id: Uuid,
        mission_id: Uuid,
        reply: oneshot::Sender<anyhow::Result<bool>>,
    },
    Finalize {
        job_id: Uuid,
        state: String,
        exit_status: Option<i32>,
        artifacts: Vec<ArtifactEntry>,
        reply: oneshot::Sender<anyhow::Result<bool>>,
    },
}

struct DirLedger {
    working_dir: PathBuf,
    snapshot: ArcSwap<JobLedgerSnapshot>,
    initialized: AtomicBool,
    init_lock: tokio::sync::Mutex<()>,
    actor_tx: std::sync::Mutex<Option<mpsc::Sender<LedgerCmd>>>,
}

static LEDGERS: LazyLock<DashMap<PathBuf, Arc<DirLedger>>> = LazyLock::new(DashMap::new);

fn dir_ledger(working_dir: &Path) -> Arc<DirLedger> {
    if let Some(existing) = LEDGERS.get(working_dir) {
        return Arc::clone(existing.value());
    }
    Arc::clone(
        LEDGERS
            .entry(working_dir.to_path_buf())
            .or_insert_with(|| {
                Arc::new(DirLedger {
                    working_dir: working_dir.to_path_buf(),
                    snapshot: ArcSwap::from_pointee(JobLedgerSnapshot::default()),
                    initialized: AtomicBool::new(false),
                    init_lock: tokio::sync::Mutex::new(()),
                    actor_tx: std::sync::Mutex::new(None),
                })
            })
            .value(),
    )
}

impl DirLedger {
    async fn load_snapshot(&self) -> anyhow::Result<Arc<JobLedgerSnapshot>> {
        if self.initialized.load(Ordering::Acquire) {
            return Ok(self.snapshot.load_full());
        }
        let _guard = self.init_lock.lock().await;
        if self.initialized.load(Ordering::Acquire) {
            return Ok(self.snapshot.load_full());
        }
        let handles = read_handles_from_disk(&self.working_dir).await?;
        let receipts = read_receipts_from_disk(&self.working_dir).await?;
        let snap = Arc::new(JobLedgerSnapshot { handles, receipts });
        self.snapshot.store(Arc::clone(&snap));
        self.initialized.store(true, Ordering::Release);
        Ok(snap)
    }

    fn actor_sender(self: &Arc<Self>) -> mpsc::Sender<LedgerCmd> {
        let mut guard = self.actor_tx.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(tx) = guard.as_ref() {
            if !tx.is_closed() {
                return tx.clone();
            }
        }
        let (tx, rx) = mpsc::channel(256);
        tokio::spawn(run_ledger_actor(Arc::clone(self), rx));
        *guard = Some(tx.clone());
        tx
    }

    async fn send_cmd<R>(
        self: &Arc<Self>,
        make_cmd: impl FnOnce(oneshot::Sender<R>) -> LedgerCmd,
    ) -> anyhow::Result<R> {
        let tx = self.actor_sender();
        let (reply_tx, reply_rx) = oneshot::channel();
        tx.send(make_cmd(reply_tx))
            .await
            .map_err(|_| anyhow::anyhow!("remote job ledger actor stopped"))?;
        reply_rx
            .await
            .map_err(|_| anyhow::anyhow!("remote job ledger actor dropped reply"))
    }
}

async fn run_blocking_mirror<F>(f: F)
where
    F: FnOnce() + Send + 'static,
{
    let _ = tokio::task::spawn_blocking(f).await;
}

async fn run_ledger_actor(ledger: Arc<DirLedger>, mut rx: mpsc::Receiver<LedgerCmd>) {
    const MAX_RECEIPTS: usize = 2_000;
    let mut pending_next: Option<LedgerCmd> = None;

    loop {
        let cmd = match pending_next.take() {
            Some(next) => next,
            None => match rx.recv().await {
                Some(cmd) => cmd,
                None => break,
            },
        };

        let current = match ledger.load_snapshot().await {
            Ok(snap) => snap,
            Err(err) => {
                match cmd {
                    LedgerCmd::Record { reply, .. } => {
                        let _ = reply.send(Err(err));
                    }
                    LedgerCmd::Attach { reply, .. } => {
                        let _ = reply.send(Err(err));
                    }
                    LedgerCmd::Remove { reply, .. } => {
                        tracing::warn!(?err, "remote job ledger removal deferred");
                        let _ = reply.send(());
                    }
                    LedgerCmd::Heartbeat { reply, .. }
                    | LedgerCmd::RequireTerminalWake { reply, .. }
                    | LedgerCmd::RequireTerminalReceiptWake { reply, .. }
                    | LedgerCmd::MarkTerminalWakeSuppressed { reply, .. }
                    | LedgerCmd::MarkTerminalWakeDelivered { reply, .. }
                    | LedgerCmd::Finalize { reply, .. } => {
                        let _ = reply.send(Err(err));
                    }
                }
                continue;
            }
        };

        match cmd {
            LedgerCmd::Record { handle, reply } => {
                let mut handle = *handle;
                let mut handles = current.handles.clone();
                let receipts = &current.receipts;
                let previous_sequence = handles
                    .iter()
                    .find(|existing| existing.job_id == handle.job_id)
                    .map(|existing| existing.submission_sequence)
                    .unwrap_or(0);
                if handle.submission_sequence == 0 {
                    handle.submission_sequence = if previous_sequence > 0 {
                        previous_sequence
                    } else {
                        let receipt_max = receipts
                            .iter()
                            .map(|receipt| receipt.submission_sequence)
                            .max()
                            .unwrap_or(0);
                        handles
                            .iter()
                            .map(|existing| existing.submission_sequence)
                            .max()
                            .unwrap_or(0)
                            .max(receipt_max)
                            .saturating_add(1)
                    };
                }
                // A job may carry one handle per subscribed mission (see [`attach`]);
                // the submitter's handle and every attached handle share the job id and
                // are told apart by mission id.
                handles.retain(|existing| {
                    existing.job_id != handle.job_id || existing.mission_id != handle.mission_id
                });
                let mirrored = handle.clone();
                handles.push(handle);
                let res = match store(&ledger.working_dir, &handles).await {
                    Ok(()) => {
                        ledger.snapshot.store(Arc::new(JobLedgerSnapshot {
                            handles,
                            receipts: current.receipts.clone(),
                        }));
                        let wd = ledger.working_dir.clone();
                        run_blocking_mirror(move || sql::mirror_handle(&wd, &mirrored)).await;
                        Ok(())
                    }
                    Err(err) => Err(err),
                };
                let _ = reply.send(res);
            }
            LedgerCmd::Attach {
                job_id,
                mission_id,
                expects_continuation,
                reply,
            } => {
                if let Some(existing) = current
                    .handles
                    .iter()
                    .find(|handle| handle.job_id == job_id && handle.mission_id == mission_id)
                {
                    let _ = reply.send(Ok(Some(existing.clone())));
                    continue;
                }
                let Some(canonical) = current
                    .handles
                    .iter()
                    .filter(|handle| {
                        handle.job_id == job_id
                            && matches!(
                                handle.kind,
                                JobHandleKind::RemoteBuild | JobHandleKind::Tentative
                            )
                    })
                    .min_by_key(|handle| {
                        validation_order(handle.submission_sequence, handle.started_at)
                    })
                    .cloned()
                else {
                    let _ = reply.send(Ok(None));
                    continue;
                };
                let attached = JobHandle {
                    mission_id,
                    wait_for_completion: Some(expects_continuation),
                    wake_on_terminal: false,
                    ..canonical
                };
                let mut handles = current.handles.clone();
                handles.push(attached.clone());
                let res = match store(&ledger.working_dir, &handles).await {
                    Ok(()) => {
                        ledger.snapshot.store(Arc::new(JobLedgerSnapshot {
                            handles,
                            receipts: current.receipts.clone(),
                        }));
                        let wd = ledger.working_dir.clone();
                        run_blocking_mirror(move || {
                            sql::mirror_subscriber(&wd, job_id, mission_id, expects_continuation);
                        })
                        .await;
                        Ok(Some(attached))
                    }
                    Err(err) => Err(err),
                };
                let _ = reply.send(res);
            }
            LedgerCmd::Remove { job_id, reply } => {
                let mut handles = current.handles.clone();
                let before = handles.len();
                handles.retain(|h| h.job_id != job_id);
                if handles.len() != before {
                    match store(&ledger.working_dir, &handles).await {
                        Ok(()) => {
                            ledger.snapshot.store(Arc::new(JobLedgerSnapshot {
                                handles,
                                receipts: current.receipts.clone(),
                            }));
                            let wd = ledger.working_dir.clone();
                            run_blocking_mirror(move || sql::mirror_remove(&wd, job_id)).await;
                            if let Some(m) = crate::managed::global() {
                                m.notify_activity_change();
                            }
                        }
                        Err(err) => {
                            tracing::warn!(?err, "remote job ledger removal failed");
                        }
                    }
                }
                let _ = reply.send(());
            }
            LedgerCmd::Heartbeat { job_id, reply } => {
                // Coalesce any contiguous queued Heartbeat commands into one batch write!
                let mut batch = vec![(job_id, reply)];
                while let Ok(next) = rx.try_recv() {
                    match next {
                        LedgerCmd::Heartbeat {
                            job_id: next_id,
                            reply: next_reply,
                        } => batch.push((next_id, next_reply)),
                        other => {
                            pending_next = Some(other);
                            break;
                        }
                    }
                }
                let mut handles = current.handles.clone();
                let now = chrono::Utc::now();
                let mut any_touched = false;
                let mut touched_ids = Vec::new();
                let mut found_flags = Vec::with_capacity(batch.len());

                for (id, _) in &batch {
                    let mut found = false;
                    let mut touched_this = false;
                    for handle in handles.iter_mut().filter(|h| h.job_id == *id) {
                        found = true;
                        if handle
                            .heartbeat_at
                            .is_some_and(|previous| now - previous < chrono::Duration::seconds(15))
                        {
                            continue;
                        }
                        handle.heartbeat_at = Some(now);
                        any_touched = true;
                        touched_this = true;
                    }
                    if touched_this && !touched_ids.contains(id) {
                        touched_ids.push(*id);
                    }
                    found_flags.push(found);
                }

                if any_touched {
                    match store(&ledger.working_dir, &handles).await {
                        Ok(()) => {
                            let mirrored: Vec<JobHandle> = touched_ids
                                .iter()
                                .filter_map(|id| handles.iter().find(|h| h.job_id == *id).cloned())
                                .collect();
                            ledger.snapshot.store(Arc::new(JobLedgerSnapshot {
                                handles,
                                receipts: current.receipts.clone(),
                            }));
                            let wd = ledger.working_dir.clone();
                            run_blocking_mirror(move || {
                                for h in &mirrored {
                                    sql::mirror_handle(&wd, h);
                                }
                            })
                            .await;
                            for ((_, reply), found) in batch.into_iter().zip(found_flags) {
                                let _ = reply.send(Ok(found));
                            }
                        }
                        Err(err) => {
                            let msg = err.to_string();
                            let mut iter = batch.into_iter();
                            if let Some((_, first_reply)) = iter.next() {
                                let _ = first_reply.send(Err(err));
                            }
                            for (_, r) in iter {
                                let _ = r.send(Err(anyhow::anyhow!("{msg}")));
                            }
                        }
                    }
                } else {
                    for ((_, reply), found) in batch.into_iter().zip(found_flags) {
                        let _ = reply.send(Ok(found));
                    }
                }
            }
            LedgerCmd::RequireTerminalWake {
                job_id,
                mission_id,
                reply,
            } => {
                let mut handles = current.handles.clone();
                let Some(handle) = handles
                    .iter_mut()
                    .find(|handle| handle.job_id == job_id && handle.mission_id == mission_id)
                else {
                    let _ = reply.send(Ok(false));
                    continue;
                };
                if !handle.wake_on_terminal {
                    handle.wake_on_terminal = true;
                    match store(&ledger.working_dir, &handles).await {
                        Ok(()) => {
                            ledger.snapshot.store(Arc::new(JobLedgerSnapshot {
                                handles,
                                receipts: current.receipts.clone(),
                            }));
                            let _ = reply.send(Ok(true));
                        }
                        Err(err) => {
                            let _ = reply.send(Err(err));
                        }
                    }
                } else {
                    let _ = reply.send(Ok(true));
                }
            }
            LedgerCmd::RequireTerminalReceiptWake {
                job_id,
                mission_id,
                reply,
            } => {
                let mut receipts = current.receipts.clone();
                let Some(receipt) = receipts
                    .iter_mut()
                    .find(|receipt| receipt.job_id == job_id && receipt.mission_id == mission_id)
                else {
                    let _ = reply.send(Ok(false));
                    continue;
                };
                if receipt.wake_delivered_at.is_some()
                    || (!receipt.wake_required && !receipt.continuation_expected)
                {
                    let _ = reply.send(Ok(false));
                    continue;
                }
                if !receipt.wake_required {
                    receipt.wake_required = true;
                    match store_receipts(&ledger.working_dir, &receipts).await {
                        Ok(()) => {
                            ledger.snapshot.store(Arc::new(JobLedgerSnapshot {
                                handles: current.handles.clone(),
                                receipts,
                            }));
                            let _ = reply.send(Ok(true));
                        }
                        Err(err) => {
                            let _ = reply.send(Err(err));
                        }
                    }
                } else {
                    let _ = reply.send(Ok(true));
                }
            }
            LedgerCmd::MarkTerminalWakeSuppressed {
                job_id,
                mission_id,
                superseding_job_id,
                reply,
            } => {
                let mut receipts = current.receipts.clone();
                let Some(receipt) = receipts
                    .iter_mut()
                    .find(|receipt| receipt.job_id == job_id && receipt.mission_id == mission_id)
                else {
                    let _ = reply.send(Ok(false));
                    continue;
                };
                if receipt.wake_delivered_at.is_none() {
                    receipt.wake_delivered_at = Some(chrono::Utc::now());
                    receipt.wake_suppressed_by = Some(superseding_job_id);
                    match store_receipts(&ledger.working_dir, &receipts).await {
                        Ok(()) => {
                            ledger.snapshot.store(Arc::new(JobLedgerSnapshot {
                                handles: current.handles.clone(),
                                receipts,
                            }));
                            let wd = ledger.working_dir.clone();
                            run_blocking_mirror(move || {
                                sql::mirror_wake(
                                    &wd,
                                    job_id,
                                    mission_id,
                                    "suppressed",
                                    Some(superseding_job_id),
                                );
                            })
                            .await;
                            let _ = reply.send(Ok(true));
                        }
                        Err(err) => {
                            let _ = reply.send(Err(err));
                        }
                    }
                } else {
                    let _ = reply.send(Ok(true));
                }
            }
            LedgerCmd::MarkTerminalWakeDelivered {
                job_id,
                mission_id,
                reply,
            } => {
                let mut receipts = current.receipts.clone();
                let Some(receipt) = receipts
                    .iter_mut()
                    .find(|receipt| receipt.job_id == job_id && receipt.mission_id == mission_id)
                else {
                    let _ = reply.send(Ok(false));
                    continue;
                };
                if receipt.wake_delivered_at.is_none() {
                    receipt.wake_delivered_at = Some(chrono::Utc::now());
                    match store_receipts(&ledger.working_dir, &receipts).await {
                        Ok(()) => {
                            ledger.snapshot.store(Arc::new(JobLedgerSnapshot {
                                handles: current.handles.clone(),
                                receipts,
                            }));
                            let wd = ledger.working_dir.clone();
                            run_blocking_mirror(move || {
                                sql::mirror_wake(&wd, job_id, mission_id, "delivered", None);
                            })
                            .await;
                            let _ = reply.send(Ok(true));
                        }
                        Err(err) => {
                            let _ = reply.send(Err(err));
                        }
                    }
                } else {
                    let _ = reply.send(Ok(true));
                }
            }
            LedgerCmd::Finalize {
                job_id,
                state,
                exit_status,
                artifacts,
                reply,
            } => {
                if !current.handles.iter().any(|handle| handle.job_id == job_id) {
                    let _ = reply.send(Ok(false));
                    continue;
                }
                // Verify receipts path is not obstructed (e.g. replaced by a directory)
                // before mutating handles, preserving atomic failure semantics.
                let rpath = receipts_path(&ledger.working_dir);
                if let Ok(meta) = tokio::fs::metadata(&rpath).await {
                    if meta.is_dir() {
                        let _ = reply.send(Err(anyhow::anyhow!(
                            "read {}: Is a directory",
                            rpath.display()
                        )));
                        continue;
                    }
                }
                let mut handles = current.handles.clone();
                let closing: Vec<JobHandle> = handles
                    .iter()
                    .filter(|handle| handle.job_id == job_id)
                    .cloned()
                    .collect();
                handles.retain(|handle| handle.job_id != job_id);
                let mut receipts = current.receipts.clone();
                let finished_at = chrono::Utc::now();
                let mut mirrored_receipts = Vec::new();
                let mut wrote_receipt = false;
                for handle in closing {
                    if handle.kind != JobHandleKind::RemoteBuild {
                        continue;
                    }
                    let continuation_expected = handle.expects_mission_continuation();
                    let Some(identity) = handle.identity.clone() else {
                        continue;
                    };
                    let previous_wake_delivered_at = receipts
                        .iter()
                        .find(|receipt| {
                            receipt.job_id == job_id && receipt.mission_id == handle.mission_id
                        })
                        .and_then(|receipt| receipt.wake_delivered_at);
                    receipts.retain(|receipt| {
                        receipt.job_id != job_id || receipt.mission_id != handle.mission_id
                    });
                    let receipt = RemoteJobReceipt {
                        mission_id: handle.mission_id,
                        node_id: handle.node_id,
                        job_id,
                        started_at: handle.started_at,
                        submission_sequence: handle.submission_sequence,
                        finished_at,
                        state: state.clone(),
                        exit_status,
                        identity,
                        artifacts: artifacts.clone(),
                        continuation_expected,
                        wake_required: handle.wake_on_terminal,
                        wake_delivered_at: previous_wake_delivered_at,
                        wake_suppressed_by: None,
                    };
                    mirrored_receipts.push(receipt.clone());
                    receipts.push(receipt);
                    wrote_receipt = true;
                }
                if !wrote_receipt {
                    match store(&ledger.working_dir, &handles).await {
                        Ok(()) => {
                            ledger
                                .snapshot
                                .store(Arc::new(JobLedgerSnapshot { handles, receipts }));
                            let wd = ledger.working_dir.clone();
                            run_blocking_mirror(move || {
                                sql::mirror_terminal_without_receipt(&wd, job_id, &state);
                            })
                            .await;
                            let _ = reply.send(Ok(true));
                        }
                        Err(err) => {
                            let _ = reply.send(Err(err));
                        }
                    }
                    continue;
                }

                if receipts.len() > MAX_RECEIPTS {
                    receipts.sort_by_key(|receipt| receipt.finished_at);
                    let mut excess = receipts.len() - MAX_RECEIPTS;
                    receipts.retain(|receipt| {
                        let pending_wake =
                            receipt.wake_required && receipt.wake_delivered_at.is_none();
                        if excess > 0 && !pending_wake {
                            excess -= 1;
                            false
                        } else {
                            true
                        }
                    });
                }

                if let Err(err) = store_receipts(&ledger.working_dir, &receipts).await {
                    let _ = reply.send(Err(err));
                    continue;
                }
                if let Err(err) = store(&ledger.working_dir, &handles).await {
                    let _ = reply.send(Err(err));
                    continue;
                }
                ledger
                    .snapshot
                    .store(Arc::new(JobLedgerSnapshot { handles, receipts }));
                let wd = ledger.working_dir.clone();
                run_blocking_mirror(move || {
                    for receipt in &mirrored_receipts {
                        sql::mirror_receipt(&wd, receipt);
                    }
                })
                .await;
                let _ = reply.send(Ok(true));
            }
        }
    }
}

/// The one unresolved remote build, if any, that is still allowed to own a
/// mission's `waiting_remote_job` lease. A terminal receipt from a later
/// validation supersedes an older in-flight handle: the old node job must
/// still be observed to terminal, but it must not resurrect or park the
/// mission after the newer validation has already advanced the workflow.
pub async fn current_remote_build_wait_handle(
    working_dir: &Path,
    mission_id: Uuid,
) -> anyhow::Result<Option<JobHandle>> {
    let snap = dir_ledger(working_dir).load_snapshot().await?;
    let handles = &snap.handles;
    let receipts = &snap.receipts;

    let current_handle = handles
        .iter()
        .filter(|handle| {
            handle.mission_id == mission_id
                && handle.kind == JobHandleKind::RemoteBuild
                && handle.accepted_at.is_some()
                && handle.expects_mission_continuation()
        })
        .max_by_key(|handle| validation_order(handle.submission_sequence, handle.started_at));
    let Some(current_handle) = current_handle else {
        return Ok(None);
    };

    let current_order = validation_order(
        current_handle.submission_sequence,
        current_handle.started_at,
    );
    let newer_terminal_exists = receipts.iter().any(|receipt| {
        if receipt.mission_id != mission_id
            || (!receipt.wake_required && !receipt.continuation_expected)
        {
            return false;
        }
        let receipt_order = validation_order(receipt.submission_sequence, receipt.started_at);
        receipt_order > current_order
            || (receipt_order == current_order
                && (receipt.submission_sequence == 0 || current_handle.submission_sequence == 0))
    });
    let newer_ambiguous_submission_exists = handles.iter().any(|handle| {
        handle.mission_id == mission_id
            && handle.kind == JobHandleKind::Tentative
            && handle.continuation_requested()
            && validation_order(handle.submission_sequence, handle.started_at) > current_order
    });

    if crate::orb_spec::job_ledger_step(
        current_handle.kind == JobHandleKind::RemoteBuild && current_handle.accepted_at.is_some(),
        current_handle.expects_mission_continuation(),
        newer_terminal_exists,
        newer_ambiguous_submission_exists,
    )
    .retain_wait_handle
    {
        Ok(Some(current_handle.clone()))
    } else {
        Ok(None)
    }
}

#[derive(Debug, Clone)]
pub enum EquivalentRemoteValidation {
    /// An accepted or ambiguously submitted job with the same immutable
    /// validation identity is still unresolved. A new submission must fail
    /// closed until that canonical job is reconciled.
    Active(JobHandle),
    /// A successful terminal receipt already proves this exact validation.
    /// Callers may replay it without consuming remote capacity.
    Succeeded(RemoteJobReceipt),
}

fn ledger_path(working_dir: &Path) -> PathBuf {
    working_dir.join(".sandboxed-sh").join("remote-jobs.json")
}

fn receipts_path(working_dir: &Path) -> PathBuf {
    working_dir
        .join(".sandboxed-sh")
        .join("remote-job-receipts.json")
}

async fn read_handles_from_disk(working_dir: &Path) -> anyhow::Result<Vec<JobHandle>> {
    let path = ledger_path(working_dir);
    match tokio::fs::read(&path).await {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map_err(|err| anyhow::anyhow!("parse {}: {err}", path.display())),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(err) => Err(anyhow::anyhow!("read {}: {err}", path.display())),
    }
}

async fn read_receipts_from_disk(working_dir: &Path) -> anyhow::Result<Vec<RemoteJobReceipt>> {
    let path = receipts_path(working_dir);
    match tokio::fs::read(&path).await {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map_err(|err| anyhow::anyhow!("parse {}: {err}", path.display())),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(err) => Err(anyhow::anyhow!("read {}: {err}", path.display())),
    }
}

async fn load_result(working_dir: &Path) -> anyhow::Result<Vec<JobHandle>> {
    Ok(dir_ledger(working_dir)
        .load_snapshot()
        .await?
        .handles
        .clone())
}

pub async fn load(working_dir: &Path) -> anyhow::Result<Vec<JobHandle>> {
    load_result(working_dir).await
}

async fn store(working_dir: &Path, handles: &[JobHandle]) -> anyhow::Result<()> {
    let path = ledger_path(working_dir);
    let bytes = serde_json::to_vec_pretty(handles)?;
    crate::concurrency::write_atomic_async(&path, &bytes, None).await?;
    Ok(())
}

#[cfg(test)]
async fn load_receipts_result(working_dir: &Path) -> anyhow::Result<Vec<RemoteJobReceipt>> {
    Ok(dir_ledger(working_dir)
        .load_snapshot()
        .await?
        .receipts
        .clone())
}

async fn store_receipts(working_dir: &Path, receipts: &[RemoteJobReceipt]) -> anyhow::Result<()> {
    let path = receipts_path(working_dir);
    let bytes = serde_json::to_vec_pretty(receipts)?;
    crate::concurrency::write_atomic_async(&path, &bytes, None).await?;
    Ok(())
}

pub async fn terminal_receipt(
    working_dir: &Path,
    job_id: Uuid,
) -> anyhow::Result<Option<RemoteJobReceipt>> {
    let snap = dir_ledger(working_dir).load_snapshot().await?;
    Ok(snap
        .receipts
        .iter()
        .find(|receipt| receipt.job_id == job_id)
        .cloned())
}

/// The terminal receipt a specific (possibly attached) mission holds for a job.
pub async fn terminal_receipt_for_mission(
    working_dir: &Path,
    job_id: Uuid,
    mission_id: Uuid,
) -> anyhow::Result<Option<RemoteJobReceipt>> {
    let snap = dir_ledger(working_dir).load_snapshot().await?;
    Ok(snap
        .receipts
        .iter()
        .find(|receipt| receipt.job_id == job_id && receipt.mission_id == mission_id)
        .cloned())
}

/// Whether `mission_id` holds (or held) a handle or receipt for `job_id`:
/// the submitter, or a mission that attached to it.
pub async fn mission_subscribed(
    working_dir: &Path,
    job_id: Uuid,
    mission_id: Uuid,
) -> anyhow::Result<bool> {
    let snap = dir_ledger(working_dir).load_snapshot().await?;
    if snap
        .handles
        .iter()
        .any(|handle| handle.job_id == job_id && handle.mission_id == mission_id)
    {
        return Ok(true);
    }
    Ok(snap
        .receipts
        .iter()
        .any(|receipt| receipt.job_id == job_id && receipt.mission_id == mission_id))
}

pub async fn terminal_receipts_for_mission(
    working_dir: &Path,
    mission_id: Uuid,
) -> anyhow::Result<Vec<RemoteJobReceipt>> {
    let snap = dir_ledger(working_dir).load_snapshot().await?;
    Ok(snap
        .receipts
        .iter()
        .filter(|receipt| receipt.mission_id == mission_id)
        .cloned()
        .collect())
}

/// Return every distinct `mission_id` that currently holds a job handle or
/// completed terminal receipt on `node_id`.
pub async fn mission_ids_for_node(working_dir: &Path, node_id: &str) -> Vec<Uuid> {
    let mut ids = Vec::new();
    if let Ok(snap) = dir_ledger(working_dir).load_snapshot().await {
        for h in &snap.handles {
            if h.node_id == node_id && !ids.contains(&h.mission_id) {
                ids.push(h.mission_id);
            }
        }
        for r in &snap.receipts {
            if r.node_id == node_id && !ids.contains(&r.mission_id) {
                ids.push(r.mission_id);
            }
        }
    }
    ids
}

/// Resolve an immutable validation identity across mission boundaries.
///
/// The ledger and receipt snapshots are swapped atomically via [`ArcSwap`] so
/// finalization cannot move a matching job between them during the lookup.
/// Successful receipts take precedence over a redundant in-flight job left by
/// an older client: once exact evidence exists, no third build should be dispatched.
pub async fn equivalent_remote_validation(
    working_dir: &Path,
    identity: &RemoteJobIdentity,
) -> anyhow::Result<Option<EquivalentRemoteValidation>> {
    let snap = dir_ledger(working_dir).load_snapshot().await?;
    if let Some(receipt) = snap
        .receipts
        .iter()
        .filter(|receipt| {
            receipt.identity.reusable_for(identity)
                && (identity.artifacts.is_empty() || !receipt.artifacts.is_empty())
                && receipt.state == "succeeded"
                && receipt.exit_status == Some(0)
        })
        .max_by_key(|receipt| receipt.finished_at)
    {
        return Ok(Some(EquivalentRemoteValidation::Succeeded(receipt.clone())));
    }
    Ok(snap
        .handles
        .iter()
        .filter(|handle| {
            handle
                .identity
                .as_ref()
                .is_some_and(|existing| existing.excludes(identity))
                && matches!(
                    handle.kind,
                    JobHandleKind::RemoteBuild | JobHandleKind::Tentative
                )
        })
        .min_by_key(|handle| handle.started_at)
        .cloned()
        .map(EquivalentRemoteValidation::Active))
}

/// Unresolved (accepted or ambiguously submitted) job handle with the same
/// immutable validation identity, ignoring terminal receipts. In the combined
/// lookup above a successful receipt takes precedence over an active handle,
/// so forced runs that bypass receipt replay must use this to keep failing
/// closed on a concurrent equivalent submission.
pub async fn active_equivalent_remote_validation(
    working_dir: &Path,
    identity: &RemoteJobIdentity,
) -> anyhow::Result<Option<JobHandle>> {
    let snap = dir_ledger(working_dir).load_snapshot().await?;
    Ok(snap
        .handles
        .iter()
        .filter(|handle| {
            handle
                .identity
                .as_ref()
                .is_some_and(|existing| existing.excludes(identity))
                && matches!(
                    handle.kind,
                    JobHandleKind::RemoteBuild | JobHandleKind::Tentative
                )
        })
        .min_by_key(|handle| handle.started_at)
        .cloned())
}

/// Terminal remote-build receipts whose mission continuation has not yet
/// reached a durable queue. The startup reconciler retries these after a
/// process crash, making receipt finalization and mission wake-up effectively
/// an outbox operation rather than a best-effort callback.
pub async fn pending_terminal_wakes(working_dir: &Path) -> anyhow::Result<Vec<RemoteJobReceipt>> {
    let snap = dir_ledger(working_dir).load_snapshot().await?;
    Ok(snap
        .receipts
        .iter()
        .filter(|receipt| receipt.wake_required && receipt.wake_delivered_at.is_none())
        .cloned()
        .collect())
}

/// Terminal receipts that can recover an inherited `waiting_remote_job`
/// lease. Unlike `pending_terminal_wakes`, this includes a synchronous result
/// finalized immediately before a core crash, while its normal HTTP/tool
/// delivery was still in flight.
pub async fn recoverable_terminal_continuations(
    working_dir: &Path,
    mission_id: Uuid,
) -> anyhow::Result<Vec<RemoteJobReceipt>> {
    let snap = dir_ledger(working_dir).load_snapshot().await?;
    Ok(snap
        .receipts
        .iter()
        .filter(|receipt| {
            receipt.mission_id == mission_id
                && receipt.wake_delivered_at.is_none()
                && (receipt.wake_required || receipt.continuation_expected)
        })
        .cloned()
        .collect())
}

/// Promote a terminal continuation into the durable wake outbox after startup
/// proved that its mission still had an inherited remote-wait lease.
pub async fn require_terminal_receipt_wake(
    working_dir: &Path,
    job_id: Uuid,
    mission_id: Uuid,
) -> anyhow::Result<bool> {
    dir_ledger(working_dir)
        .send_cmd(|reply| LedgerCmd::RequireTerminalReceiptWake {
            job_id,
            mission_id,
            reply,
        })
        .await?
}

/// Decide whether a durable terminal callback still owns the mission wake.
///
/// Missions may advance their immutable head while an older validation is in
/// flight. After a restart the older handle is armed for recovery, while the
/// resumed harness can submit the newer head in the same run. Delivering the
/// old callback would then finish `waiting_remote_job` underneath the newer
/// synchronous tool. Prefer the newest accepted validation and retain older
/// receipts as evidence only.
pub async fn terminal_wake_disposition(
    working_dir: &Path,
    receipt: &RemoteJobReceipt,
) -> anyhow::Result<TerminalWakeDisposition> {
    let snap = dir_ledger(working_dir).load_snapshot().await?;
    let handles = &snap.handles;
    let receipts = &snap.receipts;
    let receipt_order = validation_order(receipt.submission_sequence, receipt.started_at);

    let newer_handle_id = handles
        .iter()
        .filter(|handle| {
            handle.kind == JobHandleKind::RemoteBuild
                && handle.expects_mission_continuation()
                && handle.mission_id == receipt.mission_id
                && handle.job_id != receipt.job_id
                && validation_order(handle.submission_sequence, handle.started_at) > receipt_order
        })
        .max_by_key(|handle| validation_order(handle.submission_sequence, handle.started_at))
        .map(|h| h.job_id);
    let newer_receipt_id = receipts
        .iter()
        .filter(|candidate| {
            candidate.mission_id == receipt.mission_id
                && (candidate.wake_required || candidate.continuation_expected)
                && candidate.job_id != receipt.job_id
                && validation_order(candidate.submission_sequence, candidate.started_at)
                    > receipt_order
        })
        .max_by_key(|candidate| {
            validation_order(candidate.submission_sequence, candidate.started_at)
        })
        .map(|r| r.job_id);
    let superseding_id = newer_handle_id.or(newer_receipt_id);
    let ambiguous_tentative = handles.iter().any(|handle| {
        handle.kind == JobHandleKind::Tentative
            && handle.continuation_requested()
            && handle.mission_id == receipt.mission_id
            && handle.job_id != receipt.job_id
            && validation_order(handle.submission_sequence, handle.started_at) >= receipt_order
    }) || handles.iter().any(|handle| {
        handle.kind == JobHandleKind::RemoteBuild
            && handle.expects_mission_continuation()
            && handle.mission_id == receipt.mission_id
            && handle.job_id != receipt.job_id
            && validation_order(handle.submission_sequence, handle.started_at) == receipt_order
            && (handle.submission_sequence == 0 || receipt.submission_sequence == 0)
    });
    match crate::orb_spec::job_ledger_step(
        true,
        receipt.wake_required || receipt.continuation_expected,
        superseding_id.is_some(),
        ambiguous_tentative,
    )
    .wake
    {
        crate::orb_spec::JobLedgerWake::Superseded => Ok(TerminalWakeDisposition::SupersededBy(
            superseding_id.expect("superseding id present"),
        )),
        crate::orb_spec::JobLedgerWake::Deferred => Ok(TerminalWakeDisposition::Deferred),
        crate::orb_spec::JobLedgerWake::Ready => Ok(TerminalWakeDisposition::Ready),
    }
}

pub async fn mark_terminal_wake_suppressed(
    working_dir: &Path,
    job_id: Uuid,
    mission_id: Uuid,
    superseding_job_id: Uuid,
) -> anyhow::Result<bool> {
    dir_ledger(working_dir)
        .send_cmd(|reply| LedgerCmd::MarkTerminalWakeSuppressed {
            job_id,
            mission_id,
            superseding_job_id,
            reply,
        })
        .await?
}

pub async fn mark_terminal_wake_delivered(
    working_dir: &Path,
    job_id: Uuid,
    mission_id: Uuid,
) -> anyhow::Result<bool> {
    dir_ledger(working_dir)
        .send_cmd(|reply| LedgerCmd::MarkTerminalWakeDelivered {
            job_id,
            mission_id,
            reply,
        })
        .await?
}

/// Close an active handle and retain immutable validation evidence. Raw
/// mission and tentative handles are removed without producing a receipt.
pub async fn finalize(
    working_dir: &Path,
    job_id: Uuid,
    state: &str,
    exit_status: Option<i32>,
) -> anyhow::Result<bool> {
    finalize_with_artifacts(working_dir, job_id, state, exit_status, Vec::new()).await
}

/// Finalize a remote build while retaining its resolved artifact evidence.
pub async fn finalize_with_artifacts(
    working_dir: &Path,
    job_id: Uuid,
    state: &str,
    exit_status: Option<i32>,
    artifacts: Vec<ArtifactEntry>,
) -> anyhow::Result<bool> {
    anyhow::ensure!(
        super::job_state_confirms_termination(state),
        "remote job {job_id} has no confirmed terminal execution: {state}"
    );
    let state = state.to_string();
    dir_ledger(working_dir)
        .send_cmd(|reply| LedgerCmd::Finalize {
            job_id,
            state,
            exit_status,
            artifacts,
            reply,
        })
        .await?
}

/// Record a job handle (idempotent on (job_id, mission_id)).
pub async fn record(working_dir: &Path, handle: JobHandle) -> anyhow::Result<()> {
    dir_ledger(working_dir)
        .send_cmd(|reply| LedgerCmd::Record {
            handle: Box::new(handle),
            reply,
        })
        .await?
}

/// Subscribe `mission_id` to an already-live job: a second submission of the
/// same content identity attaches to the canonical job instead of failing.
/// The attached handle is a clone of the canonical one under the attaching
/// mission, so parking (`waiting_remote_job`), supersession and the terminal
/// wake all work per mission without a second execution. Idempotent.
pub async fn attach(
    working_dir: &Path,
    job_id: Uuid,
    mission_id: Uuid,
    expects_continuation: bool,
) -> anyhow::Result<Option<JobHandle>> {
    dir_ledger(working_dir)
        .send_cmd(|reply| LedgerCmd::Attach {
            job_id,
            mission_id,
            expects_continuation,
            reply,
        })
        .await?
}

/// Remove a job handle once its mission is finalized.
pub async fn remove(working_dir: &Path, job_id: Uuid) {
    let _ = dir_ledger(working_dir)
        .send_cmd(|reply| LedgerCmd::Remove { job_id, reply })
        .await;
}

/// Advance the durable heartbeat after a successful node status observation.
pub async fn heartbeat(working_dir: &Path, job_id: Uuid) -> anyhow::Result<bool> {
    let ledger = dir_ledger(working_dir);
    let snap = ledger.load_snapshot().await?;
    let now = chrono::Utc::now();
    let mut found = false;
    let mut needs_update = false;
    for handle in snap.handles.iter().filter(|h| h.job_id == job_id) {
        found = true;
        if handle
            .heartbeat_at
            .is_none_or(|previous| now - previous >= chrono::Duration::seconds(15))
        {
            needs_update = true;
            break;
        }
    }
    if found && !needs_update {
        return Ok(true);
    }
    ledger
        .send_cmd(|reply| LedgerCmd::Heartbeat { job_id, reply })
        .await?
}

pub async fn require_terminal_wake(
    working_dir: &Path,
    job_id: Uuid,
    mission_id: Uuid,
) -> anyhow::Result<bool> {
    dir_ledger(working_dir)
        .send_cmd(|reply| LedgerCmd::RequireTerminalWake {
            job_id,
            mission_id,
            reply,
        })
        .await?
}

/// SQL mirror of the JSON ledger (`projects.db`: `remote_jobs`,
/// `remote_job_subscribers`, `receipts` kind=`build`).
///
/// Dual-write window (plan step 6): the JSON files stay authoritative and
/// every mutation is mirrored here best-effort; startup runs
/// [`sql_parity_backfill`] so a mirror that fell behind converges. Reads move
/// to SQL in step 7, once a production restart has shown zero drift.
pub mod sql {
    use std::path::{Path, PathBuf};

    use rusqlite::{params, Connection, OptionalExtension};
    use serde::Serialize;
    use uuid::Uuid;

    use super::{JobHandle, JobHandleKind, RemoteJobReceipt};

    fn db_path(working_dir: &Path) -> PathBuf {
        working_dir.join(".sandboxed-sh").join("projects.db")
    }

    fn open(working_dir: &Path) -> Option<Connection> {
        let path = db_path(working_dir);
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let connection = Connection::open(&path)
            .map_err(|error| tracing::warn!(%error, "remote job SQL mirror: open failed"))
            .ok()?;
        let _ = connection.busy_timeout(std::time::Duration::from_secs(5));
        let _ = connection.pragma_update(None, "journal_mode", "WAL");
        // Idempotent: the store normally created these already; a fresh
        // working dir (tests, first boot before the store opened) gets them
        // here so a mirror write can never race the store's initialize.
        for schema in [
            crate::api::projects_store::SCHEMA,
            crate::api::projects_store::REMOTE_JOBS_SCHEMA,
        ] {
            if let Err(error) = connection.execute_batch(schema) {
                tracing::warn!(%error, "remote job SQL mirror: schema failed");
                return None;
            }
        }
        Some(connection)
    }

    fn kind_label(kind: JobHandleKind) -> &'static str {
        match kind {
            JobHandleKind::Mission => "mission",
            JobHandleKind::RemoteBuild => "remote_build",
            JobHandleKind::Tentative => "tentative",
        }
    }

    fn handle_state(handle: &JobHandle) -> &'static str {
        if handle.kind == JobHandleKind::Tentative || handle.accepted_at.is_none() {
            "submitting"
        } else if handle.heartbeat_at.is_some() {
            "running"
        } else {
            "accepted"
        }
    }

    fn upsert_handle(connection: &Connection, handle: &JobHandle) -> rusqlite::Result<()> {
        let now = chrono::Utc::now().to_rfc3339();
        // An attached handle (same job, another mission) is a subscriber row,
        // never a second job row.
        let submitter: Option<String> = connection
            .query_row(
                "SELECT mission_id FROM remote_jobs WHERE job_id = ?1",
                params![handle.job_id.to_string()],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(submitter) = submitter {
            if submitter != handle.mission_id.to_string() {
                connection.execute(
                    "INSERT OR IGNORE INTO remote_job_subscribers \
                       (job_id, mission_id, wake_required, wake_state, attached_at) \
                     VALUES (?1, ?2, ?3, 'pending', ?4)",
                    params![
                        handle.job_id.to_string(),
                        handle.mission_id.to_string(),
                        handle.wake_on_terminal as i64,
                        now
                    ],
                )?;
                return Ok(());
            }
        }
        let identity_json = handle
            .identity
            .as_ref()
            .and_then(|identity| serde_json::to_string(identity).ok());
        let identity_hash = handle
            .identity
            .as_ref()
            .map(|identity| identity.identity_hash());
        let identity_version = handle
            .identity
            .as_ref()
            .map(|identity| identity.version)
            .unwrap_or(0);
        connection.execute(
            "INSERT INTO remote_jobs \
               (job_id, mission_id, node_id, kind, state, identity_version, identity_hash, identity_json, \
                submission_sequence, started_at, accepted_at, heartbeat_at, wake_required, updated_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14) \
             ON CONFLICT(job_id) DO UPDATE SET \
               node_id = excluded.node_id, kind = excluded.kind, \
               state = CASE WHEN remote_jobs.state IN ('succeeded','failed','cancelled','lost') \
                            THEN remote_jobs.state ELSE excluded.state END, \
               identity_version = excluded.identity_version, identity_hash = excluded.identity_hash, \
               identity_json = excluded.identity_json, \
               submission_sequence = CASE WHEN excluded.submission_sequence > 0 \
                                          THEN excluded.submission_sequence ELSE remote_jobs.submission_sequence END, \
               accepted_at = COALESCE(excluded.accepted_at, remote_jobs.accepted_at), \
               heartbeat_at = COALESCE(excluded.heartbeat_at, remote_jobs.heartbeat_at), \
               wake_required = MAX(remote_jobs.wake_required, excluded.wake_required), \
               updated_at = excluded.updated_at",
            params![
                handle.job_id.to_string(),
                handle.mission_id.to_string(),
                handle.node_id,
                kind_label(handle.kind),
                handle_state(handle),
                identity_version,
                identity_hash,
                identity_json,
                handle.submission_sequence as i64,
                handle.started_at.to_rfc3339(),
                handle.accepted_at.map(|at| at.to_rfc3339()),
                handle.heartbeat_at.map(|at| at.to_rfc3339()),
                handle.wake_on_terminal as i64,
                now,
            ],
        )?;
        Ok(())
    }

    /// Mirror a live handle. A unique-index violation means a second live
    /// job for the same identity slipped past the JSON check: logged loudly
    /// (the JSON path is still the authority in the dual-write window).
    pub fn mirror_handle(working_dir: &Path, handle: &JobHandle) {
        let Some(connection) = open(working_dir) else {
            return;
        };
        if let Err(error) = upsert_handle(&connection, handle) {
            tracing::warn!(
                job_id = %handle.job_id,
                mission_id = %handle.mission_id,
                %error,
                "remote job SQL mirror: handle upsert failed (duplicate live identity?)"
            );
        }
    }

    fn upsert_receipt(connection: &Connection, receipt: &RemoteJobReceipt) -> rusqlite::Result<()> {
        let now = chrono::Utc::now().to_rfc3339();
        let state = match receipt.state.as_str() {
            "succeeded" | "failed" | "cancelled" | "lost" => receipt.state.as_str(),
            _ => "failed",
        };
        let artifacts = serde_json::to_string(&receipt.artifacts).unwrap_or_else(|_| "[]".into());
        let identity_json = serde_json::to_string(&receipt.identity).ok();
        connection.execute(
            "INSERT INTO remote_jobs \
               (job_id, mission_id, node_id, kind, state, identity_version, identity_hash, identity_json, \
                submission_sequence, started_at, finished_at, exit_status, artifacts_json, wake_required, \
                wake_delivered_at, wake_suppressed_by, updated_at) \
             VALUES (?1, ?2, ?3, 'remote_build', ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16) \
             ON CONFLICT(job_id) DO UPDATE SET \
               state = excluded.state, finished_at = excluded.finished_at, exit_status = excluded.exit_status, \
               artifacts_json = excluded.artifacts_json, identity_version = excluded.identity_version, \
               identity_hash = excluded.identity_hash, identity_json = excluded.identity_json, \
               wake_required = excluded.wake_required, wake_delivered_at = excluded.wake_delivered_at, \
               wake_suppressed_by = excluded.wake_suppressed_by, updated_at = excluded.updated_at",
            params![
                receipt.job_id.to_string(),
                receipt.mission_id.to_string(),
                receipt.node_id,
                state,
                receipt.identity.version,
                receipt.identity.identity_hash(),
                identity_json,
                receipt.submission_sequence as i64,
                receipt.started_at.to_rfc3339(),
                receipt.finished_at.to_rfc3339(),
                receipt.exit_status,
                artifacts,
                receipt.wake_required as i64,
                receipt.wake_delivered_at.map(|at| at.to_rfc3339()),
                receipt.wake_suppressed_by.map(|id| id.to_string()),
                now,
            ],
        )?;
        // Immutable evidence: one build receipt per job (idempotent).
        let outcome = match state {
            "succeeded" => "succeeded",
            "cancelled" => "cancelled",
            _ => "failed",
        };
        let payload = serde_json::json!({
            "identity": receipt.identity,
            "identity_hash": receipt.identity.identity_hash(),
            "node_id": receipt.node_id,
            "mission_id": receipt.mission_id,
            "exit_status": receipt.exit_status,
            "artifacts": receipt.artifacts,
            "started_at": receipt.started_at,
            "finished_at": receipt.finished_at,
        });
        let request_hash = {
            use sha2::Digest;
            let mut hasher = sha2::Sha256::new();
            hasher.update(payload.to_string().as_bytes());
            hex::encode(hasher.finalize())
        };
        connection.execute(
            "INSERT OR IGNORE INTO receipts \
               (id, idempotency_key, request_hash, kind, project_slug, track_id, criterion_id, subject_type, \
                subject_id, outcome, actor_type, actor_id, verifier, supersedes_receipt_id, observed_at, \
                payload, created_at) \
             VALUES (?1, ?2, ?3, 'build', NULL, NULL, NULL, 'build', ?4, ?5, 'system', ?6, ?7, NULL, ?8, ?9, ?10)",
            params![
                Uuid::new_v4().to_string(),
                format!("build:{}", receipt.job_id),
                request_hash,
                receipt.job_id.to_string(),
                outcome,
                format!("node:{}", receipt.node_id),
                receipt.identity.toolchain,
                receipt.finished_at.to_rfc3339(),
                payload.to_string(),
                now,
            ],
        )?;
        Ok(())
    }

    pub fn mirror_receipt(working_dir: &Path, receipt: &RemoteJobReceipt) {
        let Some(connection) = open(working_dir) else {
            return;
        };
        if let Err(error) = upsert_receipt(&connection, receipt) {
            tracing::warn!(job_id = %receipt.job_id, %error, "remote job SQL mirror: receipt upsert failed");
        }
    }

    /// A mission / tentative handle finalized without a receipt.
    pub fn mirror_terminal_without_receipt(working_dir: &Path, job_id: Uuid, state: &str) {
        let Some(connection) = open(working_dir) else {
            return;
        };
        let state = match state {
            "succeeded" | "failed" | "cancelled" | "lost" => state,
            _ => "failed",
        };
        if let Err(error) = connection.execute(
            "UPDATE remote_jobs SET state = ?2, finished_at = ?3, updated_at = ?3 WHERE job_id = ?1",
            params![job_id.to_string(), state, chrono::Utc::now().to_rfc3339()],
        ) {
            tracing::warn!(%job_id, %error, "remote job SQL mirror: terminal update failed");
        }
    }

    pub fn mirror_remove(working_dir: &Path, job_id: Uuid) {
        let Some(connection) = open(working_dir) else {
            return;
        };
        // Only a still-live row is removed; terminal rows are history.
        if let Err(error) = connection.execute(
            "DELETE FROM remote_jobs WHERE job_id = ?1 AND state IN ('submitting','accepted','running')",
            params![job_id.to_string()],
        ) {
            tracing::warn!(%job_id, %error, "remote job SQL mirror: remove failed");
        }
    }

    pub fn mirror_wake(
        working_dir: &Path,
        job_id: Uuid,
        mission_id: Uuid,
        disposition: &str,
        suppressed_by: Option<Uuid>,
    ) {
        let Some(connection) = open(working_dir) else {
            return;
        };
        let now = chrono::Utc::now().to_rfc3339();
        // The submitter's wake lives on the job row; an attached mission's on
        // its subscriber row.
        let submitter: Option<String> = connection
            .query_row(
                "SELECT mission_id FROM remote_jobs WHERE job_id = ?1",
                params![job_id.to_string()],
                |row| row.get(0),
            )
            .optional()
            .ok()
            .flatten();
        let result = if submitter.as_deref() == Some(mission_id.to_string().as_str()) {
            match disposition {
                "delivered" => connection.execute(
                    "UPDATE remote_jobs SET wake_delivered_at = ?2, updated_at = ?2 WHERE job_id = ?1",
                    params![job_id.to_string(), now],
                ),
                _ => connection.execute(
                    "UPDATE remote_jobs SET wake_suppressed_by = ?2, updated_at = ?3 WHERE job_id = ?1",
                    params![
                        job_id.to_string(),
                        suppressed_by.map(|id| id.to_string()),
                        now
                    ],
                ),
            }
        } else {
            connection.execute(
                "UPDATE remote_job_subscribers SET wake_state = ?3, delivered_at = ?4 \
                 WHERE job_id = ?1 AND mission_id = ?2",
                params![
                    job_id.to_string(),
                    mission_id.to_string(),
                    if disposition == "delivered" {
                        "delivered"
                    } else {
                        "suppressed"
                    },
                    now
                ],
            )
        };
        if let Err(error) = result {
            tracing::warn!(%job_id, %mission_id, %error, "remote job SQL mirror: wake update failed");
        }
    }

    /// Record an attached mission as a durable subscriber of a live job.
    pub fn mirror_subscriber(
        working_dir: &Path,
        job_id: Uuid,
        mission_id: Uuid,
        wake_required: bool,
    ) {
        let Some(connection) = open(working_dir) else {
            return;
        };
        if let Err(error) = connection.execute(
            "INSERT OR IGNORE INTO remote_job_subscribers \
               (job_id, mission_id, wake_required, wake_state, attached_at) \
             VALUES (?1, ?2, ?3, 'pending', ?4)",
            params![
                job_id.to_string(),
                mission_id.to_string(),
                wake_required as i64,
                chrono::Utc::now().to_rfc3339()
            ],
        ) {
            tracing::warn!(%job_id, %mission_id, %error, "remote job SQL mirror: subscriber insert failed");
        }
    }

    #[derive(Debug, Default, Clone, Serialize)]
    pub struct ParityReport {
        pub json_handles: usize,
        pub json_receipts: usize,
        pub sql_live: usize,
        pub sql_terminal: usize,
        pub backfilled_handles: usize,
        pub backfilled_receipts: usize,
        pub sql_live_not_in_json: usize,
    }

    /// Compare the JSON ledger with the mirror and backfill what the mirror
    /// lacks. Live SQL rows with no JSON handle are reported, not deleted:
    /// in the dual-write window the JSON file is the authority and a
    /// disagreement is the signal the removal gate waits on.
    pub fn parity_backfill(
        working_dir: &Path,
        handles: &[JobHandle],
        receipts: &[RemoteJobReceipt],
    ) -> ParityReport {
        let mut report = ParityReport {
            json_handles: handles.len(),
            json_receipts: receipts.len(),
            ..ParityReport::default()
        };
        let Some(connection) = open(working_dir) else {
            return report;
        };
        let exists = |job_id: &Uuid| -> bool {
            connection
                .query_row(
                    "SELECT 1 FROM remote_jobs WHERE job_id = ?1",
                    params![job_id.to_string()],
                    |_| Ok(()),
                )
                .optional()
                .ok()
                .flatten()
                .is_some()
        };
        for handle in handles {
            if !exists(&handle.job_id) && upsert_handle(&connection, handle).is_ok() {
                report.backfilled_handles += 1;
            }
        }
        for receipt in receipts {
            let terminal: Option<String> = connection
                .query_row(
                    "SELECT state FROM remote_jobs WHERE job_id = ?1",
                    params![receipt.job_id.to_string()],
                    |row| row.get(0),
                )
                .optional()
                .ok()
                .flatten();
            let needs = !matches!(
                terminal.as_deref(),
                Some("succeeded" | "failed" | "cancelled" | "lost")
            );
            if needs && upsert_receipt(&connection, receipt).is_ok() {
                report.backfilled_receipts += 1;
            }
        }
        report.sql_live = connection
            .query_row(
                "SELECT count(*) FROM remote_jobs WHERE state IN ('submitting','accepted','running')",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as usize;
        report.sql_terminal = connection
            .query_row(
                "SELECT count(*) FROM remote_jobs WHERE state IN ('succeeded','failed','cancelled','lost')",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as usize;
        let live_ids: Vec<String> = connection
            .prepare(
                "SELECT job_id FROM remote_jobs WHERE state IN ('submitting','accepted','running')",
            )
            .and_then(|mut statement| {
                statement
                    .query_map([], |row| row.get::<_, String>(0))
                    .map(|rows| rows.filter_map(Result::ok).collect())
            })
            .unwrap_or_default();
        report.sql_live_not_in_json = live_ids
            .iter()
            .filter(|id| {
                !handles
                    .iter()
                    .any(|handle| handle.job_id.to_string() == **id)
            })
            .count();
        report
    }
}

/// Boot-time parity pass: mirror anything the JSON ledger has that SQL lacks
/// and report drift. Never deletes.
pub async fn sql_parity_backfill(working_dir: &Path) -> anyhow::Result<sql::ParityReport> {
    let snap = dir_ledger(working_dir).load_snapshot().await?;
    let wd = working_dir.to_path_buf();
    tokio::task::spawn_blocking(move || sql::parity_backfill(&wd, &snap.handles, &snap.receipts))
        .await
        .map_err(|err| anyhow::anyhow!("sql_parity_backfill task failed: {err}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_build_continuation_mode_is_explicit_and_legacy_safe() {
        let base = JobHandle {
            mission_id: Uuid::new_v4(),
            node_id: "node-a".to_string(),
            job_id: Uuid::new_v4(),
            started_at: chrono::Utc::now(),
            submission_sequence: 1,
            accepted_at: Some(chrono::Utc::now()),
            heartbeat_at: Some(chrono::Utc::now()),
            disk_reservation_bytes: 0,
            kind: JobHandleKind::RemoteBuild,
            identity: None,
            wait_for_completion: Some(false),
            wake_on_terminal: false,
        };

        assert!(!base.expects_mission_continuation());
        assert!(JobHandle {
            wait_for_completion: Some(true),
            ..base.clone()
        }
        .expects_mission_continuation());
        assert!(JobHandle {
            wait_for_completion: None,
            ..base.clone()
        }
        .expects_mission_continuation());
        assert!(JobHandle {
            wake_on_terminal: true,
            ..base
        }
        .expects_mission_continuation());
    }

    #[tokio::test]
    async fn record_is_durable_and_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let job_id = Uuid::new_v4();
        let handle = JobHandle {
            mission_id: Uuid::new_v4(),
            node_id: "node-a".to_string(),
            job_id,
            started_at: chrono::Utc::now(),
            submission_sequence: 0,
            accepted_at: Some(chrono::Utc::now()),
            heartbeat_at: Some(chrono::Utc::now()),
            disk_reservation_bytes: 0,
            kind: JobHandleKind::Mission,
            identity: None,
            wait_for_completion: None,
            wake_on_terminal: false,
        };

        record(dir.path(), handle.clone()).await.unwrap();
        record(dir.path(), handle).await.unwrap();
        let handles = load_result(dir.path()).await.unwrap();
        assert_eq!(handles.len(), 1);
        assert_eq!(handles[0].job_id, job_id);
    }

    #[tokio::test]
    async fn record_surfaces_an_unwritable_ledger_path() {
        let dir = tempfile::tempdir().unwrap();
        tokio::fs::write(dir.path().join(".sandboxed-sh"), b"not a directory")
            .await
            .unwrap();
        let result = record(
            dir.path(),
            JobHandle {
                mission_id: Uuid::new_v4(),
                node_id: "node-a".to_string(),
                job_id: Uuid::new_v4(),
                started_at: chrono::Utc::now(),
                submission_sequence: 0,
                accepted_at: Some(chrono::Utc::now()),
                heartbeat_at: Some(chrono::Utc::now()),
                disk_reservation_bytes: 0,
                kind: JobHandleKind::Mission,
                identity: None,
                wait_for_completion: None,
                wake_on_terminal: false,
            },
        )
        .await;
        assert!(result.is_err());
    }

    #[test]
    fn legacy_handles_default_to_mission_kind() {
        let raw = serde_json::json!({
            "mission_id": Uuid::new_v4(),
            "node_id": "node-a",
            "job_id": Uuid::new_v4(),
            "started_at": chrono::Utc::now(),
        });

        let handle: JobHandle = serde_json::from_value(raw).unwrap();

        assert_eq!(handle.kind, JobHandleKind::Mission);
        assert_eq!(handle.submission_sequence, 0);
        assert_eq!(handle.accepted_at, None);
        assert_eq!(handle.heartbeat_at, None);
        assert_eq!(handle.identity, None);
    }

    #[test]
    fn tentative_handles_round_trip() {
        let raw = serde_json::json!({
            "mission_id": Uuid::new_v4(),
            "node_id": "node-a",
            "job_id": Uuid::new_v4(),
            "started_at": chrono::Utc::now(),
            "kind": "tentative",
        });

        let handle: JobHandle = serde_json::from_value(raw).unwrap();

        assert_eq!(handle.kind, JobHandleKind::Tentative);
    }

    #[test]
    fn legacy_validation_identity_keeps_cwd_unknown() {
        let identity: RemoteJobIdentity = serde_json::from_value(serde_json::json!({
            "repository": "https://example.invalid/repo.git",
            "commit": "a".repeat(40),
            "command": ["lake", "build"]
        }))
        .unwrap();

        assert!(!identity.cwd_rel_known);
        assert_eq!(identity.cwd_rel, None);
        assert!(identity.artifacts.is_empty());
    }

    #[tokio::test]
    async fn accepted_handle_replaces_pre_submit_tentative_handle() {
        let dir = tempfile::tempdir().unwrap();
        let job_id = Uuid::new_v4();
        let mission_id = Uuid::new_v4();
        let mut handle = JobHandle {
            mission_id,
            node_id: "node-a".to_string(),
            job_id,
            started_at: chrono::Utc::now(),
            submission_sequence: 0,
            accepted_at: None,
            heartbeat_at: None,
            disk_reservation_bytes: 0,
            kind: JobHandleKind::Tentative,
            identity: None,
            wait_for_completion: None,
            wake_on_terminal: false,
        };
        record(dir.path(), handle.clone()).await.unwrap();

        handle.kind = JobHandleKind::Mission;
        handle.accepted_at = Some(chrono::Utc::now());
        record(dir.path(), handle).await.unwrap();

        let handles = load_result(dir.path()).await.unwrap();
        assert_eq!(handles.len(), 1);
        assert_eq!(handles[0].job_id, job_id);
        assert_eq!(handles[0].kind, JobHandleKind::Mission);
        assert_eq!(handles[0].submission_sequence, 1);
    }

    #[tokio::test]
    async fn heartbeat_advances_only_an_existing_handle() {
        let dir = tempfile::tempdir().unwrap();
        let job_id = Uuid::new_v4();
        let handle = JobHandle {
            mission_id: Uuid::new_v4(),
            node_id: "node-a".to_string(),
            job_id,
            started_at: chrono::Utc::now(),
            submission_sequence: 0,
            accepted_at: Some(chrono::Utc::now()),
            heartbeat_at: None,
            disk_reservation_bytes: 0,
            kind: JobHandleKind::RemoteBuild,
            identity: Some(RemoteJobIdentity {
                version: 0,
                base_tree_sha: None,
                builder_image_digest: None,
                build_protocol_version: None,
                behavior_env_digest: None,
                repository: "https://example.invalid/repo.git".to_string(),
                commit: "a".repeat(40),
                cwd_rel_known: true,
                cwd_rel: None,
                command: vec!["lake".to_string(), "build".to_string()],
                artifacts: Vec::new(),
                toolchain: None,
                source_bundle_digest: None,
            }),
            wait_for_completion: None,
            wake_on_terminal: false,
        };
        record(dir.path(), handle).await.unwrap();

        assert!(heartbeat(dir.path(), job_id).await.unwrap());
        assert!(load_result(dir.path()).await.unwrap()[0]
            .heartbeat_at
            .is_some());
        assert!(!heartbeat(dir.path(), Uuid::new_v4()).await.unwrap());
    }

    #[tokio::test]
    async fn finalization_retains_immutable_remote_validation_receipt() {
        let dir = tempfile::tempdir().unwrap();
        let job_id = Uuid::new_v4();
        let mission_id = Uuid::new_v4();
        let identity = RemoteJobIdentity {
            version: 0,
            base_tree_sha: None,
            builder_image_digest: None,
            build_protocol_version: None,
            behavior_env_digest: None,
            repository: "https://example.invalid/repo.git".to_string(),
            commit: "a".repeat(40),
            cwd_rel_known: true,
            cwd_rel: None,
            command: vec!["lake".to_string(), "build".to_string()],
            artifacts: Vec::new(),
            toolchain: Some("leanprover/lean4:v4.19.0".to_string()),
            source_bundle_digest: Some("b".repeat(64)),
        };
        record(
            dir.path(),
            JobHandle {
                mission_id,
                node_id: "node-a".to_string(),
                job_id,
                started_at: chrono::Utc::now(),
                submission_sequence: 0,
                accepted_at: Some(chrono::Utc::now()),
                heartbeat_at: Some(chrono::Utc::now()),
                disk_reservation_bytes: 0,
                kind: JobHandleKind::RemoteBuild,
                identity: Some(identity.clone()),
                wait_for_completion: None,
                wake_on_terminal: true,
            },
        )
        .await
        .unwrap();

        assert!(finalize(dir.path(), job_id, "succeeded", Some(0))
            .await
            .unwrap());
        assert!(load_result(dir.path()).await.unwrap().is_empty());
        let receipt = terminal_receipt(dir.path(), job_id).await.unwrap().unwrap();
        assert_eq!(receipt.identity, identity);
        assert_eq!(receipt.state, "succeeded");
        assert_eq!(receipt.exit_status, Some(0));
        assert!(receipt.wake_required);
        assert_eq!(receipt.wake_delivered_at, None);
        assert_eq!(pending_terminal_wakes(dir.path()).await.unwrap().len(), 1);
        assert!(
            mark_terminal_wake_delivered(dir.path(), job_id, receipt.mission_id)
                .await
                .unwrap()
        );
        assert!(pending_terminal_wakes(dir.path()).await.unwrap().is_empty());
        assert_eq!(
            terminal_receipts_for_mission(dir.path(), mission_id)
                .await
                .unwrap()
                .len(),
            1
        );
        assert!(terminal_receipts_for_mission(dir.path(), Uuid::new_v4())
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn immutable_validation_lookup_blocks_active_and_reuses_success() {
        let dir = tempfile::tempdir().unwrap();
        let job_id = Uuid::new_v4();
        let identity = RemoteJobIdentity {
            version: IDENTITY_VERSION,
            base_tree_sha: None,
            builder_image_digest: None,
            build_protocol_version: None,
            behavior_env_digest: None,
            repository: "https://example.invalid/repo.git".to_string(),
            commit: "a".repeat(40),
            cwd_rel_known: true,
            cwd_rel: None,
            command: vec!["lake".to_string(), "build".to_string()],
            artifacts: Vec::new(),
            toolchain: Some("leanprover/lean4:v4.24.0".to_string()),
            source_bundle_digest: None,
        };
        record(
            dir.path(),
            JobHandle {
                mission_id: Uuid::new_v4(),
                node_id: "node-a".to_string(),
                job_id,
                started_at: chrono::Utc::now(),
                submission_sequence: 0,
                accepted_at: Some(chrono::Utc::now()),
                heartbeat_at: Some(chrono::Utc::now()),
                disk_reservation_bytes: 0,
                kind: JobHandleKind::RemoteBuild,
                identity: Some(identity.clone()),
                wait_for_completion: None,
                wake_on_terminal: false,
            },
        )
        .await
        .unwrap();

        assert!(matches!(
            equivalent_remote_validation(dir.path(), &identity)
                .await
                .unwrap(),
            Some(EquivalentRemoteValidation::Active(handle)) if handle.job_id == job_id
        ));

        finalize(dir.path(), job_id, "succeeded", Some(0))
            .await
            .unwrap();
        assert!(matches!(
            equivalent_remote_validation(dir.path(), &identity)
                .await
                .unwrap(),
            Some(EquivalentRemoteValidation::Succeeded(receipt)) if receipt.job_id == job_id
        ));

        let changed_cwd = RemoteJobIdentity {
            cwd_rel: Some("subproject".to_string()),
            ..identity.clone()
        };
        assert!(equivalent_remote_validation(dir.path(), &changed_cwd)
            .await
            .unwrap()
            .is_none());

        let artifact_identity = RemoteJobIdentity {
            artifacts: vec!["build/report.json".to_string()],
            ..identity.clone()
        };
        let artifact_job_id = Uuid::new_v4();
        record(
            dir.path(),
            JobHandle {
                mission_id: Uuid::new_v4(),
                node_id: "node-b".to_string(),
                job_id: artifact_job_id,
                started_at: chrono::Utc::now(),
                submission_sequence: 0,
                accepted_at: Some(chrono::Utc::now()),
                heartbeat_at: Some(chrono::Utc::now()),
                disk_reservation_bytes: 0,
                kind: JobHandleKind::RemoteBuild,
                identity: Some(artifact_identity.clone()),
                wait_for_completion: None,
                wake_on_terminal: false,
            },
        )
        .await
        .unwrap();
        finalize_with_artifacts(
            dir.path(),
            artifact_job_id,
            "succeeded",
            Some(0),
            vec![ArtifactEntry {
                path: "build/report.json".to_string(),
                sha256: "c".repeat(64),
                size_bytes: 42,
            }],
        )
        .await
        .unwrap();
        assert!(matches!(
            equivalent_remote_validation(dir.path(), &artifact_identity)
                .await
                .unwrap(),
            Some(EquivalentRemoteValidation::Succeeded(receipt))
                if receipt.job_id == artifact_job_id && receipt.artifacts.len() == 1
        ));

        let changed_overlay = RemoteJobIdentity {
            source_bundle_digest: Some("b".repeat(64)),
            ..identity.clone()
        };
        assert!(equivalent_remote_validation(dir.path(), &changed_overlay)
            .await
            .unwrap()
            .is_none());

        // A forced run bypasses the succeeded receipt, so it must be able to
        // see a concurrent unresolved handle that the combined lookup hides
        // behind receipt precedence.
        let forced_job_id = Uuid::new_v4();
        record(
            dir.path(),
            JobHandle {
                mission_id: Uuid::new_v4(),
                node_id: "node-c".to_string(),
                job_id: forced_job_id,
                started_at: chrono::Utc::now(),
                submission_sequence: 0,
                accepted_at: Some(chrono::Utc::now()),
                heartbeat_at: Some(chrono::Utc::now()),
                disk_reservation_bytes: 0,
                kind: JobHandleKind::RemoteBuild,
                identity: Some(identity.clone()),
                wait_for_completion: None,
                wake_on_terminal: false,
            },
        )
        .await
        .unwrap();
        assert!(matches!(
            equivalent_remote_validation(dir.path(), &identity)
                .await
                .unwrap(),
            Some(EquivalentRemoteValidation::Succeeded(receipt)) if receipt.job_id == job_id
        ));
        assert!(matches!(
            active_equivalent_remote_validation(dir.path(), &identity)
                .await
                .unwrap(),
            Some(handle) if handle.job_id == forced_job_id
        ));
    }

    #[tokio::test]
    async fn newer_validation_suppresses_stale_terminal_wake() {
        let dir = tempfile::tempdir().unwrap();
        let mission_id = Uuid::new_v4();
        let old_job_id = Uuid::new_v4();
        let new_job_id = Uuid::new_v4();
        let old_started_at = chrono::Utc::now() - chrono::Duration::minutes(2);
        let new_started_at = chrono::Utc::now() - chrono::Duration::minutes(1);
        let identity = |commit: char| RemoteJobIdentity {
            version: 0,
            base_tree_sha: None,
            builder_image_digest: None,
            build_protocol_version: None,
            behavior_env_digest: None,
            repository: "https://example.invalid/verity.git".to_string(),
            commit: commit.to_string().repeat(40),
            cwd_rel_known: true,
            cwd_rel: None,
            command: vec!["lake".to_string(), "build".to_string()],
            artifacts: Vec::new(),
            toolchain: Some("leanprover/lean4:v4.24.0".to_string()),
            source_bundle_digest: None,
        };

        record(
            dir.path(),
            JobHandle {
                mission_id,
                node_id: "node-old".to_string(),
                job_id: old_job_id,
                started_at: old_started_at,
                submission_sequence: 0,
                accepted_at: Some(old_started_at),
                heartbeat_at: Some(old_started_at),
                disk_reservation_bytes: 0,
                kind: JobHandleKind::RemoteBuild,
                identity: Some(identity('a')),
                wait_for_completion: None,
                wake_on_terminal: true,
            },
        )
        .await
        .unwrap();
        finalize(dir.path(), old_job_id, "succeeded", Some(0))
            .await
            .unwrap();
        let old_receipt = terminal_receipt(dir.path(), old_job_id)
            .await
            .unwrap()
            .unwrap();

        record(
            dir.path(),
            JobHandle {
                mission_id,
                node_id: "node-new".to_string(),
                job_id: new_job_id,
                started_at: new_started_at,
                submission_sequence: 0,
                accepted_at: Some(new_started_at),
                heartbeat_at: Some(new_started_at),
                disk_reservation_bytes: 0,
                kind: JobHandleKind::RemoteBuild,
                identity: Some(identity('b')),
                wait_for_completion: None,
                wake_on_terminal: false,
            },
        )
        .await
        .unwrap();

        assert_eq!(
            terminal_wake_disposition(dir.path(), &old_receipt)
                .await
                .unwrap(),
            TerminalWakeDisposition::SupersededBy(new_job_id)
        );
        assert!(
            mark_terminal_wake_suppressed(dir.path(), old_job_id, mission_id, new_job_id)
                .await
                .unwrap()
        );
        assert!(pending_terminal_wakes(dir.path()).await.unwrap().is_empty());
        let old_receipt = terminal_receipt(dir.path(), old_job_id)
            .await
            .unwrap()
            .unwrap();
        assert!(old_receipt.wake_delivered_at.is_some());
        assert_eq!(old_receipt.wake_suppressed_by, Some(new_job_id));
    }

    #[tokio::test]
    async fn newer_terminal_validation_prevents_old_handle_from_owning_wait_lease() {
        let dir = tempfile::tempdir().unwrap();
        let mission_id = Uuid::new_v4();
        let old_job_id = Uuid::new_v4();
        let new_job_id = Uuid::new_v4();
        let old_started_at = chrono::Utc::now() - chrono::Duration::minutes(2);
        let new_started_at = chrono::Utc::now() - chrono::Duration::minutes(1);
        let handle = |job_id, started_at| JobHandle {
            mission_id,
            node_id: "node-a".to_string(),
            job_id,
            started_at,
            submission_sequence: 0,
            accepted_at: Some(started_at),
            heartbeat_at: Some(started_at),
            disk_reservation_bytes: 0,
            kind: JobHandleKind::RemoteBuild,
            identity: Some(RemoteJobIdentity {
                version: 0,
                base_tree_sha: None,
                builder_image_digest: None,
                build_protocol_version: None,
                behavior_env_digest: None,
                repository: "https://example.invalid/verity.git".to_string(),
                commit: job_id.to_string(),
                cwd_rel_known: true,
                cwd_rel: None,
                command: vec!["lake".to_string(), "build".to_string()],
                artifacts: Vec::new(),
                toolchain: None,
                source_bundle_digest: None,
            }),
            wait_for_completion: None,
            wake_on_terminal: true,
        };

        record(dir.path(), handle(old_job_id, old_started_at))
            .await
            .unwrap();
        record(dir.path(), handle(new_job_id, new_started_at))
            .await
            .unwrap();
        assert_eq!(
            current_remote_build_wait_handle(dir.path(), mission_id)
                .await
                .unwrap()
                .map(|handle| handle.job_id),
            Some(new_job_id)
        );

        finalize(dir.path(), new_job_id, "succeeded", Some(0))
            .await
            .unwrap();
        assert!(
            current_remote_build_wait_handle(dir.path(), mission_id)
                .await
                .unwrap()
                .is_none(),
            "an older live job is evidence only after a newer validation is terminal"
        );
    }

    #[tokio::test]
    async fn fire_and_forget_validation_never_supersedes_a_continuation_owner() {
        let dir = tempfile::tempdir().unwrap();
        let mission_id = Uuid::new_v4();
        let continuation_job_id = Uuid::new_v4();
        let detached_job_id = Uuid::new_v4();
        let identity = |commit: char| RemoteJobIdentity {
            version: 0,
            base_tree_sha: None,
            builder_image_digest: None,
            build_protocol_version: None,
            behavior_env_digest: None,
            repository: "https://example.invalid/verity.git".to_string(),
            commit: commit.to_string().repeat(40),
            cwd_rel_known: true,
            cwd_rel: None,
            command: vec!["lake".to_string(), "build".to_string()],
            artifacts: Vec::new(),
            toolchain: None,
            source_bundle_digest: None,
        };
        let continuation_started_at = chrono::Utc::now() - chrono::Duration::minutes(2);
        record(
            dir.path(),
            JobHandle {
                mission_id,
                node_id: "node-a".to_string(),
                job_id: continuation_job_id,
                started_at: continuation_started_at,
                submission_sequence: 0,
                accepted_at: Some(continuation_started_at),
                heartbeat_at: Some(continuation_started_at),
                disk_reservation_bytes: 0,
                kind: JobHandleKind::RemoteBuild,
                identity: Some(identity('a')),
                wait_for_completion: Some(true),
                wake_on_terminal: true,
            },
        )
        .await
        .unwrap();
        let detached_started_at = chrono::Utc::now() - chrono::Duration::minutes(1);
        record(
            dir.path(),
            JobHandle {
                mission_id,
                node_id: "node-b".to_string(),
                job_id: detached_job_id,
                started_at: detached_started_at,
                submission_sequence: 0,
                accepted_at: Some(detached_started_at),
                heartbeat_at: Some(detached_started_at),
                disk_reservation_bytes: 0,
                kind: JobHandleKind::RemoteBuild,
                identity: Some(identity('b')),
                wait_for_completion: Some(false),
                wake_on_terminal: false,
            },
        )
        .await
        .unwrap();
        finalize(dir.path(), detached_job_id, "succeeded", Some(0))
            .await
            .unwrap();

        assert_eq!(
            current_remote_build_wait_handle(dir.path(), mission_id)
                .await
                .unwrap()
                .map(|handle| handle.job_id),
            Some(continuation_job_id),
            "detached terminal evidence must not hide the live continuation owner"
        );

        finalize(dir.path(), continuation_job_id, "succeeded", Some(0))
            .await
            .unwrap();
        let continuation_receipt = load_receipts_result(dir.path())
            .await
            .unwrap()
            .into_iter()
            .find(|receipt| receipt.job_id == continuation_job_id)
            .unwrap();
        assert_eq!(
            terminal_wake_disposition(dir.path(), &continuation_receipt)
                .await
                .unwrap(),
            TerminalWakeDisposition::Ready,
            "a newer detached receipt must not suppress the owning terminal wake"
        );
    }

    #[tokio::test]
    async fn submission_sequence_breaks_equal_timestamp_ties_without_using_uuid_order() {
        let dir = tempfile::tempdir().unwrap();
        let mission_id = Uuid::new_v4();
        let old_job_id = Uuid::parse_str("ffffffff-ffff-ffff-ffff-ffffffffffff").unwrap();
        let new_job_id = Uuid::parse_str("00000000-0000-0000-0000-000000000001").unwrap();
        let started_at = chrono::Utc::now();
        let handle = |job_id| JobHandle {
            mission_id,
            node_id: "node-a".to_string(),
            job_id,
            started_at,
            submission_sequence: 0,
            accepted_at: Some(started_at),
            heartbeat_at: Some(started_at),
            disk_reservation_bytes: 0,
            kind: JobHandleKind::RemoteBuild,
            identity: None,
            wait_for_completion: None,
            wake_on_terminal: true,
        };

        record(dir.path(), handle(old_job_id)).await.unwrap();
        record(dir.path(), handle(new_job_id)).await.unwrap();

        let handles = load(dir.path()).await.unwrap();
        let old_sequence = handles
            .iter()
            .find(|handle| handle.job_id == old_job_id)
            .unwrap()
            .submission_sequence;
        let new_sequence = handles
            .iter()
            .find(|handle| handle.job_id == new_job_id)
            .unwrap()
            .submission_sequence;
        assert!(new_sequence > old_sequence);
        assert_eq!(
            current_remote_build_wait_handle(dir.path(), mission_id)
                .await
                .unwrap()
                .map(|handle| handle.job_id),
            Some(new_job_id)
        );
    }

    #[tokio::test]
    async fn newer_terminal_wake_is_not_blocked_by_an_older_active_validation() {
        let dir = tempfile::tempdir().unwrap();
        let mission_id = Uuid::new_v4();
        let active_job_id = Uuid::new_v4();
        let receipt_job_id = Uuid::new_v4();
        let active_started_at = chrono::Utc::now() - chrono::Duration::minutes(2);
        let receipt_started_at = chrono::Utc::now() - chrono::Duration::minutes(1);
        let identity = RemoteJobIdentity {
            version: 0,
            base_tree_sha: None,
            builder_image_digest: None,
            build_protocol_version: None,
            behavior_env_digest: None,
            repository: "https://example.invalid/verity.git".to_string(),
            commit: "a".repeat(40),
            cwd_rel_known: true,
            cwd_rel: None,
            command: vec!["lake".to_string(), "build".to_string()],
            artifacts: Vec::new(),
            toolchain: None,
            source_bundle_digest: None,
        };
        for (job_id, started_at, wake_on_terminal) in [
            (active_job_id, active_started_at, false),
            (receipt_job_id, receipt_started_at, true),
        ] {
            record(
                dir.path(),
                JobHandle {
                    mission_id,
                    node_id: "node-a".to_string(),
                    job_id,
                    started_at,
                    submission_sequence: 0,
                    accepted_at: Some(started_at),
                    heartbeat_at: Some(started_at),
                    disk_reservation_bytes: 0,
                    kind: JobHandleKind::RemoteBuild,
                    identity: Some(identity.clone()),
                    wait_for_completion: None,
                    wake_on_terminal,
                },
            )
            .await
            .unwrap();
        }
        finalize(dir.path(), receipt_job_id, "succeeded", Some(0))
            .await
            .unwrap();
        let receipt = terminal_receipt(dir.path(), receipt_job_id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            terminal_wake_disposition(dir.path(), &receipt)
                .await
                .unwrap(),
            TerminalWakeDisposition::Ready
        );
        assert_eq!(pending_terminal_wakes(dir.path()).await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn newer_tentative_submission_defers_without_suppressing_wake() {
        let dir = tempfile::tempdir().unwrap();
        let mission_id = Uuid::new_v4();
        let receipt_job_id = Uuid::new_v4();
        let tentative_job_id = Uuid::new_v4();
        let old_started_at = chrono::Utc::now() - chrono::Duration::minutes(2);
        let new_started_at = chrono::Utc::now() - chrono::Duration::minutes(1);
        let identity = RemoteJobIdentity {
            version: 0,
            base_tree_sha: None,
            builder_image_digest: None,
            build_protocol_version: None,
            behavior_env_digest: None,
            repository: "https://example.invalid/verity.git".to_string(),
            commit: "a".repeat(40),
            cwd_rel_known: true,
            cwd_rel: None,
            command: vec!["lake".to_string(), "build".to_string()],
            artifacts: Vec::new(),
            toolchain: None,
            source_bundle_digest: None,
        };
        record(
            dir.path(),
            JobHandle {
                mission_id,
                node_id: "node-old".to_string(),
                job_id: receipt_job_id,
                started_at: old_started_at,
                submission_sequence: 0,
                accepted_at: Some(old_started_at),
                heartbeat_at: Some(old_started_at),
                disk_reservation_bytes: 0,
                kind: JobHandleKind::RemoteBuild,
                identity: Some(identity.clone()),
                wait_for_completion: None,
                wake_on_terminal: true,
            },
        )
        .await
        .unwrap();
        finalize(dir.path(), receipt_job_id, "succeeded", Some(0))
            .await
            .unwrap();
        record(
            dir.path(),
            JobHandle {
                mission_id,
                node_id: "node-new".to_string(),
                job_id: tentative_job_id,
                started_at: new_started_at,
                submission_sequence: 0,
                accepted_at: None,
                heartbeat_at: None,
                disk_reservation_bytes: 0,
                kind: JobHandleKind::Tentative,
                identity: Some(identity),
                wait_for_completion: None,
                wake_on_terminal: false,
            },
        )
        .await
        .unwrap();

        let receipt = terminal_receipt(dir.path(), receipt_job_id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            terminal_wake_disposition(dir.path(), &receipt)
                .await
                .unwrap(),
            TerminalWakeDisposition::Deferred
        );
        assert_eq!(pending_terminal_wakes(dir.path()).await.unwrap().len(), 1);
        assert_eq!(receipt.wake_suppressed_by, None);
    }

    #[tokio::test]
    async fn terminal_tentative_handle_never_becomes_validation_receipt() {
        let dir = tempfile::tempdir().unwrap();
        let mission_id = Uuid::new_v4();
        let job_id = Uuid::new_v4();
        let now = chrono::Utc::now();
        record(
            dir.path(),
            JobHandle {
                mission_id,
                node_id: "node-a".to_string(),
                job_id,
                started_at: now,
                submission_sequence: 0,
                accepted_at: None,
                heartbeat_at: None,
                disk_reservation_bytes: 0,
                kind: JobHandleKind::Tentative,
                identity: Some(RemoteJobIdentity {
                    version: 0,
                    base_tree_sha: None,
                    builder_image_digest: None,
                    build_protocol_version: None,
                    behavior_env_digest: None,
                    repository: "https://example.invalid/verity.git".to_string(),
                    commit: "a".repeat(40),
                    cwd_rel_known: true,
                    cwd_rel: None,
                    command: vec!["lake".to_string(), "build".to_string()],
                    artifacts: Vec::new(),
                    toolchain: None,
                    source_bundle_digest: None,
                }),
                wait_for_completion: None,
                wake_on_terminal: false,
            },
        )
        .await
        .unwrap();

        assert!(finalize(dir.path(), job_id, "lost", None).await.is_err());
        assert_eq!(load_result(dir.path()).await.unwrap().len(), 1);
        assert!(finalize(dir.path(), job_id, "cancelled", None)
            .await
            .unwrap());
        assert!(load_result(dir.path()).await.unwrap().is_empty());
        assert!(terminal_receipt(dir.path(), job_id)
            .await
            .unwrap()
            .is_none());
        assert!(terminal_receipts_for_mission(dir.path(), mission_id)
            .await
            .unwrap()
            .is_empty());
    }

    fn identity_v1(commit: &str, tree: Option<&str>) -> RemoteJobIdentity {
        RemoteJobIdentity {
            version: IDENTITY_VERSION,
            repository: "github.com/lfglabs-dev/verity".to_string(),
            commit: commit.to_string(),
            base_tree_sha: tree.map(str::to_string),
            cwd_rel_known: true,
            cwd_rel: Some("verity".to_string()),
            command: vec!["lake".to_string(), "build".to_string()],
            artifacts: vec!["b.olean".to_string(), "a.olean".to_string()],
            toolchain: Some("leanprover/lean4:v4.19.0".to_string()),
            source_bundle_digest: None,
            builder_image_digest: None,
            build_protocol_version: Some("1".to_string()),
            behavior_env_digest: None,
        }
    }

    #[test]
    fn identity_hash_is_content_not_commit_and_every_input_matters() {
        let tree = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        let a = identity_v1("a".repeat(40).as_str(), Some(tree));
        let b = identity_v1("b".repeat(40).as_str(), Some(tree));
        assert_eq!(
            a.identity_hash(),
            b.identity_hash(),
            "same tree, different commit: same build"
        );
        assert!(a.reusable_for(&b));
        assert!(a.excludes(&b));

        let other_tree = identity_v1("a".repeat(40).as_str(), Some(&"f".repeat(64)));
        assert_ne!(a.identity_hash(), other_tree.identity_hash());

        let mut env = a.clone();
        env.behavior_env_digest = Some("abc".into());
        assert_ne!(a.identity_hash(), env.identity_hash());
        let mut image = a.clone();
        image.builder_image_digest = Some("sha256:1".into());
        assert_ne!(a.identity_hash(), image.identity_hash());
        let mut argv = a.clone();
        argv.command = vec!["lake".into(), "build".into(), "-K".into()];
        assert_ne!(a.identity_hash(), argv.identity_hash());
        let mut sorted = a.clone();
        sorted.artifacts = vec!["a.olean".into(), "b.olean".into()];
        assert_eq!(
            a.identity_hash(),
            sorted.identity_hash(),
            "artifact order is not identity"
        );

        // No tree: the commit is the content.
        let c1 = identity_v1("c".repeat(40).as_str(), None);
        let c2 = identity_v1("d".repeat(40).as_str(), None);
        assert_ne!(c1.identity_hash(), c2.identity_hash());
    }

    #[test]
    fn legacy_v0_receipts_never_replay_but_still_exclude() {
        let mut legacy = identity_v1("a".repeat(40).as_str(), None);
        legacy.version = 0;
        legacy.base_tree_sha = None;
        legacy.build_protocol_version = None;
        let current = identity_v1("a".repeat(40).as_str(), Some(&"e".repeat(64)));
        assert!(
            !legacy.reusable_for(&current),
            "a pre-upgrade success is not evidence for v1"
        );
        assert!(
            !legacy.reusable_for(&legacy),
            "v0 never replays, even against itself"
        );
        let mut current_same_fields = current.clone();
        current_same_fields.build_protocol_version = None;
        assert!(
            legacy.excludes(&current_same_fields),
            "an in-flight v0 job still blocks a v1 duplicate"
        );
        let mut other_cwd = current_same_fields.clone();
        other_cwd.cwd_rel = Some("elsewhere".into());
        assert!(!legacy.excludes(&other_cwd));
    }

    #[tokio::test]
    async fn sql_mirror_tracks_handles_receipts_and_backfills() {
        let dir = tempfile::tempdir().unwrap();
        let job_id = Uuid::new_v4();
        let mission_id = Uuid::new_v4();
        let identity = identity_v1("a".repeat(40).as_str(), Some(&"e".repeat(64)));
        record(
            dir.path(),
            JobHandle {
                mission_id,
                node_id: "spark".to_string(),
                job_id,
                started_at: chrono::Utc::now(),
                submission_sequence: 0,
                accepted_at: Some(chrono::Utc::now()),
                heartbeat_at: None,
                disk_reservation_bytes: 0,
                kind: JobHandleKind::RemoteBuild,
                identity: Some(identity.clone()),
                wait_for_completion: Some(true),
                wake_on_terminal: true,
            },
        )
        .await
        .unwrap();
        let db = dir.path().join(".sandboxed-sh/projects.db");
        let connection = rusqlite::Connection::open(&db).unwrap();
        let (state, hash): (String, String) = connection
            .query_row(
                "SELECT state, identity_hash FROM remote_jobs WHERE job_id = ?1",
                rusqlite::params![job_id.to_string()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(state, "accepted");
        assert_eq!(hash, identity.identity_hash());

        // A second live job with the same identity trips the unique index in
        // SQL (logged, not fatal in the dual-write window).
        let duplicate = Uuid::new_v4();
        sql::mirror_handle(
            dir.path(),
            &JobHandle {
                mission_id: Uuid::new_v4(),
                node_id: "spark".to_string(),
                job_id: duplicate,
                started_at: chrono::Utc::now(),
                submission_sequence: 0,
                accepted_at: Some(chrono::Utc::now()),
                heartbeat_at: None,
                disk_reservation_bytes: 0,
                kind: JobHandleKind::RemoteBuild,
                identity: Some(identity.clone()),
                wait_for_completion: None,
                wake_on_terminal: false,
            },
        );
        let live: i64 = connection
            .query_row(
                "SELECT count(*) FROM remote_jobs WHERE state IN ('submitting','accepted','running')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(live, 1, "the unique index keeps one live job per identity");

        finalize(dir.path(), job_id, "succeeded", Some(0))
            .await
            .unwrap();
        let (state, outcome): (String, String) = connection
            .query_row(
                "SELECT j.state, r.outcome FROM remote_jobs j \
                 JOIN receipts r ON r.subject_type = 'build' AND r.subject_id = j.job_id \
                 WHERE j.job_id = ?1",
                rusqlite::params![job_id.to_string()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(
            (state.as_str(), outcome.as_str()),
            ("succeeded", "succeeded")
        );

        // Wipe the mirror; the boot parity pass rebuilds it from JSON.
        connection.execute("DELETE FROM remote_jobs", []).unwrap();
        let report = sql_parity_backfill(dir.path()).await.unwrap();
        assert_eq!(report.json_receipts, 1);
        assert_eq!(report.backfilled_receipts, 1);
        assert_eq!(report.sql_terminal, 1);
        assert_eq!(report.sql_live_not_in_json, 0);
        let again = sql_parity_backfill(dir.path()).await.unwrap();
        assert_eq!(again.backfilled_receipts, 0, "parity is idempotent");
    }

    #[tokio::test]
    async fn attached_missions_get_their_own_receipts_and_wakes() {
        let dir = tempfile::tempdir().unwrap();
        let job_id = Uuid::new_v4();
        let submitter = Uuid::new_v4();
        let attacher = Uuid::new_v4();
        let identity = identity_v1("a".repeat(40).as_str(), Some(&"e".repeat(64)));
        record(
            dir.path(),
            JobHandle {
                mission_id: submitter,
                node_id: "spark".to_string(),
                job_id,
                started_at: chrono::Utc::now(),
                submission_sequence: 0,
                accepted_at: Some(chrono::Utc::now()),
                heartbeat_at: None,
                disk_reservation_bytes: 0,
                kind: JobHandleKind::RemoteBuild,
                identity: Some(identity.clone()),
                wait_for_completion: Some(true),
                wake_on_terminal: true,
            },
        )
        .await
        .unwrap();
        assert!(attach(dir.path(), Uuid::new_v4(), attacher, true)
            .await
            .unwrap()
            .is_none());
        let attached = attach(dir.path(), job_id, attacher, true)
            .await
            .unwrap()
            .expect("attached");
        assert_eq!(attached.mission_id, attacher);
        assert_eq!(attached.job_id, job_id);
        assert!(!attached.wake_on_terminal);
        // Idempotent.
        attach(dir.path(), job_id, attacher, true).await.unwrap();
        assert_eq!(load(dir.path()).await.unwrap().len(), 2);
        assert!(mission_subscribed(dir.path(), job_id, attacher)
            .await
            .unwrap());
        assert!(!mission_subscribed(dir.path(), job_id, Uuid::new_v4())
            .await
            .unwrap());
        // The attacher parks on the same job.
        let wait = current_remote_build_wait_handle(dir.path(), attacher)
            .await
            .unwrap()
            .expect("attached wait handle");
        assert_eq!(wait.job_id, job_id);
        assert!(require_terminal_wake(dir.path(), job_id, attacher)
            .await
            .unwrap());
        // One execution, one receipt per subscribed mission, each with its own wake.
        finalize(dir.path(), job_id, "succeeded", Some(0))
            .await
            .unwrap();
        assert!(load(dir.path()).await.unwrap().is_empty());
        let pending = pending_terminal_wakes(dir.path()).await.unwrap();
        let mut waiting: Vec<Uuid> = pending.iter().map(|r| r.mission_id).collect();
        waiting.sort();
        let mut expected = vec![submitter, attacher];
        expected.sort();
        assert_eq!(waiting, expected);
        assert!(mark_terminal_wake_delivered(dir.path(), job_id, attacher)
            .await
            .unwrap());
        let still: Vec<Uuid> = pending_terminal_wakes(dir.path())
            .await
            .unwrap()
            .iter()
            .map(|r| r.mission_id)
            .collect();
        assert_eq!(
            still,
            vec![submitter],
            "the submitter's wake is independent"
        );
        assert!(terminal_receipt_for_mission(dir.path(), job_id, attacher)
            .await
            .unwrap()
            .is_some());
        // SQL mirror: one job row, one subscriber row.
        let db = dir.path().join(".sandboxed-sh/projects.db");
        let connection = rusqlite::Connection::open(&db).unwrap();
        let jobs: i64 = connection
            .query_row("SELECT count(*) FROM remote_jobs", [], |r| r.get(0))
            .unwrap();
        let subs: (i64, String) = connection
            .query_row(
                "SELECT count(*), COALESCE(MAX(wake_state), '') FROM remote_job_subscribers WHERE job_id = ?1",
                rusqlite::params![job_id.to_string()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(jobs, 1);
        assert_eq!(subs, (1, "delivered".to_string()));
    }
}
