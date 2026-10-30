//! Mission spending budgets for managed machines (optional, off by default).
//!
//! `GET /api/control/missions/:id/budget` and `PUT` (`{"budget_usd": n|null}`).
//! Semantics and ledger: `crate::managed::budget`.

#![allow(clippy::result_large_err)] // axum Response as the early-return error

use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
    Extension, Json, Router,
};
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

use super::auth::AuthUser;
use super::mission_store::MissionStore;
use super::routes::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new().route(
        "/api/control/missions/:id/budget",
        get(get_budget).put(put_budget),
    )
}

/// `id` then its ancestors (bounded, cycle-safe).
/// Empty when `id` is not in this store (another tenant's or unknown).
pub(crate) async fn lineage(store: &Arc<dyn MissionStore>, id: Uuid) -> Vec<String> {
    if !matches!(store.get_mission(id).await, Ok(Some(_))) {
        return Vec::new();
    }
    let mut chain = vec![id];
    let mut cur = id;
    for _ in 0..32 {
        match store.get_mission(cur).await {
            Ok(Some(m)) => match m.parent_mission_id {
                Some(parent) if !chain.contains(&parent) => {
                    chain.push(parent);
                    cur = parent;
                }
                _ => break,
            },
            _ => break,
        }
    }
    chain.iter().map(Uuid::to_string).collect()
}

/// The pool a mission (existing, or about to be created under `parent`)
/// draws from.
pub(crate) async fn pool_for(
    store: &Arc<dyn MissionStore>,
    mission: Uuid,
    user_id: &str,
) -> Option<String> {
    let manager = crate::managed::global()?;
    let pools = manager.budget_pools().await;
    if pools.is_empty() {
        return None;
    }
    let chain = lineage(store, mission).await;
    crate::managed::budget::nearest_pool(chain.iter().map(String::as_str), &pools, user_id)
}

/// The concurrency override pool a mission's VM on `provider` draws from.
pub(crate) async fn cap_pool_for(
    store: &Arc<dyn MissionStore>,
    mission: Uuid,
    user_id: &str,
    provider: &str,
) -> Option<String> {
    let manager = crate::managed::global()?;
    let pools = manager.budget_pools().await;
    if pools.is_empty() {
        return None;
    }
    let chain = lineage(store, mission).await;
    crate::managed::budget::nearest_cap_pool_for_provider(
        chain.iter().map(String::as_str),
        &pools,
        user_id,
        provider,
    )
}

/// Re-attach the calling user's pools at or below `changed` to their
/// current nearest ancestor pool (after a budget was added or removed at
/// `changed`). Other users' pools are never touched, and a pool whose
/// mission is not in this user's store keeps its parent unchanged (a failed
/// lookup must not detach it from its pool).
pub(crate) async fn reparent_subtree(store: &Arc<dyn MissionStore>, user_id: &str, changed: Uuid) {
    let Some(manager) = crate::managed::global() else {
        return;
    };
    let pools = manager.budget_pools().await;
    let changed = changed.to_string();
    for plan in reparent_plan(&pools, user_id, &changed, |id| {
        let store = store.clone();
        let id = id.to_string();
        async move {
            let uuid = Uuid::parse_str(&id).ok()?;
            matches!(store.get_mission(uuid).await, Ok(Some(_))).then_some(())?;
            Some(lineage(&store, uuid).await)
        }
    })
    .await
    {
        manager.reparent_pool(&plan.0, plan.1).await;
    }
}

