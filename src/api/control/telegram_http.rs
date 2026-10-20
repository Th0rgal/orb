//! Telegram channel/bot HTTP handlers.

use super::*;

// ─────────────────────────────────────────────────────────────────────────────
// Telegram Channel endpoints
// ─────────────────────────────────────────────────────────────────────────────

/// List Telegram channels for a mission.
pub async fn list_telegram_channels(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
) -> Result<Json<Vec<super::super::mission_store::TelegramChannel>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let channels = control
        .mission_store
        .list_telegram_channels(mission_id)
        .await
        .map_err(internal_error)?;
    Ok(Json(channels))
}

/// Create a Telegram channel for a mission.
pub async fn create_telegram_channel(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
    Json(req): Json<CreateTelegramChannelRequest>,
) -> Result<Json<super::super::mission_store::TelegramChannel>, (StatusCode, String)> {
    use super::super::mission_store::{now_string, MissionMode, TelegramChannel};

    let control = control_for_user(&state, &user).await;

    // Verify mission exists
    let mission = control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                format!("Mission {} not found", mission_id),
            )
        })?;

    // Auto-set mission to Assistant mode when adding a Telegram channel
    if mission.mission_mode != MissionMode::Assistant {
        if let Err(e) = control
            .mission_store
            .update_mission_mode(mission_id, MissionMode::Assistant)
            .await
        {
            tracing::warn!(
                "Failed to set assistant mode on mission {}: {}",
                mission_id,
                e
            );
        } else {
            tracing::info!(
                "Auto-set mission {} to Assistant mode (Telegram channel attached)",
                mission_id
            );
        }
    }

    // Reject duplicate bot tokens to avoid webhook conflicts
    let all_channels = control
        .mission_store
        .list_all_telegram_channels()
        .await
        .map_err(internal_error)?;
    if all_channels.iter().any(|c| c.bot_token == req.bot_token) {
        return Err((
            StatusCode::CONFLICT,
            "A channel with this bot token already exists".to_string(),
        ));
    }

    let now = now_string();
    let webhook_secret = Uuid::new_v4().to_string().replace('-', "");
    let channel = TelegramChannel {
        id: Uuid::new_v4(),
        mission_id,
        bot_token: req.bot_token,
        bot_username: req.bot_username,
        allowed_chat_ids: req.allowed_chat_ids.unwrap_or_default(),
        trigger_mode: req.trigger_mode.unwrap_or_default(),
        active: true,
        webhook_secret: Some(webhook_secret),
        instructions: req.instructions,
        auto_create_missions: false,
        default_backend: None,
        default_model_override: None,
        default_model_effort: None,
        default_workspace_id: None,
        default_config_profile: None,
        default_agent: None,
        created_at: now.clone(),
        updated_at: now,
    };

    let created = control
        .mission_store
        .create_telegram_channel(channel)
        .await
        .map_err(internal_error)?;

    // Register the webhook — roll back the channel if this fails
    let public_url = std::env::var("SANDBOXED_PUBLIC_URL")
        .unwrap_or_else(|_| format!("http://{}:{}", state.config.host, state.config.port));
    if let Err(e) = state
        .telegram_bridge
        .start_channel(
            created.clone(),
            control.cmd_tx.clone(),
            control.events_tx.clone(),
            control.mission_store.clone(),
            &public_url,
        )
        .await
    {
        let _ = control
            .mission_store
            .delete_telegram_channel(created.id)
            .await;
        return Err(internal_error(e));
    }

    tracing::info!(
        "Created Telegram channel {} for mission {}",
        created.id,
        mission_id
    );

    Ok(Json(created))
}

#[derive(Deserialize)]
pub struct CreateTelegramChannelRequest {
    pub bot_token: String,
    #[serde(default)]
    pub bot_username: Option<String>,
    #[serde(default)]
    pub allowed_chat_ids: Option<Vec<i64>>,
    #[serde(default)]
    pub trigger_mode: Option<super::super::mission_store::TelegramTriggerMode>,
    /// System instructions for the assistant (e.g. "Don't use markdown formatting")
    #[serde(default)]
    pub instructions: Option<String>,
}

