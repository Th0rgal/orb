//! REST surface for managed machines.
//!
//! Protected (dashboard JWT): list / spawn / extend / destroy / reconcile.
//! Public, self-authenticated: `enroll` (one-time token), `relay/poll` and
//! `relay/respond` (node credential), and the loopback `relay/tunnel` that
//! Core's own node client uses (node credential as bearer, like a real node).

#![allow(clippy::result_large_err)] // axum Response as the early-return error

use std::sync::Arc;
use std::time::Duration;

use axum::{
    body::Bytes,
    extract::{Path, Query},
    http::{HeaderMap, Method, StatusCode, Uri},
    response::{IntoResponse, Response},
    routing::{any, get, post},
    Json, Router,
};
use base64::Engine;
use serde::Deserialize;
use serde_json::json;

use super::routes::AppState;
use crate::managed::relay::{RelayError, RelayRequest, RelayResponse};
use crate::managed::{ManagedError, ManagedManager, SpawnRequest};

fn manager() -> Result<Arc<ManagedManager>, Response> {
    crate::managed::global().ok_or_else(|| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"error":"disabled","message":"Managed machines are not initialised"})),
        )
            .into_response()
    })
}

fn err(e: ManagedError) -> Response {
    let status = StatusCode::from_u16(e.status).unwrap_or(StatusCode::BAD_REQUEST);
    (status, Json(e)).into_response()
}

pub fn protected_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/managed-machines", get(list).post(spawn))
        .route("/api/managed-machines/reconcile", post(reconcile))
        .route("/api/managed-machines/spend", get(spend))
        .route("/api/managed-machines/reap-plan", get(reap_plan))
        .route(
            "/api/managed-machines/settings",
            get(get_settings).put(put_settings),
        )
        .route("/api/managed-machines/snapshots", get(list_snapshots))
        .route(
            "/api/managed-machines/snapshots/:name",
            axum::routing::delete(delete_snapshot),
        )
        .route("/api/managed-machines/:id", get(get_one).delete(destroy))
        .route(
            "/api/managed-machines/:id/operations",
            post(raw_operation).layer(axum::extract::DefaultBodyLimit::max(128 * 1024)),
        )
        .route("/api/managed-machines/:id/stop", post(stop))
        .route("/api/managed-machines/:id/resume", post(resume))
        .route("/api/managed-machines/:id/fork", post(fork))
        .route("/api/managed-machines/:id/snapshot", post(snapshot))
        .route("/api/managed-machines/:id/extend", post(extend))
        .route("/api/managed-machines/:id/owner", post(set_owner))
}

pub fn public_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/managed-machines/enroll", post(enroll))
        .route("/api/managed-machines/relay/poll", get(relay_poll))
        .route(
            "/api/managed-machines/relay/respond",
            post(relay_respond).layer(axum::extract::DefaultBodyLimit::max(1024 * 1024 * 1024)),
        )
        .route(
            "/api/managed-machines/relay/tunnel/:id/*path",
            any(relay_tunnel).layer(axum::extract::DefaultBodyLimit::max(1024 * 1024 * 1024)),
        )
}

#[derive(Deserialize)]
struct ListQuery {
    history_hours: Option<i64>,
}

async fn list(
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Query(q): Query<ListQuery>,
) -> Response {
    match manager() {
        Ok(m) => {
            let mut view = m
                .list(q.history_hours.unwrap_or(24).clamp(0, 24 * 30))
                .await;
            view.machines.retain(|machine| {
                machine.provisioning_mode.is_worker()
                    || machine.owner_user_id.as_deref() == Some(user.id.as_str())
            });
            view.budget = m.visible_budget(&user.id).await;
            let visible = visible_machines(&m, &user.id).await;
            view.daily_spend = crate::managed::daily_spend(
                &visible,
                crate::managed::SPEND_DAYS,
                chrono::Utc::now(),
            );
            Json(view).into_response()
        }
        Err(r) => r,
    }
}

#[derive(Deserialize)]
struct SpendQuery {
    days: Option<u32>,
}

/// Daily spend aggregates (UTC days, oldest first) with per-mission and
/// per-size breakdowns.
async fn spend(
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Query(q): Query<SpendQuery>,
) -> Response {
    match manager() {
        Ok(m) => Json(json!({
            "days": crate::managed::daily_spend(&visible_machines(&m, &user.id).await, q.days.unwrap_or(crate::managed::SPEND_DAYS), chrono::Utc::now())
        }))
        .into_response(),
        Err(r) => r,
    }
}

