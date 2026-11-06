//! Hierarchical managed-machine spending budgets (optional, off by default).
//!
//! A mission may carry a budget in USD. It is a pool shared with all its
//! descendants, until a mission below it gets its own (lower) budget: that
//! sub-budget is carved out of the parent pool and becomes the pool for its
//! own subtree. Missions without a budget draw from the nearest ancestor
//! pool; an active pool overrides (bypasses) the shared global daily cap, while
//! missions with no pool anywhere are bounded by the shared global daily cap.
//!
//! The registry of machines doubles as the ledger: each machine records the
//! pool it is charged to (`budget_pool_id`). A pool's usage is derived:
//! - `spent`: metered (or estimated so far) cost of its machines;
//! - `reserved`: for each live machine, `min(remaining TTL, 60 min)` at its
//!   hourly price (TTL auto-extends in chunks while busy, each re-checked);
//! - `carved`: for each child pool, its budget while its owner is open, and
//!   only what it used once its owner is terminal (unused money returns);
//! - `available = budget - spent - reserved - carved`.
//!
//! Spec: `docs/specs/managed-vm-lifecycle.md` ("Budgets").

use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Datelike, Duration as ChronoDuration, Utc};
use serde::{Deserialize, Serialize};

use super::{ManagedMachine, CANONICAL_PROVIDERS};

/// Reservation horizon per live machine.
pub const RESERVE_MINUTES: i64 = 60;

/// Upper bound on any operator-specified per-mission VM concurrency override.
pub const MAX_VM_CONCURRENCY_LIMIT: usize = 128;

/// Bounds on per-mission inference & managed-compute bandwidth limits.
pub const MIN_TOKENS_PER_MIN: u64 = 1_000;
pub const MAX_TOKENS_PER_MIN: u64 = 100_000_000;
pub const MIN_INFERENCE_USD_PER_HOUR: f64 = 0.01;
pub const MAX_INFERENCE_USD_PER_HOUR: f64 = 10_000.0;
pub const MAX_COMPUTE_VCPU_PER_MIN: u32 = 4_096;
pub const MIN_COMPUTE_USD_PER_HOUR: f64 = 0.01;
pub const MAX_COMPUTE_USD_PER_HOUR: f64 = 10_000.0;

/// Reset cadence for a root mission spending budget (`parent_pool_id == None`).
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BudgetResetPeriod {
    /// Lifetime pool (never resets automatically).
    #[default]
    #[serde(alias = "none")]
    Total,
    /// Resets every UTC midnight (`00:00:00Z`).
    Daily,
    /// Resets every ISO Monday at `00:00:00Z`.
    Weekly,
}

impl BudgetResetPeriod {
    pub fn is_total(&self) -> bool {
        matches!(self, Self::Total)
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Total => "total",
            Self::Daily => "daily",
            Self::Weekly => "weekly",
        }
    }

    pub fn period_bounds(self, now: DateTime<Utc>) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
        period_bounds(self, now)
    }
}

/// Active `[period_start, period_resets_at)` UTC bounds for `period` at `now`,
/// or `None` when `period == Total`.
pub fn period_bounds(
    period: BudgetResetPeriod,
    now: DateTime<Utc>,
) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
    match period {
        BudgetResetPeriod::Total => None,
        BudgetResetPeriod::Daily => {
            let start = now.date_naive().and_hms_opt(0, 0, 0)?.and_utc();
            Some((start, start + ChronoDuration::days(1)))
        }
        BudgetResetPeriod::Weekly => {
            let days_from_monday = i64::from(now.weekday().num_days_from_monday());
            let monday = now.date_naive() - ChronoDuration::days(days_from_monday);
            let start = monday.and_hms_opt(0, 0, 0)?.and_utc();
            Some((start, start + ChronoDuration::days(7)))
        }
    }
}

/// Concurrency cap override for a mission and its descendants.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct VmConcurrencyLimits {
    /// Max concurrent live VMs across all providers in this pool (`1..=128`).
    /// When `None`, only providers in `provider_max_concurrent` are overridden.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_concurrent: Option<usize>,
    /// Optional per-provider concurrent live VM caps (`0..=128`, canonical provider keys).
    /// `0` blocks spawns on that provider for this subtree.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub provider_max_concurrent: BTreeMap<String, usize>,
}

