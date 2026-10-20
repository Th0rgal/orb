//! Automation HTTP handlers.

use super::*;

// === Automation API handlers ===

#[derive(Debug, Deserialize)]
pub struct CreateAutomationRequest {
    pub command_source: mission_store::CommandSource,
    pub trigger: mission_store::TriggerType,
    #[serde(default)]
    pub variables: HashMap<String, String>,
    #[serde(default)]
    pub retry_config: Option<mission_store::RetryConfig>,
    #[serde(default)]
    pub stop_policy: Option<mission_store::StopPolicy>,
    #[serde(default)]
    pub fresh_session: Option<mission_store::FreshSession>,
    /// When true, trigger the first execution immediately after creation.
    #[serde(default)]
    pub start_immediately: bool,
}

#[derive(Debug, Deserialize)]
pub struct UpdateAutomationRequest {
    pub command_source: Option<mission_store::CommandSource>,
    pub trigger: Option<mission_store::TriggerType>,
    pub variables: Option<HashMap<String, String>>,
    pub retry_config: Option<mission_store::RetryConfig>,
    pub stop_policy: Option<mission_store::StopPolicy>,
    pub fresh_session: Option<mission_store::FreshSession>,
    pub active: Option<bool>,
}

/// List all automations for a mission.
pub async fn list_mission_automations(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
) -> Result<Json<Vec<mission_store::Automation>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    let automations = control
        .mission_store
        .get_mission_automations(mission_id)
        .await
        .map_err(internal_error)?;

    Ok(Json(automations))
}

/// List all active automations across missions.
pub async fn list_active_automations(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<Vec<mission_store::Automation>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    let automations = control
        .mission_store
        .list_active_automations()
        .await
        .map_err(internal_error)?;

    Ok(Json(automations))
}