/// Delete a Telegram channel.
pub async fn delete_telegram_channel(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(channel_id): Path<Uuid>,
) -> Result<StatusCode, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    // Fetch channel first so we can clean up the placeholder mission for auto-create bots
    let channel = control
        .mission_store
        .get_telegram_channel(channel_id)
        .await
        .map_err(internal_error)?;

    // Delete from store first (verifies ownership), then stop the poller
    let deleted = control
        .mission_store
        .delete_telegram_channel(channel_id)
        .await
        .map_err(internal_error)?;

    if deleted {
        state.telegram_bridge.stop_channel(channel_id).await;

        // Clean up the placeholder mission for auto-create bots
        if let Some(ch) = channel {
            if ch.auto_create_missions {
                let _ = control.mission_store.delete_mission(ch.mission_id).await;
            }
        }

        tracing::info!("Deleted Telegram channel {}", channel_id);
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err((
            StatusCode::NOT_FOUND,
            format!("Telegram channel {} not found", channel_id),
        ))
    }
}

/// Toggle a Telegram channel's active state.
pub async fn toggle_telegram_channel(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(channel_id): Path<Uuid>,
    Json(req): Json<ToggleTelegramChannelRequest>,
) -> Result<Json<super::super::mission_store::TelegramChannel>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    let mut channel = control
        .mission_store
        .get_telegram_channel(channel_id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                format!("Telegram channel {} not found", channel_id),
            )
        })?;

    let previous_active = channel.active;
    channel.active = req.active;
    channel.updated_at = super::super::mission_store::now_string();

    control
        .mission_store
        .update_telegram_channel(channel.clone())
        .await
        .map_err(internal_error)?;

    if channel.active {
        let public_url = std::env::var("SANDBOXED_PUBLIC_URL")
            .unwrap_or_else(|_| format!("http://{}:{}", state.config.host, state.config.port));
        if let Err(e) = state
            .telegram_bridge
            .start_channel(
                channel.clone(),
                control.cmd_tx.clone(),
                control.events_tx.clone(),
                control.mission_store.clone(),
                &public_url,
            )
            .await
        {
            // Roll back active state
            channel.active = previous_active;
            channel.updated_at = super::super::mission_store::now_string();
            let _ = control.mission_store.update_telegram_channel(channel).await;
            return Err(internal_error(e));
        }
    } else {
        state.telegram_bridge.stop_channel(channel_id).await;
    }

    Ok(Json(channel))
}

#[derive(Deserialize)]
pub struct ToggleTelegramChannelRequest {
    pub active: bool,
}

