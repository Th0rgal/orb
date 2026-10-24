//! Automation scheduler loop and agent-finished routing.

use super::*;

/// Resolve an IANA timezone string to a chrono::FixedOffset at a given UTC instant.
///
/// Falls back to UTC if the timezone is unknown.  We use a simple lookup table for
/// common timezones to avoid pulling in chrono-tz (heavy dependency).  The offset is
/// evaluated at `now_utc` to account for DST — though the lookup table doesn't model
/// DST transitions, the most common use-case (Europe/Paris, America/New_York, etc.)
/// is close enough for a 5-second poll cadence.
/// Map a timezone string to a `chrono_tz::Tz`, handling common abbreviations
/// and IANA names.  Returns `None` for fixed-offset strings like "+02:00".
pub(super) fn resolve_tz(tz: &str) -> Option<chrono_tz::Tz> {
    // Fixed-offset strings ("+02:00", "-05:00") are not IANA timezones.
    if tz.starts_with('+') || tz.starts_with('-') {
        return None;
    }

    // Handle common abbreviations that chrono-tz doesn't know about.
    let canonical = match tz {
        "UTC" | "GMT" => "Etc/UTC",
        "EST" => "America/New_York",
        "CST" => "America/Chicago",
        "MST" => "America/Denver",
        "PST" => "America/Los_Angeles",
        "CET" => "Europe/Paris",
        "JST" => "Asia/Tokyo",
        "AEST" => "Australia/Sydney",
        other => other,
    };

    match canonical.parse::<chrono_tz::Tz>() {
        Ok(timezone) => Some(timezone),
        Err(_) => {
            tracing::warn!(timezone = %tz, "Unknown timezone, rejecting");
            None
        }
    }
}

pub(super) fn resolve_tz_offset(
    tz: &str,
    now_utc: chrono::DateTime<chrono::Utc>,
) -> chrono::FixedOffset {
    // Try to parse as a fixed offset first (e.g. "+02:00", "-05:00").
    if let Ok(fo) = tz.parse::<chrono::FixedOffset>() {
        return fo;
    }

    use chrono::Offset;
    match resolve_tz(tz) {
        Some(timezone) => {
            let local_dt = now_utc.with_timezone(&timezone);
            local_dt.offset().fix()
        }
        None => chrono::FixedOffset::east_opt(0).unwrap(),
    }
}

