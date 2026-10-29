//! Mission secrets broker.
//!
//! Missions never hold the Bitwarden machine token. They ask Core through the
//! `secret_*` MCP tools; Core reads Bitwarden on their behalf when the
//! mission's Paloma project has default access to the secret's Bitwarden
//! project, or when the operator approved a grant for that mission. Writes
//! always wait for operator approval.
//!
//! Grants, pending requests and the read audit log persist in
//! `<working_dir>/.sandboxed-sh/secret_broker.json`. Secret values are never
//! stored there, except a pending write's value, which is encrypted with the
//! backend's `env_crypto` key and dropped once the request is resolved.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::Mutex;
use uuid::Uuid;

use super::bitwarden::{self, BitwardenSecretDetail, BitwardenSecretSummary};
use super::routes::AppState;
use crate::library::env_crypto;

/// Default lifetime of an approved grant.
pub const DEFAULT_GRANT_TTL_HOURS: i64 = 24;
/// Pending requests nobody answered expire after this long.
const REQUEST_TTL_HOURS: i64 = 24;
/// How long a tool call waits for the operator before returning `pending`.
/// Stays under the MCP client's 30 s HTTP timeout.
const APPROVAL_WAIT: Duration = Duration::from_secs(20);
const AUDIT_LIMIT: usize = 500;
const LIST_CACHE_TTL: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum GrantScope {
    Secret { key: String },
    Project { project_id: String },
    All,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Grant {
    pub id: Uuid,
    #[serde(default)]
    pub mission_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requester: Option<approval_flow::RequesterSubject>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requester_label: Option<String>,
    #[serde(default)]
    pub mission_title: Option<String>,
    #[serde(default)]
    pub paloma_project: Option<String>,
    pub scope: GrantScope,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

impl Grant {
    pub fn subject(&self) -> approval_flow::RequesterSubject {
        self.requester.clone().unwrap_or_else(|| {
            approval_flow::RequesterSubject::mission(self.mission_id.unwrap_or_else(Uuid::nil))
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RequestKind {
    Read,
    Write,
    Delete,
    Move,
}

/// Request state: the shared approval state machine (`rejected` in older
/// files reads as `denied`).
pub use super::approval_flow::ApprovalState as RequestStatus;
use super::approval_flow::{self, ApprovalEvent};
use super::approval_queue::{self, ApprovalItem, BatchRef};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecretRequest {
    pub id: Uuid,
    pub kind: RequestKind,
    pub status: RequestStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    #[serde(default)]
    pub mission_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requester: Option<approval_flow::RequesterSubject>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requester_label: Option<String>,
    #[serde(default)]
    pub mission_title: Option<String>,
    #[serde(default)]
    pub paloma_project: Option<String>,
    /// Secret name asked for (read of one secret, or the write target).
    #[serde(default)]
    pub key: Option<String>,
    /// Bitwarden project asked for (project read, or write destination).
    #[serde(default)]
    pub project_id: Option<String>,
    /// `true` when a read asks for every project.
    #[serde(default)]
    pub all_projects: bool,
    pub reason: String,
    #[serde(default)]
    pub note: Option<String>,
    /// HMAC-SHA256 (backend key) of a write's value, to tell a retry from a new value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value_sha256: Option<String>,
    /// Encrypted value of a pending write. Never serialized to clients.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encrypted_value: Option<String>,
    /// Destination project of a move.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_project_id: Option<String>,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub resolved_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub error: Option<String>,
}

impl SecretRequest {
    pub fn subject(&self) -> approval_flow::RequesterSubject {
        self.requester.clone().unwrap_or_else(|| {
            approval_flow::RequesterSubject::mission(self.mission_id.unwrap_or_else(Uuid::nil))
        })
    }

    /// Client view: the encrypted value of a write never leaves Core.
    pub fn public(&self) -> Value {
        let mut v = serde_json::to_value(self).unwrap_or_default();
        if let Some(o) = v.as_object_mut() {
            o.remove("encrypted_value");
            o.remove("value_sha256");
            o.remove("owner");
        }
        v
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEntry {
    pub at: DateTime<Utc>,
    #[serde(default)]
    pub mission_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requester: Option<approval_flow::RequesterSubject>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requester_label: Option<String>,
    #[serde(default)]
    pub paloma_project: Option<String>,
    pub key: String,
    #[serde(default)]
    pub project_id: Option<String>,
    /// `default`, `grant`, `write`, `delete`, or `move`.
    pub via: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Persisted {
    #[serde(default)]
    grants: Vec<Grant>,
    #[serde(default)]
    requests: Vec<SecretRequest>,
    #[serde(default)]
    audit: Vec<AuditEntry>,
}

pub struct SecretBroker {
    path: PathBuf,
    data: Mutex<Persisted>,
    list_cache: Mutex<Option<(Instant, Vec<BitwardenSecretSummary>)>>,
    changed: tokio::sync::Notify,
    /// One approve/reject at a time, so a request is never acted on twice.
    resolving: Mutex<()>,
}

static BROKER: OnceLock<Arc<SecretBroker>> = OnceLock::new();

pub fn broker(state: &AppState) -> Arc<SecretBroker> {
    BROKER
        .get_or_init(|| {
            let path = state
                .config
                .working_dir
                .join(".sandboxed-sh")
                .join("secret_broker.json");
            let data = std::fs::read_to_string(&path)
                .ok()
                .and_then(|t| serde_json::from_str(&t).ok())
                .unwrap_or_default();
            Arc::new(SecretBroker {
                path,
                data: Mutex::new(data),
                list_cache: Mutex::new(None),
                changed: tokio::sync::Notify::new(),
                resolving: Mutex::new(()),
            })
        })
        .clone()
}

/// What a mission may read without asking.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Access {
    pub all: bool,
    pub projects: Vec<String>,
    pub keys: Vec<String>,
}

impl Access {
    pub fn allows(&self, key: &str, project_id: Option<&str>) -> bool {
        self.all
            || self.keys.iter().any(|k| k == key)
            || project_id.is_some_and(|p| self.projects.iter().any(|x| x == p))
    }
}

/// Default access of a Paloma project. Before `default_access` existed, the
/// single `project_bindings` entry played that role; keep honoring it.
pub fn default_projects(
    bw: &crate::settings::BitwardenSettings,
    slug: Option<&str>,
) -> Vec<String> {
    let Some(slug) = slug.map(str::trim).filter(|s| !s.is_empty()) else {
        return Vec::new();
    };
    if let Some(list) = bw.default_access.get(slug) {
        return list.clone();
    }
    bw.project_bindings
        .get(slug)
        .map(|id| vec![id.clone()])
        .unwrap_or_default()
}

fn grant_access(
    defaults: Vec<String>,
    grants: &[Grant],
    subject: &approval_flow::RequesterSubject,
    now: DateTime<Utc>,
) -> Access {
    let mut access = Access {
        all: false,
        projects: defaults,
        keys: Vec::new(),
    };
    for g in grants
        .iter()
        .filter(|g| g.subject().same_actor(subject) && g.expires_at > now)
    {
        match &g.scope {
            GrantScope::All => access.all = true,
            GrantScope::Project { project_id } => access.projects.push(project_id.clone()),
            GrantScope::Secret { key } => access.keys.push(key.clone()),
        }
    }
    access
}

/// Identity of the calling mission or external session, from the signed MCP session.
#[derive(Debug, Clone)]
pub struct Caller {
    pub owner: String,
    pub subject: approval_flow::RequesterSubject,
    pub mission_title: Option<String>,
    pub paloma_project: Option<String>,
    /// True when the calling mission executes on an untrusted `managed-*` VM.
    pub on_managed_node: bool,
}

/// Cloud-compute provider credentials reserved exclusively for Core's native
/// `ManagedManager` (`spawn_managed_machine`, `start_mission(auto-managed:...)`).
/// Agents never receive raw cloud-compute API keys over `secret_get` because
/// direct provider API calls bypass Core's ownership tracking, daily spend
/// caps, concurrency limits, and idle/orphan reaper.
pub fn is_core_reserved_compute_secret(key: &str) -> bool {
    matches!(
        key.trim().to_ascii_uppercase().as_str(),
        "BOAT_API_KEY"
            | "HETZNER_CLOUD_APIKEY"
            | "HCLOUD_TOKEN"
            | "SCALEWAY_SECRET_KEY"
            | "SCALEWAY_KEY_ID"
            | "SCW_SECRET_KEY"
            | "SCW_ACCESS_KEY"
            | "VASTAI_API_KEY"
            | "VAST_API_KEY"
            | "RUNPOD_API_KEY"
            | "COLAB_API_DOTENV_PRIVATE_KEY"
    )
}

/// Secrets safe to deliver to an untrusted `managed-*` compute worker when the
/// mission's project/grant authorizes them. All other vault secrets stay on
/// trusted static nodes or Core.
pub fn is_allowlisted_managed_secret(key: &str) -> bool {
    matches!(
        key.trim().to_ascii_uppercase().as_str(),
        "GITHUB_TOKEN" | "GH_TOKEN"
    )
}

/// Formal kernel admission gate (`orb_compute_secret_gate`) deciding whether
/// `secret_get` may deliver `key` to `caller`.
pub fn admits_secret_delivery(key: &str, caller_on_managed_node: bool) -> bool {
    crate::orb_spec::compute_secret_admit(crate::orb_spec::ComputeSecretInput {
        is_core_reserved_compute_key: is_core_reserved_compute_secret(key),
        caller_on_managed_node,
        is_allowlisted_managed_secret: is_allowlisted_managed_secret(key),
        operator_break_glass: false,
    })
}

impl SecretBroker {
    async fn save(&self, data: &Persisted) {
        if let Err(e) = approval_flow::persist_private(&self.path, data).await {
            tracing::warn!("secret broker state not saved: {e}");
        }
    }

    /// Drop expired grants and expire stale pending requests.
    fn prune(data: &mut Persisted, now: DateTime<Utc>) {
        data.grants.retain(|g| g.expires_at > now);
        for r in data.requests.iter_mut() {
            if r.status.is_pending()
                && approval_flow::pending_timed_out(
                    r.created_at,
                    now,
                    chrono::Duration::hours(REQUEST_TTL_HOURS),
                )
            {
                r.status = RequestStatus::Expired;
                r.resolved_at = Some(now);
                r.encrypted_value = None;
            }
        }
        // Keep the last 200 resolved requests for the history view.
        let resolved = data
            .requests
            .iter()
            .filter(|r| r.status != RequestStatus::Pending)
            .count();
        if resolved > 200 {
            let mut drop = resolved - 200;
            data.requests.retain(|r| {
                if drop > 0 && r.status != RequestStatus::Pending {
                    drop -= 1;
                    false
                } else {
                    true
                }
            });
        }
    }

    pub async fn access_for(&self, state: &AppState, caller: &Caller) -> Access {
        if caller.subject.is_external()
            && super::privilege_broker::store(state).bunker_state().await
                >= super::privilege_broker::BunkerState::SoftQuarantine
        {
            return Access {
                all: false,
                projects: Vec::new(),
                keys: Vec::new(),
            };
        }
        let bw = state.settings.get_bitwarden().await;
        let defaults = default_projects(&bw, caller.paloma_project.as_deref());
        let data = self.data.lock().await;
        grant_access(defaults, &data.grants, &caller.subject, Utc::now())
    }

    pub async fn list_all(
        &self,
        state: &Arc<AppState>,
        fresh: bool,
    ) -> Result<Vec<BitwardenSecretSummary>, String> {
        let mut cache = self.list_cache.lock().await;
        if !fresh {
            if let Some((at, list)) = cache.as_ref() {
                if at.elapsed() < LIST_CACHE_TTL {
                    return Ok(list.clone());
                }
            }
        }
        let list = bitwarden::list_all_secrets(state)
            .await
            .map_err(|(_, e)| e)?;
        *cache = Some((Instant::now(), list.clone()));
        Ok(list)
    }

    pub async fn invalidate_list(&self) {
        *self.list_cache.lock().await = None;
    }

    async fn audit(&self, entry: AuditEntry) {
        let mut data = self.data.lock().await;
        data.audit.push(entry);
        let len = data.audit.len();
        if len > AUDIT_LIMIT {
            data.audit.drain(..len - AUDIT_LIMIT);
        }
        self.save(&data).await;
    }

    /// Reuse an identical pending request instead of piling up duplicates.
    async fn open_request(&self, mut request: SecretRequest) -> SecretRequest {
        let req_subject = request.subject();
        let mut data = self.data.lock().await;
        Self::prune(&mut data, Utc::now());
        if request.kind == RequestKind::Write {
            if let Some(existing) = data.requests.iter_mut().find(|r| {
                r.status == RequestStatus::Pending
                    && r.kind == RequestKind::Write
                    && r.subject().same_actor(&req_subject)
                    && r.key == request.key
                    && r.project_id == request.project_id
            }) {
                // A pending request never changes after the operator may have
                // seen it: the same value reuses it, a new value replaces it.
                if existing.value_sha256 == request.value_sha256 && existing.note == request.note {
                    return existing.clone();
                }
                existing.status = RequestStatus::Expired;
                existing.resolved_at = Some(Utc::now());
                existing.encrypted_value = None;
                existing.error = Some("Superseded by a newer value from the session".into());
            }
        }
        if matches!(request.kind, RequestKind::Delete | RequestKind::Move) {
            if let Some(existing) = data.requests.iter().find(|r| {
                r.status == RequestStatus::Pending
                    && r.kind == request.kind
                    && r.subject().same_actor(&req_subject)
                    && r.key == request.key
                    && r.project_id == request.project_id
                    && r.target_project_id == request.target_project_id
            }) {
                return existing.clone();
            }
        }
        if request.kind == RequestKind::Read {
            if let Some(existing) = data.requests.iter().find(|r| {
                r.status == RequestStatus::Pending
                    && r.kind == RequestKind::Read
                    && r.subject().same_actor(&req_subject)
                    && r.key == request.key
                    && r.project_id == request.project_id
                    && r.all_projects == request.all_projects
            }) {
                return existing.clone();
            }
        }
        request.status = RequestStatus::Pending;
        data.requests.push(request.clone());
        self.save(&data).await;
        drop(data);
        self.changed.notify_waiters();
        request
    }

    /// An approved write of this name by this actor in the last hour.
    async fn recent_approved_write(
        &self,
        subject: &approval_flow::RequesterSubject,
        key: &str,
        project_id: &str,
        value_sha256: &str,
    ) -> Option<Uuid> {
        let since = Utc::now() - chrono::Duration::hours(1);
        self.data
            .lock()
            .await
            .requests
            .iter()
            .rev()
            .find(|r| {
                r.kind == RequestKind::Write
                    && r.status == RequestStatus::Approved
                    && r.subject().same_actor(subject)
                    && r.key.as_deref() == Some(key)
                    && r.project_id.as_deref() == Some(project_id)
                    && r.value_sha256.as_deref() == Some(value_sha256)
                    && r.resolved_at.is_some_and(|t| t > since)
            })
            .map(|r| r.id)
    }

    /// An approved delete or move of this name by this actor in the last hour.
    async fn recent_approved(
        &self,
        kind: RequestKind,
        subject: &approval_flow::RequesterSubject,
        key: &str,
    ) -> Option<Uuid> {
        let since = Utc::now() - chrono::Duration::hours(1);
        self.data
            .lock()
            .await
            .requests
            .iter()
            .rev()
            .find(|r| {
                r.kind == kind
                    && r.status == RequestStatus::Approved
                    && r.subject().same_actor(subject)
                    && r.key.as_deref() == Some(key)
                    && r.resolved_at.is_some_and(|t| t > since)
            })
            .map(|r| r.id)
    }

    async fn request(&self, id: Uuid) -> Option<SecretRequest> {
        self.data
            .lock()
            .await
            .requests
            .iter()
            .find(|r| r.id == id)
            .cloned()
    }

    /// Wait until the request leaves `pending` or the wait elapses.
    async fn wait_resolved(&self, id: Uuid, wait: Duration) -> Option<SecretRequest> {
        approval_flow::wait_settled(&self.changed, wait, move || async move {
            self.request(id).await.map(|r| r.status)
        })
        .await?;
        self.request(id).await
    }

    pub async fn snapshot(&self) -> Value {
        let mut data = self.data.lock().await;
        Self::prune(&mut data, Utc::now());
        let mut requests: Vec<Value> = data
            .requests
            .iter()
            .rev()
            .take(100)
            .map(|r| {
                approval_queue::listed(r.public(), r.status.is_pending(), || {
                    ApprovalItem::secret(r)
                })
            })
            .collect();
        requests.truncate(100);
        json!({
            "requests": requests,
            "grants": data.grants,
            "audit": data.audit.iter().rev().take(200).collect::<Vec<_>>(),
        })
    }

    pub async fn pending_count(&self) -> usize {
        let mut data = self.data.lock().await;
        Self::prune(&mut data, Utc::now());
        data.requests
            .iter()
            .filter(|r| r.status == RequestStatus::Pending)
            .count()
    }

    pub async fn revoke(&self, id: Uuid) -> bool {
        let mut data = self.data.lock().await;
        let before = data.grants.len();
        data.grants.retain(|g| g.id != id);
        let removed = data.grants.len() != before;
        if removed {
            self.save(&data).await;
        }
        removed
    }

    pub async fn reject(&self, id: Uuid) -> Result<SecretRequest, String> {
        let _resolving = self.resolving.lock().await;
        let mut data = self.data.lock().await;
        let r = data
            .requests
            .iter_mut()
            .find(|r| r.id == id)
            .ok_or("Request not found")?;
        r.status = r.status.apply(ApprovalEvent::Deny)?;
        r.resolved_at = Some(Utc::now());
        r.encrypted_value = None;
        let out = r.clone();
        self.save(&data).await;
        drop(data);
        self.changed.notify_waiters();
        Ok(out)
    }

    /// Approve a request. Reads become a grant of the chosen scope; writes are
    /// applied to Bitwarden now.
    pub async fn approve(
        &self,
        state: &Arc<AppState>,
        id: Uuid,
        scope: Option<&str>,
        ttl_hours: Option<i64>,
    ) -> Result<SecretRequest, String> {
        let _resolving = self.resolving.lock().await;
        self.approve_resolving(state, id, scope, ttl_hours).await
    }

    /// Pending requests in the shared approval shape. Secrets belong to the
    /// backend's single Bitwarden account, so every pending request is the
    /// approver's (as with the per-request endpoints).
    pub async fn pending_items(&self) -> Vec<ApprovalItem> {
        let mut data = self.data.lock().await;
        Self::prune(&mut data, Utc::now());
        data.requests
            .iter()
            .filter(|r| r.status.is_pending())
            .map(ApprovalItem::secret)
            .collect()
    }

    /// Approve the listed requests with their default scope. Every item is
    /// checked with [`approval_queue::admit`] before any is applied, while
    /// holding the lock that serializes approvals; a write that Bitwarden then
    /// refuses comes back denied with its error, the others still apply.
    pub async fn approve_batch(
        &self,
        state: &Arc<AppState>,
        refs: &[BatchRef],
        confirm_critical: bool,
    ) -> Result<Vec<SecretRequest>, String> {
        if refs.is_empty() {
            return Ok(Vec::new());
        }
        let _resolving = self.resolving.lock().await;
        let current = self.pending_items().await;
        for want in refs {
            let c = current.iter().find(|c| c.id == want.id);
            approval_queue::admit(c, want, confirm_critical)?;
        }
        let mut out = Vec::with_capacity(refs.len());
        for want in refs {
            match self.approve_resolving(state, want.id, None, None).await {
                Ok(r) => out.push(r),
                Err(_) => out.extend(self.request(want.id).await),
            }
        }
        Ok(out)
    }

    /// [`Self::approve`] with the `resolving` lock already held.
    async fn approve_resolving(
        &self,
        state: &Arc<AppState>,
        id: Uuid,
        scope: Option<&str>,
        ttl_hours: Option<i64>,
    ) -> Result<SecretRequest, String> {
        let request = self.request(id).await.ok_or("Request not found")?;
        request.status.apply(ApprovalEvent::Approve)?;
        let now = Utc::now();
        let mut error = None;
        match request.kind {
            RequestKind::Read => {
                let scope = match scope.unwrap_or("") {
                    "all" => GrantScope::All,
                    "project" => GrantScope::Project {
                        project_id: match &request.project_id {
                            Some(p) => p.clone(),
                            None => self
                                .project_of(state, request.key.as_deref().unwrap_or(""))
                                .await
                                .ok_or(
                                    "The secret's project is unknown; approve the secret only",
                                )?,
                        },
                    },
                    "secret" | "" if request.key.is_some() => GrantScope::Secret {
                        key: request.key.clone().unwrap_or_default(),
                    },
                    "" if request.all_projects => GrantScope::All,
                    "" if request.project_id.is_some() => GrantScope::Project {
                        project_id: request.project_id.clone().unwrap_or_default(),
                    },
                    other => return Err(format!("Unsupported scope `{other}` for this request")),
                };
                let default_ttl = if request.subject().is_external() {
                    1
                } else {
                    DEFAULT_GRANT_TTL_HOURS
                };
                let ttl = ttl_hours.unwrap_or(default_ttl).clamp(1, 24 * 30);
                let mut expires_at = now + chrono::Duration::hours(ttl);
                if let Some(session_id) = request.subject().session_id() {
                    if let Some(hard) =
                        crate::control_mcp::gateway::session_hard_expires_at(state, session_id)
                            .await
                    {
                        if hard < expires_at {
                            expires_at = hard;
                        }
                    }
                }
                let grant = Grant {
                    id: Uuid::new_v4(),
                    mission_id: request.mission_id,
                    requester: request.requester.clone(),
                    requester_label: request.requester_label.clone(),
                    mission_title: request.mission_title.clone(),
                    paloma_project: request.paloma_project.clone(),
                    scope,
                    created_at: now,
                    expires_at,
                };
                self.data.lock().await.grants.push(grant);
            }
            RequestKind::Write => {
                let key = request.key.clone().ok_or("Write request has no name")?;
                let project_id = request
                    .project_id
                    .clone()
                    .ok_or("Write request has no project")?;
                let value =
                    decrypt(state, request.encrypted_value.as_deref().unwrap_or("")).await?;
                let existing =
                    self.list_all(state, true).await?.into_iter().find(|s| {
                        s.key == key && s.project_id.as_deref() == Some(project_id.as_str())
                    });
                let result = match existing {
                    Some(s) => {
                        bitwarden::edit_secret_value(state, &s.id, &value, request.note.as_deref())
                            .await
                    }
                    None => {
                        bitwarden::create_secret(
                            state,
                            &project_id,
                            &key,
                            &value,
                            request.note.as_deref(),
                        )
                        .await
                    }
                };
                if let Err((_, e)) = result {
                    error = Some(e);
                }
                self.invalidate_list().await;
            }
            RequestKind::Delete | RequestKind::Move => {
                let key = request.key.clone().ok_or("Request has no name")?;
                let found = self.list_all(state, true).await?.into_iter().find(|s| {
                    s.key == key && s.project_id.as_deref() == request.project_id.as_deref()
                });
                let result = match (found, request.kind) {
                    (None, _) => Err(format!("`{key}` no longer exists in that project")),
                    (Some(s), RequestKind::Delete) => bitwarden::delete_secret_by_id(state, &s.id)
                        .await
                        .map_err(|(_, e)| e),
                    (Some(s), _) => {
                        let target = request
                            .target_project_id
                            .as_deref()
                            .ok_or("Move request has no destination")?;
                        bitwarden::move_secret(state, &s.id, target)
                            .await
                            .map(|_| ())
                            .map_err(|(_, e)| e)
                    }
                };
                if let Err(e) = result {
                    error = Some(e);
                }
                self.invalidate_list().await;
            }
        }
        let mut data = self.data.lock().await;
        let r = data
            .requests
            .iter_mut()
            .find(|r| r.id == id)
            .ok_or("Request not found")?;
        r.resolved_at = Some(now);
        r.encrypted_value = None;
        r.status = r.status.apply(if error.is_some() {
            ApprovalEvent::Deny
        } else {
            ApprovalEvent::Approve
        })?;
        r.error = error.clone();
        let out = r.clone();
        let via = match out.kind {
            RequestKind::Read => None,
            RequestKind::Write => Some("write"),
            RequestKind::Delete => Some("delete"),
            RequestKind::Move => Some("move"),
        };
        if let (Some(via), None) = (via, &error) {
            data.audit.push(AuditEntry {
                at: now,
                mission_id: out.mission_id,
                requester: out.requester.clone(),
                requester_label: out.requester_label.clone(),
                paloma_project: out.paloma_project.clone(),
                key: out.key.clone().unwrap_or_default(),
                project_id: out.project_id.clone(),
                via: via.into(),
            });
        }
        self.save(&data).await;
        drop(data);
        self.changed.notify_waiters();
        match error {
            Some(e) => Err(format!("Bitwarden rejected the change: {e}")),
            None => Ok(out),
        }
    }

    async fn project_of(&self, state: &Arc<AppState>, key: &str) -> Option<String> {
        self.list_all(state, false)
            .await
            .ok()?
            .into_iter()
            .find(|s| s.key == key)
            .and_then(|s| s.project_id)
    }

    /// Revoke active secret grants and expire pending requests bound to an external MCP session.
    pub async fn revoke_session_grants(&self, session_id: Uuid) -> usize {
        let now = Utc::now();
        let mut data = self.data.lock().await;
        let before_grants = data.grants.len();
        data.grants
            .retain(|g| g.subject().session_id() != Some(session_id));
        let mut touched = before_grants - data.grants.len();
        for r in data.requests.iter_mut() {
            if r.status.is_pending() && r.subject().session_id() == Some(session_id) {
                r.status = RequestStatus::Expired;
                r.resolved_at = Some(now);
                r.encrypted_value = None;
                r.error = Some("External MCP session revoked".into());
                touched += 1;
            }
        }
        if touched > 0 {
            self.save(&data).await;
            drop(data);
            self.changed.notify_waiters();
        }
        touched
    }

    /// Wait view used by `GET /api/mcp/requests/secret/:id/wait`.
    pub async fn wait_for_requester(
        &self,
        owner: &str,
        requester: &approval_flow::RequesterSubject,
        id: Uuid,
        wait: Duration,
    ) -> Result<Value, (axum::http::StatusCode, String)> {
        let initial = self
            .request(id)
            .await
            .filter(|r| {
                r.subject().same_actor(requester) && r.owner.as_deref().is_none_or(|o| o == owner)
            })
            .ok_or_else(|| {
                (
                    axum::http::StatusCode::NOT_FOUND,
                    "Secret request not found".to_string(),
                )
            })?;
        let final_req = if initial.status.is_pending() && !wait.is_zero() {
            self.wait_resolved(id, wait).await.unwrap_or(initial)
        } else {
            initial
        };
        Ok(json!({
            "request_id": final_req.id,
            "kind": final_req.kind,
            "status": final_req.status,
            "name": final_req.key,
            "project_id": final_req.project_id,
            "all_projects": final_req.all_projects,
            "resolved_at": final_req.resolved_at,
            "error": final_req.error,
        }))
    }
}

async fn crypto_key(state: &AppState) -> Result<[u8; 32], String> {
    bitwarden::load_encryption_key(&state.config.working_dir)
        .await
        .ok_or_else(|| "Encryption key unavailable".to_string())
}

/// Keyed digest of a written value, so a retry can be recognized without
/// storing anything that allows offline guessing of the secret.
async fn value_digest(state: &AppState, value: &str) -> Result<String, String> {
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &crypto_key(state).await?);
    Ok(hex::encode(
        ring::hmac::sign(&key, value.as_bytes()).as_ref(),
    ))
}

async fn encrypt(state: &AppState, value: &str) -> Result<String, String> {
    env_crypto::encrypt_value(&crypto_key(state).await?, value).map_err(|e| e.to_string())
}

async fn decrypt(state: &AppState, value: &str) -> Result<String, String> {
    env_crypto::decrypt_value(&crypto_key(state).await?, value).map_err(|e| e.to_string())
}

fn project_names(projects: &[bitwarden::BitwardenProject]) -> BTreeMap<String, String> {
    projects
        .iter()
        .map(|p| (p.id.clone(), p.name.clone()))
        .collect()
}

/// Resolve a project given by name or id.
fn resolve_project(projects: &[bitwarden::BitwardenProject], wanted: &str) -> Option<String> {
    let wanted = wanted.trim();
    projects
        .iter()
        .find(|p| p.id == wanted || p.name.eq_ignore_ascii_case(wanted))
        .map(|p| p.id.clone())
}

fn pending_reply(request: &SecretRequest) -> Value {
    json!({
        "status": "pending",
        "request_id": request.id,
        "message": "Waiting for Thomas to approve this in Orb (Settings → Secrets, Touch ID / Face ID). \
                    Continue other work and call the same tool again later; do not ask for the value in chat.",
    })
}

/// The MCP client in the workspace replaces `secret_delivery` with a private
/// file so the value never enters the transcript or Core's event log.
fn delivery(detail: &BitwardenSecretDetail, project: Option<&str>) -> Value {
    json!({
        "status": "granted",
        "name": detail.key,
        "project": project,
        "secret_delivery": { "name": detail.key, "value": detail.value },
    })
}

async fn caller_for(
    state: &Arc<AppState>,
    p: &crate::control_mcp::gateway::Principal,
) -> Result<Caller, String> {
    let subject = p.requester_subject();
    let (mission, on_managed_node) = if let Some(mission_id) = p.mission_id {
        let control = state
            .control
            .get_or_spawn(&crate::api::auth::AuthUser {
                id: p.sub.clone(),
                username: p.username.clone(),
            })
            .await;
        let mission = control
            .mission_store
            .get_mission(mission_id)
            .await
            .ok()
            .flatten();
        let on_managed_node = crate::api::control::remote_grok::placement(
            &state.config.working_dir,
            &control.mission_store,
            mission_id,
        )
        .await
        .ok()
        .flatten()
        .is_some_and(|pl| crate::managed::is_managed_node(&pl.node_id));
        (mission, on_managed_node)
    } else {
        (None, false)
    };
    // The signed session's project decides default access; the mission record
    // is only a fallback for mission sessions issued without one.
    let paloma_project = p
        .project
        .clone()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| mission.as_ref().and_then(|m| m.project.project.clone()));
    Ok(Caller {
        owner: p.sub.clone(),
        subject,
        mission_title: mission.and_then(|m| m.title),
        paloma_project,
        on_managed_node,
    })
}

pub const TOOL_NAMES: [&str; 6] = [
    "secret_list",
    "secret_get",
    "secret_request",
    "secret_put",
    "secret_delete",
    "secret_move",
];

/// Entry point for the `secret_*` MCP tools.
pub async fn handle_tool(
    state: &Arc<AppState>,
    p: &crate::control_mcp::gateway::Principal,
    name: &str,
    args: &Value,
) -> Result<Value, String> {
    let caller = caller_for(state, p).await?;
    let broker = broker(state);
    if caller.subject.is_external() {
        let bunker = super::privilege_broker::store(state).bunker_state().await;
        if bunker >= super::privilege_broker::BunkerState::HardLockdown {
            return Err(
                "Bunker HardLockdown is active; external MCP sessions are suspended".into(),
            );
        }
        if bunker >= super::privilege_broker::BunkerState::SoftQuarantine && name != "secret_list" {
            return Err(
                "Fleet is in Bunker SoftQuarantine; external secret requests and mutations are suspended"
                    .into(),
            );
        }
    }
    let str_arg = |k: &str| {
        args.get(k)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
    };
    let reason = str_arg("reason").unwrap_or("").to_string();
    match name {
        "secret_list" => {
            let access = broker.access_for(state, &caller).await;
            let projects = bitwarden::list_projects_raw(state)
                .await
                .map_err(|(_, e)| e)?;
            let names = project_names(&projects);
            let secrets = broker.list_all(state, false).await?;
            let mut accessible = Vec::new();
            let mut by_request = BTreeMap::<String, Vec<String>>::new();
            let mut core_reserved = Vec::new();
            for s in secrets {
                let project = s
                    .project_id
                    .as_deref()
                    .and_then(|id| names.get(id))
                    .cloned();
                if is_core_reserved_compute_secret(&s.key) {
                    core_reserved.push(s.key);
                    continue;
                }
                if !admits_secret_delivery(&s.key, caller.on_managed_node) {
                    continue;
                }
                if access.allows(&s.key, s.project_id.as_deref()) {
                    accessible.push(json!({"name": s.key, "project": project}));
                } else {
                    by_request
                        .entry(project.unwrap_or_else(|| "unknown".into()))
                        .or_default()
                        .push(s.key);
                }
            }
            Ok(json!({
                "paloma_project": caller.paloma_project,
                "on_managed_node": caller.on_managed_node,
                "accessible": accessible,
                "requires_approval": by_request,
                "core_reserved": core_reserved,
                "projects": projects.iter().map(|p| p.name.clone()).collect::<Vec<_>>(),
                "hint": "secret_get NAME returns accessible secrets immediately and asks Thomas for the others. \
                         Cloud-compute keys in core_reserved are managed natively by Core: use spawn_managed_machine(provider=...) \
                         or start_mission(remote_node_id=\"auto-managed:<provider>:<size>\") instead of calling cloud APIs directly. \
                         secret_request bitwarden_project asks for a whole Bitwarden project. secret_put stores a new secret after approval; \
                         secret_delete and secret_move remove or relocate one after approval.",
            }))
        }
        "secret_get" => {
            let key = str_arg("name").ok_or("`name` is required")?.to_string();
            if !admits_secret_delivery(&key, caller.on_managed_node) {
                if is_core_reserved_compute_secret(&key) {
                    return Err(format!(
                        "`{key}` is a Core-reserved cloud-compute credential. Never call provider APIs directly; \
                         use `spawn_managed_machine(provider=...)` or `start_mission(remote_node_id=\"auto-managed:<provider>:<size>\")` \
                         so Core tracks ownership, budgets, and automatic reaping."
                    ));
                }
                return Err(format!(
                    "`{key}` cannot be delivered to an untrusted managed compute node (`managed-*`). \
                     Managed workers only allow worker-safe repository tokens (`GITHUB_TOKEN` / `GH_TOKEN`)."
                ));
            }
            let secrets = broker.list_all(state, false).await?;
            let matches: Vec<_> = secrets.iter().filter(|s| s.key == key).collect();
            let Some(summary) = matches.first().copied() else {
                return Err(format!(
                    "No secret named `{key}`. Use secret_list to see names."
                ));
            };
            if matches.len() > 1 {
                return Err(format!(
                    "`{key}` exists in several projects; ask Thomas to remove the duplicate."
                ));
            }
            let project_id = summary.project_id.clone();
            let mut access = broker.access_for(state, &caller).await;
            if !access.allows(&key, project_id.as_deref()) {
                let request = broker
                    .open_request(SecretRequest {
                        id: Uuid::new_v4(),
                        kind: RequestKind::Read,
                        status: RequestStatus::Pending,
                        owner: Some(caller.owner.clone()),
                        mission_id: caller.subject.mission_id(),
                        requester: Some(caller.subject.clone()),
                        requester_label: caller.subject.external_display_label(),
                        mission_title: caller.mission_title.clone(),
                        paloma_project: caller.paloma_project.clone(),
                        key: Some(key.clone()),
                        project_id: project_id.clone(),
                        all_projects: false,
                        reason,
                        note: None,
                        value_sha256: None,
                        encrypted_value: None,
                        target_project_id: None,
                        created_at: Utc::now(),
                        resolved_at: None,
                        error: None,
                    })
                    .await;
                let resolved = broker.wait_resolved(request.id, APPROVAL_WAIT).await;
                match resolved.map(|r| r.status) {
                    Some(RequestStatus::Approved) => {}
                    Some(RequestStatus::Denied) => {
                        return Err(format!("Thomas declined access to `{key}`."))
                    }
                    Some(RequestStatus::Expired) => {
                        return Err("The request expired; ask again if still needed.".into())
                    }
                    _ => return Ok(pending_reply(&request)),
                }
                access = broker.access_for(state, &caller).await;
                if !access.allows(&key, project_id.as_deref()) {
                    return Err("Approval did not cover this secret.".into());
                }
            }
            let via = if bitwarden_defaults_cover(state, &caller, project_id.as_deref()).await {
                "default"
            } else {
                "grant"
            };
            let detail = bitwarden::get_secret(state, &summary.id)
                .await
                .map_err(|(_, e)| e)?;
            broker
                .audit(AuditEntry {
                    at: Utc::now(),
                    mission_id: caller.subject.mission_id(),
                    requester: Some(caller.subject.clone()),
                    requester_label: caller.subject.external_display_label(),
                    paloma_project: caller.paloma_project.clone(),
                    key: key.clone(),
                    project_id: project_id.clone(),
                    via: via.into(),
                })
                .await;
            let projects = bitwarden::list_projects_raw(state)
                .await
                .unwrap_or_default();
            let project_name = project_id
                .as_deref()
                .and_then(|id| project_names(&projects).get(id).cloned());
            Ok(delivery(&detail, project_name.as_deref()))
        }
        "secret_request" => {
            if caller.on_managed_node {
                return Err(
                    "Project-wide secret grants are disabled on untrusted managed compute nodes (`managed-*`). \
                     Request individual worker-safe tokens (`GITHUB_TOKEN` / `GH_TOKEN`) via `secret_get` instead."
                        .into(),
                );
            }
            let projects = bitwarden::list_projects_raw(state)
                .await
                .map_err(|(_, e)| e)?;
            let wanted = str_arg("bitwarden_project")
                .ok_or("`bitwarden_project` is required (a Bitwarden project name, or `all`)")?;
            let all = wanted.eq_ignore_ascii_case("all") || wanted == "*";
            let project_id = if all {
                None
            } else {
                Some(
                    resolve_project(&projects, wanted)
                        .ok_or_else(|| format!("Unknown Bitwarden project `{wanted}`"))?,
                )
            };
            let access = broker.access_for(state, &caller).await;
            if access.all
                || project_id
                    .as_ref()
                    .is_some_and(|p| access.projects.contains(p))
            {
                return Ok(
                    json!({"status":"granted","message":"Access already granted; use secret_get."}),
                );
            }
            let request = broker
                .open_request(SecretRequest {
                    id: Uuid::new_v4(),
                    kind: RequestKind::Read,
                    status: RequestStatus::Pending,
                    owner: Some(caller.owner.clone()),
                    mission_id: caller.subject.mission_id(),
                    requester: Some(caller.subject.clone()),
                    requester_label: caller.subject.external_display_label(),
                    mission_title: caller.mission_title.clone(),
                    paloma_project: caller.paloma_project.clone(),
                    key: None,
                    project_id,
                    all_projects: all,
                    reason,
                    note: None,
                    value_sha256: None,
                    encrypted_value: None,
                    target_project_id: None,
                    created_at: Utc::now(),
                    resolved_at: None,
                    error: None,
                })
                .await;
            match broker
                .wait_resolved(request.id, APPROVAL_WAIT)
                .await
                .map(|r| r.status)
            {
                Some(RequestStatus::Approved) => {
                    Ok(json!({"status":"granted","message":"Approved; use secret_get."}))
                }
                Some(RequestStatus::Denied) => Err("Thomas declined the request.".into()),
                Some(RequestStatus::Expired) => Err("The request expired.".into()),
                _ => Ok(pending_reply(&request)),
            }
        }
        "secret_put" => {
            if caller.on_managed_node {
                return Err(
                    "Mutating Bitwarden vault secrets (`secret_put`) is disabled on untrusted managed compute nodes (`managed-*`)."
                        .into(),
                );
            }
            let key = str_arg("name").ok_or("`name` is required")?.to_string();
            if !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
                return Err("Secret names use A-Z, 0-9 and _ (environment-variable style).".into());
            }
            let value = args
                .get("value")
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
                .ok_or("`value` is required")?;
            let projects = bitwarden::list_projects_raw(state)
                .await
                .map_err(|(_, e)| e)?;
            let wanted = str_arg("bitwarden_project").ok_or("`bitwarden_project` is required")?;
            let project_id = resolve_project(&projects, wanted)
                .ok_or_else(|| format!("Unknown Bitwarden project `{wanted}`"))?;
            if let Some(dup) = broker
                .list_all(state, false)
                .await?
                .into_iter()
                .find(|s| s.key == key && s.project_id.as_deref() != Some(project_id.as_str()))
            {
                let other = dup
                    .project_id
                    .as_deref()
                    .and_then(|id| project_names(&projects).get(id).cloned())
                    .unwrap_or_default();
                return Err(format!(
                    "`{key}` already exists in project `{other}`; use that project."
                ));
            }
            // A retry after the operator approved the earlier call: done already.
            let value_sha256 = value_digest(state, value).await?;
            if let Some(done) = broker
                .recent_approved_write(&caller.subject, &key, &project_id, &value_sha256)
                .await
            {
                return Ok(json!({"status":"stored","request_id": done}));
            }
            let request = broker
                .open_request(SecretRequest {
                    id: Uuid::new_v4(),
                    kind: RequestKind::Write,
                    status: RequestStatus::Pending,
                    owner: Some(caller.owner.clone()),
                    mission_id: caller.subject.mission_id(),
                    requester: Some(caller.subject.clone()),
                    requester_label: caller.subject.external_display_label(),
                    mission_title: caller.mission_title.clone(),
                    paloma_project: caller.paloma_project.clone(),
                    key: Some(key),
                    project_id: Some(project_id),
                    all_projects: false,
                    reason,
                    note: str_arg("note").map(str::to_string),
                    value_sha256: Some(value_sha256),
                    encrypted_value: Some(encrypt(state, value).await?),
                    target_project_id: None,
                    created_at: Utc::now(),
                    resolved_at: None,
                    error: None,
                })
                .await;
            match broker.wait_resolved(request.id, APPROVAL_WAIT).await {
                Some(r) if r.status == RequestStatus::Approved => {
                    Ok(json!({"status":"stored","request_id": r.id}))
                }
                Some(r) if r.status == RequestStatus::Denied => Err(r
                    .error
                    .unwrap_or_else(|| "Thomas declined the write.".into())),
                Some(r) if r.status == RequestStatus::Expired => Err("The request expired.".into()),
                _ => Ok(pending_reply(&request)),
            }
        }
        "secret_delete" | "secret_move" => {
            if caller.on_managed_node {
                return Err(format!(
                    "Mutating Bitwarden vault secrets (`{name}`) is disabled on untrusted managed compute nodes (`managed-*`)."
                ));
            }
            let kind = if name == "secret_delete" {
                RequestKind::Delete
            } else {
                RequestKind::Move
            };
            let key = str_arg("name").ok_or("`name` is required")?.to_string();
            let projects = bitwarden::list_projects_raw(state)
                .await
                .map_err(|(_, e)| e)?;
            let names = project_names(&projects);
            // Delete: optional `bitwarden_project` picks among duplicates.
            // Move: `bitwarden_project` is the destination.
            let wanted = str_arg("bitwarden_project")
                .map(|w| {
                    resolve_project(&projects, w)
                        .ok_or_else(|| format!("Unknown Bitwarden project `{w}`"))
                })
                .transpose()?;
            if kind == RequestKind::Move && wanted.is_none() {
                return Err("`bitwarden_project` (the destination) is required".into());
            }
            let secrets = broker.list_all(state, true).await?;
            let mut matches: Vec<_> = secrets.iter().filter(|s| s.key == key).collect();
            if kind == RequestKind::Delete && wanted.is_some() {
                matches.retain(|s| s.project_id == wanted);
            }
            let done = |id: Option<Uuid>| -> Result<Value, String> {
                Ok(json!({
                    "status": if kind == RequestKind::Delete { "deleted" } else { "moved" },
                    "request_id": id,
                }))
            };
            let Some(summary) = matches.first().copied() else {
                if let Some(id) = broker.recent_approved(kind, &caller.subject, &key).await {
                    return done(Some(id));
                }
                return Err(format!(
                    "No secret named `{key}`. Use secret_list to see names."
                ));
            };
            if matches.len() > 1 {
                return Err(format!(
                    "`{key}` exists in several projects; pass `bitwarden_project` to pick one{}.",
                    if kind == RequestKind::Move {
                        " (delete the duplicate first)"
                    } else {
                        ""
                    }
                ));
            }
            if kind == RequestKind::Move && summary.project_id == wanted {
                return done(broker.recent_approved(kind, &caller.subject, &key).await);
            }
            if kind == RequestKind::Move {
                // A move must not turn into a read: refuse moving a secret this
                // session cannot read into a project it can.
                let access = broker.access_for(state, &caller).await;
                if !access.allows(&key, summary.project_id.as_deref())
                    && access.allows(&key, wanted.as_deref())
                {
                    return Err(format!(
                        "This session could read `{key}` after the move; use secret_get to ask for it, \
                         or ask Thomas to move it himself."
                    ));
                }
            }
            let project_label = |id: Option<&str>| {
                id.and_then(|id| names.get(id).cloned())
                    .unwrap_or_else(|| "unknown".into())
            };
            let request = broker
                .open_request(SecretRequest {
                    id: Uuid::new_v4(),
                    kind,
                    status: RequestStatus::Pending,
                    owner: Some(caller.owner.clone()),
                    mission_id: caller.subject.mission_id(),
                    requester: Some(caller.subject.clone()),
                    requester_label: caller.subject.external_display_label(),
                    mission_title: caller.mission_title.clone(),
                    paloma_project: caller.paloma_project.clone(),
                    key: Some(key.clone()),
                    project_id: summary.project_id.clone(),
                    all_projects: false,
                    reason,
                    note: None,
                    value_sha256: None,
                    encrypted_value: None,
                    target_project_id: if kind == RequestKind::Move {
                        wanted.clone()
                    } else {
                        None
                    },
                    created_at: Utc::now(),
                    resolved_at: None,
                    error: None,
                })
                .await;
            match broker.wait_resolved(request.id, APPROVAL_WAIT).await {
                Some(r) if r.status == RequestStatus::Approved => {
                    let mut out = done(Some(r.id))?;
                    out["from"] = json!(project_label(summary.project_id.as_deref()));
                    if kind == RequestKind::Move {
                        out["to"] = json!(project_label(wanted.as_deref()));
                    }
                    Ok(out)
                }
                Some(r) if r.status == RequestStatus::Denied => Err(r
                    .error
                    .unwrap_or_else(|| "Thomas declined the change.".into())),
                Some(r) if r.status == RequestStatus::Expired => Err("The request expired.".into()),
                _ => Ok(pending_reply(&request)),
            }
        }
        _ => Err("Unknown secret tool".into()),
    }
}

async fn bitwarden_defaults_cover(
    state: &AppState,
    caller: &Caller,
    project_id: Option<&str>,
) -> bool {
    let bw = state.settings.get_bitwarden().await;
    project_id.is_some_and(|p| {
        default_projects(&bw, caller.paloma_project.as_deref())
            .iter()
            .any(|d| d == p)
    })
}

pub fn tool_definitions() -> Vec<crate::control_mcp::ToolDefinition> {
    use crate::control_mcp::ToolDefinition;
    vec![
        ToolDefinition {
            name: "secret_list".into(),
            description: "List the names (never values) of Thomas's secrets: which ones this mission can read now, \
                          and which need his approval, grouped by Bitwarden project."
                .into(),
            input_schema: json!({"type":"object","properties":{},"additionalProperties":false}),
        },
        ToolDefinition {
            name: "secret_get".into(),
            description: "Get one secret by name. Secrets in this project's default Bitwarden projects come back at once; \
                          others ask Thomas (Touch ID / Face ID) and wait up to 20 s, then return `pending` — call again later. \
                          The value is written to a private file; the result gives its path and an `export` line. \
                          Never print the value or paste it into chat, commits or logs."
                .into(),
            input_schema: json!({"type":"object","required":["name"],"properties":{
                "name":{"type":"string","minLength":1,"maxLength":200},
                "reason":{"type":"string","maxLength":500,"description":"Why the mission needs it; shown to Thomas."}
            },"additionalProperties":false}),
        },
        ToolDefinition {
            name: "secret_request".into(),
            description: "Ask Thomas for read access to a whole Bitwarden project (by name), or `all`, for this mission. \
                          Waits up to 20 s for approval, then returns `pending`."
                .into(),
            input_schema: json!({"type":"object","required":["bitwarden_project","reason"],"properties":{
                "bitwarden_project":{"type":"string","minLength":1,"maxLength":200},
                "reason":{"type":"string","minLength":1,"maxLength":500}
            },"additionalProperties":false}),
        },
        ToolDefinition {
            name: "secret_put".into(),
            description: "Store a secret (create, or update the value) in a Bitwarden project. Always needs Thomas's approval; \
                          waits up to 20 s, then returns `pending`. Use UPPER_SNAKE_CASE names and the project that fits \
                          (see secret_list for project names)."
                .into(),
            input_schema: json!({"type":"object","required":["name","value","bitwarden_project","reason"],"properties":{
                "name":{"type":"string","minLength":1,"maxLength":200},
                "value":{"type":"string","minLength":1,"maxLength":65536},
                "bitwarden_project":{"type":"string","minLength":1,"maxLength":200},
                "note":{"type":"string","maxLength":2000},
                "reason":{"type":"string","minLength":1,"maxLength":500}
            },"additionalProperties":false}),
        },
        ToolDefinition {
            name: "secret_delete".into(),
            description: "Permanently delete a secret from Bitwarden. Always needs Thomas's approval; waits up to 20 s, \
                          then returns `pending` — call again later. If the same name exists in several projects, \
                          pass `bitwarden_project` to pick which copy to delete. To rename a secret: secret_get the old \
                          name, secret_put the new one, then secret_delete the old one."
                .into(),
            input_schema: json!({"type":"object","required":["name","reason"],"properties":{
                "name":{"type":"string","minLength":1,"maxLength":200},
                "bitwarden_project":{"type":"string","minLength":1,"maxLength":200,
                    "description":"Project holding the copy to delete; only needed when the name is duplicated."},
                "reason":{"type":"string","minLength":1,"maxLength":500}
            },"additionalProperties":false}),
        },
        ToolDefinition {
            name: "secret_move".into(),
            description: "Move a secret (value and note unchanged) to another Bitwarden project. Always needs Thomas's \
                          approval; waits up to 20 s, then returns `pending` — call again later."
                .into(),
            input_schema: json!({"type":"object","required":["name","bitwarden_project","reason"],"properties":{
                "name":{"type":"string","minLength":1,"maxLength":200},
                "bitwarden_project":{"type":"string","minLength":1,"maxLength":200,"description":"Destination project."},
                "reason":{"type":"string","minLength":1,"maxLength":500}
            },"additionalProperties":false}),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::BitwardenSettings;

    #[test]
    fn default_access_falls_back_to_legacy_binding() {
        let mut bw = BitwardenSettings::default();
        bw.project_bindings
            .insert("minecraft".into(), "p-mc".into());
        assert_eq!(
            default_projects(&bw, Some("minecraft")),
            vec!["p-mc".to_string()]
        );
        bw.default_access
            .insert("minecraft".into(), vec!["p-a".into(), "p-b".into()]);
        assert_eq!(default_projects(&bw, Some("minecraft")).len(), 2);
        assert!(default_projects(&bw, None).is_empty());
        assert!(default_projects(&bw, Some("other")).is_empty());
    }

    #[test]
    fn grants_only_apply_to_their_mission_until_expiry() {
        let now = Utc::now();
        let mission = Uuid::new_v4();
        let grant = |m, scope, hours| Grant {
            id: Uuid::new_v4(),
            mission_id: Some(m),
            requester: Some(approval_flow::RequesterSubject::mission(m)),
            requester_label: None,
            mission_title: None,
            paloma_project: None,
            scope,
            created_at: now,
            expires_at: now + chrono::Duration::hours(hours),
        };
        let grants = vec![
            grant(mission, GrantScope::Secret { key: "UXON".into() }, 1),
            grant(
                mission,
                GrantScope::Project {
                    project_id: "p-infra".into(),
                },
                -1,
            ),
            grant(Uuid::new_v4(), GrantScope::All, 1),
        ];
        let access = grant_access(
            vec!["p-mc".into()],
            &grants,
            &approval_flow::RequesterSubject::mission(mission),
            now,
        );
        assert!(access.allows("UXON", Some("p-core")));
        assert!(access.allows("ANY", Some("p-mc")));
        assert!(
            !access.allows("CLOUDFLARE_API_TOKEN", Some("p-infra")),
            "expired grant"
        );
        assert!(
            !access.allows("JWT_SECRET", Some("p-core")),
            "other mission's grant"
        );
    }

    #[test]
    fn public_request_view_hides_the_pending_value() {
        let r = SecretRequest {
            id: Uuid::new_v4(),
            kind: RequestKind::Write,
            status: RequestStatus::Pending,
            owner: Some("thomas".into()),
            mission_id: Some(Uuid::new_v4()),
            requester: None,
            requester_label: None,
            mission_title: None,
            paloma_project: None,
            key: Some("K".into()),
            project_id: Some("p".into()),
            all_projects: false,
            reason: "r".into(),
            note: None,
            value_sha256: None,
            encrypted_value: Some("<encrypted>".into()),
            target_project_id: None,
            created_at: Utc::now(),
            resolved_at: None,
            error: None,
        };
        assert!(r.public().get("encrypted_value").is_none());
        assert!(r.public().get("owner").is_none());
    }

    #[test]
    fn move_request_shows_kind_and_destination_to_clients() {
        let r = SecretRequest {
            id: Uuid::new_v4(),
            kind: RequestKind::Move,
            status: RequestStatus::Pending,
            owner: None,
            mission_id: Some(Uuid::new_v4()),
            requester: None,
            requester_label: None,
            mission_title: None,
            paloma_project: None,
            key: Some("K".into()),
            project_id: Some("from".into()),
            all_projects: false,
            reason: "r".into(),
            note: None,
            value_sha256: None,
            encrypted_value: None,
            target_project_id: Some("to".into()),
            created_at: Utc::now(),
            resolved_at: None,
            error: None,
        };
        let v = r.public();
        assert_eq!(v["kind"], "move");
        assert_eq!(v["target_project_id"], "to");
        let names: Vec<_> = tool_definitions().into_iter().map(|t| t.name).collect();
        assert!(TOOL_NAMES.iter().all(|n| names.iter().any(|d| d == n)));
    }

    #[test]
    fn compute_secret_confinement_blocks_reserved_keys_and_untrusted_nodes() {
        for reserved in [
            "BOAT_API_KEY",
            "HETZNER_CLOUD_APIKEY",
            "hcloud_token",
            "SCALEWAY_SECRET_KEY",
            "SCALEWAY_KEY_ID",
            "VASTAI_API_KEY",
            "RUNPOD_API_KEY",
            "COLAB_API_DOTENV_PRIVATE_KEY",
        ] {
            assert!(is_core_reserved_compute_secret(reserved));
            assert!(!admits_secret_delivery(reserved, false));
            assert!(!admits_secret_delivery(reserved, true));
        }

        // Ordinary vault secrets are deliverable on trusted static nodes,
        // never on untrusted `managed-*` workers.
        assert!(admits_secret_delivery("OPENAI_API_KEY", false));
        assert!(!admits_secret_delivery("OPENAI_API_KEY", true));
        assert!(!admits_secret_delivery("CLOUDFLARE_API_TOKEN", true));

        // Worker-safe repository tokens remain deliverable on `managed-*` VMs.
        assert!(is_allowlisted_managed_secret("GITHUB_TOKEN"));
        assert!(is_allowlisted_managed_secret("gh_token"));
        assert!(admits_secret_delivery("GITHUB_TOKEN", true));
        assert!(admits_secret_delivery("GH_TOKEN", true));
    }
}
