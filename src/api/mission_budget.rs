//! Mission spending budgets for managed machines (optional, off by default).
//!
//! `GET /api/control/missions/:id/budget` and `PUT` (`{"budget_usd": n|null}`).
//! Semantics and ledger: `crate::managed::budget`.

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

/// Re-attach every pool to its current nearest ancestor pool (after a
/// budget was added or removed somewhere in the tree).
pub(crate) async fn reparent_all(store: &Arc<dyn MissionStore>) {
    let Some(manager) = crate::managed::global() else {
        return;
    };
    let pools = manager.budget_pools().await;
    for id in pools.keys() {
        let Ok(uuid) = Uuid::parse_str(id) else {
            continue;
        };
        let chain = lineage(store, uuid).await;
        let parent =
            crate::managed::budget::nearest_pool(chain.iter().skip(1).map(String::as_str), &pools);
        manager.reparent_pool(id, parent).await;
    }
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
    reparent_all(store).await;
    Ok(())
}
