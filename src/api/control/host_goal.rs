//! Host-side goal loop for remote harnesses without a native goal driver.
//!
//! Codex and Antigravity run `/goal` natively and report its state; Grok has
//! the server-driven automation in `grok_goal`. Remote OpenCode has neither,
//! so the end of a goal turn only means the model stopped for now. Treating
//! that as success marked continuous objectives ("never stop, report every
//! 30 min") complete and disarmed goal mode (mission 4ad4bc01, 13:38Z).
//!
//! Core drives the loop instead. When a goal turn ends, in order:
//! 1. the goal is no longer armed (user Stop disarmed it): nothing;
//! 2. the agent wrote a completion marker (`<!-- GOAL_COMPLETE -->`, the
//!    Antigravity convention, or Grok's `<goal_complete/>`): complete;
//!    `<goal_aborted reason="..."/>` aborts;
//! 3. a host continuation is already queued: stay active, queue nothing;
//! 4. the agent armed its own wake-up: paused until it fires;
//! 5. too many consecutive turns without a tool call: paused, user notified;
//! 6. the continuation budget is spent: budget_limited;
//! 7. otherwise a one-shot continuation wake-up is queued after a short delay.
//!
//! The continuation is an ordinary durable wake-up, so user Stop fences it
//! (`continuations::stop_for_mission`) and a newer wake-up supersedes it:
//! at most one continuation is ever pending per mission.

use std::collections::HashMap;

use crate::api::mission_store::Automation;

/// `__wakeup_source` of a host goal continuation.
pub(crate) const SOURCE: &str = "host-goal";
pub(crate) const VAR_OBJECTIVE: &str = "__goal_objective";
pub(crate) const VAR_NO_PROGRESS: &str = "__goal_no_progress";
pub(crate) const VAR_CONTINUATIONS: &str = "__goal_continuations";

const DEFAULT_DELAY_SECS: u64 = 60;
const DEFAULT_MAX_NO_PROGRESS: u32 = 3;

/// Harnesses whose remote goal loop Core drives.
pub(crate) fn host_drives_goal(backend: &str) -> bool {
    backend == "opencode"
}

fn env_u64(name: &str) -> Option<u64> {
    std::env::var(name).ok()?.trim().parse().ok()
}

/// Delay before a continuation turn (`SANDBOXED_HOST_GOAL_CONTINUATION_SECS`).
pub(crate) fn continuation_delay_secs() -> u64 {
    env_u64("SANDBOXED_HOST_GOAL_CONTINUATION_SECS")
        .filter(|v| *v > 0)
        .unwrap_or(DEFAULT_DELAY_SECS)
}

/// Consecutive no-progress turns before pausing
/// (`SANDBOXED_HOST_GOAL_MAX_NO_PROGRESS`).
pub(crate) fn max_no_progress() -> u32 {
    env_u64("SANDBOXED_HOST_GOAL_MAX_NO_PROGRESS")
        .filter(|v| *v > 0)
        .and_then(|v| u32::try_from(v).ok())
        .unwrap_or(DEFAULT_MAX_NO_PROGRESS)
}

/// Total continuation budget (`SANDBOXED_HOST_GOAL_MAX_CONTINUATIONS`);
/// unset or 0 is unlimited, since objectives can be continuous.
pub(crate) fn max_continuations() -> Option<u32> {
    env_u64("SANDBOXED_HOST_GOAL_MAX_CONTINUATIONS")
        .filter(|v| *v > 0)
        .and_then(|v| u32::try_from(v).ok())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Signal {
    Complete,
    Aborted(String),
    None,
}

/// Explicit completion signal in the agent's final text.
pub(crate) fn signal(text: &str) -> Signal {
    if text.contains("<!-- GOAL_COMPLETE -->") {
        return Signal::Complete;
    }
    match crate::api::grok_goal::parse_goal_sentinel(text) {
        crate::api::grok_goal::GoalSentinel::Complete => Signal::Complete,
        crate::api::grok_goal::GoalSentinel::Aborted { reason } => Signal::Aborted(reason),
        _ => Signal::None,
    }
}

#[derive(Debug, Clone, Default)]
pub(crate) struct Input<'a> {
    pub(crate) text: &'a str,
    /// Persisted goal mode re-read at the end of the turn (Stop clears it).
    pub(crate) armed: bool,
    pub(crate) continuation_pending: bool,
    /// Another (agent-armed) wake-up is pending.
    pub(crate) wakeup_armed: bool,
    /// The turn made a tool call (edits are tool calls).
    pub(crate) made_progress: bool,
    pub(crate) prior_no_progress: u32,
    pub(crate) prior_continuations: u32,
    pub(crate) max_no_progress: u32,
    pub(crate) max_continuations: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// Goal disarmed by the user: no status, no continuation.
    Stopped,
    Complete,
    Aborted(String),
    /// A continuation is already queued; do not queue another.
    AlreadyQueued,
    /// Waiting for the agent's own wake-up.
    Paused,
    /// Too many turns without progress; the user is told.
    Stalled {
        turns: u32,
    },
    BudgetLimited,
    Continue {
        no_progress: u32,
        continuations: u32,
    },
}