/// Re-attach descendant concurrency override pools and re-evaluate `cap_pool_id`
/// on live/stopped machines in `changed`'s subtree after `vm_limits` changed.
pub(crate) async fn reparent_cap_subtree(
    store: &Arc<dyn MissionStore>,
    user_id: &str,
    changed: Uuid,
) {
    let Some(manager) = crate::managed::global() else {
        return;
    };
    let pools = manager.budget_pools().await;
    let changed_str = changed.to_string();
    for plan in reparent_cap_plan(&pools, user_id, &changed_str, |id| {
        let store = store.clone();
        let id = id.to_string();
        async move {
            let uuid = Uuid::parse_str(&id).ok()?;
            matches!(store.get_mission(uuid).await, Ok(Some(_))).then_some(())?;
            Some(lineage(&store, uuid).await)
        }
    })
    .await
    {
        manager.reparent_cap_pool(&plan.0, plan.1).await;
    }

    let pools = manager.budget_pools().await;
    for m in manager.machines_snapshot().await {
        if !(m.state.is_live() || m.state == crate::managed::MachineState::Stopped) {
            continue;
        }
        if m.owner_user_id.as_deref() != Some(user_id) {
            continue;
        }
        let Some(owner_str) = m
            .owner_mission_id
            .as_deref()
            .or(m.requested_by_mission_id.as_deref())
        else {
            continue;
        };
        let Ok(owner_uuid) = Uuid::parse_str(owner_str) else {
            continue;
        };
        let chain = lineage(store, owner_uuid).await;
        if !chain.iter().any(|a| a == &changed_str) {
            continue;
        }
        let next_cap = crate::managed::budget::nearest_cap_pool_for_provider(
            chain.iter().map(String::as_str),
            &pools,
            user_id,
            &m.provider,
        );
        manager.set_machine_cap_pool(&m.id, next_cap).await;
    }
}

/// Pure planning step of [`reparent_subtree`]: `(pool, new parent)` pairs.
/// `lineage_of` returns `None` when the mission is unknown (skipped).
pub(crate) async fn reparent_plan<F, Fut>(
    pools: &std::collections::HashMap<String, crate::managed::budget::BudgetPool>,
    user_id: &str,
    changed: &str,
    lineage_of: F,
) -> Vec<(String, Option<String>)>
where
    F: Fn(&str) -> Fut,
    Fut: std::future::Future<Output = Option<Vec<String>>>,
{
    let mut out = Vec::new();
    for (id, pool) in pools {
        if pool.budget_usd.is_none()
            || pool.owner_user_id.as_deref() != Some(user_id)
            || id == changed
        {
            continue;
        }
        let Some(chain) = lineage_of(id).await else {
            continue;
        };
        // Only pools below the changed mission can change parent.
        if !chain.iter().skip(1).any(|a| a == changed) {
            continue;
        }
        let parent = crate::managed::budget::nearest_pool(
            chain.iter().skip(1).map(String::as_str),
            pools,
            user_id,
        );
        out.push((id.clone(), parent));
    }
    out
}

/// Pure planning step of [`reparent_cap_subtree`]: `(pool, new parent_cap_pool)` pairs.
pub(crate) async fn reparent_cap_plan<F, Fut>(
    pools: &std::collections::HashMap<String, crate::managed::budget::BudgetPool>,
    user_id: &str,
    changed: &str,
    lineage_of: F,
) -> Vec<(String, Option<String>)>
where
    F: Fn(&str) -> Fut,
    Fut: std::future::Future<Output = Option<Vec<String>>>,
{
    let mut out = Vec::new();
    for (id, pool) in pools {
        if pool.vm_limits.is_none()
            || pool.owner_user_id.as_deref() != Some(user_id)
            || id == changed
        {
            continue;
        }
        let Some(chain) = lineage_of(id).await else {
            continue;
        };
        if !chain.iter().skip(1).any(|a| a == changed) {
            continue;
        }
        let parent = crate::managed::budget::nearest_cap_pool(
            chain.iter().skip(1).map(String::as_str),
            pools,
            user_id,
        );
        out.push((id.clone(), parent));
    }
    out
}

fn error(status: StatusCode, code: &str, message: impl Into<String>) -> Response {
    (
        status,
        Json(json!({"error": code, "message": message.into()})),
    )
        .into_response()
}

