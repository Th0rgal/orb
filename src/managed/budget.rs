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

use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::{ManagedMachine, CANONICAL_PROVIDERS};

/// Reservation horizon per live machine.
pub const RESERVE_MINUTES: i64 = 60;

/// Upper bound on any operator-specified per-mission VM concurrency override.
pub const MAX_VM_CONCURRENCY_LIMIT: usize = 128;

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

/// One mission's budget and/or concurrency override, keyed by mission id.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BudgetPool {
    pub mission_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget_usd: Option<f64>,
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
    let budget_usd = pool.budget_usd?;
    let mut spent = 0.0;
    let mut reserved = 0.0;
    let mut live = 0;
    for m in machines {
        // Cost charged here before the VM moved to another pool.
        spent += m
            .prior_pool_charges
            .iter()
            .filter(|(p, _)| p == pool_id)
            .map(|(_, usd)| usd)
            .sum::<f64>();
        if m.budget_pool_id.as_deref() != Some(pool_id) {
            continue;
        }
        spent += (machine_spent(m, now) - m.pool_spent_offset).max(0.0);
        reserved += machine_reserved(m, now);
        if m.state.is_live() {
            live += 1;
        }
    }
    let mut carved = 0.0;
    if depth < 32 {
        for child in pools.values().filter(|p| {
            p.budget_usd.is_some()
                && p.parent_pool_id.as_deref() == Some(pool_id)
                && p.mission_id != pool_id
        }) {
            if let Some(u) =
                pool_usage_depth(&child.mission_id, pools, machines, now, open, depth + 1)
            {
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
        spent_usd: round4(spent),
        reserved_usd: round4(reserved),
        carved_usd: round4(carved),
        available_usd: round4(budget_usd - spent - reserved - carved),
        live_machines: live,
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
