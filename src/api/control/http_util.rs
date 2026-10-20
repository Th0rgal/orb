//! Small shared helpers for HTTP handlers (error mapping, required ids, default models).

use super::*;

/// Error returned when the control session command channel is closed.
pub(super) fn session_unavailable<T>(_: T) -> (StatusCode, String) {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        "control session unavailable".to_string(),
    )
}

/// Error returned when a oneshot response channel is dropped.
pub(super) fn recv_failed<T>(_: T) -> (StatusCode, String) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        "Failed to receive response".to_string(),
    )
}

/// Shorthand for a `{ "ok": true }` JSON response.
pub(super) fn ok_json() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "ok": true }))
}

/// Unwrap a mission ID or emit an error event and return a failure result.
#[allow(clippy::result_large_err)]
pub(super) fn require_mission_id(
    mission_id: Option<Uuid>,
    backend: &str,
    events_tx: &broadcast::Sender<AgentEvent>,
) -> Result<Uuid, crate::agents::AgentResult> {
    mission_id.ok_or_else(|| {
        let msg = format!("{} backend requires a mission ID", backend);
        let _ = events_tx.send(AgentEvent::Error {
            message: msg.clone(),
            mission_id: None,
            resumable: false,
        });
        crate::agents::AgentResult::failure(msg, 0).with_terminal_reason(TerminalReason::LlmError)
    })
}

/// Query the control actor for the list of currently running missions.
pub(super) async fn get_running_missions(
    control: &ControlState,
) -> Result<Vec<super::super::mission_runner::RunningMissionInfo>, (StatusCode, String)> {
    let (tx, rx) = oneshot::channel();
    control
        .cmd_tx
        .send(ControlCommand::ListRunning { respond: tx })
        .await
        .map_err(session_unavailable)?;
    let actor_rows = rx.await.map_err(recv_failed)?;
    let durable_runs = control
        .mission_store
        .list_active_mission_runs()
        .await
        .map_err(internal_error)?;
    let mut actor_by_mission: HashMap<Uuid, super::super::mission_runner::RunningMissionInfo> =
        actor_rows
            .into_iter()
            .map(|row| (row.mission_id, row))
            .collect();
    let mut projected = Vec::with_capacity(durable_runs.len() + actor_by_mission.len());
    for run in durable_runs {
        let mission = control
            .mission_store
            .get_mission(run.mission_id)
            .await
            .map_err(internal_error)?;
        let heartbeat_age = chrono::DateTime::parse_from_rfc3339(&run.heartbeat_at)
            .ok()
            .map(|timestamp| {
                (chrono::Utc::now() - timestamp.with_timezone(&chrono::Utc))
                    .num_seconds()
                    .max(0) as u64
            })
            .unwrap_or(u64::MAX);
        let presentation_conflict = mission.as_ref().and_then(|mission| {
            (mission.status == MissionStatus::Acknowledged || mission.status.is_terminal())
                .then(|| format!("status_{}_with_non_terminal_run", mission.status))
        });
        let healthy_detached_remote_wait =
            detached_remote_wait_is_healthy(run.execution_state, heartbeat_age);
        let mut row = actor_by_mission.remove(&run.mission_id).unwrap_or_else(|| {
            super::super::mission_runner::RunningMissionInfo {
                mission_id: run.mission_id,
                // A detached durable row does not prove which backend process
                // owns the in-flight turn. Do not infer it from mutable
                // next-turn mission settings.
                backend_id: None,
                state: run.execution_state.as_str().to_string(),
                queue_len: 0,
                history_len: 0,
                seconds_since_activity: heartbeat_age,
                tool_call_in_flight: matches!(
                    run.execution_state,
                    MissionExecutionState::WaitingTool | MissionExecutionState::WaitingRemoteJob
                ),
                health: if healthy_detached_remote_wait {
                    super::super::mission_runner::MissionHealth::Healthy
                } else {
                    super::super::mission_runner::MissionHealth::Reconciling {
                        reason: "durable_run_without_registered_actor".to_string(),
                    }
                },
                expected_deliverables: 0,
                current_activity: None,
                subtask_total: 0,
                subtask_completed: 0,
                run_id: Some(run.run_id),
                generation: Some(run.generation),
                heartbeat_at: Some(run.heartbeat_at.clone()),
                scope_unit: run.scope_unit.clone(),
                status_conflict: (!healthy_detached_remote_wait)
                    .then(|| "durable_run_without_registered_actor".to_string()),
            }
        });
        row.state = run.execution_state.as_str().to_string();
        row.run_id = Some(run.run_id);
        row.generation = Some(run.generation);
        row.heartbeat_at = Some(run.heartbeat_at.clone());
        row.scope_unit = run.scope_unit.clone();
        if let Some(conflict) = presentation_conflict {
            row.status_conflict = Some(conflict.clone());
            row.health =
                super::super::mission_runner::MissionHealth::Reconciling { reason: conflict };
        } else if heartbeat_age > 60 && run.execution_state != MissionExecutionState::WaitingUser {
            let reason = format!("run_heartbeat_stale_{heartbeat_age}s");
            row.status_conflict = Some(reason.clone());
            row.health = super::super::mission_runner::MissionHealth::Reconciling { reason };
        }
        projected.push(row);
    }
    for (_, mut row) in actor_by_mission {
        row.status_conflict = Some("registered_actor_without_durable_run".to_string());
        row.health = super::super::mission_runner::MissionHealth::Reconciling {
            reason: "registered_actor_without_durable_run".to_string(),
        };
        projected.push(row);
    }
    Ok(projected)
}

