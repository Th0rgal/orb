//! Token-bucket & rolling-rate pacing for mission bandwidth pools.
//!
//! When a `BudgetPool` sets `bandwidth_limits.tokens_per_min`, routed LLM
//! requests attributed to missions in that pool's subtree check their debt
//! before dispatching upstream and sleep transparently (`pace/delay`) instead
//! of failing with synthetic `429` errors. Editing or clearing a bandwidth pool
//! immediately wakes any sleeping requests via `Notify`.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use tokio::sync::Notify;

/// Maximum per-request sleep applied by token-bandwidth pacing so harness and
/// HTTP client socket timeouts never mistake intentional pacing for a dead
/// connection. Sustained bursts stack smoothly across consecutive turns.
pub const MAX_INFERENCE_PACE_DELAY_MS: u64 = 30_000;

/// Maximum wait applied to a transient managed-VM spawn/resume when active
/// subtree compute bandwidth (`vCPU-min/min` or `$/h`) is temporarily full.
pub const MAX_COMPUTE_PACE_DELAY: Duration = Duration::from_secs(45);

/// Rolling window used to report live `current_tokens_per_min` in Mission Settings.
const RATE_WINDOW: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, Copy)]
struct TokenSample {
    at: Instant,
    tokens: u64,
}

#[derive(Debug)]
struct PoolPacerEntry {
    /// Outstanding token*ms debt (`tokens * 60_000`) above instantaneous
    /// allowance, maintained via `orb_pool_pacer_step` without `f64` drift.
    debt_token_ms: u64,
    last_updated: Instant,
    /// Rolling recent token samples (`<= RATE_WINDOW`) for live UI telemetry.
    samples: VecDeque<TokenSample>,
    /// Concurrent requests currently awaiting a pacing delay in this pool.
    active_waiters: usize,
    /// Last computed delay (ms) when `debt_token_ms > 0`, decayed as debt drains.
    last_delay_ms: u64,
}

impl PoolPacerEntry {
    fn new(now: Instant) -> Self {
        Self {
            debt_token_ms: 0,
            last_updated: now,
            samples: VecDeque::new(),
            active_waiters: 0,
            last_delay_ms: 0,
        }
    }

    fn prune_samples(&mut self, now: Instant) {
        while let Some(front) = self.samples.front() {
            if now.saturating_duration_since(front.at) > RATE_WINDOW {
                self.samples.pop_front();
            } else {
                break;
            }
        }
    }

    fn advance_and_add(
        &mut self,
        now: Instant,
        rate_tokens_per_min: Option<u64>,
        added_tokens: u64,
    ) {
        let elapsed_ms = now
            .saturating_duration_since(self.last_updated)
            .as_millis()
            .min(u128::from(u64::MAX)) as u64;
        self.last_updated = now;
        let tpm = rate_tokens_per_min.unwrap_or(0);
        self.debt_token_ms = crate::orb_spec::pool_pacer_next_debt_token_ms(
            self.debt_token_ms,
            elapsed_ms,
            tpm,
            added_tokens,
            MAX_INFERENCE_PACE_DELAY_MS,
        );
        self.prune_samples(now);
    }

    fn advance(&mut self, now: Instant, rate_tokens_per_min: Option<u64>) {
        self.advance_and_add(now, rate_tokens_per_min, 0);
    }

    fn delay_ms(&self, rate_tokens_per_min: u64) -> u64 {
        if rate_tokens_per_min == 0 || self.debt_token_ms == 0 {
            return 0;
        }
        crate::orb_spec::pool_pacer_delay_ms(
            self.debt_token_ms,
            0,
            rate_tokens_per_min,
            0,
            MAX_INFERENCE_PACE_DELAY_MS,
        )
    }

