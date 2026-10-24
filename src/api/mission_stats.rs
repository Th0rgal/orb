//! Mission spend statistics (statistics only, no enforcement).
//!
//! `GET /api/control/missions/:id/stats?period=today|lifetime` returns what a
//! mission and its subagents cost, in one USD unit:
//! - LLM requests from the usage ledger (`docs/specs/usage-attribution.md`),
//!   grouped by the `(provider, model)` that actually served each request
//!   (the proxy records the final successful attempt, not the chain name);
//! - managed VM cost (boat), charged to the VM's owner mission.
//!
//! Pricing per request:
//! - metered: the ledger's list price (re-priced from tokens when known);
//! - subscription (Antigravity, Muse, OAuth accounts…): a shadow price from
//!   the configurable table (`.sandboxed-sh/shadow_prices.json`, `GET/PUT
//!   /api/usage/shadow-prices`), else the model's list price, flagged
//!   `shadow_priced`; never shown as a silent $0 (`unpriced` when neither);
//! - local (Spark): 0.
//!
//! Each request is settled once through the verified kernel step
//! (`orb_stats_settle_step`, keyed by the ledger row id). Conservation of the
//! grouping (mission total = Σ served models + VMs; subtree = own + Σ
//! children) is proved in `lean/Orb/Spec.lean` (`statBuckets_conserve`) and
//! checked by the tests below. Spec: `docs/specs/mission-stats.md`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
    Extension, Json, Router,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

use super::auth::AuthUser;
use super::mission_store::{MissionStore, UsageRecord};
use super::routes::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/control/missions/:id/stats", get(get_stats))
        .route(
            "/api/usage/shadow-prices",
            get(get_shadow_prices).put(put_shadow_prices),
        )
}

// ------------------------------------------------------------ shadow prices

/// USD per million tokens.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct TokenPrice {
    #[serde(default)]
    pub input: f64,
    #[serde(default)]
    pub cache_read: f64,
    #[serde(default)]
    pub cache_write: f64,
    #[serde(default)]
    pub output: f64,
}

/// How requests are billed, and the shadow prices of subscriptions.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShadowPrices {
    /// Providers paid by subscription (served requests cost nothing extra).
    #[serde(default)]
    pub subscription_providers: Vec<String>,
    /// Provider accounts paid by subscription (OAuth logins on a metered
    /// provider, e.g. a ChatGPT-backed Codex account).
    #[serde(default)]
    pub subscription_accounts: Vec<String>,
    /// Local inference (free).
    #[serde(default)]
    pub local_providers: Vec<String>,
    /// `provider/model` or `provider` -> price per million tokens.
    #[serde(default)]
    pub prices: BTreeMap<String, TokenPrice>,
}