impl VmConcurrencyLimits {
    pub fn covers(&self, provider: &str) -> bool {
        self.max_concurrent.is_some() || self.provider_max_concurrent.contains_key(provider)
    }

    pub fn is_empty(&self) -> bool {
        self.max_concurrent.is_none() && self.provider_max_concurrent.is_empty()
    }
}

/// Bandwidth (rate/pacing) limits for a mission and its descendants.
/// Exceeding these rates applies transparent pace/delay smoothing rather than
/// hard `429` rejections (unless a single VM exceeds the entire compute ceiling).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct BandwidthLimits {
    /// Optional LLM throughput ceiling in tokens per minute (`1_000..=100_000_000`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens_per_min: Option<u64>,
    /// Optional LLM dollar burn ceiling in USD per hour (`0.01..=10_000.0`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inference_usd_per_hour: Option<f64>,
    /// Optional active managed-compute vCPU bandwidth ceiling (`1..=4_096` vCPU-min/min).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compute_vcpu_per_min: Option<u32>,
    /// Optional active managed-compute burn ceiling in USD/hour (`0.01..=10_000.0`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compute_usd_per_hour: Option<f64>,
    /// When `true`, the mission owning this bandwidth pool bypasses pacing delays
    /// itself while pooled descendant subagents absorb the smoothing delay.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub protect_root: bool,
}

impl BandwidthLimits {
    pub fn is_empty(&self) -> bool {
        self.tokens_per_min.is_none()
            && self.inference_usd_per_hour.is_none()
            && self.compute_vcpu_per_min.is_none()
            && self.compute_usd_per_hour.is_none()
    }

    pub fn has_inference_limit(&self) -> bool {
        self.tokens_per_min.is_some() || self.inference_usd_per_hour.is_some()
    }

    pub fn has_compute_limit(&self) -> bool {
        self.compute_vcpu_per_min.is_some() || self.compute_usd_per_hour.is_some()
    }
}

/// One mission's budget, concurrency, and/or bandwidth override, keyed by mission id.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BudgetPool {
    pub mission_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget_usd: Option<f64>,
    /// Reset cadence for a root spending pool (`Total`, `Daily`, `Weekly`).
    /// Carved sub-budgets (`parent_pool_id.is_some()`) are always `Total`.
    #[serde(default, skip_serializing_if = "BudgetResetPeriod::is_total")]
    pub budget_reset_period: BudgetResetPeriod,
    /// Nearest ancestor pool with `budget_usd` when this budget was set (the
    /// pool it carves from); `None` for a root pool.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_pool_id: Option<String>,
    /// Optional concurrency cap override for this mission's subtree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vm_limits: Option<VmConcurrencyLimits>,
    /// Nearest ancestor pool with `vm_limits` when this override was set;
    /// `None` for a root cap pool.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_cap_pool_id: Option<String>,
    /// Optional bandwidth & pacing limits for this mission's subtree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bandwidth_limits: Option<BandwidthLimits>,
    /// Nearest ancestor pool with `bandwidth_limits` when this override was set;
    /// `None` for a root bandwidth pool.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_bandwidth_pool_id: Option<String>,
    #[serde(default)]
    pub owner_user_id: Option<String>,
    pub updated_at: DateTime<Utc>,
}

