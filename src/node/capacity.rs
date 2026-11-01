//! Live-resizable node admission (`SANDBOXED_NODE_CAPACITY`,
//! `SANDBOXED_NODE_SIDE_CAPACITY`, `SANDBOXED_NODE_COORDINATOR_CAPACITY`),
//! disk floor (`SANDBOXED_NODE_MIN_FREE_GB`), persistent operator override
//! (`<work_root>/capacity_override.json`), and the env-file reload that drives them.
//!
//! A restart of `sandboxed-node` retires every running job, so capacity
//! changes are applied in place instead: on `SIGHUP`, via `POST /capacity`, or
//! when the env file's mtime changes, the node resizes its pools via the
//! verified `orb_node_resize_step` kernel.
//!
//! * Grow: permits are added immediately (after cancelling any outstanding
//!   shrink debt).
//! * Shrink: idle permits are forgotten immediately; the rest becomes *debt*
//!   that is paid by forgetting permits as running jobs release them. No new
//!   job is admitted until the running count is under the new cap, and no
//!   running job is ever interrupted.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};
use tokio::sync::{AcquireError, OwnedSemaphorePermit, Semaphore, TryAcquireError};

/// Default env file written by node enrollment.
pub const DEFAULT_ENV_FILE: &str = "/etc/sandboxed-node.env";
/// Persistent runtime override written by live operator capacity updates.
pub const CAPACITY_OVERRIDE_FILENAME: &str = "capacity_override.json";
/// How often the env file mtime is polled when no `SIGHUP` arrives.
pub const POLL_INTERVAL: Duration = Duration::from_secs(30);

/// Maximum main-slot capacity accepted via live operator resize (`POST /capacity`).
pub const MAX_NODE_CAPACITY: u32 = 256;
/// Default side-question lane width when unset or out of range.
pub const DEFAULT_SIDE_CAPACITY: usize = 2;
/// Default coordinator / `schedule_wakeup` priority lane width (`1..=16`).
pub const DEFAULT_COORDINATOR_CAPACITY: usize = 2;
/// Default node free-disk floor in GiB (`SANDBOXED_NODE_MIN_FREE_GB`).
pub const DEFAULT_MIN_FREE_GB: u64 = 10;

const UNSET_MIN_FREE_GB: u64 = u64::MAX;

/// Current main-slot capacity, read by the per-job memory budget.
static CURRENT_CAPACITY: AtomicU32 = AtomicU32::new(0);
/// Current side-question capacity, read by the per-job memory budget.
static CURRENT_SIDE_CAPACITY: AtomicUsize = AtomicUsize::new(0);
/// Current coordinator priority-lane capacity.
static CURRENT_COORDINATOR_CAPACITY: AtomicUsize = AtomicUsize::new(0);
/// Current free-disk floor in GiB (`u64::MAX` until published by `for_process`).
static CURRENT_MIN_FREE_GB: AtomicU64 = AtomicU64::new(UNSET_MIN_FREE_GB);

/// Live main capacity (falls back to the process environment before the node
/// has published one).
pub fn current_capacity() -> u32 {
    match CURRENT_CAPACITY.load(Ordering::Acquire) {
        0 => parse_capacity(std::env::var("SANDBOXED_NODE_CAPACITY").ok().as_deref())
            .ok()
            .flatten()
            .unwrap_or(1),
        n => n,
    }
}

/// Live side-question capacity.
pub fn current_side_capacity() -> usize {
    match CURRENT_SIDE_CAPACITY.load(Ordering::Acquire) {
        0 => parse_side_capacity(
            std::env::var("SANDBOXED_NODE_SIDE_CAPACITY")
                .ok()
                .as_deref(),
        ),
        n => n,
    }
}

/// Live coordinator priority-lane capacity (`SANDBOXED_NODE_COORDINATOR_CAPACITY`, default 2).
pub fn current_coordinator_capacity() -> usize {
    match CURRENT_COORDINATOR_CAPACITY.load(Ordering::Acquire) {
        0 => parse_coordinator_capacity(
            std::env::var("SANDBOXED_NODE_COORDINATOR_CAPACITY")
                .ok()
                .as_deref(),
        ),
        n => n,
    }
}

