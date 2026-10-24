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
pub(crate) async fn lineage(store: &Arc<dyn MissionStore>, id: Uuid) -> Vec<String> {
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
pub(crate) async fn pool_for(store: &Arc<dyn MissionStore>, mission: Uuid) -> Option<String> {
    let manager = crate::managed::global()?;
    let pools = manager.budget_pools().await;
    if pools.is_empty() {
        return None;
    }
    let chain = lineage(store, mission).await;
    crate::managed::budget::nearest_pool(chain.iter().map(String::as_str), &pools)
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
        if pool.owner_user_id.as_deref() != Some(user_id) || id == changed {
            continue;
        }
        let Some(chain) = lineage_of(id).await else {
            continue;
        };
        // Only pools below the changed mission can change parent.
        if !chain.iter().skip(1).any(|a| a == changed) {
            continue;
        }
        let parent =
            crate::managed::budget::nearest_pool(chain.iter().skip(1).map(String::as_str), pools);
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
        .mission_budget(&id.to_string(), &chain, &children)
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
    match view(&store, id).await {
        Ok(v) => Json(v).into_response(),
        Err(r) => r,
    }
}

#[derive(Deserialize)]
pub struct BudgetBody {
    /// `null` removes the mission's own budget (it then draws from the
    /// nearest ancestor pool, or has no limit).
    pub budget_usd: Option<f64>,
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
    match set_budget(&store, &user, id, body.budget_usd).await {
        Ok(()) => match view(&store, id).await {
            Ok(v) => Json(v).into_response(),
            Err(r) => r,
        },
        Err(e) => {
            let status = StatusCode::from_u16(e.status).unwrap_or(StatusCode::BAD_REQUEST);
            (status, Json(e)).into_response()
        }
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
    let parent =
        crate::managed::budget::nearest_pool(chain.iter().skip(1).map(String::as_str), &pools);
    manager
        .set_mission_budget(&id.to_string(), amount, parent, Some(user.id.clone()))
        .await?;
    reparent_subtree(store, &user.id, id).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::managed::budget::BudgetPool;
    use std::collections::HashMap;

    fn pool(id: &str, user: &str, parent: Option<&str>) -> (String, BudgetPool) {
        (
            id.into(),
            BudgetPool {
                mission_id: id.into(),
                budget_usd: 1.0,
                parent_pool_id: parent.map(Into::into),
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
}