impl BudgetPool {
    pub fn has_any_override(&self) -> bool {
        self.budget_usd.is_some() || self.vm_limits.is_some() || self.bandwidth_limits.is_some()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LiveLease {
    pub remaining_secs: u64,
    pub usd_per_hour: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct PoolUsage {
    pub pool_id: String,
    pub budget_usd: f64,
    /// Spend attributed inside the active reset period (equals `lifetime_spent_usd` when `Total`).
    pub spent_usd: f64,
    /// Cumulative all-time spend attributed to this pool across all reset windows.
    pub lifetime_spent_usd: f64,
    pub reserved_usd: f64,
    /// Held by child sub-budgets.
    pub carved_usd: f64,
    pub available_usd: f64,
    pub live_machines: usize,
    /// Per-VM lease horizons for live machines charged directly to this pool,
    /// sorted by `remaining_secs` ascending so clients forecast exact `auto_extend` sweeps.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub live_leases: Vec<LiveLease>,
    pub reset_period: BudgetResetPeriod,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub period_started_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub period_resets_at: Option<DateTime<Utc>>,
}

fn round4(v: f64) -> f64 {
    (v * 10000.0).round() / 10000.0
}

/// Cost so far of one machine (metered, else estimated while unmetered).
pub fn machine_spent(m: &ManagedMachine, now: DateTime<Utc>) -> f64 {
    if m.state.is_live() && !m.cost_is_metered {
        m.cost_usd.max(m.estimated_cost(now))
    } else {
        m.cost_usd
    }
}

/// Open reservation of one machine: `min(remaining TTL, 60 min)` of price.
pub fn machine_reserved(m: &ManagedMachine, now: DateTime<Utc>) -> f64 {
    if !m.state.is_live() {
        return 0.0;
    }
    let secs = (m.expires_at - now)
        .num_seconds()
        .clamp(0, RESERVE_MINUTES * 60) as f64;
    secs / 3600.0 * m.usd_per_hour
}

/// Reservation a new machine (or an extension) of `ttl_minutes` needs.
pub fn reservation_for(ttl_minutes: u64, usd_per_hour: f64) -> f64 {
    (ttl_minutes.min(RESERVE_MINUTES as u64) as f64) / 60.0 * usd_per_hour
}

fn segment_cost_in_window(
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    cost_usd: f64,
    w0: DateTime<Utc>,
) -> f64 {
    if cost_usd <= 0.0 || end <= w0 {
        return 0.0;
    }
    if start >= w0 {
        return cost_usd;
    }
    let span = (end - start).num_milliseconds() as f64;
    let ov = (end - start.max(w0)).num_milliseconds().max(0) as f64;
    if span <= 0.0 {
        cost_usd
    } else {
        cost_usd * (ov / span).clamp(0.0, 1.0)
    }
}

/// Cost of one machine attributed to `pool_id` inside `[window_start, now]`
/// (or all-time when `window_start == None`).
fn machine_pool_spent_in_window(
    m: &ManagedMachine,
    pool_id: &str,
    now: DateTime<Utc>,
    window_start: Option<DateTime<Utc>>,
) -> f64 {
    let prior_here: f64 = m
        .prior_pool_charges
        .iter()
        .filter(|(p, _)| p == pool_id)
        .map(|(_, usd)| *usd)
        .sum();
    let current_here = if m.budget_pool_id.as_deref() == Some(pool_id) {
        (machine_spent(m, now) - m.pool_spent_offset).max(0.0)
    } else {
        0.0
    };
    let total_here = prior_here + current_here;
    if total_here <= 0.0 {
        return 0.0;
    }
    let Some(w0) = window_start else {
        return total_here;
    };
    let min_end = m.deletable_at.unwrap_or(m.created_at);
    let end = m
        .destroyed_at
        .or(m.stopped_at)
        .unwrap_or(now)
        .min(m.expires_at)
        .max(min_end.min(now))
        .max(m.created_at);

    // Exact ownership-interval accounting whenever billed segments have been
    // recorded across pool changes, stops, or resumes.
    if !m.billed_segments.is_empty() || m.segment_started_at.is_some() {
        let seg_sum: f64 = m.billed_segments.iter().map(|s| s.cost_usd).sum();
        let total_spent = machine_spent(m, now);
        // Defensive fallback if a non-live machine's metered `cost_usd` was
        // updated without running `reconcile_metered_cost`.
        let scale = if !m.state.is_live() && seg_sum > 1e-9 && (total_spent - seg_sum).abs() > 1e-6
        {
            (total_spent / seg_sum).max(0.0)
        } else {
            1.0
        };
        let mut sum = 0.0;
        for seg in &m.billed_segments {
            if seg.pool_id.as_deref() == Some(pool_id) {
                sum += segment_cost_in_window(seg.start, seg.end, seg.cost_usd * scale, w0);
            }
        }
        if m.state.is_live() && m.budget_pool_id.as_deref() == Some(pool_id) {
            let open_cost = (total_spent - m.segment_spent_offset).max(0.0);
            let seg_start = m
                .segment_started_at
                .or(m.run_started_at)
                .unwrap_or(m.created_at);
            sum += segment_cost_in_window(seg_start, end.max(seg_start), open_cost, w0);
        }
        return sum.min(total_here);
    }

    if end <= w0 {
        return 0.0;
    }
    if m.created_at >= w0 {
        return total_here;
    }
    let total_spent = machine_spent(m, now);
    if total_spent <= 0.0 {
        return 0.0;
    }
    // Legacy fallback for persisted machines that changed pools or resumed
    // before `billed_segments` existed: reconstruct sequential pre-handoff /
    // pre-resume intervals so neither prior-pool charges nor stopped gaps leak
    // across daily/weekly boundaries.
    if m.pool_spent_offset > 0.0 || !m.prior_pool_charges.is_empty() || m.cost_before_resume > 0.0 {
        let (legacy_segs, cur_start, accounted_offset) = m.legacy_pool_segments(end, total_spent);
        let mut sum = 0.0;
        for seg in &legacy_segs {
            if seg.pool_id.as_deref() == Some(pool_id) {
                sum += segment_cost_in_window(seg.start, seg.end, seg.cost_usd, w0);
            }
        }
        if m.budget_pool_id.as_deref() == Some(pool_id) {
            let open_cost = (total_spent - accounted_offset).max(0.0);
            let open_start = cur_start.max(m.run_started_at.unwrap_or(m.created_at));
            sum += segment_cost_in_window(open_start, end.max(open_start), open_cost, w0);
        }
        return sum.min(total_here);
    }
    segment_cost_in_window(m.created_at, end, total_spent, w0).min(total_here)
}

/// Usage of `pool_id`. `open(mission_id)` tells whether a child pool's owner
/// still runs (its whole sub-budget stays carved) or ended (only its use).
pub fn pool_usage(
    pool_id: &str,
    pools: &HashMap<String, BudgetPool>,
    machines: &[ManagedMachine],
    now: DateTime<Utc>,
    open: &dyn Fn(&str) -> bool,
) -> Option<PoolUsage> {
    pool_usage_depth(pool_id, pools, machines, now, open, 0, None)
}

fn pool_usage_depth(
    pool_id: &str,
    pools: &HashMap<String, BudgetPool>,
    machines: &[ManagedMachine],
    now: DateTime<Utc>,
    open: &dyn Fn(&str) -> bool,
    depth: usize,
    override_window_start: Option<DateTime<Utc>>,
) -> Option<PoolUsage> {
    let pool = pools.get(pool_id)?;
    let budget_usd = pool.budget_usd?;
    let effective_period = if pool.parent_pool_id.is_some() {
        BudgetResetPeriod::Total
    } else {
        pool.budget_reset_period
    };
    let bounds = period_bounds(effective_period, now);
    let window_start = override_window_start.or_else(|| bounds.map(|(s, _)| s));

    let mut lifetime_spent = 0.0;
    let mut window_spent = 0.0;
    let mut reserved = 0.0;
    let mut live = 0;
    let mut live_leases = Vec::new();
    for m in machines {
        lifetime_spent += machine_pool_spent_in_window(m, pool_id, now, None);
        window_spent += machine_pool_spent_in_window(m, pool_id, now, window_start);
        if m.budget_pool_id.as_deref() == Some(pool_id) {
            reserved += machine_reserved(m, now);
            if m.state.is_live() {
                live += 1;
                live_leases.push(LiveLease {
                    remaining_secs: (m.expires_at - now).num_seconds().max(0) as u64,
                    usd_per_hour: round4(m.usd_per_hour),
                });
            }
        }
    }
    live_leases.sort_by_key(|l| l.remaining_secs);
    let mut carved = 0.0;
    if depth < 32 {
        for child in pools.values().filter(|p| {
            p.budget_usd.is_some()
                && p.parent_pool_id.as_deref() == Some(pool_id)
                && p.mission_id != pool_id
        }) {
            if let Some(u) = pool_usage_depth(
                &child.mission_id,
                pools,
                machines,
                now,
                open,
                depth + 1,
                window_start,
            ) {
                let used = u.spent_usd + u.reserved_usd + u.carved_usd;
                let child_budget = child.budget_usd.unwrap_or(0.0);
                carved += if open(&child.mission_id) {
                    used.max(child_budget)
                } else {
                    used
                };
            }
        }
    }
    Some(PoolUsage {
        pool_id: pool_id.to_string(),
        budget_usd,
        spent_usd: round4(window_spent),
        lifetime_spent_usd: round4(lifetime_spent),
        reserved_usd: round4(reserved),
        carved_usd: round4(carved),
        available_usd: round4(budget_usd - window_spent - reserved - carved),
        live_machines: live,
        live_leases,
        reset_period: effective_period,
        period_started_at: bounds.map(|(s, _)| s),
        period_resets_at: bounds.map(|(_, e)| e),
    })
}

/// First mission in `lineage` (self first, then ancestors) that has a USD
/// spending pool owned by `user` (another tenant's pool is never selected).
pub fn nearest_pool<'a>(
    lineage: impl IntoIterator<Item = &'a str>,
    pools: &HashMap<String, BudgetPool>,
    user: &str,
) -> Option<String> {
    lineage
        .into_iter()
        .find(|id| {
            pools
                .get(*id)
                .is_some_and(|p| p.budget_usd.is_some() && p.owner_user_id.as_deref() == Some(user))
        })
        .map(str::to_string)
}

/// First mission in `lineage` (self first, then ancestors) that has a
/// `vm_limits` override owned by `user`.
pub fn nearest_cap_pool<'a>(
    lineage: impl IntoIterator<Item = &'a str>,
    pools: &HashMap<String, BudgetPool>,
    user: &str,
) -> Option<String> {
    lineage
        .into_iter()
        .find(|id| {
            pools
                .get(*id)
                .is_some_and(|p| p.vm_limits.is_some() && p.owner_user_id.as_deref() == Some(user))
        })
        .map(str::to_string)
}

/// First mission in `lineage` (self first, then ancestors) whose `vm_limits`
/// covers `provider` (`max_concurrent` set or `provider_max_concurrent[provider]` set).
pub fn nearest_cap_pool_for_provider<'a>(
    lineage: impl IntoIterator<Item = &'a str>,
    pools: &HashMap<String, BudgetPool>,
    user: &str,
    provider: &str,
) -> Option<String> {
    lineage
        .into_iter()
        .find(|id| {
            pools.get(*id).is_some_and(|p| {
                p.owner_user_id.as_deref() == Some(user)
                    && p.vm_limits.as_ref().is_some_and(|l| l.covers(provider))
            })
        })
        .map(str::to_string)
}