/// Update a Telegram channel's settings (PATCH).
pub async fn update_telegram_channel(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(channel_id): Path<Uuid>,
    Json(req): Json<UpdateTelegramChannelRequest>,
) -> Result<Json<super::super::mission_store::TelegramChannel>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    let original_channel = control
        .mission_store
        .get_telegram_channel(channel_id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                format!("Telegram channel {} not found", channel_id),
            )
        })?;

    let mut channel = original_channel.clone();

    // Apply partial updates
    if let Some(active) = req.active {
        channel.active = active;
    }
    if let Some(trigger_mode) = req.trigger_mode {
        channel.trigger_mode = trigger_mode;
    }
    if let Some(allowed_chat_ids) = req.allowed_chat_ids {
        channel.allowed_chat_ids = allowed_chat_ids;
    }
    if let Some(instructions) = req.instructions {
        channel.instructions = if instructions.is_empty() {
            None
        } else {
            Some(instructions)
        };
    }
    if let Some(backend) = req.default_backend {
        channel.default_backend = if backend.is_empty() {
            None
        } else {
            Some(backend)
        };
    }
    if let Some(model) = req.default_model_override {
        channel.default_model_override = if model.is_empty() { None } else { Some(model) };
    }
    if let Some(effort) = req.default_model_effort {
        channel.default_model_effort = if effort.is_empty() {
            None
        } else {
            Some(effort)
        };
    }
    if let Some(ws_id) = req.default_workspace_id {
        channel.default_workspace_id = if ws_id.is_empty() {
            None
        } else {
            uuid::Uuid::parse_str(&ws_id).ok()
        };
    }
    if let Some(profile) = req.default_config_profile {
        channel.default_config_profile = if profile.is_empty() {
            None
        } else {
            Some(profile)
        };
    }
    if let Some(agent) = req.default_agent {
        channel.default_agent = if agent.is_empty() { None } else { Some(agent) };
    }
    channel.updated_at = super::super::mission_store::now_string();

    control
        .mission_store
        .update_telegram_channel(channel.clone())
        .await
        .map_err(internal_error)?;

    // Re-register or stop webhook based on active state
    if channel.active {
        let public_url = std::env::var("SANDBOXED_PUBLIC_URL")
            .unwrap_or_else(|_| format!("http://{}:{}", state.config.host, state.config.port));
        if let Err(e) = state
            .telegram_bridge
            .start_channel(
                channel.clone(),
                control.cmd_tx.clone(),
                control.events_tx.clone(),
                control.mission_store.clone(),
                &public_url,
            )
            .await
        {
            // Roll back to original channel state
            let _ = control
                .mission_store
                .update_telegram_channel(original_channel)
                .await;
            return Err(internal_error(e));
        }
    } else {
        state.telegram_bridge.stop_channel(channel_id).await;
    }

    Ok(Json(channel))
}

#[derive(Deserialize)]
pub struct UpdateTelegramChannelRequest {
    #[serde(default)]
    pub active: Option<bool>,
    #[serde(default)]
    pub trigger_mode: Option<super::super::mission_store::TelegramTriggerMode>,
    #[serde(default)]
    pub allowed_chat_ids: Option<Vec<i64>>,
    #[serde(default)]
    pub instructions: Option<String>,
    #[serde(default)]
    pub default_backend: Option<String>,
    #[serde(default)]
    pub default_model_override: Option<String>,
    #[serde(default)]
    pub default_model_effort: Option<String>,
    #[serde(default)]
    pub default_workspace_id: Option<String>,
    #[serde(default)]
    pub default_config_profile: Option<String>,
    #[serde(default)]
    pub default_agent: Option<String>,
}

// === Standalone Telegram Bot endpoints (auto-create missions per chat) ===