/// Live free-disk floor in GiB (`SANDBOXED_NODE_MIN_FREE_GB`, default 10).
pub fn current_min_free_gb() -> u64 {
    match CURRENT_MIN_FREE_GB.load(Ordering::Acquire) {
        UNSET_MIN_FREE_GB => {
            parse_min_free_gb(std::env::var("SANDBOXED_NODE_MIN_FREE_GB").ok().as_deref())
                .ok()
                .flatten()
                .unwrap_or(DEFAULT_MIN_FREE_GB)
        }
        gb => gb,
    }
}

/// Live free-disk floor in bytes.
pub fn current_min_free_bytes() -> u64 {
    current_min_free_gb().saturating_mul(1 << 30)
}

pub(crate) fn publish_capacities(capacity: u32, side: usize) {
    CURRENT_CAPACITY.store(capacity.max(1), Ordering::Release);
    CURRENT_SIDE_CAPACITY.store(side.max(1), Ordering::Release);
}

fn publish_coordinator_capacity(coordinator: usize) {
    CURRENT_COORDINATOR_CAPACITY.store(coordinator.max(1), Ordering::Release);
}

fn publish_min_free_gb(min_free_gb: u64) {
    CURRENT_MIN_FREE_GB.store(min_free_gb, Ordering::Release);
}

/// `SANDBOXED_NODE_CAPACITY`: unset → `Ok(None)`; otherwise a positive integer.
pub fn parse_capacity(raw: Option<&str>) -> anyhow::Result<Option<u32>> {
    match raw {
        None => Ok(None),
        Some(raw) => raw
            .trim()
            .parse::<u32>()
            .ok()
            .filter(|capacity| *capacity > 0)
            .map(Some)
            .ok_or_else(|| anyhow::anyhow!("SANDBOXED_NODE_CAPACITY must be a positive integer")),
    }
}

/// `SANDBOXED_NODE_SIDE_CAPACITY`: 1..=16, default 2.
pub fn parse_side_capacity(raw: Option<&str>) -> usize {
    raw.and_then(|v| v.trim().parse::<usize>().ok())
        .filter(|n| (1..=16).contains(n))
        .unwrap_or(DEFAULT_SIDE_CAPACITY)
}

/// `SANDBOXED_NODE_COORDINATOR_CAPACITY`: 1..=16, default 2.
pub fn parse_coordinator_capacity(raw: Option<&str>) -> usize {
    raw.and_then(|v| v.trim().parse::<usize>().ok())
        .filter(|n| (1..=16).contains(n))
        .unwrap_or(DEFAULT_COORDINATOR_CAPACITY)
}

/// `SANDBOXED_NODE_MIN_FREE_GB`: unset → `Ok(None)`; otherwise a non-negative integer (`0` allowed).
pub fn parse_min_free_gb(raw: Option<&str>) -> anyhow::Result<Option<u64>> {
    match raw {
        None => Ok(None),
        Some(raw) => raw.trim().parse::<u64>().map(Some).map_err(|_| {
            anyhow::anyhow!("SANDBOXED_NODE_MIN_FREE_GB must be a non-negative integer")
        }),
    }
}

/// Capacities parsed from an env file or live operator update.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capacities {
    pub capacity: u32,
    pub side_capacity: usize,
    pub coordinator_capacity: usize,
    pub min_free_gb: u64,
}

/// Persistent runtime override written under `<work_root>/capacity_override.json`
/// when an operator updates capacity from Orb's `Machines` page.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CapacityOverride {
    pub capacity: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coordinator_capacity: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub side_capacity: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_free_gb: Option<u64>,
    pub updated_at: String,
}

/// Path to the persistent operator override file inside `work_root`.
pub fn override_file_path(work_root: &Path) -> PathBuf {
    work_root.join(CAPACITY_OVERRIDE_FILENAME)
}