/// True when `leaf_pool` is `ancestor_pool` or descends from it via
/// `parent_cap_pool_id` (bounded, cycle-safe).
pub fn cap_pool_descends_from(
    leaf_pool: &str,
    ancestor_pool: &str,
    pools: &HashMap<String, BudgetPool>,
) -> bool {
    let mut cur = Some(leaf_pool);
    for _ in 0..32 {
        let Some(id) = cur else {
            return false;
        };
        if id == ancestor_pool {
            return true;
        }
        cur = pools.get(id).and_then(|p| p.parent_cap_pool_id.as_deref());
    }
    false
}

/// Live machine counts (`(pool_active, provider_active)`) attributed to
/// `pool_id` or any descendant cap pool below it.
pub fn cap_pool_counts(
    pool_id: &str,
    provider: &str,
    pools: &HashMap<String, BudgetPool>,
    machines: &[ManagedMachine],
) -> (usize, usize) {
    let mut total = 0usize;
    let mut prov = 0usize;
    for m in machines {
        if !m.state.is_live() {
            continue;
        }
        let Some(cp) = m.cap_pool_id.as_deref() else {
            continue;
        };
        if cap_pool_descends_from(cp, pool_id, pools) {
            total += 1;
            if m.provider == provider {
                prov += 1;
            }
        }
    }
    (total, prov)
}

