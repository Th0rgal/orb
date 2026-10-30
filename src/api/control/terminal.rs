//! Terminal outcome classification, soft-error recovery, transport auto-resume and terminal finalization.

use super::*;

/// If the turn ended with `LlmError` or `AuthError` but the agent produced
/// substantive output, downgrade the reason to `TurnComplete` so the mission
/// stays active and can be picked up by the next automation cycle or user
/// message.  This prevents transient backend errors (e.g. Codex "Failed to
/// shutdown rollout recorder", or Claude Code exiting with code 1 after a
/// successful turn that happens to contain an auth-error string in its
/// output) from killing missions that actually completed their work.
pub(super) fn maybe_recover_soft_llm_error(result: &mut crate::agents::AgentResult) {
    let is_recoverable = matches!(
        result.terminal_reason,
        Some(
            TerminalReason::LlmError
                | TerminalReason::AuthError
                | TerminalReason::RateLimited
                | TerminalReason::CapacityLimited
        )
    );
    if !is_recoverable {
        return;
    }
    // Structured transport failures are never successful turns. Treating
    // either the Claude marker or the generic/Codex stage as TurnComplete
    // would erase the failure evidence before bounded auto-resume runs.
    let has_transport_failure = result.data.as_ref().is_some_and(|data| {
        data.get("claudecode_transport_failure").is_some()
            || data.get("transport_failure_stage").is_some()
    });
    // A backend that supplied an explicit failure class has already made a
    // structured terminal decision. Its human-readable error text must never
    // be reinterpreted as substantive assistant output by this legacy
    // heuristic.
    let has_structured_failure = result.data.as_ref().is_some_and(|data| {
        data.get("failure_class")
            .is_some_and(|failure_class| !failure_class.is_null())
    });
    if has_transport_failure || has_structured_failure {
        return;
    }
    let output = result.output.trim();
    // Only recover when we have real content — not just an error message.
    // Heuristic: at least 20 chars and doesn't look like a bare error.
    if output.len() >= 20
        && !output.starts_with("Codex produced no output")
        && !output.starts_with("Codex CLI produced no JSON")
        && !output.starts_with("Codex CLI exited before completing the turn")
        && !output.starts_with("No response from")
        && !output.starts_with("Claude Code error:")
        && !output.starts_with("Claude Code produced no")
        && !output.starts_with("Claude Code emitted malformed")
        && !output.starts_with("Claude Code ended before startup")
        && !output.starts_with("Claude Code exited without")
        && !output.starts_with("Claude Code stopped producing output")
        && !output.starts_with("No Claude Code credentials detected")
        && !super::super::mission_runner::is_rate_limited_error(output)
        && !super::super::mission_runner::is_capacity_limited_error(output)
        && !super::super::mission_runner::is_auth_error(output)
        && !is_bare_llm_error_output(output)
    {
        tracing::info!(
            output_len = output.len(),
            reason = ?result.terminal_reason,
            "Recovering from soft error: agent produced valid output, upgrading to TurnComplete"
        );
        result.success = true;
        result.terminal_reason = Some(TerminalReason::TurnComplete);
    }
}