/// Atomically persist `ov` to `<work_root>/capacity_override.json`.
pub fn write_capacity_override(work_root: &Path, ov: &CapacityOverride) -> anyhow::Result<()> {
    std::fs::create_dir_all(work_root)
        .map_err(|e| anyhow::anyhow!("create {}: {e}", work_root.display()))?;
    let path = override_file_path(work_root);
    let tmp = work_root.join(format!(
        ".{}.{}.tmp",
        CAPACITY_OVERRIDE_FILENAME,
        std::process::id()
    ));
    let mut bytes = serde_json::to_vec_pretty(ov)?;
    bytes.push(b'\n');
    std::fs::write(&tmp, &bytes).map_err(|e| anyhow::anyhow!("write {}: {e}", tmp.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, &path)
        .map_err(|e| anyhow::anyhow!("rename {} -> {}: {e}", tmp.display(), path.display()))?;
    Ok(())
}

/// Read `<work_root>/capacity_override.json` if present.
pub fn read_capacity_override(path: &Path) -> anyhow::Result<Option<CapacityOverride>> {
    match std::fs::read_to_string(path) {
        Ok(raw) => {
            let parsed: CapacityOverride = serde_json::from_str(&raw)
                .map_err(|e| anyhow::anyhow!("parse {}: {e}", path.display()))?;
            if parsed.capacity == 0 || parsed.capacity > MAX_NODE_CAPACITY {
                anyhow::bail!(
                    "capacity override {} out of bounds (1..={})",
                    parsed.capacity,
                    MAX_NODE_CAPACITY
                );
            }
            Ok(Some(parsed))
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(anyhow::anyhow!("read {}: {err}", path.display())),
    }
}

/// Minimal systemd `EnvironmentFile=` parser: `KEY=value` lines, optional
/// `export ` prefix, `#`/`;` comments, single or double quotes.
pub fn parse_env_file(content: &str) -> Vec<(String, String)> {
    content
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
                return None;
            }
            let line = line.strip_prefix("export ").unwrap_or(line);
            let (key, value) = line.split_once('=')?;
            let key = key.trim();
            if key.is_empty() {
                return None;
            }
            let value = value.trim();
            let value = value
                .strip_prefix('"')
                .and_then(|v| v.strip_suffix('"'))
                .or_else(|| value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
                .unwrap_or(value);
            Some((key.to_string(), value.to_string()))
        })
        .collect()
}

/// Capacities from env-file content. A missing key keeps `fallback` (the
/// running value, which may come from the unit's `Environment=`); a malformed
/// capacity is an error and the running values are kept.
pub fn capacities_from_env_content(
    content: &str,
    fallback: Capacities,
) -> anyhow::Result<Capacities> {
    let vars = parse_env_file(content);
    let get = |key: &str| {
        vars.iter()
            .rev()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    };
    Ok(Capacities {
        capacity: parse_capacity(get("SANDBOXED_NODE_CAPACITY"))?.unwrap_or(fallback.capacity),
        side_capacity: get("SANDBOXED_NODE_SIDE_CAPACITY")
            .map(|raw| parse_side_capacity(Some(raw)))
            .unwrap_or(fallback.side_capacity),
        coordinator_capacity: get("SANDBOXED_NODE_COORDINATOR_CAPACITY")
            .map(|raw| parse_coordinator_capacity(Some(raw)))
            .unwrap_or(fallback.coordinator_capacity),
        min_free_gb: parse_min_free_gb(get("SANDBOXED_NODE_MIN_FREE_GB"))?
            .unwrap_or(fallback.min_free_gb),
    })
}

/// A semaphore whose size can change while permits are held.
pub struct Admission {
    semaphore: Arc<Semaphore>,
    state: Mutex<AdmissionState>,
}

#[derive(Debug)]
struct AdmissionState {
    capacity: usize,
    /// Permits still to be retired as holders release them.
    debt: usize,
}

/// A held admission slot. On drop it is either returned to the pool or, while
/// a shrink is outstanding, retired.
pub struct AdmissionPermit {
    permit: Option<OwnedSemaphorePermit>,
    admission: Arc<Admission>,
}

impl Drop for AdmissionPermit {
    fn drop(&mut self) {
        if let Some(permit) = self.permit.take() {
            let mut state = self.admission.lock();
            if state.debt > 0 {
                state.debt -= 1;
                permit.forget();
            }
            // else: dropping returns the permit to the semaphore.
        }
    }
}

