//! Authenticated Core boundary. Scoped MCP tokens never authorize ordinary API routes.
use super::{registry, wire_catalog, Role, Tool, CONTRACT_VERSION};
use crate::api::{
    auth::{issue_jwt, AuthUser},
    routes::AppState,
};
use axum::{extract::State, Extension, Json};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::Arc;
use uuid::Uuid;

/// Read-only tools a /btw side agent may call on its parent mission.
fn btw_parent_read_allowed(tool: &str, owner_tags: &[String], target: Uuid) -> bool {
    BTW_PARENT_READS.contains(&tool)
        && owner_tags
            .iter()
            .any(|t| *t == format!("btw-parent:{target}"))
}
fn sets_reserved_btw_tag(args: &Value) -> bool {
    args.get("tags")
        .and_then(Value::as_array)
        .is_some_and(|tags| {
            tags.iter()
                .filter_map(Value::as_str)
                .any(|t| t.starts_with("btw-parent:"))
        })
}
const BTW_PARENT_READS: &[&str] = &[
    "get_mission",
    "get_mission_events",
    "get_mission_health",
    "list_mission_shared_files",
];

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Principal {
    pub sub: String,
    pub username: String,
    pub role: Role,
    pub mission_id: Option<Uuid>,
    #[serde(default)]
    pub project: Option<String>,
    /// Captured at action acceptance, persisted with queued wake-up intent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_run_generation: Option<u64>,
    pub session_id: Uuid,
    pub exp: usize,
}

fn key(state: &AppState) -> Result<String, String> {
    let secret = state
        .config
        .auth
        .jwt_secret
        .as_deref()
        .ok_or("MCP grants require configured authentication")?;
    Ok(crate::project_context::digest(
        format!("sandboxed-mcp-v1:{secret}").as_bytes(),
    ))
}

/// How long after expiry a still-live mission may renew its session. A remote
/// job carries the credential minted at dispatch and may wait in a node queue
/// for hours before its harness first contacts Core.
pub const RENEWAL_GRACE_SECS: i64 = 24 * 3600;

pub fn verify(state: &AppState, token: &str) -> Result<Principal, String> {
    verify_with(state, token, false)
}

/// Accepts a signed, unrevoked session up to [`RENEWAL_GRACE_SECS`] after
/// expiry. Only `/api/mcp/renew` uses this, and renewal also requires the
/// bound mission to be live.
pub fn verify_for_renewal(state: &AppState, token: &str) -> Result<Principal, String> {
    verify_with(state, token, true)
}