/// Create a standalone Telegram bot configuration (auto-creates missions per chat).
pub async fn create_telegram_bot(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(req): Json<CreateTelegramBotRequest>,
) -> Result<Json<super::super::mission_store::TelegramChannel>, (StatusCode, String)> {
    use super::super::mission_store::{now_string, MissionMode, TelegramChannel};

    let control = control_for_user(&state, &user).await;

    // Reject duplicate bot tokens to avoid webhook conflicts
    let all_channels = control
        .mission_store
        .list_all_telegram_channels()
        .await
        .map_err(internal_error)?;
    if all_channels.iter().any(|c| c.bot_token == req.bot_token) {
        return Err((
            StatusCode::CONFLICT,
            "A bot with this token already exists".to_string(),
        ));
    }

    // Create a placeholder mission so the FK constraint is satisfied.
    // When auto_create_missions is true, individual chat missions are auto-created;
    // this placeholder is only used to anchor the channel row.
    let placeholder_mission = control
        .mission_store
        .create_mission(
            Some("Telegram Bot (auto-create)"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .map_err(internal_error)?;
    // Set placeholder to assistant mode
    let _ = control
        .mission_store
        .update_mission_mode(placeholder_mission.id, MissionMode::Assistant)
        .await;

    let now = now_string();
    let webhook_secret = Uuid::new_v4().to_string().replace('-', "");
    let channel = TelegramChannel {
        id: Uuid::new_v4(),
        mission_id: placeholder_mission.id,
        bot_token: req.bot_token,
        bot_username: req.bot_username,
        allowed_chat_ids: req.allowed_chat_ids.unwrap_or_default(),
        trigger_mode: req.trigger_mode.unwrap_or_default(),
        active: true,
        webhook_secret: Some(webhook_secret),
        instructions: req.instructions,
        auto_create_missions: true,
        default_backend: req.default_backend,
        default_model_override: req.default_model_override,
        default_model_effort: req.default_model_effort,
        default_workspace_id: req.default_workspace_id,
        default_config_profile: req.default_config_profile,
        default_agent: req.default_agent,
        created_at: now.clone(),
        updated_at: now,
    };

    let created = match control.mission_store.create_telegram_channel(channel).await {
        Ok(c) => c,
        Err(e) => {
            // Clean up placeholder mission
            let _ = control
                .mission_store
                .delete_mission(placeholder_mission.id)
                .await;
            return Err(internal_error(e));
        }
    };

    // Register the webhook — roll back channel + placeholder on failure
    let public_url = std::env::var("SANDBOXED_PUBLIC_URL")
        .unwrap_or_else(|_| format!("http://{}:{}", state.config.host, state.config.port));
    if let Err(e) = state
        .telegram_bridge
        .start_channel(
            created.clone(),
            control.cmd_tx.clone(),
            control.events_tx.clone(),
            control.mission_store.clone(),
            &public_url,
        )
        .await
    {
        let _ = control
            .mission_store
            .delete_telegram_channel(created.id)
            .await;
        let _ = control
            .mission_store
            .delete_mission(placeholder_mission.id)
            .await;
        return Err(internal_error(e));
    }

    tracing::info!("Created Telegram bot {} (auto-create missions)", created.id);

    Ok(Json(created))
}

#[derive(Deserialize)]
pub struct CreateTelegramBotRequest {
    pub bot_token: String,
    #[serde(default)]
    pub bot_username: Option<String>,
    #[serde(default)]
    pub allowed_chat_ids: Option<Vec<i64>>,
    #[serde(default)]
    pub trigger_mode: Option<super::super::mission_store::TelegramTriggerMode>,
    #[serde(default)]
    pub instructions: Option<String>,
    #[serde(default)]
    pub default_backend: Option<String>,
    #[serde(default)]
    pub default_model_override: Option<String>,
    #[serde(default)]
    pub default_model_effort: Option<String>,
    #[serde(default)]
    pub default_workspace_id: Option<Uuid>,
    #[serde(default)]
    pub default_config_profile: Option<String>,
    #[serde(default)]
    pub default_agent: Option<String>,
}

/// List all Telegram bot configurations.
pub async fn list_telegram_bots(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<Vec<super::super::mission_store::TelegramChannel>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let channels = control
        .mission_store
        .list_all_telegram_channels()
        .await
        .map_err(internal_error)?;
    Ok(Json(channels))
}

/// List chat-to-mission mappings for a Telegram bot.
pub async fn list_bot_chats(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(channel_id): Path<Uuid>,
) -> Result<Json<Vec<super::super::mission_store::TelegramChatMission>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let mappings = control
        .mission_store
        .list_telegram_chat_missions(channel_id)
        .await
        .map_err(internal_error)?;
    Ok(Json(mappings))
}

#[derive(Debug, Deserialize)]
pub struct TelegramBotListQuery {
    #[serde(default = "default_telegram_limit")]
    pub limit: usize,
    #[serde(default)]
    pub chat_id: Option<i64>,
}

pub(super) fn default_telegram_limit() -> usize {
    20
}

pub async fn list_bot_scheduled_messages(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(channel_id): Path<Uuid>,
    Query(query): Query<TelegramBotListQuery>,
) -> Result<Json<Vec<super::super::mission_store::TelegramScheduledMessage>>, (StatusCode, String)>
{
    let control = control_for_user(&state, &user).await;
    let messages = control
        .mission_store
        .list_telegram_scheduled_messages(channel_id, query.chat_id, query.limit.clamp(1, 100))
        .await
        .map_err(internal_error)?;
    Ok(Json(messages))
}

pub async fn list_bot_action_executions(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(channel_id): Path<Uuid>,
    Query(query): Query<TelegramBotListQuery>,
) -> Result<Json<Vec<super::super::mission_store::TelegramActionExecution>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let executions = control
        .mission_store
        .list_telegram_action_executions(channel_id, query.chat_id, query.limit.clamp(1, 100))
        .await
        .map_err(internal_error)?;
    Ok(Json(executions))
}

