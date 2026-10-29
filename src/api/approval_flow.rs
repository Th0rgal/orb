//! Shared "access request / approval" primitive.
//!
//! Missions ask Core for something they may not do on their own (read a
//! secret, read another mission); Thomas answers on an enrolled device with
//! Touch ID / Face ID (see [`super::approvals`] for the signature check). The
//! secrets broker ([`super::secret_broker`]) and mission access grants
//! ([`super::mission_access`]) both use the pieces here:
//!
//! - [`ApprovalState`] and [`ApprovalEvent`]: the one state machine every
//!   request follows. Only `pending` can be decided; only `approved` can be
//!   revoked or expire after the fact; every other state is final.
//! - [`pending_timed_out`]: an unanswered request is denied by timeout
//!   (it becomes `expired`, never `approved`).
//! - [`wait_settled`]: a tool call waits a bounded time for the decision.
//! - [`persist_private`]: atomic, owner-only JSON persistence.

use std::future::Future;
use std::path::Path;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// Kind of external (non-mission) MCP client raising an approval request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ExternalClientKind {
    #[default]
    LocalMcp,
    Cli,
    Ci,
    Webhook,
}

impl ExternalClientKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ExternalClientKind::LocalMcp => "local_mcp",
            ExternalClientKind::Cli => "cli",
            ExternalClientKind::Ci => "ci",
            ExternalClientKind::Webhook => "webhook",
        }
    }
}

/// First-class subject identity for authorization and approval requests.
///
/// Legacy records persisted with only `mission_id` / `requester_mission_id`
/// normalize to [`RequesterSubject::Mission`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RequesterSubject {
    Mission {
        mission_id: Uuid,
    },
    ExternalSession {
        session_id: Uuid,
        #[serde(default)]
        client_kind: ExternalClientKind,
        client_label: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        host_hint: Option<String>,
    },
}

impl RequesterSubject {
    pub fn mission(mission_id: Uuid) -> Self {
        Self::Mission { mission_id }
    }

    pub fn external_session(
        session_id: Uuid,
        client_kind: ExternalClientKind,
        client_label: impl Into<String>,
        host_hint: Option<String>,
    ) -> Self {
        let label = sanitize_client_label(&client_label.into(), client_kind);
        let host = host_hint.as_deref().and_then(sanitize_host_hint);
        Self::ExternalSession {
            session_id,
            client_kind,
            client_label: label,
            host_hint: host,
        }
    }

    pub fn mission_id(&self) -> Option<Uuid> {
        match self {
            Self::Mission { mission_id } => Some(*mission_id),
            Self::ExternalSession { .. } => None,
        }
    }

    pub fn session_id(&self) -> Option<Uuid> {
        match self {
            Self::Mission { .. } => None,
            Self::ExternalSession { session_id, .. } => Some(*session_id),
        }
    }

    pub fn is_external(&self) -> bool {
        matches!(self, Self::ExternalSession { .. })
    }

    /// Canonical, collision-free subject identity for equality, deduplication,
    /// and approval digest calculation.
    ///
    /// - Mission: `"mission:<uuid>"`
    /// - ExternalSession: `"session:<uuid>:<kind>:<label_hash>"` (where
    ///   `label_hash` hashes normalized `client_label` and `host_hint`).
    pub fn canonical_id(&self) -> String {
        match self {
            Self::Mission { mission_id } => format!("mission:{mission_id}"),
            Self::ExternalSession {
                session_id,
                client_kind,
                client_label,
                host_hint,
            } => {
                let mut h = Sha256::new();
                h.update(client_label.trim().as_bytes());
                h.update(b"\n");
                if let Some(host) = host_hint
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                {
                    h.update(host.as_bytes());
                }
                let digest = hex::encode(h.finalize());
                format!(
                    "session:{}:{}:{}",
                    session_id,
                    client_kind.as_str(),
                    &digest[..16]
                )
            }
        }
    }