async fn get_one(
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Path(id): Path<String>,
) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    if let Err(r) = raw_owner_check(&m, &id, &user).await {
        return r;
    }
    match m.get(&id).await {
        Some(machine) => Json(machine).into_response(),
        None => err(ManagedError {
            error: "not_found",
            message: "Unknown managed machine".into(),
            status: 404,
        }),
    }
}

pub(crate) async fn spawn(
    axum::extract::State(state): axum::extract::State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Json(req): Json<SpawnRequest>,
) -> Response {
    spawn_for(&state, &user, req).await
}

/// Shared by spawn and fork: tenant, budget pool and sibling reuse.
async fn spawn_for(
    state: &Arc<AppState>,
    user: &crate::api::auth::AuthUser,
    mut req: SpawnRequest,
) -> Response {
    // The owner's tenant comes from the authenticated caller, never the body.
    req.owner_user_id = Some(user.id.clone());
    let store = crate::api::control::control_for_user(state, user)
        .await
        .mission_store;
    // The mission the machine is charged to: its owner, else its requester.
    let charged = req
        .owner_mission_id
        .as_deref()
        .or(req.requested_by_mission_id.as_deref())
        .and_then(|id| uuid::Uuid::parse_str(id).ok());
    if let Some(mission) = charged {
        // The mission must be the caller's: never charge (or escape to)
        // another tenant's pool.
        if !matches!(store.get_mission(mission).await, Ok(Some(_))) {
            return err(ManagedError {
                error: "unknown_mission",
                message: "Owner mission not found".into(),
                status: 404,
            });
        }
        req.budget_pool_id = crate::api::mission_budget::pool_for(&store, mission, &user.id).await;
        req.snapshot_project = store
            .get_mission(mission)
            .await
            .ok()
            .flatten()
            .and_then(|m| m.project.project);
    }
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    if req.provisioning_mode.unwrap_or_default().is_worker()
        && req.reuse_idle == Some(true)
        && req.from_snapshot.is_none()
        && req.fork_of.is_none()
    {
        if let (Some(parent), Ok((spec, _))) = (charged, ManagedManager::plan(&m.settings, &req)) {
            if let Some(machine) = reuse_idle_sibling(&m, &store, &req, parent, spec.size).await {
                let mut body = serde_json::to_value(&machine).unwrap_or_default();
                body["reused"] = json!(true);
                return (StatusCode::OK, Json(body)).into_response();
            }
        }
    }
    match m.spawn(req).await {
        Ok(machine) => (StatusCode::CREATED, Json(machine)).into_response(),
        Err(e) => err(e),
    }
}

/// An idle VM of the same size/image whose owner is an ended child of
/// `parent` (a sibling of the child about to start) and is still inside its
/// grace window: hand it over instead of renting.
async fn reuse_idle_sibling(
    m: &Arc<ManagedManager>,
    store: &Arc<dyn crate::api::mission_store::MissionStore>,
    req: &SpawnRequest,
    parent: uuid::Uuid,
    size: &str,
) -> Option<crate::managed::ManagedMachine> {
    let image = ManagedManager::resolve_image(&m.settings, req.image.as_deref()).ok()?;
    let ended: std::collections::HashSet<String> = store
        .get_child_missions(parent)
        .await
        .ok()?
        .into_iter()
        .filter(|c| {
            matches!(
                crate::managed::owner_state_for_status(&c.status.to_string(), chrono::Utc::now()),
                crate::managed::OwnerState::Terminal { .. }
            )
        })
        .map(|c| c.id.to_string())
        .collect();
    if ended.is_empty() {
        return None;
    }
    let parent_id = parent.to_string();
    let machine = m
        .take_idle_sibling(
            &crate::managed::SiblingReuse {
                size,
                image: &image,
                requested_by: &parent_id,
                tenant: req.owner_user_id.as_deref(),
                budget_pool_id: req.budget_pool_id.as_deref(),
                sub_budget_usd: req.sub_budget_usd,
            },
            &|owner| ended.contains(owner),
        )
        .await?;
    Some(machine)
}

