//! Parallel slot usage, published by the scheduler for read paths.
//!
//! The FLEET-001 scheduler only dispatches a pending mission while
//! `running < max_parallel`. Readers could not see that limit, so a mission
//! waiting for a slot looked exactly like one whose dispatch was lost: status
//! `pending`, verdict `queued` then `stuck_queued`, an empty message queue,
//! and `get_mission_health` reporting "No problems detected".

use super::super::mission_store::{Mission, QueueWait};
use super::MissionStatus;
use uuid::Uuid;

/// Slot usage seen by the most recent scheduler pass.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DispatchCapacity {
    pub max_parallel: usize,
    /// Missions holding a slot (parallel runners plus the main session).
    pub running: Vec<Uuid>,
}

impl DispatchCapacity {
    pub fn new(max_parallel: usize, mut running: Vec<Uuid>) -> Self {
        running.sort();
        running.dedup();
        Self {
            max_parallel,
            running,
        }
    }

    pub fn is_full(&self) -> bool {
        self.running.len() >= self.max_parallel
    }
}

/// Why `mission` has not started, when the answer is "every slot is taken".
///
/// Client placements run on the desktop and never take a slot. A mission
/// held by `not_before` is waiting for its time, not for capacity.
pub fn queue_wait_for(
    mission: &Mission,
    capacity: Option<&DispatchCapacity>,
    now: chrono::DateTime<chrono::Utc>,
) -> Option<QueueWait> {
    let capacity = capacity?;
    if mission.status != MissionStatus::Pending || !capacity.is_full() {
        return None;
    }
    let tags = &mission.project.tags;
    if super::client_placement::is_tagged(tags) {
        return None;
    }
    let held_until_later = mission
        .scheduling
        .not_before
        .as_deref()
        .and_then(|ts| chrono::DateTime::parse_from_rfc3339(ts).ok())
        .is_some_and(|ts| ts.with_timezone(&chrono::Utc) > now);
    if held_until_later {
        return None;
    }
    Some(QueueWait {
        reason: "waiting_for_slot".to_string(),
        slots_used: capacity.running.len(),
        slots_max: capacity.max_parallel,
        running_mission_ids: capacity.running.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pending() -> Mission {
        let mut mission: Mission = serde_json::from_value(serde_json::json!({
            "id": Uuid::new_v4(),
            "status": "pending",
            "workspace_id": Uuid::nil(),
            "backend": "codex",
            "history": [],
            "created_at": "2026-10-24T21:18:20Z",
            "updated_at": "2026-10-24T21:18:20Z",
        }))
        .expect("mission");
        mission.status = MissionStatus::Pending;
        mission
    }

    fn full() -> DispatchCapacity {
        DispatchCapacity::new(1, vec![Uuid::new_v4()])
    }

    #[test]
    fn pending_mission_at_capacity_waits_for_a_slot() {
        let capacity = full();
        let wait = queue_wait_for(&pending(), Some(&capacity), chrono::Utc::now())
            .expect("waiting for a slot");
        assert_eq!(wait.reason, "waiting_for_slot");
        assert_eq!((wait.slots_used, wait.slots_max), (1, 1));
        assert_eq!(wait.running_mission_ids, capacity.running);
    }

    #[test]
    fn free_slot_means_no_queue_wait() {
        let capacity = DispatchCapacity::new(3, vec![Uuid::new_v4()]);
        assert!(queue_wait_for(&pending(), Some(&capacity), chrono::Utc::now()).is_none());
    }

    #[test]
    fn unknown_capacity_means_no_queue_wait() {
        assert!(queue_wait_for(&pending(), None, chrono::Utc::now()).is_none());
    }

    #[test]
    fn only_pending_missions_wait() {
        let mut mission = pending();
        mission.status = MissionStatus::Active;
        assert!(queue_wait_for(&mission, Some(&full()), chrono::Utc::now()).is_none());
    }

    #[test]
    fn client_placement_never_waits_for_a_core_slot() {
        let mut mission = pending();
        mission.project.tags = vec![super::super::client_placement::TAG.to_string()];
        assert!(queue_wait_for(&mission, Some(&full()), chrono::Utc::now()).is_none());
    }

    #[test]
    fn not_before_in_the_future_is_not_a_capacity_wait() {
        let now = chrono::Utc::now();
        let mut mission = pending();
        mission.scheduling.not_before = Some((now + chrono::Duration::hours(1)).to_rfc3339());
        assert!(queue_wait_for(&mission, Some(&full()), now).is_none());
        mission.scheduling.not_before = Some((now - chrono::Duration::hours(1)).to_rfc3339());
        assert!(queue_wait_for(&mission, Some(&full()), now).is_some());
    }

    #[test]
    fn running_ids_are_deduplicated() {
        let id = Uuid::new_v4();
        let capacity = DispatchCapacity::new(2, vec![id, id]);
        assert_eq!(capacity.running, vec![id]);
        assert!(!capacity.is_full());
    }
}
