//! Goal-loop handling: stall guard, automation stop policies, Grok goal kickoff and goal mode transitions.

use super::*;

/// Stall-guard: number of consecutive auto-armed fallback wakeups per mission,
/// since the last real user message or self-armed automation. Bounds how many
/// times the server will auto-resume an orchestrator that keeps parking without
/// scheduling its own wakeup, so a genuinely-finished orchestrator isn't woken
/// forever (after the cap it's left for a human).
pub(super) static STALL_GUARD_CONSECUTIVE_ARMS: std::sync::LazyLock<
    std::sync::Mutex<HashMap<Uuid, u32>>,
> = std::sync::LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

pub(super) const STALL_GUARD_MAX_CONSECUTIVE_ARMS: u32 = 3;
pub(super) const STALL_GUARD_WAKEUP_SECONDS: u64 = 1200;

/// Clear a mission's stall-guard counter — called when a real user message
/// arrives (the operator is steering it) so the guard's budget resets.
pub(crate) fn reset_stall_guard(mission_id: Uuid) {
    if let Ok(mut m) = STALL_GUARD_CONSECUTIVE_ARMS.lock() {
        m.remove(&mission_id);
    }
}

/// If an orchestrator mission (one that has spawned child missions) parks in
/// `AwaitingUser` with no active automation, arm a one-shot fallback wakeup so
/// it re-checks and continues instead of stalling on an auto-notification that
/// won't arrive. Leaf missions (no children) are never touched, so a mission
/// legitimately awaiting a human answer is never auto-resumed. Bounded per
/// mission; a no-op when the agent already armed its own wakeup.
/// Returns `true` when a fallback wakeup was armed (used by tests; callers may
/// ignore it).
pub(super) async fn maybe_arm_stall_guard_wakeup(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
) -> bool {
    // Only orchestrators are guarded — leaf missions awaiting a human are not.
    let has_children = mission_store
        .get_child_missions(mission_id)
        .await
        .map(|c| !c.is_empty())
        .unwrap_or(false);
    if !has_children {
        return false;
    }
    // The agent self-armed a wakeup → it manages its own cadence; reset + skip.
    if mission_has_active_automation(mission_store, mission_id).await {
        reset_stall_guard(mission_id);
        return false;
    }
    // Bound consecutive auto-arms.
    let count = {
        let Ok(mut m) = STALL_GUARD_CONSECUTIVE_ARMS.lock() else {
            return false;
        };
        let c = m.entry(mission_id).or_insert(0);
        if *c >= STALL_GUARD_MAX_CONSECUTIVE_ARMS {
            return false;
        }
        *c += 1;
        *c
    };
    tracing::info!(
        mission_id = %mission_id,
        arm = count,
        max = STALL_GUARD_MAX_CONSECUTIVE_ARMS,
        "Stall-guard: orchestrator parked in awaiting_user with no wakeup armed; arming fallback"
    );
    let prompt = "Auto-resume (stall-guard): your previous turn ended in awaiting_user \
without scheduling a wakeup, but you are an orchestrator with work that may still be in \
flight. Re-check your workers / board tasks / open PRs + CI and continue. If something is \
genuinely async (CI, a long build), call ScheduleWakeup so you resume yourself. If \
everything is truly done, report completion and stop."
        .to_string();
    let reason = format!(
        "stall-guard auto-resume {}/{} (orchestrator parked with no wakeup armed)",
        count, STALL_GUARD_MAX_CONSECUTIVE_ARMS
    );
    crate::api::mission_runner::spawn_claude_builtin_wakeup_automation(
        mission_id,
        STALL_GUARD_WAKEUP_SECONDS,
        prompt,
        reason,
    );
    true
}

pub(super) async fn mission_has_active_automation(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
) -> bool {
    match mission_store.get_mission_automations(mission_id).await {
        Ok(automations) => automations.iter().any(|automation| automation.active),
        Err(err) => {
            tracing::warn!(
                "Failed to load automations for mission {}: {}",
                mission_id,
                err
            );
            false
        }
    }
}

pub(super) fn mission_is_terminal_for_goal_loop(status: MissionStatus) -> bool {
    matches!(
        status,
        MissionStatus::Acknowledged
            | MissionStatus::Completed
            | MissionStatus::Failed
            | MissionStatus::Interrupted
            | MissionStatus::NotFeasible
            | MissionStatus::Paused
    )
}