pub(super) fn completion_evidence_for_agent_result(
    result: &crate::agents::AgentResult,
) -> crate::agents::CompletionEvidence {
    use crate::agents::{CompletionConfidence, CompletionEvidence, CompletionSignal, FailureClass};

    let terminal_reason = result.terminal_reason;
    let data = result.data.as_ref();
    let native_terminal_seen = data
        .and_then(|v| v.get("native_terminal_seen"))
        .and_then(|v| v.as_bool())
        .unwrap_or(matches!(
            terminal_reason,
            Some(TerminalReason::TurnComplete | TerminalReason::Completed)
        ));
    let pending_tools = data.and_then(|v| v.get("pending_tools")).and_then(|value| {
        value
            .as_u64()
            .and_then(|count| usize::try_from(count).ok())
            .or_else(|| value.as_array().map(Vec::len))
    });
    let transport_failure_stage = data
        .and_then(|v| v.get("transport_failure_stage"))
        .or_else(|| data.and_then(|v| v.get("claudecode_transport_failure")))
        .and_then(|v| v.as_str())
        .map(ToString::to_string);
    let provider_error_source = data
        .and_then(|v| v.get("provider_error_source"))
        .or_else(|| data.and_then(|v| v.get("error_source")))
        .and_then(|v| v.as_str())
        .map(ToString::to_string);

    let failure_class_from_data = data
        .and_then(|v| v.get("failure_class"))
        .and_then(|v| serde_json::from_value(v.clone()).ok())
        .flatten();
    let failure_class = failure_class_from_data.or(match terminal_reason {
        Some(TerminalReason::AuthError) => Some(FailureClass::AuthError),
        Some(TerminalReason::RateLimited) => Some(FailureClass::RateLimited),
        Some(TerminalReason::CapacityLimited) => Some(FailureClass::CapacityLimited),
        Some(TerminalReason::LlmError) if transport_failure_stage.is_some() => {
            Some(FailureClass::TransportError)
        }
        Some(TerminalReason::LlmError) => Some(FailureClass::ProviderError),
        Some(
            TerminalReason::Stalled | TerminalReason::InfiniteLoop | TerminalReason::MaxIterations,
        ) => Some(FailureClass::AgentError),
        _ => None,
    });

    let completion_signal_from_data = data
        .and_then(|v| v.get("completion_signal"))
        .and_then(|v| serde_json::from_value(v.clone()).ok());
    let completion_signal = completion_signal_from_data.unwrap_or(match terminal_reason {
        Some(TerminalReason::TurnComplete | TerminalReason::Completed) if native_terminal_seen => {
            CompletionSignal::NativeTerminal
        }
        Some(TerminalReason::TurnComplete | TerminalReason::Completed) => {
            CompletionSignal::TextFallback
        }
        Some(_) => CompletionSignal::ProcessExit,
        None => CompletionSignal::Unknown,
    });
    let completion_confidence_from_data = data
        .and_then(|v| v.get("completion_confidence"))
        .and_then(|v| serde_json::from_value(v.clone()).ok());
    let completion_confidence =
        completion_confidence_from_data.unwrap_or(match completion_signal {
            CompletionSignal::NativeTerminal => CompletionConfidence::High,
            CompletionSignal::SessionIdle => CompletionConfidence::Medium,
            CompletionSignal::ProcessExit | CompletionSignal::TextFallback => {
                if result.success {
                    CompletionConfidence::Low
                } else {
                    CompletionConfidence::High
                }
            }
            CompletionSignal::RecoveredSoftError => CompletionConfidence::Low,
            CompletionSignal::Unknown => CompletionConfidence::Low,
        });
    let classification_source = data
        .and_then(|v| v.get("classification_source"))
        .and_then(|v| v.as_str())
        .unwrap_or(match completion_signal {
            CompletionSignal::TextFallback | CompletionSignal::RecoveredSoftError => {
                "text_fallback"
            }
            CompletionSignal::Unknown => "unknown",
            _ => "structured",
        });

    CompletionEvidence {
        terminal_reason,
        completion_signal,
        completion_confidence,
        native_terminal_seen,
        pending_tools,
        transport_failure_stage,
        provider_error_source,
        failure_class,
        classification_source: classification_source.to_string(),
    }
}

pub(super) fn is_transport_failure_evidence(evidence: &crate::agents::CompletionEvidence) -> bool {
    matches!(
        evidence.failure_class,
        Some(crate::agents::FailureClass::TransportError)
    )
}

pub(super) fn is_grok_acp_transport_failure(result: &crate::agents::AgentResult) -> bool {
    result
        .data
        .as_ref()
        .and_then(|data| data.get("grok_acp_transport_failure"))
        .and_then(serde_json::Value::as_bool)
        == Some(true)
}

pub(super) const GROK_TRANSPORT_RECOVERY_RESERVED: &str = "Grok ACP transport recovery reserved (1/1 for this mission). Reconcile the existing checkout and jobs before continuing; automatic recovery will not repeat.";

