//! Managed VM lifecycle: the pure reap decision.
//!
//! Spec: `docs/specs/managed-vm-lifecycle.md`. The reaper and the reap-plan
//! endpoint both call [`decide`], so what Orb shows as "reaps in X" is exactly
//! what the reaper will do. Backed by the verified Lean stepper
//! `orb_vm_lifecycle_step` (`lean/Orb/Kernel.lean`) plus the final destroy
//! admission gate `orb_vm_step` (`reap_check`) in `ManagedManager::reap_once`.

use chrono::{DateTime, Duration, Utc};
use serde::Serialize;

use crate::orb_spec::{vm_lifecycle_step, VmLifecycleAction, VmLifecycleInput, VmOwnerClass};

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
    /// A mission owns it; `None` when neither its loaded nor persisted store
    /// could resolve it (state unknown: never destroy on the owner rule).
    Mission(Option<OwnerState>),
    /// Created by a user from Orb or the API, without a mission.
    User,
    /// Legacy row: no owner was ever recorded.
    None,
}

/// Tunables (minutes). See `docs/specs/managed-vm-lifecycle.md` for defaults.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct LifecyclePolicy {
    /// Idle time before an idle machine whose owner is not working is reaped.
    pub idle_minutes: i64,
    /// Idle time before an unused worker VM owned by a `Working` parent is
    /// reaped (`0` disables `Working`-owner idle reaping).
    pub working_idle_minutes: i64,
    /// Idle time after a worker VM has already completed at least one job
    /// (`has_executed_job = true`) while its `Working` parent moves on.
    pub post_job_working_idle_minutes: i64,
    /// Grace after the owner ended or vanished.
    pub ended_grace_minutes: i64,
    /// How long an owner may be interrupted/awaiting before its idle machine
    /// is released.
    pub waiting_grace_minutes: i64,
}

impl Default for LifecyclePolicy {
    fn default() -> Self {
        Self {
            idle_minutes: 15,
            working_idle_minutes: 15,
            post_job_working_idle_minutes: 5,
            ended_grace_minutes: 2,
            waiting_grace_minutes: 15,
        }
    }
}

/// Facts about one live machine for one reaper pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReapFacts {
    pub now: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    /// Optional minimum billing commitment (e.g. Scaleway Apple Silicon 24h
    /// `deletable_at`) before which provider deletion is forbidden.
    pub deletable_at: Option<DateTime<Utc>>,
    /// A job, lease or queued job is on the node (any mission).
    pub busy: bool,
    /// Whether this machine has ever been observed executing a job/lease.
    pub has_executed_job: bool,
    /// Whether stopping the VM ends provider billing (`true` on Boat, `false`
    /// on Hetzner, Vast.ai, and Scaleway).
    pub supports_free_stop: bool,
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
    /// A rule applies (or `deletable_at` is still in the future) and its due
    /// time has not yet arrived.
    Schedule { reason: String, at: DateTime<Utc> },
    /// Stop now (retaining disk without billing) with this reason.
    Stop { reason: String },
    /// Destroy now with this `destroy_reason`.
    Destroy { reason: String },
}

impl ReapDecision {
    pub fn reason(&self) -> Option<&str> {
        match self {
            Self::Keep => None,
            Self::Schedule { reason, .. } | Self::Stop { reason } | Self::Destroy { reason } => {
                Some(reason)
            }
        }
    }
    /// True when the reason comes from the owner rule (Lean `ownerEnded`),
    /// false for the idle rule (Lean `idleExpired`).
    pub fn is_owner_rule(&self) -> bool {
        self.reason().is_some_and(|r| r.starts_with("owner_"))
    }
}