/// Strict ancestor cap pools above `start_pool` (walking both
/// `parent_cap_pool_id` links and any remaining entries after `start_pool` in
/// `lineage` belonging to `user`).
pub fn ancestor_cap_chain(
    start_pool: &str,
    lineage: &[String],
    pools: &HashMap<String, BudgetPool>,
    user: Option<&str>,
) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = pools
        .get(start_pool)
        .and_then(|p| p.parent_cap_pool_id.as_deref());
    for _ in 0..32 {
        let Some(id) = cur else { break };
        if out.iter().any(|x| x == id) || id == start_pool {
            break;
        }
        if pools.get(id).is_some_and(|p| p.vm_limits.is_some()) {
            out.push(id.to_string());
        }
        cur = pools.get(id).and_then(|p| p.parent_cap_pool_id.as_deref());
    }
    if let Some(pos) = lineage.iter().position(|id| id == start_pool) {
        for anc in lineage.iter().skip(pos + 1) {
            if anc != start_pool
                && !out.iter().any(|x| x == anc)
                && pools.get(anc.as_str()).is_some_and(|p| {
                    p.vm_limits.is_some()
                        && user.is_none_or(|u| p.owner_user_id.as_deref() == Some(u))
                })
            {
                out.push(anc.clone());
            }
        }
    }
    out
}