pub(super) async fn grok_transport_recovery_was_reserved(
    store: &dyn MissionStore,
    mission_id: Uuid,
) -> Result<bool, String> {
    // Page only messages/errors, not a bounded tail that could forget an old
    // attempt. Include legacy recovery messages when upgrading an actor.
    let mut offset = 0;
    loop {
        let events = store
            .get_events(
                mission_id,
                Some(&["user_message", "error"]),
                Some(100),
                Some(offset),
            )
            .await?;
        if events.iter().any(|event| {
            (event.event_type == "error" && event.content == GROK_TRANSPORT_RECOVERY_RESERVED)
                || (event.event_type == "user_message"
                    && event.metadata.get("source").and_then(|v| v.as_str())
                        == Some("transport_auto_resume"))
        }) {
            return Ok(true);
        }
        if events.len() < 100 {
            return Ok(false);
        }
        offset += events.len();
    }
}

/// Shared by the serial and parallel completion paths in the single control
/// actor. Grok gets one recovery per mission, deliberately stricter than a
/// budget reset at each new checkpoint. Persist the reservation before queueing
/// so an actor restart (or a crash between reservation and queueing) cannot
/// replay the same incident. Other backends retain their existing three tries.
pub(super) async fn reserve_transport_auto_resume(
    store: &dyn MissionStore,
    attempts: &mut HashMap<Uuid, u8>,
    mission_id: Uuid,
    grok_acp: bool,
    cancellation_requested: bool,
) -> bool {
    if cancellation_requested {
        return false;
    }
    let count = attempts.entry(mission_id).or_insert(0);
    if *count >= if grok_acp { 1 } else { 3 } {
        return false;
    }
    *count += 1;
    if !grok_acp {
        return true;
    }

    let reserve = async {
        if grok_transport_recovery_was_reserved(store, mission_id).await? {
            return Ok(false);
        }
        // Queued UserMessage events intentionally are not persisted. Record
        // the reservation as an error diagnostic instead of falsely claiming
        // that a recovery message has already started executing.
        store
            .log_event(
                mission_id,
                &AgentEvent::Error {
                    message: GROK_TRANSPORT_RECOVERY_RESERVED.to_string(),
                    mission_id: Some(mission_id),
                    resumable: true,
                },
            )
            .await?;
        if !grok_transport_recovery_was_reserved(store, mission_id).await? {
            return Err("mission store did not persist the Grok recovery reservation".to_string());
        }
        Ok(true)
    }
    .await;
    match reserve {
        Ok(reserved) => reserved,
        Err(error) => {
            tracing::warn!(%mission_id, %error, "Grok transport recovery withheld: durable budget unavailable");
            false
        }
    }
}

pub(super) const TRANSPORT_AUTO_RESUME_PROMPT: &str = "The previous turn ended because its provider transport disconnected. Reconcile the current workspace, remote jobs, and repository head, then resume the same task. Do not duplicate an accepted job or create a replacement writer.";

pub(super) fn is_bare_llm_error_output(output: &str) -> bool {
    if looks_like_structured_provider_error(output) {
        return true;
    }
    if super::super::mission_runner::is_provider_payload_error(output) {
        return true;
    }

    let normalized = output
        .trim()
        .trim_matches(|c: char| matches!(c, '.' | '!' | '"' | '\''))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase();

    if normalized.is_empty() {
        return false;
    }

    matches!(
        normalized.as_str(),
        "internal server error"
            | "invalid authentication credentials"
            | "no claude code credentials detected"
            | "unknown error"
            | "service unavailable"
            | "bad gateway"
            | "gateway timeout"
            | "request timeout"
            | "upstream error"
            | "model error"
    ) || normalized.starts_with("api error:")
        || normalized.starts_with("anthropic api error:")
        || normalized.starts_with("claude code error:")
        // Claude Code's canonical auth-failure surface: the CLI prints
        // `Failed to authenticate. API Error: 401 ...` when Anthropic
        // rejects the request mid-turn. Without this pattern the
        // short auth-error string slipped past
        // `maybe_recover_soft_llm_error` and got fake-promoted to
        // TurnComplete, hiding rotation exhaustion from the UI.
        || normalized.starts_with("failed to authenticate")
        // Any short output whose only substantive content is an auth
        // HTTP status from Anthropic/OpenAI — catches phrasings like
        // `<some prefix>. API Error: 401 ...` without needing to
        // enumerate the prefix.
        || (normalized.len() < 200
            && (normalized.contains("api error: 401")
                || normalized.contains("api error: 403")
                || normalized.contains("api error: 407")))
        // Codex / ChatGPT-OAuth refresh-token reuse surfaces as a short
        // user-visible string. Without these the soft-error recovery
        // fake-promoted the mission to TurnComplete after rotation had
        // already exhausted every configured account, hiding the real
        // failure from the UI.
        || (normalized.len() < 400
            && (normalized.contains("refresh token was already used")
                || normalized.contains("refresh_token_reused")
                || normalized.contains("please log out and sign in again")))
}

