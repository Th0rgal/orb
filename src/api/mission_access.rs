//! Mission access requests: a mission asks to read another mission it did not
//! start and that is not in its tree.
//!
//! `request_mission_access` opens a pending request; Thomas approves it on an
//! enrolled device (Touch ID / Face ID signature, always required, see
//! [`super::approvals::always_signed`]). An approved request is the grant: it
//! lets the requester call the read-only tools in [`READ_TOOLS`] on the
//! target until it expires (default 24 h) or is revoked. A grant never
//! allows control (messages, cancel, resume, placement): the gateway only
//! consults it for [`READ_TOOLS`].
//!
//! Requests carry the owner (the MCP session's / dashboard user's id); every
//! lookup is filtered by owner, so a grant never crosses tenants and only the
//! owner of the target mission can decide it. State follows the shared
//! [`ApprovalState`] machine. Requests and the audit log persist in
//! `<working_dir>/.sandboxed-sh/mission_access.json`.

use std::path::PathBuf;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use axum::{
    extract::{Path as AxumPath, State},
    http::StatusCode,
    routing::{delete, get, post},
    Extension, Json, Router,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::Mutex;
use uuid::Uuid;

use super::approval_flow::{self, ApprovalEvent, ApprovalState};
use super::auth::AuthUser;
use super::routes::AppState;

/// Default lifetime of an approved grant.
pub const DEFAULT_TTL_HOURS: i64 = 24;
/// Longest grant Thomas can give.
pub const MAX_TTL_HOURS: i64 = 24 * 7;
/// An unanswered request is denied by timeout after this long.
const PENDING_TTL_HOURS: i64 = 12;
/// How long the tool call waits for a decision before returning `pending`.
/// Stays under the MCP client's 30 s HTTP timeout.
const APPROVAL_WAIT: Duration = Duration::from_secs(20);
/// Pending requests one mission may have open at once.
const MAX_PENDING_PER_MISSION: usize = 5;
const AUDIT_LIMIT: usize = 2000;
const HISTORY_LIMIT: usize = 500;

/// The only tools a grant opens. All read-only: mission record, events
/// (messages), health, shared file listing.
pub const READ_TOOLS: &[&str] = &[
    "get_mission",
    "get_mission_events",
    "get_mission_health",
    "list_mission_shared_files",
];

pub const TOOL_NAMES: [&str; 2] = ["request_mission_access", "list_mission_access"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccessScope {
    Read,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccessRequest {
    pub id: Uuid,
    /// Tenant: user id owning both missions. Never shown to other users.
    pub owner: String,
    #[serde(default)]
    pub owner_username: String,
    pub requester_mission_id: Uuid,
    #[serde(default)]
    pub requester_title: Option<String>,
    pub target_mission_id: Uuid,
    #[serde(default)]
    pub target_title: Option<String>,
    pub scope: AccessScope,
    pub reason: String,
    /// Lifetime the mission asked for; Thomas may change it when approving.
    pub ttl_hours: i64,
    pub state: ApprovalState,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub decided_at: Option<DateTime<Utc>>,
    /// End of the grant (set on approval).
    #[serde(default)]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub revoked_at: Option<DateTime<Utc>>,
}

impl AccessRequest {
    fn live_grant(&self, now: DateTime<Utc>) -> bool {
        self.state == ApprovalState::Approved && self.expires_at.is_some_and(|t| t > now)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEntry {
    pub at: DateTime<Utc>,
    pub owner: String,
    pub request_id: Uuid,
    pub requester_mission_id: Uuid,
    pub target_mission_id: Uuid,
    /// `requested`, `approved`, `denied`, `expired`, `revoked`, or `read`.
    pub action: String,
    /// Tool name for reads, lifetime for approvals.
    #[serde(default)]
    pub detail: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Persisted {
    #[serde(default)]
    requests: Vec<AccessRequest>,
    #[serde(default)]
    audit: Vec<AuditEntry>,
}

impl Persisted {
    fn log(&mut self, r: &AccessRequest, action: &str, detail: Option<String>, at: DateTime<Utc>) {
        self.audit.push(AuditEntry {
            at,
            owner: r.owner.clone(),
            request_id: r.id,
            requester_mission_id: r.requester_mission_id,
            target_mission_id: r.target_mission_id,
            action: action.into(),
            detail,
        });
        let len = self.audit.len();
        if len > AUDIT_LIMIT {
            self.audit.drain(..len - AUDIT_LIMIT);
        }
    }

    /// Deny unanswered requests by timeout, expire grants that ran out.
    /// Returns whether anything changed.
    fn prune(&mut self, now: DateTime<Utc>) -> bool {
        let mut changed = Vec::new();
        for r in self.requests.iter_mut() {
            let ran_out = match r.state {
                ApprovalState::Pending => approval_flow::pending_timed_out(
                    r.created_at,
                    now,
                    chrono::Duration::hours(PENDING_TTL_HOURS),
                ),
                ApprovalState::Approved => r.expires_at.is_none_or(|t| t <= now),
                _ => false,
            };
            if ran_out {
                if let Ok(next) = r.state.apply(ApprovalEvent::Expire) {
                    if r.state.is_pending() {
                        r.decided_at = Some(now);
                    }
                    r.state = next;
                    changed.push(r.clone());
                }
            }
        }
        for r in &changed {
            self.log(r, "expired", None, now);
        }
        let finished = self
            .requests
            .iter()
            .filter(|r| !r.state.is_pending() && r.state != ApprovalState::Approved)
            .count();
        if finished > HISTORY_LIMIT {
            let mut drop = finished - HISTORY_LIMIT;
            self.requests.retain(|r| {
                let old = !r.state.is_pending() && r.state != ApprovalState::Approved;
                if old && drop > 0 {
                    drop -= 1;
                    false
                } else {
                    true
                }
            });
        }
        !changed.is_empty()
    }
}

pub struct MissionAccess {
    path: PathBuf,
    data: Mutex<Persisted>,
    changed: tokio::sync::Notify,
}

static STORE: OnceLock<Arc<MissionAccess>> = OnceLock::new();

pub fn store(state: &AppState) -> Arc<MissionAccess> {
    STORE
        .get_or_init(|| {
            Arc::new(MissionAccess::open(
                state
                    .config
                    .working_dir
                    .join(".sandboxed-sh")
                    .join("mission_access.json"),
            ))
        })
        .clone()
}

/// What a new request needs to know about the two missions.
#[derive(Debug, Clone)]
pub struct NewRequest {
    pub owner: String,
    pub owner_username: String,
    pub requester: Uuid,
    pub requester_title: Option<String>,
    pub target: Uuid,
    pub target_title: Option<String>,
    pub reason: String,
    pub ttl_hours: Option<i64>,
}

fn clamp_ttl(ttl: Option<i64>) -> i64 {
    ttl.unwrap_or(DEFAULT_TTL_HOURS).clamp(1, MAX_TTL_HOURS)
}

impl MissionAccess {
    pub fn open(path: PathBuf) -> Self {
        let data = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        Self {
            path,
            data: Mutex::new(data),
            changed: tokio::sync::Notify::new(),
        }
    }

    /// Best-effort save (pruning, audit of reads).
    async fn save(&self, data: &Persisted) {
        if let Err(e) = approval_flow::persist_private(&self.path, data).await {
            tracing::warn!("mission access state not saved: {e}");
        }
    }

    /// Save that must succeed: a decision is only reported once it is on disk.
    async fn commit(&self, data: &Persisted) -> Result<(), String> {
        approval_flow::persist_private(&self.path, data)
            .await
            .map_err(|e| format!("Could not save the decision ({e}); nothing changed"))
    }

    /// Open a request, or return the pending request / live grant that
    /// already covers it.
    pub async fn request(&self, new: NewRequest) -> Result<AccessRequest, String> {
        if new.requester == new.target {
            return Err("A mission can already read itself".into());
        }
        let now = Utc::now();
        let mut data = self.data.lock().await;
        let pruned = data.prune(now);
        if let Some(existing) = data.requests.iter().rev().find(|r| {
            r.owner == new.owner
                && r.requester_mission_id == new.requester
                && r.target_mission_id == new.target
                && (r.state.is_pending() || r.live_grant(now))
        }) {
            let out = existing.clone();
            if pruned {
                self.save(&data).await;
            }
            return Ok(out);
        }
        let open = data
            .requests
            .iter()
            .filter(|r| r.owner == new.owner && r.requester_mission_id == new.requester)
            .filter(|r| r.state.is_pending())
            .count();
        if open >= MAX_PENDING_PER_MISSION {
            return Err(format!(
                "This mission already has {open} pending access requests; wait for Thomas to answer them"
            ));
        }
        let r = AccessRequest {
            id: Uuid::new_v4(),
            owner: new.owner,
            owner_username: new.owner_username,
            requester_mission_id: new.requester,
            requester_title: new.requester_title,
            target_mission_id: new.target,
            target_title: new.target_title,
            scope: AccessScope::Read,
            reason: new.reason,
            ttl_hours: clamp_ttl(new.ttl_hours),
            state: ApprovalState::Pending,
            created_at: now,
            decided_at: None,
            expires_at: None,
            revoked_at: None,
        };
        data.requests.push(r.clone());
        data.log(&r, "requested", None, now);
        if let Err(e) = self.commit(&data).await {
            data.requests.pop();
            data.audit.pop();
            return Err(e);
        }
        drop(data);
        self.changed.notify_waiters();
        Ok(r)
    }

    /// Owner-scoped lookup. Another tenant's request reads as not found.
    pub async fn get(&self, owner: &str, id: Uuid) -> Option<AccessRequest> {
        let mut data = self.data.lock().await;
        if data.prune(Utc::now()) {
            self.save(&data).await;
        }
        data.requests
            .iter()
            .find(|r| r.id == id && r.owner == owner)
            .cloned()
    }

    async fn transition(
        &self,
        owner: &str,
        id: Uuid,
        event: ApprovalEvent,
        ttl_hours: Option<i64>,
    ) -> Result<AccessRequest, String> {
        let now = Utc::now();
        let mut data = self.data.lock().await;
        data.prune(now);
        let idx = data
            .requests
            .iter()
            .position(|r| r.id == id && r.owner == owner)
            .ok_or("Request not found")?;
        let before = data.requests[idx].clone();
        let r = &mut data.requests[idx];
        let next = r.state.apply(event)?;
        let detail = match event {
            ApprovalEvent::Approve => {
                let ttl = clamp_ttl(ttl_hours.or(Some(r.ttl_hours)));
                r.ttl_hours = ttl;
                r.expires_at = Some(now + chrono::Duration::hours(ttl));
                r.decided_at = Some(now);
                Some(format!("{ttl}h"))
            }
            ApprovalEvent::Deny => {
                r.decided_at = Some(now);
                None
            }
            ApprovalEvent::Revoke => {
                r.revoked_at = Some(now);
                None
            }
            ApprovalEvent::Expire => None,
        };
        r.state = next;
        let out = r.clone();
        let action = match event {
            ApprovalEvent::Approve => "approved",
            ApprovalEvent::Deny => "denied",
            ApprovalEvent::Revoke => "revoked",
            ApprovalEvent::Expire => "expired",
        };
        data.log(&out, action, detail, now);
        if let Err(e) = self.commit(&data).await {
            // Roll back: memory must match disk, or a restart would undo a
            // revoke (or resurrect a denied request).
            data.requests[idx] = before;
            data.audit.pop();
            return Err(e);
        }
        drop(data);
        self.changed.notify_waiters();
        Ok(out)
    }

    pub async fn approve(
        &self,
        owner: &str,
        id: Uuid,
        ttl_hours: Option<i64>,
    ) -> Result<AccessRequest, String> {
        self.transition(owner, id, ApprovalEvent::Approve, ttl_hours)
            .await
    }

    pub async fn deny(&self, owner: &str, id: Uuid) -> Result<AccessRequest, String> {
        self.transition(owner, id, ApprovalEvent::Deny, None).await
    }

    pub async fn revoke(&self, owner: &str, id: Uuid) -> Result<AccessRequest, String> {
        self.transition(owner, id, ApprovalEvent::Revoke, None)
            .await
    }

    /// The live read grant of `requester` on `target`, if any.
    pub async fn read_grant(&self, owner: &str, requester: Uuid, target: Uuid) -> Option<Uuid> {
        let now = Utc::now();
        let data = self.data.lock().await;
        data.requests
            .iter()
            .find(|r| {
                r.owner == owner
                    && r.requester_mission_id == requester
                    && r.target_mission_id == target
                    && r.scope == AccessScope::Read
                    && r.live_grant(now)
            })
            .map(|r| r.id)
    }

    /// The grant that lets `requester` call `tool` on `target`: only the
    /// read-only [`READ_TOOLS`] ever consult a grant.
    pub async fn grant_for_tool(
        &self,
        owner: &str,
        requester: Uuid,
        target: Uuid,
        tool: &str,
    ) -> Option<Uuid> {
        if !READ_TOOLS.contains(&tool) {
            return None;
        }
        self.read_grant(owner, requester, target).await
    }

    /// Audit one read made through a grant.
    pub async fn record_read(&self, owner: &str, grant: Uuid, tool: &str) {
        let now = Utc::now();
        let mut data = self.data.lock().await;
        let Some(r) = data
            .requests
            .iter()
            .find(|r| r.id == grant && r.owner == owner)
            .cloned()
        else {
            return;
        };
        data.log(&r, "read", Some(tool.to_string()), now);
        self.save(&data).await;
    }

    /// Wait up to `wait` for a decision on the request.
    pub async fn wait_decided(
        &self,
        owner: &str,
        id: Uuid,
        wait: Duration,
    ) -> Option<AccessRequest> {
        approval_flow::wait_settled(&self.changed, wait, move || async move {
            self.get(owner, id).await.map(|r| r.state)
        })
        .await?;
        self.get(owner, id).await
    }

    /// Owner's requests (newest first) and audit log.
    pub async fn snapshot(&self, owner: &str) -> Value {
        let mut data = self.data.lock().await;
        if data.prune(Utc::now()) {
            self.save(&data).await;
        }
        let requests: Vec<&AccessRequest> = data
            .requests
            .iter()
            .rev()
            .filter(|r| r.owner == owner)
            .take(200)
            .collect();
        let audit: Vec<&AuditEntry> = data
            .audit
            .iter()
            .rev()
            .filter(|a| a.owner == owner)
            .take(300)
            .collect();
        json!({ "requests": requests, "audit": audit })
    }

    /// Requests made by one mission (for `list_mission_access`).
    pub async fn by_requester(&self, owner: &str, requester: Uuid) -> Vec<AccessRequest> {
        let mut data = self.data.lock().await;
        if data.prune(Utc::now()) {
            self.save(&data).await;
        }
        data.requests
            .iter()
            .rev()
            .filter(|r| r.owner == owner && r.requester_mission_id == requester)
            .take(50)
            .cloned()
            .collect()
    }
}

/// What the requesting agent sees. Nothing from the target mission (title,
/// project, status, even whether it exists) until a live grant exists; only
/// Thomas's approval card shows the target title.
fn agent_view(r: &AccessRequest) -> Value {
    let live = r.live_grant(Utc::now());
    json!({
        "request_id": r.id,
        "target_mission_id": r.target_mission_id,
        "target_title": if live { json!(r.target_title) } else { Value::Null },
        "scope": r.scope,
        "status": r.state,
        "reason": r.reason,
        "created_at": r.created_at,
        "expires_at": r.expires_at,
        "allowed_tools": if live { json!(READ_TOOLS) } else { json!([]) },
    })
}

fn decision_note(r: &AccessRequest) -> String {
    match r.state {
        ApprovalState::Approved => format!(
            "Approved: you may read mission {} with {} until {}. Read only: messages, cancel, resume and placement stay denied.",
            r.target_mission_id,
            READ_TOOLS.join(", "),
            r.expires_at.map(|t| t.to_rfc3339()).unwrap_or_default()
        ),
        ApprovalState::Pending => format!(
            "Waiting for Thomas to approve on his device. You will get a message when he decides; or call list_mission_access later (request {}). Pending requests are denied after {PENDING_TTL_HOURS} h.",
            r.id
        ),
        ApprovalState::Denied => "Thomas declined this request. Do not ask again for the same reason.".into(),
        ApprovalState::Expired => "The request or grant expired. Ask again if you still need it.".into(),
        ApprovalState::Revoked => "Thomas revoked this grant.".into(),
    }
}

/// Error text the gateway returns when a mission reads outside its scope.
pub fn scope_hint(tool: &str, target: Uuid) -> String {
    if READ_TOOLS.contains(&tool) {
        format!(
            "Mission is outside this session's scope. To read it, ask Thomas with \
             request_mission_access(target_mission_id=\"{target}\", reason=\"why you need it\"); \
             once approved, {} work on it (read-only).",
            READ_TOOLS.join(", ")
        )
    } else {
        "Mission is outside this session's scope. Access grants (request_mission_access) are \
         read-only and never allow messages, cancel, resume or placement on another mission."
            .to_string()
    }
}

/// Entry point for the access MCP tools.
pub async fn handle_tool(
    state: &Arc<AppState>,
    p: &crate::control_mcp::gateway::Principal,
    name: &str,
    args: &Value,
) -> Result<Value, String> {
    let own = p
        .mission_id
        .ok_or("Mission access is only available to mission-scoped sessions")?;
    let access = store(state);
    match name {
        "list_mission_access" => {
            let list = access.by_requester(&p.sub, own).await;
            Ok(json!({ "requests": list.iter().map(agent_view).collect::<Vec<_>>() }))
        }
        "request_mission_access" => {
            let target = args
                .get("target_mission_id")
                .and_then(Value::as_str)
                .and_then(|s| Uuid::parse_str(s.trim()).ok())
                .ok_or("target_mission_id must be a full mission UUID")?;
            match args.get("scope").and_then(Value::as_str).unwrap_or("read") {
                "read" => {}
                _ => {
                    return Err(
                        "Only scope=\"read\" exists; control of another mission is never granted"
                            .into(),
                    )
                }
            }
            let reason = args
                .get("reason")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or("reason is required; it is shown to Thomas")?
                .chars()
                .take(500)
                .collect::<String>();
            let user = AuthUser {
                id: p.sub.clone(),
                username: p.username.clone(),
            };
            // The mission store is per user: another tenant's mission is not found.
            let missions = state.control.get_or_spawn(&user).await.mission_store;
            // A missing target gets the same pending reply as an existing one,
            // so the tool cannot probe which missions exist. Such a request can
            // never be approved (the approver must own the target) and times out.
            let target_mission = missions.get_mission(target).await.ok().flatten();
            let requester = missions
                .get_mission(own)
                .await
                .ok()
                .flatten()
                .ok_or("Mission no longer exists")?;
            if target == own
                || target_mission
                    .as_ref()
                    .is_some_and(|m| m.parent_mission_id == Some(own))
            {
                return Ok(
                    json!({"status":"already_in_scope","message":"This mission is already in your scope; read it directly."}),
                );
            }
            let r = access
                .request(NewRequest {
                    owner: p.sub.clone(),
                    owner_username: p.username.clone(),
                    requester: own,
                    requester_title: requester.title,
                    target,
                    target_title: target_mission.and_then(|m| m.title),
                    reason,
                    ttl_hours: args.get("ttl_hours").and_then(Value::as_i64),
                })
                .await?;
            let r = if r.state.is_pending() {
                access
                    .wait_decided(&p.sub, r.id, APPROVAL_WAIT)
                    .await
                    .unwrap_or(r)
            } else {
                r
            };
            let mut out = agent_view(&r);
            out["message"] = json!(decision_note(&r));
            Ok(out)
        }
        _ => Err("Unknown tool".into()),
    }
}

pub fn tool_definitions() -> Vec<crate::control_mcp::ToolDefinition> {
    use crate::control_mcp::ToolDefinition;
    vec![
        ToolDefinition {
            name: "request_mission_access".into(),
            description: "Ask Thomas for read-only access to another mission that you did not start and that is not in your tree \
                          (when get_mission / get_mission_events answer \"outside this session's scope\"). He approves on his device \
                          with Touch ID / Face ID. Waits up to 20 s, then returns `pending`; you get a message when he decides, \
                          or call list_mission_access. Once approved (default 24 h), get_mission, get_mission_events, \
                          get_mission_health and list_mission_shared_files work on that mission. Never grants control: \
                          sending messages, cancel, resume and placement stay denied."
                .into(),
            input_schema: json!({"type":"object","required":["target_mission_id","reason"],"properties":{
                "target_mission_id":{"type":"string","format":"uuid","description":"Full UUID of the mission to read."},
                "scope":{"type":"string","enum":["read"],"default":"read"},
                "reason":{"type":"string","minLength":1,"maxLength":500,"description":"Why you need it; shown to Thomas."},
                "ttl_hours":{"type":"integer","minimum":1,"maximum":MAX_TTL_HOURS,"description":"How long you need it (default 24)."}
            },"additionalProperties":false}),
        },
        ToolDefinition {
            name: "list_mission_access".into(),
            description: "List this mission's access requests to other missions and their status (pending, approved with expiry, denied, expired, revoked)."
                .into(),
            input_schema: json!({"type":"object","properties":{},"additionalProperties":false}),
        },
    ]
}

/// Wake the requesting mission with the decision (best effort).
async fn notify_requester(state: &Arc<AppState>, r: &AccessRequest) {
    use crate::api::control::{ControlCommand, MissionStatus};
    let user = AuthUser {
        id: r.owner.clone(),
        username: r.owner_username.clone(),
    };
    let control = state.control.get_or_spawn(&user).await;
    let Ok(Some(m)) = control
        .mission_store
        .get_mission(r.requester_mission_id)
        .await
    else {
        return;
    };
    // Never revive a finished mission just to tell it.
    if !matches!(
        m.status,
        MissionStatus::Active
            | MissionStatus::AwaitingUser
            | MissionStatus::Pending
            | MissionStatus::WaitingBackground
    ) {
        return;
    }
    let content = format!(
        "[mission-access] Request {} to read mission {} ({}): {}",
        r.id,
        r.target_mission_id,
        r.state_label(),
        decision_note(r)
    );
    let (tx, _rx) = tokio::sync::oneshot::channel();
    let _ = control
        .cmd_tx
        .send(ControlCommand::UserMessage {
            id: Uuid::new_v4(),
            content,
            agent: None,
            target_mission_id: Some(r.requester_mission_id),
            strict: false,
            source: Some("mission-access".to_string()),
            respond: tx,
        })
        .await;
}

impl AccessRequest {
    fn state_label(&self) -> &'static str {
        match self.state {
            ApprovalState::Pending => "pending",
            ApprovalState::Approved => "approved",
            ApprovalState::Denied => "denied",
            ApprovalState::Expired => "expired",
            ApprovalState::Revoked => "revoked",
        }
    }
}

// ---------------------------------------------------------------- HTTP

type ApiError = (StatusCode, String);

/// `/api/mission-access`. Approve needs a device signature (enforced by
/// [`super::approvals::require_device_approval`]); every route is owner-scoped.
pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/", get(list))
        .route("/:id/approve", post(approve))
        .route("/:id/deny", post(deny))
        .route("/:id", delete(revoke))
}

fn parse_id(raw: &str) -> Result<Uuid, ApiError> {
    Uuid::parse_str(raw.trim()).map_err(|_| (StatusCode::BAD_REQUEST, "Invalid id".into()))
}

async fn list(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Json<Value> {
    Json(store(&state).snapshot(&user.id).await)
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApproveBody {
    #[serde(default)]
    pub ttl_hours: Option<i64>,
}

async fn approve(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    AxumPath(id): AxumPath<String>,
    Json(body): Json<ApproveBody>,
) -> Result<Json<AccessRequest>, ApiError> {
    let id = parse_id(&id)?;
    let access = store(&state);
    let pending = access
        .get(&user.id, id)
        .await
        .ok_or((StatusCode::NOT_FOUND, "Request not found".to_string()))?;
    // Only the owner of the target mission decides: it must still exist in
    // the approver's own mission store.
    let missions = state.control.get_or_spawn(&user).await.mission_store;
    if !matches!(
        missions.get_mission(pending.target_mission_id).await,
        Ok(Some(_))
    ) {
        return Err((
            StatusCode::FORBIDDEN,
            "You do not own the target mission".into(),
        ));
    }
    let r = access
        .approve(&user.id, id, body.ttl_hours)
        .await
        .map_err(|e| (StatusCode::CONFLICT, e))?;
    notify_requester(&state, &r).await;
    Ok(Json(r))
}

async fn deny(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    AxumPath(id): AxumPath<String>,
) -> Result<Json<AccessRequest>, ApiError> {
    let id = parse_id(&id)?;
    let r = store(&state)
        .deny(&user.id, id)
        .await
        .map_err(|e| (StatusCode::CONFLICT, e))?;
    notify_requester(&state, &r).await;
    Ok(Json(r))
}

async fn revoke(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    AxumPath(id): AxumPath<String>,
) -> Result<Json<AccessRequest>, ApiError> {
    let id = parse_id(&id)?;
    store(&state)
        .revoke(&user.id, id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::CONFLICT, e))
}

/// One-line description for the device approval prompt.
pub async fn describe_for_approval(
    state: &Arc<AppState>,
    owner: &str,
    id: &str,
    action: &str,
    ttl: Option<i64>,
) -> Result<String, String> {
    let id = Uuid::parse_str(id).map_err(|_| "Unknown request")?;
    let r = store(state).get(owner, id).await.ok_or("Unknown request")?;
    let who = r
        .requester_title
        .clone()
        .unwrap_or_else(|| format!("mission {}", &r.requester_mission_id.to_string()[..8]));
    let target = r
        .target_title
        .clone()
        .unwrap_or_else(|| format!("mission {}", &r.target_mission_id.to_string()[..8]));
    Ok(match action {
        "approve" => format!(
            "Let {} READ (not control) {} for {} h",
            super::approvals::quoted(&who),
            super::approvals::quoted(&target),
            clamp_ttl(ttl.or(Some(r.ttl_hours)))
        ),
        _ => format!(
            "Decline: {} wants to read {}",
            super::approvals::quoted(&who),
            super::approvals::quoted(&target)
        ),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> MissionAccess {
        let dir = std::env::temp_dir().join(format!("mission-access-{}", Uuid::new_v4()));
        MissionAccess::open(dir.join("mission_access.json"))
    }

    fn new(owner: &str, requester: Uuid, target: Uuid) -> NewRequest {
        NewRequest {
            owner: owner.into(),
            owner_username: owner.into(),
            requester,
            requester_title: Some("requester".into()),
            target,
            target_title: Some("target".into()),
            reason: "compare results".into(),
            ttl_hours: None,
        }
    }

    #[tokio::test]
    async fn read_allowed_only_after_approval() {
        let s = temp();
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
        let r = s.request(new("thomas", a, b)).await.unwrap();
        assert_eq!(r.state, ApprovalState::Pending);
        assert_eq!(s.read_grant("thomas", a, b).await, None);
        // Asking again returns the same pending request.
        assert_eq!(s.request(new("thomas", a, b)).await.unwrap().id, r.id);
        let ok = s.approve("thomas", r.id, None).await.unwrap();
        assert_eq!(ok.state, ApprovalState::Approved);
        let left = ok.expires_at.unwrap() - Utc::now();
        assert!(left > chrono::Duration::hours(23) && left <= chrono::Duration::hours(24));
        assert_eq!(s.read_grant("thomas", a, b).await, Some(r.id));
        // A grant is directional.
        assert_eq!(s.read_grant("thomas", b, a).await, None);
        // Decided once only.
        assert!(s.approve("thomas", r.id, None).await.is_err());
        assert!(s.deny("thomas", r.id).await.is_err());
    }

    #[tokio::test]
    async fn an_approved_grant_never_allows_control() {
        let s = temp();
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
        let r = s.request(new("thomas", a, b)).await.unwrap();
        s.approve("thomas", r.id, None).await.unwrap();
        for tool in READ_TOOLS {
            assert_eq!(
                s.grant_for_tool("thomas", a, b, tool).await,
                Some(r.id),
                "{tool}"
            );
        }
        for tool in [
            "send_message_to_mission",
            "answer_mission_question",
            "cancel_mission",
            "resume_mission",
            "start_mission",
            "update_mission_settings",
            "start_workspace_job",
            "ask_mission",
        ] {
            assert_eq!(
                s.grant_for_tool("thomas", a, b, tool).await,
                None,
                "{tool} allowed"
            );
        }
    }

    #[tokio::test]
    async fn denied_and_revoked_grant_nothing() {
        let s = temp();
        let (a, b, c) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
        let r = s.request(new("thomas", a, b)).await.unwrap();
        s.deny("thomas", r.id).await.unwrap();
        assert_eq!(s.read_grant("thomas", a, b).await, None);
        // Revoking a pending request is refused (deny it instead).
        let r2 = s.request(new("thomas", a, c)).await.unwrap();
        assert!(s.revoke("thomas", r2.id).await.is_err());
        s.approve("thomas", r2.id, Some(1)).await.unwrap();
        assert!(s.read_grant("thomas", a, c).await.is_some());
        s.revoke("thomas", r2.id).await.unwrap();
        assert_eq!(s.read_grant("thomas", a, c).await, None);
        assert!(
            s.approve("thomas", r2.id, None).await.is_err(),
            "revoked never comes back"
        );
        let snap = s.snapshot("thomas").await;
        let actions: Vec<&str> = snap["audit"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|a| a["action"].as_str())
            .collect();
        for a in ["requested", "denied", "approved", "revoked"] {
            assert!(actions.contains(&a), "audit misses {a}: {actions:?}");
        }
    }

    #[tokio::test]
    async fn grants_and_pending_requests_expire() {
        let s = temp();
        let (a, b, c) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
        let r = s.request(new("thomas", a, b)).await.unwrap();
        s.approve("thomas", r.id, Some(1)).await.unwrap();
        let p = s.request(new("thomas", a, c)).await.unwrap();
        {
            let mut d = s.data.lock().await;
            for x in d.requests.iter_mut() {
                if x.id == r.id {
                    x.expires_at = Some(Utc::now() - chrono::Duration::seconds(1));
                }
                if x.id == p.id {
                    x.created_at = Utc::now() - chrono::Duration::hours(PENDING_TTL_HOURS + 1);
                }
            }
        }
        assert_eq!(
            s.read_grant("thomas", a, b).await,
            None,
            "expired grant still reads"
        );
        assert_eq!(
            s.get("thomas", r.id).await.unwrap().state,
            ApprovalState::Expired
        );
        // Unanswered request: denied by timeout, can no longer be approved.
        assert_eq!(
            s.get("thomas", p.id).await.unwrap().state,
            ApprovalState::Expired
        );
        assert!(s.approve("thomas", p.id, None).await.is_err());
    }

    #[tokio::test]
    async fn other_tenants_cannot_see_decide_or_use() {
        let s = temp();
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
        let r = s.request(new("thomas", a, b)).await.unwrap();
        assert!(s.get("mallory", r.id).await.is_none());
        assert!(s.approve("mallory", r.id, None).await.is_err());
        assert!(s.deny("mallory", r.id).await.is_err());
        s.approve("thomas", r.id, None).await.unwrap();
        assert!(s.revoke("mallory", r.id).await.is_err());
        assert_eq!(s.read_grant("mallory", a, b).await, None);
        assert_eq!(
            s.snapshot("mallory").await["requests"]
                .as_array()
                .unwrap()
                .len(),
            0
        );
    }

    #[tokio::test]
    async fn ttl_is_clamped_and_self_requests_refused() {
        let s = temp();
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
        assert!(s.request(new("thomas", a, a)).await.is_err());
        let r = s.request(new("thomas", a, b)).await.unwrap();
        let ok = s.approve("thomas", r.id, Some(10_000)).await.unwrap();
        assert_eq!(ok.ttl_hours, MAX_TTL_HOURS);
    }

    #[tokio::test]
    async fn pending_requests_per_mission_are_capped() {
        let s = temp();
        let a = Uuid::new_v4();
        for _ in 0..MAX_PENDING_PER_MISSION {
            s.request(new("thomas", a, Uuid::new_v4())).await.unwrap();
        }
        assert!(s.request(new("thomas", a, Uuid::new_v4())).await.is_err());
    }

    #[tokio::test]
    async fn state_survives_restart() {
        let dir = std::env::temp_dir().join(format!("mission-access-{}", Uuid::new_v4()));
        let path = dir.join("mission_access.json");
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
        let id = {
            let s = MissionAccess::open(path.clone());
            let r = s.request(new("thomas", a, b)).await.unwrap();
            s.approve("thomas", r.id, None).await.unwrap();
            r.id
        };
        let s = MissionAccess::open(path);
        assert_eq!(s.read_grant("thomas", a, b).await, Some(id));
    }

    #[tokio::test]
    async fn agent_sees_nothing_of_the_target_before_a_live_grant() {
        let s = temp();
        let (a, b, ghost) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
        let real = s.request(new("thomas", a, b)).await.unwrap();
        // A request for a mission that does not exist (no title known).
        let mut missing = new("thomas", a, ghost);
        missing.target_title = None;
        let missing = s.request(missing).await.unwrap();
        let (v1, v2) = (agent_view(&real), agent_view(&missing));
        assert!(v1["target_title"].is_null(), "pending view leaks the title");
        assert!(
            !v1.to_string().contains("target\""),
            "title text leaked: {v1}"
        );
        let keys = |v: &Value| v.as_object().unwrap().keys().cloned().collect::<Vec<_>>();
        assert_eq!(keys(&v1), keys(&v2));
        assert_eq!(v1["status"], v2["status"]);
        assert_eq!(v1["allowed_tools"], json!([]));
        // Denied: still nothing.
        let denied = s.deny("thomas", real.id).await.unwrap();
        assert!(agent_view(&denied)["target_title"].is_null());
        // Live grant: the title is visible.
        let r2 = s.request(new("thomas", a, Uuid::new_v4())).await.unwrap();
        let ok = s.approve("thomas", r2.id, None).await.unwrap();
        assert_eq!(agent_view(&ok)["target_title"], "target");
        // Revoked: hidden again.
        let gone = s.revoke("thomas", r2.id).await.unwrap();
        assert!(agent_view(&gone)["target_title"].is_null());
    }

    #[tokio::test]
    async fn a_revoke_that_cannot_be_saved_changes_nothing() {
        let dir = std::env::temp_dir().join(format!("mission-access-{}", Uuid::new_v4()));
        let path = dir.join("mission_access.json");
        let s = MissionAccess::open(path.clone());
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
        let r = s.request(new("thomas", a, b)).await.unwrap();
        s.approve("thomas", r.id, None).await.unwrap();
        // Make the state path unwritable: a directory where the temp file goes.
        std::fs::create_dir_all(path.with_extension("json.tmp")).unwrap();
        assert!(s.revoke("thomas", r.id).await.is_err());
        assert_eq!(
            s.read_grant("thomas", a, b).await,
            Some(r.id),
            "memory must match disk"
        );
        std::fs::remove_dir(path.with_extension("json.tmp")).unwrap();
        s.revoke("thomas", r.id).await.unwrap();
        // After a restart the revoke holds.
        assert_eq!(
            MissionAccess::open(path).read_grant("thomas", a, b).await,
            None
        );
    }

    #[test]
    fn scope_hint_points_reads_to_the_tool_and_refuses_control() {
        let t = Uuid::new_v4();
        assert!(scope_hint("get_mission_events", t).contains("request_mission_access"));
        assert!(scope_hint("cancel_mission", t).contains("never allow"));
        assert!(!READ_TOOLS.iter().any(|t| matches!(
            *t,
            "send_message_to_mission" | "cancel_mission" | "resume_mission" | "start_mission"
        )));
    }
}