/// What the lifecycle reaper would do now for each live machine, and
/// whether it is in dry-run. Read-only.
async fn reap_plan(axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>) -> Response {
    match manager() {
        Ok(m) => Json(json!({
            "dry_run": m.runtime_settings().reaper_dry_run,
            "policy": m.settings.policy(),
            "machines": ({
                let visible: std::collections::HashSet<_> = visible_machines(&m, &user.id).await.into_iter().map(|m| m.id).collect();
                m.reap_plan().await.into_iter().filter(|entry| visible.contains(&entry.machine_id)).collect::<Vec<_>>()
            }),
        }))
        .into_response(),
        Err(r) => r,
    }
}

#[derive(Deserialize)]
struct OwnerBody {
    owner_mission_id: uuid::Uuid,
}

/// Record the mission a machine serves (backfill of ownerless machines).
/// The mission must exist in the caller's own store and the machine must be
/// the caller's. No requester is accepted from the body: this REST call has
/// no mission attribution, so only an unowned machine can be claimed here
/// (a previous owner, if any, becomes the requester server-side).
async fn set_owner(
    axum::extract::State(state): axum::extract::State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Path(id): Path<String>,
    Json(body): Json<OwnerBody>,
) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    if let Err(r) = raw_owner_check(&m, &id, &user).await {
        return r;
    }
    let exists = match state.control.loaded_mission_store(&user.id).await {
        Some(store) => matches!(store.get_mission(body.owner_mission_id).await, Ok(Some(_))),
        None => false,
    };
    if !exists {
        return err(ManagedError {
            error: "unknown_mission",
            message: "Owner mission not found".into(),
            status: 404,
        });
    }
    match m
        .claim_for_mission(
            &id,
            &body.owner_mission_id.to_string(),
            None,
            Some(user.id.as_str()),
        )
        .await
    {
        Ok(machine) => Json(machine).into_response(),
        Err(e) => err(e),
    }
}

#[derive(Deserialize)]
struct ExtendBody {
    ttl_minutes: u64,
}

async fn extend(
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Path(id): Path<String>,
    Json(body): Json<ExtendBody>,
) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    if let Err(r) = raw_owner_check(&m, &id, &user).await {
        return r;
    }
    match m.extend(&id, body.ttl_minutes).await {
        Ok(machine) => Json(machine).into_response(),
        Err(e) => err(e),
    }
}

#[derive(Deserialize)]
struct DestroyQuery {
    reason: Option<String>,
}

/// `destroy_reason` from a client: short, printable, prefixed so it can
/// never pose as a reaper reason.
fn client_destroy_reason(raw: Option<&str>) -> String {
    match raw
        .map(|r| {
            r.chars()
                .filter(|c| c.is_ascii_alphanumeric() || "_-:. ".contains(*c))
                .take(120)
                .collect::<String>()
        })
        .filter(|r| !r.trim().is_empty())
    {
        Some(r) => format!("requested: {}", r.trim()),
        None => "requested".to_string(),
    }
}

async fn destroy(
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Path(id): Path<String>,
    Query(q): Query<DestroyQuery>,
) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    if let Err(r) = raw_owner_check(&m, &id, &user).await {
        return r;
    }
    match m
        .destroy(&id, &client_destroy_reason(q.reason.as_deref()))
        .await
    {
        Ok(machine) => Json(machine).into_response(),
        Err(e) => err(e),
    }
}

async fn get_settings() -> Response {
    match manager() {
        Ok(m) => Json(m.runtime_settings()).into_response(),
        Err(r) => r,
    }
}

/// Partial update: fields absent from the body keep their current value
/// (a client that only knows `antigravity_on_managed` must not reset
/// `reaper_dry_run`).
async fn put_settings(Json(body): Json<serde_json::Value>) -> Response {
    match manager() {
        Ok(m) => {
            let mut merged = serde_json::to_value(m.runtime_settings()).unwrap_or_default();
            if let (Some(base), Some(patch)) = (merged.as_object_mut(), body.as_object()) {
                for (k, v) in patch {
                    base.insert(k.clone(), v.clone());
                }
            }
            match serde_json::from_value::<crate::managed::RuntimeSettings>(merged) {
                Ok(settings) => {
                    m.set_runtime_settings(settings);
                    Json(m.runtime_settings()).into_response()
                }
                Err(e) => (
                    StatusCode::BAD_REQUEST,
                    Json(json!({"error":"invalid_settings","message":e.to_string()})),
                )
                    .into_response(),
            }
        }
        Err(r) => r,
    }
}

