//! Lightweight in-process metrics for the control plane (P0-#3).
//!
//! Tracks counters used to validate the perf overhaul:
//! - SSE chunk size p50 / p99 (sample-based)
//! - `/api/control/events` request rate, latency, payload bytes, and summarization
//! - `/api/control/running` request rate
//! - Average broadcast events per active mission and broadcast lag
//!
//! Everything lives behind a single `Arc<ControlMetrics>` so the handler at
//! `GET /api/control/metrics` can return a JSON snapshot. Counters, rate
//! buckets, and sample rings are lock-free atomics; `snapshot()` copies sample
//! values out and sorts `unstable` completely outside any lock.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use dashmap::DashMap;
use serde::Serialize;

use crate::concurrency::AtomicRingSamples;

/// Number of samples we keep for percentile estimation. ~64 KB at 8 bytes
/// each — generous enough for stable percentiles, small enough not to
/// matter.
const SAMPLE_BUFFER_SIZE: usize = 8192;

/// Sliding window in seconds for per-endpoint rate calculations.
const RATE_WINDOW_SECS: u64 = 60;

/// Number of atomic epoch-second buckets (>= `RATE_WINDOW_SECS` power of two).
const RATE_BUCKET_SLOTS: usize = 64;

/// Lock-free 60-second sliding rate counter backed by `[AtomicU64; 64]`.
///
/// Each slot packs `((epoch_sec + 1) << 32) | count` so recording a hit is a
/// single CAS/fetch loop on the current second's bucket with zero allocations
/// and zero mutex contention.
struct AtomicEpochRateBuckets {
    origin: Instant,
    buckets: [AtomicU64; RATE_BUCKET_SLOTS],
}

impl AtomicEpochRateBuckets {
    fn new(origin: Instant) -> Self {
        Self {
            origin,
            buckets: std::array::from_fn(|_| AtomicU64::new(0)),
        }
    }

    #[inline]
    fn current_sec(&self) -> u64 {
        self.origin.elapsed().as_secs() + 1
    }

    #[inline]
    fn record_hit(&self) {
        let sec = self.current_sec();
        let slot = &self.buckets[(sec as usize) & (RATE_BUCKET_SLOTS - 1)];
        let mut cur = slot.load(Ordering::Relaxed);
        loop {
            let cur_sec = cur >> 32;
            let next = if cur_sec == sec {
                let count = (cur & 0xffff_ffff)
                    .saturating_add(1)
                    .min(u64::from(u32::MAX));
                (sec << 32) | count
            } else {
                (sec << 32) | 1
            };
            match slot.compare_exchange_weak(cur, next, Ordering::Relaxed, Ordering::Relaxed) {
                Ok(_) => break,
                Err(actual) => cur = actual,
            }
        }
    }

    fn count_last_window(&self) -> u64 {
        let now_sec = self.current_sec();
        let min_sec = now_sec.saturating_sub(RATE_WINDOW_SECS - 1);
        let mut total = 0u64;
        for slot in &self.buckets {
            let packed = slot.load(Ordering::Relaxed);
            let sec = packed >> 32;
            if sec >= min_sec && sec <= now_sec {
                total += packed & 0xffff_ffff;
            }
        }
        total
    }
}

fn percentiles_from_ring(
    ring: &AtomicRingSamples<SAMPLE_BUFFER_SIZE>,
) -> (Option<u64>, Option<u64>, usize) {
    let mut copy = ring.values();
    if copy.is_empty() {
        return (None, None, 0);
    }
    // Sorted completely outside any lock.
    copy.sort_unstable();
    let n = copy.len();
    let p50 = copy[n / 2];
    let p99_idx = ((n as f64 * 0.99) as usize).min(n - 1);
    let p99 = copy[p99_idx];
    (Some(p50), Some(p99), n)
}

pub struct ControlMetrics {
    /// Wall-clock when the process started — exposed so dashboards can
    /// compute uptime-relative averages.
    start: Instant,