pub(super) async fn stop_policy_matches_status(
    stop_policy: &mission_store::StopPolicy,
    status: MissionStatus,
    consecutive_failures: u32,
    has_fired: bool,
) -> bool {
    match stop_policy {
        mission_store::StopPolicy::Never => false,
        mission_store::StopPolicy::WhenMissionTerminal => mission_is_terminal_for_goal_loop(status),
        mission_store::StopPolicy::WhenFailingConsecutively { count } => {
            consecutive_failures >= *count
        }
        mission_store::StopPolicy::WhenAllIssuesClosedAndPRsMerged { repo } => {
            check_github_all_issues_closed_and_prs_merged(repo).await
        }
        mission_store::StopPolicy::AfterFirstFire => has_fired,
    }
}

pub(super) async fn automation_has_fired(
    mission_store: &Arc<dyn mission_store::MissionStore>,
    automation_id: Uuid,
) -> bool {
    match mission_store
        .get_automation_executions(automation_id, Some(1))
        .await
    {
        Ok(executions) => !executions.is_empty(),
        Err(e) => {
            tracing::warn!(
                "Failed to load executions for automation {} while evaluating stop policy: {}",
                automation_id,
                e
            );
            false
        }
    }
}

pub(super) async fn consecutive_failure_count_for_automation(
    mission_store: &Arc<dyn MissionStore>,
    automation: &mission_store::Automation,
) -> u32 {
    if !matches!(
        automation.stop_policy,
        mission_store::StopPolicy::WhenFailingConsecutively { .. }
    ) {
        return 0;
    }

    let executions = mission_store
        .get_automation_executions(automation.id, Some(20))
        .await
        .unwrap_or_default();
    let mut count = 0u32;
    for exec in executions.iter().take(20) {
        match exec.status {
            mission_store::ExecutionStatus::Failed => count += 1,
            mission_store::ExecutionStatus::Success => break,
            _ => {}
        }
    }
    count
}

pub(super) async fn check_github_all_issues_closed_and_prs_merged(repo: &str) -> bool {
    let client = reqwest::Client::new();

    let issues_url = format!("https://api.github.com/repos/{}/issues?state=open", repo);
    let pulls_url = format!("https://api.github.com/repos/{}/pulls?state=open", repo);

    let check_repo = async {
        let issues_resp = client
            .get(&issues_url)
            .header("User-Agent", "sandboxed-sh")
            .header("Accept", "application/vnd.github.v3+json")
            .send()
            .await;

        let pulls_resp = client
            .get(&pulls_url)
            .header("User-Agent", "sandboxed-sh")
            .header("Accept", "application/vnd.github.v3+json")
            .send()
            .await;

        let has_open_issues = match issues_resp {
            Ok(resp) => match resp.json::<serde_json::Value>().await {
                Ok(value) => value.as_array().map(|arr| !arr.is_empty()).unwrap_or(false),
                Err(_) => false,
            },
            Err(_) => false,
        };

        let has_open_prs = match pulls_resp {
            Ok(resp) => match resp.json::<serde_json::Value>().await {
                Ok(value) => value.as_array().map(|arr| !arr.is_empty()).unwrap_or(false),
                Err(_) => false,
            },
            Err(_) => false,
        };

        !has_open_issues && !has_open_prs
    };

    tokio::time::timeout(std::time::Duration::from_secs(10), check_repo)
        .await
        .unwrap_or(false)
}

/// Outcome of [`maybe_begin_grok_goal`]: either a rewritten first-turn
/// prompt (the message should now carry this content) or a user-facing
/// error to surface in the message ack.
pub(crate) enum GrokGoalKickoff {
    /// Not a grok-goal request; queue the original content unchanged.
    Passthrough,
    /// `/goal X` accepted; queue `prompt` (the wrapped first-turn prompt)
    /// in place of the original message content.
    Rewritten { prompt: String },
    /// `/goal X` rejected — surface this string to the user.
    Rejected { reason: String },
}