async fn reconcile() -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    match m.reconcile_once().await {
        Ok(report) => Json(report).into_response(),
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            Json(json!({"error":"provider_error","message":e})),
        )
            .into_response(),
    }
}

// ---------------------------------------------------------------- public

#[derive(Deserialize)]
struct EnrollBody {
    machine_id: String,
    enroll_token: String,
}

async fn enroll(Json(body): Json<EnrollBody>) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    match m.enroll(&body.machine_id, &body.enroll_token).await {
        Ok((node_id, node_token)) => {
            Json(json!({"node_id": node_id, "node_token": node_token})).into_response()
        }
        Err(e) => err(e),
    }
}

async fn node_auth(
    m: &ManagedManager,
    headers: &HeaderMap,
    machine_id: &str,
) -> Result<crate::managed::ManagedMachine, Response> {
    let token = crate::remote_node::bearer_token(headers).unwrap_or_default();
    match m.machine_for_token(machine_id, token).await {
        Some(machine) => Ok(machine),
        // 410 tells a dial-out node to stop: its machine is gone or the
        // credential is no longer valid.
        None => Err((StatusCode::GONE, "machine not live").into_response()),
    }
}

fn header_machine(headers: &HeaderMap) -> String {
    headers
        .get("x-orb-machine-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_string()
}

async fn relay_poll(headers: HeaderMap) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    let mid = header_machine(&headers);
    let machine = match node_auth(&m, &headers, &mid).await {
        Ok(machine) => machine,
        Err(r) => return r,
    };
    let requests = m.relay.poll(&machine.id, Duration::from_secs(25), 32).await;
    if m.relay.is_closed(&machine.id).await {
        return (StatusCode::GONE, "machine not live").into_response();
    }
    Json(requests).into_response()
}

async fn relay_respond(headers: HeaderMap, Json(resp): Json<RelayResponse>) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    let mid = header_machine(&headers);
    let machine = match node_auth(&m, &headers, &mid).await {
        Ok(machine) => machine,
        Err(r) => return r,
    };
    let delivered = m.relay.respond(&machine.id, resp).await;
    Json(json!({"delivered": delivered})).into_response()
}

/// Headers never forwarded through the tunnel in either direction.
fn hop_by_hop(name: &str) -> bool {
    matches!(
        name,
        "host"
            | "connection"
            | "content-length"
            | "transfer-encoding"
            | "keep-alive"
            | "upgrade"
            | "proxy-connection"
            | "te"
            | "trailer"
    )
}

async fn relay_tunnel(
    Path((id, _path)): Path<(String, String)>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    let machine = match node_auth(&m, &headers, &id).await {
        Ok(machine) => machine,
        Err(_) => return (StatusCode::UNAUTHORIZED, "unauthorized").into_response(),
    };
    let prefix = format!("/api/managed-machines/relay/tunnel/{}", machine.id);
    let path_and_query = uri
        .path_and_query()
        .map(|p| p.as_str().to_string())
        .unwrap_or_default();
    let node_path = path_and_query
        .strip_prefix(&prefix)
        .unwrap_or("/")
        .to_string();
    let request = RelayRequest {
        id: uuid::Uuid::new_v4().to_string(),
        method: method.to_string(),
        path: if node_path.is_empty() {
            "/".into()
        } else {
            node_path
        },
        headers: headers
            .iter()
            .filter(|(k, _)| !hop_by_hop(k.as_str()))
            .filter_map(|(k, v)| Some((k.to_string(), v.to_str().ok()?.to_string())))
            .collect(),
        body_b64: base64::engine::general_purpose::STANDARD.encode(&body),
        timeout_secs: 0,
    };
    // Long enough for `/execute`, which blocks for the whole command.
    match m
        .relay
        .call(&machine.id, request, Duration::from_secs(2 * 60 * 60))
        .await
    {
        Ok(resp) => {
            let body = base64::engine::general_purpose::STANDARD
                .decode(resp.body_b64.as_bytes())
                .unwrap_or_default();
            let mut builder = Response::builder()
                .status(StatusCode::from_u16(resp.status).unwrap_or(StatusCode::BAD_GATEWAY));
            for (k, v) in resp.headers {
                if !hop_by_hop(&k.to_ascii_lowercase()) {
                    builder = builder.header(k, v);
                }
            }
            builder
                .body(axum::body::Body::from(body))
                .unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response())
        }
        Err(RelayError::NodeNotConnected) => (
            StatusCode::SERVICE_UNAVAILABLE,
            "managed node is not connected",
        )
            .into_response(),
        Err(RelayError::Timeout) => {
            (StatusCode::GATEWAY_TIMEOUT, "managed node did not answer").into_response()
        }
        Err(RelayError::Closed) => (StatusCode::GONE, "managed machine destroyed").into_response(),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn client_destroy_reason_is_prefixed_and_sanitized() {
        assert_eq!(super::client_destroy_reason(None), "requested");
        assert_eq!(
            super::client_destroy_reason(Some("launch_failed")),
            "requested: launch_failed"
        );
        let r = super::client_destroy_reason(Some("ttl_expired\n<script>"));
        assert_eq!(r, "requested: ttl_expiredscript");
    }
}

