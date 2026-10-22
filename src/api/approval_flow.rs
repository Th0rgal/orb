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
/// by the backend user only.
pub async fn persist_private<T: Serialize>(path: &Path, value: &T) {
    let Ok(text) = serde_json::to_string_pretty(value) else {
        return;
    };
    if let Some(dir) = path.parent() {
        let _ = tokio::fs::create_dir_all(dir).await;
    }
    let tmp = path.with_extension("json.tmp");
    if tokio::fs::write(&tmp, text).await.is_ok() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = tokio::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600)).await;
        }
        let _ = tokio::fs::rename(&tmp, path).await;
    }
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
}