/// Background task that checks for automations and triggers them at their intervals.
pub(super) async fn automation_scheduler_loop(
    mission_store: Arc<dyn MissionStore>,
    library: SharedLibrary,
    cmd_tx: mpsc::Sender<ControlCommand>,
    workspaces: workspace::SharedWorkspaceStore,
    events_tx: broadcast::Sender<AgentEvent>,
    telegram_bridge: Option<super::super::telegram::SharedTelegramBridge>,
    working_dir: PathBuf,
) {
    use super::super::automation_variables::{substitute_variables, SubstitutionContext};
    use super::super::mission_store::{
        AutomationExecution, CommandSource, ExecutionStatus, TriggerType,
    };

    // Check every 5 seconds for automations that need to run
    let check_interval = std::time::Duration::from_secs(5);

    tracing::info!(
        telegram_bridge_available = telegram_bridge.is_some(),
        "Automation scheduler task started"
    );

    let mut logged_unsupported = false;
    let mut tick_count: u64 = 0;

    loop {
        tokio::time::sleep(check_interval).await;
        tick_count += 1;
        if let Err(error) = continuations::deliver(
            &mission_store,
            &cmd_tx,
            &events_tx,
            telegram_bridge.as_ref(),
        )
        .await
        {
            tracing::error!(%error, "Scheduled continuation delivery failed");
        }

        // Every ~60 seconds (12 ticks × 5s), run housekeeping sweeps.
        if tick_count.is_multiple_of(12) {
            // Timeout stale WaitingExternal workflows (older than 30 minutes).
            match mission_store
                .timeout_stale_telegram_workflows(30 * 60)
                .await
            {
                Ok(n) if n > 0 => {
                    tracing::info!("Timed out {} stale WaitingExternal Telegram workflows", n);
                }
                Err(e) => {
                    tracing::warn!("Failed to timeout stale Telegram workflows: {}", e);
                }
                _ => {}
            }

            // Recover stale 'sending' scheduled messages (stuck >5 min after crash).
            match mission_store
                .recover_stale_sending_scheduled_messages(5 * 60)
                .await
            {
                Ok(n) if n > 0 => {
                    tracing::info!(
                        "Recovered {} stale 'sending' scheduled messages back to 'pending'",
                        n
                    );
                }
                Err(e) => {
                    tracing::warn!("Failed to recover stale sending messages: {}", e);
                }
                _ => {}
            }

            // Clean up old webhook dedup entries (older than 15 minutes).
            match mission_store.cleanup_webhook_dedup(15 * 60).await {
                Ok(n) if n > 0 => {
                    tracing::debug!("Cleaned up {} expired webhook dedup entries", n);
                }
                Err(e) => {
                    tracing::warn!("Failed to cleanup webhook dedup entries: {}", e);
                }
                _ => {}
            }
        }

        let automations = match mission_store.list_active_automations().await {
            Ok(automations) => automations,
            Err(e) => {
                if !logged_unsupported {
                    tracing::warn!("Automation scheduler disabled: {}", e);
                    logged_unsupported = true;
                }
                continue;
            }
        };

        for automation in automations {
            // Only trigger interval-based and cron-based automations.
            // Webhooks are triggered via HTTP, agent_finished via turn completion,
            // Telegram via the Telegram bridge.
            enum ScheduleKind {
                Interval(u64),
                Cron {
                    expression: String,
                    timezone: String,
                },
                DurableJobTerminal(Uuid),
            }

            let mission = match mission_store.get_mission(automation.mission_id).await {
                Ok(Some(mission)) => mission,
                Ok(None) => {
                    tracing::debug!(
                        "Automation {} references missing mission {}",
                        automation.id,
                        automation.mission_id
                    );
                    if is_native_schedule(&automation)
                        && native_schedule_tick(&automation, true)
                            == crate::orb_spec::ScheduleAction::Drop
                    {
                        let _ = mission_store
                            .update_automation_active(automation.id, false)
                            .await;
                    }
                    continue;
                }
                Err(e) => {
                    tracing::warn!(
                        "Failed to load mission {} for automation {}: {}",
                        automation.mission_id,
                        automation.id,
                        e
                    );
                    continue;
                }
            };

            if matches!(automation.trigger, TriggerType::AgentFinished)
                && mission_is_terminal_for_goal_loop(mission.status)
            {
                tracing::info!(
                    "Disabling agent_finished automation {} — host mission {} is {:?}",
                    automation.id,
                    mission.id,
                    mission.status
                );
                let mut updated = automation.clone();
                updated.active = false;
                if let Err(e) = mission_store.update_automation(updated).await {
                    tracing::warn!(
                        "Failed to disable automation {} after host mission ended: {}",
                        automation.id,
                        e
                    );
                }
                continue;
            }

            let consecutive_failures =
                consecutive_failure_count_for_automation(&mission_store, &automation).await;
            let has_fired = if matches!(
                automation.stop_policy,
                mission_store::StopPolicy::AfterFirstFire
            ) {
                automation_has_fired(&mission_store, automation.id).await
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
                tracing::info!(
                    "Disabling automation {} due to stop policy {:?} (mission {} status {:?})",
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

            let schedule = match &automation.trigger {
                TriggerType::Interval { seconds } => ScheduleKind::Interval(*seconds),
                TriggerType::Cron {
                    expression,
                    timezone,
                } => ScheduleKind::Cron {
                    expression: expression.clone(),
                    timezone: timezone.clone(),
                },
                TriggerType::Webhook { .. } => continue,
                TriggerType::AgentFinished => continue,
                TriggerType::Telegram { .. } => continue,
                TriggerType::DurableJobTerminal { job_id } => {
                    ScheduleKind::DurableJobTerminal(*job_id)
                }
            };

            // Check if it's time to trigger based on schedule type.
            let should_trigger = match &schedule {
                ScheduleKind::Interval(interval_seconds) => {
                    if let Some(ref last_triggered) = automation.last_triggered_at {
                        match chrono::DateTime::parse_from_rfc3339(last_triggered) {
                            Ok(last_time) => {
                                let elapsed = chrono::Utc::now()
                                    .signed_duration_since(last_time.with_timezone(&chrono::Utc));
                                elapsed.num_seconds() >= *interval_seconds as i64
                            }
                            Err(_) => true,
                        }
                    } else {
                        true // Never triggered before
                    }
                }
                ScheduleKind::Cron {
                    expression,
                    timezone,
                } => {
                    match croner::Cron::new(expression).parse() {
                        Ok(cron) => {
                            // Determine "now" in the configured timezone.
                            let now_utc = chrono::Utc::now();

                            // If we've never triggered (start_immediately=true sets
                            // last_triggered_at to None), fire right away.
                            let reference = if let Some(ref lt) = automation.last_triggered_at {
                                match chrono::DateTime::parse_from_rfc3339(lt) {
                                    Ok(t) => t.with_timezone(&chrono::Utc),
                                    Err(_) => now_utc - chrono::Duration::seconds(10),
                                }
                            } else {
                                // Never triggered → fire immediately on next tick.
                                // Using a very large lookback ensures the next cron
                                // occurrence after this reference is in the past.
                                now_utc - chrono::Duration::days(366)
                            };

                            // Find the next occurrence after the last trigger.
                            // If that occurrence is <= now, it's time to fire.
                            // Use real timezone (not a FixedOffset snapshot) so DST
                            // transitions are evaluated correctly by croner.
                            if let Some(tz) = resolve_tz(timezone) {
                                let ref_with_tz = reference.with_timezone(&tz);
                                match cron.find_next_occurrence(&ref_with_tz, false) {
                                    Ok(next) => {
                                        let next_utc = next.with_timezone(&chrono::Utc);
                                        next_utc <= now_utc
                                    }
                                    Err(_) => false,
                                }
                            } else {
                                // Fixed-offset timezone string (e.g. "+02:00")
                                let tz_offset = resolve_tz_offset(timezone, now_utc);
                                let ref_with_tz = reference.with_timezone(&tz_offset);
                                match cron.find_next_occurrence(&ref_with_tz, false) {
                                    Ok(next) => {
                                        let next_utc = next.with_timezone(&chrono::Utc);
                                        next_utc <= now_utc
                                    }
                                    Err(_) => false,
                                }
                            }
                        }
                        Err(e) => {
                            tracing::warn!(
                                automation_id = %automation.id,
                                expression = %expression,
                                "Invalid cron expression, skipping: {}", e
                            );
                            false
                        }
                    }
                }
                ScheduleKind::DurableJobTerminal(job_id) => {
                    match super::super::durable_jobs::terminal_for_mission(
                        &working_dir,
                        *job_id,
                        mission.id,
                    )
                    .await
                    {
                        Ok(terminal) => terminal,
                        Err(error) => {
                            tracing::debug!(
                                automation_id = %automation.id,
                                mission_id = %mission.id,
                                durable_job_id = %job_id,
                                %error,
                                "Durable-job automation is not ready"
                            );
                            false
                        }
                    }
                }
            };

            if !should_trigger {
                continue;
            }
            // Agent-created recurring schedules go through the verified step:
            // one fire per due slot, nothing after a cancel or for a gone owner.
            if is_native_schedule(&automation) {
                let ended = native_schedule_owner_ended(&automation, mission.status);
                match native_schedule_tick(&automation, ended) {
                    crate::orb_spec::ScheduleAction::Fire => {}
                    crate::orb_spec::ScheduleAction::Drop => {
                        let _ = mission_store
                            .update_automation_active(automation.id, false)
                            .await;
                        continue;
                    }
                    _ => continue,
                }
            }

            // Check if the mission is currently busy (has a running task or queued messages)
            let is_busy = {
                let (tx, rx) = tokio::sync::oneshot::channel();
                if cmd_tx
                    .send(ControlCommand::ListRunning { respond: tx })
                    .await
                    .is_err()
                {
                    tracing::warn!("Failed to send ListRunning command for automation busy check");
                    continue;
                }
                match rx.await {
                    Ok(running) => running.iter().any(|r| {
                        r.mission_id == mission.id
                            && (r.queue_len > 0
                                || matches!(r.state.as_str(), "running" | "waiting_for_tool"))
                    }),
                    Err(_) => {
                        tracing::warn!(
                            "Failed to receive ListRunning response for automation busy check"
                        );
                        continue;
                    }
                }
            };

            if is_busy {
                tracing::debug!(
                    "Mission {} is busy, skipping automation trigger",
                    mission.id
                );
                continue;
            }

            // Get workspace for reading local files
            let workspace = workspaces.get(mission.workspace_id).await;

            // Fetch the command content based on the command source
            let command_content = match &automation.command_source {
                CommandSource::Library { name } => {
                    if let Some(lib) = library.read().await.as_ref() {
                        match lib.get_command(name).await {
                            Ok(command) => automation_library_command_body(&command.content),
                            Err(e) => {
                                tracing::warn!(
                                    "Failed to fetch command '{}' for automation {}: {}",
                                    name,
                                    automation.id,
                                    e
                                );
                                continue;
                            }
                        }
                    } else {
                        tracing::debug!("Library not initialized, skipping automation trigger");
                        continue;
                    }
                }
                CommandSource::LocalFile { path } => {
                    // Read file from mission workspace
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
                    // Harness-driven loops iterate via the harness CLI itself,
                    // not the OA scheduler. Skip — the native_loop_observer
                    // records executions when the harness emits goal events.
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

            // Apply variable substitution
            let substituted_content = substitute_variables(&command_content, &context);

            // One-shot continuations use the durable outbox. General automations
            // retain their existing execution and notification behavior.
            if automation.variables.contains_key("__wakeup_source") {
                let mutex = continuations::lock(mission.id);
                let _guard = mutex.lock().await;
                if let Err(error) =
                    continuations::stage(&mission_store, &automation, substituted_content).await
                {
                    tracing::error!(automation_id = %automation.id, %error, "Could not persist scheduled continuation");
                }
                continue;
            }

            // Create execution record before execution
            let execution_id = Uuid::new_v4();
            let execution = AutomationExecution {
                id: execution_id,
                automation_id: automation.id,
                mission_id: mission.id,
                triggered_at: mission_store::now_string(),
                trigger_source: match &schedule {
                    ScheduleKind::Interval(_) => "interval",
                    ScheduleKind::Cron { .. } => "cron",
                    ScheduleKind::DurableJobTerminal(_) => "durable_job_terminal",
                }
                .to_string(),
                status: ExecutionStatus::Pending,
                webhook_payload: None,
                variables_used: automation.variables.clone(),
                completed_at: None,
                error: None,
                retry_count: 0,
            };

            let execution = match mission_store.create_automation_execution(execution).await {
                Ok(exec) => exec,
                Err(e) => {
                    tracing::warn!(
                        "Failed to create execution record for automation {}: {}",
                        automation.id,
                        e
                    );
                    continue;
                }
            };

            tracing::info!(
                "Triggering automation {} (execution {}) for mission {}",
                automation.id,
                execution_id,
                mission.id
            );

            // Update execution status to Running
            let mut exec = execution.clone();
            exec.status = ExecutionStatus::Running;
            if let Err(e) = mission_store.update_automation_execution(exec).await {
                tracing::warn!(
                    "Failed to update execution status to running for {}: {}",
                    execution_id,
                    e
                );
            }

            // Send the message to the mission with retry logic
            let mut retry_attempt = 0;
            let max_retries = automation.retry_config.max_retries;
            let base_delay = automation.retry_config.retry_delay_seconds;
            let backoff_multiplier = automation.retry_config.backoff_multiplier;

            loop {
                let message_id = Uuid::new_v4();
                let (respond_tx, _respond_rx) = tokio::sync::oneshot::channel();

                let send_result = cmd_tx
                    .send(ControlCommand::UserMessage {
                        id: message_id,
                        content: substituted_content.clone(),
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
                        let mut exec = execution.clone();
                        exec.retry_count = retry_attempt;
                        if let Err(e) = mission_store.update_automation_execution(exec).await {
                            tracing::warn!(
                                "Failed to update execution retry count for {}: {}",
                                execution_id,
                                e
                            );
                        }

                        // Update last triggered time
                        if let Err(e) = mission_store
                            .update_automation_last_triggered(automation.id)
                            .await
                        {
                            tracing::warn!(
                                "Failed to update automation last triggered time: {}",
                                e
                            );
                        }

                        // Route response to Telegram if this mission has an
                        // associated Telegram chat (proactive messaging).
                        if let Some(ref bridge) = telegram_bridge {
                            let mission_id = mission.id;
                            let store = Arc::clone(&mission_store);
                            let bridge = Arc::clone(bridge);
                            let tg_events_rx = events_tx.subscribe();
                            tokio::spawn(async move {
                                // Look up the Telegram chat for this mission
                                let chat_mapping = store
                                    .get_telegram_chat_mission_by_mission_id(mission_id)
                                    .await;
                                if let Ok(Some(mapping)) = chat_mapping {
                                    // Find the channel context to get the bot token
                                    if let Some(ctx) =
                                        bridge.get_channel_context(mapping.channel_id).await
                                    {
                                        tracing::info!(
                                            "Routing automation response for mission {} to Telegram chat {}",
                                            mission_id,
                                            mapping.chat_id
                                        );
                                        if let Err(e) = super::super::telegram::stream_response(
                                            tg_events_rx,
                                            bridge.http(),
                                            &ctx.channel.bot_token,
                                            mapping.chat_id,
                                            0, // no reply_to for proactive messages
                                            None,
                                            mission_id,
                                            Some(Arc::clone(&bridge)),
                                            Some(mapping.channel_id),
                                            Some(Arc::clone(&store)),
                                        )
                                        .await
                                        {
                                            tracing::warn!(
                                                "Failed to stream automation response to Telegram: {}",
                                                e
                                            );
                                        }
                                    }
                                }
                            });
                        }

                        break;
                    }
                    Err(e) => {
                        if retry_attempt < max_retries {
                            // Calculate exponential backoff delay
                            let delay_seconds =
                                base_delay as f64 * backoff_multiplier.powi(retry_attempt as i32);

                            tracing::warn!(
                                "Failed to send automation message (attempt {}/{}): {}. Retrying in {:.1}s",
                                retry_attempt + 1,
                                max_retries + 1,
                                e,
                                delay_seconds
                            );

                            retry_attempt += 1;

                            // Wait before retry
                            tokio::time::sleep(std::time::Duration::from_secs_f64(delay_seconds))
                                .await;
                        } else {
                            // Max retries exceeded - mark as failed
                            tracing::error!(
                                "Failed to send automation message after {} attempts: {}",
                                max_retries + 1,
                                e
                            );

                            let mut exec = execution.clone();
                            exec.status = ExecutionStatus::Failed;
                            exec.completed_at = Some(mission_store::now_string());
                            exec.error =
                                Some(format!("Failed after {} retries: {}", max_retries + 1, e));
                            exec.retry_count = retry_attempt;

                            if let Err(e) = mission_store.update_automation_execution(exec).await {
                                tracing::warn!(
                                    "Failed to update execution status to failed for {}: {}",
                                    execution_id,
                                    e
                                );
                            }

                            break;
                        }
                    }
                }
            }
        }
    }
}

/// Keep automation library command execution consistent with `/command` usage:
/// frontmatter is metadata and should never be injected into model prompts.
pub(super) fn automation_library_command_body(command_content: &str) -> String {
    let (_frontmatter, body) = crate::library::types::parse_frontmatter(command_content);
    body.trim().to_string()
}

/// Resolve the command content for a single automation, applying variable
/// substitution.  Returns `None` if the command cannot be resolved (e.g.
/// library unavailable, file not found).
pub(super) async fn resolve_automation_command(
    automation: &mission_store::Automation,
    mission_id: Uuid,
    state: &Arc<AppState>,
    store: &Arc<dyn MissionStore>,
) -> Option<String> {
    use super::super::automation_variables::{substitute_variables, SubstitutionContext};
    use super::super::mission_store::CommandSource;

    let mission = store.get_mission(mission_id).await.ok()??;
    let workspace = state.workspaces.get(mission.workspace_id).await;

    let command_content = match &automation.command_source {
        CommandSource::Library { name } => {
            let lib = state.library.read().await;
            let lib = lib.as_ref()?;
            lib.get_command(name)
                .await
                .ok()
                .map(|c| automation_library_command_body(&c.content))?
        }
        CommandSource::LocalFile { path } => {
            let ws = workspace.as_ref()?;
            tokio::fs::read_to_string(ws.path.join(path)).await.ok()?
        }
        CommandSource::Inline { content } => content.clone(),
        CommandSource::NativeLoop { .. } => return None,
    };

    let mut context = SubstitutionContext::new(mission.id);
    if let Some(ref title) = mission.title {
        context = context.with_mission_name(title.clone());
    }
    if let Some(ws) = workspace.as_ref() {
        context = context.with_working_directory(ws.path.to_string_lossy().to_string());
    }
    context = context.with_custom_variables(automation.variables.clone());

    Some(substitute_variables(&command_content, &context))
}

#[derive(Debug, Clone)]
pub(super) struct RoutedAutomationMessage {
    pub(super) content: String,
    pub(super) target_mission_id: Uuid,
}

pub(super) fn enqueue_agent_finished_messages(
    queue: &mut VecDeque<ControlQueueEntry>,
    messages: Vec<RoutedAutomationMessage>,
) {
    for message in messages {
        queue.push_back((
            Uuid::new_v4(),
            message.content,
            None,
            Some(message.target_mission_id),
            Some("automation".to_string()),
        ));
    }
}

/// Backend id for a mission, or `None` if the mission isn't found.
///
/// Used by [`maybe_begin_grok_goal`] / [`post_turn_handle_grok_goal`] to
/// gate the `/goal` loop behavior on backend identity without having to
/// thread the backend id through every queue-dispatch path.
pub(super) async fn lookup_mission_backend(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
) -> Option<String> {
    match mission_store.get_mission(mission_id).await {
        Ok(Some(m)) => Some(m.backend),
        _ => None,
    }
}

fn is_native_schedule(automation: &mission_store::Automation) -> bool {
    automation
        .variables
        .get("__wakeup_source")
        .map(String::as_str)
        == Some(crate::api::mission_runner::ANTIGRAVITY_SCHEDULE_SOURCE)
        && matches!(automation.trigger, mission_store::TriggerType::Cron { .. })
}

/// `orb_schedule_step` tick for an agent-created recurring schedule.
fn native_schedule_tick(
    automation: &mission_store::Automation,
    owner_terminal: bool,
) -> crate::orb_spec::ScheduleAction {
    let reference = automation
        .last_triggered_at
        .as_deref()
        .unwrap_or(&automation.created_at);
    let secs = |at: Option<chrono::DateTime<chrono::Utc>>| {
        at.map_or(u64::MAX, |at| u64::try_from(at.timestamp()).unwrap_or(0))
    };
    let last_fired = secs(
        chrono::DateTime::parse_from_rfc3339(reference)
            .ok()
            .map(|at| at.with_timezone(&chrono::Utc)),
    );
    crate::orb_spec::schedule_tick(crate::orb_spec::ScheduleTickInput {
        cancelled: !automation.active,
        owner_terminal,
        authorized: true,
        busy: false,
        last_fired,
        next_due: secs(super::continuations::next_at(automation)),
        now: secs(Some(chrono::Utc::now())),
    })
}

/// An agent-created schedule outlives neither its TTL nor a finished mission.
/// Acknowledged/AwaitingUser missions keep it: reading a mission is not an end.
fn native_schedule_owner_ended(
    automation: &mission_store::Automation,
    status: MissionStatus,
) -> bool {
    // Rows registered before the TTL existed expire from their creation time.
    let expires_at = automation
        .variables
        .get("__schedule_expires_at")
        .and_then(|at| chrono::DateTime::parse_from_rfc3339(at).ok())
        .or_else(|| {
            chrono::DateTime::parse_from_rfc3339(&automation.created_at)
                .ok()
                .map(|at| {
                    at + chrono::Duration::seconds(
                        crate::api::mission_runner::NATIVE_SCHEDULE_TTL_SECONDS,
                    )
                })
        });
    let expired = expires_at.is_none_or(|at| at <= chrono::Utc::now());
    expired
        || matches!(
            status,
            MissionStatus::Completed | MissionStatus::NotFeasible
        )
}

#[cfg(test)]
mod native_schedule_bounds_tests {
    use super::*;
    use crate::api::mission_store::{CommandSource, TriggerType};

    fn schedule(expires: &str) -> mission_store::Automation {
        mission_store::Automation {
            id: Uuid::new_v4(),
            mission_id: Uuid::new_v4(),
            command_source: CommandSource::Inline {
                content: "status".into(),
            },
            trigger: TriggerType::Cron {
                expression: "*/30 * * * *".into(),
                timezone: "UTC".into(),
            },
            variables: std::collections::HashMap::from([
                (
                    "__wakeup_source".into(),
                    crate::api::mission_runner::ANTIGRAVITY_SCHEDULE_SOURCE.into(),
                ),
                ("__schedule_expires_at".into(), expires.into()),
            ]),
            active: true,
            stop_policy: mission_store::StopPolicy::Never,
            fresh_session: Default::default(),
            created_at: "2026-10-24T10:00:00Z".into(),
            last_triggered_at: None,
            retry_config: Default::default(),
            consecutive_failures: 0,
            driver: mission_store::AutomationDriver::Scheduler,
        }
    }

    #[test]
    fn native_schedule_stops_after_ttl_or_a_finished_mission() {
        let live = schedule("2999-01-01T00:00:00Z");
        assert!(!native_schedule_owner_ended(&live, MissionStatus::Active));
        assert!(!native_schedule_owner_ended(
            &live,
            MissionStatus::Acknowledged
        ));
        assert!(native_schedule_owner_ended(&live, MissionStatus::Completed));
        let mut legacy = schedule("");
        legacy.variables.remove("__schedule_expires_at");
        legacy.created_at = "2026-10-01T00:00:00Z".into();
        assert!(
            native_schedule_owner_ended(&legacy, MissionStatus::Active),
            "TTL counts from creation"
        );
        let expired = schedule("2026-10-01T00:00:00Z");
        assert!(native_schedule_owner_ended(&expired, MissionStatus::Active));
        // A due slot of an ended schedule is dropped, never fired.
        assert_eq!(
            native_schedule_tick(&expired, true),
            crate::orb_spec::ScheduleAction::Drop
        );
        assert_eq!(
            native_schedule_tick(&live, false),
            crate::orb_spec::ScheduleAction::Fire
        );
    }
}
