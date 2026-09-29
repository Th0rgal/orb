//! Claude sessions that outlive a turn.
//!
//! A `result` ends one turn, not the session: while the CLI still has
//! background tasks (agents, shells), the runner keeps the process and parks.
//! The CLI wakes itself when a task finishes. A user message that arrives
//! while the session is parked is written to its stdin instead of starting a
//! new process, which would stop those tasks.

use std::collections::{HashMap, HashSet};
use std::sync::{LazyLock, Mutex};

use serde_json::Value;
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

/// `MissionActivity::tool_name` the runner emits once each time it parks. The
/// control actor answers by handing over one message queued for the mission.
pub(crate) const PARKED_MARKER: &str = "claudecode_parked";

/// Stream-json stdin is required: a parked session receives its next message
/// there.
pub(crate) fn enabled() -> bool {
    crate::util::env_var_bool("SANDBOXED_SH_CLAUDE_STREAM_INPUT", false)
}

static PARKED: LazyLock<Mutex<HashMap<Uuid, oneshot::Sender<String>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Accept one message for this mission. The slot is consumed by the first
/// delivery, so a parked session never receives two inputs for one turn.
pub(crate) fn park(mission_id: Uuid) -> oneshot::Receiver<String> {
    let (tx, rx) = oneshot::channel();
    PARKED.lock().unwrap().insert(mission_id, tx);
    rx
}

/// Missions whose session is parked and can take a message now.
pub(crate) fn parked_missions() -> Vec<Uuid> {
    PARKED.lock().unwrap().keys().copied().collect()
}

pub(crate) fn unpark(mission_id: Uuid) {
    PARKED.lock().unwrap().remove(&mission_id);
}

/// Hand a message to the mission's parked session. Returns the message when no
/// session is parked, so the caller queues it as usual.
pub(crate) fn deliver(mission_id: Uuid, content: String) -> Result<(), String> {
    let Some(slot) = PARKED.lock().unwrap().remove(&mission_id) else {
        return Err(content);
    };
    slot.send(content)
}

static EFFORT: LazyLock<Mutex<HashMap<Uuid, mpsc::UnboundedSender<Option<String>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Effort changes for a session that reads stream-json input arrive here and
/// are applied to the running process.
pub(crate) fn effort_changes(mission_id: Uuid) -> mpsc::UnboundedReceiver<Option<String>> {
    let (tx, rx) = mpsc::unbounded_channel();
    EFFORT.lock().unwrap().insert(mission_id, tx);
    rx
}

/// Change the effort of the mission's running session. False when no session
/// can take it: the stored effort then applies from the next process.
pub(crate) fn set_effort(mission_id: Uuid, effort: Option<String>) -> bool {
    EFFORT
        .lock()
        .unwrap()
        .get(&mission_id)
        .is_some_and(|session| session.send(effort).is_ok())
}

/// The control request that sets the effort of a running CLI. `None` returns
/// to the CLI's default.
pub(crate) fn effort_request(effort: Option<&str>) -> Value {
    serde_json::json!({
        "type": "control_request",
        "request_id": format!("orb-effort-{}", Uuid::new_v4()),
        "request": { "subtype": "apply_flag_settings", "settings": { "effortLevel": effort } }
    })
}

static ATTACHED: LazyLock<Mutex<HashSet<Uuid>>> = LazyLock::new(|| Mutex::new(HashSet::new()));

/// True while a runner that keeps its session owns this mission. The CLI then
/// reports its own background tasks, so nothing else has to watch them.
pub(crate) fn is_attached(mission_id: Uuid) -> bool {
    ATTACHED.lock().unwrap().contains(&mission_id)
}

/// Marks the mission as owned by a live session until dropped, and removes
/// its slot when the runner leaves, however it leaves.
pub(crate) struct SessionGuard(Uuid);

impl SessionGuard {
    pub(crate) fn attach(mission_id: Uuid, keep_alive: bool) -> Self {
        if keep_alive {
            ATTACHED.lock().unwrap().insert(mission_id);
        }
        Self(mission_id)
    }
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        ATTACHED.lock().unwrap().remove(&self.0);
        EFFORT.lock().unwrap().remove(&self.0);
        unpark(self.0);
    }
}

