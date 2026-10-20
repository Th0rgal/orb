//! Live-resizable node admission (`SANDBOXED_NODE_CAPACITY`,
//! `SANDBOXED_NODE_SIDE_CAPACITY`) and the env-file reload that drives it.
//!
//! A restart of `sandboxed-node` retires every running job, so capacity
//! changes are applied in place instead: on `SIGHUP` (or when the env file's
//! mtime changes) the node re-reads both capacities and resizes its pools.
//!
//! * Grow: permits are added immediately (after cancelling any outstanding
//!   shrink debt).
//! * Shrink: idle permits are forgotten immediately; the rest becomes *debt*
//!   that is paid by forgetting permits as running jobs release them. No new
//!   job is admitted until the running count is under the new cap, and no
//!   running job is ever interrupted.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use tokio::sync::{AcquireError, OwnedSemaphorePermit, Semaphore, TryAcquireError};

/// Default env file written by node enrollment.
pub const DEFAULT_ENV_FILE: &str = "/etc/sandboxed-node.env";
/// How often the env file mtime is polled when no `SIGHUP` arrives.
pub const POLL_INTERVAL: Duration = Duration::from_secs(30);

/// Default side-question lane width when unset or out of range.
pub const DEFAULT_SIDE_CAPACITY: usize = 2;

/// Current main-slot capacity, read by the per-job memory budget.
static CURRENT_CAPACITY: AtomicU32 = AtomicU32::new(0);
/// Current side-question capacity, read by the per-job memory budget.
static CURRENT_SIDE_CAPACITY: AtomicUsize = AtomicUsize::new(0);

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

pub(crate) fn publish_capacities(capacity: u32, side: usize) {
    CURRENT_CAPACITY.store(capacity.max(1), Ordering::Release);
    CURRENT_SIDE_CAPACITY.store(side.max(1), Ordering::Release);
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

/// Capacities parsed from an env file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capacities {
    pub capacity: u32,
    pub side_capacity: usize,
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

    /// Change the target size. Never interrupts a holder. Returns the
    /// previous target.
    pub fn resize(&self, capacity: usize) -> usize {
        let mut state = self.lock();
        let previous = state.capacity;
        if capacity > previous {
            let grow = capacity - previous;
            let cancelled = grow.min(state.debt);
            state.debt -= cancelled;
            self.semaphore.add_permits(grow - cancelled);
        } else if capacity < previous {
            let shrink = previous - capacity;
            let forgotten = self.semaphore.forget_permits(shrink);
            state.debt += shrink - forgotten;
        }
        state.capacity = capacity;
        previous
    }
}

/// Both admission pools of a node.
#[derive(Clone)]
pub struct NodeCapacity {
    pub main: Arc<Admission>,
    pub side: Arc<Admission>,
    /// Whether this is the process's own node (publishes the live values
    /// read by the per-job memory budget).
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
            publish: false,
        }
    }

    /// The running node's pools: also publishes process-wide live values.
    pub fn for_process(capacity: u32, side_capacity: usize) -> Self {
        publish_capacities(capacity, side_capacity);
        Self {
            publish: true,
            ..Self::new(capacity, side_capacity)
        }
    }

    pub fn capacity(&self) -> u32 {
        u32::try_from(self.main.capacity()).unwrap_or(u32::MAX)
    }

    pub fn side_capacity(&self) -> usize {
        self.side.capacity()
    }

    /// Apply new capacities. Returns whether anything changed.
    pub fn apply(&self, next: Capacities) -> bool {
        let capacity = next.capacity.max(1) as usize;
        let side = next.side_capacity.max(1);
        let old_main = self.main.resize(capacity);
        let old_side = self.side.resize(side);
        if self.publish {
            publish_capacities(next.capacity, side);
        }
        if old_main != capacity || old_side != side {
            tracing::info!(
                capacity_from = old_main,
                capacity_to = capacity,
                side_capacity_from = old_side,
                side_capacity_to = side,
                main_in_use = self.main.in_use(),
                "node capacity reloaded"
            );
            true
        } else {
            false
        }
    }

    /// Re-read `path` and apply it. Errors keep the running capacities.
    pub fn reload_from(&self, path: &Path) -> anyhow::Result<bool> {
        let content = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("read {}: {e}", path.display()))?;
        let current = Capacities {
            capacity: self.capacity(),
            side_capacity: self.side_capacity(),
        };
        Ok(self.apply(capacities_from_env_content(&content, current)?))
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
            match capacity.reload_from(&path) {
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

/// Pid file the running node writes (`SANDBOXED_NODE_PID_FILE`, default
/// `<work_root>/../sandboxed-node.pid`, i.e. `/var/lib/sandboxed-node`).
pub fn pid_file_path(work_root: &Path) -> PathBuf {
    if let Some(path) = std::env::var_os("SANDBOXED_NODE_PID_FILE") {
        return PathBuf::from(path);
    }
    work_root
        .parent()
        .unwrap_or(work_root)
        .join("sandboxed-node.pid")
}

#[cfg(test)]
mod tests {
    use super::*;

    const FALLBACK: Capacities = Capacities {
        capacity: 7,
        side_capacity: 3,
    };

    #[test]
    fn env_reparse_reads_both_capacities() {
        let content = "# node\nSANDBOXED_NODE_TOKEN=x\nexport SANDBOXED_NODE_CAPACITY=\"6\"\n\
                       SANDBOXED_NODE_SIDE_CAPACITY='4'\n";
        assert_eq!(
            capacities_from_env_content(content, FALLBACK).unwrap(),
            Capacities {
                capacity: 6,
                side_capacity: 4
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
                side_capacity: 3
            }
        );
        assert_eq!(capacities_from_env_content("", FALLBACK).unwrap(), FALLBACK);
        // A bad value is rejected rather than silently becoming 1.
        assert!(capacities_from_env_content("SANDBOXED_NODE_CAPACITY=0\n", FALLBACK).is_err());
        assert!(capacities_from_env_content("SANDBOXED_NODE_CAPACITY=lots\n", FALLBACK).is_err());
    }

    #[test]
    fn reload_from_file_resizes_and_keeps_capacity_on_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("node.env");
        std::fs::write(&path, "SANDBOXED_NODE_CAPACITY=2\n").unwrap();
        let capacity = NodeCapacity::new(2, 2);
        assert!(!capacity.reload_from(&path).unwrap());
        std::fs::write(
            &path,
            "SANDBOXED_NODE_CAPACITY=5\nSANDBOXED_NODE_SIDE_CAPACITY=3\n",
        )
        .unwrap();
        assert!(capacity.reload_from(&path).unwrap());
        assert_eq!(capacity.capacity(), 5);
        assert_eq!(capacity.side_capacity(), 3);
        assert_eq!(capacity.main.available_permits(), 5);
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
