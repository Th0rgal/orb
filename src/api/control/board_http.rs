//! HTTP handlers for the mission board.

use super::*;

// ---------------------------------------------------------------------------
// Task board API (see `board` module for the scheduler).
// ---------------------------------------------------------------------------

#[derive(Debug, serde::Deserialize)]
pub struct BoardUpsertRequest {
    pub tasks: Vec<NewBoardTask>,
}

#[derive(Debug, serde::Serialize)]
pub struct BoardUtilization {
    pub pending: usize,
    pub running: usize,
    pub settled: usize,
    pub accepted: usize,
    pub failed: usize,
    pub cancelled: usize,
    pub total: usize,
    pub max_parallel: usize,
}

#[derive(Debug, serde::Serialize)]
pub struct UnresolvableDep {
    pub task_key: String,
    pub missing_dep: String,
}

#[derive(Debug, serde::Serialize)]
pub struct BoardResponse {
    pub tasks: Vec<BoardTask>,
    pub utilization: BoardUtilization,
    /// Pending tasks parked forever on a `depends_on` key that doesn't exist
    /// on this board (typo'd or never-registered dependency). The scheduler
    /// wakes the boss when this is non-empty; fix by re-registering the task
    /// with corrected depends_on via plan_tasks.
    pub unresolvable_deps: Vec<UnresolvableDep>,
}

pub(super) fn board_unresolvable_deps(tasks: &[BoardTask]) -> Vec<UnresolvableDep> {
    board::unresolvable_dependencies(tasks)
        .into_iter()
        .map(|(task_key, missing_dep)| UnresolvableDep {
            task_key,
            missing_dep,
        })
        .collect()
}

pub(super) fn validate_and_normalize_board_tasks(
    tasks: &mut [NewBoardTask],
) -> Result<(), (StatusCode, String)> {
    for t in tasks {
        if t.task_key.trim().is_empty() || t.prompt.trim().is_empty() {
            return Err((
                StatusCode::BAD_REQUEST,
                "every task needs a non-empty task_key and prompt".to_string(),
            ));
        }
        if t.backend.trim().eq_ignore_ascii_case("gemini") {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("task `{}`: {}", t.task_key, board::RETIRED_GEMINI_TASK),
            ));
        }
        // Same operator policy as the orchestrator MCP: worker missions never
        // burn Claude tokens. Enforced here too so the API can't be used to
        // bypass the MCP-level check.
        let claude_allowed = std::env::var("SANDBOXED_SH_ALLOW_CLAUDE_WORKERS")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        let is_claude = t.backend.eq_ignore_ascii_case("claudecode")
            || t.model_override
                .as_deref()
                .map(|m| m.to_ascii_lowercase().contains("claude"))
                .unwrap_or(false);
        if t.backend.trim().is_empty() || (is_claude && !claude_allowed) {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "task `{}`: workers need an explicit non-Claude backend (got `{}`)",
                    t.task_key, t.backend
                ),
            ));
        }
        if let Some(model) = t.model_override.as_deref() {
            if let Some(prefixed_backend) = native_backend_prefix(model) {
                if t.backend != "opencode" && t.backend != prefixed_backend {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        format!(
                            "task `{}`: model '{}' selects backend '{}', but task backend is '{}'",
                            t.task_key, model, prefixed_backend, t.backend
                        ),
                    ));
                }
            }
        }
        t.model_override = t
            .model_override
            .as_deref()
            .and_then(|model| normalize_model_override_for_backend(Some(&t.backend), model));
        if t.backend.eq_ignore_ascii_case("codex") {
            if let Some(model) = t.model_override.as_deref() {
                if let Err(err) = crate::api::providers::reject_known_unsupported_codex_model(model)
                {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        format!("task `{}`: {}", t.task_key, err),
                    ));
                }
            }
        }
        // Blank acceptance criteria must not count as an outcome contract:
        // `[" "]` would otherwise suppress spec_warnings, emit a blank bullet
        // in the worker contract, and declare the prompt advisory on retry.
        t.acceptance_criteria = t
            .acceptance_criteria
            .iter()
            .map(|criterion| criterion.trim().to_string())
            .filter(|criterion| !criterion.is_empty())
            .collect();
        t.verification_command = t
            .verification_command
            .as_deref()
            .map(str::trim)
            .filter(|command| !command.is_empty())
            .map(String::from);
        // `risk_class` now gates scheduler behavior (high = no silent retry),
        // so an unrecognized value must fail loudly instead of silently acting
        // like "normal".
        t.risk_class = t.risk_class.trim().to_ascii_lowercase();
        if !matches!(t.risk_class.as_str(), "low" | "normal" | "high") {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "task `{}`: unknown risk_class `{}` (use low|normal|high)",
                    t.task_key, t.risk_class
                ),
            ));
        }
    }
    Ok(())
}