impl Outcome {
    /// `goal_status` reported for this outcome.
    pub(crate) fn status(&self) -> Option<String> {
        Some(match self {
            Outcome::Stopped => return None,
            Outcome::Complete => "complete".into(),
            Outcome::Aborted(reason) => format!("aborted:{reason}"),
            Outcome::AlreadyQueued | Outcome::Continue { .. } => "active".into(),
            Outcome::Paused | Outcome::Stalled { .. } => "paused".into(),
            Outcome::BudgetLimited => "budget_limited".into(),
        })
    }
}

pub(crate) fn decide(input: &Input<'_>) -> Outcome {
    let parsed_signal = signal(input.text);
    let signal_code = match &parsed_signal {
        Signal::None => 0,
        Signal::Complete => 1,
        Signal::Aborted(_) => 2,
    };
    let no_progress = if input.made_progress {
        0
    } else {
        input.prior_no_progress.saturating_add(1)
    };
    let continuations = input.prior_continuations.saturating_add(1);
    match crate::orb_spec::mission_step(crate::orb_spec::MissionStepInput {
        armed: input.armed,
        signal: signal_code,
        continuation_pending: input.continuation_pending,
        wakeup_armed: input.wakeup_armed,
        made_progress: input.made_progress,
        prior_no_progress: input.prior_no_progress,
        max_no_progress: input.max_no_progress,
        prior_continuations: input.prior_continuations,
        max_continuations: input.max_continuations.unwrap_or(0),
        has_max_continuations: input.max_continuations.is_some(),
    }) {
        crate::orb_spec::MissionStepOutcome::Stopped => Outcome::Stopped,
        crate::orb_spec::MissionStepOutcome::Complete => Outcome::Complete,
        crate::orb_spec::MissionStepOutcome::Aborted => match parsed_signal {
            Signal::Aborted(reason) => Outcome::Aborted(reason),
            _ => Outcome::Aborted(String::new()),
        },
        crate::orb_spec::MissionStepOutcome::AlreadyQueued => Outcome::AlreadyQueued,
        crate::orb_spec::MissionStepOutcome::PausedWakeup => Outcome::Paused,
        crate::orb_spec::MissionStepOutcome::Stalled => Outcome::Stalled { turns: no_progress },
        crate::orb_spec::MissionStepOutcome::BudgetLimited => Outcome::BudgetLimited,
        crate::orb_spec::MissionStepOutcome::ContinueGoal => Outcome::Continue {
            no_progress,
            continuations,
        },
    }
}

/// Counters carried by the latest continuation for this objective.
pub(crate) fn prior_counters(rows: &[Automation], objective: &str) -> (u32, u32) {
    rows.iter()
        .filter(|a| {
            a.variables.get("__wakeup_source").map(String::as_str) == Some(SOURCE)
                && a.variables.get(VAR_OBJECTIVE).map(String::as_str) == Some(objective)
        })
        .max_by(|a, b| a.created_at.cmp(&b.created_at))
        .map(|a| {
            let get = |key| {
                a.variables
                    .get(key)
                    .and_then(|v: &String| v.parse().ok())
                    .unwrap_or(0)
            };
            (get(VAR_NO_PROGRESS), get(VAR_CONTINUATIONS))
        })
        .unwrap_or((0, 0))
}

/// Pending wake-ups: (host continuation, any other wake-up).
pub(crate) fn pending(rows: &[Automation]) -> (bool, bool) {
    let mut continuation = false;
    let mut other = false;
    for a in rows.iter().filter(|a| a.active) {
        match a.variables.get("__wakeup_source").map(String::as_str) {
            Some(SOURCE) => continuation = true,
            Some(_) => other = true,
            None => {}
        }
    }
    (continuation, other)
}