impl Default for ShadowPrices {
    fn default() -> Self {
        Self {
            subscription_providers: vec!["antigravity".into(), "muse-code".into()],
            subscription_accounts: Vec::new(),
            local_providers: vec!["spark".into(), "local".into()],
            prices: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Billing {
    Metered,
    Subscription,
    Local,
}

impl ShadowPrices {
    fn path(working_dir: &std::path::Path) -> std::path::PathBuf {
        working_dir.join(".sandboxed-sh").join("shadow_prices.json")
    }

    pub fn load(working_dir: &std::path::Path) -> Self {
        std::fs::read(Self::path(working_dir))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn billing(&self, r: &UsageRecord) -> Billing {
        let provider = r.provider.as_deref().unwrap_or_default();
        if self.local_providers.iter().any(|p| p == provider) {
            Billing::Local
        } else if self.subscription_providers.iter().any(|p| p == provider)
            || r.account_id
                .as_deref()
                .is_some_and(|a| self.subscription_accounts.iter().any(|s| s == a))
        {
            Billing::Subscription
        } else {
            Billing::Metered
        }
    }

    fn table_price(&self, provider: &str, model: &str) -> Option<TokenPrice> {
        self.prices
            .get(&format!("{provider}/{model}"))
            .or_else(|| self.prices.get(provider))
            .copied()
    }
}

/// Cents for one request, and whether it is shadow-priced / priced at all.
pub fn price_cents(r: &UsageRecord, table: &ShadowPrices) -> (u64, bool, bool) {
    match table.billing(r) {
        Billing::Local => (0, false, true),
        Billing::Metered => (r.cost_cents, false, r.cost_known),
        Billing::Subscription => {
            let provider = r.provider.as_deref().unwrap_or_default();
            if let Some(p) = table.table_price(provider, &r.model) {
                let usd = (r.input_tokens as f64 * p.input
                    + r.cache_read_tokens as f64 * p.cache_read
                    + r.cache_creation_tokens as f64 * p.cache_write
                    + r.output_tokens as f64 * p.output)
                    / 1_000_000.0;
                ((usd * 100.0).round().max(0.0) as u64, true, true)
            } else if crate::cost::has_pricing(&r.model) {
                // The model's list price as the shadow price.
                (r.cost_cents, true, true)
            } else {
                (0, true, false)
            }
        }
    }
}

// -------------------------------------------------------------- aggregation

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub struct ModelLine {
    pub provider: Option<String>,
    pub model: String,
    pub requests: u64,
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub output_tokens: u64,
    pub cost_usd: f64,
    /// Priced from the subscription shadow table (not money paid per use).
    pub shadow_priced: bool,
    /// Some requests had no price at all (counted as 0, flagged).
    pub unpriced: bool,
    #[serde(skip)]
    cents: u64,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub struct OwnStats {
    pub models: Vec<ModelLine>,
    pub vm_usd: f64,
    pub total_usd: f64,
    #[serde(skip)]
    pub total_cents: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ChildStats {
    pub mission_id: String,
    pub title: Option<String>,
    /// The child and its own subagents.
    pub total_usd: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct MissionStats {
    pub mission_id: String,
    pub period: &'static str,
    pub since: Option<DateTime<Utc>>,
    pub own: OwnStats,
    /// Own plus every subagent below.
    pub subtree_total_usd: f64,
    pub children: Vec<ChildStats>,
}

/// One mission's own spend: requests grouped by served `(provider, model)`,
/// plus its VM cost (`vm_cents`). Every request is settled once by id
/// through the verified kernel step.
pub fn own_stats(
    records: &[&UsageRecord],
    vm_cents: u64,
    table: &ShadowPrices,
    seen: &mut HashSet<String>,
) -> OwnStats {
    let mut lines: BTreeMap<(Option<String>, String), ModelLine> = BTreeMap::new();
    for r in records {
        let fresh = match &r.request_id {
            Some(id) => seen.insert(id.clone()),
            None => true,
        };
        let (cents, shadow, priced) = price_cents(r, table);
        let line = lines
            .entry((r.provider.clone(), r.model.clone()))
            .or_insert_with(|| ModelLine {
                provider: r.provider.clone(),
                model: r.model.clone(),
                ..Default::default()
            });
        line.cents = crate::orb_spec::stats_settle_step(line.cents, cents, !fresh);
        if fresh {
            line.requests += 1;
            line.input_tokens += r.input_tokens;
            line.cache_read_tokens += r.cache_read_tokens;
            line.cache_write_tokens += r.cache_creation_tokens;
            line.output_tokens += r.output_tokens;
            line.shadow_priced |= shadow;
            line.unpriced |= !priced;
        }
    }
    let mut models: Vec<ModelLine> = lines
        .into_values()
        .map(|mut l| {
            l.cost_usd = cents_usd(l.cents);
            l
        })
        .collect();
    models.sort_by(|a, b| b.cents.cmp(&a.cents).then_with(|| a.model.cmp(&b.model)));
    let total_cents = models.iter().fold(vm_cents, |acc, l| {
        crate::orb_spec::stats_settle_step(acc, l.cents, false)
    });
    OwnStats {
        models,
        vm_usd: cents_usd(vm_cents),
        total_usd: cents_usd(total_cents),
        total_cents,
    }
}

fn cents_usd(c: u64) -> f64 {
    c as f64 / 100.0
}

/// VM cost per owner mission over the period, in cents. `today` spreads each
/// machine's cost over the time it ran and keeps today's share.
pub fn vm_cents_by_mission(
    machines: &[crate::managed::ManagedMachine],
    since: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> HashMap<String, u64> {
    let mut out: HashMap<String, f64> = HashMap::new();
    match since {
        Some(start) if start.date_naive() == now.date_naive() => {
            if let Some(today) = crate::managed::daily_spend(machines, 1, now).pop() {
                for part in today.missions {
                    if let Some(m) = part.mission_id {
                        *out.entry(m).or_default() += part.usd;
                    }
                }
            }
        }
        _ => {
            for m in machines {
                if let Some(owner) = &m.owner_mission_id {
                    if since.is_none_or(|s| m.destroyed_at.is_none_or(|d| d >= s)) {
                        *out.entry(owner.clone()).or_default() += m.cost_usd;
                    }
                }
            }
        }
    }
    out.into_iter()
        .map(|(k, usd)| (k, (usd * 100.0).round().max(0.0) as u64))
        .collect()
}

/// Missions below `root` (breadth first, bounded), with their parent.
pub(crate) async fn subtree(
    store: &Arc<dyn MissionStore>,
    root: Uuid,
) -> Vec<(Uuid, Option<Uuid>, Option<String>)> {
    let mut out = Vec::new();
    let mut queue = vec![(root, None::<Uuid>)];
    let mut seen = HashSet::new();
    while let Some((id, parent)) = queue.pop() {
        if !seen.insert(id) || out.len() >= 2000 {
            continue;
        }
        let title = store
            .get_mission(id)
            .await
            .ok()
            .flatten()
            .and_then(|m| m.title);
        out.push((id, parent, title));
        for child in store.get_child_missions(id).await.unwrap_or_default() {
            queue.push((child.id, Some(id)));
        }
    }
    out
}

/// Full stats for `root` from the ledger rows, VM costs and the tree.
pub fn compute(
    root: Uuid,
    tree: &[(Uuid, Option<Uuid>, Option<String>)],
    records: &[UsageRecord],
    vm_cents: &HashMap<String, u64>,
    table: &ShadowPrices,
    period: &'static str,
    since: Option<DateTime<Utc>>,
) -> MissionStats {
    let mut by_mission: HashMap<String, Vec<&UsageRecord>> = HashMap::new();
    for r in records {
        if let Some(m) = &r.mission_id {
            by_mission.entry(m.clone()).or_default().push(r);
        }
    }
    let mut seen = HashSet::new();
    let mut own_cents: HashMap<Uuid, u64> = HashMap::new();
    let mut root_own = OwnStats::default();
    for (id, _, _) in tree {
        let key = id.to_string();
        let rows = by_mission.remove(&key).unwrap_or_default();
        let stats = own_stats(
            &rows,
            vm_cents.get(&key).copied().unwrap_or(0),
            table,
            &mut seen,
        );
        own_cents.insert(*id, stats.total_cents);
        if *id == root {
            root_own = stats;
        }
    }
    // Subtree totals, children before parents (reverse discovery order).
    let mut subtree_cents: HashMap<Uuid, u64> = HashMap::new();
    for (id, _, _) in tree.iter().rev() {
        let own = own_cents.get(id).copied().unwrap_or(0);
        let kids = tree
            .iter()
            .filter(|(_, p, _)| *p == Some(*id))
            .fold(own, |acc, (c, _, _)| {
                crate::orb_spec::stats_settle_step(
                    acc,
                    subtree_cents.get(c).copied().unwrap_or(0),
                    false,
                )
            });
        subtree_cents.insert(*id, kids);
    }
    let mut children: Vec<ChildStats> = tree
        .iter()
        .filter(|(_, p, _)| *p == Some(root))
        .map(|(id, _, title)| ChildStats {
            mission_id: id.to_string(),
            title: title.clone(),
            total_usd: cents_usd(subtree_cents.get(id).copied().unwrap_or(0)),
        })
        .collect();
    children.sort_by(|a, b| {
        b.total_usd
            .partial_cmp(&a.total_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    MissionStats {
        mission_id: root.to_string(),
        period,
        since,
        own: root_own,
        subtree_total_usd: cents_usd(subtree_cents.get(&root).copied().unwrap_or(0)),
        children,
    }
}

// --------------------------------------------------------------------- http

#[derive(Deserialize)]
struct StatsQuery {
    period: Option<String>,
}

fn error(status: StatusCode, code: &str, message: impl Into<String>) -> Response {
    (
        status,
        Json(json!({"error": code, "message": message.into()})),
    )
        .into_response()
}

async fn get_stats(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Query(q): Query<StatsQuery>,
) -> Response {
    let store = super::control::control_for_user(&state, &user)
        .await
        .mission_store;
    let Ok(Some(mission)) = store.get_mission(id).await else {
        return error(StatusCode::NOT_FOUND, "not_found", "Mission not found");
    };
    let now = Utc::now();
    let (period, since) = match q.period.as_deref() {
        Some("today") => (
            "today",
            Some(now.date_naive().and_hms_opt(0, 0, 0).unwrap().and_utc()),
        ),
        _ => (
            "lifetime",
            DateTime::parse_from_rfc3339(&mission.created_at)
                .ok()
                .map(|d| d.with_timezone(&Utc)),
        ),
    };
    let since_str = since.map(|s| s.to_rfc3339());
    let records = match store.get_usage_records(since_str.as_deref()).await {
        Ok(r) => r,
        Err(e) => return error(StatusCode::INTERNAL_SERVER_ERROR, "usage_unavailable", e),
    };
    let tree = subtree(&store, id).await;
    let ids: HashSet<String> = tree.iter().map(|(i, _, _)| i.to_string()).collect();
    let records: Vec<UsageRecord> = records
        .into_iter()
        .filter(|r| r.mission_id.as_ref().is_some_and(|m| ids.contains(m)))
        .collect();
    let machines = match crate::managed::global() {
        Some(m) => m.machines_snapshot().await,
        None => Vec::new(),
    };
    let vm = vm_cents_by_mission(&machines, since, now);
    let table = ShadowPrices::load(&state.config.working_dir);
    Json(compute(id, &tree, &records, &vm, &table, period, since)).into_response()
}

async fn get_shadow_prices(State(state): State<Arc<AppState>>) -> Response {
    Json(ShadowPrices::load(&state.config.working_dir)).into_response()
}

async fn put_shadow_prices(
    State(state): State<Arc<AppState>>,
    Json(table): Json<ShadowPrices>,
) -> Response {
    if table.prices.values().any(|p| {
        [p.input, p.cache_read, p.cache_write, p.output]
            .iter()
            .any(|v| !v.is_finite() || *v < 0.0)
    }) {
        return error(
            StatusCode::BAD_REQUEST,
            "invalid_price",
            "Prices must be non-negative numbers",
        );
    }
    let path = ShadowPrices::path(&state.config.working_dir);
    let _ = std::fs::create_dir_all(path.parent().unwrap_or(std::path::Path::new(".")));
    match std::fs::write(&path, serde_json::to_vec_pretty(&table).unwrap_or_default()) {
        Ok(()) => Json(table).into_response(),
        Err(e) => error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "write_failed",
            e.to_string(),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::mission_store::UsageSource;

    fn rec(id: &str, mission: &str, provider: &str, model: &str, cents: u64) -> UsageRecord {
        UsageRecord {
            request_id: Some(id.into()),
            timestamp: "2026-10-24T10:00:00Z".into(),
            source: UsageSource::Router,
            model: model.into(),
            provider: Some(provider.into()),
            backend: None,
            mission_id: Some(mission.into()),
            mission_title: None,
            root_mission_id: None,
            caller_kind: "mission".into(),
            purpose: None,
            api_key_id: None,
            api_key_name: None,
            account_id: None,
            input_tokens: 1000,
            output_tokens: 100,
            cache_creation_tokens: 0,
            cache_read_tokens: 500,
            reasoning_tokens: 0,
            cost_cents: cents,
            cost_known: true,
        }
    }

    #[test]
    fn mission_and_subtree_totals_are_conserved_and_replays_count_once() {
        let (root, a, b, gc) = (
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
        );
        let tree = vec![
            (root, None, Some("root".into())),
            (a, Some(root), Some("a".into())),
            (b, Some(root), Some("b".into())),
            (gc, Some(a), Some("gc".into())),
        ];
        let r = root.to_string();
        let records = vec![
            rec("proxy:1", &r, "openai", "gpt-6.1-sol", 120),
            rec("proxy:2", &r, "openai", "gpt-6.1-sol", 80),
            rec("proxy:2", &r, "openai", "gpt-6.1-sol", 80), // replay
            rec("proxy:3", &r, "anthropic", "claude-opus-5", 300),
            rec("proxy:4", &a.to_string(), "xai", "grok-4.7", 50),
            rec("proxy:5", &gc.to_string(), "spark", "qwen", 999),
            rec("proxy:6", &b.to_string(), "google", "gemini-4-argon", 10),
        ];
        let vm: HashMap<String, u64> = [(r.clone(), 40), (gc.to_string(), 7)].into();
        let s = compute(
            root,
            &tree,
            &records,
            &vm,
            &ShadowPrices::default(),
            "lifetime",
            None,
        );
        // Own: models (200 + 300) + VM 40, the replay counted once.
        let sol = s
            .own
            .models
            .iter()
            .find(|m| m.model == "gpt-6.1-sol")
            .unwrap();
        assert_eq!((sol.requests, sol.cost_usd), (2, 2.0));
        let models: f64 = s.own.models.iter().map(|m| m.cost_usd).sum();
        assert!((s.own.total_usd - (models + s.own.vm_usd)).abs() < 1e-9);
        assert_eq!(s.own.total_usd, 5.4);
        // Spark is local (0); the grandchild VM rolls up into child a.
        let child_a = s
            .children
            .iter()
            .find(|c| c.title.as_deref() == Some("a"))
            .unwrap();
        assert_eq!(child_a.total_usd, 0.57);
        let kids: f64 = s.children.iter().map(|c| c.total_usd).sum();
        assert!((s.subtree_total_usd - (s.own.total_usd + kids)).abs() < 1e-9);
        assert_eq!(s.subtree_total_usd, 6.07);
    }

    #[test]
    fn subscriptions_are_shadow_priced_and_never_a_silent_zero() {
        let mut table = ShadowPrices::default();
        table.prices.insert(
            "antigravity/gemini-4-argon".into(),
            TokenPrice {
                input: 2.0,
                cache_read: 0.5,
                cache_write: 0.0,
                output: 12.0,
            },
        );
        let sub = rec("proxy:1", "m", "antigravity", "gemini-4-argon", 0);
        // (1000*2 + 500*0.5 + 100*12) / 1e6 = $0.00345 -> 0 cents rounded
        let (cents, shadow, priced) = price_cents(&sub, &table);
        assert!(shadow && priced);
        assert_eq!(cents, 0);
        let mut big = sub.clone();
        big.input_tokens = 10_000_000;
        assert_eq!(price_cents(&big, &table).0, 2000);
        // No table entry, unknown model: flagged unpriced.
        let unknown = rec("proxy:2", "m", "muse-code", "muse-x", 0);
        assert_eq!(price_cents(&unknown, &table), (0, true, false));
        // An OAuth account on a metered provider is a subscription.
        let mut oauth = rec("proxy:3", "m", "openai", "gpt-6.1-sol", 55);
        oauth.account_id = Some("acc-1".into());
        table.subscription_accounts.push("acc-1".into());
        assert_eq!(table.billing(&oauth), Billing::Subscription);
        // Local inference is free and not shadow-priced.
        assert_eq!(
            price_cents(&rec("p", "m", "spark", "q", 9), &table),
            (0, false, true)
        );
    }

    #[test]
    fn vm_cost_today_is_the_share_run_today() {
        let now = Utc::now();
        let start = now.date_naive().and_hms_opt(0, 0, 0).unwrap().and_utc();
        let out = vm_cents_by_mission(&[], Some(start), now);
        assert!(out.is_empty());
    }
}