/// Detect `/goal <objective>` for a grok mission and, if recognised,
/// create the AgentFinished-driven automation row that will iterate the
/// loop. Returns the wrapped first-turn prompt to use in place of the
/// raw `/goal X` message.
///
/// Non-grok backends fall through unchanged — claudecode and codex have
/// their own `/goal` handling (CLI-native and `thread/goal/set`
/// respectively); only grok needs sandboxed.sh to drive iteration.
pub(super) async fn maybe_begin_grok_goal(
    mission_store: &Arc<dyn MissionStore>,
    events_tx: &broadcast::Sender<AgentEvent>,
    mission_id: Option<Uuid>,
    content: &str,
) -> GrokGoalKickoff {
    let (is_goal, objective) = super::super::grok_goal::parse_goal_prefix(content);
    if !is_goal {
        return GrokGoalKickoff::Passthrough;
    }
    let Some(mid) = mission_id else {
        // No target mission resolved yet (auto-create path) — let the
        // normal flow create a mission, then we'll catch the next turn.
        // For now treat as passthrough; the user can re-send `/goal X`
        // once the mission exists. This avoids a chicken/egg with
        // mission creation happening *after* this hook.
        return GrokGoalKickoff::Passthrough;
    };
    if !matches!(
        lookup_mission_backend(mission_store, mid).await.as_deref(),
        Some("grok")
    ) {
        return GrokGoalKickoff::Passthrough;
    }
    if objective.is_empty() {
        return GrokGoalKickoff::Rejected {
            reason: "/goal requires an objective (e.g. `/goal write the docs`)".to_string(),
        };
    }
    if super::super::grok_goal::active_goal_for_mission(mission_store, mid)
        .await
        .is_some()
    {
        return GrokGoalKickoff::Rejected {
            reason: "this mission already has an active /goal loop — wait for it to finish or cancel before starting a new one".to_string(),
        };
    }
    if let Err(e) =
        super::super::grok_goal::create_goal_automation(mission_store, mid, &objective).await
    {
        tracing::warn!(
            "grok_goal: failed to create automation for mission {}: {}",
            mid,
            e
        );
        return GrokGoalKickoff::Rejected {
            reason: format!("failed to set up /goal loop: {}", e),
        };
    }
    tracing::info!(
        mission_id = %mid,
        objective_len = objective.len(),
        "grok_goal: started loop"
    );
    let _ = events_tx.send(AgentEvent::GoalIteration {
        iteration: 1,
        objective: objective.clone(),
        mission_id: Some(mid),
    });
    GrokGoalKickoff::Rewritten {
        prompt: super::super::grok_goal::first_turn_prompt(&objective),
    }
}

