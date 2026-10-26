//! Biometric Just-In-Time (JIT) Privilege & Root Access Broker (`orb_privilege_step`, `orb_bunker_step`).
//!
//! Lets a mission request temporary, session-scoped (or bounded-TTL) privileged
//! execution (`ops_read`, `service_deploy`, or `root_exec`) on its own worker
//! node (`target_host = "self"`, executed via `orb-privd.sock` / `orb-sudo`
//! with zero SSH overhead) or on a named fleet host (`agent-core`, `ashur`,
//! `babylon`, `nippur`, `thomas-md`, `polymath`, `maven-repo`, `dgx-spark`).
//!
//! Thomas approves on an enrolled device with Touch ID / Face ID
//! (`POST /api/privilege-access/:id/approve`, always hardware-signed via
//! [`super::approvals::always_signed`]). Every admission decision is gated by
//! [`crate::orb_spec::privilege_step`] and [`crate::orb_spec::bunker_step`],
//! and every command executed under a grant is recorded in a structured
//! per-command JSON audit log in `<working_dir>/.sandboxed-sh/privilege_access.json`.

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
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;
use uuid::Uuid;

use super::approval_flow::{self, ApprovalEvent, ApprovalState};
use super::auth::AuthUser;
use super::routes::AppState;
use crate::orb_spec::{
    bunker_step, privilege_step, BunkerState, PrivilegeScopeRank, PrivilegeStepInput,
};

/// Default ceiling for a `"session"`-scoped grant (reaped earlier when the
/// mission session ends via [`reap_mission_grants`]).
pub const DEFAULT_SESSION_MAX_MINUTES: i64 = 240;
/// Maximum explicit TTL in minutes (4 hours).
pub const MAX_TTL_MINUTES: i64 = 240;
/// Unanswered requests expire after 4 hours.
const PENDING_TTL_HOURS: i64 = 4;
/// Synchronous wait in MCP tool call before returning `pending`.
const APPROVAL_WAIT: Duration = Duration::from_secs(20);
const MAX_PENDING_PER_MISSION: usize = 5;
const AUDIT_LIMIT: usize = 2000;
const COMMAND_AUDIT_LIMIT: usize = 5000;
const BUNKER_INCIDENT_LIMIT: usize = 500;
const HISTORY_LIMIT: usize = 500;

