//! Managed VM lifecycle: the pure reap decision.
//!
//! Spec: `docs/specs/managed-vm-lifecycle.md`. The reaper and the reap-plan
//! endpoint both call [`decide`], so what Orb shows as "reaps in X" is exactly
//! what the reaper will do. The final destroy still passes the Lean gate
//! (`orb_vm_step`, op `reap_check`) in `ManagedManager::reap_once`.

use chrono::{DateTime, Duration, Utc};
use serde::Serialize;

/// Lifecycle of a machine's owning mission, as seen by the reaper.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OwnerState {
    /// Pending, active, waiting on a background job: the owner is working.
    Working,
    /// Interrupted, awaiting the user, blocked or paused since `since`. It may
    /// resume (deploy restarts interrupt missions), so only a long idle wait
    /// releases the machine.
    Waiting {
        status: &'static str,
        since: DateTime<Utc>,
    },
    /// Completed, failed, not feasible, cancelled or acknowledged.
    Terminal { status: &'static str },
    /// The mission no longer exists (deleted).
    Missing,
}

/// Who a machine belongs to, as the reaper sees it this pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Owner {
    /// A mission owns it; `None` when its store is not loaded (state unknown:
    /// never destroy on the owner rule).
    Mission(Option<OwnerState>),
    /// Created by a user from Orb or the API, without a mission.
    User,
    /// Legacy row: no owner was ever recorded.
    None,
}

/// Tunables (minutes). See the spec for defaults.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct LifecyclePolicy {
    /// Idle time before an idle machine whose owner is not working is reaped.
    pub idle_minutes: i64,
    /// Grace after the owner ended or vanished.
    pub ended_grace_minutes: i64,
    /// How long an owner may be interrupted/awaiting before its idle machine
    /// is released.
    pub waiting_grace_minutes: i64,
}

impl Default for LifecyclePolicy {
    fn default() -> Self {
        Self {
            idle_minutes: 30,
            ended_grace_minutes: 5,
            waiting_grace_minutes: 15,
        }
    }
}

/// Facts about one live machine for one reaper pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReapFacts {
    pub now: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    /// A job, lease or queued job is on the node (any mission).
    pub busy: bool,
    /// Last time the node was seen busy (or its creation time).
    pub idle_since: DateTime<Utc>,
    pub owner: Owner,
    /// Reap already scheduled by an earlier pass: (reason, due time). Keeps a
    /// grace that is counted from first observation stable across passes.
    pub scheduled: Option<(String, DateTime<Utc>)>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum ReapDecision {
    /// Nothing to do; any earlier schedule is cleared.
    Keep,
    /// A rule applies but its grace has not run out.
    Schedule { reason: String, at: DateTime<Utc> },
    /// Destroy now with this `destroy_reason`.
    Destroy { reason: String },
}

impl ReapDecision {
    pub fn reason(&self) -> Option<&str> {
        match self {
            Self::Keep => None,
            Self::Schedule { reason, .. } | Self::Destroy { reason } => Some(reason),
        }
    }
    /// True when the reason comes from the owner rule (Lean `ownerEnded`),
    /// false for the idle rule (Lean `idleExpired`).
    pub fn is_owner_rule(&self) -> bool {
        self.reason().is_some_and(|r| r.starts_with("owner_"))
    }
}

/// The reap decision table (spec, "Decision table").
pub fn decide(f: &ReapFacts, p: &LifecyclePolicy) -> ReapDecision {
    // 1. TTL is the hard backstop and applies even to a busy machine (boat
    //    stops it at TTL + 5 min regardless).
    if f.now >= f.expires_at {
        return ReapDecision::Destroy {
            reason: "ttl_expired".into(),
        };
    }
    // 2. Never destroy while any job or lease is active.
    if f.busy {
        return ReapDecision::Keep;
    }
    let idle_due = f.idle_since + Duration::minutes(p.idle_minutes);
    let (reason, due) = match f.owner {
        Owner::Mission(None) | Owner::Mission(Some(OwnerState::Working)) => {
            return ReapDecision::Keep
        }
        Owner::Mission(Some(OwnerState::Terminal { status })) => {
            let reason = format!("owner_{status}");
            (reason.clone(), grace_due(f, &reason, p.ended_grace_minutes))
        }
        Owner::Mission(Some(OwnerState::Missing)) => {
            let reason = "owner_missing".to_string();
            (reason.clone(), grace_due(f, &reason, p.ended_grace_minutes))
        }
        Owner::Mission(Some(OwnerState::Waiting { status, since })) => (
            format!("owner_{status}_idle"),
            idle_due.max(since + Duration::minutes(p.waiting_grace_minutes)),
        ),
        Owner::User => ("idle_user_owned".into(), idle_due),
        Owner::None => ("idle_no_owner".into(), idle_due),
    };
    if f.now >= due {
        ReapDecision::Destroy { reason }
    } else {
        ReapDecision::Schedule { reason, at: due }
    }
}

