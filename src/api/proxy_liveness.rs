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

use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use dashmap::DashMap;
use uuid::Uuid;

/// Header carrying the mission id on builtin proxy requests.
pub const MISSION_ID_HEADER: &str = "x-sandboxed-mission-id";

/// A builtin-proxy request in flight or active within this window counts as
/// live model traffic for harness and control-plane stall watchdogs.
pub const PROXY_STREAM_RECENT: Duration = Duration::from_secs(30);

/// Hard ceiling on proxy-stream grace: even with live upstream chunks, allow
/// inactivity watchdogs to fire once harness output has been silent for this
/// long (protects against a wedged CLI or runaway internal subagent loop).
pub const PROXY_STREAM_INACTIVITY_CAP: Duration = Duration::from_secs(1800);

/// Entries older than this are pruned opportunistically on handle lookup; a turn
/// that has been silent for an hour is long past any watchdog decision.
const PRUNE_AFTER: Duration = Duration::from_secs(3600);

/// Pre-bound atomic liveness cell for one mission.
///
/// Request/stream wrappers bind an `Arc<MissionProxyLiveness>` once at request
/// setup so per-chunk `record_chunk()` executes a single relaxed `AtomicU64`
/// store with zero mutex locks and zero map lookups.
#[derive(Debug, Default)]
pub struct MissionProxyLiveness {
    last_nanos: AtomicU64,
    in_flight: AtomicU32,
}

impl MissionProxyLiveness {
    /// Record an upstream byte/SSE chunk or keepalive with zero locks or lookups.
    #[inline]
    pub fn record_chunk(&self) {
        self.last_nanos
            .store(crate::concurrency::monotonic_nanos(), Ordering::Relaxed);
    }

    /// Alias for [`Self::record_chunk`] at request lifecycle boundaries.
    #[inline]
    pub fn note_activity(&self) {
        self.record_chunk();
    }

    #[inline]
    fn elapsed(&self) -> Option<Duration> {
        crate::concurrency::elapsed_since_monotonic(self.last_nanos.load(Ordering::Relaxed))
    }

    #[inline]
    fn inflight_count(&self) -> u32 {
        self.in_flight.load(Ordering::Acquire)
    }
}

static REGISTRY: OnceLock<DashMap<Uuid, Arc<MissionProxyLiveness>>> = OnceLock::new();

fn registry() -> &'static DashMap<Uuid, Arc<MissionProxyLiveness>> {
    REGISTRY.get_or_init(DashMap::new)
}

/// Obtain a pre-bound `Arc<MissionProxyLiveness>` handle for `mission_id`
/// without marking activity yet.
pub fn liveness_for(mission_id: Uuid) -> Arc<MissionProxyLiveness> {
    let map = registry();
    if let Some(existing) = map.get(&mission_id) {
        return Arc::clone(existing.value());
    }
    let handle = Arc::clone(
        map.entry(mission_id)
            .or_insert_with(|| Arc::new(MissionProxyLiveness::default()))
            .value(),
    );
    if map.len() > 64 {
        map.retain(|_, e| {
            e.inflight_count() > 0 || e.elapsed().is_some_and(|age| age < PRUNE_AFTER)
        });
    }
    handle
}

/// Record proxy activity (request accepted or upstream chunk received) for a
/// mission.
pub fn note_activity(mission_id: Uuid) {
    liveness_for(mission_id).record_chunk();
}

/// A proxy request for a mission that is still being served (waiting for the
/// upstream's first byte, or relaying its stream). Dropping it ends the
/// request and counts as activity.
#[derive(Debug)]
pub struct InFlight(Arc<MissionProxyLiveness>);

impl Drop for InFlight {
    fn drop(&mut self) {
        let _ = self
            .0
            .in_flight
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |cur| {
                Some(cur.saturating_sub(1))
            });
        self.0.record_chunk();
    }
}

/// Mark a proxy request for `mission_id` as in flight until the guard drops.
pub fn begin_request(mission_id: Uuid) -> InFlight {
    let entry = liveness_for(mission_id);
    entry.in_flight.fetch_add(1, Ordering::AcqRel);
    entry.record_chunk();
    InFlight(entry)
}

/// Time since the proxy last saw activity for this mission, if any.
pub fn time_since_activity(mission_id: Uuid) -> Option<Duration> {
    registry().get(&mission_id).and_then(|e| e.elapsed())
}

/// Proxy requests of this mission currently in flight.
pub fn in_flight(mission_id: Uuid) -> u32 {
    registry()
        .get(&mission_id)
        .map(|e| e.inflight_count())
        .unwrap_or(0)
}

/// Whether the mission is talking to a model right now: a request is in
/// flight, or one was active within `recent`.
pub fn is_active(mission_id: Uuid, recent: Duration) -> bool {
    registry()
        .get(&mission_id)
        .is_some_and(|e| e.inflight_count() > 0 || e.elapsed().is_some_and(|d| d < recent))
}

/// Pure decision: whether live builtin-proxy activity defers a harness-idle
/// interrupt at `harness_idle`, bounded by [`PROXY_STREAM_INACTIVITY_CAP`].
pub fn defers_idle_interrupt_pure(proxy_active: bool, harness_idle: Duration) -> bool {
    proxy_active && harness_idle < PROXY_STREAM_INACTIVITY_CAP
}

/// Whether `mission_id` has live builtin-proxy traffic right now (in flight or
/// active within [`PROXY_STREAM_RECENT`]) and `harness_idle` is still below
/// [`PROXY_STREAM_INACTIVITY_CAP`].
pub fn defers_idle_interrupt(mission_id: Uuid, harness_idle: Duration) -> bool {
    defers_idle_interrupt_pure(is_active(mission_id, PROXY_STREAM_RECENT), harness_idle)
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

    #[test]
    fn defers_idle_interrupt_respects_30m_cap() {
        let idle_id = Uuid::new_v4();
        assert!(!defers_idle_interrupt(idle_id, Duration::from_secs(914)));

        let live_id = Uuid::new_v4();
        let _guard = begin_request(live_id);
        assert!(defers_idle_interrupt(live_id, Duration::from_secs(900)));
        assert!(defers_idle_interrupt(live_id, Duration::from_secs(1799)));
        assert!(!defers_idle_interrupt(live_id, PROXY_STREAM_INACTIVITY_CAP));
        assert!(!defers_idle_interrupt(live_id, Duration::from_secs(2400)));
    }
}
