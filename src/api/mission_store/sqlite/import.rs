//! Mission bundle import.

use super::*;

impl SqliteMissionStore {
    pub(super) async fn import_mission_bundle(
        &self,
        bundle: super::super::MissionBundle,
        options: super::super::MissionImportOptions,
    ) -> Result<Uuid, String> {
        use super::super::MissionBundle;
        // Always mint fresh IDs on import so a bundle can be re-imported
        // into the same instance for debugging without collisions and
        // without clobbering the source history if the bundle round-trips
        // back. Mapping tables below rewrite child rows accordingly.
        let new_mission_id = Uuid::new_v4();
        let target_workspace_id = options
            .target_workspace_id
            .unwrap_or(bundle.mission.workspace_id);
        // Prefer the caller-provided target name; only fall back to the
        // bundle's own name when no override was passed. This keeps the
        // stored workspace_name consistent with the target workspace_id.
        let target_workspace_name = options
            .target_workspace_name
            .clone()
            .or_else(|| bundle.mission.workspace_name.clone());
        let keep_active = options.keep_automations_active;

        // Remap automation IDs: bundle's automation_id -> freshly minted
        // UUID, so imported automations are distinguishable from the
        // originals and don't collide if the source lives on the same
        // database.
        let mut automation_id_map: HashMap<Uuid, Uuid> = HashMap::new();
        for auto in &bundle.automations {
            automation_id_map.insert(auto.id, Uuid::new_v4());
        }

        let MissionBundle {
            mission,
            events,
            automations,
            executions,
            ..
        } = bundle;

        let conn = self.conn.clone();
        let content_dir = self.content_dir.clone();

        tokio::task::spawn_blocking(move || -> Result<Uuid, String> {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction().map_err(|e| e.to_string())?;

            // --- mission row ---
            let mission_mode_str = serde_json::to_value(&mission.mission_mode)
                .ok()
                .and_then(|v| v.as_str().map(|s| s.to_string()))
                .unwrap_or_else(|| "task".to_string());
            // Normalize statuses that imply an attached runtime session.
            // The bundle clears `session_id` (the CLI-level handles don't
            // travel), so `active`/`pending` would leave the record
            // looking running with nothing behind it — it couldn't be
            // continued and couldn't be resumed via the normal path
            // (which only accepts interrupted/failed/blocked). Rewrite to
            // `interrupted` so the user can explicitly resume it.
            use crate::api::control::MissionStatus;
            let normalized_status = match mission.status {
                MissionStatus::Active | MissionStatus::Pending => MissionStatus::Interrupted,
                other => other,
            };
            let status_str = status_to_string(normalized_status);
            let now = Utc::now().to_rfc3339();
            let imported_title = mission
                .title
                .clone()
                .map(|t| format!("{t} (imported)"))
                .or_else(|| Some("Imported mission".to_string()));
            tx.execute(
                "INSERT INTO missions (id, status, title, short_description, metadata_updated_at, metadata_source, metadata_model, metadata_version, workspace_id, workspace_name, agent, model_override, model_effort, backend, config_profile, created_at, updated_at, interrupted_at, resumable, desktop_sessions, session_id, terminal_reason, parent_mission_id, working_directory, mission_mode, goal_mode, goal_objective, fast_mode)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28)",
                rusqlite::params![
                    new_mission_id.to_string(),
                    status_str,
                    imported_title,
                    mission.short_description,
                    mission.metadata_updated_at,
                    mission.metadata_source,
                    mission.metadata_model,
                    mission.metadata_version,
                    target_workspace_id.to_string(),
                    target_workspace_name,
                    mission.agent,
                    mission.model_override,
                    mission.model_effort,
                    mission.backend,
                    mission.config_profile,
                    mission.created_at,
                    now,
                    mission.interrupted_at,
                    if mission.resumable { 1 } else { 0 },
                    serde_json::to_string(&mission.desktop_sessions).ok(),
                    // Blank the session_id: the CLI-level session files
                    // (.claude/.credentials.json, codex threads) don't
                    // travel with the bundle, so resuming would reuse a
                    // stale handle. Let the import side start fresh on
                    // next turn.
                    Option::<String>::None,
                    mission.terminal_reason,
                    // Skip parent_mission_id remapping — parent probably
                    // doesn't exist on the target side.
                    Option::<String>::None,
                    mission.working_directory,
                    mission_mode_str,
                    if mission.goal_mode { 1i64 } else { 0i64 },
                    mission.goal_objective.clone(),
                    if mission.fast_mode { 1i64 } else { 0i64 },
                ],
            )
            .map_err(|e| format!("Failed to insert mission: {e}"))?;

            tx.execute("UPDATE missions SET service_tier = ?1 WHERE id = ?2", rusqlite::params![
                mission.service_tier.map(|tier| tier.id().to_string()), new_mission_id.to_string()
            ]).map_err(|e| e.to_string())?;

            // --- events ---
            // Re-spill large content to the target's content_dir so the
            // existing inline/file split logic stays consistent.
            for event in &events {
                let (content_inline, content_file) = SqliteMissionStore::store_content(
                    &content_dir,
                    new_mission_id,
                    event.sequence,
                    &event.event_type,
                    &event.content,
                );
                let metadata_json =
                    serde_json::to_string(&event.metadata).unwrap_or_else(|_| "{}".to_string());
                tx.execute(
                    "INSERT INTO mission_events
                     (mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                    rusqlite::params![
                        new_mission_id.to_string(),
                        event.sequence,
                        event.event_type,
                        event.timestamp,
                        event.event_id,
                        event.tool_call_id,
                        event.tool_name,
                        content_inline,
                        content_file,
                        metadata_json,
                    ],
                )
                .map_err(|e| format!("Failed to insert event: {e}"))?;
            }
            super::search_index::reconcile_mission_docs(
                &tx,
                &content_dir,
                &new_mission_id.to_string(),
            )?;

            // --- automations ---
            for auto in &automations {
                let new_auto_id = *automation_id_map
                    .get(&auto.id)
                    .expect("remap table built from this list");
                let (command_source_type, command_source_data) = match &auto.command_source {
                    CommandSource::Library { name } => (
                        "library",
                        serde_json::json!({ "name": name }).to_string(),
                    ),
                    CommandSource::LocalFile { path } => (
                        "local_file",
                        serde_json::json!({ "path": path }).to_string(),
                    ),
                    CommandSource::Inline { content } => (
                        "inline",
                        serde_json::json!({ "content": content }).to_string(),
                    ),
                    CommandSource::NativeLoop {
                        harness,
                        command,
                        args,
                    } => (
                        "native_loop",
                        serde_json::json!({
                            "harness": harness,
                            "command": command,
                            "args": args,
                        })
                        .to_string(),
                    ),
                };
                let (trigger_type, trigger_data) = match &auto.trigger {
                    TriggerType::Interval { seconds } => (
                        "interval",
                        serde_json::json!({ "seconds": seconds }).to_string(),
                    ),
                    TriggerType::Cron {
                        expression,
                        timezone,
                    } => (
                        "cron",
                        serde_json::json!({
                            "expression": expression,
                            "timezone": timezone,
                        })
                        .to_string(),
                    ),
                    TriggerType::Webhook { config } => (
                        "webhook",
                        serde_json::to_string(config).unwrap_or_else(|_| "{}".to_string()),
                    ),
                    TriggerType::AgentFinished => ("agent_finished", "{}".to_string()),
                    TriggerType::DurableJobTerminal { job_id } => (
                        "durable_job_terminal",
                        serde_json::json!({ "job_id": job_id }).to_string(),
                    ),
                    TriggerType::Telegram { config } => (
                        "telegram",
                        serde_json::to_string(config).unwrap_or_else(|_| "{}".to_string()),
                    ),
                };
                let variables_json = serde_json::to_string(&auto.variables)
                    .unwrap_or_else(|_| "{}".to_string());
                let stop_policy_str = match &auto.stop_policy {
                    StopPolicy::Never => "never".to_string(),
                    StopPolicy::WhenMissionTerminal => "when_mission_terminal".to_string(),
                    StopPolicy::WhenFailingConsecutively { count } => {
                        format!("consecutive_failures:{}", count)
                    }
                    StopPolicy::WhenAllIssuesClosedAndPRsMerged { repo } => {
                        format!("all_issues_closed_and_prs_merged:{}", repo)
                    }
                    StopPolicy::AfterFirstFire => "after_first_fire".to_string(),
                };
                let fresh_session_str = match auto.fresh_session {
                    FreshSession::Always => "always",
                    FreshSession::Switch => "switch",
                    FreshSession::Keep => "keep",
                };
                let driver_str = match auto.driver {
                    super::super::AutomationDriver::Scheduler => "scheduler",
                    super::super::AutomationDriver::HarnessLoop => "harness_loop",
                };
                tx.execute(
                    "INSERT INTO automations (id, mission_id, command_source_type, command_source_data,
                                             trigger_type, trigger_data, variables, active, stop_policy,
                                             fresh_session, driver, created_at, last_triggered_at, retry_max_retries,
                                             retry_delay_seconds, retry_backoff_multiplier)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    rusqlite::params![
                        new_auto_id.to_string(),
                        new_mission_id.to_string(),
                        command_source_type,
                        command_source_data,
                        trigger_type,
                        trigger_data,
                        variables_json,
                        if keep_active && auto.active { 1 } else { 0 },
                        stop_policy_str,
                        fresh_session_str,
                        driver_str,
                        auto.created_at,
                        // Clear last_triggered_at so interval-based automations
                        // get a full interval on the target before firing.
                        Option::<String>::None,
                        auto.retry_config.max_retries as i64,
                        auto.retry_config.retry_delay_seconds as i64,
                        auto.retry_config.backoff_multiplier,
                    ],
                )
                .map_err(|e| format!("Failed to insert automation: {e}"))?;
            }

            // --- automation_executions ---
            for exec in &executions {
                let Some(new_auto_id) = automation_id_map.get(&exec.automation_id) else {
                    // Execution referenced an automation not in the bundle
                    // (shouldn't happen for bundles produced by export, but
                    // stay defensive).
                    continue;
                };
                let status_str = match exec.status {
                    ExecutionStatus::Pending => "pending",
                    ExecutionStatus::Running => "running",
                    ExecutionStatus::Success => "success",
                    ExecutionStatus::Failed => "failed",
                    ExecutionStatus::Cancelled => "cancelled",
                    ExecutionStatus::Skipped => "skipped",
                };
                let variables_json = serde_json::to_string(&exec.variables_used)
                    .unwrap_or_else(|_| "{}".to_string());
                let webhook_payload = exec
                    .webhook_payload
                    .as_ref()
                    .map(|v| v.to_string());
                tx.execute(
                    "INSERT INTO automation_executions (id, automation_id, mission_id, triggered_at,
                                                        trigger_source, status, webhook_payload,
                                                        variables_used, completed_at, error, retry_count)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    rusqlite::params![
                        Uuid::new_v4().to_string(),
                        new_auto_id.to_string(),
                        new_mission_id.to_string(),
                        exec.triggered_at,
                        exec.trigger_source,
                        status_str,
                        webhook_payload,
                        variables_json,
                        exec.completed_at,
                        exec.error,
                        exec.retry_count as i64,
                    ],
                )
                .map_err(|e| format!("Failed to insert execution: {e}"))?;
            }

            tx.commit().map_err(|e| e.to_string())?;
            Ok(new_mission_id)
        })
        .await
        .map_err(|e| e.to_string())?
    }
}