// ------------------------------------------------- snapshots, fork, stop

#[derive(Deserialize, Default)]
struct MissionScope {
    /// The calling mission (set by the gateway); its project scopes snapshots.
    owner_mission_id: Option<uuid::Uuid>,
    /// Orb/API without a mission: an explicit project, or `all=true`.
    project: Option<String>,
    all: Option<bool>,
}

/// The project a request is scoped to. A mission must be in the caller's
/// store (404 otherwise).
async fn scope_project(
    state: &Arc<AppState>,
    user: &crate::api::auth::AuthUser,
    scope: &MissionScope,
) -> Result<Option<String>, Response> {
    let Some(mission) = scope.owner_mission_id else {
        return Ok(scope.project.clone().filter(|p| !p.trim().is_empty()));
    };
    let store = crate::api::control::control_for_user(state, user)
        .await
        .mission_store;
    match store.get_mission(mission).await {
        Ok(Some(m)) => Ok(m.project.project),
        _ => Err(err(ManagedError {
            error: "unknown_mission",
            message: "Owner mission not found".into(),
            status: 404,
        })),
    }
}

async fn list_snapshots(
    axum::extract::State(state): axum::extract::State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Query(scope): Query<MissionScope>,
) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    if scope.all == Some(true) && scope.owner_mission_id.is_none() {
        let mine: Vec<_> = m
            .all_snapshots()
            .await
            .into_iter()
            .filter(|s| s.owner_user_id.as_deref() == Some(user.id.as_str()))
            .collect();
        return Json(json!({ "snapshots": mine })).into_response();
    }
    let project = match scope_project(&state, &user, &scope).await {
        Ok(p) => p,
        Err(r) => return r,
    };
    Json(json!({
        "project": project,
        "snapshots": m.list_snapshots(Some(user.id.as_str()), project.as_deref()).await,
        "included_free": crate::managed::snapshots::INCLUDED_SNAPSHOTS,
        "usd_per_month_beyond": crate::managed::snapshots::SNAPSHOT_USD_PER_MONTH,
    }))
    .into_response()
}

async fn delete_snapshot(
    axum::extract::State(state): axum::extract::State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Path(name): Path<String>,
    Query(scope): Query<MissionScope>,
) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    let project = match scope_project(&state, &user, &scope).await {
        Ok(p) => p,
        Err(r) => return r,
    };
    match m
        .delete_snapshot(&name, Some(user.id.as_str()), project.as_deref())
        .await
    {
        Ok(()) => Json(json!({"deleted": name})).into_response(),
        Err(e) => err(e),
    }
}

#[derive(Deserialize)]
struct SnapshotBody {
    name: String,
    owner_mission_id: Option<uuid::Uuid>,
    project: Option<String>,
}

async fn snapshot(
    axum::extract::State(state): axum::extract::State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Path(id): Path<String>,
    Json(body): Json<SnapshotBody>,
) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    if let Err(r) = raw_owner_check(&m, &id, &user).await {
        return r;
    }
    let scope = MissionScope {
        owner_mission_id: body.owner_mission_id,
        project: body.project.clone(),
        all: None,
    };
    let project = match scope_project(&state, &user, &scope).await {
        Ok(p) => p,
        Err(r) => return r,
    };
    let owner = body.owner_mission_id.map(|u| u.to_string());
    match m
        .snapshot_machine(
            &id,
            &body.name,
            project.as_deref(),
            owner.as_deref(),
            Some(user.id.as_str()),
        )
        .await
    {
        Ok(s) => (StatusCode::ACCEPTED, Json(s)).into_response(),
        Err(e) => err(e),
    }
}