/// Post-turn hook for grok-goal missions. Parses the sentinel from the
/// assistant's final text and either ends the loop (terminal sentinel,
/// budget exhausted, sentinel-missing streak, or explicit cancellation)
/// or bumps the iteration counter so the existing AgentFinished hook
/// re-fires the continuation prompt.
///
/// `terminal_reason` is the runner's structured exit reason. A `Cancelled`
/// turn ends the loop immediately with status `aborted:cancelled` —
/// otherwise the cancelled output (typically the literal string
/// `"Cancelled"`) would look like a sentinel-missing turn and burn through
/// the missing-count budget before the loop tore down.
pub(super) async fn post_turn_handle_grok_goal(
    mission_store: &Arc<dyn MissionStore>,
    events_tx: &broadcast::Sender<AgentEvent>,
    mission_id: Uuid,
    assistant_text: &str,
    terminal_reason: Option<TerminalReason>,
) {
    let Some(mut row) =
        super::super::grok_goal::active_goal_for_mission(mission_store, mission_id).await
    else {
        return;
    };
    let objective = super::super::grok_goal::objective_of(&row);
    let iteration = super::super::grok_goal::iteration_of(&row);
    let prev_missing = super::super::grok_goal::missing_count_of(&row);

    // Cancellation short-circuits sentinel parsing — there's no agent
    // output to interpret and continuing the loop would re-fire prompts
    // after the user explicitly stopped the mission.
    if matches!(terminal_reason, Some(TerminalReason::Cancelled)) {
        if let Err(e) = super::super::grok_goal::disable_goal(mission_store, &mut row).await {
            tracing::warn!("grok_goal: disable_goal failed: {}", e);
        }
        let _ = events_tx.send(AgentEvent::GoalStatus {
            status: "aborted:cancelled".to_string(),
            objective,
            mission_id: Some(mission_id),
        });
        return;
    }

    let sentinel = super::super::grok_goal::parse_goal_sentinel(assistant_text);
    tracing::info!(
        mission_id = %mission_id,
        iteration,
        prev_missing,
        ?sentinel,
        "grok_goal: post-turn sentinel"
    );
    match sentinel {
        super::super::grok_goal::GoalSentinel::Complete => {
            if let Err(e) = super::super::grok_goal::record_decision(
                mission_store,
                &mut row,
                &sentinel,
                "complete",
                "high",
            )
            .await
            {
                tracing::warn!("grok_goal: record_decision failed: {}", e);
            }
            if let Err(e) = super::super::grok_goal::disable_goal(mission_store, &mut row).await {
                tracing::warn!("grok_goal: disable_goal failed: {}", e);
            }
            let _ = events_tx.send(AgentEvent::GoalStatus {
                status: "complete".to_string(),
                objective,
                mission_id: Some(mission_id),
            });
        }
        super::super::grok_goal::GoalSentinel::Aborted { ref reason } => {
            if let Err(e) = super::super::grok_goal::record_decision(
                mission_store,
                &mut row,
                &sentinel,
                "aborted",
                "high",
            )
            .await
            {
                tracing::warn!("grok_goal: record_decision failed: {}", e);
            }
            if let Err(e) = super::super::grok_goal::disable_goal(mission_store, &mut row).await {
                tracing::warn!("grok_goal: disable_goal failed: {}", e);
            }
            let _ = events_tx.send(AgentEvent::GoalStatus {
                status: format!("aborted:{}", reason),
                objective,
                mission_id: Some(mission_id),
            });
        }
        super::super::grok_goal::GoalSentinel::Continue
        | super::super::grok_goal::GoalSentinel::Missing => {
            let was_missing = matches!(sentinel, super::super::grok_goal::GoalSentinel::Missing);
            let new_missing = if was_missing {
                prev_missing.saturating_add(1)
            } else {
                0
            };
            if new_missing >= super::super::grok_goal::MAX_MISSING_SENTINELS {
                if let Err(e) = super::super::grok_goal::record_decision(
                    mission_store,
                    &mut row,
                    &sentinel,
                    "aborted:no_goal_sentinel",
                    "low",
                )
                .await
                {
                    tracing::warn!("grok_goal: record_decision failed: {}", e);
                }
                if let Err(e) = super::super::grok_goal::disable_goal(mission_store, &mut row).await
                {
                    tracing::warn!("grok_goal: disable_goal failed: {}", e);
                }
                let _ = events_tx.send(AgentEvent::GoalStatus {
                    status: "aborted:no_goal_sentinel".to_string(),
                    objective,
                    mission_id: Some(mission_id),
                });
                return;
            }
            let next_iter = iteration.saturating_add(1);
            if next_iter > super::super::grok_goal::MAX_ITERATIONS {
                if let Err(e) = super::super::grok_goal::record_decision(
                    mission_store,
                    &mut row,
                    &sentinel,
                    "budget_limited",
                    "medium",
                )
                .await
                {
                    tracing::warn!("grok_goal: record_decision failed: {}", e);
                }
                if let Err(e) = super::super::grok_goal::disable_goal(mission_store, &mut row).await
                {
                    tracing::warn!("grok_goal: disable_goal failed: {}", e);
                }
                let _ = events_tx.send(AgentEvent::GoalStatus {
                    status: "budget_limited".to_string(),
                    objective,
                    mission_id: Some(mission_id),
                });
                return;
            }
            if let Err(e) = super::super::grok_goal::update_counters(
                mission_store,
                &mut row,
                next_iter,
                new_missing,
            )
            .await
            {
                tracing::warn!("grok_goal: update_counters failed: {}", e);
            }
            let decision = if was_missing {
                "continue:missing_sentinel"
            } else {
                "continue"
            };
            if let Err(e) = super::super::grok_goal::record_decision(
                mission_store,
                &mut row,
                &sentinel,
                decision,
                if was_missing { "low" } else { "high" },
            )
            .await
            {
                tracing::warn!("grok_goal: record_decision failed: {}", e);
            }
            let _ = events_tx.send(AgentEvent::GoalIteration {
                iteration: next_iter,
                objective,
                mission_id: Some(mission_id),
            });
        }
    }
}

pub(super) fn queue_has_pending_target_mission(
    queue: &VecDeque<ControlQueueEntry>,
    mission_id: Uuid,
) -> bool {
    queue
        .iter()
        .any(|(_id, _msg, _agent, target_mid, _source)| *target_mid == Some(mission_id))
}

pub(super) fn accept_user_message_id(accepted: &mut HashSet<Uuid>, id: Uuid) -> bool {
    accepted.insert(id)
}