/// Validate a budget amount from a client.
pub fn validate_amount(amount: f64) -> Result<f64, String> {
    if !amount.is_finite() || amount < 0.0 {
        return Err("budget_usd must be a non-negative number".into());
    }
    if amount > 100_000.0 {
        return Err("budget_usd is too large (max 100000)".into());
    }
    Ok(round4(amount))
}

/// Validate per-mission VM concurrency overrides from an operator client.
pub fn validate_vm_limits(raw: VmConcurrencyLimits) -> Result<VmConcurrencyLimits, String> {
    if let Some(total) = raw.max_concurrent {
        if !(1..=MAX_VM_CONCURRENCY_LIMIT).contains(&total) {
            return Err(format!(
                "max_concurrent must be between 1 and {MAX_VM_CONCURRENCY_LIMIT}"
            ));
        }
    }
    let mut provider_max_concurrent = BTreeMap::new();
    for (k, v) in raw.provider_max_concurrent {
        let key = k.trim().to_ascii_lowercase();
        if !CANONICAL_PROVIDERS.contains(&key.as_str()) {
            return Err(format!(
                "Unknown managed provider '{k}'; use {}",
                CANONICAL_PROVIDERS.join(", ")
            ));
        }
        if v > MAX_VM_CONCURRENCY_LIMIT {
            return Err(format!(
                "Limit for provider '{key}' must be between 0 and {MAX_VM_CONCURRENCY_LIMIT}"
            ));
        }
        if let Some(total) = raw.max_concurrent {
            if v > total {
                return Err(format!(
                    "Limit for provider '{key}' ({v}) cannot exceed max_concurrent ({total})"
                ));
            }
        }
        if provider_max_concurrent.insert(key.clone(), v).is_some() {
            return Err(format!("Duplicate provider limit for '{key}'"));
        }
    }
    let normalized = VmConcurrencyLimits {
        max_concurrent: raw.max_concurrent,
        provider_max_concurrent,
    };
    if normalized.is_empty() {
        return Err(
            "Set max_concurrent or at least one provider limit, or clear vm_limits to use the global cap"
                .into(),
        );
    }
    Ok(normalized)
}

/// First mission in `lineage` (self first, then ancestors) that has a
/// `bandwidth_limits` override owned by `user`.
pub fn nearest_bandwidth_pool<'a>(
    lineage: impl IntoIterator<Item = &'a str>,
    pools: &HashMap<String, BudgetPool>,
    user: &str,
) -> Option<String> {
    lineage
        .into_iter()
        .find(|id| {
            pools.get(*id).is_some_and(|p| {
                p.bandwidth_limits.is_some() && p.owner_user_id.as_deref() == Some(user)
            })
        })
        .map(str::to_string)
}

/// First mission in `lineage` (self first, then ancestors) whose
/// `bandwidth_limits` sets a compute ceiling (`compute_vcpu_per_min` or
/// `compute_usd_per_hour`) owned by `user`.
pub fn nearest_compute_bandwidth_pool<'a>(
    lineage: impl IntoIterator<Item = &'a str>,
    pools: &HashMap<String, BudgetPool>,
    user: &str,
) -> Option<String> {
    lineage
        .into_iter()
        .find(|id| {
            pools.get(*id).is_some_and(|p| {
                p.owner_user_id.as_deref() == Some(user)
                    && p.bandwidth_limits
                        .as_ref()
                        .is_some_and(BandwidthLimits::has_compute_limit)
            })
        })
        .map(str::to_string)
}

/// True when `leaf_pool` is `ancestor_pool` or descends from it via
/// `parent_bandwidth_pool_id` (bounded, cycle-safe).
pub fn bandwidth_pool_descends_from(
    leaf_pool: &str,
    ancestor_pool: &str,
    pools: &HashMap<String, BudgetPool>,
) -> bool {
    let mut cur = Some(leaf_pool);
    for _ in 0..32 {
        let Some(id) = cur else {
            return false;
        };
        if id == ancestor_pool {
            return true;
        }
        cur = pools
            .get(id)
            .and_then(|p| p.parent_bandwidth_pool_id.as_deref());
    }
    false
}