#[derive(Deserialize, Default)]
struct ForkBody {
    provisioning_mode: Option<crate::managed::ProvisioningMode>,
    size: Option<String>,
    ttl_minutes: Option<u64>,
    reason: Option<String>,
    owner_mission_id: Option<String>,
    requested_by_mission_id: Option<String>,
    wait: Option<bool>,
}

async fn fork(
    axum::extract::State(state): axum::extract::State<Arc<AppState>>,
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Path(id): Path<String>,
    body: Option<Json<ForkBody>>,
) -> Response {
    let body = body.map(|b| b.0).unwrap_or_default();
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    if let Err(r) = raw_owner_check(&m, &id, &user).await {
        return r;
    }
    // A fork keeps the source's size unless one is asked for.
    let size = match body.size {
        Some(s) => Some(s),
        None => m.get(&id).await.map(|src| src.size),
    };
    let req = SpawnRequest {
        provisioning_mode: body.provisioning_mode,
        size,
        ttl_minutes: body.ttl_minutes,
        reason: body.reason.or_else(|| Some(format!("fork of {id}"))),
        owner_mission_id: body.owner_mission_id,
        requested_by_mission_id: body.requested_by_mission_id,
        wait: body.wait,
        fork_of: Some(id),
        ..Default::default()
    };
    spawn_for(&state, &user, req).await
}

async fn visible_machines(m: &ManagedManager, tenant: &str) -> Vec<crate::managed::ManagedMachine> {
    m.machines_snapshot()
        .await
        .into_iter()
        .filter(|machine| {
            machine.provisioning_mode.is_worker()
                || machine.owner_user_id.as_deref() == Some(tenant)
        })
        .collect()
}

async fn raw_owner_check(
    m: &ManagedManager,
    id: &str,
    user: &crate::api::auth::AuthUser,
) -> Result<(), Response> {
    if let Some(machine) = m.get(id).await {
        if !machine.provisioning_mode.is_worker()
            && machine.owner_user_id.as_deref() != Some(user.id.as_str())
        {
            return Err(err(ManagedError {
                error: "not_found",
                status: 404,
                message: "Unknown managed machine".into(),
            }));
        }
    }
    Ok(())
}

/// Only the machine's own tenant may stop/resume it.
async fn tenant_machine(
    m: &ManagedManager,
    id: &str,
    user: &crate::api::auth::AuthUser,
) -> Result<crate::managed::ManagedMachine, Response> {
    raw_owner_check(m, id, user).await?;
    match m.get(id).await {
        Some(x)
            if (x.provisioning_mode.is_worker() && x.owner_user_id.is_none())
                || x.owner_user_id.as_deref() == Some(user.id.as_str()) =>
        {
            Ok(x)
        }
        Some(_) => Err(err(ManagedError {
            error: "forbidden",
            message: "Managed machine belongs to another user".into(),
            status: 403,
        })),
        None => Err(err(ManagedError {
            error: "not_found",
            message: "Unknown managed machine".into(),
            status: 404,
        })),
    }
}

async fn stop(
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Path(id): Path<String>,
) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    let machine = match tenant_machine(&m, &id, &user).await {
        Ok(x) => x,
        Err(r) => return r,
    };
    match m.stop_inner(&machine.id, "requested", false).await {
        Ok(x) => Json(x).into_response(),
        Err(e) => err(e),
    }
}

#[derive(Deserialize, Default)]
struct ResumeBody {
    ttl_minutes: Option<u64>,
}

async fn resume(
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Path(id): Path<String>,
    body: Option<Json<ResumeBody>>,
) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    let machine = match tenant_machine(&m, &id, &user).await {
        Ok(x) => x,
        Err(r) => return r,
    };
    match m
        .resume(&machine.id, body.and_then(|b| b.0.ttl_minutes))
        .await
    {
        Ok(x) => (StatusCode::ACCEPTED, Json(x)).into_response(),
        Err(e) => err(e),
    }
}

async fn raw_operation(
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Path(id): Path<String>,
    Json(request): Json<crate::managed::raw_operations::OperationRequest>,
) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    match m.raw_operation(&id, &user.id, request).await {
        Ok(receipt) => Json(receipt).into_response(),
        Err(e) => err(e),
    }
}