async fn store_and_mission(
    state: &Arc<AppState>,
    user: &AuthUser,
    id: Uuid,
) -> Result<Arc<dyn MissionStore>, Response> {
    let store = super::control::control_for_user(state, user)
        .await
        .mission_store;
    match store.get_mission(id).await {
        Ok(Some(_)) => Ok(store),
        _ => Err(error(
            StatusCode::NOT_FOUND,
            "not_found",
            "Mission not found",
        )),
    }
}

pub(crate) async fn view(
    store: &Arc<dyn MissionStore>,
    user_id: &str,
    id: Uuid,
) -> Result<crate::managed::MissionBudgetView, Response> {
    let manager = crate::managed::global().ok_or_else(|| {
        error(
            StatusCode::SERVICE_UNAVAILABLE,
            "disabled",
            "Managed machines are not initialised",
        )
    })?;
    let chain = lineage(store, id).await;
    let children: Vec<String> = store
        .get_child_missions(id)
        .await
        .unwrap_or_default()
        .iter()
        .map(|m| m.id.to_string())
        .collect();
    Ok(manager
        .mission_budget(&id.to_string(), &chain, &children, user_id)
        .await)
}

async fn get_budget(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> Response {
    let store = match store_and_mission(&state, &user, id).await {
        Ok(s) => s,
        Err(r) => return r,
    };
    match view(&store, &user.id, id).await {
        Ok(v) => Json(v).into_response(),
        Err(r) => r,
    }
}

fn deserialize_patch<'de, T, D>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    T: Deserialize<'de>,
    D: serde::Deserializer<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

#[derive(Debug, Default, Deserialize, PartialEq)]
pub struct BudgetBody {
    /// Omit to leave unchanged; `null` removes the mission's own USD budget;
    /// a number sets it.
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub budget_usd: Option<Option<f64>>,
    /// Omit to leave unchanged; `null` removes the mission's VM concurrency
    /// override; an object sets it.
    #[serde(default, deserialize_with = "deserialize_patch")]
    pub vm_limits: Option<Option<crate::managed::budget::VmConcurrencyLimits>>,
}

async fn put_budget(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(body): Json<BudgetBody>,
) -> Response {
    let store = match store_and_mission(&state, &user, id).await {
        Ok(s) => s,
        Err(r) => return r,
    };
    if let Some(amount) = body.budget_usd {
        if let Err(e) = set_budget(&store, &user, id, amount).await {
            let status = StatusCode::from_u16(e.status).unwrap_or(StatusCode::BAD_REQUEST);
            return (status, Json(e)).into_response();
        }
    }
    if let Some(limits) = body.vm_limits {
        if let Err(e) = set_vm_limits(&store, &user, id, limits).await {
            let status = StatusCode::from_u16(e.status).unwrap_or(StatusCode::BAD_REQUEST);
            return (status, Json(e)).into_response();
        }
    }
    match view(&store, &user.id, id).await {
        Ok(v) => Json(v).into_response(),
        Err(r) => r,
    }
}

/// Set or clear a mission's own budget (validated against its parent pool).
pub(crate) async fn set_budget(
    store: &Arc<dyn MissionStore>,
    user: &AuthUser,
    id: Uuid,
    amount: Option<f64>,
) -> Result<(), crate::managed::ManagedError> {
    let manager = crate::managed::global().ok_or_else(|| crate::managed::ManagedError {
        error: "disabled",
        message: "Managed machines are not initialised".into(),
        status: 503,
    })?;
    let chain = lineage(store, id).await;
    let pools = manager.budget_pools().await;
    let parent = crate::managed::budget::nearest_pool(
        chain.iter().skip(1).map(String::as_str),
        &pools,
        &user.id,
    );
    manager
        .set_mission_budget(&id.to_string(), amount, parent, Some(user.id.clone()))
        .await?;
    reparent_subtree(store, &user.id, id).await;
    Ok(())
}

/// Set or clear a mission's own VM concurrency override.
pub(crate) async fn set_vm_limits(
    store: &Arc<dyn MissionStore>,
    user: &AuthUser,
    id: Uuid,
    limits: Option<crate::managed::budget::VmConcurrencyLimits>,
) -> Result<(), crate::managed::ManagedError> {
    let manager = crate::managed::global().ok_or_else(|| crate::managed::ManagedError {
        error: "disabled",
        message: "Managed machines are not initialised".into(),
        status: 503,
    })?;
    let chain = lineage(store, id).await;
    let pools = manager.budget_pools().await;
    let parent_cap = crate::managed::budget::nearest_cap_pool(
        chain.iter().skip(1).map(String::as_str),
        &pools,
        &user.id,
    );
    manager
        .set_mission_vm_limits(
            &id.to_string(),
            limits,
            &chain,
            parent_cap,
            Some(user.id.clone()),
        )
        .await?;
    reparent_cap_subtree(store, &user.id, id).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::managed::budget::{BudgetPool, VmConcurrencyLimits};
    use std::collections::{BTreeMap, HashMap};

    fn pool(id: &str, user: &str, parent: Option<&str>) -> (String, BudgetPool) {
        (
            id.into(),
            BudgetPool {
                mission_id: id.into(),
                budget_usd: Some(1.0),
                parent_pool_id: parent.map(Into::into),
                vm_limits: None,
                parent_cap_pool_id: None,
                owner_user_id: Some(user.into()),
                updated_at: chrono::Utc::now(),
            },
        )
    }

    #[tokio::test]
    async fn reparenting_stays_in_the_callers_subtree_and_skips_unknown_missions() {
        // u1: root -> mid -> leaf ; "gone" is a u1 pool whose mission is missing.
        // u2: other pool under a lineage that also contains "mid" (forged).
        let pools: HashMap<_, _> = [
            pool("root", "u1", None),
            pool("mid", "u1", Some("root")),
            pool("leaf", "u1", Some("root")),
            pool("gone", "u1", Some("root")),
            pool("other", "u2", Some("x")),
        ]
        .into_iter()
        .collect();
        let lineages: HashMap<&str, Vec<String>> = [
            ("root", vec!["root"]),
            ("mid", vec!["mid", "root"]),
            ("leaf", vec!["leaf", "mid", "root"]),
            ("other", vec!["other", "mid", "x"]),
        ]
        .into_iter()
        .map(|(k, v)| (k, v.into_iter().map(String::from).collect()))
        .collect();
        let plan = reparent_plan(&pools, "u1", "mid", |id| {
            let found = lineages.get(id).cloned();
            async move { found }
        })
        .await;
        // Only u1's leaf (below "mid") moves, to "mid"; "gone" (lookup failed)
        // and u2's pool are untouched; the changed pool itself is skipped.
        assert_eq!(plan, vec![("leaf".to_string(), Some("mid".to_string()))]);
    }

    #[test]
    fn budget_body_distinguishes_omitted_from_null_for_partial_updates() {
        let only_budget: BudgetBody = serde_json::from_str(r#"{"budget_usd": 12.5}"#).unwrap();
        assert_eq!(only_budget.budget_usd, Some(Some(12.5)));
        assert_eq!(only_budget.vm_limits, None);

        let clear_budget: BudgetBody = serde_json::from_str(r#"{"budget_usd": null}"#).unwrap();
        assert_eq!(clear_budget.budget_usd, Some(None));
        assert_eq!(clear_budget.vm_limits, None);

        let only_limits: BudgetBody = serde_json::from_str(
            r#"{"vm_limits": {"max_concurrent": 4, "provider_max_concurrent": {"vastai": 2}}}"#,
        )
        .unwrap();
        assert_eq!(only_limits.budget_usd, None);
        assert_eq!(
            only_limits.vm_limits,
            Some(Some(VmConcurrencyLimits {
                max_concurrent: Some(4),
                provider_max_concurrent: BTreeMap::from([("vastai".to_string(), 2)]),
            }))
        );

        let clear_limits: BudgetBody = serde_json::from_str(r#"{"vm_limits": null}"#).unwrap();
        assert_eq!(clear_limits.budget_usd, None);
        assert_eq!(clear_limits.vm_limits, Some(None));
    }
}