pub async fn list_paloma_decisions(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Query(query): Query<TelegramBotListQuery>,
) -> Result<Json<Vec<super::super::mission_store::PalomaDecision>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let decisions = control
        .mission_store
        .list_paloma_decisions(query.limit.clamp(1, 100))
        .await
        .map_err(internal_error)?;
    Ok(Json(decisions))
}

pub async fn list_paloma_scheduler_jobs(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<Vec<super::super::mission_store::PalomaSchedulerJob>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let jobs = control
        .mission_store
        .list_paloma_scheduler_jobs()
        .await
        .map_err(internal_error)?;
    Ok(Json(jobs))
}

pub async fn get_paloma_queue_metrics(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<super::super::paloma::queue::QueueMetrics>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let channels = control
        .mission_store
        .list_all_telegram_channels()
        .await
        .map_err(internal_error)?;
    let channel_ids: HashSet<String> = channels
        .into_iter()
        .map(|channel| channel.id.to_string())
        .collect();
    let metrics = state
        .telegram_bridge
        .paloma_queue_metrics_for_channels(&channel_ids)
        .await;
    Ok(Json(metrics))
}

pub async fn list_bot_conversations(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(channel_id): Path<Uuid>,
    Query(query): Query<TelegramBotListQuery>,
) -> Result<Json<Vec<super::super::mission_store::TelegramConversation>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let conversations = control
        .mission_store
        .list_telegram_conversations(channel_id, query.limit.clamp(1, 100))
        .await
        .map_err(internal_error)?;
    Ok(Json(conversations))
}

pub async fn list_bot_workflows(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(channel_id): Path<Uuid>,
    Query(query): Query<TelegramBotListQuery>,
) -> Result<Json<Vec<super::super::mission_store::TelegramWorkflow>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let workflows = control
        .mission_store
        .list_telegram_workflows(channel_id, query.limit.clamp(1, 100))
        .await
        .map_err(internal_error)?;
    Ok(Json(workflows))
}

pub async fn list_telegram_conversation_messages(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(conversation_id): Path<Uuid>,
    Query(query): Query<TelegramBotListQuery>,
) -> Result<Json<Vec<super::super::mission_store::TelegramConversationMessage>>, (StatusCode, String)>
{
    let control = control_for_user(&state, &user).await;
    let messages = control
        .mission_store
        .list_telegram_conversation_messages(conversation_id, query.limit.clamp(1, 200))
        .await
        .map_err(internal_error)?;
    Ok(Json(messages))
}

pub async fn list_telegram_workflow_events(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(workflow_id): Path<Uuid>,
    Query(query): Query<TelegramBotListQuery>,
) -> Result<Json<Vec<super::super::mission_store::TelegramWorkflowEvent>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let events = control
        .mission_store
        .list_telegram_workflow_events(workflow_id, query.limit.clamp(1, 200))
        .await
        .map_err(internal_error)?;
    Ok(Json(events))
}

#[derive(Debug, Deserialize)]
pub struct TelegramMemoryQuery {
    #[serde(default = "default_telegram_limit")]
    pub limit: usize,
    #[serde(default)]
    pub chat_id: Option<i64>,
    #[serde(default)]
    pub subject_user_id: Option<i64>,
    #[serde(default)]
    pub q: Option<String>,
}