/// Create an automation for a mission.
pub async fn create_automation(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
    Json(req): Json<CreateAutomationRequest>,
) -> Result<Json<mission_store::Automation>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    if control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?
        .is_none()
    {
        tracing::warn!(
            mission_id = %mission_id,
            user_id = %user.id,
            "Rejecting automation create for missing mission"
        );
        return Err((
            StatusCode::NOT_FOUND,
            format!("Mission {} not found; cannot create automation", mission_id),
        ));
    }

    // Queued MCP actions carry the generation captured before durable acceptance.
    // Direct requests capture it before waiting behind Stop's transaction.
    let wakeup_generation = if req.variables.contains_key("__wakeup_source") {
        if !state.config.automations_enabled || !control.mission_store.is_persistent() {
            return Err((
                StatusCode::SERVICE_UNAVAILABLE,
                "Durable scheduling is disabled on this server".into(),
            ));
        }
        Some(match req.variables.get("__wakeup_run_generation") {
            Some(value) => value.parse::<u64>().map_err(|_| {
                (
                    StatusCode::BAD_REQUEST,
                    "Invalid originating wake-up generation".into(),
                )
            })?,
            None if req.variables.contains_key("__wakeup_local") => {
                return Err((
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "Local wake-up is missing its originating run generation".into(),
                ))
            }
            None => control
                .mission_store
                .get_latest_mission_run(mission_id)
                .await
                .map_err(internal_error)?
                .map_or(0, |run| run.generation),
        })
    } else {
        None
    };
    let continuation_lock = continuations::lock(mission_id);
    let _continuation_guard = continuation_lock.lock().await;
    let automation_id = req
        .variables
        .get("__wakeup_request_id")
        .map(|key| Uuid::new_v5(&mission_id, key.as_bytes()))
        .unwrap_or_else(Uuid::new_v4);
    if let Some(existing) = control
        .mission_store
        .get_automation(automation_id)
        .await
        .map_err(internal_error)?
    {
        return Ok(Json(existing));
    }
    if let Some(generation) = wakeup_generation {
        if !control
            .mission_store
            .wakeup_creation_allowed(mission_id, generation)
            .await
            .map_err(internal_error)?
        {
            return Err((if req.variables.contains_key("__wakeup_local") {StatusCode::GONE} else {StatusCode::CONFLICT}, "Wake-up creation belongs to a stopped or superseded mission generation; resume the mission first".into()));
        }
    }
    // Validate the command exists in the library if CommandSource::Library
    if let mission_store::CommandSource::Library { ref name } = req.command_source {
        validate_library_command(&state, name).await?;
    }

    // Generate webhook_id if trigger type is Webhook
    let trigger = match req.trigger {
        mission_store::TriggerType::Webhook { mut config } => {
            // Generate a unique webhook_id if not provided or empty
            if config.webhook_id.is_empty() {
                config.webhook_id = Uuid::new_v4().to_string();
            }
            mission_store::TriggerType::Webhook { config }
        }
        other => other,
    };

    // Validate cron expression before persisting
    if let mission_store::TriggerType::Cron { ref expression, .. } = trigger {
        if croner::Cron::new(expression).parse().is_err() {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("Invalid cron expression: {}", expression),
            ));
        }
    }

    if let mission_store::TriggerType::DurableJobTerminal { job_id } = &trigger {
        super::super::durable_jobs::terminal_for_mission(
            &state.config.working_dir,
            *job_id,
            mission_id,
        )
        .await
        .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
    }

    let start_immediately = req.start_immediately;

    // For interval/cron triggers, if start_immediately is false, set last_triggered_at
    // to now so the scheduler waits for the next occurrence before the first trigger.
    let last_triggered_at = if !start_immediately
        && matches!(
            trigger,
            mission_store::TriggerType::Interval { .. } | mission_store::TriggerType::Cron { .. }
        ) {
        Some(mission_store::now_string())
    } else {
        None
    };

    let last_triggered_at = if let (Some(due), mission_store::TriggerType::Interval { seconds }) =
        (req.variables.get("__wakeup_due_at"), &trigger)
    {
        let due = chrono::DateTime::parse_from_rfc3339(due)
            .map_err(|_| (StatusCode::BAD_REQUEST, "Invalid wake-up due time".into()))?;
        let seconds = i64::try_from(*seconds)
            .map_err(|_| (StatusCode::BAD_REQUEST, "Invalid wake-up delay".into()))?;
        Some(
            due.checked_sub_signed(
                chrono::Duration::try_seconds(seconds)
                    .ok_or((StatusCode::BAD_REQUEST, "Wake-up delay out of range".into()))?,
            )
            .ok_or((StatusCode::BAD_REQUEST, "Wake-up date out of range".into()))?
            .to_rfc3339(),
        )
    } else {
        last_triggered_at
    };

    // Build the complete Automation struct
    let fresh_session = req
        .fresh_session
        .unwrap_or(mission_store::FreshSession::Keep);
    if fresh_session == mission_store::FreshSession::Switch {
        let has_next_session_id = req
            .variables
            .get("nextSessionId")
            .map(|value| Uuid::parse_str(value.trim()).is_ok())
            .unwrap_or(false);
        if !has_next_session_id {
            return Err((
                StatusCode::BAD_REQUEST,
                "session mode 'switch' requires variables.nextSessionId to be a valid mission UUID"
                    .to_string(),
            ));
        }
    }

    let automation = mission_store::Automation {
        id: automation_id,
        mission_id,
        command_source: req.command_source,
        trigger,
        variables: {
            let mut variables = req.variables;
            if let Some(generation) = wakeup_generation {
                variables.insert("__wakeup_run_generation".into(), generation.to_string());
            }
            variables
        },
        active: true,
        stop_policy: req
            .stop_policy
            .unwrap_or(mission_store::StopPolicy::WhenFailingConsecutively { count: 2 }),
        fresh_session,
        created_at: mission_store::now_string(),
        last_triggered_at,
        retry_config: req.retry_config.unwrap_or_default(),
        consecutive_failures: 0,
        driver: mission_store::AutomationDriver::Scheduler,
    };

    let is_one_shot_wakeup = automation.variables.contains_key("__wakeup_source");
    let wakeup_key = wakeup_supersession_key(
        automation
            .variables
            .get("__wakeup_source")
            .map(String::as_str),
        &automation.trigger,
    );

    tracing::info!(
        mission_id = %mission_id,
        automation_id = %automation.id,
        command_source = ?automation.command_source,
        trigger = ?automation.trigger,
        fresh_session = ?automation.fresh_session,
        is_one_shot_wakeup,
        "Creating mission automation"
    );

    let mut automation = control
        .mission_store
        .create_automation(automation)
        .await
        .map_err(internal_error)?;

    // One pending wakeup per mission: a new ScheduleWakeup
    // supersedes any earlier un-fired one. Without this, a turn that starts
    // before the previous wakeup fires (user message, other automation)
    // schedules a second wakeup, and the leftovers pile up into overlapping
    // re-triggers (observed: 5 concurrent pending wakeups on one mission,
    // all firing within two minutes).
    //
    // Ordering: the new wakeup is created *first*, then older ones are
    // deactivated — if creation fails the mission keeps its previous wakeup
    // instead of losing all of them. Only automations strictly older than
    // the new row are deactivated ((created_at, id) tie-break), so two
    // overlapping creates converge on exactly the newest wakeup instead of
    // deactivating each other.
    let mut wakeup_iteration: u32 = 1;
    if let Some(wakeup_key) = wakeup_key {
        if let Ok(existing) = control
            .mission_store
            .get_mission_automations(mission_id)
            .await
        {
            let new_key = (automation.created_at.clone(), automation.id.to_string());
            let priors: Vec<_> = existing
                .into_iter()
                .filter(|a| {
                    a.id != automation.id
                        && wakeup_supersession_key(
                            a.variables.get("__wakeup_source").map(String::as_str),
                            &a.trigger,
                        ) == Some(wakeup_key.clone())
                })
                .collect();
            wakeup_iteration = (priors.len() as u32).saturating_add(1);
            for prior in priors
                .into_iter()
                .filter(|a| a.active && (a.created_at.clone(), a.id.to_string()) < new_key)
            {
                if let Err(e) = control
                    .mission_store
                    .update_automation_active(prior.id, false)
                    .await
                {
                    tracing::warn!(
                        "Failed to deactivate superseded wakeup automation {}: {}",
                        prior.id,
                        e
                    );
                }
            }
        }
    }

    // Persist a goal-iteration marker for self-paced loops so the dashboard
    // and assistant can see loop progress after a reload — previously this
    // state lived only in the (transient) wakeup automations.
    if is_one_shot_wakeup {
        let _ = control.events_tx.send(AgentEvent::GoalIteration {
            iteration: wakeup_iteration,
            objective: automation
                .variables
                .get("__wakeup_reason")
                .cloned()
                .unwrap_or_default(),
            mission_id: Some(mission_id),
        });
    }

    // If start_immediately is requested for agent_finished triggers, fire the
    // first execution right away by resolving the command and sending it as a
    // user message to the control actor.
    if start_immediately
        && matches!(
            automation.trigger,
            mission_store::TriggerType::AgentFinished
        )
    {
        if let Ok(Some(mission)) = control.mission_store.get_mission(mission_id).await {
            // Newly created automation has 0 consecutive failures and has never fired.
            if stop_policy_matches_status(&automation.stop_policy, mission.status, 0, false).await {
                let mut updated = automation.clone();
                updated.active = false;
                if let Err(e) = control.mission_store.update_automation(updated).await {
                    tracing::warn!(
                        "Failed to disable automation {} on create due to stop policy: {}",
                        automation.id,
                        e
                    );
                }
                automation.active = false;
                return Ok(Json(automation));
            }
        }

        let cmd_content =
            resolve_automation_command(&automation, mission_id, &state, &control.mission_store)
                .await;

        if let Some(content) = cmd_content {
            let target_mission_id = match control.mission_store.get_mission(mission_id).await {
                Ok(Some(mission)) => {
                    resolve_agent_finished_target_mission(mission_id, mission.status, &automation)
                }
                Ok(None) => mission_id,
                Err(e) => {
                    tracing::warn!(
                        "Failed to load mission {} while resolving start_immediately target: {}",
                        mission_id,
                        e
                    );
                    mission_id
                }
            };

            // Record the execution in Running status – it will be completed
            // by complete_turn_executions_for_mission when the agent
            // finishes processing.
            let execution_id = Uuid::new_v4();
            let execution = mission_store::AutomationExecution {
                id: execution_id,
                automation_id: automation.id,
                mission_id: target_mission_id,
                triggered_at: mission_store::now_string(),
                trigger_source: "start_immediately".to_string(),
                status: mission_store::ExecutionStatus::Running,
                webhook_payload: None,
                variables_used: automation.variables.clone(),
                completed_at: None,
                error: None,
                retry_count: 0,
            };
            let _ = control
                .mission_store
                .create_automation_execution(execution)
                .await;
            let _ = control
                .mission_store
                .update_automation_last_triggered(automation.id)
                .await;

            // Send as a user message to the mission
            let (respond_tx, _respond_rx) = tokio::sync::oneshot::channel();
            let _ = control
                .cmd_tx
                .send(ControlCommand::UserMessage {
                    id: Uuid::new_v4(),
                    content,
                    agent: None,
                    target_mission_id: Some(target_mission_id),
                    strict: false,
                    source: None,
                    respond: respond_tx,
                })
                .await;
        }
    }

    Ok(Json(automation))
}