    fn observed_tokens_per_min(&self, now: Instant) -> u64 {
        if self.samples.is_empty() {
            return 0;
        }
        let sum: u64 = self.samples.iter().map(|s| s.tokens).sum();
        if sum == 0 {
            return 0;
        }
        // Normalize over a minimum 60s denominator so a single turn of 4k tokens
        // reads as 4k tok/min rather than extrapolating 100ms into millions/min.
        let oldest = self
            .samples
            .front()
            .map(|s| now.saturating_duration_since(s.at).as_secs_f64())
            .unwrap_or(60.0)
            .clamp(60.0, RATE_WINDOW.as_secs_f64());
        ((sum as f64) * (60.0 / oldest)).round() as u64
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PoolPacingSnapshot {
    pub current_tokens_per_min: u64,
    pub pacing_active: bool,
    pub paced_delay_ms: u64,
    pub active_waiters: usize,
}

struct PacingHub {
    pools: Mutex<HashMap<String, PoolPacerEntry>>,
    notify: Notify,
}

static HUB: OnceLock<Arc<PacingHub>> = OnceLock::new();

fn hub() -> &'static Arc<PacingHub> {
    HUB.get_or_init(|| {
        Arc::new(PacingHub {
            pools: Mutex::new(HashMap::new()),
            notify: Notify::new(),
        })
    })
}

/// Wake all in-flight inference or compute pacing waiters (called when
/// bandwidth limits change or a live managed VM stops/destroys).
pub fn notify_capacity_changed() {
    hub().notify.notify_waiters();
}

/// Wait for either `duration` or an explicit capacity/limit change notification.
pub async fn wait_or_notified(duration: Duration) {
    if duration.is_zero() {
        return;
    }
    let notified = hub().notify.notified();
    let _ = tokio::time::timeout(duration, notified).await;
}

/// Reset token debt for `pool_id` when its `tokens_per_min` limit is cleared.
pub fn clear_pool_debt(pool_id: &str) {
    if let Ok(mut map) = hub().pools.lock() {
        if let Some(entry) = map.get_mut(pool_id) {
            entry.debt_token_ms = 0;
            entry.last_delay_ms = 0;
        }
    }
    notify_capacity_changed();
}

/// Pure calculation of required delay in milliseconds for `(pool_id, tokens_per_min)`
/// constraints at `now`.
pub fn compute_inference_delay_ms(constraints: &[(String, u64)]) -> u64 {
    compute_inference_delay_at(constraints, Instant::now())
}

fn compute_inference_delay_at(constraints: &[(String, u64)], now: Instant) -> u64 {
    if constraints.is_empty() {
        return 0;
    }
    let Ok(mut map) = hub().pools.lock() else {
        return 0;
    };
    let mut max_delay = 0u64;
    for (pool_id, tpm) in constraints {
        let entry = map
            .entry(pool_id.clone())
            .or_insert_with(|| PoolPacerEntry::new(now));
        entry.advance(now, Some(*tpm));
        let d = entry.delay_ms(*tpm);
        entry.last_delay_ms = d;
        if d > max_delay {
            max_delay = d;
        }
    }
    max_delay
}

struct WaiterGuard {
    pool_ids: Vec<String>,
}

impl WaiterGuard {
    fn enter(pool_ids: Vec<String>) -> Self {
        if let Ok(mut map) = hub().pools.lock() {
            let now = Instant::now();
            for id in &pool_ids {
                let entry = map
                    .entry(id.clone())
                    .or_insert_with(|| PoolPacerEntry::new(now));
                entry.active_waiters = entry.active_waiters.saturating_add(1);
            }
        }
        Self { pool_ids }
    }
}

impl Drop for WaiterGuard {
    fn drop(&mut self) {
        if let Ok(mut map) = hub().pools.lock() {
            for id in &self.pool_ids {
                if let Some(entry) = map.get_mut(id) {
                    entry.active_waiters = entry.active_waiters.saturating_sub(1);
                }
            }
        }
    }
}

/// Record billed token usage (`input + output + reasoning`) against all pools in
/// `pool_rates` (`(pool_id, configured_tokens_per_min)`). Also records rolling
/// telemetry even when `tokens_per_min` is `None` (compute-only bandwidth pool).
pub fn record_pool_tokens(pool_rates: &[(String, Option<u64>)], tokens: u64) {
    record_pool_tokens_at(pool_rates, tokens, Instant::now());
}

fn record_pool_tokens_at(pool_rates: &[(String, Option<u64>)], tokens: u64, now: Instant) {
    if tokens == 0 || pool_rates.is_empty() {
        return;
    }
    let Ok(mut map) = hub().pools.lock() else {
        return;
    };
    for (pool_id, rate_opt) in pool_rates {
        let entry = map
            .entry(pool_id.clone())
            .or_insert_with(|| PoolPacerEntry::new(now));
        entry.advance_and_add(now, *rate_opt, tokens);
        entry.samples.push_back(TokenSample { at: now, tokens });
        if let Some(tpm) = rate_opt.filter(|&r| r > 0) {
            entry.last_delay_ms = entry.delay_ms(tpm);
        }
    }
    if map.len() > 256 {
        map.retain(|_, e| {
            e.active_waiters > 0
                || e.debt_token_ms > 0
                || now.saturating_duration_since(e.last_updated) < Duration::from_secs(600)
        });
    }
}

/// Snapshot live token throughput and pacing status for `pool_id`.
pub fn snapshot_pool(pool_id: &str, rate_tokens_per_min: Option<u64>) -> PoolPacingSnapshot {
    let now = Instant::now();
    let Ok(mut map) = hub().pools.lock() else {
        return PoolPacingSnapshot::default();
    };
    let Some(entry) = map.get_mut(pool_id) else {
        return PoolPacingSnapshot::default();
    };
    entry.advance(now, rate_tokens_per_min);
    let delay = rate_tokens_per_min.map_or(0, |tpm| entry.delay_ms(tpm));
    entry.last_delay_ms = delay;
    PoolPacingSnapshot {
        current_tokens_per_min: entry.observed_tokens_per_min(now),
        pacing_active: delay > 0 || entry.active_waiters > 0,
        paced_delay_ms: delay,
        active_waiters: entry.active_waiters,
    }
}

/// Sleep transparently until `constraints` (`(pool_id, tokens_per_min)`) drain
/// or `MAX_INFERENCE_PACE_DELAY_MS` elapses, re-evaluating if limits are edited
/// mid-sleep and touching `on_tick` periodically to keep liveness fresh.
pub async fn pace_for_constraints<F>(mut resolve_constraints: F, mut on_tick: impl FnMut()) -> u64
where
    F: FnMut() -> Vec<(String, u64)>,
{
    let initial = resolve_constraints();
    let first_delay = compute_inference_delay_ms(&initial);
    if first_delay == 0 {
        return 0;
    }
    let pool_ids: Vec<String> = initial.into_iter().map(|(id, _)| id).collect();
    let _guard = WaiterGuard::enter(pool_ids);
    let started = Instant::now();
    let hard_cap = Duration::from_millis(MAX_INFERENCE_PACE_DELAY_MS);
    loop {
        let elapsed = started.elapsed();
        if elapsed >= hard_cap {
            break;
        }
        let current = resolve_constraints();
        let remaining_need = compute_inference_delay_ms(&current);
        if remaining_need == 0 {
            break;
        }
        let budget_left = hard_cap.saturating_sub(elapsed);
        let step = Duration::from_millis(remaining_need)
            .min(budget_left)
            .min(Duration::from_secs(5));
        on_tick();
        wait_or_notified(step).await;
    }
    on_tick();
    started.elapsed().as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_bucket_accumulates_debt_and_drains_over_time() {
        let pool = format!("test-pool-{}", uuid::Uuid::new_v4());
        let t0 = Instant::now();
        // Limit: 60_000 tok/min = 1_000 tok/sec = 1 tok/ms.
        record_pool_tokens_at(&[(pool.clone(), Some(60_000))], 5_000, t0);
        let d0 = compute_inference_delay_at(&[(pool.clone(), 60_000)], t0);
        assert_eq!(d0, 5_000);

        // After 3 seconds, 3_000 tokens drain -> 2_000 ms remaining delay.
        let t1 = t0 + Duration::from_secs(3);
        let d1 = compute_inference_delay_at(&[(pool.clone(), 60_000)], t1);
        assert_eq!(d1, 2_000);

        // After another 3 seconds, debt reaches 0.
        let t2 = t1 + Duration::from_secs(3);
        let d2 = compute_inference_delay_at(&[(pool.clone(), 60_000)], t2);
        assert_eq!(d2, 0);
    }

    #[test]
    fn delay_is_bounded_by_max_inference_pace_delay() {
        let pool = format!("test-cap-{}", uuid::Uuid::new_v4());
        let t0 = Instant::now();
        // Limit: 10_000 tok/min; record 20_000 tokens -> 2 min debt, capped at 30_000 ms.
        record_pool_tokens_at(&[(pool.clone(), Some(10_000))], 20_000, t0);
        let d = compute_inference_delay_at(&[(pool, 10_000)], t0);
        assert_eq!(d, MAX_INFERENCE_PACE_DELAY_MS);
    }
}
