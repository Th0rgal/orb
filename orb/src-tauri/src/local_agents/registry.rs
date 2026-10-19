//! The table of local runs and the state each run shares with its readers.

use super::*;

/// One value shared between the threads of a run, written once or a few
/// times. Locking never panics: a reader that panicked must not wedge the
/// exit watcher, Stop or polling.
pub(crate) struct Slot<T>(Arc<Mutex<Option<T>>>);

impl<T> Clone for Slot<T> {
    fn clone(&self) -> Self {
        Self(Arc::clone(&self.0))
    }
}

impl<T> Default for Slot<T> {
    fn default() -> Self {
        Self(Arc::new(Mutex::new(None)))
    }
}

impl<T: Clone> Slot<T> {
    pub(crate) fn new(value: Option<T>) -> Self {
        Self(Arc::new(Mutex::new(value)))
    }
    pub(crate) fn set(&self, value: T) {
        *crate::sync_util::lock(&self.0) = Some(value);
    }
    pub(crate) fn replace(&self, value: Option<T>) {
        *crate::sync_util::lock(&self.0) = value;
    }
    /// Store `value` only when nothing was stored yet; true when it was stored.
    pub(crate) fn set_if_none(&self, value: T) -> bool {
        let mut slot = crate::sync_util::lock(&self.0);
        if slot.is_some() {
            return false;
        }
        *slot = Some(value);
        true
    }
    pub(crate) fn get(&self) -> Option<T> {
        crate::sync_util::lock(&self.0).clone()
    }
    pub(crate) fn is_some(&self) -> bool {
        crate::sync_util::lock(&self.0).is_some()
    }
    /// Read and write under one lock.
    pub(crate) fn update<R>(&self, change: impl FnOnce(&mut Option<T>) -> R) -> R {
        change(&mut crate::sync_util::lock(&self.0))
    }
}

/// What a harness's reader threads publish: the transcript, the native
/// session, the terminal error and whether the run has ended.
#[derive(Clone)]
pub(crate) struct RunCtx {
    pub(crate) output: Arc<Output>,
    pub(crate) session: Slot<String>,
    pub(crate) error: Slot<String>,
    pub(crate) done: Arc<AtomicBool>,
    /// The mission this run belongs to, for logs.
    pub(crate) mission: String,
    /// The harness id (`claudecode`, `codex`, ...).
    pub(crate) harness: String,
}

impl RunCtx {
    pub(crate) fn new(mission: &str, harness: &str, session: Option<String>) -> Self {
        Self {
            output: Arc::new(Output::default()),
            session: Slot::new(session),
            error: Slot::default(),
            done: Arc::new(AtomicBool::new(false)),
            mission: mission.to_owned(),
            harness: harness.to_owned(),
        }
    }
    pub(crate) fn label(&self) -> &'static str {
        harness_label(&self.harness)
    }
    /// Record the native session the harness announced; logged when it changes.
    pub(crate) fn bind_session(&self, id: String) {
        let changed = self.session.update(|slot| {
            let changed = slot.as_deref() != Some(id.as_str());
            *slot = Some(id.clone());
            changed
        });
        if changed {
            crate::orb_log!(
                info,
                "session_bound",
                mission = self.mission,
                harness = self.harness,
                extra = json!({"session": id})
            );
        }
    }
}

#[derive(Clone)]
pub(crate) struct Run {
    pub(crate) mcp_wrapped: bool,
    pub(crate) generation: String,
    pub(crate) cwd: PathBuf,
    pub(crate) shared_cwd_with: Option<String>,
    pub(crate) child: Arc<Mutex<Child>>,
    pub(crate) ctx: RunCtx,
    pub(crate) exit_code: Slot<i32>,
    pub(crate) resumed: bool,
    /// Set by Stop before it signals the process: its exit is not a crash.
    pub(crate) stopped: Arc<AtomicBool>,
    /// When the run reached its terminal state; finished runs are pruned.
    pub(crate) finished: Arc<OnceLock<Instant>>,
}

impl Run {
    pub(crate) fn new(ctx: RunCtx, child: Child, cwd: PathBuf, resumed: bool) -> Self {
        Self {
            mcp_wrapped: false,
            generation: uuid::Uuid::new_v4().to_string(),
            cwd,
            shared_cwd_with: None,
            child: Arc::new(Mutex::new(child)),
            ctx,
            exit_code: Slot::default(),
            resumed,
            stopped: Arc::new(AtomicBool::new(false)),
            finished: Arc::new(OnceLock::new()),
        }
    }
    pub(crate) fn is_done(&self) -> bool {
        self.ctx.done.load(Ordering::SeqCst)
    }
    /// The state a poll or a terminal event reports.
    pub(crate) fn snapshot(&self, retryable: bool, waiting_since: Option<u64>) -> PollState {
        PollState {
            text: self.ctx.output.snapshot(),
            activities: self.ctx.output.activities(),
            done: self.is_done(),
            exit_code: self.exit_code.get(),
            session_id: self.ctx.session.get(),
            error: self.ctx.error.get(),
            retryable,
            resumed: self.resumed,
            waiting_since,
        }
    }
}

