//! Inbound webhook receiver and assistant mission mode handlers.

use super::*;

/// Webhook receiver endpoint for triggering automations.
/// Accepts POST requests with JSON body and validates webhook secret if configured.
pub async fn webhook_receiver(
    State(state): State<Arc<AppState>>,
    Path((mission_id, webhook_id)): Path<(Uuid, String)>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, (StatusCode, String)> {
    use super::super::automation_variables::{
        apply_webhook_mappings, substitute_variables, SubstitutionContext,
    };
    use super::super::mission_store::{
        AutomationExecution, CommandSource, ExecutionStatus, TriggerType,
    };
    use hmac::{Hmac, Mac};
    use sha2::Sha256;

    let payload: serde_json::Value = serde_json::from_slice(&body).map_err(|e| {
        (
            StatusCode::BAD_REQUEST,
            format!("Invalid JSON payload: {}", e),
        )
    })?;

    // Search across all user sessions for the webhook automation.
    // Automations are user-scoped, so we must check every session's mission store.
    let sessions = state.control.all_sessions().await;
    let mut found: Option<(mission_store::Automation, ControlState)> = None;
    for session in &sessions {
        match session
            .mission_store
            .get_automation_by_webhook_id(&webhook_id)
            .await
        {
            Ok(Some(automation)) => {
                found = Some((automation, session.clone()));
                break;
            }
            Ok(None) => continue,
            Err(e) => {
                tracing::warn!("Error searching webhook {} in session: {}", webhook_id, e);
                continue;
            }
        }
    }

    let (automation, control) = found.ok_or((
        StatusCode::NOT_FOUND,
        format!("Webhook {} not found", webhook_id),
    ))?;

    // Verify mission_id matches
    if automation.mission_id != mission_id {
        return Err((
            StatusCode::BAD_REQUEST,
            format!(
                "Webhook {} does not belong to mission {}",
                webhook_id, mission_id
            ),
        ));
    }

    // Check if automation is active
    if !automation.active {
        return Err((
            StatusCode::BAD_REQUEST,
            format!("Automation {} is not active", automation.id),
        ));
    }

    // Extract webhook config
    let webhook_config = match &automation.trigger {
        TriggerType::Webhook { config } => config,
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                "Automation is not configured for webhook trigger".to_string(),
            ));
        }
    };

    // Validate webhook secret if configured (HMAC-SHA256)
    if let Some(ref secret) = webhook_config.secret {
        // Check for signature in headers (support both GitHub and generic formats)
        let signature_header = headers
            .get("x-hub-signature-256")
            .or_else(|| headers.get("x-webhook-signature"))
            .and_then(|v| v.to_str().ok());

        if let Some(signature) = signature_header {
            let signature = signature.trim();
            let signature = signature.strip_prefix("sha256=").unwrap_or(signature);
            let signature_bytes = hex::decode(signature).map_err(|_| {
                (
                    StatusCode::UNAUTHORIZED,
                    "Invalid webhook signature".to_string(),
                )
            })?;

            let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).map_err(|_| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Invalid webhook secret".to_string(),
                )
            })?;
            mac.update(&body);

            if mac.verify_slice(&signature_bytes).is_err() {
                return Err((
                    StatusCode::UNAUTHORIZED,
                    "Invalid webhook signature".to_string(),
                ));
            }
        } else {
            return Err((
                StatusCode::UNAUTHORIZED,
                "Missing webhook signature".to_string(),
            ));
        }
    }

    // Get mission
    let mission = control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?
        .ok_or((
            StatusCode::NOT_FOUND,
            format!("Mission {} not found", mission_id),
        ))?;

    let consecutive_failures =
        consecutive_failure_count_for_automation(&control.mission_store, &automation).await;
    let has_fired = if matches!(
        automation.stop_policy,
        mission_store::StopPolicy::AfterFirstFire
    ) {
        automation_has_fired(&control.mission_store, automation.id).await
    } else {
        false
    };

    if stop_policy_matches_status(
        &automation.stop_policy,
        mission.status,
        consecutive_failures,
        has_fired,
    )
    .await
    {
        let mut updated = automation.clone();
        updated.active = false;
        if let Err(e) = control.mission_store.update_automation(updated).await {
            tracing::warn!(
                "Failed to disable webhook automation {} after stop policy match: {}",
                automation.id,
                e
            );
        }
        return Err((
            StatusCode::BAD_REQUEST,
            format!(
                "Automation {} is stopped by policy {:?} for mission status {:?}",
                automation.id, automation.stop_policy, mission.status
            ),
        ));
    }

    // Get workspace for reading local files
    let workspace = state.workspaces.get(mission.workspace_id).await;

    // Fetch the command content based on the command source
    let command_content = match &automation.command_source {
        CommandSource::Library { name } => {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "Library command '{}' cannot be executed: Library commands have been retired",
                    name
                ),
            ));
        }
        CommandSource::LocalFile { path } => {
            // Read file from mission workspace
            let file_path = if let Some(ws) = workspace.as_ref() {
                ws.path.join(path)
            } else {
                return Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("Workspace {} not found", mission.workspace_id),
                ));
            };

            match tokio::fs::read_to_string(&file_path).await {
                Ok(content) => content,
                Err(e) => {
                    return Err((
                        StatusCode::INTERNAL_SERVER_ERROR,
                        format!("Failed to read file '{}': {}", file_path.display(), e),
                    ));
                }
            }
        }
        CommandSource::Inline { content } => content.clone(),
        CommandSource::NativeLoop { .. } => {
            return Err((
                StatusCode::BAD_REQUEST,
                "Webhook triggers are not supported for native-loop automations".to_string(),
            ));
        }
    };

    // Apply webhook variable mappings
    let webhook_vars = apply_webhook_mappings(&payload, &webhook_config.variable_mappings);

    // Extract direct "variables" from payload (allows callers to pass {"variables": {"key": "value"}})
    let direct_vars: HashMap<String, String> = payload
        .get("variables")
        .and_then(|v| v.as_object())
        .map(|obj| {
            obj.iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                .collect()
        })
        .unwrap_or_default();

    // Build substitution context for variable replacement
    let mut context = SubstitutionContext::new(mission.id);
    if let Some(ref title) = mission.title {
        context = context.with_mission_name(title.clone());
    }
    if let Some(ws) = workspace.as_ref() {
        context = context.with_working_directory(ws.path.to_string_lossy().to_string());
    }
    context = context.with_webhook_payload(payload.clone());

    // Merge variables: automation defaults < webhook mappings < direct variables (highest priority)
    let mut merged_vars = automation.variables.clone();
    merged_vars.extend(webhook_vars.clone());
    merged_vars.extend(direct_vars);
    context = context.with_custom_variables(merged_vars.clone());

    // Apply variable substitution
    let substituted_content = substitute_variables(&command_content, &context);

    // Create execution record
    let execution_id = Uuid::new_v4();
    let execution = AutomationExecution {
        id: execution_id,
        automation_id: automation.id,
        mission_id: mission.id,
        triggered_at: mission_store::now_string(),
        trigger_source: "webhook".to_string(),
        status: ExecutionStatus::Pending,
        webhook_payload: Some(payload),
        variables_used: merged_vars,
        completed_at: None,
        error: None,
        retry_count: 0,
    };

    let mut execution = match control
        .mission_store
        .create_automation_execution(execution)
        .await
    {
        Ok(exec) => exec,
        Err(e) => {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to create execution record: {}", e),
            ));
        }
    };

    tracing::info!(
        "Webhook {} triggered automation {} (execution {}) for mission {}",
        webhook_id,
        automation.id,
        execution_id,
        mission.id
    );

    // Update execution status to Running
    execution.status = ExecutionStatus::Running;
    if let Err(e) = control
        .mission_store
        .update_automation_execution(execution.clone())
        .await
    {
        tracing::warn!(
            "Failed to update execution status to running for {}: {}",
            execution_id,
            e
        );
    }

    // Send the message to the mission
    let message_id = Uuid::new_v4();
    let (respond_tx, _respond_rx) = tokio::sync::oneshot::channel();

    let cmd_tx = control.cmd_tx.clone();
    let mission_store = control.mission_store.clone();
    drop(control); // Release the lock before sending

    let send_result = cmd_tx
        .send(ControlCommand::UserMessage {
            id: message_id,
            content: substituted_content,
            agent: None,
            target_mission_id: Some(mission.id),
            strict: false,
            source: None,
            respond: respond_tx,
        })
        .await;

    match send_result {
        Ok(_) => {
            // Message queued successfully – keep execution in Running
            // status. The actual success/failure will be determined
            // when the agent finishes processing and
            // complete_turn_executions_for_mission is called.
            if let Err(e) = mission_store
                .update_automation_last_triggered(automation.id)
                .await
            {
                tracing::warn!(
                    "Failed to update automation last triggered time for {}: {}",
                    automation.id,
                    e
                );
            }

            Ok(StatusCode::OK)
        }
        Err(e) => {
            // Failed to even send the message – mark as Failed immediately
            execution.status = ExecutionStatus::Failed;
            execution.completed_at = Some(mission_store::now_string());
            execution.error = Some(format!("Failed to send message: {}", e));

            if let Err(e) = mission_store.update_automation_execution(execution).await {
                tracing::warn!(
                    "Failed to update execution status to failed for {}: {}",
                    execution_id,
                    e
                );
            }

            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to trigger automation: {}", e),
            ))
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Assistant missions
// ─────────────────────────────────────────────────────────────────────────────

/// List all missions with MissionMode::Assistant.
pub async fn list_assistant_missions(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<Vec<super::super::mission_store::Mission>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let missions = control
        .mission_store
        .list_assistant_missions()
        .await
        .map_err(internal_error)?;
    Ok(Json(missions))
}

/// Set mission mode (task or assistant).
pub async fn set_mission_mode(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<SetMissionModeRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    use super::super::mission_store::MissionMode;

    let mode = match req.mode.as_str() {
        "task" => MissionMode::Task,
        "assistant" => MissionMode::Assistant,
        other => {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("Invalid mission mode: {other}. Must be 'task' or 'assistant'."),
            ));
        }
    };

    let control = control_for_user(&state, &user).await;
    control
        .mission_store
        .update_mission_mode(id, mode)
        .await
        .map_err(internal_error)?;

    Ok(ok_json())
}

#[derive(Deserialize)]
pub struct SetMissionModeRequest {
    pub mode: String,
}