pub(super) fn detached_remote_wait_is_healthy(
    state: MissionExecutionState,
    heartbeat_age: u64,
) -> bool {
    state == MissionExecutionState::WaitingRemoteJob && heartbeat_age <= 60
}

/// Look up an automation by ID, returning 404 if it does not exist.
pub(super) async fn require_automation(
    store: &Arc<dyn MissionStore>,
    id: Uuid,
) -> Result<mission_store::Automation, (StatusCode, String)> {
    store
        .get_automation(id)
        .await
        .map_err(internal_error)?
        .ok_or((
            StatusCode::NOT_FOUND,
            format!("Automation {} not found", id),
        ))
}

/// Validate that a command exists in the library.
pub(super) async fn validate_library_command(
    state: &AppState,
    name: &str,
) -> Result<(), (StatusCode, String)> {
    if let Some(lib) = state.library.read().await.as_ref() {
        match lib.get_command(name).await {
            Ok(_) => Ok(()),
            Err(e) => {
                let msg = e.to_string();
                if msg.contains("not found") || msg.contains("does not exist") {
                    Err((
                        StatusCode::BAD_REQUEST,
                        format!("Command '{}' not found in library", name),
                    ))
                } else {
                    Err((
                        StatusCode::INTERNAL_SERVER_ERROR,
                        format!("Failed to validate command: {}", e),
                    ))
                }
            }
        }
    } else {
        Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "Library not initialized".to_string(),
        ))
    }
}

pub(crate) async fn resolve_claudecode_default_model(
    library: &SharedLibrary,
    config_profile: Option<&str>,
) -> Option<String> {
    // Keep this fallback aligned with Anthropic's model catalog:
    // https://platform.claude.com/docs/en/about-claude/models/overview
    let lib = {
        let guard = library.read().await;
        guard.clone()
    };

    let Some(lib) = lib else {
        return Some(crate::library::CLAUDE_CODE_DEFAULT_MODEL.to_string());
    };

    let profile = config_profile.unwrap_or("default");
    match lib.get_claudecode_config_for_profile(profile).await {
        Ok(config) => Some(crate::library::normalize_claude_code_default_model(
            config.default_model,
        )),
        Err(err) => {
            tracing::warn!(
                "Failed to load Claude Code config from library (profile: {}): {}",
                profile,
                err
            );
            Some(crate::library::CLAUDE_CODE_DEFAULT_MODEL.to_string())
        }
    }
}

/// Return the default model for Codex CLI when no override is specified.
pub(crate) fn resolve_codex_default_model() -> String {
    // Keep aligned with the live ChatGPT Codex catalog (`codex debug models`):
    // gpt-6.1-sol is first in the catalog of both prod accounts since
    // 2026-09-29 (efforts low..ultra). Owner decision: it is the Codex default.
    if let Ok(model) = std::env::var("CODEX_DEFAULT_MODEL") {
        let trimmed = model.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    "gpt-6.1-sol".to_string()
}

/// Return the default model for Grok Build when no override is specified.
///
/// Mirrors the dashboard's `KNOWN_BACKEND_DEFAULT_MODELS` entry for grok and
/// the value advertised by `/api/providers` for xAI. Pinning here prevents
/// grok missions from inheriting the global `DEFAULT_MODEL`
/// (e.g. `anthropic/claude-opus-4-6`) which grok rejects as "unknown model id".
pub(crate) fn resolve_grok_default_model() -> String {
    // Allow ops to override without a rebuild (e.g. when xAI renames the coding
    // model again).
    if let Ok(model) = std::env::var("GROK_DEFAULT_MODEL") {
        let trimmed = model.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    // The Grok Build CLI's coding model id. NOTE: the bare `grok-build` alias is
    // rejected by current CLIs ("unknown model id"); `grok models` lists
    // `grok-build-0.1`. Passing an invalid id makes the very first turn fail, so
    // keep this in sync with the CLI. xAI *API* model IDs (for the API-key
    // provider catalog) live separately: https://docs.x.ai/docs/models
    "grok-build-0.1".to_string()
}

pub(super) async fn close_mission_desktop_sessions(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    working_dir: &std::path::Path,
) {
    let Ok(Some(mission)) = mission_store.get_mission(mission_id).await else {
        return;
    };

    if mission.desktop_sessions.is_empty() {
        return;
    }

    let mut sessions = mission.desktop_sessions.clone();
    let now = now_string();
    let mut updated = false;

    for session in sessions
        .iter_mut()
        .filter(|session| session.stopped_at.is_none())
    {
        if let Err(err) = desktop::close_desktop_session(&session.display, working_dir).await {
            tracing::warn!(
                mission_id = %mission_id,
                display = %session.display,
                error = %err,
                "Failed to close desktop session"
            );
        }
        session.stopped_at = Some(now.clone());
        updated = true;
    }

    if updated {
        if let Err(err) = mission_store
            .update_mission_desktop_sessions(mission_id, &sessions)
            .await
        {
            tracing::warn!(
                mission_id = %mission_id,
                error = %err,
                "Failed to persist desktop session shutdown"
            );
        }
    }
}