/// Get an automation by ID.
pub async fn get_automation(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(automation_id): Path<Uuid>,
) -> Result<Json<mission_store::Automation>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    let automation = require_automation(&control.mission_store, automation_id).await?;

    Ok(Json(automation))
}

/// Update an automation.
pub async fn update_automation(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(automation_id): Path<Uuid>,
    Json(req): Json<UpdateAutomationRequest>,
) -> Result<Json<mission_store::Automation>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    let original = require_automation(&control.mission_store, automation_id).await?;
    let mutex = continuations::lock(original.mission_id);
    let _guard = mutex.lock().await;
    let mut automation = require_automation(&control.mission_store, automation_id).await?;
    let was_wakeup = automation.variables.contains_key("__wakeup_source");

    // Validate the command exists in the library if CommandSource::Library is being updated
    if let Some(mission_store::CommandSource::Library { name }) = req.command_source.as_ref() {
        validate_library_command(&state, name).await?;
    }

    // Update fields if provided
    if let Some(command_source) = req.command_source {
        automation.command_source = command_source;
    }

    if let Some(trigger) = req.trigger {
        // Generate webhook_id if trigger type is Webhook and webhook_id is empty
        automation.trigger = match trigger {
            mission_store::TriggerType::Webhook { mut config } => {
                if config.webhook_id.is_empty() {
                    config.webhook_id = Uuid::new_v4().to_string();
                }
                mission_store::TriggerType::Webhook { config }
            }
            other => other,
        };
    }

    if let Some(variables) = req.variables {
        automation.variables = variables;
    }

    if let Some(retry_config) = req.retry_config {
        automation.retry_config = retry_config;
    }

    if let Some(stop_policy) = req.stop_policy {
        automation.stop_policy = stop_policy;
    }

    if let Some(fresh_session) = req.fresh_session {
        automation.fresh_session = fresh_session;
    }

    if let Some(active) = req.active {
        automation.active = active;
    }

    if let mission_store::TriggerType::Cron { expression, .. } = &automation.trigger {
        if croner::Cron::new(expression).parse().is_err() {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("Invalid cron expression: {expression}"),
            ));
        }
    }
    if let mission_store::TriggerType::DurableJobTerminal { job_id } = &automation.trigger {
        super::super::durable_jobs::terminal_for_mission(
            &state.config.working_dir,
            *job_id,
            automation.mission_id,
        )
        .await
        .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
    }

    if automation.fresh_session == mission_store::FreshSession::Switch {
        let has_next_session_id = automation
            .variables
            .get("nextSessionId")
            .map(|value| Uuid::parse_str(value.trim()).is_ok())
            .unwrap_or(false);
        if !has_next_session_id {
            return Err((
                StatusCode::BAD_REQUEST,
                "session mode 'switch' requires variables.nextSessionId to be a valid mission UUID"
                    .to_string(),
            ));
        }
    }

    if was_wakeup && !automation.active {
        continuations::ensure_cancellable(&control.mission_store, automation_id).await?;
        control
            .mission_store
            .cancel_scheduled_delivery(automation_id)
            .await
            .map_err(internal_error)?;
    }
    // Update automation in the store
    control
        .mission_store
        .update_automation(automation.clone())
        .await
        .map_err(internal_error)?;

    Ok(Json(automation))
}

