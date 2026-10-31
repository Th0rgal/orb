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
use super::approval_queue::{self, ApprovalItem, BatchRef};
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
/// (messages), health, shared file listing, and cloud execution receipts.
pub const READ_TOOLS: &[&str] = &[
    "get_mission",
    "get_mission_events",
    "get_mission_health",
    "list_mission_shared_files",
    "get_cloud_execution",
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
    #[serde(default)]
    pub requester_mission_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requester: Option<approval_flow::RequesterSubject>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requester_label: Option<String>,
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
    pub fn subject(&self) -> approval_flow::RequesterSubject {
        self.requester.clone().unwrap_or_else(|| {
            approval_flow::RequesterSubject::mission(
                self.requester_mission_id.unwrap_or_else(Uuid::nil),
            )
        })
    }

    fn live_grant(&self, now: DateTime<Utc>) -> bool {
        self.state == ApprovalState::Approved && self.expires_at.is_some_and(|t| t > now)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEntry {
    pub at: DateTime<Utc>,
    pub owner: String,
    pub request_id: Uuid,
    #[serde(default)]
    pub requester_mission_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requester: Option<approval_flow::RequesterSubject>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requester_label: Option<String>,
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
            requester: r.requester.clone(),
            requester_label: r.requester_label.clone(),
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

/// What a new request needs to know about the requester and target mission.
#[derive(Debug, Clone)]
pub struct NewRequest {
    pub owner: String,
    pub owner_username: String,
    pub requester: approval_flow::RequesterSubject,
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
        if new.requester.mission_id() == Some(new.target) {
            return Err("A mission can already read itself".into());
        }
        let now = Utc::now();
        let mut data = self.data.lock().await;
        let pruned = data.prune(now);
        if let Some(existing) = data.requests.iter().rev().find(|r| {
            r.owner == new.owner
                && r.subject().same_actor(&new.requester)
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
            .filter(|r| r.owner == new.owner && r.subject().same_actor(&new.requester))
            .filter(|r| r.state.is_pending())
            .count();
        if open >= MAX_PENDING_PER_MISSION {
            return Err(format!(
                "This session already has {open} pending access requests; wait for Thomas to answer them"
            ));
        }
        let requester_mission_id = new.requester.mission_id();
        let requester_label = new.requester.external_display_label();
        let r = AccessRequest {
            id: Uuid::new_v4(),
            owner: new.owner,
            owner_username: new.owner_username,
            requester_mission_id,
            requester: Some(new.requester),
            requester_label,
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
        state: Option<&Arc<AppState>>,
    ) -> Result<AccessRequest, String> {
        let now = Utc::now();
        let hard_expires_at = if matches!(event, ApprovalEvent::Approve) {
            let session_id = {
                let data = self.data.lock().await;
                data.requests
                    .iter()
                    .find(|r| r.id == id && r.owner == owner)
                    .and_then(|r| r.subject().session_id())
            };
            match session_id {
                Some(sid) => {
                    let st = state.ok_or_else(|| {
                        "External session approval requires live AppState verification".to_string()
                    })?;
                    crate::control_mcp::gateway::external_session_approval_bounds(st, sid, now)
                        .await?
                }
                None => None,
            }
        } else {
            None
        };
        let mut data = self.data.lock().await;
        data.prune(now);
        let idx = data
            .requests
            .iter()
            .position(|r| r.id == id && r.owner == owner)
            .ok_or("Request not found")?;
        if matches!(event, ApprovalEvent::Approve)
            && data.requests[idx].subject().is_external()
            && state.is_none()
        {
            return Err("External session approval requires live AppState verification".into());
        }
        let before = data.requests[idx].clone();
        let r = &mut data.requests[idx];
        let next = r.state.apply(event)?;
        let detail = match event {
            ApprovalEvent::Approve => Some(grant(r, now, ttl_hours, hard_expires_at)),
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
        self.transition(owner, id, ApprovalEvent::Approve, ttl_hours, None)
            .await
    }

    pub async fn approve_with_state(
        &self,
        state: &Arc<AppState>,
        owner: &str,
        id: Uuid,
        ttl_hours: Option<i64>,
    ) -> Result<AccessRequest, String> {
        self.transition(owner, id, ApprovalEvent::Approve, ttl_hours, Some(state))
            .await
    }

    /// Pending requests of `owner` in the shared approval shape.
    pub async fn pending_items(&self, owner: &str) -> Vec<ApprovalItem> {
        let mut data = self.data.lock().await;
        if data.prune(Utc::now()) {
            self.save(&data).await;
        }
        data.requests
            .iter()
            .filter(|r| r.owner == owner && r.state.is_pending())
            .map(ApprovalItem::mission_access)
            .collect()
    }

    /// Approve the listed requests, all or none, each through
    /// [`approval_queue::admit`]. The caller checks that `owner` owns every
    /// target mission (as the single approve does).
    pub async fn approve_batch(
        &self,
        owner: &str,
        refs: &[BatchRef],
        confirm_critical: bool,
    ) -> Result<Vec<AccessRequest>, String> {
        self.approve_batch_inner(None, owner, refs, confirm_critical)
            .await
    }

    pub async fn approve_batch_with_state(
        &self,
        state: &Arc<AppState>,
        owner: &str,
        refs: &[BatchRef],
        confirm_critical: bool,
    ) -> Result<Vec<AccessRequest>, String> {
        self.approve_batch_inner(Some(state), owner, refs, confirm_critical)
            .await
    }

    async fn approve_batch_inner(
        &self,
        state: Option<&Arc<AppState>>,
        owner: &str,
        refs: &[BatchRef],
        confirm_critical: bool,
    ) -> Result<Vec<AccessRequest>, String> {
        if refs.is_empty() {
            return Ok(Vec::new());
        }
        let now = Utc::now();
        let session_ids: Vec<(Uuid, Option<Uuid>)> = {
            let data = self.data.lock().await;
            refs.iter()
                .map(|want| {
                    let sid = data
                        .requests
                        .iter()
                        .find(|r| r.id == want.id && r.owner == owner && r.state.is_pending())
                        .and_then(|r| r.subject().session_id());
                    (want.id, sid)
                })
                .collect()
        };
        let mut session_bounds = std::collections::HashMap::new();
        for (req_id, sid) in session_ids {
            if let Some(sid) = sid {
                let st = state.ok_or_else(|| {
                    "External session approval requires live AppState verification".to_string()
                })?;
                let hard =
                    crate::control_mcp::gateway::external_session_approval_bounds(st, sid, now)
                        .await?;
                session_bounds.insert(req_id, hard);
            }
        }
        let mut data = self.data.lock().await;
        data.prune(now);
        let mut idxs = Vec::with_capacity(refs.len());
        for want in refs {
            let idx = data
                .requests
                .iter()
                .position(|r| r.id == want.id && r.owner == owner && r.state.is_pending());
            let current = idx.map(|i| ApprovalItem::mission_access(&data.requests[i]));
            approval_queue::admit(current.as_ref(), want, confirm_critical)?;
            if let Some(i) = idx {
                if data.requests[i].subject().is_external()
                    && !session_bounds.contains_key(&want.id)
                {
                    return Err(
                        "External session approval requires live AppState verification".into(),
                    );
                }
            }
            idxs.extend(idx);
        }
        let before: Vec<AccessRequest> = idxs.iter().map(|&i| data.requests[i].clone()).collect();
        // The whole log, not its length: at the cap `log()` also drops the oldest entries.
        let audit_before = data.audit.clone();
        let mut out = Vec::with_capacity(idxs.len());
        for &idx in &idxs {
            let r = &mut data.requests[idx];
            r.state = r.state.apply(ApprovalEvent::Approve)?;
            let hard_expires_at = session_bounds.get(&r.id).copied().flatten();
            let detail = grant(r, now, None, hard_expires_at);
            let snapshot = r.clone();
            data.log(&snapshot, "approved", Some(detail), now);
            out.push(snapshot);
        }
        if let Err(e) = self.commit(&data).await {
            for (&idx, r) in idxs.iter().zip(before) {
                data.requests[idx] = r;
            }
            data.audit = audit_before;
            return Err(e);
        }
        drop(data);
        self.changed.notify_waiters();
        Ok(out)
    }

    pub async fn deny(&self, owner: &str, id: Uuid) -> Result<AccessRequest, String> {
        self.transition(owner, id, ApprovalEvent::Deny, None, None)
            .await
    }

    pub async fn revoke(&self, owner: &str, id: Uuid) -> Result<AccessRequest, String> {
        self.transition(owner, id, ApprovalEvent::Revoke, None, None)
            .await
    }

    /// The live read grant of `requester` on `target`, if any.
    pub async fn read_grant(
        &self,
        owner: &str,
        requester: &approval_flow::RequesterSubject,
        target: Uuid,
    ) -> Option<Uuid> {
        let now = Utc::now();
        let data = self.data.lock().await;
        data.requests
            .iter()
            .find(|r| {
                r.owner == owner
                    && r.subject().same_actor(requester)
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
        requester: &approval_flow::RequesterSubject,
        target: Uuid,
        tool: &str,
    ) -> Option<Uuid> {
        let is_read_tool = READ_TOOLS.contains(&tool);
        if !crate::orb_spec::access_step(crate::orb_spec::AccessStepInput {
            same_owner: true,
            is_self_or_child: false,
            is_read_tool,
            grant_approved: true,
            grant_unexpired: true,
            target_exists: true,
        })
        .allow_tool
        {
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
        let requests: Vec<Value> = data
            .requests
            .iter()
            .rev()
            .filter(|r| r.owner == owner)
            .take(200)
            .map(|r| {
                approval_queue::listed(json!(r), r.state.is_pending(), || {
                    ApprovalItem::mission_access(r)
                })
            })
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

    /// Requests made by one actor (for `list_mission_access`).
    pub async fn by_requester(
        &self,
        owner: &str,
        requester: &approval_flow::RequesterSubject,
    ) -> Vec<AccessRequest> {
        let mut data = self.data.lock().await;
        if data.prune(Utc::now()) {
            self.save(&data).await;
        }
        data.requests
            .iter()
            .rev()
            .filter(|r| r.owner == owner && r.subject().same_actor(requester))
            .take(50)
            .cloned()
            .collect()
    }

    /// Revoke active read grants and expire pending requests for an external MCP session.
    pub async fn revoke_session_grants(&self, owner: &str, session_id: Uuid) -> usize {
        let now = Utc::now();
        let mut data = self.data.lock().await;
        let mut touched = Vec::new();
        for r in data.requests.iter_mut() {
            if r.owner != owner || r.subject().session_id() != Some(session_id) {
                continue;
            }
            if r.state == ApprovalState::Approved && r.live_grant(now) {
                r.state = ApprovalState::Revoked;
                r.revoked_at = Some(now);
                touched.push((r.clone(), "revoked"));
            } else if r.state.is_pending() {
                r.state = ApprovalState::Expired;
                r.decided_at = Some(now);
                touched.push((r.clone(), "expired"));
            }
        }
        if touched.is_empty() {
            return 0;
        }
        for (r, action) in &touched {
            data.log(r, action, Some("external_session_revoked".into()), now);
        }
        self.save(&data).await;
        drop(data);
        self.changed.notify_waiters();
        touched.len()
    }

    /// Expire pending requests for `owner` whose target mission does not exist
    /// in `missions` (for example legacy zero-padded prefix rows) or whose
    /// requesting mission has been archived (`Acknowledged`), so unapprovable
    /// or retired requests never linger in the device approval queue.
    pub async fn expire_stale_for_store(
        &self,
        missions: &Arc<dyn crate::api::mission_store::MissionStore>,
        owner: &str,
    ) -> usize {
        use crate::api::control::MissionStatus;
        let candidates: Vec<(Uuid, Uuid, Option<Uuid>)> = {
            let data = self.data.lock().await;
            data.requests
                .iter()
                .filter(|r| r.owner == owner && r.state.is_pending())
                .map(|r| (r.id, r.target_mission_id, r.requester_mission_id))
                .collect()
        };
        if candidates.is_empty() {
            return 0;
        }
        let mut stale: Vec<(Uuid, &'static str)> = Vec::new();
        for (req_id, target_id, requester_mid) in candidates {
            match missions.get_mission(target_id).await {
                Ok(Some(_)) => {}
                Ok(None) => {
                    stale.push((req_id, "target_missing"));
                    continue;
                }
                Err(_) => continue,
            }
            if let Some(rmid) = requester_mid {
                if let Ok(Some(req_m)) = missions.get_mission(rmid).await {
                    if req_m.status == MissionStatus::Acknowledged {
                        stale.push((req_id, "requester_archived"));
                    }
                }
            }
        }
        if stale.is_empty() {
            return 0;
        }
        let now = Utc::now();
        let mut data = self.data.lock().await;
        let mut touched = Vec::new();
        for (req_id, reason) in stale {
            if let Some(r) = data
                .requests
                .iter_mut()
                .find(|r| r.id == req_id && r.owner == owner && r.state.is_pending())
            {
                r.state = ApprovalState::Expired;
                r.decided_at = Some(now);
                touched.push((r.clone(), reason));
            }
        }
        if touched.is_empty() {
            return 0;
        }
        for (r, reason) in &touched {
            data.log(r, "expired", Some((*reason).to_string()), now);
        }
        self.save(&data).await;
        drop(data);
        self.changed.notify_waiters();
        touched.len()
    }

    /// Wait view used by `GET /api/mcp/requests/mission_access/:id/wait`.
    pub async fn wait_for_requester(
        &self,
        owner: &str,
        requester: &approval_flow::RequesterSubject,
        id: Uuid,
        wait: Duration,
    ) -> Result<Value, (StatusCode, String)> {
        let initial = self
            .get(owner, id)
            .await
            .filter(|r| r.subject().same_actor(requester))
            .ok_or_else(|| {
                (
                    StatusCode::NOT_FOUND,
                    "Access request not found".to_string(),
                )
            })?;
        let final_req = if initial.state.is_pending() && !wait.is_zero() {
            self.wait_decided(owner, id, wait).await.unwrap_or(initial)
        } else {
            initial
        };
        let mut out = agent_view(&final_req);
        out["message"] = json!(decision_note(&final_req));
        Ok(out)
    }
}

/// What the requesting agent sees. Nothing from the target mission (title,
/// project, status, even whether it exists) until a live grant exists; only
/// Thomas's approval card shows the target title.
fn agent_view(r: &AccessRequest) -> Value {
    let now = Utc::now();
    let live = r.live_grant(now);
    let access_verdict = crate::orb_spec::access_step(crate::orb_spec::AccessStepInput {
        same_owner: true,
        is_self_or_child: false,
        is_read_tool: true,
        grant_approved: r.state == ApprovalState::Approved && r.revoked_at.is_none(),
        grant_unexpired: live,
        target_exists: r.target_title.is_some(),
    });
    json!({
        "request_id": r.id,
        "target_mission_id": r.target_mission_id,
        "target_title": if access_verdict.disclose_title { json!(r.target_title) } else { Value::Null },
        "scope": r.scope,
        "status": r.state,
        "reason": r.reason,
        "created_at": r.created_at,
        "expires_at": r.expires_at,
        "allowed_tools": if access_verdict.allow_tool { json!(READ_TOOLS) } else { json!([]) },
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
    let subject = p.requester_subject();
    if subject.is_external() {
        let bunker = super::privilege_broker::store(state).bunker_state().await;
        if bunker >= super::privilege_broker::BunkerState::HardLockdown {
            return Err(
                "Bunker HardLockdown is active; external MCP sessions are suspended".into(),
            );
        }
        if bunker >= super::privilege_broker::BunkerState::SoftQuarantine
            && name == "request_mission_access"
        {
            return Err(
                "Fleet is in Bunker SoftQuarantine; external mission-access requests are suspended"
                    .into(),
            );
        }
    }
    let access = store(state);
    match name {
        "list_mission_access" => {
            let list = access.by_requester(&p.sub, &subject).await;
            Ok(json!({ "requests": list.iter().map(agent_view).collect::<Vec<_>>() }))
        }
        "request_mission_access" => {
            let raw_target = args
                .get("target_mission_id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or("target_mission_id is required")?;
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
            let target_mission = resolve_target_mission_for_request(&missions, raw_target).await?;
            let target = target_mission.id;
            let requester_title = if let Some(own) = p.mission_id {
                let requester = missions
                    .get_mission(own)
                    .await
                    .ok()
                    .flatten()
                    .ok_or("Mission no longer exists")?;
                let fork_chain = crate::control_mcp::gateway::fork_lineage(&missions, own).await;
                if fork_chain.contains(&target)
                    || target_mission
                        .parent_mission_id
                        .is_some_and(|parent| fork_chain.contains(&parent))
                {
                    return Ok(
                        json!({"status":"already_in_scope","message":"This mission is already in your scope; read it directly."}),
                    );
                }
                for anc in &fork_chain {
                    let anc_subject = approval_flow::RequesterSubject::mission(*anc);
                    if let Some(grant_id) = access.read_grant(&p.sub, &anc_subject, target).await {
                        if let Some(existing) = access.get(&p.sub, grant_id).await {
                            let mut out = agent_view(&existing);
                            out["message"] = json!(decision_note(&existing));
                            return Ok(out);
                        }
                    }
                }
                requester.title
            } else {
                None
            };
            let r = access
                .request(NewRequest {
                    owner: p.sub.clone(),
                    owner_username: p.username.clone(),
                    requester: subject,
                    requester_title,
                    target,
                    target_title: target_mission.title,
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

/// Extract a leading hex prefix when an LLM zero-padded a short 8-char prefix
/// into a 36-char UUID (e.g. `2148a266-0000-0000-0000-000000000000` -> `2148a266`).
fn zero_padded_uuid_prefix(canonical_lower: &str) -> Option<&str> {
    let head = canonical_lower.strip_suffix("-0000-0000-0000-000000000000")?;
    (head.len() == 8 && head.chars().any(|c| c != '0')).then_some(head)
}

async fn resolve_target_mission_for_request(
    missions: &Arc<dyn crate::api::mission_store::MissionStore>,
    raw: &str,
) -> Result<crate::api::mission_store::Mission, String> {
    let normalized = raw.trim().to_ascii_lowercase();
    let prefix = if let Ok(id) = Uuid::parse_str(&normalized) {
        if let Some(m) = missions
            .get_mission(id)
            .await
            .map_err(|_| "Mission store unavailable".to_string())?
        {
            return Ok(m);
        }
        let canonical = id.to_string();
        match zero_padded_uuid_prefix(&canonical) {
            Some(head) => head.to_string(),
            None => {
                return Err(format!(
                    "Target mission {id} was not found; pass an existing mission UUID from list_missions."
                ));
            }
        }
    } else {
        if normalized.len() < 4
            || !normalized
                .chars()
                .all(|c| c.is_ascii_hexdigit() || c == '-')
        {
            return Err(
                "target_mission_id must be a mission UUID or at least 4 hex characters of one"
                    .into(),
            );
        }
        normalized
    };
    let candidates = missions
        .find_missions_by_id_prefix(&prefix, 11)
        .await
        .map_err(|_| "Mission store unavailable".to_string())?;
    match candidates.len() {
        0 => Err(format!("No mission matches '{raw}'")),
        1 => Ok(candidates.into_iter().next().expect("single candidate")),
        _ => Err(format!(
            "Mission prefix '{prefix}' is ambiguous; pass the full 36-character mission UUID."
        )),
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
                          get_mission_health, list_mission_shared_files and get_cloud_execution work on that mission. Never grants control: \
                          sending messages, cancel, resume and placement stay denied."
                .into(),
            input_schema: json!({"type":"object","required":["target_mission_id","reason"],"properties":{
                "target_mission_id":{"type":"string","minLength":4,"maxLength":64,"description":"Full UUID (or unambiguous >=4-char hex prefix) of the mission to read."},
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
/// Turn a pending request into a grant: lifetime and decision time. The
/// caller applies the state change. Returns the audit detail.
fn grant(
    r: &mut AccessRequest,
    now: DateTime<Utc>,
    ttl_hours: Option<i64>,
    hard_expires_at: Option<DateTime<Utc>>,
) -> String {
    let ttl = clamp_ttl(ttl_hours.or(Some(r.ttl_hours)));
    r.ttl_hours = ttl;
    let mut exp = now + chrono::Duration::hours(ttl);
    if let Some(hard) = hard_expires_at {
        if hard < exp {
            exp = hard;
        }
    }
    r.expires_at = Some(exp);
    r.decided_at = Some(now);
    format!("{ttl}h")
}

pub(crate) async fn notify_requester(state: &Arc<AppState>, r: &AccessRequest) {
    use crate::api::control::{ControlCommand, MissionStatus};
    let Some(requester_mission_id) = r.requester_mission_id else {
        return;
    };
    let user = AuthUser {
        id: r.owner.clone(),
        username: r.owner_username.clone(),
    };
    let control = state.control.get_or_spawn(&user).await;
    let Ok(Some(m)) = control
        .mission_store
        .get_mission(requester_mission_id)
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
            target_mission_id: Some(requester_mission_id),
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
    let missions = state.control.get_or_spawn(&user).await.mission_store;
    let access = store(&state);
    access.expire_stale_for_store(&missions, &user.id).await;
    Json(access.snapshot(&user.id).await)
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
        .approve_with_state(&state, &user.id, id, body.ttl_hours)
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
    let who = r.subject().prompt_who(r.requester_title.as_deref());
    let target = r
        .target_title
        .clone()
        .unwrap_or_else(|| format!("mission {}", &r.target_mission_id.to_string()[..8]));
    Ok(match action {
        "approve" => format!(
            "Let {} READ (not control) {} for {} h",
            who,
            super::approvals::quoted(&target),
            clamp_ttl(ttl.or(Some(r.ttl_hours)))
        ),
        _ => format!(
            "Decline: {} wants to read {}",
            who,
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

    fn subj(id: Uuid) -> approval_flow::RequesterSubject {
        approval_flow::RequesterSubject::mission(id)
    }

    fn new(owner: &str, requester: Uuid, target: Uuid) -> NewRequest {
        NewRequest {
            owner: owner.into(),
            owner_username: owner.into(),
            requester: subj(requester),
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
        assert_eq!(s.read_grant("thomas", &subj(a), b).await, None);
        // Asking again returns the same pending request.
        assert_eq!(s.request(new("thomas", a, b)).await.unwrap().id, r.id);
        let ok = s.approve("thomas", r.id, None).await.unwrap();
        assert_eq!(ok.state, ApprovalState::Approved);
        let left = ok.expires_at.unwrap() - Utc::now();
        assert!(left > chrono::Duration::hours(23) && left <= chrono::Duration::hours(24));
        assert_eq!(s.read_grant("thomas", &subj(a), b).await, Some(r.id));
        // A grant is directional.
        assert_eq!(s.read_grant("thomas", &subj(b), a).await, None);
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
                s.grant_for_tool("thomas", &subj(a), b, tool).await,
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
                s.grant_for_tool("thomas", &subj(a), b, tool).await,
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
        assert_eq!(s.read_grant("thomas", &subj(a), b).await, None);
        // Revoking a pending request is refused (deny it instead).
        let r2 = s.request(new("thomas", a, c)).await.unwrap();
        assert!(s.revoke("thomas", r2.id).await.is_err());
        s.approve("thomas", r2.id, Some(1)).await.unwrap();
        assert!(s.read_grant("thomas", &subj(a), c).await.is_some());
        s.revoke("thomas", r2.id).await.unwrap();
        assert_eq!(s.read_grant("thomas", &subj(a), c).await, None);
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
            s.read_grant("thomas", &subj(a), b).await,
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
        assert_eq!(s.read_grant("mallory", &subj(a), b).await, None);
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
        assert_eq!(s.read_grant("thomas", &subj(a), b).await, Some(id));
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
            s.read_grant("thomas", &subj(a), b).await,
            Some(r.id),
            "memory must match disk"
        );
        std::fs::remove_dir(path.with_extension("json.tmp")).unwrap();
        s.revoke("thomas", r.id).await.unwrap();
        // After a restart the revoke holds.
        assert_eq!(
            MissionAccess::open(path)
                .read_grant("thomas", &subj(a), b)
                .await,
            None
        );
    }

    #[test]
    fn scope_hint_points_reads_to_the_tool_and_refuses_control() {
        let t = Uuid::new_v4();
        assert!(scope_hint("get_mission_events", t).contains("request_mission_access"));
        assert!(scope_hint("get_cloud_execution", t).contains("request_mission_access"));
        assert!(scope_hint("cancel_mission", t).contains("never allow"));
        assert!(!READ_TOOLS.iter().any(|t| matches!(
            *t,
            "send_message_to_mission" | "cancel_mission" | "resume_mission" | "start_mission"
        )));
    }

    #[tokio::test]
    async fn approve_all_is_all_or_nothing_and_owner_scoped() {
        let s = temp();
        let a = s
            .request(new("thomas", Uuid::new_v4(), Uuid::new_v4()))
            .await
            .unwrap();
        let b = s
            .request(new("thomas", Uuid::new_v4(), Uuid::new_v4()))
            .await
            .unwrap();
        let theirs = s
            .request(new("mallory", Uuid::new_v4(), Uuid::new_v4()))
            .await
            .unwrap();
        let seen = |r: &AccessRequest| {
            let i = ApprovalItem::mission_access(r);
            BatchRef {
                kind: i.kind,
                id: i.id,
                digest: i.digest,
            }
        };
        assert_eq!(s.pending_items("thomas").await.len(), 2);
        assert!(s
            .approve_batch("thomas", &[seen(&a), seen(&theirs)], false)
            .await
            .is_err());
        assert_eq!(
            s.get("thomas", a.id).await.unwrap().state,
            ApprovalState::Pending
        );
        let mut changed = b.clone();
        changed.ttl_hours += 1;
        assert!(s
            .approve_batch("thomas", &[seen(&a), seen(&changed)], false)
            .await
            .is_err());
        let ok = s
            .approve_batch("thomas", &[seen(&a), seen(&b)], false)
            .await
            .unwrap();
        assert!(ok.iter().all(|r| r.state == ApprovalState::Approved));
        assert!(s.pending_items("thomas").await.is_empty());
    }
}