    sse_chunks_total: AtomicU64,
    sse_bytes_total: AtomicU64,
    sse_chunk_sizes: AtomicRingSamples<SAMPLE_BUFFER_SIZE>,

    events_endpoint_hits: AtomicEpochRateBuckets,
    events_latency_ms: AtomicRingSamples<SAMPLE_BUFFER_SIZE>,
    events_payload_bytes_total: AtomicU64,
    events_original_total: AtomicU64,
    events_summarized_total: AtomicU64,
    running_endpoint_hits: AtomicEpochRateBuckets,

    broadcast_events_total: AtomicU64,
    broadcast_lagged_total: AtomicU64,
    broadcast_dropped_total: AtomicU64,
    broadcast_events_by_mission: DashMap<uuid::Uuid, AtomicU64>,

    /// P5-#25 health budget reports — bounded ring of recent client
    /// telemetry pings. A client posts when its 5-second longtask total
    /// exceeds 2s; we keep the last 256 to surface in /metrics.
    health_reports: Mutex<Vec<HealthReport>>,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct HealthReport {
    pub mission_id: Option<uuid::Uuid>,
    pub longtask_total_ms: u64,
    pub longtask_max_ms: u64,
    pub event_count: u64,
    pub heap_used_mb: f64,
    pub dom_nodes: u64,
    /// Client wall-clock when the budget breach was observed (ms since epoch).
    pub at: u64,
}

impl Default for ControlMetrics {
    fn default() -> Self {
        Self::new()
    }
}

impl ControlMetrics {
    pub fn new() -> Self {
        let start = Instant::now();
        Self {
            start,
            sse_chunks_total: AtomicU64::new(0),
            sse_bytes_total: AtomicU64::new(0),
            sse_chunk_sizes: AtomicRingSamples::new(),
            events_endpoint_hits: AtomicEpochRateBuckets::new(start),
            events_latency_ms: AtomicRingSamples::new(),
            events_payload_bytes_total: AtomicU64::new(0),
            events_original_total: AtomicU64::new(0),
            events_summarized_total: AtomicU64::new(0),
            running_endpoint_hits: AtomicEpochRateBuckets::new(start),
            broadcast_events_total: AtomicU64::new(0),
            broadcast_lagged_total: AtomicU64::new(0),
            broadcast_dropped_total: AtomicU64::new(0),
            broadcast_events_by_mission: DashMap::new(),
            health_reports: Mutex::new(Vec::with_capacity(256)),
        }
    }

    /// Record a client-side health budget breach (P5-#25). Caps the
    /// in-memory ring at 256 entries so a runaway client can't OOM us.
    pub fn record_health_report(&self, report: HealthReport) {
        if let Ok(mut buf) = self.health_reports.lock() {
            if buf.len() >= 256 {
                buf.remove(0);
            }
            buf.push(report);
        }
    }

    /// Record a single SSE chunk emitted to a client.
    pub fn record_sse_chunk(&self, bytes: usize) {
        self.sse_chunks_total.fetch_add(1, Ordering::Relaxed);
        self.sse_bytes_total
            .fetch_add(bytes as u64, Ordering::Relaxed);
        self.sse_chunk_sizes.record(bytes as u64);
    }

    /// Record a single `/api/control/missions/:id/events` request hit.
    pub fn record_events_request(&self) {
        self.events_endpoint_hits.record_hit();
    }

    /// Record `/events` response characteristics after the handler has
    /// materialized the read-side payload.
    pub fn record_events_response(
        &self,
        latency: Duration,
        payload_bytes: usize,
        original_count: usize,
        summarized_count: usize,
    ) {
        self.events_latency_ms
            .record(latency.as_millis().min(u128::from(u64::MAX - 1)) as u64);
        self.events_payload_bytes_total
            .fetch_add(payload_bytes as u64, Ordering::Relaxed);
        self.events_original_total
            .fetch_add(original_count as u64, Ordering::Relaxed);
        self.events_summarized_total
            .fetch_add(summarized_count as u64, Ordering::Relaxed);
    }

