//! Schema definition and migrations for the SQLite mission store.

use super::*;

pub(super) const SCHEMA: &str = r#"
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS missions (
    id TEXT PRIMARY KEY NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    title TEXT,
    short_description TEXT,
    metadata_updated_at TEXT,
    metadata_source TEXT,
    metadata_model TEXT,
    metadata_version TEXT,
    workspace_id TEXT NOT NULL,
    workspace_name TEXT,
    agent TEXT,
    model_override TEXT,
    model_effort TEXT,
    fast_mode INTEGER NOT NULL DEFAULT 0,
    service_tier TEXT,
    backend TEXT NOT NULL DEFAULT 'opencode',
    config_profile TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    interrupted_at TEXT,
    resumable INTEGER NOT NULL DEFAULT 0,
    desktop_sessions TEXT,
    terminal_reason TEXT,
    first_viewed_at TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    not_before TEXT,
    deadline TEXT,
    deferred_goal TEXT,
    paused_at TEXT,
    project TEXT,
    track TEXT,
    intent TEXT,
    github_pr TEXT,
    tags TEXT,
    desired_state TEXT,
    next_check_at TEXT,
    awaiting_kind TEXT,
    last_status_change_at TEXT,
    origin TEXT,
    origin_session_id TEXT,
    requires_local_disk INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_missions_updated_at ON missions(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_missions_status ON missions(status);
CREATE INDEX IF NOT EXISTS idx_missions_status_updated ON missions(status, updated_at);

CREATE TABLE IF NOT EXISTS mission_native_prompt_attempts (
    mission_id TEXT NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    backend TEXT NOT NULL,
    PRIMARY KEY (mission_id, backend)
);
CREATE TABLE IF NOT EXISTS mission_native_prompt_claims (
    mission_id TEXT NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    backend TEXT NOT NULL,
    claim_id TEXT NOT NULL,
    run_stamp TEXT NOT NULL,
    PRIMARY KEY(mission_id, backend)
);
CREATE TABLE IF NOT EXISTS mission_harness_sessions (
    mission_id TEXT NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    backend TEXT NOT NULL,
    session_id TEXT NOT NULL,
    PRIMARY KEY (mission_id, backend)
);

CREATE TABLE IF NOT EXISTS remote_log_offsets (
    job_id TEXT PRIMARY KEY NOT NULL,
    published_offset INTEGER NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS mission_runs (
    run_id TEXT PRIMARY KEY NOT NULL,
    mission_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    execution_state TEXT NOT NULL,
    owner_actor_id TEXT NOT NULL,
    scope_unit TEXT,
    started_at TEXT NOT NULL,
    heartbeat_at TEXT NOT NULL,
    stopping_at TEXT,
    ended_at TEXT,
    terminal_reason TEXT,
    UNIQUE(mission_id, generation),
    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_mission_runs_one_active
ON mission_runs(mission_id) WHERE execution_state <> 'terminal';
CREATE INDEX IF NOT EXISTS idx_mission_runs_active_heartbeat
ON mission_runs(execution_state, heartbeat_at) WHERE execution_state <> 'terminal';

CREATE TABLE IF NOT EXISTS mission_tool_executions (
    tool_call_id TEXT NOT NULL,
    run_id TEXT NOT NULL,
    tool_kind TEXT NOT NULL,
    state TEXT NOT NULL,
    started_at TEXT NOT NULL,
    heartbeat_at TEXT NOT NULL,
    deadline_at TEXT NOT NULL,
    process_pid INTEGER,
    durable_job_id TEXT,
    completed_at TEXT,
    exit_status INTEGER,
    failure_class TEXT,
    PRIMARY KEY(run_id, tool_call_id),
    FOREIGN KEY (run_id) REFERENCES mission_runs(run_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_mission_tool_executions_active
ON mission_tool_executions(run_id, state)
WHERE state IN ('provisional', 'running');

CREATE TABLE IF NOT EXISTS mission_trees (
    mission_id TEXT PRIMARY KEY NOT NULL,
    tree_json TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS mission_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    mission_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    event_id TEXT,
    tool_call_id TEXT,
    tool_name TEXT,
    content TEXT,
    content_file TEXT,
    metadata TEXT,
    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_events_mission ON mission_events(mission_id, sequence);
CREATE INDEX IF NOT EXISTS idx_events_type ON mission_events(mission_id, event_type);
CREATE INDEX IF NOT EXISTS idx_events_mission_type_sequence ON mission_events(mission_id, event_type, sequence);
CREATE INDEX IF NOT EXISTS idx_events_tool_call ON mission_events(tool_call_id) WHERE tool_call_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_events_event_type ON mission_events(event_type);
-- Stale-mission detection takes MAX(timestamp) per mission. Sequence ordering
-- doesn't help here because in-place updates (e.g. text_delta_latest rewriting
-- an existing event_id row) bump `timestamp` without changing `sequence`.
CREATE INDEX IF NOT EXISTS idx_events_mission_timestamp ON mission_events(mission_id, timestamp DESC);

CREATE TABLE IF NOT EXISTS mission_summaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    mission_id TEXT NOT NULL,
    summary TEXT NOT NULL,
    key_files TEXT,
    success INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_summaries_mission ON mission_summaries(mission_id);

CREATE TABLE IF NOT EXISTS automations (
    id TEXT PRIMARY KEY NOT NULL,
    mission_id TEXT NOT NULL,
    command_source_type TEXT NOT NULL,
    command_source_data TEXT NOT NULL,
    trigger_type TEXT NOT NULL,
    trigger_data TEXT NOT NULL,
    variables TEXT NOT NULL DEFAULT '{}',
    active INTEGER NOT NULL DEFAULT 1,
    stop_policy TEXT NOT NULL DEFAULT 'consecutive_failures:2',
    fresh_session TEXT NOT NULL DEFAULT 'keep',
    driver TEXT NOT NULL DEFAULT 'scheduler',
    created_at TEXT NOT NULL,
    last_triggered_at TEXT,
    retry_max_retries INTEGER NOT NULL DEFAULT 3,
    retry_delay_seconds INTEGER NOT NULL DEFAULT 60,
    retry_backoff_multiplier REAL NOT NULL DEFAULT 2.0,
    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_automations_mission ON automations(mission_id);
CREATE INDEX IF NOT EXISTS idx_automations_active ON automations(mission_id, active);

CREATE TABLE IF NOT EXISTS mission_wakeup_fences (
    mission_id TEXT PRIMARY KEY NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    stopped_generation INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS automation_executions (
    id TEXT PRIMARY KEY NOT NULL,
    automation_id TEXT NOT NULL,
    mission_id TEXT NOT NULL,
    triggered_at TEXT NOT NULL,
    trigger_source TEXT NOT NULL,
    status TEXT NOT NULL,
    webhook_payload TEXT,
    variables_used TEXT NOT NULL DEFAULT '{}',
    completed_at TEXT,
    error TEXT,
    retry_count INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (automation_id) REFERENCES automations(id) ON DELETE CASCADE,
    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_executions_automation ON automation_executions(automation_id, triggered_at DESC);
CREATE INDEX IF NOT EXISTS idx_executions_mission ON automation_executions(mission_id, triggered_at DESC);
CREATE INDEX IF NOT EXISTS idx_executions_status ON automation_executions(status);

-- Telegram channels (communication bridges between Telegram and missions)
CREATE TABLE IF NOT EXISTS telegram_channels (
    id TEXT PRIMARY KEY NOT NULL,
    mission_id TEXT NOT NULL,
    bot_token TEXT NOT NULL,
    bot_username TEXT,
    allowed_chat_ids TEXT NOT NULL DEFAULT '[]',
    trigger_mode TEXT NOT NULL DEFAULT 'direct_message',
    active INTEGER NOT NULL DEFAULT 1,
    webhook_secret TEXT,
    instructions TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    auto_create_missions INTEGER NOT NULL DEFAULT 0,
    default_backend TEXT,
    default_model_override TEXT,
    default_model_effort TEXT,
    default_workspace_id TEXT,
    default_config_profile TEXT,
    default_agent TEXT,
    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_telegram_channels_mission ON telegram_channels(mission_id);
CREATE INDEX IF NOT EXISTS idx_telegram_channels_active ON telegram_channels(active);
CREATE UNIQUE INDEX IF NOT EXISTS idx_telegram_channels_bot_token ON telegram_channels(bot_token);

-- Token usage from the OpenAI-compatible /v1 router (external clients:
-- assistant gateways, IDEs with proxy keys, ...). Mission usage lives in
-- mission_events metadata; both sources are merged by the usage summary.
CREATE TABLE IF NOT EXISTS proxy_usage (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    model TEXT NOT NULL,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens INTEGER NOT NULL DEFAULT 0,
    cost_cents INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_proxy_usage_timestamp ON proxy_usage(timestamp);
CREATE INDEX IF NOT EXISTS idx_proxy_usage_model ON proxy_usage(model);

-- Task board: server-scheduled worker tasks owned by a boss mission.
-- The control loop spawns workers for ready tasks and settles them when the
-- worker turn ends; the boss only plans and judges. See api::control::board.
CREATE TABLE IF NOT EXISTS board_tasks (
    id TEXT PRIMARY KEY,
    boss_mission_id TEXT NOT NULL,
    task_key TEXT NOT NULL,
    title TEXT NOT NULL,
    prompt TEXT NOT NULL,
    backend TEXT NOT NULL,
    model_override TEXT,
    model_effort TEXT,
    working_directory TEXT,
    repository TEXT,
    branch TEXT,
    role TEXT NOT NULL DEFAULT 'worker',
    acceptance_criteria TEXT NOT NULL DEFAULT '[]',
    verification_command TEXT,
    design_domain TEXT,
    declared_write_set TEXT NOT NULL DEFAULT '[]',
    risk_class TEXT NOT NULL DEFAULT 'normal',
    token_budget INTEGER,
    cost_budget_cents INTEGER,
    depends_on TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'pending',
    outcome TEXT,
    worker_mission_id TEXT,
    prior_worker_mission_id TEXT,
    prior_outcome TEXT,
    prior_result_digest TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    result_digest TEXT,
    notes TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(boss_mission_id, task_key),
    FOREIGN KEY (boss_mission_id) REFERENCES missions(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_board_tasks_boss ON board_tasks(boss_mission_id);
CREATE INDEX IF NOT EXISTS idx_board_tasks_worker ON board_tasks(worker_mission_id);
CREATE INDEX IF NOT EXISTS idx_board_tasks_status ON board_tasks(status);

CREATE TABLE IF NOT EXISTS task_attempts (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    attempt_number INTEGER NOT NULL,
    mission_id TEXT NOT NULL,
    backend TEXT NOT NULL,
    model TEXT,
    role TEXT NOT NULL,
    run_id TEXT,
    commit_sha TEXT,
    changed_files TEXT NOT NULL DEFAULT '[]',
    verification_evidence TEXT NOT NULL DEFAULT '{}',
    cost_cents INTEGER,
    terminal_class TEXT,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    UNIQUE(task_id, attempt_number),
    FOREIGN KEY (task_id) REFERENCES board_tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_task_attempts_task ON task_attempts(task_id, attempt_number);

CREATE TABLE IF NOT EXISTS board_outbox (
    id TEXT PRIMARY KEY,
    boss_mission_id TEXT NOT NULL,
    task_id TEXT,
    delivery_kind TEXT NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE,
    payload TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    acknowledged_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_board_outbox_pending ON board_outbox(state, created_at);

-- Persisted control-session message queue (JSON snapshot) so pending queued
-- messages survive a restart. Single row (the DB is already per-user).
CREATE TABLE IF NOT EXISTS control_queue (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    payload TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
"#;
impl SqliteMissionStore {
    /// Run database migrations for existing databases.
    /// CREATE TABLE IF NOT EXISTS doesn't add columns to existing tables,
    /// so we need to handle schema changes manually.
    pub(super) fn run_migrations(conn: &Connection) -> Result<(), String> {
        for (column, ty) in [
            ("repository", "TEXT"),
            ("branch", "TEXT"),
            ("prior_worker_mission_id", "TEXT"),
            ("prior_outcome", "TEXT"),
            ("prior_result_digest", "TEXT"),
            ("role", "TEXT NOT NULL DEFAULT 'worker'"),
            ("acceptance_criteria", "TEXT NOT NULL DEFAULT '[]'"),
            ("verification_command", "TEXT"),
            ("design_domain", "TEXT"),
            ("declared_write_set", "TEXT NOT NULL DEFAULT '[]'"),
            ("risk_class", "TEXT NOT NULL DEFAULT 'normal'"),
            ("token_budget", "INTEGER"),
            ("cost_budget_cents", "INTEGER"),
        ] {
            let exists = conn
                .prepare(&format!(
                    "SELECT 1 FROM pragma_table_info('board_tasks') WHERE name = '{column}'"
                ))
                .map_err(|e| format!("Failed to check board_tasks.{column}: {e}"))?
                .exists([])
                .map_err(|e| format!("Failed to query board_tasks schema: {e}"))?;
            if !exists {
                tracing::info!(column, "Running migration: adding board task column");
                match conn.execute(
                    &format!("ALTER TABLE board_tasks ADD COLUMN {column} {ty}"),
                    [],
                ) {
                    Ok(_) => {}
                    Err(error) if error.to_string().contains("duplicate column") => {
                        tracing::debug!(
                            column,
                            "board task column already exists after concurrent migration"
                        );
                    }
                    Err(error) => {
                        return Err(format!("Failed to add board_tasks.{column}: {error}"));
                    }
                }
            }
        }

        // board_projects never got wired up (the `projects` table in
        // projects.db is the authoritative project object); every deployment
        // audited at zero rows, so drop it outright.
        conn.execute("DROP TABLE IF EXISTS board_projects", [])
            .map_err(|e| format!("Failed to drop board_projects: {e}"))?;

        fn add_column_if_missing(
            conn: &Connection,
            table: &str,
            column: &str,
            ddl_type: &str,
        ) -> Result<(), String> {
            let exists: bool = conn
                .prepare(&format!(
                    "SELECT 1 FROM pragma_table_info('{table}') WHERE name = ?1"
                ))
                .map_err(|e| format!("Failed to check for {table}.{column} column: {e}"))?
                .exists(params![column])
                .map_err(|e| format!("Failed to query {table} table info: {e}"))?;
            if !exists {
                tracing::info!("Running migration: adding '{column}' column to {table} table");
                match conn.execute(
                    &format!("ALTER TABLE {table} ADD COLUMN {column} {ddl_type}"),
                    [],
                ) {
                    Ok(_) => {}
                    Err(e) if e.to_string().contains("duplicate column") => {
                        tracing::warn!(
                            "Adding '{column}' column to {table} skipped (already present or concurrent migration): {e}"
                        );
                    }
                    Err(e) => return Err(format!("Failed to add {table}.{column} column: {e}")),
                }
            }
            Ok(())
        }

        add_column_if_missing(
            conn,
            "missions",
            "backend",
            "TEXT NOT NULL DEFAULT 'opencode'",
        )?;
        add_column_if_missing(conn, "missions", "session_id", "TEXT")?;

        // Add performance indexes if they don't exist (idempotent)
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_missions_status_updated ON missions(status, updated_at);
             CREATE INDEX IF NOT EXISTS idx_events_mission_type_sequence ON mission_events(mission_id, event_type, sequence);
             CREATE INDEX IF NOT EXISTS idx_events_event_type ON mission_events(event_type);
             CREATE INDEX IF NOT EXISTS idx_events_mission_timestamp ON mission_events(mission_id, timestamp DESC);",
        )
        .map_err(|e| format!("Failed to create performance indexes: {}", e))?;

        for (column, ddl_type) in [
            ("terminal_reason", "TEXT"),
            ("config_profile", "TEXT"),
            ("model_effort", "TEXT"),
            ("service_tier", "TEXT"),
            ("fast_mode", "INTEGER NOT NULL DEFAULT 0"),
            ("short_description", "TEXT"),
            ("metadata_updated_at", "TEXT"),
            ("metadata_source", "TEXT"),
            ("metadata_model", "TEXT"),
            ("metadata_version", "TEXT"),
            ("parent_mission_id", "TEXT"),
            ("working_directory", "TEXT"),
            ("mission_mode", "TEXT NOT NULL DEFAULT 'task'"),
        ] {
            add_column_if_missing(conn, "missions", column, ddl_type)?;
        }
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_missions_parent ON missions(parent_mission_id)",
            [],
        )
        .map_err(|e| format!("Failed to create parent_mission_id index: {}", e))?;

        // Ensure telegram_channels table exists (for existing databases)
        let has_telegram_channels: bool = conn
            .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='telegram_channels'")
            .map_err(|e| format!("Failed to check for telegram_channels table: {}", e))?
            .exists([])
            .map_err(|e| format!("Failed to query sqlite_master: {}", e))?;

        if !has_telegram_channels {
            tracing::info!("Running migration: creating 'telegram_channels' table");
            conn.execute_batch(
                "CREATE TABLE IF NOT EXISTS telegram_channels (
                    id TEXT PRIMARY KEY NOT NULL,
                    mission_id TEXT NOT NULL,
                    bot_token TEXT NOT NULL,
                    bot_username TEXT,
                    allowed_chat_ids TEXT NOT NULL DEFAULT '[]',
                    trigger_mode TEXT NOT NULL DEFAULT 'mention_or_dm',
                    active INTEGER NOT NULL DEFAULT 1,
                    webhook_secret TEXT,
                    instructions TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    auto_create_missions INTEGER NOT NULL DEFAULT 0,
                    default_backend TEXT,
                    default_model_override TEXT,
                    default_model_effort TEXT,
                    default_workspace_id TEXT,
                    default_config_profile TEXT,
                    default_agent TEXT,
                    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_telegram_channels_mission ON telegram_channels(mission_id);
                CREATE INDEX IF NOT EXISTS idx_telegram_channels_active ON telegram_channels(active);
                CREATE UNIQUE INDEX IF NOT EXISTS idx_telegram_channels_bot_token ON telegram_channels(bot_token);",
            )
            .map_err(|e| format!("Failed to create telegram_channels table: {}", e))?;
        } else {
            for (col_name, col_type) in [
                ("webhook_secret", "TEXT"),
                ("instructions", "TEXT"),
                ("auto_create_missions", "INTEGER NOT NULL DEFAULT 0"),
                ("default_backend", "TEXT"),
                ("default_model_override", "TEXT"),
                ("default_model_effort", "TEXT"),
                ("default_workspace_id", "TEXT"),
                ("default_config_profile", "TEXT"),
                ("default_agent", "TEXT"),
            ] {
                add_column_if_missing(conn, "telegram_channels", col_name, col_type)?;
            }
        }

        if let Err(e) = conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_telegram_channels_bot_token ON telegram_channels(bot_token)",
            [],
        ) {
            tracing::warn!(
                "Failed to enforce unique Telegram bot tokens at the database layer: {}",
                e
            );
        }

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS telegram_users (
                id TEXT PRIMARY KEY NOT NULL,
                telegram_user_id INTEGER NOT NULL UNIQUE,
                username TEXT,
                display_name TEXT,
                role TEXT NOT NULL DEFAULT 'observer',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_tusers_role
                ON telegram_users(role);

            CREATE TABLE IF NOT EXISTS telegram_user_cursors (
                id TEXT PRIMARY KEY NOT NULL,
                telegram_user_id INTEGER NOT NULL UNIQUE,
                last_status_at TEXT,
                last_dashboard_seen_at TEXT,
                last_alert_ack_at TEXT,
                last_digest_at TEXT,
                last_seen_event_sequence_by_mission_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS telegram_mission_subscriptions (
                id TEXT PRIMARY KEY NOT NULL,
                telegram_user_id INTEGER NOT NULL,
                mission_id TEXT NOT NULL,
                interest_level TEXT NOT NULL DEFAULT 'normal',
                reason TEXT,
                expires_at TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(telegram_user_id, mission_id),
                FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_tsub_user_interest
                ON telegram_mission_subscriptions(telegram_user_id, interest_level);
            CREATE INDEX IF NOT EXISTS idx_tsub_mission
                ON telegram_mission_subscriptions(mission_id);

            CREATE TABLE IF NOT EXISTS telegram_alert_preferences (
                id TEXT PRIMARY KEY NOT NULL,
                telegram_user_id INTEGER NOT NULL,
                scope TEXT NOT NULL,
                scope_value TEXT,
                rule_text TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_from_message_id INTEGER,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_talert_pref_user_scope
                ON telegram_alert_preferences(telegram_user_id, scope, scope_value);

            CREATE TABLE IF NOT EXISTS telegram_alerts (
                id TEXT PRIMARY KEY NOT NULL,
                telegram_user_id INTEGER NOT NULL,
                mission_id TEXT,
                event_kind TEXT NOT NULL,
                importance TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                telegram_message_id INTEGER,
                last_error TEXT,
                created_at TEXT NOT NULL,
                sent_at TEXT,
                acknowledged_at TEXT,
                UNIQUE(telegram_user_id, mission_id, event_kind)
            );
            CREATE INDEX IF NOT EXISTS idx_talerts_user_status
                ON telegram_alerts(telegram_user_id, status, created_at);

            CREATE TABLE IF NOT EXISTS paloma_decisions (
                id TEXT PRIMARY KEY NOT NULL,
                event_source TEXT NOT NULL,
                mission_id TEXT,
                user_id INTEGER,
                channel TEXT NOT NULL,
                reason_code TEXT NOT NULL,
                proposed_action TEXT NOT NULL,
                allowed INTEGER NOT NULL,
                suppression_reason TEXT,
                policy_snapshot_json TEXT NOT NULL,
                generated_text_hash TEXT,
                generated_text_preview TEXT,
                created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_paloma_decisions_created
                ON paloma_decisions(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_paloma_decisions_mission
                ON paloma_decisions(mission_id, created_at DESC);

            CREATE TABLE IF NOT EXISTS paloma_scheduler_jobs (
                name TEXT PRIMARY KEY NOT NULL,
                lease_owner TEXT,
                lease_expires_at TEXT,
                last_started_at TEXT,
                last_finished_at TEXT,
                last_error TEXT,
                run_count INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS paloma_mission_cards (
                mission_id TEXT PRIMARY KEY NOT NULL,
                telegram_user_id INTEGER NOT NULL,
                channel_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                message_id INTEGER NOT NULL,
                content_hash TEXT NOT NULL,
                anchor_ts TEXT NOT NULL,
                last_edit_ts TEXT NOT NULL,
                version INTEGER NOT NULL DEFAULT 1,
                archived INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_paloma_mc_user
                ON paloma_mission_cards(telegram_user_id, archived);

            CREATE TABLE IF NOT EXISTS paloma_cooldown_state (
                mission_id TEXT NOT NULL,
                alert_class TEXT NOT NULL,
                telegram_user_id INTEGER NOT NULL,
                last_sent_at TEXT NOT NULL,
                next_eligible_at TEXT NOT NULL,
                backoff_step INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (mission_id, alert_class, telegram_user_id),
                FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_paloma_cd_user_eligibility
                ON paloma_cooldown_state(telegram_user_id, next_eligible_at);

            CREATE TABLE IF NOT EXISTS paloma_user_preferences (
                telegram_user_id INTEGER PRIMARY KEY NOT NULL,
                timezone TEXT NOT NULL DEFAULT 'UTC',
                quiet_hours_start INTEGER,
                quiet_hours_end INTEGER,
                max_interrupts_per_hour INTEGER NOT NULL DEFAULT 1,
                max_interrupts_per_day INTEGER NOT NULL DEFAULT 4,
                failure_override_quiet INTEGER NOT NULL DEFAULT 1,
                alert_class_overrides_json TEXT NOT NULL DEFAULT '{}',
                mission_overrides_json TEXT NOT NULL DEFAULT '{}',
                digest_cadence TEXT NOT NULL DEFAULT 'daily',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );",
        )
        .map_err(|e| format!("Failed to create Paloma Telegram state tables: {}", e))?;

        // Create telegram_chat_missions table if it doesn't exist
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS telegram_chat_missions (
                id TEXT PRIMARY KEY NOT NULL,
                channel_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                mission_id TEXT NOT NULL,
                chat_title TEXT,
                created_at TEXT NOT NULL,
                FOREIGN KEY (channel_id) REFERENCES telegram_channels(id) ON DELETE CASCADE,
                FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_tcm_channel_chat ON telegram_chat_missions(channel_id, chat_id);
            CREATE INDEX IF NOT EXISTS idx_tcm_mission ON telegram_chat_missions(mission_id);",
        )
        .map_err(|e| format!("Failed to create telegram_chat_missions table: {}", e))?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS telegram_scheduled_messages (
                id TEXT PRIMARY KEY NOT NULL,
                channel_id TEXT NOT NULL,
                source_mission_id TEXT,
                chat_id INTEGER NOT NULL,
                chat_title TEXT,
                text TEXT NOT NULL,
                send_at TEXT NOT NULL,
                sent_at TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                last_error TEXT,
                created_at TEXT NOT NULL,
                FOREIGN KEY (channel_id) REFERENCES telegram_channels(id) ON DELETE CASCADE,
                FOREIGN KEY (source_mission_id) REFERENCES missions(id) ON DELETE SET NULL
            );
            CREATE INDEX IF NOT EXISTS idx_tsm_due
                ON telegram_scheduled_messages(status, send_at);
            CREATE INDEX IF NOT EXISTS idx_tsm_channel
                ON telegram_scheduled_messages(channel_id, status, send_at);
            CREATE INDEX IF NOT EXISTS idx_telegram_scheduled_messages_mission
                ON telegram_scheduled_messages(source_mission_id);",
        )
        .map_err(|e| format!("Failed to create telegram_scheduled_messages table: {}", e))?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS telegram_structured_memory (
                id TEXT PRIMARY KEY NOT NULL,
                channel_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                mission_id TEXT,
                scope TEXT NOT NULL DEFAULT 'chat',
                kind TEXT NOT NULL,
                label TEXT,
                normalized_label TEXT,
                value TEXT NOT NULL,
                subject_user_id INTEGER,
                subject_username TEXT,
                subject_display_name TEXT,
                source_message_id INTEGER,
                source_role TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (channel_id) REFERENCES telegram_channels(id) ON DELETE CASCADE,
                FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE SET NULL
            );
            CREATE INDEX IF NOT EXISTS idx_tmem_channel_search
                ON telegram_structured_memory(channel_id, normalized_label, updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_telegram_structured_memory_mission
                ON telegram_structured_memory(mission_id);",
        )
        .map_err(|e| format!("Failed to create telegram_structured_memory table: {}", e))?;

        let telegram_memory_cols = [
            ("scope", "TEXT NOT NULL DEFAULT 'chat'"),
            ("subject_user_id", "INTEGER"),
            ("subject_username", "TEXT"),
            ("subject_display_name", "TEXT"),
        ];
        for (col_name, col_type) in &telegram_memory_cols {
            let has_col: bool = conn
                .prepare(&format!(
                    "SELECT 1 FROM pragma_table_info('telegram_structured_memory') WHERE name='{}'",
                    col_name
                ))
                .map_err(|e| format!("Failed to check for {} column: {}", col_name, e))?
                .exists([])
                .map_err(|e| format!("Failed to query pragma_table_info: {}", e))?;
            if !has_col {
                tracing::info!(
                    "Running migration: adding '{}' column to telegram_structured_memory",
                    col_name
                );
                match conn.execute(
                    &format!(
                        "ALTER TABLE telegram_structured_memory ADD COLUMN {} {}",
                        col_name, col_type
                    ),
                    [],
                ) {
                    Ok(_) => {}
                    Err(e) if e.to_string().contains("duplicate column") => {}
                    Err(e) => return Err(format!("Failed to add {} column: {}", col_name, e)),
                }
            }
        }

        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_tmem_channel_chat_updated
                ON telegram_structured_memory(channel_id, scope, chat_id, updated_at DESC);
             CREATE INDEX IF NOT EXISTS idx_tmem_channel_user_updated
                ON telegram_structured_memory(channel_id, scope, subject_user_id, updated_at DESC);",
        )
        .map_err(|e| format!("Failed to create telegram_structured_memory indexes: {}", e))?;

        Self::ensure_telegram_memory_search_index(conn)?;
        let memory_row_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM telegram_structured_memory",
                [],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to count telegram structured memory rows: {}", e))?;
        if memory_row_count > 0 {
            let search_row_count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM telegram_structured_memory_fts",
                    [],
                    |row| row.get(0),
                )
                .map_err(|e| format!("Failed to count telegram memory search rows: {}", e))?;
            if search_row_count == 0 {
                Self::rebuild_telegram_memory_search_index(conn)?;
            }
        }

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS telegram_action_executions (
                id TEXT PRIMARY KEY NOT NULL,
                channel_id TEXT NOT NULL,
                source_mission_id TEXT,
                source_chat_id INTEGER,
                target_chat_id INTEGER NOT NULL,
                target_chat_title TEXT,
                action_kind TEXT NOT NULL,
                target_kind TEXT NOT NULL,
                target_value TEXT NOT NULL,
                text TEXT NOT NULL,
                delay_seconds INTEGER NOT NULL DEFAULT 0,
                scheduled_message_id TEXT,
                status TEXT NOT NULL,
                last_error TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (channel_id) REFERENCES telegram_channels(id) ON DELETE CASCADE,
                FOREIGN KEY (source_mission_id) REFERENCES missions(id) ON DELETE SET NULL,
                FOREIGN KEY (scheduled_message_id) REFERENCES telegram_scheduled_messages(id) ON DELETE SET NULL
            );
            CREATE INDEX IF NOT EXISTS idx_tae_channel_updated
                ON telegram_action_executions(channel_id, updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_tae_scheduled
                ON telegram_action_executions(scheduled_message_id);
            CREATE INDEX IF NOT EXISTS idx_telegram_action_executions_mission
                ON telegram_action_executions(source_mission_id);",
        )
        .map_err(|e| format!("Failed to create telegram_action_executions table: {}", e))?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS telegram_conversations (
                id TEXT PRIMARY KEY NOT NULL,
                channel_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                mission_id TEXT,
                chat_title TEXT,
                chat_type TEXT,
                last_message_at TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (channel_id) REFERENCES telegram_channels(id) ON DELETE CASCADE,
                FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE SET NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_tconv_channel_chat
                ON telegram_conversations(channel_id, chat_id);
            CREATE INDEX IF NOT EXISTS idx_tconv_channel_updated
                ON telegram_conversations(channel_id, updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_telegram_conversations_mission
                ON telegram_conversations(mission_id);",
        )
        .map_err(|e| format!("Failed to create telegram_conversations table: {}", e))?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS telegram_conversation_messages (
                id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL,
                channel_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                mission_id TEXT,
                workflow_id TEXT,
                telegram_message_id INTEGER,
                direction TEXT NOT NULL,
                role TEXT NOT NULL,
                sender_user_id INTEGER,
                sender_username TEXT,
                sender_display_name TEXT,
                reply_to_message_id INTEGER,
                text TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (conversation_id) REFERENCES telegram_conversations(id) ON DELETE CASCADE,
                FOREIGN KEY (channel_id) REFERENCES telegram_channels(id) ON DELETE CASCADE,
                FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE SET NULL
            );
            CREATE INDEX IF NOT EXISTS idx_tconv_msg_conversation_created
                ON telegram_conversation_messages(conversation_id, created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_tconv_msg_chat_created
                ON telegram_conversation_messages(channel_id, chat_id, created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_telegram_conversation_messages_mission
                ON telegram_conversation_messages(mission_id);",
        )
        .map_err(|e| format!("Failed to create telegram_conversation_messages table: {}", e))?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS telegram_workflows (
                id TEXT PRIMARY KEY NOT NULL,
                channel_id TEXT NOT NULL,
                origin_conversation_id TEXT NOT NULL,
                origin_chat_id INTEGER NOT NULL,
                origin_mission_id TEXT,
                target_conversation_id TEXT,
                target_chat_id INTEGER,
                target_chat_title TEXT,
                target_chat_type TEXT,
                target_request_message_id INTEGER,
                initiated_by_user_id INTEGER,
                initiated_by_username TEXT,
                kind TEXT NOT NULL,
                status TEXT NOT NULL,
                request_text TEXT NOT NULL,
                latest_reply_text TEXT,
                summary TEXT,
                last_error TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                completed_at TEXT,
                FOREIGN KEY (channel_id) REFERENCES telegram_channels(id) ON DELETE CASCADE,
                FOREIGN KEY (origin_conversation_id) REFERENCES telegram_conversations(id) ON DELETE CASCADE,
                FOREIGN KEY (target_conversation_id) REFERENCES telegram_conversations(id) ON DELETE SET NULL,
                FOREIGN KEY (origin_mission_id) REFERENCES missions(id) ON DELETE SET NULL
            );
            CREATE INDEX IF NOT EXISTS idx_twf_channel_updated
                ON telegram_workflows(channel_id, updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_twf_target_status
                ON telegram_workflows(channel_id, target_chat_id, status, updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_telegram_workflows_origin_mission
                ON telegram_workflows(origin_mission_id);
            CREATE INDEX IF NOT EXISTS idx_telegram_workflows_origin_conv
                ON telegram_workflows(origin_conversation_id);
            CREATE INDEX IF NOT EXISTS idx_telegram_workflows_target_conv
                ON telegram_workflows(target_conversation_id);",
        )
        .map_err(|e| format!("Failed to create telegram_workflows table: {}", e))?;
        for (col_name, col_type) in [
            ("target_chat_type", "TEXT"),
            ("target_request_message_id", "INTEGER"),
        ] {
            add_column_if_missing(conn, "telegram_workflows", col_name, col_type)?;
        }

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS telegram_workflow_events (
                id TEXT PRIMARY KEY NOT NULL,
                workflow_id TEXT NOT NULL,
                conversation_id TEXT,
                event_type TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (workflow_id) REFERENCES telegram_workflows(id) ON DELETE CASCADE,
                FOREIGN KEY (conversation_id) REFERENCES telegram_conversations(id) ON DELETE SET NULL
            );
            CREATE INDEX IF NOT EXISTS idx_twf_events_workflow_created
                ON telegram_workflow_events(workflow_id, created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_telegram_workflow_events_conv
                ON telegram_workflow_events(conversation_id);",
        )
        .map_err(|e| format!("Failed to create telegram_workflow_events table: {}", e))?;

        // Telegram webhook dedup table (persists across restarts)
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS telegram_webhook_dedup (
                channel_id TEXT NOT NULL,
                update_id INTEGER NOT NULL,
                seen_at TEXT NOT NULL,
                PRIMARY KEY (channel_id, update_id)
            );
            CREATE INDEX IF NOT EXISTS idx_tg_dedup_seen
                ON telegram_webhook_dedup(seen_at);",
        )
        .map_err(|e| format!("Failed to create telegram_webhook_dedup table: {}", e))?;

        // Migrate automations table to new schema
        Self::migrate_automations_table(conn)?;
        Self::ensure_automation_indexes(conn)?;

        for (column, ddl_type) in [
            ("goal_mode", "INTEGER NOT NULL DEFAULT 0"),
            ("goal_objective", "TEXT"),
            ("first_viewed_at", "TEXT"),
            ("priority", "INTEGER NOT NULL DEFAULT 0"),
            ("not_before", "TEXT"),
            ("deadline", "TEXT"),
            ("deferred_goal", "TEXT"),
            ("paused_at", "TEXT"),
            ("requires_local_disk", "INTEGER NOT NULL DEFAULT 1"),
        ] {
            add_column_if_missing(conn, "missions", column, ddl_type)?;
        }

        // Project tagging + awaiting_kind classification + activity timestamps +
        // track state. Lets external consumers (Paloma) group/filter/route
        // missions, tell "needs a decision" apart from "finished, please ack",
        // tell "no worker = problem" apart from "intentionally waiting on CI",
        // and reason about staleness without parsing titles. All nullable.
        for (column, sql_type) in [
            ("project", "TEXT"),
            ("track", "TEXT"),
            ("intent", "TEXT"),
            ("github_pr", "TEXT"),
            ("tags", "TEXT"),
            ("desired_state", "TEXT"),
            ("next_check_at", "TEXT"),
            ("awaiting_kind", "TEXT"),
            ("last_status_change_at", "TEXT"),
            ("origin", "TEXT"),
            ("origin_session_id", "TEXT"),
        ] {
            // `github_pr` shipped briefly as INTEGER; it now holds a free-form
            // PR reference string (e.g. "owner/repo#123"). The column is freshly
            // added and always NULL in practice, so converting affinity via a
            // lossless DROP + re-add as TEXT is safe.
            //
            // CRITICAL: this runs concurrently — a global store and the per-user
            // store both initialize on the same DB file at startup. The DDL here
            // MUST be non-fatal: a previous (#572) version returned Err when the
            // racing init had already dropped the column ("no such column"),
            // which failed the whole sqlite store init and silently fell the
            // service back to an in-memory store (losing visibility of all
            // persisted missions). So tolerate "already done" / concurrent races
            // on every ALTER below instead of propagating them.
            if column == "github_pr" {
                let is_integer: bool = conn
                    .prepare(
                        "SELECT 1 FROM pragma_table_info('missions') WHERE name = 'github_pr' AND UPPER(type) = 'INTEGER'",
                    )
                    .map_err(|e| format!("Failed to check github_pr type: {}", e))?
                    .exists([])
                    .map_err(|e| format!("Failed to query table info: {}", e))?;
                if is_integer {
                    tracing::info!(
                        "Running migration: converting 'github_pr' column from INTEGER to TEXT"
                    );
                    if let Err(e) = conn.execute("ALTER TABLE missions DROP COLUMN github_pr", []) {
                        tracing::warn!(
                            "github_pr INTEGER→TEXT drop skipped (already converted or concurrent migration): {}",
                            e
                        );
                    }
                }
            }
            let exists: bool = conn
                .prepare("SELECT 1 FROM pragma_table_info('missions') WHERE name = ?1")
                .map_err(|e| format!("Failed to check for {} column: {}", column, e))?
                .exists(params![column])
                .map_err(|e| format!("Failed to query table info: {}", e))?;
            if !exists {
                tracing::info!(
                    "Running migration: adding '{}' column to missions table",
                    column
                );
                // Non-fatal: a concurrent init may have added the column between
                // our `exists` check and here ("duplicate column name").
                if let Err(e) = conn.execute(
                    &format!("ALTER TABLE missions ADD COLUMN {} {}", column, sql_type),
                    [],
                ) {
                    tracing::warn!(
                        "Adding '{}' column skipped (already present or concurrent migration): {}",
                        column,
                        e
                    );
                }
            }
        }

        // Backfill `origin` for missions created by the Hermes assistant MCP
        // before the dedicated column existed (the marker was only a tag).
        // Non-fatal for the same concurrent-init reason as the ALTERs above.
        if let Err(e) = conn.execute(
            "UPDATE missions SET origin = 'hermes' \
             WHERE origin IS NULL AND tags LIKE '%\"origin:hermes-assistant\"%'",
            [],
        ) {
            tracing::warn!("origin backfill from tags skipped: {}", e);
        }

        // Indexes for the filtered listing. These MUST live here and not in
        // SCHEMA: `execute_batch(SCHEMA)` runs BEFORE this function, and on an
        // existing database `CREATE TABLE IF NOT EXISTS missions` is a no-op,
        // so an index over a column the ALTERs above have not added yet would
        // fail with "no such column" — failing store init and silently
        // dropping the service to an in-memory store (same trap the ALTER
        // comment above describes). Non-fatal for the same reason.
        for (name, ddl) in [
            (
                "idx_missions_origin_session",
                "CREATE INDEX IF NOT EXISTS idx_missions_origin_session ON missions(origin_session_id)",
            ),
            (
                "idx_missions_project_track",
                "CREATE INDEX IF NOT EXISTS idx_missions_project_track ON missions(project, track)",
            ),
            (
                // `track` alone cannot use the composite above — SQLite can
                // only seek an index by a prefix of its columns, and that one
                // starts with `project`. Both client APIs and the control
                // endpoint accept `track` without a project, so without this
                // a rare or missing track scanned the whole fleet while the
                // connection mutex was held, once per page.
                "idx_missions_track_updated",
                "CREATE INDEX IF NOT EXISTS idx_missions_track_updated ON missions(track, updated_at DESC)",
            ),
        ] {
            if let Err(e) = conn.execute(ddl, []) {
                tracing::warn!("creating {} skipped: {}", name, e);
            }
        }

        // Guard-evidence side table (2026-08-06). A separate table, NOT a
        // missions column: every mission SELECT here maps columns by
        // position, and widening those projections risks the exact
        // fall-back-to-memory failure the migration comments above warn
        // about. Non-fatal like the indexes.
        if let Err(e) = conn.execute(
            "CREATE TABLE IF NOT EXISTS mission_terminal_evidence (
                mission_id TEXT PRIMARY KEY,
                evidence TEXT NOT NULL,
                recorded_at TEXT NOT NULL
            )",
            [],
        ) {
            tracing::warn!("creating mission_terminal_evidence skipped: {}", e);
        }

        // Match the conservative file-store migration: an untouched pending
        // Grok mission with no native/session or execution evidence. Use one
        // conditional UPDATE so a concurrent writer cannot race a read/clear.
        conn.execute(
            "UPDATE missions SET session_id = NULL
             WHERE backend = 'grok' AND status = 'pending'
               AND created_at = updated_at
               AND (last_status_change_at IS NULL OR last_status_change_at = created_at)
               AND resumable = 0 AND interrupted_at IS NULL AND paused_at IS NULL
               AND terminal_reason IS NULL
               AND (desktop_sessions IS NULL OR desktop_sessions = '[]')
               AND length(session_id) = 36 AND substr(session_id, 15, 1) = '4'
               AND substr(session_id, 9, 1) = '-' AND substr(session_id, 14, 1) = '-'
               AND substr(session_id, 19, 1) = '-' AND substr(session_id, 24, 1) = '-'
               AND length(replace(session_id, '-', '')) = 32
               AND lower(replace(session_id, '-', '')) NOT GLOB '*[^0-9a-f]*'
               AND NOT EXISTS (SELECT 1 FROM mission_harness_sessions s WHERE s.mission_id = missions.id)
               AND NOT EXISTS (SELECT 1 FROM mission_native_prompt_attempts p WHERE p.mission_id = missions.id)
               AND NOT EXISTS (SELECT 1 FROM mission_runs r WHERE r.mission_id = missions.id)
               AND NOT EXISTS (SELECT 1 FROM mission_events e WHERE e.mission_id = missions.id)
               AND NOT EXISTS (SELECT 1 FROM mission_trees t WHERE t.mission_id = missions.id)
               AND NOT EXISTS (SELECT 1 FROM mission_terminal_evidence e WHERE e.mission_id = missions.id)",
            [],
        ).map_err(|e| format!("Failed to migrate unused Grok session placeholders: {e}"))?;

        Ok(())
    }

    /// Migrate the automations table from old schema to new schema.
    pub(super) fn migrate_automations_table(conn: &Connection) -> Result<(), String> {
        // Check if the automations table has the old schema
        let has_command_name: bool = conn
            .prepare("SELECT 1 FROM pragma_table_info('automations') WHERE name = 'command_name'")
            .map_err(|e| format!("Failed to check automations schema: {}", e))?
            .exists([])
            .map_err(|e| format!("Failed to query table info: {}", e))?;

        if has_command_name {
            tracing::info!("Running migration: updating automations table to new schema");

            // Read existing automations
            let mut stmt = conn
                .prepare("SELECT id, mission_id, command_name, interval_seconds, active, created_at, last_triggered_at FROM automations")
                .map_err(|e| format!("Failed to read old automations: {}", e))?;

            let old_automations: Vec<LegacyAutomationRow> = stmt
                .query_map([], |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                    ))
                })
                .map_err(|e| format!("Failed to query old automations: {}", e))?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| format!("Failed to collect old automations: {}", e))?;

            // Drop the old table
            conn.execute("DROP TABLE IF EXISTS automations", [])
                .map_err(|e| format!("Failed to drop old automations table: {}", e))?;

            // Create the new table
            conn.execute_batch(
                "CREATE TABLE automations (
                    id TEXT PRIMARY KEY NOT NULL,
                    mission_id TEXT NOT NULL,
                    command_source_type TEXT NOT NULL,
                    command_source_data TEXT NOT NULL,
                    trigger_type TEXT NOT NULL,
                    trigger_data TEXT NOT NULL,
                    variables TEXT NOT NULL DEFAULT '{}',
                    active INTEGER NOT NULL DEFAULT 1,
                    stop_policy TEXT NOT NULL DEFAULT 'consecutive_failures:2',
                    created_at TEXT NOT NULL,
                    last_triggered_at TEXT,
                    retry_max_retries INTEGER NOT NULL DEFAULT 3,
                    retry_delay_seconds INTEGER NOT NULL DEFAULT 60,
                    retry_backoff_multiplier REAL NOT NULL DEFAULT 2.0,
                    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_automations_mission ON automations(mission_id);
                CREATE INDEX IF NOT EXISTS idx_automations_active ON automations(mission_id, active);
                CREATE INDEX IF NOT EXISTS idx_automations_webhook_id ON automations(json_extract(trigger_data, '$.webhook_id')) WHERE trigger_type = 'webhook';

                CREATE TABLE IF NOT EXISTS automation_executions (
                    id TEXT PRIMARY KEY NOT NULL,
                    automation_id TEXT NOT NULL,
                    mission_id TEXT NOT NULL,
                    triggered_at TEXT NOT NULL,
                    trigger_source TEXT NOT NULL,
                    status TEXT NOT NULL,
                    webhook_payload TEXT,
                    variables_used TEXT NOT NULL DEFAULT '{}',
                    completed_at TEXT,
                    error TEXT,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    FOREIGN KEY (automation_id) REFERENCES automations(id) ON DELETE CASCADE,
                    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_executions_automation ON automation_executions(automation_id, triggered_at DESC);
                CREATE INDEX IF NOT EXISTS idx_executions_mission ON automation_executions(mission_id, triggered_at DESC);
                CREATE INDEX IF NOT EXISTS idx_executions_status ON automation_executions(status);"
            )
            .map_err(|e| format!("Failed to create new automations table: {}", e))?;

            // Migrate old data to new schema
            let automation_count = old_automations.len();
            for (
                id,
                mission_id,
                command_name,
                interval_seconds,
                active,
                created_at,
                last_triggered_at,
            ) in old_automations
            {
                // Convert old format to new format
                let command_source_data = serde_json::json!({
                    "name": command_name
                })
                .to_string();

                let trigger_data = serde_json::json!({
                    "seconds": interval_seconds
                })
                .to_string();

                conn.execute(
                    "INSERT INTO automations (id, mission_id, command_source_type, command_source_data,
                                             trigger_type, trigger_data, variables, active, stop_policy,
                                             fresh_session, created_at, last_triggered_at, retry_max_retries,
                                             retry_delay_seconds, retry_backoff_multiplier)
                     VALUES (?, ?, 'library', ?, 'interval', ?, '{}', ?, 'consecutive_failures:2', 'keep', ?, ?, 3, 60, 2.0)",
                    params![id, mission_id, command_source_data, trigger_data, active, created_at, last_triggered_at],
                )
                .map_err(|e| format!("Failed to migrate automation: {}", e))?;
            }

            tracing::info!(
                "Successfully migrated {} automations to new schema",
                automation_count
            );
        } else {
            // Check if automation_executions table exists
            let has_executions_table: bool = conn
                .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='automation_executions'")
                .map_err(|e| format!("Failed to check for automation_executions table: {}", e))?
                .exists([])
                .map_err(|e| format!("Failed to query sqlite_master: {}", e))?;

            if !has_executions_table {
                tracing::info!("Creating automation_executions table");
                conn.execute_batch(
                    "CREATE TABLE IF NOT EXISTS automation_executions (
                        id TEXT PRIMARY KEY NOT NULL,
                        automation_id TEXT NOT NULL,
                        mission_id TEXT NOT NULL,
                        triggered_at TEXT NOT NULL,
                        trigger_source TEXT NOT NULL,
                        status TEXT NOT NULL,
                        webhook_payload TEXT,
                        variables_used TEXT NOT NULL DEFAULT '{}',
                        completed_at TEXT,
                        error TEXT,
                        retry_count INTEGER NOT NULL DEFAULT 0,
                        FOREIGN KEY (automation_id) REFERENCES automations(id) ON DELETE CASCADE,
                        FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
                    );

                    CREATE INDEX IF NOT EXISTS idx_executions_automation ON automation_executions(automation_id, triggered_at DESC);
                    CREATE INDEX IF NOT EXISTS idx_executions_mission ON automation_executions(mission_id, triggered_at DESC);
                    CREATE INDEX IF NOT EXISTS idx_executions_status ON automation_executions(status);"
                )
                .map_err(|e| format!("Failed to create automation_executions table: {}", e))?;
            }
        }

        Ok(())
    }

    pub(super) fn ensure_automation_indexes(conn: &Connection) -> Result<(), String> {
        let has_trigger_data: bool = conn
            .prepare("SELECT 1 FROM pragma_table_info('automations') WHERE name = 'trigger_data'")
            .map_err(|e| format!("Failed to check automations columns: {}", e))?
            .exists([])
            .map_err(|e| format!("Failed to query table info: {}", e))?;

        if has_trigger_data {
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_automations_webhook_id ON automations(json_extract(trigger_data, '$.webhook_id')) WHERE trigger_type = 'webhook'",
                [],
            )
            .map_err(|e| format!("Failed to create automation webhook index: {}", e))?;
        }

        for (column, ddl_type) in [
            (
                "stop_policy",
                "TEXT NOT NULL DEFAULT 'consecutive_failures:2'",
            ),
            ("fresh_session", "TEXT NOT NULL DEFAULT 'keep'"),
            ("driver", "TEXT NOT NULL DEFAULT 'scheduler'"),
        ] {
            let exists: bool = conn
                .prepare("SELECT 1 FROM pragma_table_info('automations') WHERE name = ?1")
                .map_err(|e| format!("Failed to check automations.{column} column: {e}"))?
                .exists(params![column])
                .map_err(|e| format!("Failed to query automations table info: {e}"))?;
            if !exists {
                tracing::info!("Running migration: adding '{column}' column to automations table");
                match conn.execute(
                    &format!("ALTER TABLE automations ADD COLUMN {column} {ddl_type}"),
                    [],
                ) {
                    Ok(_) => {}
                    Err(e) if e.to_string().contains("duplicate column") => {}
                    Err(e) => {
                        return Err(format!("Failed to add automations.{column} column: {e}"))
                    }
                }
            }
        }

        // Cleanup: drop stale inactive harness-loop automations. These are
        // per-`/goal`-cycle UI artifacts that the native_loop_observer now
        // deletes on terminal status; this purges any rows accumulated under
        // the old "deactivate-and-keep" behavior (one mission had 50+ such
        // rows for a single recurring interval). Cascade FK removes the
        // matching automation_executions. Safe to run on every startup —
        // idempotent and only affects rows that should not exist under the
        // current model.
        let purged: usize = conn
            .execute(
                "DELETE FROM automations WHERE active = 0 AND driver = 'harness_loop'",
                [],
            )
            .map_err(|e| format!("Failed to purge inactive harness_loop rows: {}", e))?;
        if purged > 0 {
            tracing::info!(
                "Cleanup: purged {} inactive harness_loop automation rows",
                purged
            );
        }

        Ok(())
    }
}