pub(super) fn mission_status_for_terminal_reason(
    reason: TerminalReason,
    complete_turn_without_follow_up: bool,
) -> Option<(MissionStatus, &'static str)> {
    match reason {
        TerminalReason::TurnComplete if complete_turn_without_follow_up => {
            // Agent finished its turn cleanly and there is no queued follow-up
            // message or scheduled wakeup — the mission is parked waiting for
            // the user to read it. The dashboard / iOS clients surface this in
            // the "Needs You" column. An explicit `TerminalReason::Completed`
            // (the path below) is used when the agent declares the work fully
            // done, not just a turn boundary.
            Some((MissionStatus::AwaitingUser, "turn_complete"))
        }
        TerminalReason::TurnComplete => None,
        TerminalReason::Completed => Some((MissionStatus::Completed, "completed")),
        TerminalReason::NativeGoalStopped => Some((MissionStatus::Blocked, "native_goal_stopped")),
        TerminalReason::CodexContinuityRequired => {
            Some((MissionStatus::Blocked, "codex_continuity_required"))
        }
        TerminalReason::NativeContinuityRequired => {
            Some((MissionStatus::Blocked, "native_continuity_required"))
        }
        TerminalReason::Cancelled => Some((MissionStatus::Interrupted, "cancelled")),
        TerminalReason::ServerShutdown => Some((MissionStatus::Interrupted, "server_shutdown")),
        TerminalReason::MaxIterations => Some((MissionStatus::Blocked, "max_iterations")),
        TerminalReason::LlmError => Some((MissionStatus::Failed, "llm_error")),
        TerminalReason::Stalled => Some((MissionStatus::Failed, "stalled")),
        TerminalReason::InfiniteLoop => Some((MissionStatus::Failed, "infinite_loop")),
        TerminalReason::RateLimited => Some((MissionStatus::Failed, "rate_limited")),
        TerminalReason::CapacityLimited => Some((MissionStatus::Failed, "capacity_limited")),
        TerminalReason::AuthError => Some((MissionStatus::Failed, "auth_error")),
    }
}

/// Classify *why* a mission is parking in `AwaitingUser` by inspecting the last
/// assistant message: a trailing question (or interrogative phrasing) means the
/// agent needs a `Decision`; anything else means it finished its turn / work and
/// is waiting for an `Ack`. This is a heuristic — consumers (Paloma) can refine
/// it — but it is far better than the old all-`awaiting_user`-is-the-same signal.
///
/// Prefer [`classify_awaiting_kind_text`] with the just-completed turn's output
/// when available: mission history is derived from the event log, which can lag
/// behind the in-hand turn output at finalization time.
pub(super) fn classify_awaiting_kind(history: &[MissionHistoryEntry]) -> AwaitingKind {
    match history.iter().rev().find(|entry| entry.role == "assistant") {
        Some(last) => classify_awaiting_kind_text(&last.content),
        // No assistant text to read (e.g. tool-only turn) — default to Ack so a
        // "done" turn doesn't masquerade as an open question.
        None => AwaitingKind::Ack,
    }
}

/// Heuristic core of [`classify_awaiting_kind`], operating on a raw assistant
/// message string (the authoritative turn output).
pub(super) fn classify_awaiting_kind_text(text: &str) -> AwaitingKind {
    let text = text.trim();
    if text.is_empty() {
        return AwaitingKind::Ack;
    }

    // Only look at the tail of the message — the closing lines carry the intent
    // (a long answer that ends with "Want me to proceed?" is a decision).
    let tail: String = text.chars().rev().take(600).collect::<String>();
    let tail: String = tail.chars().rev().collect();
    let lower = tail.to_lowercase();

    let ends_with_question = tail.trim_end().ends_with('?');
    // Interrogative / approval-seeking lead-ins that signal an open decision even
    // when the literal '?' lands earlier than the very last character.
    const DECISION_CUES: &[&str] = &[
        "should i ",
        "shall i ",
        "do you want",
        "would you like",
        "which option",
        "which one",
        "let me know",
        "how would you like",
        "what would you like",
        "can you confirm",
        "please confirm",
        "your call",
        "proceed?",
        "go ahead?",
    ];
    let has_cue = DECISION_CUES.iter().any(|cue| lower.contains(cue));

    if ends_with_question || has_cue {
        AwaitingKind::Decision
    } else {
        AwaitingKind::Ack
    }
}