pub async fn list_bot_structured_memory(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(channel_id): Path<Uuid>,
    Query(query): Query<TelegramMemoryQuery>,
) -> Result<
    Json<Vec<super::super::mission_store::TelegramStructuredMemoryEntry>>,
    (StatusCode, String),
> {
    let control = control_for_user(&state, &user).await;
    let limit = query.limit.clamp(1, 100);
    let entries = if let Some(q) = query.q.as_deref().filter(|q| !q.trim().is_empty()) {
        let mut entries = control
            .mission_store
            .search_telegram_structured_memory_hybrid(
                channel_id,
                query.chat_id,
                query.subject_user_id,
                q,
                limit,
            )
            .await
            .map_err(internal_error)?
            .into_iter()
            .map(|hit| hit.entry)
            .collect::<Vec<_>>();
        if let Some(subject_user_id) = query.subject_user_id {
            entries.retain(|entry| entry.subject_user_id == Some(subject_user_id));
        }
        entries
    } else {
        control
            .mission_store
            .list_telegram_structured_memory(
                channel_id,
                query.chat_id,
                query.subject_user_id,
                limit,
            )
            .await
            .map_err(internal_error)?
    };
    Ok(Json(entries))
}

pub async fn search_bot_structured_memory(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(channel_id): Path<Uuid>,
    Query(query): Query<TelegramMemoryQuery>,
) -> Result<
    Json<Vec<super::super::mission_store::TelegramStructuredMemorySearchHit>>,
    (StatusCode, String),
> {
    let control = control_for_user(&state, &user).await;
    let Some(q) = query.q.as_deref().filter(|q| !q.trim().is_empty()) else {
        return Ok(Json(Vec::new()));
    };
    let mut hits = control
        .mission_store
        .search_telegram_structured_memory_hybrid(
            channel_id,
            query.chat_id,
            query.subject_user_id,
            q,
            query.limit.clamp(1, 100),
        )
        .await
        .map_err(internal_error)?;
    if let Some(subject_user_id) = query.subject_user_id {
        hits.retain(|hit| hit.entry.subject_user_id == Some(subject_user_id));
    }
    Ok(Json(hits))
}

/// Send a message to a Telegram chat via the bot and optionally dispatch it to
/// the associated mission. Used by agents (e.g. Paloma) to proactively message users.
#[derive(Debug, Deserialize)]
pub struct SendTelegramMessageRequest {
    /// Telegram chat ID to send to
    pub chat_id: i64,
    /// Message text
    pub text: String,
    /// Bot channel ID (if omitted, uses the first active bot)
    #[serde(default)]
    pub channel_id: Option<Uuid>,
    /// Also dispatch as a user message to the chat's associated mission
    #[serde(default)]
    pub dispatch_to_mission: bool,
}

#[derive(Debug, Deserialize)]
pub struct TelegramActionRequest {
    pub mission_id: Uuid,
    pub text: String,
    #[serde(default)]
    pub delay_seconds: Option<u64>,
    #[serde(default)]
    pub target: Option<super::super::telegram::TelegramActionTarget>,
}

#[derive(Debug, Deserialize)]
pub struct TelegramWorkflowRequest {
    pub mission_id: Uuid,
    pub text: String,
    #[serde(default)]
    pub target: Option<super::super::telegram::TelegramActionTarget>,
}

pub async fn execute_telegram_action_api(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(req): Json<TelegramActionRequest>,
) -> Result<Json<super::super::telegram::TelegramActionExecutionResult>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let result = super::super::telegram::execute_native_telegram_action(
        &state.telegram_bridge,
        &control.mission_store,
        req.mission_id,
        req.target
            .unwrap_or(super::super::telegram::TelegramActionTarget::Current),
        &req.text,
        req.delay_seconds.unwrap_or(0),
    )
    .await
    .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
    Ok(Json(result))
}

pub async fn execute_telegram_workflow_request_api(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(req): Json<TelegramWorkflowRequest>,
) -> Result<Json<super::super::telegram::TelegramWorkflowRequestResult>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let result = super::super::telegram::execute_native_telegram_request_workflow(
        &state.telegram_bridge,
        &control.mission_store,
        req.mission_id,
        req.target
            .unwrap_or(super::super::telegram::TelegramActionTarget::Current),
        &req.text,
    )
    .await
    .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
    Ok(Json(result))
}

