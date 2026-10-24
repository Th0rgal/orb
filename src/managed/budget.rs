//! Hierarchical managed-machine spending budgets (optional, off by default).
//!
//! A mission may carry a budget in USD. It is a pool shared with all its
//! descendants, until a mission below it gets its own (lower) budget: that
//! sub-budget is carved out of the parent pool and becomes the pool for its
//! own subtree. Missions without a budget draw from the nearest ancestor
//! pool; with no pool anywhere there is no limit beyond the global daily cap.
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

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::ManagedMachine;

/// Reservation horizon per live machine.
pub const RESERVE_MINUTES: i64 = 60;

/// One mission's budget. Keyed by mission id (the pool id).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BudgetPool {
    pub mission_id: String,
    pub budget_usd: f64,
    /// Nearest ancestor pool when this budget was set (the pool it carves
    /// from); `None` for a root pool.
    #[serde(default)]
    pub parent_pool_id: Option<String>,
    #[serde(default)]
    pub owner_user_id: Option<String>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct PoolUsage {
    pub pool_id: String,
    pub budget_usd: f64,
    pub spent_usd: f64,
    pub reserved_usd: f64,
    /// Held by child sub-budgets.
    pub carved_usd: f64,
    pub available_usd: f64,
    pub live_machines: usize,
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

/// Usage of `pool_id`. `open(mission_id)` tells whether a child pool's owner
/// still runs (its whole sub-budget stays carved) or ended (only its use).
pub fn pool_usage(
    pool_id: &str,
    pools: &HashMap<String, BudgetPool>,
    machines: &[ManagedMachine],
    now: DateTime<Utc>,
    open: &dyn Fn(&str) -> bool,
) -> Option<PoolUsage> {
    pool_usage_depth(pool_id, pools, machines, now, open, 0)
}

fn pool_usage_depth(
    pool_id: &str,
    pools: &HashMap<String, BudgetPool>,
    machines: &[ManagedMachine],
    now: DateTime<Utc>,
    open: &dyn Fn(&str) -> bool,
    depth: usize,
) -> Option<PoolUsage> {
    let pool = pools.get(pool_id)?;
    let mut spent = 0.0;
    let mut reserved = 0.0;
    let mut live = 0;
    for m in machines
        .iter()
        .filter(|m| m.budget_pool_id.as_deref() == Some(pool_id))
    {
        spent += machine_spent(m, now);
        reserved += machine_reserved(m, now);
        if m.state.is_live() {
            live += 1;
        }
    }
    let mut carved = 0.0;
    if depth < 32 {
        for child in pools
            .values()
            .filter(|p| p.parent_pool_id.as_deref() == Some(pool_id) && p.mission_id != pool_id)
        {
            if let Some(u) =
                pool_usage_depth(&child.mission_id, pools, machines, now, open, depth + 1)
            {
                let used = u.spent_usd + u.reserved_usd + u.carved_usd;
                carved += if open(&child.mission_id) {
                    used.max(child.budget_usd)
                } else {
                    used
                };
            }
        }
    }
    Some(PoolUsage {
        pool_id: pool_id.to_string(),
        budget_usd: pool.budget_usd,
        spent_usd: round4(spent),
        reserved_usd: round4(reserved),
        carved_usd: round4(carved),
        available_usd: round4(pool.budget_usd - spent - reserved - carved),
        live_machines: live,
    })
}

/// First mission in `lineage` (self first, then ancestors) that has a pool.
pub fn nearest_pool<'a>(
    lineage: impl IntoIterator<Item = &'a str>,
    pools: &HashMap<String, BudgetPool>,
) -> Option<String> {
    lineage
        .into_iter()
        .find(|id| pools.contains_key(*id))
        .map(str::to_string)
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

/// The error message an agent sees when a spend does not fit its pool.
pub fn exceeded_message(u: &PoolUsage, needed: f64, what: &str) -> String {
    format!(
        "Mission budget pool {} would be exceeded by {what}: needs ${needed:.4}, remaining ${:.4} of ${:.2} (spent ${:.4}, reserved ${:.4}, sub-budgets ${:.4}). Use a smaller size or shorter TTL, destroy idle machines, or ask the owner to raise the budget.",
        u.pool_id,
        u.available_usd.max(0.0),
        u.budget_usd,
        u.spent_usd,
        u.reserved_usd,
        u.carved_usd,
    )
}