pub(super) fn mission_status_summary_for_terminal_reason(reason: TerminalReason) -> Option<String> {
    match reason {
        TerminalReason::TurnComplete | TerminalReason::Completed => None,
        TerminalReason::MaxIterations => Some("Reached iteration limit".to_string()),
        TerminalReason::NativeGoalStopped => {
            Some("Native goal stopped — resume after external steering".to_string())
        }
        TerminalReason::CodexContinuityRequired => {
            Some("Native Codex history requires reconciliation before resume".into())
        }
        TerminalReason::NativeContinuityRequired => {
            Some("Native session requires reconciliation before resume".into())
        }
        TerminalReason::Cancelled => Some("Execution interrupted".to_string()),
        TerminalReason::ServerShutdown => {
            Some("Paused for server restart — click Resume to continue".to_string())
        }
        TerminalReason::Stalled => Some("No progress detected".to_string()),
        TerminalReason::InfiniteLoop => Some("Detected repetitive behavior".to_string()),
        TerminalReason::LlmError => Some("Model error".to_string()),
        TerminalReason::RateLimited => Some("Provider rate limited".to_string()),
        TerminalReason::CapacityLimited => Some("Provider capacity limit reached".to_string()),
        TerminalReason::AuthError => Some("Authentication failed".to_string()),
    }
}

/// How a native goal status changes the persisted `goal_mode` flag.
///
/// `Some(true)`: the loop is running. `Some(false)`: the loop ended for good
/// (completed, cleared, aborted, budget exhausted), so no resume path may
/// rebuild a `/goal` prompt from it. `None`: the loop is suspended (paused,
/// blocked, usage limited) and keeps whatever state it had: an automatic
/// recovery may continue it, unless the user stopped it (see
/// [`disarm_goal_on_user_stop`]).
pub(crate) fn goal_mode_after_status(status: &str) -> Option<bool> {
    match status {
        "active" => Some(true),
        "complete" | "completed" | "cleared" | "budget_limited" => Some(false),
        s if s.starts_with("aborted") => Some(false),
        _ => None,
    }
}

/// A user Stop ends the goal loop: persisted goal mode is disarmed (the
/// objective stays for display) and a server-driven Grok goal automation is
/// disabled, so neither automatic recovery nor the AgentFinished hook starts
/// another goal turn. Only a new `/goal` re-arms it.
pub(crate) async fn disarm_goal_on_user_stop(
    mission_store: &Arc<dyn MissionStore>,
    events_tx: &broadcast::Sender<AgentEvent>,
    mission_id: Uuid,
) -> Result<(), String> {
    let Some(mission) = mission_store.get_mission(mission_id).await? else {
        return Ok(());
    };
    if mission.goal_mode {
        mission_store
            .update_mission_goal(mission_id, false, mission.goal_objective.as_deref())
            .await?;
    }
    if let Some(mut row) =
        super::super::grok_goal::active_goal_for_mission(mission_store, mission_id).await
    {
        let objective = super::super::grok_goal::objective_of(&row);
        super::super::grok_goal::disable_goal(mission_store, &mut row).await?;
        let _ = events_tx.send(AgentEvent::GoalStatus {
            status: "aborted:cancelled".to_string(),
            objective,
            mission_id: Some(mission_id),
        });
    } else if mission.goal_mode {
        if let Some(objective) = mission.goal_objective {
            let _ = events_tx.send(AgentEvent::GoalStatus {
                status: "aborted:cancelled".to_string(),
                objective,
                mission_id: Some(mission_id),
            });
        }
    }
    Ok(())
}

pub(super) fn parse_goal_objective(message: &str) -> Option<String> {
    // Accept any whitespace after the command ("/goal x", "/goal\nx"), but
    // not other slash commands sharing the prefix ("/goals").
    let rest = message.trim_start().strip_prefix("/goal")?;
    if !rest.starts_with(char::is_whitespace) {
        return None;
    }
    let objective = rest.trim();
    (!objective.is_empty()).then(|| objective.to_string())
}

/// Canonical `/goal <objective>` form for a goal message, or `None` when the
/// message is not a goal command. The backend goal drivers (codex
/// `parse_goal_prefix`, grok, opencode) only recognise the space-separated
/// form, while `parse_goal_objective` accepts any whitespace after the
/// command — normalising at the choke points keeps every downstream parser in
/// agreement without teaching each one about `/goal\n`.
pub(super) fn canonical_goal_message(message: &str) -> Option<String> {
    parse_goal_objective(message).map(|objective| format!("/goal {objective}"))
}