impl Admission {
    pub fn new(capacity: usize) -> Arc<Self> {
        Arc::new(Self {
            semaphore: Arc::new(Semaphore::new(capacity)),
            state: Mutex::new(AdmissionState { capacity, debt: 0 }),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, AdmissionState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Configured (target) capacity.
    pub fn capacity(&self) -> usize {
        self.lock().capacity
    }

    /// Outstanding shrink debt waiting for running jobs to release permits.
    pub fn debt(&self) -> usize {
        self.lock().debt
    }

    /// Free slots under the current target (0 while a shrink is draining).
    pub fn available_permits(&self) -> usize {
        self.semaphore.available_permits()
    }

    /// Slots in use, possibly above `capacity()` while a shrink drains.
    pub fn in_use(&self) -> usize {
        let state = self.lock();
        (state.capacity + state.debt).saturating_sub(self.semaphore.available_permits())
    }

    pub async fn acquire_owned(self: &Arc<Self>) -> Result<AdmissionPermit, AcquireError> {
        let permit = Arc::clone(&self.semaphore).acquire_owned().await?;
        Ok(AdmissionPermit {
            permit: Some(permit),
            admission: Arc::clone(self),
        })
    }

    pub fn try_acquire_owned(self: &Arc<Self>) -> Result<AdmissionPermit, TryAcquireError> {
        let permit = Arc::clone(&self.semaphore).try_acquire_owned()?;
        Ok(AdmissionPermit {
            permit: Some(permit),
            admission: Arc::clone(self),
        })
    }

    /// Change the target size using the formally verified `orb_node_resize_step`
    /// kernel. Never interrupts a holder. Returns the previous target.
    pub fn resize(&self, capacity: usize) -> usize {
        let target = capacity.max(1);
        let mut state = self.lock();
        let previous = state.capacity;
        if target > previous {
            let grow = target - previous;
            let verdict = crate::orb_spec::node_resize_step(crate::orb_spec::NodeResizeInput {
                is_operator_caller: true,
                is_agent_caller: false,
                is_static_node: true,
                cur_cap: u32::try_from(previous).unwrap_or(u32::MAX),
                cur_debt: u32::try_from(state.debt).unwrap_or(u32::MAX),
                idle_permits: u32::try_from(self.semaphore.available_permits()).unwrap_or(u32::MAX),
                target_cap: u32::try_from(target).unwrap_or(u32::MAX),
                max_cap: u32::MAX,
            });
            let next_debt = if verdict.admitted {
                verdict.next_debt as usize
            } else {
                state.debt.saturating_sub(grow)
            };
            let cancelled = state.debt.saturating_sub(next_debt);
            state.debt = next_debt;
            self.semaphore.add_permits(grow.saturating_sub(cancelled));
        } else if target < previous {
            let shrink = previous - target;
            let forgotten = self.semaphore.forget_permits(shrink);
            let verdict = crate::orb_spec::node_resize_step(crate::orb_spec::NodeResizeInput {
                is_operator_caller: true,
                is_agent_caller: false,
                is_static_node: true,
                cur_cap: u32::try_from(previous).unwrap_or(u32::MAX),
                cur_debt: u32::try_from(state.debt).unwrap_or(u32::MAX),
                idle_permits: u32::try_from(forgotten).unwrap_or(u32::MAX),
                target_cap: u32::try_from(target).unwrap_or(u32::MAX),
                max_cap: u32::MAX,
            });
            state.debt = if verdict.admitted {
                verdict.next_debt as usize
            } else {
                state.debt + (shrink - forgotten)
            };
        }
        state.capacity = target;
        previous
    }
}

/// Admission pools (`main`, `side`, `coordinator`, and 1-slot operator `force`) and live free-disk floor of a node.
#[derive(Clone)]
pub struct NodeCapacity {
    pub main: Arc<Admission>,
    pub side: Arc<Admission>,
    pub coordinator: Arc<Admission>,
    pub force: Arc<Admission>,
    min_free_gb: Arc<AtomicU64>,
    /// Whether this is the process's own node (publishes the live values
    /// read by the per-job memory budget and GC floor).
    publish: bool,
}

impl NodeCapacity {
    pub fn new(capacity: u32, side_capacity: usize) -> Self {
        Self::from_pools(
            Admission::new(capacity.max(1) as usize),
            Admission::new(side_capacity.max(1)),
        )
    }

    pub fn from_pools(main: Arc<Admission>, side: Arc<Admission>) -> Self {
        Self {
            main,
            side,
            coordinator: Admission::new(DEFAULT_COORDINATOR_CAPACITY),
            force: Admission::new(1),
            min_free_gb: Arc::new(AtomicU64::new(current_min_free_gb())),
            publish: false,
        }
    }

    /// The running node's pools: also publishes process-wide live values.
    pub fn for_process(capacity: u32, side_capacity: usize) -> Self {
        let coordinator_capacity = current_coordinator_capacity();
        let min_free_gb = current_min_free_gb();
        publish_capacities(capacity, side_capacity);
        publish_coordinator_capacity(coordinator_capacity);
        publish_min_free_gb(min_free_gb);
        Self {
            main: Admission::new(capacity.max(1) as usize),
            side: Admission::new(side_capacity.max(1)),
            coordinator: Admission::new(coordinator_capacity.max(1)),
            force: Admission::new(1),
            min_free_gb: Arc::new(AtomicU64::new(min_free_gb)),
            publish: true,
        }
    }

    pub fn capacity(&self) -> u32 {
        u32::try_from(self.main.capacity()).unwrap_or(u32::MAX)
    }

    pub fn side_capacity(&self) -> usize {
        self.side.capacity()
    }

    pub fn coordinator_capacity(&self) -> usize {
        self.coordinator.capacity()
    }

    pub fn min_free_gb(&self) -> u64 {
        self.min_free_gb.load(Ordering::Acquire)
    }

    pub fn min_free_bytes(&self) -> u64 {
        self.min_free_gb().saturating_mul(1 << 30)
    }

    pub fn snapshot(&self) -> Capacities {
        Capacities {
            capacity: self.capacity(),
            side_capacity: self.side_capacity(),
            coordinator_capacity: self.coordinator_capacity(),
            min_free_gb: self.min_free_gb(),
        }
    }

    /// Apply new capacities and disk floor. Returns whether anything changed.
    pub fn apply(&self, next: Capacities) -> bool {
        let capacity = next.capacity.max(1) as usize;
        let side = next.side_capacity.max(1);
        let coordinator = next.coordinator_capacity.max(1);
        let old_main = self.main.resize(capacity);
        let old_side = self.side.resize(side);
        let old_coord = self.coordinator.resize(coordinator);
        let old_min_free_gb = self.min_free_gb.swap(next.min_free_gb, Ordering::AcqRel);
        if self.publish {
            publish_capacities(next.capacity, side);
            publish_coordinator_capacity(coordinator);
            publish_min_free_gb(next.min_free_gb);
            if old_min_free_gb != next.min_free_gb {
                super::lean::notify_min_free_changed();
            }
        }
        if old_main != capacity
            || old_side != side
            || old_coord != coordinator
            || old_min_free_gb != next.min_free_gb
        {
            tracing::info!(
                capacity_from = old_main,
                capacity_to = capacity,
                side_capacity_from = old_side,
                side_capacity_to = side,
                coordinator_capacity_from = old_coord,
                coordinator_capacity_to = coordinator,
                min_free_gb_from = old_min_free_gb,
                min_free_gb_to = next.min_free_gb,
                main_in_use = self.main.in_use(),
                coordinator_in_use = self.coordinator.in_use(),
                "node capacity reloaded"
            );
            true
        } else {
            false
        }
    }

    /// Apply `<work_root>/capacity_override.json` on startup when present and at
    /// least as recent as `env_path` (so operator UI edits survive restarts
    /// while a newer `/etc/sandboxed-node.env` edit on disk still wins).
    pub fn apply_startup_override(&self, work_root: &Path, env_path: &Path) -> bool {
        let ov_path = override_file_path(work_root);
        if !override_takes_precedence(&ov_path, env_path) {
            return false;
        }
        match read_capacity_override(&ov_path) {
            Ok(Some(ov)) => {
                let mut next = self.snapshot();
                next.capacity = ov.capacity;
                if let Some(coord) = ov.coordinator_capacity {
                    next.coordinator_capacity = coord.clamp(1, 16);
                }
                if let Some(side) = ov.side_capacity {
                    next.side_capacity = side.clamp(1, 16);
                }
                if let Some(floor) = ov.min_free_gb {
                    next.min_free_gb = floor;
                }
                self.apply(next)
            }
            Ok(None) => false,
            Err(error) => {
                tracing::warn!(%error, path = %ov_path.display(), "ignoring invalid capacity override");
                false
            }
        }
    }

    /// Re-read `path` and apply it. Errors keep the running capacities.
    pub fn reload_from(&self, path: &Path) -> anyhow::Result<bool> {
        self.reload_from_with_override(path, None)
    }

    /// Re-read `path` while respecting a newer persistent operator override file
    /// (so `SIGHUP` or periodic env checks do not clobber live UI edits unless
    /// `path` itself was edited more recently than `override_path`).
    pub fn reload_from_with_override(
        &self,
        path: &Path,
        override_path: Option<&Path>,
    ) -> anyhow::Result<bool> {
        let content = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("read {}: {e}", path.display()))?;
        let current = self.snapshot();
        let mut parsed = capacities_from_env_content(&content, current)?;
        if let Some(ov_path) = override_path {
            if override_takes_precedence(ov_path, path) {
                if let Ok(Some(ov)) = read_capacity_override(ov_path) {
                    parsed.capacity = ov.capacity;
                    if let Some(coord) = ov.coordinator_capacity {
                        parsed.coordinator_capacity = coord.clamp(1, 16);
                    }
                    if let Some(side) = ov.side_capacity {
                        parsed.side_capacity = side.clamp(1, 16);
                    }
                    if let Some(floor) = ov.min_free_gb {
                        parsed.min_free_gb = floor;
                    }
                }
            }
        }
        Ok(self.apply(parsed))
    }
}

fn override_takes_precedence(override_path: &Path, env_path: &Path) -> bool {
    let Some(ov_mtime) = mtime(override_path) else {
        return false;
    };
    match mtime(env_path) {
        Some(env_mtime) => ov_mtime > env_mtime,
        None => true,
    }
}

/// Env file the node reloads from (`SANDBOXED_NODE_ENV_FILE`).
pub fn env_file_path() -> PathBuf {
    std::env::var_os("SANDBOXED_NODE_ENV_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_ENV_FILE))
}

fn mtime(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

/// Reload on `SIGHUP` and whenever the env file mtime changes (polled every
/// [`POLL_INTERVAL`]).
pub fn spawn_reload_watcher(capacity: NodeCapacity, path: PathBuf) {
    spawn_reload_watcher_with_override(capacity, path, None);
}

/// Reload on `SIGHUP` and whenever the env file mtime changes, reconciling
/// against an optional persistent operator override file.
pub fn spawn_reload_watcher_with_override(
    capacity: NodeCapacity,
    path: PathBuf,
    override_path: Option<PathBuf>,
) {
    tokio::spawn(async move {
        let mut last_mtime = mtime(&path);
        #[cfg(unix)]
        let mut hangup = match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup())
        {
            Ok(signal) => Some(signal),
            Err(error) => {
                tracing::warn!(%error, "cannot install SIGHUP handler; polling only");
                None
            }
        };
        let mut ticker = tokio::time::interval(POLL_INTERVAL);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        ticker.tick().await;
        loop {
            #[cfg(unix)]
            let forced = match hangup.as_mut() {
                Some(signal) => tokio::select! {
                    _ = signal.recv() => true,
                    _ = ticker.tick() => false,
                },
                None => {
                    ticker.tick().await;
                    false
                }
            };
            #[cfg(not(unix))]
            let forced = {
                ticker.tick().await;
                false
            };
            let current = mtime(&path);
            if !forced && current == last_mtime {
                continue;
            }
            last_mtime = current;
            match capacity.reload_from_with_override(&path, override_path.as_deref()) {
                Ok(changed) => {
                    if forced && !changed {
                        tracing::info!(path = %path.display(), "reload: capacity unchanged");
                    }
                }
                Err(error) => {
                    tracing::warn!(%error, "reload: keeping current capacity");
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    const FALLBACK: Capacities = Capacities {
        capacity: 7,
        side_capacity: 3,
        coordinator_capacity: 2,
        min_free_gb: 30,
    };

    #[test]
    fn env_reparse_reads_capacities_and_disk_floor() {
        let content = "# node\nSANDBOXED_NODE_TOKEN=x\nexport SANDBOXED_NODE_CAPACITY=\"6\"\n\
                       SANDBOXED_NODE_SIDE_CAPACITY='4'\nSANDBOXED_NODE_COORDINATOR_CAPACITY=5\n\
                       SANDBOXED_NODE_MIN_FREE_GB=80\n";
        assert_eq!(
            capacities_from_env_content(content, FALLBACK).unwrap(),
            Capacities {
                capacity: 6,
                side_capacity: 4,
                coordinator_capacity: 5,
                min_free_gb: 80,
            }
        );
        // Explicit 0 GiB floor is preserved (not treated as unset).
        assert_eq!(
            capacities_from_env_content("SANDBOXED_NODE_MIN_FREE_GB=0\n", FALLBACK).unwrap(),
            Capacities {
                capacity: 7,
                side_capacity: 3,
                coordinator_capacity: 2,
                min_free_gb: 0,
            }
        );
        // Running values kept when absent; last assignment wins.
        assert_eq!(
            capacities_from_env_content(
                "SANDBOXED_NODE_CAPACITY=2\nSANDBOXED_NODE_CAPACITY=3\n",
                FALLBACK
            )
            .unwrap(),
            Capacities {
                capacity: 3,
                side_capacity: 3,
                coordinator_capacity: 2,
                min_free_gb: 30,
            }
        );
        assert_eq!(capacities_from_env_content("", FALLBACK).unwrap(), FALLBACK);
        // A bad value is rejected rather than silently becoming 1 or 10.
        assert!(capacities_from_env_content("SANDBOXED_NODE_CAPACITY=0\n", FALLBACK).is_err());
        assert!(capacities_from_env_content("SANDBOXED_NODE_CAPACITY=lots\n", FALLBACK).is_err());
        assert!(capacities_from_env_content("SANDBOXED_NODE_MIN_FREE_GB=-5\n", FALLBACK).is_err());
        assert!(capacities_from_env_content("SANDBOXED_NODE_MIN_FREE_GB=bad\n", FALLBACK).is_err());
    }

    #[test]
    fn runtime_override_persists_across_sighup_until_env_file_is_edited_later() {
        let dir = tempfile::tempdir().unwrap();
        let env_path = dir.path().join("node.env");
        let work_root = dir.path().join("work");
        std::fs::write(&env_path, "SANDBOXED_NODE_CAPACITY=2\n").unwrap();
        std::thread::sleep(Duration::from_millis(20));

        write_capacity_override(
            &work_root,
            &CapacityOverride {
                capacity: 8,
                coordinator_capacity: Some(3),
                side_capacity: None,
                min_free_gb: None,
                updated_at: "2026-11-01T00:00:00Z".to_string(),
            },
        )
        .unwrap();

        let cap = NodeCapacity::new(2, 2);
        assert!(cap.apply_startup_override(&work_root, &env_path));
        assert_eq!(cap.capacity(), 8);
        assert_eq!(cap.coordinator_capacity(), 3);

        // Simulated SIGHUP with untouched env_path must NOT revert the UI override.
        let ov_path = override_file_path(&work_root);
        assert!(!cap
            .reload_from_with_override(&env_path, Some(&ov_path))
            .unwrap());
        assert_eq!(cap.capacity(), 8);

        // Explicit later edit to /etc/sandboxed-node.env takes precedence again.
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(&env_path, "SANDBOXED_NODE_CAPACITY=5\n").unwrap();
        assert!(cap
            .reload_from_with_override(&env_path, Some(&ov_path))
            .unwrap());
        assert_eq!(cap.capacity(), 5);
    }

    #[test]
    fn reload_from_file_resizes_updates_floor_and_keeps_running_on_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("node.env");
        let capacity = NodeCapacity::new(2, 2);
        let initial_floor = capacity.min_free_gb();
        std::fs::write(
            &path,
            format!("SANDBOXED_NODE_CAPACITY=2\nSANDBOXED_NODE_MIN_FREE_GB={initial_floor}\n"),
        )
        .unwrap();
        assert!(!capacity.reload_from(&path).unwrap());
        std::fs::write(
            &path,
            "SANDBOXED_NODE_CAPACITY=5\nSANDBOXED_NODE_SIDE_CAPACITY=3\nSANDBOXED_NODE_MIN_FREE_GB=45\n",
        )
        .unwrap();
        assert!(capacity.reload_from(&path).unwrap());
        assert_eq!(capacity.capacity(), 5);
        assert_eq!(capacity.side_capacity(), 3);
        assert_eq!(capacity.min_free_gb(), 45);
        assert_eq!(capacity.min_free_bytes(), 45 << 30);
        assert_eq!(capacity.main.available_permits(), 5);
        std::fs::write(&path, "SANDBOXED_NODE_MIN_FREE_GB=not-a-number\n").unwrap();
        assert!(capacity.reload_from(&path).is_err());
        assert_eq!(capacity.min_free_gb(), 45);
        std::fs::write(&path, "SANDBOXED_NODE_CAPACITY=-1\n").unwrap();
        assert!(capacity.reload_from(&path).is_err());
        assert_eq!(capacity.capacity(), 5);
        assert!(capacity.reload_from(&dir.path().join("missing")).is_err());
        assert_eq!(capacity.capacity(), 5);
    }

    #[tokio::test]
    async fn grow_with_jobs_in_flight_admits_more_immediately() {
        let admission = Admission::new(1);
        let running = admission.try_acquire_owned().unwrap();
        assert!(admission.try_acquire_owned().is_err());
        admission.resize(3);
        let second = admission.try_acquire_owned().unwrap();
        let third = admission.try_acquire_owned().unwrap();
        assert!(admission.try_acquire_owned().is_err());
        assert_eq!(admission.in_use(), 3);
        drop((running, second, third));
        assert_eq!(admission.available_permits(), 3);
    }

    #[tokio::test]
    async fn shrink_with_jobs_in_flight_never_revokes_and_blocks_until_under_cap() {
        let admission = Admission::new(4);
        let jobs: Vec<_> = (0..4)
            .map(|_| admission.try_acquire_owned().unwrap())
            .collect();
        admission.resize(2);
        assert_eq!(admission.capacity(), 2);
        // All four keep running above the new cap.
        assert_eq!(admission.in_use(), 4);
        let mut jobs = jobs.into_iter();

        // A queued admission waits while running >= new cap.
        let waiter = {
            let admission = Arc::clone(&admission);
            tokio::spawn(async move { admission.acquire_owned().await.unwrap() })
        };
        tokio::task::yield_now().await;
        drop(jobs.next()); // 3 running: still above cap.
        drop(jobs.next()); // 2 running: at cap.
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(!waiter.is_finished());
        assert_eq!(admission.available_permits(), 0);
        drop(jobs.next()); // 1 running: under cap, waiter admitted.
        let admitted = tokio::time::timeout(Duration::from_secs(1), waiter)
            .await
            .expect("waiter admitted once under the new cap")
            .unwrap();
        assert_eq!(admission.in_use(), 2);
        drop((admitted, jobs.next()));
        assert_eq!(admission.available_permits(), 2);
    }

    #[tokio::test]
    async fn grow_after_partial_shrink_cancels_outstanding_debt() {
        let admission = Admission::new(3);
        let a = admission.try_acquire_owned().unwrap();
        let b = admission.try_acquire_owned().unwrap();
        admission.resize(1); // forgets 1 idle, owes 1
        assert_eq!(admission.available_permits(), 0);
        admission.resize(4); // cancels the debt, adds 2
        assert_eq!(admission.available_permits(), 2);
        drop((a, b));
        assert_eq!(admission.available_permits(), 4);
        // Shrink of idle permits applies immediately.
        admission.resize(1);
        assert_eq!(admission.available_permits(), 1);
    }
}