/// Live compute bandwidth (`(active_vcpu, active_usd_per_hour)`) attributed to
/// `pool_id` or any descendant bandwidth pool below it (or live VMs charged to
/// `pool_id`'s USD budget pool when `bandwidth_pool_id` was not yet populated).
pub fn bandwidth_pool_compute_usage(
    pool_id: &str,
    pools: &HashMap<String, BudgetPool>,
    machines: &[ManagedMachine],
) -> (u32, f64) {
    let mut vcpu = 0u32;
    let mut usd_per_h = 0.0f64;
    for m in machines {
        if !m.state.is_live() {
            continue;
        }
        let matches_bw = m
            .bandwidth_pool_id
            .as_deref()
            .is_some_and(|bp| bandwidth_pool_descends_from(bp, pool_id, pools));
        let matches_owner = m.bandwidth_pool_id.is_none()
            && (m.owner_mission_id.as_deref() == Some(pool_id)
                || m.budget_pool_id.as_deref() == Some(pool_id)
                || m.cap_pool_id.as_deref() == Some(pool_id));
        if matches_bw || matches_owner {
            vcpu = vcpu.saturating_add(m.cpu);
            usd_per_h += m.usd_per_hour;
        }
    }
    (vcpu, round4(usd_per_h))
}

/// Strict ancestor bandwidth pools above `start_pool`.
pub fn ancestor_bandwidth_chain(
    start_pool: &str,
    lineage: &[String],
    pools: &HashMap<String, BudgetPool>,
    user: Option<&str>,
) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = pools
        .get(start_pool)
        .and_then(|p| p.parent_bandwidth_pool_id.as_deref());
    for _ in 0..32 {
        let Some(id) = cur else { break };
        if out.iter().any(|x| x == id) || id == start_pool {
            break;
        }
        if pools.get(id).is_some_and(|p| p.bandwidth_limits.is_some()) {
            out.push(id.to_string());
        }
        cur = pools
            .get(id)
            .and_then(|p| p.parent_bandwidth_pool_id.as_deref());
    }
    if let Some(pos) = lineage.iter().position(|id| id == start_pool) {
        for anc in lineage.iter().skip(pos + 1) {
            if anc != start_pool
                && !out.iter().any(|x| x == anc)
                && pools.get(anc.as_str()).is_some_and(|p| {
                    p.bandwidth_limits.is_some()
                        && user.is_none_or(|u| p.owner_user_id.as_deref() == Some(u))
                })
            {
                out.push(anc.clone());
            }
        }
    }
    out
}

/// Validate per-mission bandwidth/pacing overrides from an operator client.
pub fn validate_bandwidth_limits(raw: BandwidthLimits) -> Result<BandwidthLimits, String> {
    if let Some(tpm) = raw.tokens_per_min {
        if !(MIN_TOKENS_PER_MIN..=MAX_TOKENS_PER_MIN).contains(&tpm) {
            return Err(format!(
                "tokens_per_min must be between {MIN_TOKENS_PER_MIN} and {MAX_TOKENS_PER_MIN}"
            ));
        }
    }
    let inference_usd_per_hour = match raw.inference_usd_per_hour {
        None => None,
        Some(rate) => {
            if !rate.is_finite()
                || !(MIN_INFERENCE_USD_PER_HOUR..=MAX_INFERENCE_USD_PER_HOUR).contains(&rate)
            {
                return Err(format!(
                    "inference_usd_per_hour must be between {MIN_INFERENCE_USD_PER_HOUR:.2} and {MAX_INFERENCE_USD_PER_HOUR:.0}"
                ));
            }
            Some(round4(rate))
        }
    };
    if let Some(vcpu) = raw.compute_vcpu_per_min {
        if !(1..=MAX_COMPUTE_VCPU_PER_MIN).contains(&vcpu) {
            return Err(format!(
                "compute_vcpu_per_min must be between 1 and {MAX_COMPUTE_VCPU_PER_MIN}"
            ));
        }
    }
    let compute_usd_per_hour = match raw.compute_usd_per_hour {
        None => None,
        Some(rate) => {
            if !rate.is_finite()
                || !(MIN_COMPUTE_USD_PER_HOUR..=MAX_COMPUTE_USD_PER_HOUR).contains(&rate)
            {
                return Err(format!(
                    "compute_usd_per_hour must be between {MIN_COMPUTE_USD_PER_HOUR:.2} and {MAX_COMPUTE_USD_PER_HOUR:.0}"
                ));
            }
            Some(round4(rate))
        }
    };
    let normalized = BandwidthLimits {
        tokens_per_min: raw.tokens_per_min,
        inference_usd_per_hour,
        compute_vcpu_per_min: raw.compute_vcpu_per_min,
        compute_usd_per_hour,
        protect_root: raw.protect_root,
    };
    if normalized.is_empty() {
        return Err(
            "Set tokens_per_min, inference_usd_per_hour, compute_vcpu_per_min, or compute_usd_per_hour, or clear bandwidth_limits to disable pacing"
                .into(),
        );
    }
    Ok(normalized)
}