fn verify_with(state: &AppState, token: &str, renewal: bool) -> Result<Principal, String> {
    let token = token.strip_prefix("mcp1.").ok_or("Invalid MCP token")?;
    let mut validation = jsonwebtoken::Validation::default();
    if renewal {
        validation.validate_exp = false;
        validation.required_spec_claims.clear();
    }
    let principal = jsonwebtoken::decode::<Principal>(
        token,
        &jsonwebtoken::DecodingKey::from_secret(key(state)?.as_bytes()),
        &validation,
    )
    .map(|v| v.claims)
    .map_err(|_| "Invalid or expired MCP session")?;
    if renewal && (principal.exp as i64) + RENEWAL_GRACE_SECS < chrono::Utc::now().timestamp() {
        return Err("Invalid or expired MCP session".into());
    }
    let conn = state
        .projects
        .connection
        .lock()
        .map_err(|_| "Session store unavailable")?;
    let valid:bool=conn.query_row("SELECT EXISTS(SELECT 1 FROM mcp_sessions_v1 WHERE id=?1 AND owner=?2 AND revoked=0 AND expires_at>=?3)",rusqlite::params![principal.session_id.to_string(),principal.sub,principal.exp as i64],|r|r.get(0)).map_err(|_|"Session unavailable")?;
    if !valid {
        return Err("MCP session revoked".into());
    }
    Ok(principal)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionRequest {
    pub role: Role,
    pub mission_id: Option<Uuid>,
    pub project: Option<String>,
}

pub async fn session(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(req): Json<SessionRequest>,
) -> Result<Json<Value>, (axum::http::StatusCode, String)> {
    use axum::http::StatusCode;
    if req.role == Role::Executor && req.mission_id.is_none() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Executor sessions require a mission".into(),
        ));
    }
    if let Some(id) = req.mission_id {
        let mission = state
            .control
            .get_or_spawn(&user)
            .await
            .mission_store
            .get_mission(id)
            .await
            .map_err(|_| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Mission lookup failed".into(),
                )
            })?
            .ok_or((
                StatusCode::FORBIDDEN,
                "Mission is not owned by this user".into(),
            ))?;
        if req
            .project
            .as_deref()
            .is_some_and(|project| mission.project.project.as_deref() != Some(project))
        {
            return Err((
                StatusCode::FORBIDDEN,
                "Mission does not belong to requested project scope".into(),
            ));
        }
    }
    if let Some(project) = req.project.as_deref() {
        if state
            .projects
            .get_project(project)
            .map_err(|_| {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Project lookup failed".into(),
                )
            })?
            .is_none()
        {
            return Err((StatusCode::BAD_REQUEST, "Unknown project scope".into()));
        }
    }
    // Only an owner login reaches this endpoint; mcp1 tokens cannot issue grants.
    let principal = Principal {
        sub: user.id,
        username: user.username,
        role: req.role,
        mission_id: req.mission_id,
        project: req.project,
        action_run_generation: None,
        session_id: Uuid::new_v4(),
        exp: (chrono::Utc::now() + chrono::Duration::hours(1)).timestamp() as usize,
    };
    issue_session(&state, &principal)
        .map(Json)
        .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, e))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolError {
    pub code: String,
    pub message: String,
    pub accepted: String,
    pub retryable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action_id: Option<String>,
}
impl ToolError {
    fn denied(message: &str) -> Self {
        Self {
            code: "forbidden".into(),
            message: message.into(),
            accepted: "no".into(),
            retryable: false,
            action_id: None,
        }
    }
    fn invalid(message: &str) -> Self {
        Self {
            code: "invalid_arguments".into(),
            message: message.into(),
            accepted: "no".into(),
            retryable: false,
            action_id: None,
        }
    }
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Call {
    pub name: String,
    #[serde(default = "empty_object")]
    pub arguments: Value,
}
fn empty_object() -> Value {
    json!({})
}

pub async fn capabilities(
    State(state): State<Arc<AppState>>,
    Extension(p): Extension<Principal>,
) -> Json<Value> {
    Json(capabilities_value(&p, state.config.automations_enabled))
}
fn capabilities_value(p: &Principal, scheduling_enabled: bool) -> Value {
    let tools: Vec<_> = wire_catalog(p.role)
        .into_iter()
        .filter(|t| scheduling_enabled || !is_wakeup(t["name"].as_str().unwrap_or("")))
        .collect();
    json!({"contract_version":CONTRACT_VERSION,"build":env!("SOFTWARE_BUILD_ID"),"identity":{"user_id":p.sub,"mission_id":p.mission_id,"project":p.project,"role":p.role},"tools":tools,"limits":{"concurrent_calls":8,"session_expires_at":p.exp},"cloud_discovery":"list_cloud_accounts"})
}

fn is_wakeup(name: &str) -> bool {
    matches!(name, "schedule_wakeup" | "schedule_job_wakeup")
}

async fn authorize(
    state: &Arc<AppState>,
    p: &Principal,
    tool: &Tool,
    args: &mut Value,
) -> Result<(), ToolError> {
    if is_wakeup(&tool.definition.name) && !state.config.automations_enabled {
        return Err(ToolError::denied(
            "Durable scheduling is disabled on this server",
        ));
    }
    if !tool.visible_to(p.role) {
        return Err(ToolError::denied("Tool is not authorized for this role"));
    }
    if !args.is_object() {
        return Err(ToolError::invalid("Arguments must be an object"));
    }
    if args.get("parent_mission_id").is_some() || args.get("caller").is_some() {
        return Err(ToolError::invalid("Parent identity is provided by Core"));
    }
    if tool.definition.name == "plan_tasks" {
        let id = p.mission_id.ok_or_else(|| {
            ToolError::denied("Task planning requires a mission-scoped coordinator session")
        })?;
        let control = state
            .control
            .get_or_spawn(&AuthUser {
                id: p.sub.clone(),
                username: p.username.clone(),
            })
            .await;
        let mission = control
            .mission_store
            .get_mission(id)
            .await
            .map_err(|_| ToolError::denied("Mission unavailable"))?
            .ok_or_else(|| ToolError::denied("Mission unavailable"))?;
        crate::api::control::machine_transfer::guard(&control.mission_store, id)
            .await
            .map_err(|_| ToolError::denied("Mission placement is changing or unavailable"))?;
        if crate::api::control::client_placement::is_tagged(&mission.project.tags)
            || crate::api::control::remote_grok::placement(
                &state.config.working_dir,
                &control.mission_store,
                id,
            )
            .await
            .map_err(|_| ToolError::denied("Mission placement unavailable"))?
            .is_some()
        {
            return Err(ToolError::denied("Task-board scheduling on this machine is not yet available; use start_mission for explicit child delegation"));
        }
    }
    if let Some(project) = p.project.as_deref() {
        // Project scope must constrain every object family, not just tools
        // which happen to take a `slug`. Infrastructure/global boards do not
        // have a project owner, so they require an unscoped session.
        if matches!(
            tool.definition.name.as_str(),
            "get_compute_fleet"
                | "list_workspaces"
                | "get_workspace"
                | "create_workspace"
                | "update_workspace"
                | "delete_workspace"
                | "rebuild_workspace_from_template"
                | "save_workspace_template"
                | "delete_workspace_template"
                | "get_backend_auth_status"
                | "deploy_sandboxed_sh"
        ) {
            return Err(ToolError::denied(
                "This operation requires an unscoped session",
            ));
        }
        if tool.handler == super::Handler::Orchestrator && p.mission_id.is_none() {
            return Err(ToolError::denied(
                "Board operations require a project mission",
            ));
        }
        for field in ["slug", "project"] {
            if let Some(requested) = args.get(field).and_then(Value::as_str) {
                if requested != project {
                    return Err(ToolError::denied(&format!(
                        "Project '{requested}' is outside this session's scope. Use {field}=\"{project}\" (or omit it to default to this session's project)."
                    )));
                }
            }
        }
        if args.get("project_prefix").is_some() {
            return Err(ToolError::denied(
                "Project-prefix queries are outside a project-scoped session",
            ));
        }
        if matches!(
            tool.definition.name.as_str(),
            "list_missions" | "list_active_missions" | "start_mission" | "consult_model"
        ) {
            args["project"] = json!(project);
        }
        let user = AuthUser {
            id: p.sub.clone(),
            username: p.username.clone(),
        };
        let store = state.control.get_or_spawn(&user).await.mission_store;
        if let Some(id) = p.mission_id {
            let mission = store
                .get_mission(id)
                .await
                .map_err(|_| ToolError::denied("Mission unavailable"))?
                .ok_or_else(|| ToolError::denied("Mission unavailable"))?;
            if mission.project.project.as_deref() != Some(project) {
                return Err(ToolError::denied(
                    "Session mission moved outside its project scope",
                ));
            }
        }
        for field in ["mission_id", "supersedes_mission_id"] {
            if let Some(raw) = args.get(field).and_then(Value::as_str) {
                let id = Uuid::parse_str(raw)
                    .map_err(|_| ToolError::invalid("Full mission UUID required"))?;
                let mission = store
                    .get_mission(id)
                    .await
                    .map_err(|_| ToolError::denied("Mission unavailable"))?
                    .ok_or_else(|| ToolError::denied("Mission unavailable"))?;
                if mission.project.project.as_deref() != Some(project) {
                    // An approved read grant crosses projects for read tools
                    // only. Executors are audited by the tree check below.
                    match granted_read(state, p, &tool.definition.name, id).await {
                        Some(grant) => {
                            if p.role != Role::Executor {
                                record_granted_read(state, p, grant, &tool.definition.name).await;
                            }
                        }
                        None => {
                            return Err(ToolError::denied(&format!(
                                "Mission is outside this session's project. {}",
                                crate::api::mission_access::scope_hint(&tool.definition.name, id)
                            )))
                        }
                    }
                }
            }
        }
    }
    if launches_child(&tool.definition.name) && args.get("cloud").is_some_and(|v| !v.is_null()) {
        for field in [
            "workspace_id",
            "remote_node_id",
            "backend",
            "model_override",
            "model_effort",
            "agent",
            "config_profile",
        ] {
            if args.get(field).is_some_and(|v| !v.is_null()) {
                return Err(ToolError::invalid(&cloud_launch_field_message(field)));
            }
        }
    }
    // `btw-parent:` grants read access to another mission (see BTW_PARENT_READS); only Core's
    // /btw launch may set it, never an agent through MCP.
    if sets_reserved_btw_tag(args) {
        return Err(ToolError::denied("The btw-parent tag is reserved"));
    }
    authorize_job(state, p, args).await?;
    if tool.handler == super::Handler::Workspace {
        super::workspace_ops::preflight(state, p, args)
            .await
            .map_err(|e| ToolError::denied(&e))?;
    }
    if p.role != Role::Executor {
        return Ok(());
    }
    let own = p
        .mission_id
        .ok_or_else(|| ToolError::denied("Missing mission scope"))?;
    let user = AuthUser {
        id: p.sub.clone(),
        username: p.username.clone(),
    };
    let store = state.control.get_or_spawn(&user).await.mission_store;
    let owner = store
        .get_mission(own)
        .await
        .map_err(|_| ToolError::denied("Mission unavailable"))?
        .ok_or_else(|| ToolError::denied("Mission no longer exists"))?;
    for field in ["mission_id", "supersedes_mission_id"] {
        if let Some(raw) = args.get(field).filter(|v| !v.is_null()) {
            let id = raw
                .as_str()
                .and_then(|s| Uuid::parse_str(s).ok())
                .ok_or_else(|| ToolError::invalid("A full mission UUID is required"))?;
            let m = store
                .get_mission(id)
                .await
                .map_err(|_| ToolError::denied("Mission unavailable"))?
                .ok_or_else(|| ToolError::denied("Mission unavailable"))?;
            // A /btw side agent may read (never act on) the conversation it was asked about:
            // Core tags it `btw-parent:<id>` at creation, and side agents read the parent
            // through get_mission_events instead of receiving a full uploaded archive.
            let reads_btw_parent =
                btw_parent_read_allowed(&tool.definition.name, &owner.project.tags, id);
            if id != own && m.parent_mission_id != Some(own) && !reads_btw_parent {
                // Read-only grant approved by Thomas (request_mission_access).
                // Only READ_TOOLS consult it; control tools stay denied.
                match granted_read(state, p, &tool.definition.name, id).await {
                    Some(grant) => {
                        record_granted_read(state, p, grant, &tool.definition.name).await
                    }
                    None => {
                        return Err(ToolError::denied(&crate::api::mission_access::scope_hint(
                            &tool.definition.name,
                            id,
                        )))
                    }
                }
            }
            if tool.definition.name == "start_workspace_job" && m.workspace_id != owner.workspace_id
            {
                return Err(ToolError::denied(
                    "Job workspace is outside this session's scope",
                ));
            }
        }
    }
    // Managed machines may be targeted by name ("small-a"); resolve to the
    // immutable node id before any check or persistence.
    if launches_child(&tool.definition.name) {
        if let Some(r) = args.get("remote_node_id").and_then(Value::as_str) {
            let resolved = crate::managed::resolve_node_alias(r);
            if resolved != r {
                args["remote_node_id"] = json!(resolved);
            }
        }
    }
    // Managed machines belong to the mission tree that rented them.
    match tool.definition.name.as_str() {
        "spawn_managed_machine" | "list_managed_snapshots" | "delete_managed_snapshot" => {
            args["owner_mission_id"] = json!(own.to_string());
        }
        // Machine-level actions: the machine must belong to the caller's
        // tree; a fork or snapshot is attributed to the caller.
        "snapshot_managed_machine"
        | "fork_managed_machine"
        | "stop_managed_machine"
        | "resume_managed_machine" => {
            let id = args
                .get("machine_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            managed_owner_check(&store, own, &id).await?;
            args["owner_mission_id"] = json!(own.to_string());
        }
        // A mission reads its own budget only.
        "get_budget" => {
            args["mission_id"] = json!(own.to_string());
        }
        "destroy_managed_machine" | "extend_managed_machine" => {
            let id = args
                .get("machine_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            managed_owner_check(&store, own, &id).await?;
            // Extending a descendant's VM is a takeover (the caller's lifetime
            // now governs it). A child extending a VM its ancestor rented
            // leaves the ancestor as owner: the child is a tenant, and the
            // VM must not go when that child completes.
            if tool.definition.name == "extend_managed_machine" {
                if let Some(manager) = crate::managed::global() {
                    let owner = manager
                        .get(&id)
                        .await
                        .and_then(|m| m.owner_mission_id)
                        .and_then(|o| Uuid::parse_str(&o).ok());
                    let caller_chain = mission_lineage(&store, own).await;
                    if !owner_is_ancestor(&caller_chain, owner) {
                        manager.adopt(&id, &own.to_string()).await;
                    }
                }
            }
        }
        "start_mission" | "consult_model" => {
            if let Some(r) = args.get("remote_node_id").and_then(Value::as_str) {
                if crate::managed::is_managed_node(r) {
                    managed_owner_check(&store, own, r).await?;
                }
            }
        }
        _ => {}
    }
    // A native child may leave its parent's machine: `remote_node_id` set to
    // "auto" (fleet scheduler) or to another registered node. It then starts
    // in that node's default workspace, never in the parent's.
    let mut elsewhere = launches_child(&tool.definition.name)
        && args.get("cloud").is_none_or(Value::is_null)
        && match args.get("remote_node_id").and_then(Value::as_str) {
            Some(r) if r.eq_ignore_ascii_case("auto") => true,
            Some(r) if r.to_ascii_lowercase().starts_with("auto-managed") => true,
            Some(r) => {
                if state.config.remote_nodes.node(r).is_none() {
                    return Err(ToolError::denied("Unknown remote node"));
                }
                true
            }
            None => false,
        };
    if let Some(raw) = args.get("workspace_id") {
        let own_workspace = raw.as_str() == Some(owner.workspace_id.to_string().as_str());
        // Acceptance pins a native child to the parent's workspace *and* the
        // parent's node, and dispatch re-runs this check on those stored
        // arguments. The parent's own node is not "elsewhere".
        let parent_node = if elsewhere && own_workspace {
            crate::api::control::remote_grok::placement(&state.config.working_dir, &store, own)
                .await
                .ok()
                .flatten()
                .map(|p| p.node_id)
        } else {
            None
        };
        let requested_node = args.get("remote_node_id").and_then(Value::as_str);
        if !workspace_in_scope(
            own_workspace,
            elsewhere,
            requested_node,
            parent_node.as_deref(),
        ) {
            return Err(ToolError::denied(
                "Workspace is outside this session's scope",
            ));
        }
        elsewhere = false;
    }
    if tool.definition.name == "start_workspace_job"
        || (launches_child(&tool.definition.name)
            && args.get("cloud").is_none_or(Value::is_null)
            && !elsewhere)
    {
        args["workspace_id"] = json!(owner.workspace_id);
    }
    if launches_child(&tool.definition.name) && args.get("cloud").is_none_or(Value::is_null) {
        crate::api::control::machine_transfer::guard(&store, own)
            .await
            .map_err(|_| {
                ToolError::denied(
                    "Parent placement is changing or does not support native delegation",
                )
            })?;
        if crate::api::control::client_placement::is_tagged(&owner.project.tags) {
            return Err(ToolError::denied(
                "Orb owns this workspace. Native child placement requires the desktop client; use a cloud child or an explicitly placed coordinator launch",
            ));
        }
        // The latest run can still refer to the source machine immediately
        // after a committed transfer. Use the same durable placement resolver
        // as follow-ups rather than inferring placement from that stale lease.
        let placement =
            crate::api::control::remote_grok::placement(&state.config.working_dir, &store, own)
                .await
                .map_err(|_| ToolError::denied("Parent placement unavailable"))?;
        let node = placement.as_ref().map(|p| p.node_id.as_str());
        if node == Some("unknown") {
            return Err(ToolError::denied(
                "Parent machine is unknown; resolve placement before delegating",
            ));
        }
        if !elsewhere {
            if let Some(node) = node {
                args["remote_node_id"] = json!(node);
            }
        }
    }
    if launches_child(&tool.definition.name) {
        if let Some(project) = args.get("project").and_then(Value::as_str) {
            if owner.project.project.as_deref() != Some(project) {
                return Err(ToolError::denied(&project_mismatch_message(
                    project,
                    owner.project.project.as_deref(),
                )));
            }
        } else if let Some(project) = owner.project.project.as_deref() {
            args["project"] = json!(project);
        }
        if args.get("request_merge_authority").and_then(Value::as_bool) == Some(true) {
            return Err(ToolError::denied("Delegation cannot grant merge authority"));
        }
        args["parent_mission_id"] = json!(own);
        // The child was started by this mission's agent, not by the Hermes
        // assistant: record that provenance instead of `origin=hermes`.
        args["caller"] = json!("mission");
    }
    Ok(())
}

/// Rejection for a child whose explicit project differs from its parent's.
fn project_mismatch_message(requested: &str, parent: Option<&str>) -> String {
    match parent {
        Some(parent) => format!(
            "Child mission project '{requested}' must match its parent's. Use the parent's project: {parent} (pass project=\"{parent}\" or omit project to inherit it)."
        ),
        None => format!(
            "Child mission project '{requested}' must match its parent, which has no project. Omit project so the child inherits the parent's (empty) project."
        ),
    }
}

/// Rejection for a cloud launch that also carries native settings.
fn cloud_launch_field_message(field: &str) -> String {
    format!(
        "Cloud launches must not include native placement or harness settings (got `{field}`). Remove {field} (and any of workspace_id, remote_node_id, backend, model_override, model_effort, agent, config_profile), or drop `cloud` and launch natively with backend=opencode and model_override=<provider>/<model>."
    )
}

/// Tools that create a child mission and therefore get the same placement,
/// project and lineage treatment as `start_mission`.
/// A pinned `workspace_id` is the caller's own, and the child either stays
/// on the parent's machine or targets the parent's own node by id.
fn workspace_in_scope(
    own_workspace: bool,
    elsewhere: bool,
    requested_node: Option<&str>,
    parent_node: Option<&str>,
) -> bool {
    own_workspace
        && (!elsewhere || requested_node.is_some_and(|r| parent_node == Some(r) && r != "unknown"))
}

fn launches_child(name: &str) -> bool {
    matches!(name, "start_mission" | "consult_model")
}

/// Live read grant of the calling mission on `target`, for read-only tools.
async fn granted_read(
    state: &Arc<AppState>,
    p: &Principal,
    tool: &str,
    target: Uuid,
) -> Option<Uuid> {
    let own = p.mission_id?;
    crate::api::mission_access::store(state)
        .grant_for_tool(&p.sub, own, target, tool)
        .await
}

async fn record_granted_read(state: &Arc<AppState>, p: &Principal, grant: Uuid, tool: &str) {
    crate::api::mission_access::store(state)
        .record_read(&p.sub, grant, tool)
        .await;
}

/// Mission ids from `id` up through its parents (bounded).
async fn mission_lineage(
    store: &std::sync::Arc<dyn crate::api::mission_store::MissionStore>,
    id: Uuid,
) -> Vec<Uuid> {
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
    chain
}

/// The machine's owner is the caller or one of its ancestors.
pub(crate) fn owner_is_ancestor(caller_chain: &[Uuid], owner: Option<Uuid>) -> bool {
    owner.is_some_and(|o| caller_chain.contains(&o))
}

/// Owner, ancestor or descendant of the owning mission may act on a machine.
pub(crate) fn lineage_related(caller_chain: &[Uuid], owner_chain: &[Uuid]) -> bool {
    let (Some(caller), Some(owner)) = (caller_chain.first(), owner_chain.first()) else {
        return false;
    };
    caller_chain.contains(owner) || owner_chain.contains(caller)
}

async fn managed_owner_check(
    store: &std::sync::Arc<dyn crate::api::mission_store::MissionStore>,
    own: Uuid,
    machine: &str,
) -> Result<(), ToolError> {
    let manager = crate::managed::global()
        .ok_or_else(|| ToolError::denied("Managed machines unavailable"))?;
    let machine = manager
        .get(machine)
        .await
        .ok_or_else(|| ToolError::denied("Unknown managed machine"))?;
    let owner = machine
        .owner_mission_id
        .as_deref()
        .and_then(|s| Uuid::parse_str(s).ok())
        .ok_or_else(|| ToolError::denied("Managed machine belongs to another owner"))?;
    let caller_chain = mission_lineage(store, own).await;
    let owner_chain = mission_lineage(store, owner).await;
    if lineage_related(&caller_chain, &owner_chain) {
        Ok(())
    } else {
        Err(ToolError::denied(
            "Managed machine belongs to another mission tree",
        ))
    }
}

async fn authorize_job(
    state: &Arc<AppState>,
    p: &Principal,
    args: &Value,
) -> Result<(), ToolError> {
    let user = AuthUser {
        id: p.sub.clone(),
        username: p.username.clone(),
    };
    // Executor job reads/cancels must validate the job owner before forwarding.
    if p.role == Role::Executor || p.project.is_some() {
        if let Some(id) = args.get("job_id").and_then(Value::as_str) {
            let job = crate::api::durable_jobs::get_job(
                State(state.clone()),
                Extension(user.clone()),
                axum::extract::Path(
                    Uuid::parse_str(id).map_err(|_| ToolError::invalid("Invalid job UUID"))?,
                ),
            )
            .await
            .map_err(|_| ToolError::denied("Job unavailable"))?
            .0;
            if p.role == Role::Executor && job.started_by_mission_id != p.mission_id {
                return Err(ToolError::denied("Job is outside this session's scope"));
            }
            if let Some(project) = p.project.as_deref() {
                let mission = match job.started_by_mission_id {
                    Some(id) => state
                        .control
                        .get_or_spawn(&user)
                        .await
                        .mission_store
                        .get_mission(id)
                        .await
                        .map_err(|_| ToolError::denied("Job mission unavailable"))?,
                    None => None,
                };
                if mission.as_ref().and_then(|m| m.project.project.as_deref()) != Some(project) {
                    return Err(ToolError::denied("Job is outside this session's project"));
                }
            }
        }
    }
    Ok(())
}

type SessionSlots = std::collections::HashMap<Uuid, std::sync::Weak<tokio::sync::Semaphore>>;
static CALL_SLOTS: std::sync::LazyLock<std::sync::Mutex<SessionSlots>> =
    std::sync::LazyLock::new(Default::default);
fn claim_call_slot(session: Uuid) -> Result<tokio::sync::OwnedSemaphorePermit, ToolError> {
    let mut slots = CALL_SLOTS
        .lock()
        .map_err(|_| ToolError::denied("Call admission unavailable"))?;
    slots.retain(|_, slot| slot.strong_count() > 0);
    let semaphore = slots
        .get(&session)
        .and_then(std::sync::Weak::upgrade)
        .unwrap_or_else(|| {
            let semaphore = Arc::new(tokio::sync::Semaphore::new(8));
            slots.insert(session, Arc::downgrade(&semaphore));
            semaphore
        });
    semaphore.try_acquire_owned().map_err(|_| ToolError {
        code: "busy".into(),
        message: "At most eight concurrent calls are allowed per session".into(),
        accepted: "no".into(),
        retryable: true,
        action_id: None,
    })
}

pub async fn call(
    State(state): State<Arc<AppState>>,
    Extension(p): Extension<Principal>,
    Json(mut call): Json<Call>,
) -> Json<Value> {
    let result = match claim_call_slot(p.session_id) {
        Ok(_permit) => call_inner(state, &p, &mut call).await,
        Err(error) => Err(error),
    };
    Json(match result {
        Ok(v) => json!({"ok":true,"result":v}),
        Err(e) => json!({"ok":false,"error":e}),
    })
}

async fn call_inner(
    state: Arc<AppState>,
    p: &Principal,
    call: &mut Call,
) -> Result<Value, ToolError> {
    let tool = registry()
        .into_iter()
        .find(|t| t.definition.name == call.name)
        .ok_or_else(|| ToolError::invalid("Unknown tool"))?;
    super::schema::validate(&tool.definition.input_schema, &call.arguments)
        .map_err(|e| ToolError::invalid(&e))?;
    authorize(&state, p, &tool, &mut call.arguments).await?;
    if call.name == "get_capabilities" {
        let mut value = capabilities_value(p, state.config.automations_enabled);
        value["tools"] = json!(registry()
            .into_iter()
            .filter(|t| t.visible_to(p.role)
                && (state.config.automations_enabled || !is_wakeup(&t.definition.name)))
            .map(|t| json!({"name":t.definition.name,"mutation":t.mutation}))
            .collect::<Vec<_>>());
        return Ok(value);
    }
    if crate::api::mission_access::TOOL_NAMES.contains(&call.name.as_str()) {
        return crate::api::mission_access::handle_tool(&state, p, &call.name, &call.arguments)
            .await
            .map_err(|e| ToolError::denied(&e));
    }
    if crate::api::privilege_broker::TOOL_NAMES.contains(&call.name.as_str()) {
        return crate::api::privilege_broker::handle_tool(&state, p, &call.name, &call.arguments)
            .await
            .map_err(|e| ToolError::denied(&e));
    }
    if crate::api::secret_broker::TOOL_NAMES.contains(&call.name.as_str()) {
        return crate::api::secret_broker::handle_tool(&state, p, &call.name, &call.arguments)
            .await
            .map_err(|e| ToolError::denied(&e));
    }
    if call.name == "get_action" {
        let id = call.arguments["action_id"]
            .as_str()
            .and_then(|s| Uuid::parse_str(s).ok())
            .ok_or_else(|| ToolError::invalid("Invalid action UUID"))?;
        return super::actions::read(
            &*state
                .projects
                .connection
                .lock()
                .map_err(|_| ToolError::denied("Action store unavailable"))?,
            p,
            &id.to_string(),
        )
        .map_err(|e| ToolError::denied(&e));
    }
    if call.name == "cancel_action" {
        return super::actions::cancel(
            &*state
                .projects
                .connection
                .lock()
                .map_err(|_| ToolError::denied("Action store unavailable"))?,
            p,
            call,
        )
        .map_err(|e| ToolError::denied(&e));
    }
    if call.name == "reconcile_action" {
        return super::actions::reconcile(
            &*state
                .projects
                .connection
                .lock()
                .map_err(|_| ToolError::denied("Action store unavailable"))?,
            p,
            call,
        )
        .map_err(|e| ToolError::denied(&e));
    }
    let user = AuthUser {
        id: p.sub.clone(),
        username: p.username.clone(),
    };
    let token = issue_jwt(
        state
            .config
            .auth
            .jwt_secret
            .as_deref()
            .ok_or_else(|| ToolError::denied("Authentication unavailable"))?,
        1,
        &user,
    )
    .map_err(|_| ToolError::denied("Authentication unavailable"))?
    .0;
    let api_url = format!("http://127.0.0.1:{}", state.config.port);
    if tool.mutation {
        let mut issuer = p.clone();
        if is_wakeup(&call.name) {
            let mission = p
                .mission_id
                .ok_or_else(|| ToolError::denied("Wake-ups require a mission"))?;
            let store = state.control.get_or_spawn(&user).await.mission_store;
            issuer.action_run_generation = Some(
                store
                    .get_latest_mission_run(mission)
                    .await
                    .map_err(|_| ToolError::denied("Mission run unavailable"))?
                    .map_or(0, |run| run.generation),
            );
        }
        return super::actions::reserve(
            &*state
                .projects
                .connection
                .lock()
                .map_err(|_| ToolError::denied("Action store unavailable"))?,
            &issuer,
            call,
        )
        .map_err(|e| ToolError::invalid(&e));
    }
    let mut value = super::execute(
        &state,
        p,
        api_url,
        token,
        p.mission_id,
        &tool,
        call.arguments.clone(),
    )
    .await
    .map_err(|error| ToolError {
        code: "read_failed".into(),
        message: super::assistant::safe_diagnostic(&error),
        accepted: "no".into(),
        retryable: true,
        action_id: None,
    })?;
    if call.name == "list_projects" {
        if let (Some(project), Some(rows)) =
            (p.project.as_deref(), value["projects"].as_array_mut())
        {
            rows.retain(|row| row["slug"].as_str() == Some(project));
        }
    }
    super::assistant::scrub_sensitive_json(&mut value);
    Ok(value)
}

/// One durable dispatcher per Core process; queued actions survive a restart.
pub fn start_worker(state: Arc<AppState>) -> Result<(), String> {
    {
        let conn = state
            .projects
            .connection
            .lock()
            .map_err(|e| e.to_string())?;
        super::actions::init(&conn)?;
        super::actions::recover(&conn)?;
    }
    tokio::spawn(async move {
        // Routes are assembled before the listener binds. Recovered queued
        // work must remain queued until our loopback dispatcher is reachable;
        // otherwise a normal restart turns safe work into an unknown outcome.
        let readiness = format!("http://127.0.0.1:{}/api/health", state.config.port);
        loop {
            if state
                .http_client
                .get(&readiness)
                .timeout(std::time::Duration::from_secs(2))
                .send()
                .await
                .is_ok_and(|response| response.status().is_success())
            {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }
        let slots = Arc::new(tokio::sync::Semaphore::new(8));
        loop {
            let Ok(permit) = slots.clone().acquire_owned().await else {
                break;
            };
            let next = {
                state
                    .projects
                    .connection
                    .lock()
                    .map_err(|_| "Action store poisoned".to_string())
                    .and_then(|conn| super::actions::claim(&conn))
            };
            match next {
                Ok(Some((id, principal, call))) => {
                    let state = state.clone();
                    tokio::spawn(async move {
                        let _permit = permit;
                        let result = run_accepted(&state, &principal, &call).await;
                        let mut receipt = match result {
                            Ok(value) => json!({"action_id":id,"state":"completed","result":value}),
                            Err(error) => {
                                json!({"action_id":id,"state":if error.accepted=="no"{"rejected"}else{"reconciliation_required"},"error":error})
                            }
                        };
                        super::assistant::scrub_sensitive_json(&mut receipt);
                        let saved = state
                            .projects
                            .connection
                            .lock()
                            .map_err(|_| "Action store poisoned".to_string())
                            .and_then(|conn| super::actions::finish(&conn, &id, &receipt));
                        if saved.is_err() {
                            tracing::error!(action_id=%id,"Failed to persist MCP action result");
                        }
                    });
                }
                Ok(None) => {
                    drop(permit);
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                }
                Err(_) => {
                    drop(permit);
                    tracing::error!("MCP action queue unavailable");
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
            }
        }
    });
    Ok(())
}
async fn run_accepted(
    state: &Arc<AppState>,
    p: &Principal,
    call: &Call,
) -> Result<Value, ToolError> {
    let tool = registry()
        .into_iter()
        .find(|t| t.definition.name == call.name)
        .ok_or_else(|| ToolError::invalid("Tool no longer available"))?;
    if !tool.visible_to(p.role) {
        return Err(ToolError::denied("Tool no longer authorized"));
    }
    // A queued action has not reached its target yet. Revocation or a deleted
    // mission must prevent dispatch even if acceptance happened earlier.
    let session_valid:bool=state.projects.connection.lock().map_err(|_|ToolError::denied("Session store unavailable"))?.query_row(
        "SELECT EXISTS(SELECT 1 FROM mcp_sessions_v1 WHERE id=?1 AND owner=?2 AND revoked=0 AND expires_at>?3)",
        rusqlite::params![p.session_id.to_string(),p.sub,chrono::Utc::now().timestamp()],|r|r.get(0)
    ).map_err(|_|ToolError::denied("Session store unavailable"))?;
    if !session_valid {
        return Err(ToolError::denied(
            "Session revoked or expired before dispatch",
        ));
    }
    if is_wakeup(&call.name) && p.action_run_generation.is_none() {
        return Err(ToolError::denied(
            "Queued wake-up has no originating run; submit a fresh request",
        ));
    }
    let mut arguments = call.arguments.clone();
    // Parent identity was inserted at acceptance, never supplied by the client.
    if let Some(map) = arguments.as_object_mut() {
        map.remove("parent_mission_id");
        map.remove("caller");
    }
    authorize(state, p, &tool, &mut arguments).await?;
    if tool.handler == super::Handler::Workspace {
        return super::workspace_ops::execute(state, p, &call.name, arguments)
            .await
            .map_err(|_| ToolError {
                code: "execution_failed".into(),
                message:
                    "Workspace operation outcome is unconfirmed; inspect its target before retrying"
                        .into(),
                accepted: "unknown".into(),
                retryable: false,
                action_id: None,
            });
    }
    let user = AuthUser {
        id: p.sub.clone(),
        username: p.username.clone(),
    };
    let token = issue_jwt(
        state
            .config
            .auth
            .jwt_secret
            .as_deref()
            .ok_or_else(|| ToolError::denied("Authentication unavailable"))?,
        1,
        &user,
    )
    .map_err(|_| ToolError::denied("Authentication unavailable"))?
    .0;
    let key = crate::project_context::digest(
        json!([
            p.sub,
            p.mission_id,
            p.project,
            call.name,
            arguments["idempotency_key"]
        ])
        .to_string()
        .as_bytes(),
    );
    arguments["idempotency_key"] = json!(format!("mcp:{key}"));
    if call.name == "send_message_to_mission" {
        arguments["client_message_id"] = json!(Uuid::new_v5(&Uuid::NAMESPACE_OID, key.as_bytes()));
    }
    super::execute(
        state,
        p,
        format!("http://127.0.0.1:{}", state.config.port),
        token,
        p.mission_id,
        &tool,
        arguments,
    )
    .await
    .map_err(|error| ToolError {
        code: "execution_failed".into(),
        message: format!(
            "Outcome unconfirmed; inspect before retrying. {}",
            super::assistant::safe_diagnostic(&error)
        ),
        accepted: "unknown".into(),
        retryable: false,
        action_id: None,
    })
}

pub(crate) fn issue_session(state: &AppState, p: &Principal) -> Result<Value, String> {
    let token = jsonwebtoken::encode(
        &jsonwebtoken::Header::default(),
        p,
        &jsonwebtoken::EncodingKey::from_secret(key(state)?.as_bytes()),
    )
    .map_err(|_| "Cannot issue MCP session")?;
    state.projects.connection.lock().map_err(|_|"Session store unavailable")?.execute("INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at) VALUES(?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET expires_at=excluded.expires_at WHERE revoked=0",rusqlite::params![p.session_id.to_string(),p.sub,p.mission_id.map(|id|id.to_string()),p.exp as i64]).map_err(|_|"Session store unavailable")?;
    Ok(
        json!({"token":format!("mcp1.{token}"),"expires_at":p.exp,"session_id":p.session_id,"contract_version":CONTRACT_VERSION}),
    )
}
/// Renewal preserves exactly the signed identity and privileges. A retired
/// mission cannot extend a credential; its trusted launcher must establish a
/// fresh session after a legitimate resume.
pub async fn renew(
    State(state): State<Arc<AppState>>,
    Extension(mut p): Extension<Principal>,
) -> Result<Json<Value>, (axum::http::StatusCode, String)> {
    use axum::http::StatusCode;
    if let Some(id) = p.mission_id {
        let user = AuthUser {
            id: p.sub.clone(),
            username: p.username.clone(),
        };
        let mission = state
            .control
            .get_or_spawn(&user)
            .await
            .mission_store
            .get_mission(id)
            .await
            .map_err(|_| {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Mission lookup failed".into(),
                )
            })?
            .ok_or_else(|| (StatusCode::FORBIDDEN, "Mission no longer exists".into()))?;
        if !matches!(
            mission.status.to_string().as_str(),
            "active" | "pending" | "waiting_background"
        ) {
            return Err((
                StatusCode::FORBIDDEN,
                "Mission is not running; reconnect through its launcher".into(),
            ));
        }
    }
    p.exp = (chrono::Utc::now() + chrono::Duration::hours(1)).timestamp() as usize;
    issue_session(&state, &p)
        .map(Json)
        .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, e))
}
pub async fn revoke(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    axum::extract::Path(id): axum::extract::Path<Uuid>,
) -> Result<Json<Value>, (axum::http::StatusCode, String)> {
    state
        .projects
        .connection
        .lock()
        .map_err(|_| {
            (
                axum::http::StatusCode::SERVICE_UNAVAILABLE,
                "Session store unavailable".into(),
            )
        })?
        .execute(
            "UPDATE mcp_sessions_v1 SET revoked=1 WHERE id=?1 AND owner=?2",
            rusqlite::params![id.to_string(), user.id],
        )
        .map_err(|_| {
            (
                axum::http::StatusCode::SERVICE_UNAVAILABLE,
                "Session store unavailable".into(),
            )
        })?;
    Ok(Json(json!({"revoked":true})))
}

#[cfg(test)]
mod managed_owner_tests {
    use super::lineage_related;
    use uuid::Uuid;

    #[test]
    fn only_owner_lineage_may_act_on_a_machine() {
        let (root, child, grandchild, other) = (
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
        );
        // chains are self-first, then ancestors
        let root_c = vec![root];
        let child_c = vec![child, root];
        let gc_c = vec![grandchild, child, root];
        let other_c = vec![other];
        let sibling = Uuid::new_v4();
        let sibling_c = vec![sibling, root];
        assert!(lineage_related(&child_c, &child_c)); // owner itself
        assert!(lineage_related(&root_c, &child_c)); // ancestor of owner
        assert!(lineage_related(&gc_c, &child_c)); // descendant of owner
        assert!(!lineage_related(&other_c, &child_c)); // unrelated
        assert!(!lineage_related(&sibling_c, &child_c)); // sibling is not lineage
        assert!(!lineage_related(&[], &child_c));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn launch_rejections_name_the_exact_fix() {
        assert!(launches_child("start_mission") && launches_child("consult_model"));
    }

    #[test]
    fn dispatch_recheck_keeps_parent_node_and_workspace_in_scope() {
        // Acceptance stored workspace_id=<own> + remote_node_id=<parent node>;
        // dispatch must accept those same arguments (consult_model quorum on a
        // remotely placed mission was rejected here).
        assert!(workspace_in_scope(true, true, Some("ashur"), Some("ashur")));
        assert!(workspace_in_scope(true, false, None, None));
        // Another node, the fleet scheduler, or another workspace stay denied.
        assert!(!workspace_in_scope(
            true,
            true,
            Some("babylon"),
            Some("ashur")
        ));
        assert!(!workspace_in_scope(true, true, Some("auto"), Some("ashur")));
        assert!(!workspace_in_scope(true, true, Some("ashur"), None));
        assert!(!workspace_in_scope(
            true,
            true,
            Some("unknown"),
            Some("unknown")
        ));
        assert!(!workspace_in_scope(false, false, None, None));
        assert!(!workspace_in_scope(
            false,
            true,
            Some("ashur"),
            Some("ashur")
        ));
        assert!(!launches_child("send_message_to_mission"));
        let mismatch = project_mismatch_message("other", Some("verity"));
        assert!(
            mismatch.contains("Use the parent's project: verity"),
            "{mismatch}"
        );
        assert!(project_mismatch_message("other", None).contains("Omit project"));
        let cloud = cloud_launch_field_message("remote_node_id");
        assert!(cloud.contains("got `remote_node_id`"), "{cloud}");
        assert!(cloud.contains("backend=opencode"), "{cloud}");
    }
    #[test]
    fn btw_side_agent_reads_only_its_parent_and_cannot_mint_the_tag() {
        let parent = Uuid::new_v4();
        let tags = vec![format!("btw-parent:{parent}")];
        assert!(btw_parent_read_allowed("get_mission_events", &tags, parent));
        assert!(btw_parent_read_allowed("get_mission", &tags, parent));
        assert!(!btw_parent_read_allowed(
            "send_message_to_mission",
            &tags,
            parent
        ));
        assert!(!btw_parent_read_allowed("cancel_mission", &tags, parent));
        assert!(!btw_parent_read_allowed(
            "get_mission_events",
            &tags,
            Uuid::new_v4()
        ));
        assert!(!btw_parent_read_allowed("get_mission_events", &[], parent));
        assert!(sets_reserved_btw_tag(
            &json!({"tags": ["x", format!("btw-parent:{parent}")]})
        ));
        assert!(!sets_reserved_btw_tag(
            &json!({"tags": ["btw", "project:x"]})
        ));
        assert!(!sets_reserved_btw_tag(&json!({"title": "no tags"})));
    }
    #[test]
    fn core_enforces_eight_calls_even_when_stdio_is_bypassed() {
        let id = Uuid::new_v4();
        let mut permits = (0..8)
            .map(|_| claim_call_slot(id).unwrap())
            .collect::<Vec<_>>();
        let error = claim_call_slot(id).unwrap_err();
        assert_eq!(error.code, "busy");
        assert_eq!(error.accepted, "no");
        assert!(claim_call_slot(Uuid::new_v4()).is_ok());
        permits.pop();
        assert!(claim_call_slot(id).is_ok());
    }
}

#[cfg(test)]
mod managed_ancestor_tests {
    use uuid::Uuid;

    #[test]
    fn a_child_never_takes_over_its_ancestors_vm() {
        let (parent, child) = (Uuid::new_v4(), Uuid::new_v4());
        let chain = vec![child, parent];
        assert!(super::owner_is_ancestor(&chain, Some(parent)));
        assert!(super::owner_is_ancestor(&chain, Some(child)));
        assert!(!super::owner_is_ancestor(&chain, Some(Uuid::new_v4())));
        assert!(!super::owner_is_ancestor(&chain, None));
    }
}