pub(super) fn internal_telegram_action_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get("x-sandboxed-mission-token")
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            headers
                .get(axum::http::header::AUTHORIZATION)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.strip_prefix("Bearer "))
                .filter(|value| !value.trim().is_empty())
        })
}

pub(super) async fn mission_store_for_telegram_mission(
    state: &Arc<AppState>,
    mission_id: Uuid,
) -> Option<Arc<dyn MissionStore>> {
    let sessions = state.control.all_sessions().await;
    for session in sessions {
        let has_chat_mapping = session
            .mission_store
            .get_telegram_chat_mission_by_mission_id(mission_id)
            .await
            .ok()
            .flatten()
            .is_some();
        let has_attached_channel = session
            .mission_store
            .list_telegram_channels(mission_id)
            .await
            .map(|channels| !channels.is_empty())
            .unwrap_or(false);
        if has_chat_mapping || has_attached_channel {
            return Some(Arc::clone(&session.mission_store));
        }
    }
    None
}

pub async fn execute_telegram_action_internal_api(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<TelegramActionRequest>,
) -> Result<Json<super::super::telegram::TelegramActionExecutionResult>, (StatusCode, String)> {
    let token = internal_telegram_action_token(&headers).ok_or_else(|| {
        (
            StatusCode::UNAUTHORIZED,
            "Missing mission token".to_string(),
        )
    })?;
    if !super::super::telegram::verify_internal_telegram_action_token(req.mission_id, token) {
        return Err((
            StatusCode::UNAUTHORIZED,
            "Invalid mission token".to_string(),
        ));
    }

    let mission_store = mission_store_for_telegram_mission(&state, req.mission_id)
        .await
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                format!(
                    "Mission {} is not linked to an active Telegram conversation",
                    req.mission_id
                ),
            )
        })?;

    let result = super::super::telegram::execute_native_telegram_action(
        &state.telegram_bridge,
        &mission_store,
        req.mission_id,
        req.target
            .unwrap_or(super::super::telegram::TelegramActionTarget::Current),
        &req.text,
        req.delay_seconds.unwrap_or(0),
    )
    .await
    .map_err(|error| (StatusCode::BAD_REQUEST, error))?;

    Ok(Json(result))
}

pub async fn execute_telegram_workflow_request_internal_api(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<TelegramWorkflowRequest>,
) -> Result<Json<super::super::telegram::TelegramWorkflowRequestResult>, (StatusCode, String)> {
    let token = internal_telegram_action_token(&headers).ok_or_else(|| {
        (
            StatusCode::UNAUTHORIZED,
            "Missing mission token".to_string(),
        )
    })?;
    if !super::super::telegram::verify_internal_telegram_action_token(req.mission_id, token) {
        return Err((
            StatusCode::UNAUTHORIZED,
            "Invalid mission token".to_string(),
        ));
    }

    let mission_store = mission_store_for_telegram_mission(&state, req.mission_id)
        .await
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                format!(
                    "Mission {} is not linked to an active Telegram conversation",
                    req.mission_id
                ),
            )
        })?;

    let result = super::super::telegram::execute_native_telegram_request_workflow(
        &state.telegram_bridge,
        &mission_store,
        req.mission_id,
        req.target
            .unwrap_or(super::super::telegram::TelegramActionTarget::Current),
        &req.text,
    )
    .await
    .map_err(|error| (StatusCode::BAD_REQUEST, error))?;

    Ok(Json(result))
}

