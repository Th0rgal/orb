//! Client transcript/status, mission status/title and tree/progress handlers.

use super::*;

#[derive(Debug, Deserialize)]
pub struct ClientTranscriptRequest {
    pub run_id: Option<Uuid>,
    pub generation: Option<u64>,
    pub id: Uuid,
    /// `user` or `assistant`.
    pub role: String,
    pub content: String,
}

#[derive(Debug, Deserialize)]
pub struct ClientStatusRequest {
    pub scheduled_execution_id: Option<Uuid>,
    pub run_id: Option<Uuid>,
    pub generation: Option<u64>,
    pub status: String,
}

/// Append one transcript row for a mission the Orb client is executing.
/// Refused for every other mission so this cannot inject history into a
/// backend-owned run.
pub async fn append_client_transcript(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<ClientTranscriptRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let content = req.content.trim().to_string();
    if content.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "content is required".into()));
    }
    let control = control_for_user(&state, &user).await;
    if !mission_is_client_placed(&control, id)
        .await
        .map_err(internal_error)?
    {
        return Err((
            StatusCode::CONFLICT,
            "transcript append is only for client-placed missions".into(),
        ));
    }
    machine_transfer::check_client_receipt(&control, id, req.run_id, req.generation).await?;
    let event = match req.role.as_str() {
        "user" => AgentEvent::UserMessage {
            id: req.id,
            content,
            queued: false,
            mission_id: Some(id),
            source: Some(format!("orb-client:{}", user.id)),
        },
        "assistant" => AgentEvent::AssistantMessage {
            id: req.run_id.unwrap_or(req.id),
            content,
            success: true,
            cost_cents: 0,
            cost_source: crate::agents::CostSource::Unknown,
            usage: None,
            model: None,
            model_normalized: None,
            mission_id: Some(id),
            shared_files: None,
            resumable: false,
            completion_evidence: None,
        },
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                "role must be user or assistant".into(),
            ))
        }
    };
    control
        .mission_store
        .log_event(id, &event)
        .await
        .map_err(internal_error)?;
    let _ = control.events_tx.send(event);
    Ok(Json(serde_json::json!({ "ok": true })))
}

/// Terminal status for a client-placed mission. Does not start a runner.
pub async fn set_client_mission_status(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<ClientStatusRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let status = match req.status.as_str() {
        "completed" => MissionStatus::Completed,
        "failed" => MissionStatus::Failed,
        "interrupted" => MissionStatus::Interrupted,
        "awaiting_user" => MissionStatus::AwaitingUser,
        other => {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("unsupported client status {other}"),
            ))
        }
    };
    let control = control_for_user(&state, &user).await;
    if !mission_is_client_placed(&control, id)
        .await
        .map_err(internal_error)?
    {
        return Err((
            StatusCode::CONFLICT,
            "status updates of this kind are only for client-placed missions".into(),
        ));
    }
    let run =
        machine_transfer::check_client_receipt(&control, id, req.run_id, req.generation).await?;
    // A stopped process also represents queue advancement or machine transfer.
    // Explicit user Stop revokes wake-ups through continuations/cancel instead.
    control
        .mission_store
        .update_mission_status_with_reason(id, status, Some("client_runner"))
        .await
        .map_err(internal_error)?;
    control
        .mission_store
        .complete_turn_executions_for_mission(
            id,
            req.scheduled_execution_id,
            matches!(
                status,
                MissionStatus::Completed | MissionStatus::AwaitingUser
            ),
            matches!(status, MissionStatus::Failed | MissionStatus::Interrupted)
                .then(|| "client_runner".to_string()),
        )
        .await
        .map_err(internal_error)?;
    if let Some(run) = run {
        control
            .mission_store
            .finish_mission_run(run.run_id, run.generation, Some("client_runner"))
            .await
            .map_err(internal_error)?;
    }
    let _ = control.events_tx.send(AgentEvent::MissionStatusChanged {
        completion: None,
        execution: None,
        mission_id: id,
        status,
        summary: Some("client_runner".into()),
    });
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub async fn set_mission_status(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<SetMissionStatusRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let (tx, rx) = oneshot::channel();

    let control = control_for_user(&state, &user).await;
    control
        .cmd_tx
        .send(ControlCommand::SetMissionStatus {
            id,
            status: req.status,
            respond: tx,
        })
        .await
        .map_err(session_unavailable)?;

    rx.await
        .map_err(recv_failed)?
        .map(|_| ok_json())
        .map_err(internal_error)
}

/// Set mission title (rename mission).
pub async fn set_mission_title(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<SetMissionTitleRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let (tx, rx) = oneshot::channel();

    let control = control_for_user(&state, &user).await;
    control
        .cmd_tx
        .send(ControlCommand::SetMissionTitle {
            id,
            title: req.title,
            respond: tx,
        })
        .await
        .map_err(session_unavailable)?;

    rx.await
        .map_err(recv_failed)?
        .map(|_| ok_json())
        .map_err(internal_error)
}

/// Get the current mission (if any).
pub async fn get_current_mission(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<Option<Mission>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let current_id = *control.current_mission.read().await;

    match current_id {
        Some(id) => {
            let mission = control
                .mission_store
                .get_mission(id)
                .await
                .map_err(internal_error)?;
            Ok(Json(mission))
        }
        None => Ok(Json(None)),
    }
}

/// Get tree for a specific mission.
/// For currently running mission, returns the live tree from memory.
/// For completed missions, returns the saved final_tree from the database.
pub async fn get_mission_tree(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
) -> Result<Json<Option<AgentTreeNode>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    // Check if this is the current active mission
    let current_id = *control.current_mission.read().await;
    if current_id == Some(mission_id) {
        // Return live tree from memory
        let tree = control.current_tree.read().await.clone();
        return Ok(Json(tree));
    }
    let tree = control
        .mission_store
        .get_mission_tree(mission_id)
        .await
        .map_err(internal_error)?;
    if tree.is_some() {
        return Ok(Json(tree));
    }

    let mission_exists = control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?;
    if mission_exists.is_some() {
        Ok(Json(None))
    } else {
        Err((StatusCode::NOT_FOUND, "Mission not found".to_string()))
    }
}

/// Get current execution progress (for progress indicator).
pub async fn get_progress(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Json<ExecutionProgress> {
    let control = control_for_user(&state, &user).await;
    let progress = control.progress.read().await.clone();
    Json(progress)
}