/// A grace counted from the first pass that saw the condition: reuse the
/// earlier schedule when it is for the same reason.
fn grace_due(f: &ReapFacts, reason: &str, minutes: i64) -> DateTime<Utc> {
    match &f.scheduled {
        Some((r, at)) if r == reason => *at,
        _ => f.now + Duration::minutes(minutes),
    }
}

/// Map a mission status (its Display string) and when it last changed to an
/// [`OwnerState`].
pub fn owner_state_for_status(status: &str, since: DateTime<Utc>) -> OwnerState {
    match status {
        "completed" => OwnerState::Terminal {
            status: "completed",
        },
        "failed" => OwnerState::Terminal { status: "failed" },
        "not_feasible" => OwnerState::Terminal {
            status: "not_feasible",
        },
        "acknowledged" => OwnerState::Terminal {
            status: "acknowledged",
        },
        "cancelled" => OwnerState::Terminal {
            status: "cancelled",
        },
        "archived" => OwnerState::Terminal { status: "archived" },
        "interrupted" => OwnerState::Waiting {
            status: "interrupted",
            since,
        },
        "awaiting_user" => OwnerState::Waiting {
            status: "awaiting_user",
            since,
        },
        "blocked" => OwnerState::Waiting {
            status: "blocked",
            since,
        },
        "paused" => OwnerState::Waiting {
            status: "paused",
            since,
        },
        _ => OwnerState::Working,
    }
}