    /// Subject identity match for grants, pending request deduplication, and
    /// `/wait` authorization: two sessions with the same `session_id` or two
    /// missions with the same `mission_id` represent the same requester.
    pub fn same_actor(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Mission { mission_id: a }, Self::Mission { mission_id: b }) => a == b,
            (
                Self::ExternalSession { session_id: a, .. },
                Self::ExternalSession { session_id: b, .. },
            ) => a == b,
            _ => false,
        }
    }

    /// Human-readable label for external sessions (e.g. `"External · macbook-air (claude-code)"`),
    /// or `None` for mission subjects (which use `requester_title` / mission ID).
    pub fn external_display_label(&self) -> Option<String> {
        match self {
            Self::Mission { .. } => None,
            Self::ExternalSession {
                client_kind,
                client_label,
                host_hint,
                ..
            } => {
                let label = sanitize_client_label(client_label, *client_kind);
                match host_hint.as_deref().and_then(sanitize_host_hint) {
                    Some(host) => Some(format!("External · {host} ({label})")),
                    None => Some(format!("External · {label}")),
                }
            }
        }
    }

    /// Formatted actor description for signed biometric challenge prompts.
    pub fn prompt_who(&self, mission_title: Option<&str>) -> String {
        match self {
            Self::Mission { mission_id } => {
                match mission_title.map(str::trim).filter(|s| !s.is_empty()) {
                    Some(title) => format!("mission {}", super::approvals::quoted(title)),
                    None => format!("mission {}", &mission_id.to_string()[..8]),
                }
            }
            Self::ExternalSession { .. } => {
                let label = self
                    .external_display_label()
                    .unwrap_or_else(|| "External · local_mcp".into());
                super::approvals::quoted(&label)
            }
        }
    }
}

pub fn sanitize_client_label(raw: &str, fallback_kind: ExternalClientKind) -> String {
    let cleaned: String = raw
        .chars()
        .filter(|c| !c.is_control())
        .collect::<String>()
        .trim()
        .chars()
        .take(80)
        .collect();
    if cleaned.is_empty() {
        fallback_kind.as_str().to_string()
    } else {
        cleaned
    }
}

pub fn sanitize_host_hint(raw: &str) -> Option<String> {
    let cleaned: String = raw
        .chars()
        .filter(|c| !c.is_control())
        .collect::<String>()
        .trim()
        .chars()
        .take(80)
        .collect();
    if cleaned.is_empty() {
        None
    } else {
        Some(cleaned)
    }
}

/// State of a request. A request that becomes a grant (mission access) stays
/// `approved` while the grant lives.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalState {
    Pending,
    Approved,
    /// Declined by Thomas. Older secret-broker files say `rejected`.
    #[serde(alias = "rejected")]
    Denied,
    /// Not answered in time, or an approved grant that ran out.
    Expired,
    /// Approved, then withdrawn by Thomas.
    Revoked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApprovalEvent {
    Approve,
    Deny,
    Expire,
    Revoke,
}

impl ApprovalState {
    /// The only allowed transitions. Anything else is refused, so a request
    /// is never decided twice and a final state never comes back to life.
    pub fn apply(self, event: ApprovalEvent) -> Result<ApprovalState, &'static str> {
        use ApprovalEvent::*;
        use ApprovalState::*;
        match (self, event) {
            (Pending, Approve) => Ok(Approved),
            (Pending, Deny) => Ok(Denied),
            (Pending, Expire) => Ok(Expired),
            (Approved, Revoke) => Ok(Revoked),
            (Approved, Expire) => Ok(Expired),
            (Pending, Revoke) => Err("Request is still pending; deny it instead"),
            _ => Err("Request is no longer pending"),
        }
    }

    pub fn is_pending(self) -> bool {
        self == ApprovalState::Pending
    }
}

/// `true` once an unanswered request is older than `ttl`: it must be
/// expired (denied by timeout), never approved implicitly.
pub fn pending_timed_out(
    created_at: DateTime<Utc>,
    now: DateTime<Utc>,
    ttl: chrono::Duration,
) -> bool {
    now - created_at > ttl
}

/// Wait until `current` reports a non-pending state, the request vanishes
/// (`None`), or `wait` elapses. `changed` is notified on every decision.
pub async fn wait_settled<F, Fut>(
    changed: &tokio::sync::Notify,
    wait: Duration,
    mut current: F,
) -> Option<ApprovalState>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Option<ApprovalState>>,
{
    let deadline = Instant::now() + wait;
    loop {
        let notified = changed.notified();
        let state = current().await?;
        if !state.is_pending() {
            return Some(state);
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Some(state);
        }
        let _ = tokio::time::timeout(left, notified).await;
    }
}

