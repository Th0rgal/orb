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
pub(crate) async fn get_running_missions(
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
    let mut seen_missions = HashSet::new();
    for run in durable_runs {
        seen_missions.insert(run.mission_id);
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
        let remote_node_id = run
            .scope_unit
            .as_deref()
            .and_then(|s| s.strip_prefix("remote-node:"))
            .map(str::to_string);
        let remote_job_id = run
            .owner_actor_id
            .strip_prefix("remote-job:")
            .and_then(|s| Uuid::parse_str(s).ok());
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
                remote_node_id: remote_node_id.clone(),
                remote_job_id,
                status_conflict: (!healthy_detached_remote_wait)
                    .then(|| "durable_run_without_registered_actor".to_string()),
            }
        });
        row.state = run.execution_state.as_str().to_string();
        row.run_id = Some(run.run_id);
        row.generation = Some(run.generation);
        row.heartbeat_at = Some(run.heartbeat_at.clone());
        row.scope_unit = run.scope_unit.clone();
        if row.remote_node_id.is_none() {
            row.remote_node_id = remote_node_id;
        }
        if row.remote_job_id.is_none() {
            row.remote_job_id = remote_job_id;
        }
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
        seen_missions.insert(row.mission_id);
        row.status_conflict = Some("registered_actor_without_durable_run".to_string());
        row.health = super::super::mission_runner::MissionHealth::Reconciling {
            reason: "registered_actor_without_durable_run".to_string(),
        };
        projected.push(row);
    }
    // Also surface active remote mission jobs from `job_ledger` so managed-VM
    // missions (`managed-mm*`) never appear with `live = null` if their durable
    // run lease lagged or is mid-reconciliation.
    if let Ok(handles) = crate::remote_node::job_ledger::load(&control.working_dir).await {
        let now = chrono::Utc::now();
        for handle in handles {
            if handle.kind != crate::remote_node::job_ledger::JobHandleKind::Mission {
                continue;
            }
            if seen_missions.contains(&handle.mission_id) {
                if let Some(existing) = projected
                    .iter_mut()
                    .find(|r| r.mission_id == handle.mission_id)
                {
                    if existing.remote_node_id.is_none() {
                        existing.remote_node_id = Some(handle.node_id.clone());
                    }
                    if existing.remote_job_id.is_none() {
                        existing.remote_job_id = Some(handle.job_id);
                    }
                }
                continue;
            }
            let Ok(Some(mission)) = control.mission_store.get_mission(handle.mission_id).await
            else {
                continue;
            };
            if mission.status.is_terminal() || mission.status == MissionStatus::Acknowledged {
                continue;
            }
            seen_missions.insert(handle.mission_id);
            let anchor = handle
                .heartbeat_at
                .or(handle.accepted_at)
                .unwrap_or(handle.started_at);
            let age = (now - anchor).num_seconds().max(0) as u64;
            let healthy = age <= 90;
            projected.push(super::super::mission_runner::RunningMissionInfo {
                mission_id: handle.mission_id,
                backend_id: Some(mission.backend.clone()),
                state: "waiting_remote_job".to_string(),
                queue_len: 0,
                history_len: mission.history.len(),
                seconds_since_activity: age,
                tool_call_in_flight: true,
                health: if healthy {
                    super::super::mission_runner::MissionHealth::Healthy
                } else {
                    super::super::mission_runner::MissionHealth::Reconciling {
                        reason: format!("remote_job_heartbeat_stale_{age}s"),
                    }
                },
                expected_deliverables: 0,
                current_activity: Some(format!("Remote job on {}", handle.node_id)),
                subtask_total: 0,
                subtask_completed: 0,
                run_id: None,
                generation: None,
                heartbeat_at: Some(anchor.to_rfc3339()),
                scope_unit: Some(format!("remote-node:{}", handle.node_id)),
                remote_node_id: Some(handle.node_id),
                remote_job_id: Some(handle.job_id),
                status_conflict: (!healthy).then(|| format!("remote_job_heartbeat_stale_{age}s")),
            });
        }
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

/// Library commands have been retired in favor of inline and local_file commands.
pub(super) async fn validate_library_command(
    _state: &AppState,
    name: &str,
) -> Result<(), (StatusCode, String)> {
    Err((
        StatusCode::BAD_REQUEST,
        format!(
            "Library command '{}' cannot be used: Library commands have been retired; use inline or local_file commands instead",
            name
        ),
    ))
}

pub(crate) async fn resolve_claudecode_default_model(
    _library: &SharedLibrary,
    _config_profile: Option<&str>,
) -> Option<String> {
    Some(crate::model_policy::CLAUDE_CODE_DEFAULT_MODEL.to_string())
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