pub(super) fn board_utilization(tasks: &[BoardTask], max_parallel: usize) -> BoardUtilization {
    let count = |s: BoardTaskStatus| tasks.iter().filter(|t| t.status == s).count();
    BoardUtilization {
        pending: count(BoardTaskStatus::Pending),
        running: count(BoardTaskStatus::Running),
        settled: count(BoardTaskStatus::Settled),
        accepted: count(BoardTaskStatus::Accepted),
        failed: count(BoardTaskStatus::Failed),
        cancelled: count(BoardTaskStatus::Cancelled),
        total: tasks.len(),
        max_parallel,
    }
}

/// GET /api/control/missions/:id/board — full board for a boss mission.
pub async fn get_mission_board(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> Result<Json<BoardResponse>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let tasks = control
        .mission_store
        .list_board_tasks(id)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let max_parallel = crate::settings::max_parallel_missions_cached_or(control.max_parallel);
    Ok(Json(BoardResponse {
        utilization: board_utilization(&tasks, max_parallel),
        unresolvable_deps: board_unresolvable_deps(&tasks),
        tasks,
    }))
}

/// POST /api/control/missions/:id/board/tasks — register/update tasks.
/// The scheduler picks up ready tasks within one pass (~3s).
pub async fn upsert_mission_board_tasks(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(mut req): Json<BoardUpsertRequest>,
) -> Result<Json<BoardResponse>, (StatusCode, String)> {
    if req.tasks.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "tasks is required".to_string()));
    }
    validate_and_normalize_board_tasks(&mut req.tasks)?;

    let control = control_for_user(&state, &user).await;
    // The boss mission must exist — tasks attached to a typo'd uuid would
    // never be scheduled against the right workspace.
    let boss = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?
        .ok_or((StatusCode::NOT_FOUND, format!("mission {} not found", id)))?;

    control
        .mission_store
        .upsert_board_tasks(boss.id, req.tasks)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    let tasks = control
        .mission_store
        .list_board_tasks(id)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    let max_parallel = crate::settings::max_parallel_missions_cached_or(control.max_parallel);
    Ok(Json(BoardResponse {
        utilization: board_utilization(&tasks, max_parallel),
        unresolvable_deps: board_unresolvable_deps(&tasks),
        tasks,
    }))
}

#[derive(Debug, serde::Deserialize)]
pub struct BoardVerdictRequest {
    /// "accept" or "reject".
    pub action: String,
    /// Required for reject: feedback delivered to the worker.
    #[serde(default)]
    pub feedback: Option<String>,
    /// The calling boss mission, when the caller IS a mission (orchestrator
    /// MCP always sends its own id). Must match the task's board — a mission
    /// may not judge another board's tasks. Absent = owner/dashboard call,
    /// which passes on auth alone.
    #[serde(default)]
    pub boss_mission_id: Option<Uuid>,
}

/// A mission may only act on its own board; the owner (no mission id) may act
/// on any.
pub(super) fn assert_board_ownership(
    task: &BoardTask,
    caller: Option<Uuid>,
) -> Result<(), (StatusCode, String)> {
    match caller {
        Some(caller) if caller != task.boss_mission_id => Err((
            StatusCode::FORBIDDEN,
            format!(
                "task `{}` belongs to boss {}, not {} — a mission may only judge its own board",
                task.task_key, task.boss_mission_id, caller
            ),
        )),
        _ => Ok(()),
    }
}