pub(super) fn looks_like_structured_provider_error(output: &str) -> bool {
    let trimmed = output.trim();
    if !(trimmed.starts_with('{') && trimmed.ends_with('}')) {
        return false;
    }

    let lower = trimmed.to_ascii_lowercase();
    let has_error_shape = lower.contains("\"detail\"")
        || lower.contains("\"error\"")
        || lower.contains("\"message\"")
        || lower.contains("\"type\"");
    if !has_error_shape {
        return false;
    }

    lower.contains("invalid_request_error")
        || lower.contains("model is not supported")
        || lower.contains("not supported when using codex")
        || lower.contains("does not exist or you do not have access")
        || lower.contains("invalid authentication credentials")
        || lower.contains("rate limit")
        || lower.contains("capacity")
        || lower.contains("service unavailable")
        || lower.contains("internal server error")
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn maybe_finalize_terminal_mission(
    mission_store: &Arc<dyn MissionStore>,
    events_tx: &tokio::sync::broadcast::Sender<AgentEvent>,
    mission_id: Uuid,
    live_background_tasks: usize,
    terminal_reason: Option<TerminalReason>,
    // What the terminating guard observed, from AgentResult::terminal_evidence.
    terminal_evidence: Option<&str>,
    completion_confidence: Option<crate::agents::CompletionConfidence>,
    complete_turn_without_follow_up: bool,
    // The just-completed turn's assistant output, if available. Used to classify
    // `awaiting_kind` authoritatively — the mission's event-log-derived history
    // can lag behind at finalization time.
    final_output: Option<&str>,
    log_context: &str,
) {
    let Some(reason) = terminal_reason else {
        return;
    };
    let transportish = final_output.or(terminal_evidence).is_some_and(|text| {
        let lower = text.to_ascii_lowercase();
        lower.contains("pending tool")
            || lower.contains("not replayed")
            || lower.contains("stream closed before mission")
            || lower.contains("codex app-server stream closed")
    });
    let mapped = if live_background_tasks > 0
        && matches!(
            reason,
            TerminalReason::TurnComplete | TerminalReason::Completed | TerminalReason::LlmError
        ) {
        // Claude Code can emit its terminal result before descendants of a
        // `run_in_background` Bash call release the PTY. The bounded teardown
        // then SIGKILLs the lingering CLI process, which historically changed
        // a healthy parked mission into Failed and invited a controller retry
        // while the build was still running. The shared registry is the
        // authoritative evidence that useful work remains live: park the
        // mission and let bg-autoresume deliver the receipt when it completes.
        Some((MissionStatus::WaitingBackground, "background_jobs_running"))
    } else if transportish && matches!(reason, TerminalReason::LlmError) {
        Some((MissionStatus::Interrupted, "transport"))
    } else {
        mission_status_for_terminal_reason(reason, complete_turn_without_follow_up)
    };
    let Some((new_status, terminal_reason_str)) = mapped else {
        tracing::debug!(
            mission_id = %mission_id,
            reason = ?reason,
            context = log_context,
            "Skipping mission finalization for non-terminal turn state"
        );
        return;
    };

    match mission_store.get_mission(mission_id).await {
        Ok(Some(mission)) => {
            if mission.status == MissionStatus::Interrupted {
                // A turn that *succeeds* after the interruption marker was set
                // (deploy restart mid-turn, then the drained turn completes)
                // supersedes it: there is a fresh assistant answer, and leaving
                // the mission "interrupted" makes the dashboard offer a resume
                // that the still-registered runner rejects with "already
                // running". Failure-shaped reasons keep the interrupted status
                // (it is the more accurate cause).
                let successful_turn = matches!(
                    new_status,
                    MissionStatus::AwaitingUser | MissionStatus::Completed
                );
                if !successful_turn {
                    tracing::debug!(
                        mission_id = %mission_id,
                        reason = ?reason,
                        context = log_context,
                        "Skipping mission finalization because mission is already interrupted"
                    );
                    return;
                }
                tracing::info!(
                    mission_id = %mission_id,
                    reason = ?reason,
                    new_status = ?new_status,
                    context = log_context,
                    "Promoting interrupted mission: turn completed successfully after interruption"
                );
            }

            // Interrupted is allowed through: the promotion check above already
            // filtered it down to successful turns only.
            if !matches!(
                mission.status,
                MissionStatus::Active | MissionStatus::Pending | MissionStatus::Interrupted
            ) {
                tracing::debug!(
                    mission_id = %mission_id,
                    status = ?mission.status,
                    context = log_context,
                    "Skipping mission finalization because mission already has terminal status"
                );
                return;
            }

            if new_status == MissionStatus::Completed
                && completion_confidence == Some(crate::agents::CompletionConfidence::Low)
            {
                tracing::info!(
                    mission_id = %mission_id,
                    reason = ?reason,
                    context = log_context,
                    "Skipping mission completion because completion evidence is low confidence"
                );
                return;
            }

            if new_status == MissionStatus::Completed
                && mission_has_active_automation(mission_store, mission_id).await
            {
                tracing::info!(
                    mission_id = %mission_id,
                    context = log_context,
                    "Skipping mission completion because active automations are enabled"
                );
                return;
            }

            // Assistant missions (e.g. Telegram-linked) should stay active
            // after each reply — they are long-lived by design.
            if new_status == MissionStatus::Completed
                && mission.mission_mode == super::super::mission_store::MissionMode::Assistant
            {
                tracing::debug!(
                    mission_id = %mission_id,
                    context = log_context,
                    "Skipping mission completion for assistant-mode mission"
                );
                return;
            }

            tracing::info!(
                mission_id = %mission_id,
                status = ?new_status,
                reason = ?reason,
                context = log_context,
                "Finalizing mission after terminal turn"
            );
            // Classify the awaiting reason now (uses the in-hand turn output;
            // falls back to history only when the caller didn't supply it, since
            // the event log can lag the turn). Applied *after* a successful
            // status write below so a failed write can't orphan awaiting_kind on
            // a mission that never became AwaitingUser.
            let awaiting_kind = if new_status == MissionStatus::AwaitingUser {
                Some(match final_output {
                    Some(text) if !text.trim().is_empty() => classify_awaiting_kind_text(text),
                    _ => classify_awaiting_kind(&mission.history),
                })
            } else {
                None
            };

            if let Some(evidence) = terminal_evidence.filter(|e| !e.trim().is_empty()) {
                // Best-effort by contract: failing to record evidence must
                // never turn into failing to terminate.
                if let Err(e) = mission_store
                    .set_terminal_evidence(mission_id, evidence)
                    .await
                {
                    tracing::warn!(mission_id = %mission_id, "failed to record terminal evidence: {e}");
                }
            }
            let execution = mission_store
                .get_latest_mission_run(mission_id)
                .await
                .ok()
                .flatten();
            if let Err(e) = mission_store
                .update_mission_status_with_reason(
                    mission_id,
                    new_status,
                    Some(terminal_reason_str),
                )
                .await
            {
                tracing::warn!(
                    mission_id = %mission_id,
                    context = log_context,
                    "Failed to finalize mission after terminal turn: {}",
                    e
                );
            } else {
                // Set awaiting_kind after the status is committed to AwaitingUser
                // and before emitting the event the Paloma webhook keys on, so
                // the webhook sees it without risking an orphan on write failure.
                if let Some(kind) = awaiting_kind {
                    if let Err(e) = mission_store
                        .set_mission_awaiting_kind(mission_id, Some(kind))
                        .await
                    {
                        tracing::warn!(
                            mission_id = %mission_id,
                            context = log_context,
                            "Failed to set awaiting_kind: {}",
                            e
                        );
                    }
                }

                maybe_schedule_mission_metadata_refresh_for_status(
                    mission_store,
                    events_tx,
                    mission_id,
                    new_status,
                );
                let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                    completion: Some(MissionCompletionSnapshot {
                        result_summary: final_output.map(str::to_owned),
                        terminal_reason: Some(terminal_reason_str.to_owned()),
                        terminal_evidence: terminal_evidence.map(str::to_owned),
                    }),
                    execution,
                    mission_id,
                    status: new_status,
                    summary: mission_status_summary_for_terminal_reason(reason),
                });

                // Broadcast delivery is best-effort. Mirror the explicit
                // SetMissionStatus path and schedule teardown directly so a
                // finalizer cannot leak detached WorkspaceExec scopes when
                // the scope-reaper listener is lagged or attached to another
                // per-user control channel. The delayed status recheck still
                // preserves missions promoted to WaitingBackground.
                super::super::scope_reaper::schedule_mission_scope_teardown(
                    Arc::clone(mission_store),
                    mission_id,
                    new_status,
                );

                // Stall-guard: orchestrators that park in awaiting_user with no
                // wakeup armed can't resume themselves — arm a bounded fallback.
                if new_status == MissionStatus::AwaitingUser {
                    maybe_arm_stall_guard_wakeup(mission_store, mission_id).await;
                }
            }
        }
        Ok(None) => {
            tracing::warn!(
                mission_id = %mission_id,
                context = log_context,
                "Mission not found for terminal finalization"
            );
        }
        Err(e) => {
            tracing::warn!(
                mission_id = %mission_id,
                context = log_context,
                "Failed to load mission for terminal finalization: {}",
                e
            );
        }
    }
}