/// Write `value` as JSON to `path` atomically (temp file + rename), readable
/// by the backend user only. Errors when the state did not reach disk, so a
/// decision (approve, revoke) is never reported done while a restart would
/// bring back the old state.
pub async fn persist_private<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    let text = serde_json::to_string_pretty(value).map_err(|e| format!("Encode state: {e}"))?;
    if let Some(dir) = path.parent() {
        tokio::fs::create_dir_all(dir)
            .await
            .map_err(|e| format!("Create state dir: {e}"))?;
    }
    let tmp = path.with_extension("json.tmp");
    tokio::fs::write(&tmp, text)
        .await
        .map_err(|e| format!("Write state: {e}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))
            .await
            .map_err(|e| format!("Protect state: {e}"))?;
    }
    tokio::fs::rename(&tmp, path)
        .await
        .map_err(|e| format!("Save state: {e}"))
}

#[cfg(test)]
mod tests {
    use super::ApprovalEvent::*;
    use super::ApprovalState::*;
    use super::*;

    #[test]
    fn only_pending_can_be_decided() {
        assert_eq!(Pending.apply(Approve), Ok(Approved));
        assert_eq!(Pending.apply(Deny), Ok(Denied));
        assert_eq!(Pending.apply(Expire), Ok(Expired));
        for s in [Approved, Denied, Expired, Revoked] {
            assert!(s.apply(Approve).is_err(), "{s:?} approved again");
            assert!(s.apply(Deny).is_err(), "{s:?} denied again");
        }
    }

    #[test]
    fn only_approved_can_be_revoked_or_run_out() {
        assert_eq!(Approved.apply(Revoke), Ok(Revoked));
        assert_eq!(Approved.apply(Expire), Ok(Expired));
        assert!(Pending.apply(Revoke).is_err());
        for s in [Denied, Expired, Revoked] {
            assert!(s.apply(Revoke).is_err());
            assert!(s.apply(Expire).is_err());
        }
    }

    #[test]
    fn legacy_rejected_reads_as_denied() {
        let s: ApprovalState = serde_json::from_str("\"rejected\"").unwrap();
        assert_eq!(s, Denied);
        assert_eq!(serde_json::to_string(&Denied).unwrap(), "\"denied\"");
    }

    #[test]
    fn timeout_is_strictly_after_ttl() {
        let t0 = Utc::now();
        let ttl = chrono::Duration::hours(1);
        assert!(!pending_timed_out(t0, t0 + ttl, ttl));
        assert!(pending_timed_out(
            t0,
            t0 + ttl + chrono::Duration::seconds(1),
            ttl
        ));
    }

    #[tokio::test]
    async fn persist_reports_failure() {
        let blocker = std::env::temp_dir().join(format!("approval-flow-{}", uuid::Uuid::new_v4()));
        std::fs::write(&blocker, b"a file, not a directory").unwrap();
        // The parent is a file: nothing can be written beneath it.
        assert!(persist_private(&blocker.join("state.json"), &1)
            .await
            .is_err());
        let ok = std::env::temp_dir().join(format!("approval-flow-{}", uuid::Uuid::new_v4()));
        assert!(persist_private(&ok.join("state.json"), &1).await.is_ok());
    }

    #[tokio::test]
    async fn wait_returns_on_decision() {
        let n = std::sync::Arc::new(tokio::sync::Notify::new());
        let state = std::sync::Arc::new(std::sync::Mutex::new(Pending));
        let (n2, s2) = (n.clone(), state.clone());
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            *s2.lock().unwrap() = Approved;
            n2.notify_waiters();
        });
        let got = wait_settled(&n, Duration::from_secs(5), || {
            let s = *state.lock().unwrap();
            async move { Some(s) }
        })
        .await;
        assert_eq!(got, Some(Approved));
    }

    #[test]
    fn requester_subject_canonical_and_display_labels_are_disjoint() {
        let id = Uuid::new_v4();
        let mission = RequesterSubject::mission(id);
        let ext = RequesterSubject::external_session(
            id,
            ExternalClientKind::LocalMcp,
            "claude-code",
            Some("macbook-air".into()),
        );
        assert_ne!(mission.canonical_id(), ext.canonical_id());
        assert!(!mission.same_actor(&ext));
        assert!(mission.canonical_id().starts_with("mission:"));
        assert!(ext.canonical_id().starts_with("session:"));
        assert_eq!(
            ext.external_display_label().as_deref(),
            Some("External · macbook-air (claude-code)")
        );
        let ext_other_label = RequesterSubject::external_session(
            id,
            ExternalClientKind::LocalMcp,
            "cursor",
            Some("macbook-air".into()),
        );
        assert_ne!(ext.canonical_id(), ext_other_label.canonical_id());
        assert!(ext.same_actor(&ext_other_label));
    }
}