pub async fn send_telegram_message_api(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(req): Json<SendTelegramMessageRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    // Resolve which bot to use
    let channel = if let Some(channel_id) = req.channel_id {
        control
            .mission_store
            .get_telegram_channel(channel_id)
            .await
            .map_err(internal_error)?
            .ok_or_else(|| {
                (
                    StatusCode::NOT_FOUND,
                    format!("Telegram channel {} not found", channel_id),
                )
            })?
    } else {
        // Use first active bot
        let channels = control
            .mission_store
            .list_all_telegram_channels()
            .await
            .map_err(internal_error)?;
        channels.into_iter().find(|c| c.active).ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                "No active Telegram bot found".to_string(),
            )
        })?
    };

    // Send the message via Telegram Bot API with HTML rendering and chunking
    let base_url = format!("https://api.telegram.org/bot{}", channel.bot_token);
    let http = reqwest::Client::new();
    let msg_id =
        super::super::telegram::send_telegram_text(&http, &base_url, req.chat_id, &req.text, None)
            .await
            .map_err(|e| (StatusCode::BAD_GATEWAY, e))?;
    let resp_body = serde_json::json!({"ok": true, "message_id": msg_id});

    // Optionally dispatch to the associated mission
    if req.dispatch_to_mission {
        if let Ok(Some(mapping)) = control
            .mission_store
            .get_telegram_chat_mission(channel.id, req.chat_id)
            .await
        {
            let msg_id = Uuid::new_v4();
            let (tx, _rx) = tokio::sync::oneshot::channel();
            let content = format!(
                "[Telegram from @{} in chat {}] {}",
                channel.bot_username.as_deref().unwrap_or("bot"),
                req.chat_id,
                req.text
            );
            let _ = control
                .cmd_tx
                .send(ControlCommand::UserMessage {
                    id: msg_id,
                    content,
                    agent: None,
                    target_mission_id: Some(mapping.mission_id),
                    strict: false,
                    source: Some("telegram".to_string()),
                    respond: tx,
                })
                .await;
        }
    }

    Ok(Json(resp_body))
}

/// Telegram webhook receiver (unauthenticated — verified via secret token header).
pub async fn telegram_webhook_receiver(
    State(state): State<Arc<AppState>>,
    Path(channel_id): Path<Uuid>,
    headers: axum::http::HeaderMap,
    Json(update): Json<super::super::telegram::Update>,
) -> StatusCode {
    // Look up the channel context in the bridge
    let ctx = match state.telegram_bridge.get_channel_context(channel_id).await {
        Some(ctx) => ctx,
        None => {
            tracing::debug!("Telegram webhook for unknown channel {}", channel_id);
            return StatusCode::NOT_FOUND;
        }
    };

    // Verify the secret token if one was set
    if let Some(ref expected_secret) = ctx.channel.webhook_secret {
        let header_secret = headers
            .get("x-telegram-bot-api-secret-token")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        if header_secret != expected_secret {
            tracing::warn!(
                "Telegram webhook secret mismatch for channel {}",
                channel_id
            );
            return StatusCode::FORBIDDEN;
        }
    }

    // Deduplicate using the channel's own SQLite-backed store (survives restarts).
    // Falls back to in-memory dedup if the mission store is unavailable.
    let is_new = match ctx
        .mission_store
        .register_webhook_update(channel_id, update.update_id)
        .await
    {
        Ok(new) => {
            if new {
                // Keep in-memory map in sync so a later SQLite failure
                // doesn't cause duplicate processing.
                state
                    .telegram_bridge
                    .register_update_once(channel_id, update.update_id)
                    .await;
            }
            new
        }
        Err(_) => {
            // Fallback to in-memory dedup if SQLite fails
            state
                .telegram_bridge
                .register_update_once(channel_id, update.update_id)
                .await
        }
    };
    if !is_new {
        tracing::info!(
            channel_id = %channel_id,
            update_id = update.update_id,
            "Ignoring duplicate Telegram webhook update"
        );
        return StatusCode::OK;
    }

    if let Some(ref msg) = update.message {
        let http = state.telegram_bridge.http().clone();
        super::super::telegram::process_webhook_message(&ctx, msg, &http, &state.telegram_bridge)
            .await;
    }

    StatusCode::OK
}