pub(super) fn next_session_id_from_automation_variables(
    automation: &super::super::mission_store::Automation,
) -> Option<Uuid> {
    let raw = automation.variables.get("nextSessionId")?.trim();
    if raw.is_empty() {
        return None;
    }
    Uuid::parse_str(raw).ok()
}

pub(super) fn resolve_agent_finished_target_mission(
    source_mission_id: Uuid,
    source_mission_status: MissionStatus,
    automation: &super::super::mission_store::Automation,
) -> Uuid {
    if source_mission_status == MissionStatus::Completed
        && automation.fresh_session == mission_store::FreshSession::Switch
    {
        if let Some(next_id) = next_session_id_from_automation_variables(automation) {
            return next_id;
        }

        tracing::warn!(
            "Automation {} is in switch mode but has no valid nextSessionId variable; falling back to mission {}",
            automation.id,
            source_mission_id
        );
    }

    source_mission_id
}

pub(super) async fn agent_finished_automation_messages(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    _library: &SharedLibrary,
    workspaces: &workspace::SharedWorkspaceStore,
) -> Vec<RoutedAutomationMessage> {
    use super::super::automation_variables::{substitute_variables, SubstitutionContext};
    use super::super::mission_store::{
        AutomationExecution, CommandSource, ExecutionStatus, TriggerType,
    };

    let automations = match mission_store.get_mission_automations(mission_id).await {
        Ok(list) => list,
        Err(e) => {
            tracing::warn!(
                "Failed to load automations for mission {} (agent_finished hook): {}",
                mission_id,
                e
            );
            return Vec::new();
        }
    };

    let mut active: Vec<super::super::mission_store::Automation> = automations
        .into_iter()
        .filter(|a| a.active && matches!(a.trigger, TriggerType::AgentFinished))
        .collect();

    if active.is_empty() {
        return Vec::new();
    }

    let mission = match mission_store.get_mission(mission_id).await {
        Ok(Some(m)) => m,
        Ok(None) => return Vec::new(),
        Err(e) => {
            tracing::warn!(
                "Failed to load mission {} for agent_finished automations: {}",
                mission_id,
                e
            );
            return Vec::new();
        }
    };

    let mut eligible = Vec::with_capacity(active.len());
    for automation in active {
        let consecutive_failures =
            consecutive_failure_count_for_automation(mission_store, &automation).await;
        let has_fired = if matches!(
            automation.stop_policy,
            mission_store::StopPolicy::AfterFirstFire
        ) {
            automation_has_fired(mission_store, automation.id).await
        } else {
            false
        };

        if mission_is_terminal_for_goal_loop(mission.status)
            || stop_policy_matches_status(
                &automation.stop_policy,
                mission.status,
                consecutive_failures,
                has_fired,
            )
            .await
        {
            tracing::info!(
                "Disabling agent_finished automation {} due to stop policy {:?} (mission {} status {:?})",
                automation.id,
                automation.stop_policy,
                mission.id,
                mission.status
            );
            let mut updated = automation.clone();
            updated.active = false;
            if let Err(e) = mission_store.update_automation(updated).await {
                tracing::warn!(
                    "Failed to disable automation {} after stop policy match: {}",
                    automation.id,
                    e
                );
            }
            continue;
        }
        eligible.push(automation);
    }
    active = eligible;

    if active.is_empty() {
        return Vec::new();
    }

    // Stable ordering to avoid surprising changes in multi-automation setups.
    active.sort_by_key(|a| a.created_at.clone());

    let workspace = workspaces.get(mission.workspace_id).await;

    let mut out = Vec::with_capacity(active.len());

    for automation in active {
        // Fetch the command content based on the command source
        let command_content = match &automation.command_source {
            CommandSource::Library { name } => {
                tracing::warn!(
                    "Skipping retired library command '{}' for automation {}",
                    name,
                    automation.id
                );
                continue;
            }
            CommandSource::LocalFile { path } => {
                let file_path = if let Some(ws) = workspace.as_ref() {
                    ws.path.join(path)
                } else {
                    tracing::warn!(
                        "Workspace {} not found for automation {}",
                        mission.workspace_id,
                        automation.id
                    );
                    continue;
                };
                match tokio::fs::read_to_string(&file_path).await {
                    Ok(content) => content,
                    Err(e) => {
                        tracing::warn!(
                            "Failed to read file '{}' for automation {}: {}",
                            file_path.display(),
                            automation.id,
                            e
                        );
                        continue;
                    }
                }
            }
            CommandSource::Inline { content } => content.clone(),
            CommandSource::NativeLoop { .. } => {
                // Harness-driven loops iterate via the harness CLI itself.
                // Skip — the native_loop_observer records executions when
                // the harness emits goal events.
                continue;
            }
        };

        // Build substitution context for variable replacement
        let mut context = SubstitutionContext::new(mission.id);
        if let Some(ref title) = mission.title {
            context = context.with_mission_name(title.clone());
        }
        if let Some(ws) = workspace.as_ref() {
            context = context.with_working_directory(ws.path.to_string_lossy().to_string());
        }
        context = context.with_custom_variables(automation.variables.clone());

        let substituted_content = substitute_variables(&command_content, &context);

        let target_mission_id =
            resolve_agent_finished_target_mission(mission.id, mission.status, &automation);

        // Create an execution record in Running status – it will be
        // completed by complete_turn_executions_for_mission when the
        // target agent finishes processing.
        let execution_id = Uuid::new_v4();
        let execution = AutomationExecution {
            id: execution_id,
            automation_id: automation.id,
            mission_id: target_mission_id,
            triggered_at: mission_store::now_string(),
            trigger_source: "agent_finished".to_string(),
            status: ExecutionStatus::Running,
            webhook_payload: None,
            variables_used: automation.variables.clone(),
            completed_at: None,
            error: None,
            retry_count: 0,
        };

        if mission_store
            .create_automation_execution(execution)
            .await
            .is_ok()
        {
            // Best-effort: update last_triggered_at for visibility in UI.
            if let Err(e) = mission_store
                .update_automation_last_triggered(automation.id)
                .await
            {
                tracing::warn!("Failed to update automation last triggered time: {}", e);
            }
        } else {
            // If we can't record execution, still trigger the message.
            tracing::warn!(
                "Failed to create execution record for agent_finished automation {}",
                automation.id
            );
        }

        tracing::info!(
            "Triggering agent_finished automation {} (execution {}) from mission {} to mission {}",
            automation.id,
            execution_id,
            mission.id,
            target_mission_id
        );

        out.push(RoutedAutomationMessage {
            content: substituted_content,
            target_mission_id,
        });
    }

    out
}