/// Delete an automation.
pub async fn delete_automation(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(automation_id): Path<Uuid>,
) -> Result<StatusCode, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    let automation = require_automation(&control.mission_store, automation_id).await?;
    let mutex = continuations::lock(automation.mission_id);
    let _guard = mutex.lock().await;
    if automation.variables.contains_key("__wakeup_source") {
        continuations::ensure_cancellable(&control.mission_store, automation_id).await?;
        control
            .mission_store
            .cancel_scheduled_delivery(automation_id)
            .await
            .map_err(internal_error)?;
    }
    let deleted = control
        .mission_store
        .delete_automation(automation_id)
        .await
        .map_err(internal_error)?;

    if deleted {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err((
            StatusCode::NOT_FOUND,
            format!("Automation {} not found", automation_id),
        ))
    }
}

/// Get execution history for an automation.
pub async fn get_automation_executions(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(automation_id): Path<Uuid>,
) -> Result<Json<Vec<mission_store::AutomationExecution>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    let _automation = require_automation(&control.mission_store, automation_id).await?;

    let executions = control
        .mission_store
        .get_automation_executions(automation_id, Some(100))
        .await
        .map_err(internal_error)?;

    Ok(Json(executions))
}

/// Get all automation executions for a mission.
pub async fn get_mission_automation_executions(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
) -> Result<Json<Vec<mission_store::AutomationExecution>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    let executions = control
        .mission_store
        .get_mission_automation_executions(mission_id, Some(100))
        .await
        .map_err(internal_error)?;

    Ok(Json(executions))
}