    /// Record a single `/api/control/running` request hit.
    pub fn record_running_request(&self) {
        self.running_endpoint_hits.record_hit();
    }

    /// Record an `AgentEvent` broadcast to subscribers. `mission_id` is
    /// `None` for connection-scoped events (status / FIDO etc.).
    pub fn record_broadcast(&self, mission_id: Option<uuid::Uuid>) {
        self.broadcast_events_total.fetch_add(1, Ordering::Relaxed);
        if let Some(mid) = mission_id {
            if let Some(counter) = self.broadcast_events_by_mission.get(&mid) {
                counter.fetch_add(1, Ordering::Relaxed);
                return;
            }
            self.broadcast_events_by_mission
                .entry(mid)
                .or_insert_with(|| AtomicU64::new(0))
                .fetch_add(1, Ordering::Relaxed);
        }
    }

    /// Record broadcast receiver lag surfaced to clients as `stream_lagged`.
    pub fn record_broadcast_lag(&self, dropped: u64) {
        self.broadcast_lagged_total.fetch_add(1, Ordering::Relaxed);
        self.broadcast_dropped_total
            .fetch_add(dropped, Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> MetricsSnapshot {
        let (sse_p50, sse_p99, sample_count) = percentiles_from_ring(&self.sse_chunk_sizes);
        let (events_latency_p50, events_latency_p99, events_latency_sample_count) =
            percentiles_from_ring(&self.events_latency_ms);

        let now = Instant::now();
        let events_hits = self.events_endpoint_hits.count_last_window();
        let running_hits = self.running_endpoint_hits.count_last_window();

        let mut entries: Vec<(uuid::Uuid, u64)> = self
            .broadcast_events_by_mission
            .iter()
            .map(|entry| (*entry.key(), entry.value().load(Ordering::Relaxed)))
            .collect();
        let mission_count = entries.len();
        let total: u64 = entries.iter().map(|(_, v)| *v).sum();
        let events_avg_per_mission = if mission_count > 0 {
            total as f64 / mission_count as f64
        } else {
            0.0
        };
        entries.sort_unstable_by_key(|entry| std::cmp::Reverse(entry.1));
        let top_missions: Vec<TopMission> = entries
            .into_iter()
            .take(5)
            .map(|(mission_id, count)| TopMission { mission_id, count })
            .collect();

        let uptime_secs = now.saturating_duration_since(self.start).as_secs();

        let health_reports = self
            .health_reports
            .lock()
            .map(|v| v.clone())
            .unwrap_or_default();

        MetricsSnapshot {
            uptime_secs,
            health_reports,
            sse: SseStats {
                chunks_total: self.sse_chunks_total.load(Ordering::Relaxed),
                bytes_total: self.sse_bytes_total.load(Ordering::Relaxed),
                chunk_size_p50: sse_p50,
                chunk_size_p99: sse_p99,
                sample_count,
            },
            endpoints: EndpointStats {
                events_req_per_minute: events_hits,
                events_latency_p50_ms: events_latency_p50,
                events_latency_p99_ms: events_latency_p99,
                events_latency_sample_count,
                events_payload_bytes_total: self.events_payload_bytes_total.load(Ordering::Relaxed),
                events_original_total: self.events_original_total.load(Ordering::Relaxed),
                events_summarized_total: self.events_summarized_total.load(Ordering::Relaxed),
                running_req_per_minute: running_hits,
            },
            broadcast: BroadcastStats {
                events_total: self.broadcast_events_total.load(Ordering::Relaxed),
                lagged_total: self.broadcast_lagged_total.load(Ordering::Relaxed),
                dropped_total: self.broadcast_dropped_total.load(Ordering::Relaxed),
                mission_count_observed: mission_count,
                events_avg_per_mission,
                top_missions,
            },
        }
    }
}

#[derive(Debug, Serialize)]
pub struct MetricsSnapshot {
    pub uptime_secs: u64,
    pub sse: SseStats,
    pub endpoints: EndpointStats,
    pub broadcast: BroadcastStats,
    /// Most recent client-side health budget breaches (P5-#25).
    pub health_reports: Vec<HealthReport>,
}

#[derive(Debug, Serialize)]
pub struct SseStats {
    pub chunks_total: u64,
    pub bytes_total: u64,
    pub chunk_size_p50: Option<u64>,
    pub chunk_size_p99: Option<u64>,
    pub sample_count: usize,
}

#[derive(Debug, Serialize)]
pub struct EndpointStats {
    /// Hits in the last 60 seconds.
    pub events_req_per_minute: u64,
    pub events_latency_p50_ms: Option<u64>,
    pub events_latency_p99_ms: Option<u64>,
    pub events_latency_sample_count: usize,
    pub events_payload_bytes_total: u64,
    pub events_original_total: u64,
    pub events_summarized_total: u64,
    pub running_req_per_minute: u64,
}

#[derive(Debug, Serialize)]
pub struct BroadcastStats {
    pub events_total: u64,
    pub lagged_total: u64,
    pub dropped_total: u64,
    pub mission_count_observed: usize,
    pub events_avg_per_mission: f64,
    pub top_missions: Vec<TopMission>,
}

#[derive(Debug, Serialize)]
pub struct TopMission {
    pub mission_id: uuid::Uuid,
    pub count: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentiles_are_monotonic() {
        let m = ControlMetrics::new();
        for size in 1..=1000 {
            m.record_sse_chunk(size);
        }
        let snap = m.snapshot();
        let p50 = snap.sse.chunk_size_p50.unwrap();
        let p99 = snap.sse.chunk_size_p99.unwrap();
        assert!(p50 <= p99, "p50 must be <= p99: p50={p50} p99={p99}");
        assert!(p99 >= 900, "p99 of 1..=1000 should be near 1000, got {p99}");
    }

    #[test]
    fn broadcast_avg_handles_missions() {
        let m = ControlMetrics::new();
        let a = uuid::Uuid::new_v4();
        let b = uuid::Uuid::new_v4();
        m.record_broadcast(Some(a));
        m.record_broadcast(Some(a));
        m.record_broadcast(Some(b));
        m.record_broadcast(None); // status event, doesn't count toward per-mission
        m.record_broadcast_lag(7);
        let snap = m.snapshot();
        assert_eq!(snap.broadcast.events_total, 4);
        assert_eq!(snap.broadcast.lagged_total, 1);
        assert_eq!(snap.broadcast.dropped_total, 7);
        assert_eq!(snap.broadcast.mission_count_observed, 2);
        assert!((snap.broadcast.events_avg_per_mission - 1.5).abs() < 1e-9);
        assert_eq!(snap.broadcast.top_missions[0].mission_id, a);
        assert_eq!(snap.broadcast.top_missions[0].count, 2);
    }

    #[test]
    fn events_response_metrics_track_latency_payload_and_summary() {
        let m = ControlMetrics::new();
        m.record_events_response(Duration::from_millis(12), 4096, 100, 10);

        let snap = m.snapshot();
        assert_eq!(snap.endpoints.events_latency_p50_ms, Some(12));
        assert_eq!(snap.endpoints.events_latency_p99_ms, Some(12));
        assert_eq!(snap.endpoints.events_latency_sample_count, 1);
        assert_eq!(snap.endpoints.events_payload_bytes_total, 4096);
        assert_eq!(snap.endpoints.events_original_total, 100);
        assert_eq!(snap.endpoints.events_summarized_total, 10);
    }

    #[test]
    fn rate_window_trims_old_hits() {
        let m = ControlMetrics::new();
        m.record_events_request();
        let snap = m.snapshot();
        assert_eq!(snap.endpoints.events_req_per_minute, 1);
    }
}