/// The error message an agent sees when a spend does not fit its pool.
pub fn exceeded_message(u: &PoolUsage, needed: f64, what: &str) -> String {
    let period_note = match (u.reset_period, u.period_resets_at) {
        (BudgetResetPeriod::Daily, Some(r)) => {
            format!("; daily pool resets at {}", r.format("%H:%M UTC"))
        }
        (BudgetResetPeriod::Weekly, Some(r)) => {
            format!("; weekly pool resets at {}", r.format("%Y-%m-%d %H:%M UTC"))
        }
        _ => String::new(),
    };
    format!(
        "Mission budget pool {} would be exceeded by {what}: needs ${needed:.4}, remaining ${:.4} of ${:.2} (spent ${:.4}, reserved ${:.4}, sub-budgets ${:.4}{period_note}). Use a smaller size or shorter TTL, destroy idle machines, or ask the owner to raise the budget.",
        u.pool_id,
        u.available_usd.max(0.0),
        u.budget_usd,
        u.spent_usd,
        u.reserved_usd,
        u.carved_usd,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::managed::MachineState;

    #[test]
    fn pool_usage_sorts_live_leases_by_remaining_ttl_and_skips_empty_in_json() {
        let now = Utc::now();
        let mut pools = HashMap::new();
        pools.insert(
            "root".to_string(),
            BudgetPool {
                mission_id: "root".to_string(),
                budget_usd: Some(50.0),
                budget_reset_period: BudgetResetPeriod::Total,
                parent_pool_id: None,
                vm_limits: None,
                parent_cap_pool_id: None,
                bandwidth_limits: None,
                parent_bandwidth_pool_id: None,
                owner_user_id: Some("u1".to_string()),
                updated_at: now,
            },
        );
        let mk = |id: &str, rem_mins: i64, rate: f64, state: MachineState| {
            let mut m: ManagedMachine = serde_json::from_value(serde_json::json!({
                "id": id,
                "node_id": id,
                "name": id,
                "provider": "boat",
                "size": "small",
                "cpu": 2,
                "ram_gb": 4,
                "disk_gb": 20,
                "image": "ubuntu",
                "state": "online",
                "budget_pool_id": "root",
                "created_at": now,
                "expires_at": now + ChronoDuration::minutes(rem_mins),
                "usd_per_hour": rate,
                "cost_usd": 0.0,
                "cost_is_metered": true,
                "ledger_closed": false,
            }))
            .unwrap();
            m.state = state;
            m
        };

        let empty_usage = pool_usage("root", &pools, &[], now, &|_| true).unwrap();
        assert!(empty_usage.live_leases.is_empty());
        let empty_json = serde_json::to_value(&empty_usage).unwrap();
        assert!(empty_json.get("live_leases").is_none());

        let machines = vec![
            mk("m-late", 25, 5.0, MachineState::Online),
            mk("m-early", 10, 2.5, MachineState::Online),
            mk("m-stopped", 5, 8.0, MachineState::Stopped),
        ];
        let usage = pool_usage("root", &pools, &machines, now, &|_| true).unwrap();
        assert_eq!(
            usage.live_leases,
            vec![
                LiveLease {
                    remaining_secs: 600,
                    usd_per_hour: 2.5,
                },
                LiveLease {
                    remaining_secs: 1500,
                    usd_per_hour: 5.0,
                },
            ]
        );
    }
}