pub(crate) fn continuation_prompt(objective: &str) -> String {
    format!(
        "[Goal mode: automatic continuation]\n\
         Objective: {objective}\n\n\
         Your previous turn ended, but the goal is still active. Take the next \
         concrete step toward the objective now, then give a short progress \
         report (what you did, what is next).\n\
         - If the objective is fully achieved, end your reply with \
         `<!-- GOAL_COMPLETE -->` on its own line.\n\
         - If you need to wait until a specific time, schedule a wake-up \
         instead of ending the turn idle.\n\
         - If the objective is continuous, never mark it complete: keep working."
    )
}

pub(crate) fn variables(
    objective: &str,
    reason: &str,
    request_id: String,
    no_progress: u32,
    continuations: u32,
) -> HashMap<String, String> {
    HashMap::from([
        ("__wakeup_source".into(), SOURCE.into()),
        ("__wakeup_reason".into(), reason.into()),
        ("__wakeup_request_id".into(), request_id),
        (VAR_OBJECTIVE.into(), objective.into()),
        (VAR_NO_PROGRESS.into(), no_progress.to_string()),
        (VAR_CONTINUATIONS.into(), continuations.to_string()),
    ])
}

pub(crate) fn stalled_notice(turns: u32) -> String {
    format!(
        "Goal paused: {turns} consecutive turns made no tool calls or edits, so Orb stopped \
         continuing automatically. Send a message (or /goal again) to resume."
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(text: &str) -> Input<'_> {
        Input {
            text,
            armed: true,
            max_no_progress: 3,
            made_progress: true,
            ..Default::default()
        }
    }

    #[test]
    fn turn_without_marker_or_wakeup_gets_a_continuation() {
        let outcome = decide(&input("Progress report: did X, next Y."));
        assert_eq!(
            outcome,
            Outcome::Continue {
                no_progress: 0,
                continuations: 1
            }
        );
        assert_eq!(outcome.status().as_deref(), Some("active"));
    }

    #[test]
    fn marker_gives_complete() {
        for text in ["Done.\n<!-- GOAL_COMPLETE -->", "Done. <goal_complete/>"] {
            let outcome = decide(&input(text));
            assert_eq!(outcome, Outcome::Complete);
            assert_eq!(outcome.status().as_deref(), Some("complete"));
        }
    }

    #[test]
    fn armed_wakeup_gives_paused() {
        let outcome = decide(&Input {
            wakeup_armed: true,
            ..input("Waiting for 06:00.")
        });
        assert_eq!(outcome, Outcome::Paused);
        assert_eq!(outcome.status().as_deref(), Some("paused"));
    }

    #[test]
    fn three_no_progress_turns_pause_and_notify() {
        let mut prior = 0;
        let mut outcomes = Vec::new();
        for _ in 0..3 {
            let outcome = decide(&Input {
                made_progress: false,
                prior_no_progress: prior,
                ..input("Still thinking.")
            });
            if let Outcome::Continue { no_progress, .. } = outcome {
                prior = no_progress;
            }
            outcomes.push(outcome);
        }
        assert!(matches!(outcomes[0], Outcome::Continue { .. }));
        assert!(matches!(outcomes[1], Outcome::Continue { .. }));
        assert_eq!(outcomes[2], Outcome::Stalled { turns: 3 });
        assert_eq!(outcomes[2].status().as_deref(), Some("paused"));
        assert!(stalled_notice(3).contains("3 consecutive turns"));
        // A tool call resets the streak.
        assert!(matches!(
            decide(&Input {
                prior_no_progress: 2,
                ..input("Edited a file.")
            }),
            Outcome::Continue { no_progress: 0, .. }
        ));
    }

    #[test]
    fn user_stop_gives_no_continuation() {
        let outcome = decide(&Input {
            armed: false,
            ..input("Progress report.")
        });
        assert_eq!(outcome, Outcome::Stopped);
        assert_eq!(outcome.status(), None);
    }

    #[test]
    fn only_one_continuation_and_budget_is_honoured() {
        assert_eq!(
            decide(&Input {
                continuation_pending: true,
                ..input("report")
            }),
            Outcome::AlreadyQueued
        );
        assert_eq!(
            decide(&Input {
                prior_continuations: 5,
                max_continuations: Some(5),
                ..input("report")
            }),
            Outcome::BudgetLimited
        );
    }
}