pub(crate) fn runs() -> &'static Mutex<HashMap<String, Run>> {
    static RUNS: OnceLock<Mutex<HashMap<String, Run>>> = OnceLock::new();
    RUNS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) fn has_run(id: &str) -> bool {
    crate::sync_util::lock(runs()).contains_key(id)
}

pub(crate) fn run_of(id: &str) -> Result<Run, String> {
    crate::sync_util::lock(runs())
        .get(id)
        .cloned()
        .ok_or_else(|| "no local run".to_string())
}

/// Finished runs stay cached for reconnect snapshots; only this many are kept.
pub(crate) const KEPT_FINISHED_RUNS: usize = 32;

/// Drop the oldest finished runs beyond `KEPT_FINISHED_RUNS`, then launch
/// fences nobody holds that were never advanced by a Stop. A fence at 0 is
/// recreated identically on demand, so forgetting it cannot admit a stale
/// launch; an advanced fence must persist for as long as the process runs.
pub(crate) fn prune_finished_runs() {
    {
        let mut map = crate::sync_util::lock(runs());
        let mut finished: Vec<(Instant, String)> = map
            .iter()
            .filter(|(_, run)| run.is_done())
            .filter_map(|(id, run)| run.finished.get().map(|at| (*at, id.clone())))
            .collect();
        if finished.len() > KEPT_FINISHED_RUNS {
            finished.sort();
            let excess = finished.len() - KEPT_FINISHED_RUNS;
            for (_, id) in finished.into_iter().take(excess) {
                map.remove(&id);
            }
        }
    }
    crate::sync_util::lock(fences()).retain(|_, fence| {
        Arc::strong_count(fence) > 1 || fence.try_lock().map_or(true, |value| *value != 0)
    });
}

// Serialize Stop with the synchronous spawn boundary, while network preparation
// holds only a captured generation. A stopped preparation must never spawn later.
pub(crate) fn fences() -> &'static Mutex<HashMap<String, Arc<Mutex<u64>>>> {
    static FENCES: OnceLock<Mutex<HashMap<String, Arc<Mutex<u64>>>>> = OnceLock::new();
    FENCES.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) fn launch_fence(id: &str) -> Arc<Mutex<u64>> {
    crate::sync_util::lock(fences())
        .entry(id.into())
        .or_insert_with(|| Arc::new(Mutex::new(0)))
        .clone()
}
pub(crate) const LAUNCH_CANCELLED: &str = "Local launch rejected: stopped before launch";

/// Only live harnesses launched by this Orb instance (not unrelated terminals).
pub fn active_pids() -> Vec<u32> {
    let Ok(all) = runs().lock() else {
        return Vec::new();
    };
    all.values()
        .filter(|r| !r.is_done())
        .filter_map(|r| r.child.try_lock().ok().map(|c| c.id()))
        .collect()
}

pub fn workspace_busy(root: &std::path::Path) -> Result<bool, String> {
    workspace_busy_for(root, None, None)
}

pub fn workspace_busy_for(
    root: &std::path::Path,
    self_id: Option<&str>,
    shared_cwd_with: Option<&str>,
) -> Result<bool, String> {
    let root = root.canonicalize().map_err(|e| e.to_string())?;
    let shared_parent = shared_cwd_with.map(str::trim).filter(|s| !s.is_empty());
    Ok(runs()
        .lock()
        .map_err(|e| e.to_string())?
        .iter()
        .any(|(id, run)| {
            self_id != Some(id.as_str())
                && shared_parent != Some(id.as_str())
                && (self_id.is_none() || run.shared_cwd_with.as_deref() != self_id)
                && (shared_parent.is_none() || run.shared_cwd_with.as_deref() != shared_parent)
                && !run.is_done()
                && run.cwd.canonicalize().ok().as_ref() == Some(&root)
        }))
}

pub fn native_generation(id: &str) -> Option<String> {
    runs()
        .lock()
        .ok()?
        .get(id)
        .map(|run| run.generation.clone())
}

pub fn clear_subscriptions() {
    if let Ok(runs) = runs().lock() {
        for run in runs.values() {
            run.ctx.output.clear_subscriptions();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slot_sets_once_and_survives_a_poisoned_lock() {
        let slot = Slot::new(None);
        assert!(slot.set_if_none("first".to_string()));
        assert!(!slot.set_if_none("second".to_string()));
        assert_eq!(slot.get().as_deref(), Some("first"));
        let poisoner = slot.clone();
        let _ = std::thread::spawn(move || {
            poisoner.update(|_| panic!("poison the slot"));
        })
        .join();
        slot.set("after".into());
        assert_eq!(slot.get().as_deref(), Some("after"));
    }
}
