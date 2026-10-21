//! Per-mission liveness signals from the builtin LLM proxy.
//!
//! Harness runners watch their CLI's stdout/stderr to decide whether a turn is
//! stuck, but thinking models (MiniMax-M3, GLM, ...) can spend minutes inside a
//! reasoning segment during which OpenCode emits no JSON events at all. The
//! proxy, however, sees the upstream tokens streaming the whole time. This
//! registry lets the proxy record "mission X received an upstream chunk just
//! now" so runner watchdogs can distinguish "model is still generating" from
//! "process is genuinely hung".
//!
//! Attribution: the per-workspace builtin provider config sends an
//! `x-sandboxed-mission-id` header with every proxy request (see
//! `ensure_opencode_provider_for_model`). Requests without the header (router
//! traffic, chain tests, older workspace configs) are simply not tracked.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use uuid::Uuid;

/// Header carrying the mission id on builtin proxy requests.
pub const MISSION_ID_HEADER: &str = "x-sandboxed-mission-id";

/// Entries older than this are pruned opportunistically on writes; a turn that
/// has been silent for an hour is long past any watchdog decision.
const PRUNE_AFTER: Duration = Duration::from_secs(3600);

#[derive(Debug, Clone, Copy)]
struct Entry {
    last: Instant,
    in_flight: u32,
}

static REGISTRY: OnceLock<Mutex<HashMap<Uuid, Entry>>> = OnceLock::new();

fn registry() -> &'static Mutex<HashMap<Uuid, Entry>> {
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn touch(mission_id: Uuid, delta: i32) {
    if let Ok(mut map) = registry().lock() {
        let entry = map.entry(mission_id).or_insert(Entry {
            last: Instant::now(),
            in_flight: 0,
        });
        entry.last = Instant::now();
        entry.in_flight = entry.in_flight.saturating_add_signed(delta);
        if map.len() > 64 {
            map.retain(|_, e| e.in_flight > 0 || e.last.elapsed() < PRUNE_AFTER);
        }
    }
}

/// Record proxy activity (request accepted or upstream chunk received) for a
/// mission.
pub fn note_activity(mission_id: Uuid) {
    touch(mission_id, 0);
}

/// A proxy request for a mission that is still being served (waiting for the
/// upstream's first byte, or relaying its stream). Dropping it ends the
/// request and counts as activity.
#[derive(Debug)]
pub struct InFlight(Uuid);

impl Drop for InFlight {
    fn drop(&mut self) {
        touch(self.0, -1);
    }
}

/// Mark a proxy request for `mission_id` as in flight until the guard drops.
pub fn begin_request(mission_id: Uuid) -> InFlight {
    touch(mission_id, 1);
    InFlight(mission_id)
}

/// Time since the proxy last saw activity for this mission, if any.
pub fn time_since_activity(mission_id: Uuid) -> Option<Duration> {
    registry()
        .lock()
        .ok()
        .and_then(|map| map.get(&mission_id).map(|e| e.last.elapsed()))
}

/// Proxy requests of this mission currently in flight.
pub fn in_flight(mission_id: Uuid) -> u32 {
    registry()
        .lock()
        .ok()
        .and_then(|map| map.get(&mission_id).map(|e| e.in_flight))
        .unwrap_or(0)
}

/// Whether the mission is talking to a model right now: a request is in
/// flight, or one was active within `recent`.
pub fn is_active(mission_id: Uuid, recent: Duration) -> bool {
    in_flight(mission_id) > 0 || time_since_activity(mission_id).is_some_and(|d| d < recent)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn note_then_query_roundtrip() {
        let id = Uuid::new_v4();
        assert!(time_since_activity(id).is_none());
        note_activity(id);
        let elapsed = time_since_activity(id).expect("activity recorded");
        assert!(elapsed < Duration::from_secs(5));
    }

    #[test]
    fn in_flight_request_is_active_until_dropped() {
        let id = Uuid::new_v4();
        assert!(!is_active(id, Duration::ZERO));
        let guard = begin_request(id);
        assert_eq!(in_flight(id), 1);
        assert!(is_active(id, Duration::ZERO));
        drop(guard);
        assert_eq!(in_flight(id), 0);
        assert!(!is_active(id, Duration::ZERO));
        assert!(is_active(id, Duration::from_secs(60)));
    }
}