/// Background tasks the CLI reports as live. Prefer its authoritative
/// snapshot; older CLIs expose only the edges.
#[derive(Default)]
pub(crate) struct ClaudeBackground {
    tasks: HashSet<String>,
    has_snapshot: bool,
}

impl ClaudeBackground {
    pub(crate) fn consume(&mut self, event: &Value) {
        if event["type"] != "system" {
            return;
        }
        match event["subtype"].as_str() {
            Some("background_tasks_changed") => {
                if let Some(tasks) = event["tasks"].as_array() {
                    self.has_snapshot = true;
                    self.tasks = tasks
                        .iter()
                        .filter(|task| task["ambient"] != true)
                        .filter_map(|task| task["task_id"].as_str().map(str::to_owned))
                        .collect();
                }
            }
            Some("task_started") if !self.has_snapshot && event["ambient"] != true => {
                if let Some(id) = event["task_id"].as_str() {
                    self.tasks.insert(id.into());
                }
            }
            Some("task_notification") if !self.has_snapshot => {
                if let Some(id) = event["task_id"].as_str() {
                    self.tasks.remove(id);
                }
            }
            _ => {}
        }
    }

    pub(crate) fn running(&self) -> usize {
        self.tasks.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn snapshot_replaces_edges_and_ignores_ambient_tasks() {
        let mut background = ClaudeBackground::default();
        background.consume(&json!({"type":"system","subtype":"task_started","task_id":"a"}));
        assert_eq!(background.running(), 1);
        background.consume(
            &json!({"type":"system","subtype":"background_tasks_changed",
            "tasks":[{"task_id":"b"},{"task_id":"c","ambient":true}]}),
        );
        assert_eq!(background.running(), 1);
        // Edges are ignored once the CLI sends snapshots.
        background.consume(&json!({"type":"system","subtype":"task_notification","task_id":"b"}));
        assert_eq!(background.running(), 1);
        background
            .consume(&json!({"type":"system","subtype":"background_tasks_changed","tasks":[]}));
        assert_eq!(background.running(), 0);
    }

    #[test]
    fn edges_track_tasks_for_older_clis() {
        let mut background = ClaudeBackground::default();
        background.consume(&json!({"type":"system","subtype":"task_started","task_id":"a"}));
        background.consume(&json!({"type":"assistant","subtype":"task_started","task_id":"z"}));
        background.consume(&json!({"type":"system","subtype":"task_notification","task_id":"a"}));
        assert_eq!(background.running(), 0);
    }

    #[tokio::test]
    async fn a_parked_session_takes_one_message() {
        let mission = Uuid::new_v4();
        assert_eq!(deliver(mission, "early".into()), Err("early".into()));
        let slot = park(mission);
        assert_eq!(deliver(mission, "first".into()), Ok(()));
        assert_eq!(deliver(mission, "second".into()), Err("second".into()));
        assert_eq!(slot.await.unwrap(), "first");
    }

    #[test]
    fn effort_reaches_the_session_until_its_runner_leaves() {
        let mission = Uuid::new_v4();
        assert!(!set_effort(mission, Some("high".into())));
        let guard = SessionGuard::attach(mission, false);
        let mut changes = effort_changes(mission);
        assert!(set_effort(mission, Some("high".into())));
        assert!(set_effort(mission, None));
        assert_eq!(changes.try_recv().unwrap().as_deref(), Some("high"));
        assert_eq!(changes.try_recv().unwrap(), None);
        drop(guard);
        assert!(!set_effort(mission, Some("low".into())));

        let request = effort_request(Some("xhigh"));
        assert_eq!(request["request"]["subtype"], "apply_flag_settings");
        assert_eq!(request["request"]["settings"]["effortLevel"], "xhigh");
        assert!(effort_request(None)["request"]["settings"]["effortLevel"].is_null());
    }

    #[test]
    fn a_runner_that_left_takes_no_message() {
        let mission = Uuid::new_v4();
        let slot = park(mission);
        drop(slot);
        assert_eq!(deliver(mission, "late".into()), Err("late".into()));
        let guard = SessionGuard::attach(mission, true);
        assert!(is_attached(mission));
        let _slot = park(mission);
        drop(guard);
        assert!(!is_attached(mission));
        assert_eq!(deliver(mission, "later".into()), Err("later".into()));
    }
}