/// POST /api/control/board/tasks/:task_id/verdict — boss judgment on a
/// settled task. Accept is terminal; reject resumes the worker with feedback
/// (or re-queues the task if the worker mission is gone).
pub async fn board_task_verdict(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(task_id): Path<Uuid>,
    Json(req): Json<BoardVerdictRequest>,
) -> Result<Json<BoardTask>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let mut task = control
        .mission_store
        .get_board_task(task_id)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?
        .ok_or((StatusCode::NOT_FOUND, format!("task {} not found", task_id)))?;
    assert_board_ownership(&task, req.boss_mission_id)?;

    match req.action.as_str() {
        "accept" => {
            if task.status != BoardTaskStatus::Settled && task.status != BoardTaskStatus::Failed {
                return Err((
                    StatusCode::CONFLICT,
                    format!("task `{}` is {}, not settled", task.task_key, task.status),
                ));
            }
            task.status = BoardTaskStatus::Accepted;
        }
        "reject" => {
            let feedback = req
                .feedback
                .as_deref()
                .map(str::trim)
                .filter(|f| !f.is_empty())
                .ok_or((
                    StatusCode::BAD_REQUEST,
                    "reject requires non-empty feedback".to_string(),
                ))?;
            if task.status.is_terminal() && task.status != BoardTaskStatus::Failed {
                return Err((
                    StatusCode::CONFLICT,
                    format!("task `{}` is already {}", task.task_key, task.status),
                ));
            }
            task.notes = {
                let stamp = now_string();
                Some(match &task.notes {
                    Some(n) => format!("{n}\n[{stamp}] rejected: {feedback}"),
                    None => format!("[{stamp}] rejected: {feedback}"),
                })
            };
            // Prefer resuming the existing worker (it has the context); fall
            // back to a fresh spawn via the scheduler when the worker is gone.
            let resumed = if let Some(worker_id) = task.worker_mission_id {
                let (tx, _rx) = oneshot::channel();
                control
                    .cmd_tx
                    .send(ControlCommand::UserMessage {
                        id: Uuid::new_v4(),
                        content: format!(
                            "[task-board] The boss rejected your result for task `{}`. \
                             Address this feedback, then end your turn with the same \
                             done/BLOCKED contract as before:\n\n{}",
                            task.task_key, feedback
                        ),
                        agent: None,
                        target_mission_id: Some(worker_id),
                        strict: false,
                        source: Some("task-board".to_string()),
                        respond: tx,
                    })
                    .await
                    .is_ok()
            } else {
                false
            };
            if resumed {
                task.status = BoardTaskStatus::Running;
                // A rejection grants a fresh retry budget: the boss explicitly
                // asked for another attempt.
                task.attempts = 1;
            } else {
                task.status = BoardTaskStatus::Pending;
                task.attempts = 0;
                task.worker_mission_id = None;
                task.prompt = format!(
                    "{}\n\n[task-board] Previous attempt was rejected with feedback:\n{}",
                    task.prompt, feedback
                );
            }
            task.outcome = None;
        }
        other => {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("unknown action `{}` (use accept|reject)", other),
            ));
        }
    }

    control
        .mission_store
        .save_board_task(&task)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(task))
}

#[derive(Debug, Default, serde::Deserialize)]
pub struct CancelBoardTaskRequest {
    /// See `BoardVerdictRequest::boss_mission_id`.
    #[serde(default)]
    pub boss_mission_id: Option<Uuid>,
}

/// POST /api/control/board/tasks/:task_id/cancel — mark a task cancelled.
/// A running worker is left to finish its current turn; its settle is ignored.
pub async fn cancel_board_task(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(task_id): Path<Uuid>,
    body: Option<Json<CancelBoardTaskRequest>>,
) -> Result<Json<BoardTask>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let mut task = control
        .mission_store
        .get_board_task(task_id)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?
        .ok_or((StatusCode::NOT_FOUND, format!("task {} not found", task_id)))?;
    assert_board_ownership(&task, body.and_then(|Json(req)| req.boss_mission_id))?;
    if task.status.is_terminal() {
        return Err((
            StatusCode::CONFLICT,
            format!("task `{}` is already {}", task.task_key, task.status),
        ));
    }
    task.status = BoardTaskStatus::Cancelled;
    task.notes = {
        let stamp = now_string();
        Some(match &task.notes {
            Some(n) => format!("{n}\n[{stamp}] cancelled"),
            None => format!("[{stamp}] cancelled"),
        })
    };
    control
        .mission_store
        .save_board_task(&task)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok(Json(task))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn board_task_with_backend_and_model(backend: &str, model: &str) -> NewBoardTask {
        NewBoardTask {
            task_key: "model-check".to_string(),
            title: "Model check".to_string(),
            prompt: "Verify board model validation".to_string(),
            backend: backend.to_string(),
            model_override: Some(model.to_string()),
            ..Default::default()
        }
    }

    #[test]
    fn board_upsert_normalizes_codex_6_1_terra_and_rejects_nonexistent_terra_6() {
        let mut valid = vec![board_task_with_backend_and_model(
            "codex",
            "codex/gpt-6.1-terra",
        )];
        validate_and_normalize_board_tasks(&mut valid).unwrap();
        assert_eq!(valid[0].model_override.as_deref(), Some("gpt-6.1-terra"));

        let mut invalid = vec![board_task_with_backend_and_model("codex", "gpt-6-terra")];
        let (status, error) = validate_and_normalize_board_tasks(&mut invalid).unwrap_err();
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(error.contains("task `model-check`"), "{error}");
        assert!(error.contains("gpt-6.1-terra"), "{error}");
    }
}
