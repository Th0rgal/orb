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
    if args.get("parent_mission_id").is_some() {
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
                | "get_chatgpt_ui_pool_status"
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
                    return Err(ToolError::denied("Project is outside this session's scope"));
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
            "list_missions" | "list_active_missions" | "start_mission"
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
                    return Err(ToolError::denied(
                        "Mission is outside this session's project",
                    ));
                }
            }
        }
    }
    if tool.definition.name == "start_mission" && args.get("cloud").is_some_and(|v| !v.is_null()) {
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
                return Err(ToolError::invalid(
                    "Cloud launches must not include native placement or harness settings",
                ));
            }
        }
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
            if id != own && m.parent_mission_id != Some(own) {
                return Err(ToolError::denied("Mission is outside this session's scope"));
            }
            if tool.definition.name == "start_workspace_job" && m.workspace_id != owner.workspace_id
            {
                return Err(ToolError::denied(
                    "Job workspace is outside this session's scope",
                ));
            }
        }
    }
    if let Some(raw) = args.get("workspace_id") {
        if raw.as_str() != Some(owner.workspace_id.to_string().as_str()) {
            return Err(ToolError::denied(
                "Workspace is outside this session's scope",
            ));
        }
    }
    if tool.definition.name == "start_workspace_job"
        || (tool.definition.name == "start_mission" && args.get("cloud").is_none_or(Value::is_null))
    {
        args["workspace_id"] = json!(owner.workspace_id);
    }
    if tool.definition.name == "start_mission" && args.get("cloud").is_none_or(Value::is_null) {
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
        if let Some(requested) = args.get("remote_node_id").and_then(Value::as_str) {
            if Some(requested) != node {
                return Err(ToolError::denied(
                    "Native child must remain on its parent's machine",
                ));
            }
        }
        if let Some(node) = node {
            args["remote_node_id"] = json!(node);
        }
    }
    if tool.definition.name == "start_mission" {
        if let Some(project) = args.get("project").and_then(Value::as_str) {
            if owner.project.project.as_deref() != Some(project) {
                return Err(ToolError::denied(
                    "Child mission project must match its parent",
                ));
            }
        } else if let Some(project) = owner.project.project.as_deref() {
            args["project"] = json!(project);
        }
        if args.get("request_merge_authority").and_then(Value::as_bool) == Some(true) {
            return Err(ToolError::denied("Delegation cannot grant merge authority"));
        }
        args["parent_mission_id"] = json!(own);
    }
    Ok(())
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
mod tests {
    use super::*;
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