/// Parent of a mission started from a Hermes session that belongs to a
/// mission (`orb_<mission uuid, simple form>`, see `cloud_agents::hermes`).
pub fn mission_of_orb_session(session: &str) -> Option<uuid::Uuid> {
    let raw = session.trim().strip_prefix("orb_")?;
    if raw.len() != 32 {
        return None;
    }
    uuid::Uuid::try_parse(raw).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(min: i64) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-10-23T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
            + Duration::minutes(min)
    }

    fn facts(owner: Owner) -> ReapFacts {
        ReapFacts {
            now: t(0),
            expires_at: t(600),
            busy: false,
            idle_since: t(-5),
            owner,
            scheduled: None,
        }
    }

    fn destroy(r: &str) -> ReapDecision {
        ReapDecision::Destroy { reason: r.into() }
    }

    const P: LifecyclePolicy = LifecyclePolicy {
        idle_minutes: 30,
        ended_grace_minutes: 5,
        waiting_grace_minutes: 60,
    };

    #[test]
    fn terminal_owner_is_reaped_after_grace_counted_from_first_sight() {
        let mut f = facts(Owner::Mission(Some(OwnerState::Terminal {
            status: "completed",
        })));
        let first = decide(&f, &P);
        assert_eq!(
            first,
            ReapDecision::Schedule {
                reason: "owner_completed".into(),
                at: t(5)
            }
        );
        // Later pass, schedule carried: due time does not move.
        f.now = t(3);
        f.scheduled = Some(("owner_completed".into(), t(5)));
        assert!(matches!(decide(&f, &P), ReapDecision::Schedule { at, .. } if at == t(5)));
        f.now = t(5);
        assert_eq!(decide(&f, &P), destroy("owner_completed"));
    }

    #[test]
    fn every_terminal_status_is_terminal() {
        for s in [
            "completed",
            "failed",
            "not_feasible",
            "acknowledged",
            "cancelled",
            "archived",
        ] {
            assert!(
                matches!(owner_state_for_status(s, t(0)), OwnerState::Terminal { status } if status == s),
                "{s}"
            );
        }
        for s in ["active", "pending", "waiting_background", "whatever"] {
            assert_eq!(owner_state_for_status(s, t(0)), OwnerState::Working, "{s}");
        }
        for s in ["interrupted", "awaiting_user", "blocked", "paused"] {
            assert!(matches!(
                owner_state_for_status(s, t(0)),
                OwnerState::Waiting { .. }
            ));
        }
    }

    #[test]
    fn interrupted_owner_releases_only_after_grace_and_idle() {
        let waiting = |since| {
            Owner::Mission(Some(OwnerState::Waiting {
                status: "interrupted",
                since,
            }))
        };
        // Interrupted 10 min ago (a deploy restart): keep, scheduled at grace end.
        let mut f = facts(waiting(t(-10)));
        assert_eq!(
            decide(&f, &P),
            ReapDecision::Schedule {
                reason: "owner_interrupted_idle".into(),
                at: t(50)
            }
        );
        // Interrupted 2 h ago, but the VM was busy 5 min ago: wait for idle.
        f.owner = waiting(t(-120));
        assert!(matches!(decide(&f, &P), ReapDecision::Schedule { at, .. } if at == t(25)));
        // Interrupted 2 h ago and idle 40 min: destroy.
        f.idle_since = t(-40);
        assert_eq!(decide(&f, &P), destroy("owner_interrupted_idle"));
        // awaiting_user follows the same rule.
        f.owner = Owner::Mission(Some(OwnerState::Waiting {
            status: "awaiting_user",
            since: t(-120),
        }));
        assert_eq!(decide(&f, &P), destroy("owner_awaiting_user_idle"));
    }

    #[test]
    fn busy_lease_protects_everything_but_ttl() {
        for owner in [
            Owner::Mission(Some(OwnerState::Terminal { status: "failed" })),
            Owner::Mission(Some(OwnerState::Missing)),
            Owner::None,
            Owner::User,
        ] {
            let mut f = facts(owner);
            f.busy = true;
            f.idle_since = t(-500);
            f.scheduled = Some(("owner_failed".into(), t(-1)));
            assert_eq!(decide(&f, &P), ReapDecision::Keep, "{owner:?}");
            f.now = t(600);
            assert_eq!(decide(&f, &P), destroy("ttl_expired"));
        }
    }

    #[test]
    fn missing_owner_is_reaped_after_grace() {
        let mut f = facts(Owner::Mission(Some(OwnerState::Missing)));
        f.scheduled = Some(("owner_missing".into(), t(-1)));
        assert_eq!(decide(&f, &P), destroy("owner_missing"));
        // A schedule for another reason restarts the grace.
        f.scheduled = Some(("idle_no_owner".into(), t(-1)));
        assert!(matches!(decide(&f, &P), ReapDecision::Schedule { at, .. } if at == t(5)));
    }

    #[test]
    fn working_or_unknown_owner_keeps_an_idle_machine() {
        for owner in [
            Owner::Mission(Some(OwnerState::Working)),
            Owner::Mission(None),
        ] {
            let mut f = facts(owner);
            f.idle_since = t(-500);
            assert_eq!(decide(&f, &P), ReapDecision::Keep);
        }
    }

    #[test]
    fn ownerless_and_user_machines_use_the_idle_reaper() {
        let mut f = facts(Owner::None);
        assert_eq!(
            decide(&f, &P),
            ReapDecision::Schedule {
                reason: "idle_no_owner".into(),
                at: t(25)
            }
        );
        f.idle_since = t(-31);
        assert_eq!(decide(&f, &P), destroy("idle_no_owner"));
        f.owner = Owner::User;
        assert_eq!(decide(&f, &P), destroy("idle_user_owned"));
    }

    #[test]
    fn ttl_expiry_wins() {
        let mut f = facts(Owner::Mission(Some(OwnerState::Working)));
        f.now = t(600);
        assert_eq!(decide(&f, &P), destroy("ttl_expired"));
    }

    #[test]
    fn owner_rule_flag() {
        assert!(destroy("owner_completed").is_owner_rule());
        assert!(!destroy("idle_no_owner").is_owner_rule());
        assert!(!ReapDecision::Keep.is_owner_rule());
    }

    #[test]
    fn orb_session_names_its_mission() {
        let id = uuid::Uuid::parse_str("910e3ce8-5acd-4b49-b58e-5e68b0b4cd87").unwrap();
        assert_eq!(
            mission_of_orb_session("orb_910e3ce85acd4b49b58e5e68b0b4cd87"),
            Some(id)
        );
        for s in [
            "20260805_night_supervision",
            "orb_m-other",
            "orb_910e3ce8-5acd-4b49-b58e-5e68b0b4cd87",
            "orb_",
        ] {
            assert_eq!(mission_of_orb_session(s), None, "{s}");
        }
    }
}