pub const TOOL_NAMES: [&str; 3] = [
    "request_privileged_access",
    "list_privileged_access",
    "revoke_privileged_access",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrivilegeScope {
    OpsRead,
    ServiceDeploy,
    RootExec,
}

impl PrivilegeScope {
    pub fn to_rank(self) -> PrivilegeScopeRank {
        match self {
            Self::OpsRead => PrivilegeScopeRank::OpsRead,
            Self::ServiceDeploy => PrivilegeScopeRank::ServiceDeploy,
            Self::RootExec => PrivilegeScopeRank::RootExec,
        }
    }

    pub fn from_str_opt(raw: &str) -> Option<Self> {
        match raw.trim() {
            "ops_read" => Some(Self::OpsRead),
            "service_deploy" => Some(Self::ServiceDeploy),
            "root_exec" | "root" | "sudo" => Some(Self::RootExec),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        self.to_rank().as_str()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrivilegeRequest {
    pub id: Uuid,
    pub owner: String,
    #[serde(default)]
    pub owner_username: String,
    pub requester_mission_id: Uuid,
    #[serde(default)]
    pub requester_title: Option<String>,
    /// `"self"` for local root via `orb-privd.sock` / `orb-sudo`, or a fleet host.
    pub target_host: String,
    pub scope: PrivilegeScope,
    /// Optional systemd unit or command restriction for `service_deploy` / `ops_read`.
    #[serde(default)]
    pub allowed_unit: Option<String>,
    pub reason: String,
    /// True when the grant is tied to the requesting mission's active session.
    #[serde(default = "default_true")]
    pub session_scoped: bool,
    pub ttl_minutes: i64,
    pub state: ApprovalState,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub decided_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub session_expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub revoked_at: Option<DateTime<Utc>>,
    /// SHA-256 of the ephemeral lease token issued to the mission on approval.
    #[serde(default, skip_serializing)]
    pub lease_token_sha256: Option<String>,
}

fn default_true() -> bool {
    true
}

impl PrivilegeRequest {
    pub fn evaluate(
        &self,
        now: DateTime<Utc>,
        mission_active: bool,
        requested_scope: PrivilegeScope,
        bunker_state: BunkerState,
    ) -> crate::orb_spec::PrivilegeStepVerdict {
        let now_epoch = now.timestamp().max(0) as u64;
        let grant_exp = self
            .expires_at
            .map(|t| t.timestamp().max(0) as u64)
            .unwrap_or(0);
        let sess_exp = self
            .session_expires_at
            .or(self.expires_at)
            .map(|t| t.timestamp().max(0) as u64)
            .unwrap_or(0);
        privilege_step(PrivilegeStepInput {
            same_owner: true,
            mission_active,
            biometric_signed: self.state == ApprovalState::Approved,
            requested_scope: requested_scope.to_rank(),
            max_granted_scope: self.scope.to_rank(),
            bunker_state,
            revoked: self.revoked_at.is_some() || self.state == ApprovalState::Revoked,
            now_epoch,
            grant_expires_at: grant_exp,
            session_expires_at: sess_exp,
        })
    }

    pub fn live_grant(&self, now: DateTime<Utc>, bunker_state: BunkerState) -> bool {
        self.evaluate(now, true, self.scope, bunker_state)
            .allow_exec
    }

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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrivilegeAuditEntry {
    pub at: DateTime<Utc>,
    pub owner: String,
    pub request_id: Uuid,
    pub requester_mission_id: Uuid,
    pub target_host: String,
    pub scope: PrivilegeScope,
    /// `requested`, `approved`, `denied`, `expired`, `revoked`, `session_reaped`, `bunker_revoked`.
    pub action: String,
    #[serde(default)]
    pub detail: Option<String>,
}

/// Structured per-command JSON audit log entry recorded by Core whenever
/// `orb-privd` / `orb-sudo` or a guarded deploy executes under a grant.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandAuditEntry {
    pub id: Uuid,
    pub at: DateTime<Utc>,
    pub owner: String,
    pub grant_id: Uuid,
    pub mission_id: Uuid,
    #[serde(default)]
    pub mission_title: Option<String>,
    pub target_host: String,
    pub scope: PrivilegeScope,
    pub command: String,
    #[serde(default)]
    pub argv: Vec<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub exit_code: Option<i32>,
    #[serde(default)]
    pub duration_ms: Option<u64>,
    #[serde(default)]
    pub stdout_sha256: Option<String>,
    pub require_force_cmd: bool,
}

/// Durable incident record for every canary tripwire alert, Sovereign Dead-Man's
/// Switch escalation, or operator biometric Bunker / Unbunker transition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BunkerIncidentEntry {
    pub id: Uuid,
    pub at: DateTime<Utc>,
    /// `"canary_tripwire"`, `"sovereign_deadman"`, `"operator_manual"`, or `"biometric_unbunker"`.
    pub source: String,
    #[serde(default)]
    pub peer_name: Option<String>,
    #[serde(default)]
    pub canary_kind: Option<String>,
    #[serde(default)]
    pub event_seq: Option<u64>,
    #[serde(default)]
    pub event_timestamp: Option<u64>,
    #[serde(default)]
    pub peer_pubkey_hex: Option<String>,
    #[serde(default)]
    pub signature_hex: Option<String>,
    #[serde(default)]
    pub epoch: u64,
    #[serde(alias = "previous_state")]
    pub previous_bunker_state: u8,
    #[serde(alias = "next_state")]
    pub new_bunker_state: u8,
    #[serde(default)]
    pub dry_run: bool,
    pub reason: String,
    #[serde(default)]
    pub pid: Option<u32>,
    #[serde(default)]
    pub uid: Option<u32>,
    #[serde(default)]
    pub cgroup: Option<String>,
    #[serde(default)]
    pub cmdline: Option<String>,
    pub detail_sha256_hex: String,
    #[serde(default)]
    pub alert_delivered: bool,
    #[serde(default)]
    pub alert_channels: Vec<String>,
    #[serde(default)]
    pub alert_error: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Persisted {
    #[serde(default)]
    bunker_state: u8,
    #[serde(default)]
    requests: Vec<PrivilegeRequest>,
    #[serde(default)]
    audit: Vec<PrivilegeAuditEntry>,
    #[serde(default)]
    command_audit: Vec<CommandAuditEntry>,
    #[serde(default)]
    bunker_incidents: Vec<BunkerIncidentEntry>,
}

impl Persisted {
    fn current_bunker(&self) -> BunkerState {
        BunkerState::from_u8(self.bunker_state)
    }

    fn log(
        &mut self,
        r: &PrivilegeRequest,
        action: &str,
        detail: Option<String>,
        at: DateTime<Utc>,
    ) {
        self.audit.push(PrivilegeAuditEntry {
            at,
            owner: r.owner.clone(),
            request_id: r.id,
            requester_mission_id: r.requester_mission_id,
            target_host: r.target_host.clone(),
            scope: r.scope,
            action: action.into(),
            detail,
        });
        let len = self.audit.len();
        if len > AUDIT_LIMIT {
            self.audit.drain(..len - AUDIT_LIMIT);
        }
    }

    fn log_command(&mut self, entry: CommandAuditEntry) {
        self.command_audit.push(entry);
        let len = self.command_audit.len();
        if len > COMMAND_AUDIT_LIMIT {
            self.command_audit.drain(..len - COMMAND_AUDIT_LIMIT);
        }
    }

    fn log_bunker_incident(&mut self, entry: BunkerIncidentEntry) {
        self.bunker_incidents.push(entry);
        let len = self.bunker_incidents.len();
        if len > BUNKER_INCIDENT_LIMIT {
            self.bunker_incidents.drain(..len - BUNKER_INCIDENT_LIMIT);
        }
    }

    fn prune(&mut self, now: DateTime<Utc>) -> bool {
        let bunker = self.current_bunker();
        let mut changed = Vec::new();
        for r in self.requests.iter_mut() {
            let ran_out = match r.state {
                ApprovalState::Pending => approval_flow::pending_timed_out(
                    r.created_at,
                    now,
                    chrono::Duration::hours(PENDING_TTL_HOURS),
                ),
                ApprovalState::Approved => {
                    let v = r.evaluate(now, true, r.scope, bunker);
                    v.reap_grant
                }
                _ => false,
            };
            if ran_out {
                if let Ok(next) = r.state.apply(ApprovalEvent::Expire) {
                    if r.state.is_pending() {
                        r.decided_at = Some(now);
                    }
                    r.state = next;
                    r.lease_token_sha256 = None;
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

pub struct PrivilegeBroker {
    path: PathBuf,
    data: Mutex<Persisted>,
    /// Ephemeral plaintext lease tokens kept only in memory so the requesting
    /// mission can read its own token once approved, while disk only stores SHA-256.
    live_tokens: Mutex<std::collections::HashMap<Uuid, String>>,
    changed: tokio::sync::Notify,
}

static BROKER: OnceLock<Arc<PrivilegeBroker>> = OnceLock::new();

pub fn store(state: &AppState) -> Arc<PrivilegeBroker> {
    BROKER
        .get_or_init(|| {
            Arc::new(PrivilegeBroker::open(
                state
                    .config
                    .working_dir
                    .join(".sandboxed-sh")
                    .join("privilege_access.json"),
            ))
        })
        .clone()
}

/// Reap session-scoped grants when the broker has been initialized in this process.
pub async fn reap_if_initialized(mission_id: Uuid, reason: &str) -> usize {
    if let Some(broker) = BROKER.get() {
        broker.reap_mission_grants(mission_id, reason).await
    } else {
        0
    }
}

#[derive(Debug, Clone)]
pub struct NewPrivilegeRequest {
    pub owner: String,
    pub owner_username: String,
    pub requester: Uuid,
    pub requester_title: Option<String>,
    pub target_host: String,
    pub scope: PrivilegeScope,
    pub allowed_unit: Option<String>,
    pub reason: String,
    pub session_scoped: bool,
    pub ttl_minutes: Option<i64>,
}

fn clamp_ttl_minutes(ttl: Option<i64>) -> i64 {
    ttl.unwrap_or(DEFAULT_SESSION_MAX_MINUTES)
        .clamp(1, MAX_TTL_MINUTES)
}

fn sha256_hex(input: &str) -> String {
    hex::encode(Sha256::digest(input.as_bytes()))
}

fn normalize_target_host(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim().to_lowercase();
    if trimmed.is_empty() {
        return Err("target_host is required (use \"self\" for local root)".into());
    }
    if trimmed == "local" || trimmed == "localhost" || trimmed == "local-node" {
        return Ok("self".into());
    }
    if !trimmed
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '.' || c == '_')
    {
        return Err("Invalid target_host".into());
    }
    Ok(trimmed)
}

impl PrivilegeBroker {
    pub fn open(path: PathBuf) -> Self {
        let data = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        Self {
            path,
            data: Mutex::new(data),
            live_tokens: Mutex::new(std::collections::HashMap::new()),
            changed: tokio::sync::Notify::new(),
        }
    }

    async fn save(&self, data: &Persisted) {
        if let Err(e) = approval_flow::persist_private(&self.path, data).await {
            tracing::warn!("privilege broker state not saved: {e}");
        }
    }

    async fn commit(&self, data: &Persisted) -> Result<(), String> {
        approval_flow::persist_private(&self.path, data)
            .await
            .map_err(|e| format!("Could not save privilege decision ({e}); nothing changed"))
    }

    pub async fn bunker_state(&self) -> BunkerState {
        self.data.lock().await.current_bunker()
    }

    pub async fn request(&self, new: NewPrivilegeRequest) -> Result<PrivilegeRequest, String> {
        let target_host = normalize_target_host(&new.target_host)?;
        let now = Utc::now();
        let mut data = self.data.lock().await;
        if data.current_bunker() != BunkerState::Normal {
            return Err(
                "Fleet is currently in Bunker Mode; privileged access requests are locked".into(),
            );
        }
        let pruned = data.prune(now);
        let bunker = data.current_bunker();
        if let Some(existing) = data.requests.iter().rev().find(|r| {
            r.owner == new.owner
                && r.requester_mission_id == new.requester
                && r.target_host == target_host
                && r.scope.to_rank() >= new.scope.to_rank()
                && (r.state.is_pending() || r.live_grant(now, bunker))
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
                "This mission already has {open} pending privilege requests; wait for Thomas to answer them"
            ));
        }
        let r = PrivilegeRequest {
            id: Uuid::new_v4(),
            owner: new.owner,
            owner_username: new.owner_username,
            requester_mission_id: new.requester,
            requester_title: new.requester_title,
            target_host,
            scope: new.scope,
            allowed_unit: new.allowed_unit,
            reason: new.reason,
            session_scoped: new.session_scoped,
            ttl_minutes: clamp_ttl_minutes(new.ttl_minutes),
            state: ApprovalState::Pending,
            created_at: now,
            decided_at: None,
            expires_at: None,
            session_expires_at: None,
            revoked_at: None,
            lease_token_sha256: None,
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

    pub async fn get(&self, owner: &str, id: Uuid) -> Option<PrivilegeRequest> {
        let mut data = self.data.lock().await;
        if data.prune(Utc::now()) {
            self.save(&data).await;
        }
        data.requests
            .iter()
            .find(|r| r.id == id && r.owner == owner)
            .cloned()
    }

    pub async fn lease_token_for(&self, request_id: Uuid) -> Option<String> {
        self.live_tokens.lock().await.get(&request_id).cloned()
    }

    async fn transition(
        &self,
        owner: &str,
        id: Uuid,
        event: ApprovalEvent,
        ttl_minutes: Option<i64>,
        session_scoped: Option<bool>,
    ) -> Result<PrivilegeRequest, String> {
        let now = Utc::now();
        let mut data = self.data.lock().await;
        data.prune(now);
        if matches!(event, ApprovalEvent::Approve) && data.current_bunker() != BunkerState::Normal {
            return Err("Cannot approve privilege grant while Bunker Mode is active".into());
        }
        let idx = data
            .requests
            .iter()
            .position(|r| r.id == id && r.owner == owner)
            .ok_or("Request not found")?;
        let before = data.requests[idx].clone();
        let r = &mut data.requests[idx];
        let next = r.state.apply(event)?;
        let mut minted_token: Option<String> = None;
        let detail = match event {
            ApprovalEvent::Approve => {
                let ttl = clamp_ttl_minutes(ttl_minutes.or(Some(r.ttl_minutes)));
                let sess = session_scoped.unwrap_or(r.session_scoped);
                r.ttl_minutes = ttl;
                r.session_scoped = sess;
                let exp = now + chrono::Duration::minutes(ttl);
                r.expires_at = Some(exp);
                r.session_expires_at = Some(exp);
                r.decided_at = Some(now);
                let token = format!(
                    "orb-jit-{}-{}",
                    Uuid::new_v4().simple(),
                    Uuid::new_v4().simple()
                );
                r.lease_token_sha256 = Some(sha256_hex(&token));
                minted_token = Some(token);
                Some(if sess {
                    format!("session (max {ttl}m)")
                } else {
                    format!("{ttl}m")
                })
            }
            ApprovalEvent::Deny => {
                r.decided_at = Some(now);
                r.lease_token_sha256 = None;
                None
            }
            ApprovalEvent::Revoke => {
                r.revoked_at = Some(now);
                r.lease_token_sha256 = None;
                None
            }
            ApprovalEvent::Expire => {
                r.lease_token_sha256 = None;
                None
            }
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
            data.requests[idx] = before;
            data.audit.pop();
            return Err(e);
        }
        drop(data);
        let mut tokens = self.live_tokens.lock().await;
        if let Some(tok) = minted_token {
            tokens.insert(id, tok);
        } else {
            tokens.remove(&id);
        }
        drop(tokens);
        self.changed.notify_waiters();
        Ok(out)
    }

    pub async fn approve(
        &self,
        owner: &str,
        id: Uuid,
        ttl_minutes: Option<i64>,
        session_scoped: Option<bool>,
    ) -> Result<PrivilegeRequest, String> {
        self.transition(
            owner,
            id,
            ApprovalEvent::Approve,
            ttl_minutes,
            session_scoped,
        )
        .await
    }

    pub async fn deny(&self, owner: &str, id: Uuid) -> Result<PrivilegeRequest, String> {
        self.transition(owner, id, ApprovalEvent::Deny, None, None)
            .await
    }

    pub async fn revoke(&self, owner: &str, id: Uuid) -> Result<PrivilegeRequest, String> {
        self.transition(owner, id, ApprovalEvent::Revoke, None, None)
            .await
    }

    /// Reap all active session-scoped privilege grants for `mission_id` when its
    /// session finishes, pauses, or is cancelled (`orb_privilege_step` ClockDiscipline).
    pub async fn reap_mission_grants(&self, mission_id: Uuid, reason: &str) -> usize {
        let now = Utc::now();
        let mut data = self.data.lock().await;
        let current_bunker = data.current_bunker();
        let mut reaped = Vec::new();
        for r in data.requests.iter_mut() {
            if r.requester_mission_id == mission_id
                && r.session_scoped
                && (r.state == ApprovalState::Approved || r.state.is_pending())
            {
                let v = privilege_step(PrivilegeStepInput {
                    same_owner: true,
                    mission_active: false,
                    biometric_signed: r.state == ApprovalState::Approved,
                    requested_scope: r.scope.to_rank(),
                    max_granted_scope: r.scope.to_rank(),
                    bunker_state: current_bunker,
                    revoked: false,
                    now_epoch: now.timestamp().max(0) as u64,
                    grant_expires_at: r
                        .expires_at
                        .map(|t| t.timestamp().max(0) as u64)
                        .unwrap_or(0),
                    session_expires_at: now.timestamp().max(0) as u64,
                });
                if v.reap_grant {
                    r.state = ApprovalState::Revoked;
                    r.revoked_at = Some(now);
                    r.session_expires_at = Some(now);
                    r.lease_token_sha256 = None;
                    reaped.push(r.clone());
                }
            }
        }
        if reaped.is_empty() {
            return 0;
        }
        for r in &reaped {
            data.log(r, "session_reaped", Some(reason.to_string()), now);
        }
        self.save(&data).await;
        drop(data);
        let mut tokens = self.live_tokens.lock().await;
        for r in &reaped {
            tokens.remove(&r.id);
        }
        drop(tokens);
        self.changed.notify_waiters();
        reaped.len()
    }

    /// Transition Bunker Mode via `orb_bunker_step`. If `revoke_all_jit_grants`
    /// is set by the Lean kernel, immediately revokes all active JIT grants.
    pub async fn step_bunker(
        &self,
        canary_tripped: bool,
        auth_failure_burst: bool,
        manual_trigger: u8,
        biometric_unbunker: bool,
        detail: Option<String>,
    ) -> Result<BunkerStepResponse, String> {
        let now = Utc::now();
        let mut data = self.data.lock().await;
        let current = data.current_bunker();
        let verdict = bunker_step(
            current,
            canary_tripped,
            auth_failure_burst,
            manual_trigger,
            biometric_unbunker,
        );
        data.bunker_state = verdict.next_state as u8;
        let mut revoked_ids = Vec::new();
        if verdict.revoke_all_jit_grants {
            for r in data.requests.iter_mut() {
                if r.state == ApprovalState::Approved || r.state.is_pending() {
                    r.state = ApprovalState::Revoked;
                    r.revoked_at = Some(now);
                    r.lease_token_sha256 = None;
                    revoked_ids.push(r.clone());
                }
            }
            for r in &revoked_ids {
                data.log(r, "bunker_revoked", detail.clone(), now);
            }
        }
        self.commit(&data).await?;
        drop(data);
        if !revoked_ids.is_empty() {
            let mut tokens = self.live_tokens.lock().await;
            for r in &revoked_ids {
                tokens.remove(&r.id);
            }
        }
        self.changed.notify_waiters();
        Ok(BunkerStepResponse {
            previous_state: current as u8,
            bunker_state: verdict.next_state as u8,
            revoke_all_jit_grants: verdict.revoke_all_jit_grants,
            isolate_node_mesh: verdict.isolate_node_mesh,
            revoked_grants_count: revoked_ids.len(),
        })
    }

    /// Verify a lease token from `orb-privd` / `orb-sudo` and log the command
    /// in Core's structured per-command JSON audit log.
    pub async fn verify_and_log_command(
        &self,
        req: VerifyLeaseRequest,
    ) -> Result<VerifyLeaseResponse, String> {
        let now = Utc::now();
        let token_hash = sha256_hex(req.lease_token.trim());
        let mut data = self.data.lock().await;
        data.prune(now);
        let bunker = data.current_bunker();
        let Some(grant) = data
            .requests
            .iter()
            .find(|r| {
                r.requester_mission_id == req.mission_id
                    && r.lease_token_sha256.as_deref() == Some(token_hash.as_str())
            })
            .cloned()
        else {
            return Err("No active privilege lease matches this token".into());
        };
        let requested_scope = req.requested_scope.unwrap_or(grant.scope);
        let target_norm = normalize_target_host(&req.target_host)?;
        if grant.target_host != target_norm && grant.target_host != "all" {
            return Err(format!(
                "Grant is scoped to target_host={}, not {}",
                grant.target_host, target_norm
            ));
        }
        let verdict = grant.evaluate(now, true, requested_scope, bunker);
        if !verdict.allow_exec {
            return Err("Privilege grant is expired, revoked, or blocked by Bunker Mode".into());
        }
        let entry = CommandAuditEntry {
            id: Uuid::new_v4(),
            at: now,
            owner: grant.owner.clone(),
            grant_id: grant.id,
            mission_id: grant.requester_mission_id,
            mission_title: grant.requester_title.clone(),
            target_host: target_norm,
            scope: requested_scope,
            command: req.command.chars().take(2000).collect(),
            argv: req.argv.into_iter().take(64).collect(),
            cwd: req.cwd,
            exit_code: req.exit_code,
            duration_ms: req.duration_ms,
            stdout_sha256: req.stdout_sha256,
            require_force_cmd: verdict.require_force_cmd,
        };
        data.log_command(entry.clone());
        self.save(&data).await;
        Ok(VerifyLeaseResponse {
            allow_exec: true,
            require_force_cmd: verdict.require_force_cmd,
            grant_id: grant.id,
            scope: grant.scope,
            allowed_unit: grant.allowed_unit,
            expires_at: grant.expires_at,
            audit_entry_id: entry.id,
        })
    }

    /// Check if `mission_id` holds an active `ServiceDeploy` or `RootExec`
    /// grant covering `target_service` on `agent-core` / `orb-core` (used by
    /// `deploy_sandboxed_sh` on `:3000`), enforcing `allowed_unit` when set.
    pub async fn has_active_deploy_grant(
        &self,
        mission_id: Uuid,
        target_service: &str,
    ) -> Option<Uuid> {
        fn unit_matches_deploy_service(allowed_unit: &str, target_service: &str) -> bool {
            let a = allowed_unit.trim().trim_end_matches(".service");
            let b = target_service.trim().trim_end_matches(".service");
            if a == b {
                return true;
            }
            let is_prod_orb = |s: &str| {
                matches!(
                    s,
                    "orb"
                        | "orb-core"
                        | "orb-prod"
                        | "assistant-mcp"
                        | "sandboxed-sh"
                        | "sandboxed-sh-prod"
                )
            };
            is_prod_orb(a) && is_prod_orb(b)
        }

        let now = Utc::now();
        let mut data = self.data.lock().await;
        data.prune(now);
        let bunker = data.current_bunker();
        data.requests
            .iter()
            .rev()
            .find(|r| {
                r.requester_mission_id == mission_id
                    && (r.target_host == target_service
                        || r.target_host == "agent-core"
                        || r.target_host == "orb-core")
                    && (r.scope == PrivilegeScope::RootExec
                        || r.allowed_unit
                            .as_deref()
                            .map(|u| unit_matches_deploy_service(u, target_service))
                            .unwrap_or(true))
                    && r.evaluate(now, true, PrivilegeScope::ServiceDeploy, bunker)
                        .allow_exec
            })
            .map(|r| r.id)
    }

    pub async fn wait_decided(
        &self,
        owner: &str,
        id: Uuid,
        wait: Duration,
    ) -> Option<PrivilegeRequest> {
        approval_flow::wait_settled(&self.changed, wait, move || async move {
            self.get(owner, id).await.map(|r| r.state)
        })
        .await?;
        self.get(owner, id).await
    }

    pub async fn snapshot(&self, owner: &str) -> Value {
        let mut data = self.data.lock().await;
        if data.prune(Utc::now()) {
            self.save(&data).await;
        }
        let bunker = data.current_bunker();
        let requests: Vec<&PrivilegeRequest> = data
            .requests
            .iter()
            .rev()
            .filter(|r| r.owner == owner)
            .take(200)
            .collect();
        let audit: Vec<&PrivilegeAuditEntry> = data
            .audit
            .iter()
            .rev()
            .filter(|a| a.owner == owner)
            .take(300)
            .collect();
        let command_audit: Vec<&CommandAuditEntry> = data
            .command_audit
            .iter()
            .rev()
            .filter(|c| c.owner == owner)
            .take(500)
            .collect();
        let bunker_incidents: Vec<&BunkerIncidentEntry> = data
            .bunker_incidents
            .iter()
            .rev()
            .take(100)
            .collect();
        json!({
            "bunker_state": bunker as u8,
            "requests": requests,
            "audit": audit,
            "command_audit": command_audit,
            "bunker_incidents": bunker_incidents,
        })
    }

    pub async fn record_bunker_incident(&self, entry: BunkerIncidentEntry) -> Result<Uuid, String> {
        let id = entry.id;
        let mut data = self.data.lock().await;
        data.log_bunker_incident(entry);
        if let Err(e) = self.commit(&data).await {
            data.bunker_incidents.pop();
            return Err(e);
        }
        drop(data);
        self.changed.notify_waiters();
        Ok(id)
    }

    pub async fn match_canary_incident(
        &self,
        req: &super::mesh::CanaryTripwireRequest,
        peer_pubkey_hex: &str,
    ) -> Result<Option<BunkerIncidentEntry>, String> {
        let peer_name = req.peer_name.trim();
        let canary_kind = req.canary_kind.trim();
        let data = self.data.lock().await;
        let Some(existing) = data.bunker_incidents.iter().rev().find(|i| {
            i.peer_name.as_deref() == Some(peer_name)
                && i.event_seq == Some(req.event_seq)
        }) else {
            return Ok(None);
        };
        let exact_match = existing.canary_kind.as_deref() == Some(canary_kind)
            && existing.dry_run == req.dry_run
            && existing.event_timestamp == Some(req.timestamp)
            && existing
                .detail_sha256_hex
                .eq_ignore_ascii_case(req.detail_sha256_hex.trim())
            && existing
                .peer_pubkey_hex
                .as_deref()
                .map(|k| k.eq_ignore_ascii_case(peer_pubkey_hex.trim()))
                .unwrap_or(false)
            && existing
                .signature_hex
                .as_deref()
                .map(|s| s.eq_ignore_ascii_case(req.signature_hex.trim()))
                .unwrap_or(false);
        if exact_match {
            Ok(Some(existing.clone()))
        } else {
            Err("conflicting canary payload for already-recorded (peer_name, event_seq)".into())
        }
    }

    /// Atomically transitions `PrivilegeBroker` Bunker state (revoking active JIT grants
    /// when `!req.dry_run`) and records the `BunkerIncidentEntry` in a single `commit`
    /// BEFORE `MeshStore.canary_replay` is advanced on disk.
    pub async fn escalate_and_record_canary_incident(
        &self,
        req: &super::mesh::CanaryTripwireRequest,
        prev_mesh_u8: u8,
        next_mesh_u8: u8,
        epoch: u64,
        peer_pubkey_hex: &str,
    ) -> Result<(BunkerStepResponse, BunkerIncidentEntry), String> {
        let now = Utc::now();
        let mut data = self.data.lock().await;
        let prev_bunker = data.current_bunker();
        let prev_bunker_u8 = prev_bunker as u8;
        let mut revoked_ids = Vec::new();
        let orb_step = if req.dry_run {
            BunkerStepResponse {
                previous_state: prev_bunker_u8,
                bunker_state: prev_bunker_u8,
                revoke_all_jit_grants: false,
                isolate_node_mesh: false,
                revoked_grants_count: 0,
            }
        } else {
            let verdict = bunker_step(prev_bunker, true, false, 2, false);
            data.bunker_state = verdict.next_state as u8;
            let detail = Some(format!(
                "canary_tripwire:{}:{}:{}",
                req.peer_name.trim(),
                req.canary_kind.trim(),
                req.reason.trim()
            ));
            if verdict.revoke_all_jit_grants {
                for r in data.requests.iter_mut() {
                    if r.state == ApprovalState::Approved || r.state.is_pending() {
                        r.state = ApprovalState::Revoked;
                        r.revoked_at = Some(now);
                        r.lease_token_sha256 = None;
                        revoked_ids.push(r.clone());
                    }
                }
                for r in &revoked_ids {
                    data.log(r, "bunker_revoked", detail.clone(), now);
                }
            }
            BunkerStepResponse {
                previous_state: prev_bunker_u8,
                bunker_state: verdict.next_state as u8,
                revoke_all_jit_grants: verdict.revoke_all_jit_grants,
                isolate_node_mesh: verdict.isolate_node_mesh,
                revoked_grants_count: revoked_ids.len(),
            }
        };

        let incident = BunkerIncidentEntry {
            id: Uuid::new_v4(),
            at: now,
            source: "canary_tripwire".into(),
            peer_name: Some(req.peer_name.trim().to_string()),
            canary_kind: Some(req.canary_kind.trim().to_string()),
            event_seq: Some(req.event_seq),
            event_timestamp: Some(req.timestamp),
            peer_pubkey_hex: Some(peer_pubkey_hex.trim().to_string()),
            signature_hex: Some(req.signature_hex.trim().to_string()),
            epoch,
            previous_bunker_state: orb_step.previous_state.max(prev_mesh_u8),
            new_bunker_state: if req.dry_run {
                orb_step.bunker_state.max(prev_mesh_u8)
            } else {
                orb_step.bunker_state.max(next_mesh_u8)
            },
            dry_run: req.dry_run,
            reason: req.reason.trim().to_string(),
            pid: req.pid,
            uid: req.uid,
            cgroup: req.cgroup.clone(),
            cmdline: req.cmdline.clone(),
            detail_sha256_hex: req.detail_sha256_hex.trim().to_string(),
            alert_delivered: false,
            alert_channels: Vec::new(),
            alert_error: None,
        };
        let snapshot_before_commit = serde_json::to_value(&*data).ok();
        data.log_bunker_incident(incident.clone());
        if let Err(e) = self.commit(&data).await {
            if let Some(prev_val) = snapshot_before_commit {
                if let Ok(restored) = serde_json::from_value::<Persisted>(prev_val) {
                    *data = restored;
                }
            }
            data.bunker_state = prev_bunker_u8;
            return Err(e);
        }
        drop(data);
        if !revoked_ids.is_empty() {
            let mut tokens = self.live_tokens.lock().await;
            for r in &revoked_ids {
                tokens.remove(&r.id);
            }
        }
        self.changed.notify_waiters();
        Ok((orb_step, incident))
    }

    pub async fn update_incident_alert_status(
        &self,
        id: Uuid,
        delivered: bool,
        channels: Vec<String>,
        error: Option<String>,
    ) {
        let mut data = self.data.lock().await;
        if let Some(item) = data.bunker_incidents.iter_mut().find(|i| i.id == id) {
            item.alert_delivered = delivered;
            item.alert_channels = channels;
            item.alert_error = error;
            self.save(&data).await;
        }
    }

    pub async fn by_requester(&self, owner: &str, requester: Uuid) -> Vec<PrivilegeRequest> {
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BunkerStepResponse {
    pub previous_state: u8,
    pub bunker_state: u8,
    pub revoke_all_jit_grants: bool,
    pub isolate_node_mesh: bool,
    pub revoked_grants_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerifyLeaseRequest {
    pub mission_id: Uuid,
    pub lease_token: String,
    pub target_host: String,
    #[serde(default)]
    pub requested_scope: Option<PrivilegeScope>,
    pub command: String,
    #[serde(default)]
    pub argv: Vec<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub exit_code: Option<i32>,
    #[serde(default)]
    pub duration_ms: Option<u64>,
    #[serde(default)]
    pub stdout_sha256: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerifyLeaseResponse {
    pub allow_exec: bool,
    pub require_force_cmd: bool,
    pub grant_id: Uuid,
    pub scope: PrivilegeScope,
    pub allowed_unit: Option<String>,
    pub expires_at: Option<DateTime<Utc>>,
    pub audit_entry_id: Uuid,
}

async fn agent_view(broker: &PrivilegeBroker, r: &PrivilegeRequest) -> Value {
    let now = Utc::now();
    let bunker = broker.bunker_state().await;
    let verdict = r.evaluate(now, true, r.scope, bunker);
    let lease_token = if verdict.allow_exec {
        broker.lease_token_for(r.id).await
    } else {
        None
    };
    json!({
        "request_id": r.id,
        "target_host": r.target_host,
        "scope": r.scope,
        "allowed_unit": r.allowed_unit,
        "session_scoped": r.session_scoped,
        "status": r.state,
        "reason": r.reason,
        "created_at": r.created_at,
        "expires_at": r.expires_at,
        "allow_exec": verdict.allow_exec,
        "require_force_cmd": verdict.require_force_cmd,
        "lease_token": lease_token,
        "usage_hint": if verdict.allow_exec {
            if r.target_host == "self" {
                json!("Use `ORB_JIT_LEASE=<lease_token> orb-sudo <command>` to execute as root on this node (every command is JSON-audited in Core).")
            } else {
                json!(format!("Approved for {} on {} until session end / expiry.", r.scope.as_str(), r.target_host))
            }
        } else {
            Value::Null
        }
    })
}

fn decision_note(r: &PrivilegeRequest) -> String {
    match r.state {
        ApprovalState::Approved => format!(
            "Approved: {} access on {} until {} (session_scoped={}). Every privileged command is recorded in Core's JSON audit log.",
            r.scope.as_str(),
            r.target_host,
            r.expires_at.map(|t| t.to_rfc3339()).unwrap_or_default(),
            r.session_scoped,
        ),
        ApprovalState::Pending => format!(
            "Waiting for Thomas to approve with Touch ID / Face ID on his device (request {}).",
            r.id
        ),
        ApprovalState::Denied => {
            "Thomas declined this privilege request. Do not ask again for the same reason.".into()
        }
        ApprovalState::Expired => "The privilege request or grant expired.".into(),
        ApprovalState::Revoked => "This privilege grant was revoked.".into(),
    }
}

pub async fn handle_tool(
    state: &Arc<AppState>,
    p: &crate::control_mcp::gateway::Principal,
    name: &str,
    args: &Value,
) -> Result<Value, String> {
    let own = p
        .mission_id
        .ok_or("Privileged access tools are only available to mission-scoped sessions")?;
    let broker = store(state);
    match name {
        "list_privileged_access" => {
            let list = broker.by_requester(&p.sub, own).await;
            let mut views = Vec::with_capacity(list.len());
            for r in &list {
                views.push(agent_view(&broker, r).await);
            }
            Ok(json!({
                "bunker_state": broker.bunker_state().await as u8,
                "requests": views,
            }))
        }
        "revoke_privileged_access" => {
            let req_id = args
                .get("request_id")
                .and_then(Value::as_str)
                .and_then(|s| Uuid::parse_str(s.trim()).ok())
                .ok_or("request_id must be a valid UUID")?;
            // A mission may only drop its own grants; other missions' grants
            // are revoked by Thomas from a client.
            match broker.get(&p.sub, req_id).await {
                Some(r) if r.requester_mission_id == own => {}
                _ => return Err("Request not found".into()),
            }
            let r = broker.revoke(&p.sub, req_id).await?;
            Ok(agent_view(&broker, &r).await)
        }
        "request_privileged_access" => {
            let target_host = args
                .get("target_host")
                .and_then(Value::as_str)
                .unwrap_or("self");
            let scope_str = args
                .get("scope")
                .and_then(Value::as_str)
                .unwrap_or("root_exec");
            let scope = PrivilegeScope::from_str_opt(scope_str)
                .ok_or("scope must be one of \"ops_read\", \"service_deploy\", or \"root_exec\"")?;
            let reason = args
                .get("reason")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or("reason is required; it is shown on Thomas's Touch ID / Face ID prompt")?
                .chars()
                .take(500)
                .collect::<String>();
            let allowed_unit = args
                .get("allowed_unit")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(String::from);
            let session_scoped = args
                .get("session_scoped")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            let ttl_minutes = args.get("ttl_minutes").and_then(Value::as_i64);

            let user = AuthUser {
                id: p.sub.clone(),
                username: p.username.clone(),
            };
            let missions = state.control.get_or_spawn(&user).await.mission_store;
            let requester = missions
                .get_mission(own)
                .await
                .ok()
                .flatten()
                .ok_or("Mission no longer exists")?;

            let r = broker
                .request(NewPrivilegeRequest {
                    owner: p.sub.clone(),
                    owner_username: p.username.clone(),
                    requester: own,
                    requester_title: requester.title,
                    target_host: target_host.to_string(),
                    scope,
                    allowed_unit,
                    reason,
                    session_scoped,
                    ttl_minutes,
                })
                .await?;
            let r = if r.state.is_pending() {
                broker
                    .wait_decided(&p.sub, r.id, APPROVAL_WAIT)
                    .await
                    .unwrap_or(r)
            } else {
                r
            };
            let mut out = agent_view(&broker, &r).await;
            out["message"] = json!(decision_note(&r));
            Ok(out)
        }
        _ => Err("Unknown privilege tool".into()),
    }
}

pub fn tool_definitions() -> Vec<crate::control_mcp::ToolDefinition> {
    use crate::control_mcp::ToolDefinition;
    vec![
        ToolDefinition {
            name: "request_privileged_access".into(),
            description: "Request temporary root or privileged host/deploy access from Thomas via Touch ID / Face ID. \
                          Defaults to the duration of the current mission session (`session_scoped: true`) and is \
                          automatically revoked when the session ends. For local root (`target_host: \"self\"`), \
                          use `orb-sudo <cmd>` with the returned `lease_token` (zero SSH overhead, structured per-command \
                          JSON audit log in Core). For production backend deploys on `:3000`, request `scope: \"service_deploy\"` \
                          once and it covers the entire deploy/verify loop for the session."
                .into(),
            input_schema: json!({
                "type": "object",
                "required": ["reason"],
                "properties": {
                    "target_host": {
                        "type": "string",
                        "default": "self",
                        "description": "Target machine: \"self\" for local node root via orb-sudo, or a fleet host (e.g. \"agent-core\", \"ashur\", \"babylon\", \"nippur\", \"thomas-md\", \"dgx-spark\")."
                    },
                    "scope": {
                        "type": "string",
                        "enum": ["ops_read", "service_deploy", "root_exec"],
                        "default": "root_exec",
                        "description": "Privilege level: ops_read (read-only diagnostics), service_deploy (deploy/restart service), or root_exec (root command execution)."
                    },
                    "allowed_unit": {
                        "type": "string",
                        "description": "Optional systemd service/unit name when scope is service_deploy."
                    },
                    "session_scoped": {
                        "type": "boolean",
                        "default": true,
                        "description": "Bind grant lifetime to the current mission session (automatically reaped when session finishes)."
                    },
                    "ttl_minutes": {
                        "type": "integer",
                        "minimum": 1,
                        "maximum": MAX_TTL_MINUTES,
                        "description": "Max grant lifetime in minutes (default 240)."
                    },
                    "reason": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 500,
                        "description": "Why root/deploy access is needed; shown on Thomas's Touch ID / Face ID prompt."
                    }
                },
                "additionalProperties": false
            }),
        },
        ToolDefinition {
            name: "list_privileged_access".into(),
            description: "List this mission's privileged/root access requests, active lease tokens, and current Bunker Mode state.".into(),
            input_schema: json!({"type": "object", "properties": {}, "additionalProperties": false}),
        },
        ToolDefinition {
            name: "revoke_privileged_access".into(),
            description: "Revoke an active privileged/root access grant early as soon as your privileged task is complete.".into(),
            input_schema: json!({
                "type": "object",
                "required": ["request_id"],
                "properties": {
                    "request_id": {"type": "string", "format": "uuid"}
                },
                "additionalProperties": false
            }),
        },
    ]
}

async fn notify_requester(state: &Arc<AppState>, r: &PrivilegeRequest) {
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
        "[privilege-access] Request {} for {} on {} ({}): {}",
        r.id,
        r.scope.as_str(),
        r.target_host,
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
            source: Some("privilege-access".to_string()),
            respond: tx,
        })
        .await;
}

// ---------------------------------------------------------------- HTTP

type ApiError = (StatusCode, String);

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/", get(list))
        .route("/:id/approve", post(approve))
        .route("/:id/deny", post(deny))
        .route("/:id", delete(revoke))
        .route("/bunker", post(trigger_bunker))
        .route("/unbunker", post(unbunker))
}

/// Lease-authenticated endpoint called by `orb-privd` on worker nodes, and
/// node-Ed25519-authenticated canary tripwire endpoints called by worker
/// canary units (`orb-canary-mongo@.service`, `paloma-canary-audit-watch`).
pub fn public_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/privilege-access/verify-and-log", post(verify_and_log))
        .route("/api/bunker/tripwire", post(canary_tripwire))
        .route("/api/privilege-access/canary-trip", post(canary_tripwire))
}

fn parse_id(raw: &str) -> Result<Uuid, ApiError> {
    Uuid::parse_str(raw.trim()).map_err(|_| (StatusCode::BAD_REQUEST, "Invalid id".into()))
}

async fn list(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Json<Value> {
    let mut snap = store(&state).snapshot(&user.id).await;
    let (mesh_bunker, _) = super::mesh::current_effective_bunker_and_epoch(&state).await;
    if let Some(obj) = snap.as_object_mut() {
        let cur = obj.get("bunker_state").and_then(Value::as_u64).unwrap_or(0) as u8;
        obj.insert("bunker_state".into(), json!(cur.max(mesh_bunker)));
    }
    Json(snap)
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApprovePrivilegeBody {
    #[serde(default)]
    pub ttl_minutes: Option<i64>,
    #[serde(default)]
    pub session_scoped: Option<bool>,
}

async fn approve(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    AxumPath(id): AxumPath<String>,
    Json(body): Json<ApprovePrivilegeBody>,
) -> Result<Json<PrivilegeRequest>, ApiError> {
    let id = parse_id(&id)?;
    let r = store(&state)
        .approve(&user.id, id, body.ttl_minutes, body.session_scoped)
        .await
        .map_err(|e| (StatusCode::CONFLICT, e))?;
    notify_requester(&state, &r).await;
    Ok(Json(r))
}

async fn deny(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    AxumPath(id): AxumPath<String>,
) -> Result<Json<PrivilegeRequest>, ApiError> {
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
) -> Result<Json<PrivilegeRequest>, ApiError> {
    let id = parse_id(&id)?;
    store(&state)
        .revoke(&user.id, id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::CONFLICT, e))
}

async fn verify_and_log(
    State(state): State<Arc<AppState>>,
    Json(body): Json<VerifyLeaseRequest>,
) -> Result<Json<VerifyLeaseResponse>, ApiError> {
    store(&state)
        .verify_and_log_command(body)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::FORBIDDEN, e))
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BunkerTriggerBody {
    #[serde(default)]
    pub canary_tripped: bool,
    #[serde(default)]
    pub auth_failure_burst: bool,
    #[serde(default)]
    pub level: Option<u8>,
    #[serde(default)]
    pub reason: Option<String>,
}

fn bunker_state_label(code: u8) -> &'static str {
    match code {
        0 => "Normal (0)",
        1 => "SoftQuarantine (1)",
        2 => "HardLockdown (2)",
        _ => "SovereignDeadManTripped (3)",
    }
}

fn resolve_bunker_telegram_bot_token() -> Option<String> {
    for env_key in ["ORB_BUNKER_TELEGRAM_BOT_TOKEN", "TELEGRAM_BOT_TOKEN"] {
        if let Ok(val) = std::env::var(env_key) {
            let trimmed = val.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    for path in [
        "/etc/sandboxed-sh/hermes-assistant.env",
        "/etc/sandboxed-sh/hermes-assistant-dev.env",
    ] {
        if let Ok(contents) = std::fs::read_to_string(path) {
            for line in contents.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                if let Some((k, v)) = line.split_once('=') {
                    if k.trim() == "TELEGRAM_BOT_TOKEN" {
                        let v = v.trim().trim_matches('"').trim_matches('\'').trim();
                        if !v.is_empty() {
                            return Some(v.to_string());
                        }
                    }
                }
            }
        }
    }
    None
}

fn resolve_bunker_telegram_chat_id() -> i64 {
    std::env::var("ORB_BUNKER_TELEGRAM_CHAT_ID")
        .ok()
        .and_then(|s| s.trim().parse::<i64>().ok())
        .unwrap_or(1_139_694_048)
}

fn redact_forensic_cmdline(cmdline: Option<&str>) -> String {
    let Some(raw) = cmdline.map(str::trim).filter(|s| !s.is_empty()) else {
        return "-".into();
    };
    let mut parts = raw.split_whitespace();
    let first = parts.next().unwrap_or("-");
    let exe = first.rsplit('/').next().unwrap_or(first);
    let safe_exe: String = exe
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        .take(48)
        .collect();
    let arg_count = parts.count();
    if arg_count > 0 {
        format!(
            "{} (+{} redacted args)",
            if safe_exe.is_empty() { "proc" } else { &safe_exe },
            arg_count
        )
    } else if safe_exe.is_empty() {
        "proc".into()
    } else {
        safe_exe
    }
}

fn sanitize_alert_error(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len().min(240));
    for token in raw.split_whitespace() {
        let word = if token.contains("api.telegram.org/bot") || token.contains("http://") || token.contains("https://") {
            "<redacted-url>"
        } else {
            token
        };
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(word);
        if out.len() >= 200 {
            break;
        }
    }
    out
}

/// Dispatches an out-of-band Bunker / Canary alert via Telegram (`send_telegram_text`)
/// and optional webhook (`ORB_BUNKER_ALERT_WEBHOOK_URL`), returning
/// `(delivered, channels_succeeded, error_summary)` and updating the incident record.
///
/// Redacts raw command-line arguments (`redact_forensic_cmdline`) so secrets or tokens
/// appearing in process arguments are never exported to external messaging providers.
pub async fn dispatch_bunker_alert(
    state: &Arc<AppState>,
    incident: &BunkerIncidentEntry,
) -> (bool, Vec<String>, Option<String>) {
    let mut channels = Vec::new();
    let mut errors = Vec::new();

    let dry_tag = if incident.dry_run { " [DRY-RUN TEST]" } else { "" };
    let host = incident.peer_name.as_deref().unwrap_or("agent-core");
    let kind = incident.canary_kind.as_deref().unwrap_or(&incident.source);
    let redacted_cmd = redact_forensic_cmdline(incident.cmdline.as_deref());
    let mut text = format!(
        "🚨 **[PALOMA BUNKER ALERT]{dry_tag}**\n\
         • **Incident ID**: `{}`\n\
         • **Source**: `{}`\n\
         • **Transition**: `{}` -> `{}` (epoch `{}`)\n\
         • **Host / Peer**: `{host}`\n\
         • **Trigger**: `{kind}`\n\
         • **Reason**: {}\n\
         • **Evidence SHA-256**: `{}`",
        incident.id,
        incident.source,
        bunker_state_label(incident.previous_bunker_state),
        bunker_state_label(incident.new_bunker_state),
        incident.epoch,
        incident.reason,
        incident.detail_sha256_hex,
    );
    if incident.pid.is_some()
        || incident.uid.is_some()
        || incident.cgroup.is_some()
        || incident.cmdline.is_some()
    {
        text.push_str(&format!(
            "\n• **Forensics**: pid=`{:?}` uid=`{:?}` cgroup=`{}` proc=`{redacted_cmd}`",
            incident.pid,
            incident.uid,
            incident.cgroup.as_deref().unwrap_or("-"),
        ));
    }

    if let Some(token) = resolve_bunker_telegram_bot_token() {
        let base_url = format!("https://api.telegram.org/bot{token}");
        let chat_id = resolve_bunker_telegram_chat_id();
        match super::telegram::send_telegram_text(&state.http_client, &base_url, chat_id, &text, None)
            .await
        {
            Ok(_) => channels.push(format!("telegram:{chat_id}")),
            Err(e) => errors.push(format!("telegram: {}", sanitize_alert_error(&e))),
        }
    } else {
        errors.push("telegram: no TELEGRAM_BOT_TOKEN configured".into());
    }

    if let Ok(webhook_url) = std::env::var("ORB_BUNKER_ALERT_WEBHOOK_URL") {
        let webhook_url = webhook_url.trim();
        if !webhook_url.is_empty() {
            let mut safe_incident = incident.clone();
            if safe_incident.cmdline.is_some() {
                safe_incident.cmdline = Some(redacted_cmd);
            }
            match state
                .http_client
                .post(webhook_url)
                .timeout(Duration::from_secs(5))
                .json(&safe_incident)
                .send()
                .await
            {
                Ok(resp) if resp.status().is_success() => channels.push("webhook".into()),
                Ok(resp) => errors.push(format!("webhook HTTP {}", resp.status())),
                Err(e) => errors.push(format!("webhook: {}", sanitize_alert_error(&e.to_string()))),
            }
        }
    }

    let delivered = !channels.is_empty();
    let err_summary = if errors.is_empty() {
        None
    } else {
        Some(errors.join("; "))
    };
    store(state)
        .update_incident_alert_status(incident.id, delivered, channels.clone(), err_summary.clone())
        .await;
    (delivered, channels, err_summary)
}

/// Called by `src/api/mesh.rs` when `post_heartbeat` transitions `MeshBunkerState`
/// (e.g., Sovereign Dead-Man's Switch escalation or recovery).
pub async fn record_and_alert_mesh_transition(
    state: &Arc<AppState>,
    peer_name: &str,
    previous_state: u8,
    next_state: u8,
    reason: &str,
) {
    let (_, epoch) = super::mesh::current_effective_bunker_and_epoch(state).await;
    let entry = BunkerIncidentEntry {
        id: Uuid::new_v4(),
        at: Utc::now(),
        source: "sovereign_deadman".into(),
        peer_name: Some(peer_name.to_string()),
        canary_kind: Some("mesh_heartbeat".into()),
        event_seq: None,
        event_timestamp: None,
        peer_pubkey_hex: None,
        signature_hex: None,
        epoch,
        previous_bunker_state: previous_state,
        new_bunker_state: next_state,
        dry_run: false,
        reason: reason.to_string(),
        pid: None,
        uid: None,
        cgroup: None,
        cmdline: None,
        detail_sha256_hex: sha256_hex(reason),
        alert_delivered: false,
        alert_channels: Vec::new(),
        alert_error: None,
    };
    let _ = store(state).record_bunker_incident(entry.clone()).await;
    let _ = dispatch_bunker_alert(state, &entry).await;
}

async fn canary_tripwire(
    State(state): State<Arc<AppState>>,
    Json(req): Json<super::mesh::CanaryTripwireRequest>,
) -> Result<Json<Value>, ApiError> {
    let broker = store(&state);

    // 1. Validate peer, timestamp, digest, and Ed25519 signature WITHOUT consuming
    //    `MeshStore.canary_replay` yet.
    let (prev_mesh, mesh_transition, epoch, peer_pubkey_hex, already_replayed) =
        super::mesh::preview_canary_tripwire(&state, &req).await?;

    // 2. Check if `(peer_name, event_seq)` was already recorded in `PrivilegeBroker`:
    //    - Reject any conflicting payload (`dry_run`, `timestamp`, `detail_sha256_hex`,
    //      `peer_pubkey_hex`, `signature_hex` mismatch) with `409 Conflict`.
    //    - If an identical authenticated payload was already persisted in `PrivilegeBroker`
    //      (e.g., crash after `PrivilegeBroker` commit and before `MeshStore` or alert delivery),
    //      reconcile `MeshStore` and alert delivery idempotently.
    match broker.match_canary_incident(&req, &peer_pubkey_hex).await {
        Err(conflict) => return Err((StatusCode::CONFLICT, conflict)),
        Ok(Some(existing)) => {
            if !already_replayed {
                super::mesh::verify_and_apply_canary_tripwire(&state, &req).await?;
            }
            if !existing.dry_run && (broker.bunker_state().await as u8) < 2 {
                broker
                    .step_bunker(
                        true,
                        false,
                        2,
                        false,
                        Some(format!(
                            "canary_tripwire_reconcile:{}:{}:{}",
                            req.peer_name, req.canary_kind, req.reason
                        )),
                    )
                    .await
                    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
            }
            let (delivered, channels, err) = if existing.alert_delivered {
                (
                    existing.alert_delivered,
                    existing.alert_channels.clone(),
                    existing.alert_error.clone(),
                )
            } else {
                dispatch_bunker_alert(&state, &existing).await
            };
            return Ok(Json(json!({
                "admitted": true,
                "idempotent_retry": true,
                "incident_id": existing.id,
                "dry_run": existing.dry_run,
                "peer_name": req.peer_name,
                "canary_kind": req.canary_kind,
                "event_seq": req.event_seq,
                "epoch": existing.epoch,
                "alert_delivered": delivered,
                "alert_channels": channels,
                "alert_error": err,
            })));
        }
        Ok(None) => {
            if already_replayed {
                return Err((
                    StatusCode::UNAUTHORIZED,
                    "replayed or zero event_seq rejected by ReplayWindow64".into(),
                ));
            }
        }
    }

    // 3. Durably escalate `PrivilegeBroker` and record the `BunkerIncidentEntry` FIRST
    //    in a single atomic commit before consuming `MeshStore.canary_replay`.
    let (orb_step, incident) = broker
        .escalate_and_record_canary_incident(
            &req,
            prev_mesh as u8,
            mesh_transition.next_state as u8,
            epoch,
            &peer_pubkey_hex,
        )
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    // 4. Advance `MeshStore.canary_replay` and persist `MeshStore` bunker state.
    let (_, mesh_transition, epoch) =
        super::mesh::verify_and_apply_canary_tripwire(&state, &req).await?;

    // 5. Dispatch redacted out-of-band alert and update incident delivery status.
    let (alert_delivered, alert_channels, alert_error) =
        dispatch_bunker_alert(&state, &incident).await;

    Ok(Json(json!({
        "admitted": true,
        "incident_id": incident.id,
        "dry_run": req.dry_run,
        "peer_name": req.peer_name,
        "canary_kind": req.canary_kind,
        "event_seq": req.event_seq,
        "epoch": epoch,
        "orb_bunker": orb_step,
        "mesh_bunker": mesh_transition,
        "alert_delivered": alert_delivered,
        "alert_channels": alert_channels,
        "alert_error": alert_error,
    })))
}

async fn trigger_bunker(
    State(state): State<Arc<AppState>>,
    Json(body): Json<BunkerTriggerBody>,
) -> Result<Json<BunkerStepResponse>, ApiError> {
    let manual = body.level.unwrap_or(1).clamp(1, 2);
    let reason = body
        .reason
        .clone()
        .unwrap_or_else(|| format!("Operator manual Bunker Mode trigger (level {manual})"));
    let (prev_mesh, mesh_transition, epoch) = super::mesh::sync_orb_bunker_transition(
        &state,
        body.canary_tripped,
        body.auth_failure_burst,
        manual,
        false,
    )
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let mut resp = store(&state)
        .step_bunker(
            body.canary_tripped,
            body.auth_failure_burst,
            manual,
            false,
            Some(reason.clone()),
        )
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    resp.previous_state = resp.previous_state.max(prev_mesh as u8);
    resp.bunker_state = resp.bunker_state.max(mesh_transition.next_state as u8);
    let incident = BunkerIncidentEntry {
        id: Uuid::new_v4(),
        at: Utc::now(),
        source: "operator_manual".into(),
        peer_name: Some("agent-core".into()),
        canary_kind: Some(format!("manual_level_{manual}")),
        event_seq: None,
        event_timestamp: None,
        peer_pubkey_hex: None,
        signature_hex: None,
        epoch,
        previous_bunker_state: resp.previous_state,
        new_bunker_state: resp.bunker_state,
        dry_run: false,
        reason: reason.clone(),
        pid: None,
        uid: None,
        cgroup: None,
        cmdline: None,
        detail_sha256_hex: sha256_hex(&reason),
        alert_delivered: false,
        alert_channels: Vec::new(),
        alert_error: None,
    };
    store(&state)
        .record_bunker_incident(incident.clone())
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let _ = dispatch_bunker_alert(&state, &incident).await;
    Ok(Json(resp))
}

async fn unbunker(
    State(state): State<Arc<AppState>>,
) -> Result<Json<BunkerStepResponse>, ApiError> {
    let (prev_mesh, mesh_transition, epoch) =
        super::mesh::sync_orb_bunker_transition(&state, false, false, 0, true)
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let mut resp = store(&state)
        .step_bunker(false, false, 0, true, Some("biometric_unbunker".into()))
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    resp.previous_state = resp.previous_state.max(prev_mesh as u8);
    resp.bunker_state = resp.bunker_state.max(mesh_transition.next_state as u8);
    let reason = if resp.bunker_state == 0 {
        "Operator biometric unbunker approved; fleet restored to Normal (0)".to_string()
    } else {
        format!(
            "Operator biometric unbunker approved for PrivilegeBroker, but mesh remains in {} pending fresh dgx-spark heartbeat",
            bunker_state_label(resp.bunker_state)
        )
    };
    let incident = BunkerIncidentEntry {
        id: Uuid::new_v4(),
        at: Utc::now(),
        source: "biometric_unbunker".into(),
        peer_name: Some("agent-core".into()),
        canary_kind: Some("biometric_unbunker".into()),
        event_seq: None,
        event_timestamp: None,
        peer_pubkey_hex: None,
        signature_hex: None,
        epoch,
        previous_bunker_state: resp.previous_state,
        new_bunker_state: resp.bunker_state,
        dry_run: false,
        reason: reason.clone(),
        pid: None,
        uid: None,
        cgroup: None,
        cmdline: None,
        detail_sha256_hex: sha256_hex(&reason),
        alert_delivered: false,
        alert_channels: Vec::new(),
        alert_error: None,
    };
    store(&state)
        .record_bunker_incident(incident.clone())
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let _ = dispatch_bunker_alert(&state, &incident).await;
    Ok(Json(resp))
}

pub async fn describe_for_approval(
    state: &Arc<AppState>,
    owner: &str,
    id: &str,
    action: &str,
    ttl_minutes: Option<i64>,
) -> Result<String, String> {
    let id = Uuid::parse_str(id).map_err(|_| "Unknown privilege request")?;
    let r = store(state)
        .get(owner, id)
        .await
        .ok_or("Unknown privilege request")?;
    let who = r
        .requester_title
        .clone()
        .unwrap_or_else(|| format!("mission {}", &r.requester_mission_id.to_string()[..8]));
    let mins = clamp_ttl_minutes(ttl_minutes.or(Some(r.ttl_minutes)));
    Ok(match action {
        "approve" => format!(
            "Grant {} {} on {} for session (max {} m): {}",
            super::approvals::quoted(&who),
            r.scope.as_str().to_uppercase(),
            super::approvals::quoted(&r.target_host),
            mins,
            super::approvals::quoted(&r.reason),
        ),
        _ => format!(
            "Decline {} {} on {}",
            super::approvals::quoted(&who),
            r.scope.as_str(),
            super::approvals::quoted(&r.target_host),
        ),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_broker() -> PrivilegeBroker {
        let dir = std::env::temp_dir().join(format!("privilege-broker-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        PrivilegeBroker::open(dir.join("privilege_access.json"))
    }

    #[tokio::test]
    async fn grant_lifecycle_audit_log_session_reap_and_bunker_lockdown() {
        let broker = temp_broker();
        let mission_id = Uuid::new_v4();
        let req = broker
            .request(NewPrivilegeRequest {
                owner: "thomas".into(),
                owner_username: "thomas".into(),
                requester: mission_id,
                requester_title: Some("Fleet Kernel Upgrade".into()),
                target_host: "self".into(),
                scope: PrivilegeScope::RootExec,
                allowed_unit: None,
                reason: "Upgrade Ubuntu kernel and fix permissions".into(),
                session_scoped: true,
                ttl_minutes: Some(60),
            })
            .await
            .unwrap();
        assert_eq!(req.state, ApprovalState::Pending);

        let approved = broker
            .approve("thomas", req.id, Some(60), Some(true))
            .await
            .unwrap();
        assert_eq!(approved.state, ApprovalState::Approved);
        let token = broker.lease_token_for(req.id).await.unwrap();

        // Execute and log a root command via orb-privd
        let verified = broker
            .verify_and_log_command(VerifyLeaseRequest {
                mission_id,
                lease_token: token.clone(),
                target_host: "self".into(),
                requested_scope: Some(PrivilegeScope::RootExec),
                command: "apt-get update && apt-get install -y linux-generic".into(),
                argv: vec!["apt-get".into(), "update".into()],
                cwd: Some("/root".into()),
                exit_code: Some(0),
                duration_ms: Some(1420),
                stdout_sha256: Some(
                    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".into(),
                ),
            })
            .await
            .unwrap();
        assert!(verified.allow_exec);
        assert!(!verified.require_force_cmd);

        let snap = broker.snapshot("thomas").await;
        assert_eq!(snap["command_audit"].as_array().unwrap().len(), 1);
        assert_eq!(
            snap["command_audit"][0]["command"].as_str(),
            Some("apt-get update && apt-get install -y linux-generic")
        );

        // Session reap immediately revokes the lease token
        let reaped = broker
            .reap_mission_grants(mission_id, "mission_completed")
            .await;
        assert_eq!(reaped, 1);
        assert!(broker.lease_token_for(req.id).await.is_none());
        assert!(broker
            .verify_and_log_command(VerifyLeaseRequest {
                mission_id,
                lease_token: token,
                target_host: "self".into(),
                requested_scope: Some(PrivilegeScope::RootExec),
                command: "id".into(),
                argv: vec!["id".into()],
                cwd: None,
                exit_code: None,
                duration_ms: None,
                stdout_sha256: None,
            })
            .await
            .is_err());

        // Bunker mode blocks new requests until biometric unbunker
        let b = broker
            .step_bunker(true, false, 2, false, Some("canary_tripped".into()))
            .await
            .unwrap();
        assert_eq!(b.bunker_state, 2);
        assert!(broker
            .request(NewPrivilegeRequest {
                owner: "thomas".into(),
                owner_username: "thomas".into(),
                requester: Uuid::new_v4(),
                requester_title: None,
                target_host: "self".into(),
                scope: PrivilegeScope::OpsRead,
                allowed_unit: None,
                reason: "test".into(),
                session_scoped: true,
                ttl_minutes: Some(15),
            })
            .await
            .is_err());

        let unbunkered = broker
            .step_bunker(false, false, 0, true, None)
            .await
            .unwrap();
        assert_eq!(unbunkered.bunker_state, 0);
    }

    fn deploy_request(mission: Uuid, scope: PrivilegeScope) -> NewPrivilegeRequest {
        NewPrivilegeRequest {
            owner: "thomas".into(),
            owner_username: "thomas".into(),
            requester: mission,
            requester_title: None,
            target_host: "agent-core".into(),
            scope,
            allowed_unit: None,
            reason: "deploy".into(),
            session_scoped: true,
            ttl_minutes: Some(60),
        }
    }

    fn verify(mission_id: Uuid, lease_token: String) -> VerifyLeaseRequest {
        VerifyLeaseRequest {
            mission_id,
            lease_token,
            target_host: "agent-core".into(),
            requested_scope: None,
            command: "systemctl status orb-core".into(),
            argv: vec![],
            cwd: None,
            exit_code: None,
            duration_ms: None,
            stdout_sha256: None,
        }
    }

    #[tokio::test]
    async fn unapproved_expired_and_other_session_grants_are_refused() {
        let broker = temp_broker();
        let mission = Uuid::new_v4();
        let other = Uuid::new_v4();
        let svc = "orb-core.service";

        // Pending: no deploy, no lease.
        let req = broker
            .request(deploy_request(mission, PrivilegeScope::ServiceDeploy))
            .await
            .unwrap();
        assert!(broker.has_active_deploy_grant(mission, svc).await.is_none());
        assert!(broker.lease_token_for(req.id).await.is_none());

        // Approved: covers this session's deploy loop, not another session's.
        broker.approve("thomas", req.id, None, None).await.unwrap();
        let token = broker.lease_token_for(req.id).await.unwrap();
        assert_eq!(
            broker.has_active_deploy_grant(mission, svc).await,
            Some(req.id)
        );
        assert_eq!(
            broker.has_active_deploy_grant(mission, svc).await,
            Some(req.id)
        );
        assert!(broker.has_active_deploy_grant(other, svc).await.is_none());
        assert!(broker
            .verify_and_log_command(verify(mission, token.clone()))
            .await
            .is_ok());
        assert!(broker
            .verify_and_log_command(verify(other, token.clone()))
            .await
            .is_err());
        assert!(broker
            .verify_and_log_command(verify(mission, "orb-jit-guess".into()))
            .await
            .is_err());

        // A read-only grant never satisfies the deploy gate.
        let ro = broker
            .request(deploy_request(other, PrivilegeScope::OpsRead))
            .await
            .unwrap();
        broker.approve("thomas", ro.id, None, None).await.unwrap();
        assert!(broker.has_active_deploy_grant(other, svc).await.is_none());

        // Expired: refused and pruned.
        {
            let mut data = broker.data.lock().await;
            let r = data.requests.iter_mut().find(|r| r.id == req.id).unwrap();
            r.expires_at = Some(Utc::now() - chrono::Duration::seconds(1));
        }
        assert!(broker.has_active_deploy_grant(mission, svc).await.is_none());
        assert!(broker
            .verify_and_log_command(verify(mission, token))
            .await
            .is_err());
        assert_eq!(
            broker.get("thomas", req.id).await.unwrap().state,
            ApprovalState::Expired
        );
    }

    #[tokio::test]
    async fn bunker_incident_serialization_and_forensic_redaction() {
        assert_eq!(
            redact_forensic_cmdline(Some("/usr/bin/curl -H Authorization:Bearer_secret https://x")),
            "curl (+3 redacted args)"
        );
        assert_eq!(redact_forensic_cmdline(Some("/usr/bin/nc")), "nc");
        assert_eq!(redact_forensic_cmdline(None), "-");
        assert_eq!(
            sanitize_alert_error("POST https://api.telegram.org/bot12345:SECRET/sendMessage failed"),
            "POST <redacted-url> failed"
        );

        let broker = temp_broker();
        let entry = BunkerIncidentEntry {
            id: Uuid::new_v4(),
            at: Utc::now(),
            source: "canary_tripwire".into(),
            peer_name: Some("nippur".into()),
            canary_kind: Some("mongo_27017".into()),
            event_seq: Some(42),
            event_timestamp: Some(1_700_000_000),
            peer_pubkey_hex: Some("11".repeat(32)),
            signature_hex: Some("22".repeat(64)),
            epoch: 9,
            previous_bunker_state: 0,
            new_bunker_state: 2,
            dry_run: false,
            reason: "TCP probe to 127.0.0.1:27017".into(),
            pid: Some(1234),
            uid: Some(1000),
            cgroup: Some("/system.slice/sandboxed-node.service".into()),
            cmdline: Some("python3 -c import_pymongo_secret".into()),
            detail_sha256_hex: "abcd".repeat(16),
            alert_delivered: false,
            alert_channels: vec![],
            alert_error: None,
        };
        broker.record_bunker_incident(entry.clone()).await.unwrap();
        let mut req_payload = crate::api::mesh::CanaryTripwireRequest {
            peer_name: "nippur".into(),
            canary_kind: "mongo_27017".into(),
            event_seq: 42,
            timestamp: 1_700_000_000,
            dry_run: false,
            detail_sha256_hex: "ABCD".repeat(16),
            signature_hex: "22".repeat(64),
            reason: None,
            pid: None,
            uid: None,
            cgroup: None,
            cmdline: None,
        };
        let found = broker
            .match_canary_incident(&req_payload, &"11".repeat(32))
            .await
            .expect("no collision")
            .expect("incident must be found case-insensitively by digest");
        assert_eq!(found.id, entry.id);

        // A conflicting retry (e.g. dry_run=true on the same (peer_name, event_seq)) is rejected.
        req_payload.dry_run = true;
        assert!(broker
            .match_canary_incident(&req_payload, &"11".repeat(32))
            .await
            .is_err());

        let snap = broker.snapshot("thomas").await;
        let inc_json = &snap["bunker_incidents"][0];
        assert_eq!(inc_json["previous_bunker_state"].as_u64(), Some(0));
        assert_eq!(inc_json["new_bunker_state"].as_u64(), Some(2));
        assert_eq!(inc_json["epoch"].as_u64(), Some(9));
    }
}