/// The reap decision table (`docs/specs/managed-vm-lifecycle.md`), evaluated
/// through the verified `orb_vm_lifecycle_step` Lean kernel.
pub fn decide(f: &ReapFacts, p: &LifecyclePolicy) -> ReapDecision {
    let ttl_expired = f.now >= f.expires_at;
    let min_delete_pending = f.deletable_at.is_some_and(|del_at| f.now < del_at);
    let idle_due = f.idle_since + Duration::minutes(p.idle_minutes);

    if let Some((prior_cause, sched_at)) = f
        .scheduled
        .as_ref()
        .and_then(|(r, at)| r.strip_prefix("awaiting_deletable_at:").map(|c| (c, *at)))
    {
        let verdict = vm_lifecycle_step(VmLifecycleInput {
            ttl_expired,
            busy: f.busy,
            owner_class: VmOwnerClass::TerminalOrMissing,
            grace_or_idle_elapsed: true,
            working_idle_enabled: p.working_idle_minutes > 0,
            supports_free_stop: f.supports_free_stop,
            min_delete_pending,
        });
        return match verdict.action {
            VmLifecycleAction::Keep => ReapDecision::Keep,
            VmLifecycleAction::Schedule => ReapDecision::Schedule {
                reason: format!("awaiting_deletable_at:{prior_cause}"),
                at: f.deletable_at.unwrap_or(sched_at),
            },
            VmLifecycleAction::Stop => ReapDecision::Stop {
                reason: prior_cause.to_string(),
            },
            VmLifecycleAction::Destroy => ReapDecision::Destroy {
                reason: prior_cause.to_string(),
            },
        };
    }

    let (owner_class, base_reason, raw_due) = match f.owner {
        Owner::Mission(None) => (VmOwnerClass::Unknown, String::new(), f.expires_at),
        Owner::Mission(Some(OwnerState::Working)) => {
            let mins = if f.has_executed_job {
                p.post_job_working_idle_minutes.max(1)
            } else {
                p.working_idle_minutes.max(1)
            };
            (
                VmOwnerClass::Working,
                "working_owner_idle".to_string(),
                f.idle_since + Duration::minutes(mins),
            )
        }
        Owner::Mission(Some(OwnerState::Waiting { status, since })) => (
            VmOwnerClass::Waiting,
            format!("owner_{status}_idle"),
            idle_due.max(since + Duration::minutes(p.waiting_grace_minutes)),
        ),
        Owner::Mission(Some(OwnerState::Terminal { status })) => {
            let reason = format!("owner_{status}");
            let due = grace_due(f, &reason, p.ended_grace_minutes);
            (VmOwnerClass::TerminalOrMissing, reason, due)
        }
        Owner::Mission(Some(OwnerState::Missing)) => {
            let reason = "owner_missing".to_string();
            let due = grace_due(f, &reason, p.ended_grace_minutes);
            (VmOwnerClass::TerminalOrMissing, reason, due)
        }
        Owner::User => (
            VmOwnerClass::UserOrUnowned,
            "idle_user_owned".to_string(),
            idle_due,
        ),
        Owner::None => (
            VmOwnerClass::UserOrUnowned,
            "idle_no_owner".to_string(),
            idle_due,
        ),
    };

    let verdict = vm_lifecycle_step(VmLifecycleInput {
        ttl_expired,
        busy: f.busy,
        owner_class,
        grace_or_idle_elapsed: f.now >= raw_due,
        working_idle_enabled: p.working_idle_minutes > 0,
        supports_free_stop: f.supports_free_stop,
        min_delete_pending,
    });

    match verdict.action {
        VmLifecycleAction::Keep => ReapDecision::Keep,
        VmLifecycleAction::Schedule => {
            if verdict.defer_for_min_lease {
                let cause = if ttl_expired {
                    "ttl_expired"
                } else {
                    base_reason.as_str()
                };
                ReapDecision::Schedule {
                    reason: format!("awaiting_deletable_at:{cause}"),
                    at: f.deletable_at.unwrap_or(raw_due),
                }
            } else {
                ReapDecision::Schedule {
                    reason: base_reason,
                    at: raw_due,
                }
            }
        }
        VmLifecycleAction::Stop => ReapDecision::Stop {
            reason: base_reason,
        },
        VmLifecycleAction::Destroy => ReapDecision::Destroy {
            reason: if ttl_expired {
                "ttl_expired".into()
            } else {
                base_reason
            },
        },
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
            deletable_at: None,
            busy: false,
            has_executed_job: false,
            supports_free_stop: false,
            idle_since: t(-5),
            owner,
            scheduled: None,
        }
    }

    fn destroy(r: &str) -> ReapDecision {
        ReapDecision::Destroy { reason: r.into() }
    }

    fn stop(r: &str) -> ReapDecision {
        ReapDecision::Stop { reason: r.into() }
    }

    const P: LifecyclePolicy = LifecyclePolicy {
        idle_minutes: 30,
        working_idle_minutes: 15,
        post_job_working_idle_minutes: 5,
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
    fn interrupted_owner_stops_on_free_stop_provider_and_destroys_on_billed_provider() {
        let waiting = |since| {
            Owner::Mission(Some(OwnerState::Waiting {
                status: "interrupted",
                since,
            }))
        };
        let mut f = facts(waiting(t(-10)));
        assert_eq!(
            decide(&f, &P),
            ReapDecision::Schedule {
                reason: "owner_interrupted_idle".into(),
                at: t(50)
            }
        );
        f.owner = waiting(t(-120));
        assert!(matches!(decide(&f, &P), ReapDecision::Schedule { at, .. } if at == t(25)));
        f.idle_since = t(-40);
        // Billed while stopped (Hetzner / Vast.ai / Scaleway): must destroy!
        f.supports_free_stop = false;
        assert_eq!(decide(&f, &P), destroy("owner_interrupted_idle"));
        // Free stop (Boat): stops to retain disk without billing!
        f.supports_free_stop = true;
        assert_eq!(decide(&f, &P), stop("owner_interrupted_idle"));
        f.owner = Owner::Mission(Some(OwnerState::Waiting {
            status: "awaiting_user",
            since: t(-120),
        }));
        assert_eq!(decide(&f, &P), stop("owner_awaiting_user_idle"));
    }

    #[test]
    fn busy_lease_protects_everything_but_ttl() {
        for owner in [
            Owner::Mission(Some(OwnerState::Working)),
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
        f.scheduled = Some(("idle_no_owner".into(), t(-1)));
        assert!(matches!(decide(&f, &P), ReapDecision::Schedule { at, .. } if at == t(5)));
    }

    #[test]
    fn unknown_owner_always_keeps_idle_machine() {
        let mut f = facts(Owner::Mission(None));
        f.idle_since = t(-500);
        assert_eq!(decide(&f, &P), ReapDecision::Keep);
    }

    #[test]
    fn working_owner_idle_reaps_unused_and_post_job_workers() {
        // Coordinator spawned a worker VM via spawn_managed_machine: before first job,
        // working_idle_minutes (15m) applies.
        let mut f = facts(Owner::Mission(Some(OwnerState::Working)));
        f.idle_since = t(-5);
        assert_eq!(
            decide(&f, &P),
            ReapDecision::Schedule {
                reason: "working_owner_idle".into(),
                at: t(10),
            }
        );
        f.idle_since = t(-15);
        assert_eq!(decide(&f, &P), destroy("working_owner_idle"));

        // Once the worker executed a child job and became idle, tighter
        // post_job_working_idle_minutes (5m) releases it promptly.
        f.has_executed_job = true;
        f.idle_since = t(-3);
        assert_eq!(
            decide(&f, &P),
            ReapDecision::Schedule {
                reason: "working_owner_idle".into(),
                at: t(2),
            }
        );
        f.idle_since = t(-5);
        assert_eq!(decide(&f, &P), destroy("working_owner_idle"));

        // Setting working_idle_minutes = 0 disables Working-owner idle reaping.
        let mut disabled = P;
        disabled.working_idle_minutes = 0;
        f.idle_since = t(-500);
        assert_eq!(decide(&f, &disabled), ReapDecision::Keep);
    }

    #[test]
    fn deletable_at_defers_premature_destroy_including_ttl() {
        // Scaleway Apple Silicon 24h minimum lease: deletable_at in future defers Destroy -> Schedule.
        let mut f = facts(Owner::Mission(Some(OwnerState::Terminal {
            status: "completed",
        })));
        f.scheduled = Some(("owner_completed".into(), t(-1)));
        f.deletable_at = Some(t(1400));
        assert_eq!(
            decide(&f, &P),
            ReapDecision::Schedule {
                reason: "awaiting_deletable_at:owner_completed".into(),
                at: t(1400),
            }
        );
        // Even TTL expiry defers the provider DELETE until deletable_at.
        f.now = t(600);
        assert_eq!(
            decide(&f, &P),
            ReapDecision::Schedule {
                reason: "awaiting_deletable_at:ttl_expired".into(),
                at: t(1400),
            }
        );
        // Once deletable_at arrives, Destroy fires immediately.
        f.now = t(1400);
        assert_eq!(decide(&f, &P), destroy("ttl_expired"));
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
        assert!(!destroy("working_owner_idle").is_owner_rule());
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
