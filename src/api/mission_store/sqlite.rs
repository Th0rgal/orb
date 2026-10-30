//! SQLite-based mission store with full event logging.
#[path = "sqlite_cloud.rs"]
mod cloud;
#[cfg(test)]
mod filter_tests;
#[cfg(test)]
mod id_prefix_tests;
#[path = "sqlite_transfer.rs"]
mod machine_transfer;
mod migrations;
mod missions;
#[path = "sqlite_client_link.rs"]
mod sqlite_client_link;
#[path = "sqlite_local_origin.rs"]
mod sqlite_local_origin;
use missions::*;
mod events;
mod runs;
pub(super) use events::*;
mod automations;
mod board;
mod import;
mod paloma;
mod queue;
pub(crate) mod search_index;
mod telegram;
mod usage;
use migrations::*;
#[cfg(test)]
mod search_tests;
#[cfg(test)]
mod tests;

use super::{
    now_string, sanitize_filename, Automation, AutomationExecution, AwaitingKind, BoardOutboxItem,
    BoardTask, BoardTaskOutcome, BoardTaskRole, BoardTaskStatus, ClientIngest, CommandSource,
    DailyUsageStats, ExecutionStatus, FreshSession, HourlyUsageStats, Mission, MissionActivity,
    MissionExecutionState, MissionFilter, MissionHistoryEntry, MissionMode, MissionProject,
    MissionProjectPatch, MissionRun, MissionScheduling, MissionStatus, MissionStatusCounts,
    MissionStore, MissionSummary, MissionToolExecution, MissionToolExecutionState, ModelUsageStats,
    NewBoardTask, PalomaCooldownState, PalomaDecision, PalomaMissionCard, PalomaSchedulerJob,
    PalomaUserPreferences, RetryConfig, StopPolicy, StoredEvent, TaskAttempt,
    TelegramActionExecution, TelegramActionExecutionKind, TelegramActionExecutionStatus,
    TelegramAlert, TelegramAlertPreference, TelegramChannel, TelegramChatMission,
    TelegramConversation, TelegramConversationMessage, TelegramConversationMessageDirection,
    TelegramMissionInterestLevel, TelegramMissionSubscription, TelegramScheduledMessage,
    TelegramScheduledMessageStatus, TelegramStructuredMemoryEntry, TelegramStructuredMemoryKind,
    TelegramStructuredMemoryScope, TelegramStructuredMemorySearchHit, TelegramUser,
    TelegramUserCursor, TelegramUserRole, TelegramWorkflow, TelegramWorkflowEvent,
    TelegramWorkflowKind, TelegramWorkflowStatus, ToolCallSummary, TriggerType, WebhookConfig,
    SUPERSEDED_TAG,
};
use crate::api::control::{AgentEvent, AgentTreeNode, DesktopSessionInfo, TextOp};
use async_trait::async_trait;
use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use uuid::Uuid;

type LegacyAutomationRow = (String, String, String, i64, i64, String, Option<String>);
const COST_CURRENCY_USD: &str = "USD";
const METADATA_SOURCE_USER: &str = "user";
const TELEGRAM_MEMORY_SEARCH_MAX_CANDIDATES: usize = 256;
const TELEGRAM_MEMORY_SEARCH_STOPWORDS: &[&str] = &[
    "a",
    "ai",
    "alors",
    "and",
    "au",
    "aux",
    "avec",
    "ce",
    "ces",
    "comment",
    "dans",
    "de",
    "des",
    "do",
    "does",
    "du",
    "elle",
    "en",
    "est",
    "et",
    "for",
    "how",
    "i",
    "il",
    "is",
    "je",
    "la",
    "le",
    "les",
    "ma",
    "me",
    "mes",
    "mi",
    "mon",
    "my",
    "of",
    "on",
    "ou",
    "où",
    "par",
    "pas",
    "pour",
    "prefere",
    "préféré",
    "prefere",
    "preference",
    "preferences",
    "preference",
    "preferences",
    "que",
    "quel",
    "quelle",
    "quelles",
    "quels",
    "qui",
    "remember",
    "rappelle",
    "rappelle-moi",
    "souviens",
    "sur",
    "the",
    "to",
    "toi",
    "tu",
    "un",
    "une",
    "user",
    "veux",
    "veux-tu",
    "what",
    "when",
    "where",
    "with",
    "you",
];

/// Content size threshold for inline storage (64KB).
const CONTENT_SIZE_THRESHOLD: usize = 64 * 1024;

pub struct SqliteMissionStore {
    conn: Arc<Mutex<Connection>>,
    /// Read-only connections for the queries clients poll. In WAL mode they
    /// do not wait for the writer, so a slow write or a burst of event
    /// writes no longer queues every status request behind one lock.
    readers: Arc<Vec<Arc<Mutex<Connection>>>>,
    next_reader: Arc<std::sync::atomic::AtomicUsize>,
    content_dir: PathBuf,
}

/// Decisions kept for the audit views, and how often an insert trims the rest.
const PALOMA_DECISIONS_KEPT: i64 = 10_000;
const PALOMA_DECISION_PRUNE_EVERY: i64 = 500;

/// Read connections opened next to the writer.
const READ_CONNECTIONS: usize = 4;

impl SqliteMissionStore {
    /// A connection for a query that only reads committed state.
    fn reader(&self) -> Arc<Mutex<Connection>> {
        if self.readers.is_empty() {
            return self.conn.clone();
        }
        let turn = self
            .next_reader
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        // Prefer an idle reader over queueing behind a busy one.
        (0..self.readers.len())
            .map(|offset| &self.readers[(turn + offset) % self.readers.len()])
            .find(|reader| reader.try_lock().is_ok())
            .unwrap_or(&self.readers[turn % self.readers.len()])
            .clone()
    }

    /// Parse an automation row from the database.
    fn parse_automation_row(row: &rusqlite::Row<'_>) -> Result<Automation, rusqlite::Error> {
        let id: String = row.get(0)?;
        let mission_id: String = row.get(1)?;
        let command_source_type: String = row.get(2)?;
        let command_source_data: String = row.get(3)?;
        let trigger_type: String = row.get(4)?;
        let trigger_data: String = row.get(5)?;
        let variables_json: String = row.get(6)?;
        let active: i64 = row.get(7)?;
        let stop_policy_str: String = row.get(8)?;
        let fresh_session_str: String = row.get(9).unwrap_or_else(|_| "keep".to_string());
        let created_at: String = row.get(10)?;
        let last_triggered_at: Option<String> = row.get(11)?;
        let retry_max_retries: i64 = row.get(12)?;
        let retry_delay_seconds: i64 = row.get(13)?;
        let retry_backoff_multiplier: f64 = row.get(14)?;
        // `driver` is appended to the SELECT list by all callers below. If a
        // legacy SELECT doesn't include it, default to `scheduler`.
        let driver_str: String = row
            .get::<_, String>(15)
            .unwrap_or_else(|_| "scheduler".to_string());

        // Parse command source
        let command_source: CommandSource = match command_source_type.as_str() {
            "library" => {
                let data: serde_json::Value = serde_json::from_str(&command_source_data)
                    .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
                CommandSource::Library {
                    name: data["name"].as_str().unwrap_or("").to_string(),
                }
            }
            "local_file" => {
                let data: serde_json::Value = serde_json::from_str(&command_source_data)
                    .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
                CommandSource::LocalFile {
                    path: data["path"].as_str().unwrap_or("").to_string(),
                }
            }
            "inline" => {
                let data: serde_json::Value = serde_json::from_str(&command_source_data)
                    .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
                CommandSource::Inline {
                    content: data["content"].as_str().unwrap_or("").to_string(),
                }
            }
            "native_loop" => {
                let data: serde_json::Value = serde_json::from_str(&command_source_data)
                    .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
                CommandSource::NativeLoop {
                    harness: data["harness"].as_str().unwrap_or("").to_string(),
                    command: data["command"].as_str().unwrap_or("").to_string(),
                    args: data.get("args").cloned().unwrap_or(serde_json::Value::Null),
                }
            }
            _ => {
                return Err(rusqlite::Error::ToSqlConversionFailure(
                    format!("Unknown command source type: {}", command_source_type).into(),
                ));
            }
        };

        // Parse trigger
        let trigger: TriggerType = match trigger_type.as_str() {
            "interval" => {
                let data: serde_json::Value = serde_json::from_str(&trigger_data)
                    .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
                TriggerType::Interval {
                    seconds: data["seconds"].as_u64().unwrap_or(60),
                }
            }
            "cron" => {
                let data: serde_json::Value = serde_json::from_str(&trigger_data)
                    .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
                TriggerType::Cron {
                    expression: data["expression"]
                        .as_str()
                        .unwrap_or("0 * * * *")
                        .to_string(),
                    timezone: data["timezone"].as_str().unwrap_or("UTC").to_string(),
                }
            }
            "webhook" => {
                let config: WebhookConfig = serde_json::from_str(&trigger_data)
                    .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
                TriggerType::Webhook { config }
            }
            "agent_finished" => TriggerType::AgentFinished,
            "durable_job_terminal" => {
                let data: serde_json::Value = serde_json::from_str(&trigger_data)
                    .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
                let job_id = data["job_id"]
                    .as_str()
                    .and_then(|value| Uuid::parse_str(value).ok())
                    .ok_or_else(|| {
                        rusqlite::Error::ToSqlConversionFailure(
                            "Invalid durable_job_terminal job_id".into(),
                        )
                    })?;
                TriggerType::DurableJobTerminal { job_id }
            }
            "telegram" => {
                let config: super::TelegramTriggerConfig = serde_json::from_str(&trigger_data)
                    .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
                TriggerType::Telegram { config }
            }
            _ => {
                return Err(rusqlite::Error::ToSqlConversionFailure(
                    format!("Unknown trigger type: {}", trigger_type).into(),
                ));
            }
        };

        // Parse variables
        let variables: HashMap<String, String> =
            serde_json::from_str(&variables_json).unwrap_or_default();
        // Parse stop_policy - handle both old format and new format
        let stop_policy = if stop_policy_str.starts_with("consecutive_failures:") {
            let count = stop_policy_str
                .split(':')
                .nth(1)
                .and_then(|s| s.parse().ok())
                .unwrap_or(2);
            StopPolicy::WhenFailingConsecutively { count }
        } else if stop_policy_str.starts_with("all_issues_closed_and_prs_merged:") {
            let repo = stop_policy_str.split(':').nth(1).unwrap_or("").to_string();
            StopPolicy::WhenAllIssuesClosedAndPRsMerged { repo }
        } else {
            match stop_policy_str.as_str() {
                "never" => StopPolicy::Never,
                "after_first_fire" => StopPolicy::AfterFirstFire,
                "when_mission_terminal" => StopPolicy::WhenMissionTerminal,
                _ => StopPolicy::Never,
            }
        };

        // Parse fresh_session
        let fresh_session = match fresh_session_str.as_str() {
            "always" => FreshSession::Always,
            "switch" => FreshSession::Switch,
            _ => FreshSession::Keep,
        };

        let driver = match driver_str.as_str() {
            "harness_loop" => super::AutomationDriver::HarnessLoop,
            _ => super::AutomationDriver::Scheduler,
        };

        Ok(Automation {
            id: Uuid::parse_str(&id)
                .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
            mission_id: Uuid::parse_str(&mission_id)
                .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
            command_source,
            trigger,
            variables,
            active: active != 0,
            stop_policy,
            fresh_session,
            created_at,
            last_triggered_at,
            retry_config: RetryConfig {
                max_retries: retry_max_retries as u32,
                retry_delay_seconds: retry_delay_seconds as u64,
                backoff_multiplier: retry_backoff_multiplier,
            },
            consecutive_failures: 0,
            driver,
        })
    }

    /// Parse an automation execution row from the database.
    fn parse_execution_row(
        row: &rusqlite::Row<'_>,
    ) -> Result<AutomationExecution, rusqlite::Error> {
        let id: String = row.get(0)?;
        let automation_id: String = row.get(1)?;
        let mission_id: String = row.get(2)?;
        let triggered_at: String = row.get(3)?;
        let trigger_source: String = row.get(4)?;
        let status_str: String = row.get(5)?;
        let webhook_payload: Option<String> = row.get(6)?;
        let variables_used_json: String = row.get(7)?;
        let completed_at: Option<String> = row.get(8)?;
        let error: Option<String> = row.get(9)?;
        let retry_count: i64 = row.get(10)?;

        // Parse status
        let status = match status_str.as_str() {
            "pending" => ExecutionStatus::Pending,
            "running" => ExecutionStatus::Running,
            "success" => ExecutionStatus::Success,
            "failed" => ExecutionStatus::Failed,
            "cancelled" => ExecutionStatus::Cancelled,
            "skipped" => ExecutionStatus::Skipped,
            _ => ExecutionStatus::Failed,
        };

        // Parse webhook payload
        let webhook_payload_value = webhook_payload.and_then(|s| serde_json::from_str(&s).ok());

        // Parse variables
        let variables_used: HashMap<String, String> =
            serde_json::from_str(&variables_used_json).unwrap_or_default();

        Ok(AutomationExecution {
            id: Uuid::parse_str(&id)
                .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
            automation_id: Uuid::parse_str(&automation_id)
                .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
            mission_id: Uuid::parse_str(&mission_id)
                .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
            triggered_at,
            trigger_source,
            status,
            webhook_payload: webhook_payload_value,
            variables_used,
            completed_at,
            error,
            retry_count: retry_count as u32,
        })
    }

    pub async fn new(base_dir: PathBuf, user_id: &str) -> Result<Self, String> {
        let sanitized = sanitize_filename(user_id);
        let db_path = base_dir.join(format!("missions-{}.db", sanitized));
        let content_dir = base_dir.join("mission_data").join(&sanitized);

        // Create directories
        tokio::fs::create_dir_all(&base_dir)
            .await
            .map_err(|e| format!("Failed to create mission store dir: {}", e))?;
        tokio::fs::create_dir_all(&content_dir)
            .await
            .map_err(|e| format!("Failed to create content dir: {}", e))?;

        // Open database in blocking task
        let conn = tokio::task::spawn_blocking(move || {
            let conn = Connection::open(&db_path)
                .map_err(|e| format!("Failed to open SQLite database: {}", e))?;

            // A global store and the per-user store can open the same DB file
            // and run schema/migrations concurrently at startup. Without a busy
            // timeout, the second writer's DDL fails with SQLITE_BUSY and aborts
            // store init (→ silent in-memory fallback). Make concurrent writers
            // wait for the lock instead.
            conn.busy_timeout(std::time::Duration::from_secs(10))
                .map_err(|e| format!("Failed to set busy_timeout: {}", e))?;

            // Run schema
            conn.execute_batch(cloud::SCHEMA)
                .map_err(|e| e.to_string())?;
            conn.execute_batch(machine_transfer::SCHEMA)
                .map_err(|e| e.to_string())?;
            conn.execute_batch(SCHEMA)
                .map_err(|e| format!("Failed to run schema: {}", e))?;

            // Run migrations for existing databases
            Self::run_migrations(&conn)?;
            usage::migrate(&conn)?;
            // Cancel abandoned transfers after all mission tables exist.
            conn.execute_batch(include_str!("transfer_cleanup.sql"))
                .map_err(|e| format!("Failed to install transfer cleanup: {e}"))?;
            let needs_search_backfill = search_index::ensure_schema(&conn)?;

            let mut readers = Vec::with_capacity(READ_CONNECTIONS);
            for _ in 0..READ_CONNECTIONS {
                let reader = Connection::open(&db_path)
                    .map_err(|e| format!("Failed to open SQLite read connection: {}", e))?;
                reader
                    .busy_timeout(std::time::Duration::from_secs(10))
                    .map_err(|e| format!("Failed to set busy_timeout: {}", e))?;
                reader
                    .pragma_update(None, "query_only", true)
                    .map_err(|e| format!("Failed to make the connection read-only: {}", e))?;
                readers.push(Arc::new(Mutex::new(reader)));
            }

            Ok::<_, String>((conn, readers, needs_search_backfill))
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))??;
        let (conn, readers, needs_search_backfill) = conn;
        let conn_arc = Arc::new(Mutex::new(conn));
        if needs_search_backfill {
            search_index::spawn_background_backfill(Arc::downgrade(&conn_arc), content_dir.clone());
        }

        Ok(Self {
            conn: conn_arc,
            readers: Arc::new(readers),
            next_reader: Arc::default(),
            content_dir,
        })
    }

    /// Open only an existing store for admission recovery. The caller holds
    /// the durable admission lock; this never creates a store or actor and
    /// never runs migrations while locating the owner of a pending receipt.
    pub(crate) async fn open_for_admission_recovery(path: PathBuf) -> Result<Self, String> {
        let user = path
            .file_stem()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_prefix("missions-"))
            .ok_or_else(|| "invalid mission database path".to_string())?;
        let content_dir = path
            .parent()
            .ok_or_else(|| "missing mission database directory".to_string())?
            .join("mission_data")
            .join(user);
        let conn = tokio::task::spawn_blocking(move || {
            let conn =
                Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE)
                    .map_err(|e| e.to_string())?;
            conn.busy_timeout(std::time::Duration::from_secs(10))
                .map_err(|e| e.to_string())?;
            Ok::<_, String>(conn)
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            readers: Arc::default(),
            next_reader: Arc::default(),
            content_dir,
        })
    }

    /// Test-only: force-set a mission's `updated_at` and (if any) the timestamp
    /// of every persisted event for that mission. Lets tests exercise the
    /// stale-cleanup path with deterministic clock values without sleeping or
    /// stubbing `now`.
    #[cfg(test)]
    pub(super) async fn force_backdate_for_test(
        &self,
        mission_id: Uuid,
        timestamp: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let mid = mission_id.to_string();
        let ts = timestamp.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET updated_at = ?1 WHERE id = ?2",
                rusqlite::params![ts, mid],
            )
            .map_err(|e| e.to_string())?;
            conn.execute(
                "UPDATE mission_events SET timestamp = ?1 WHERE mission_id = ?2",
                rusqlite::params![ts, mid],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(())
    }

    /// Store content, either inline or in a file if too large.
    fn store_content(
        content_dir: &std::path::Path,
        mission_id: Uuid,
        sequence: i64,
        event_type: &str,
        content: &str,
    ) -> (Option<String>, Option<String>) {
        if content.len() <= CONTENT_SIZE_THRESHOLD {
            (Some(content.to_string()), None)
        } else {
            let events_dir = content_dir.join(mission_id.to_string()).join("events");
            if let Err(e) = std::fs::create_dir_all(&events_dir) {
                tracing::warn!("Failed to create events dir: {}", e);
                // Fall back to inline storage
                return (Some(content.to_string()), None);
            }

            let file_path = events_dir.join(format!("event_{}_{}.txt", sequence, event_type));
            if let Err(e) = std::fs::write(&file_path, content) {
                tracing::warn!("Failed to write content file: {}", e);
                return (Some(content.to_string()), None);
            }

            (None, Some(file_path.to_string_lossy().to_string()))
        }
    }

    /// Load content from inline or file.
    fn load_content(content: Option<&str>, content_file: Option<&str>) -> String {
        if let Some(c) = content {
            c.to_string()
        } else if let Some(path) = content_file {
            std::fs::read_to_string(path).unwrap_or_default()
        } else {
            String::new()
        }
    }
}

#[async_trait]
impl MissionStore for SqliteMissionStore {
    async fn sync_local_origin(
        &self,
        snapshot: crate::local_origin::Snapshot,
    ) -> Result<(), String> {
        sqlite_local_origin::sync(self, snapshot).await
    }
    async fn client_event_cursor(&self, mission_id: Uuid, client_id: &str) -> Result<u64, String> {
        sqlite_client_link::cursor(self, mission_id, client_id).await
    }
    async fn log_client_event(
        &self,
        mission_id: Uuid,
        client_id: &str,
        seq: u64,
        event: Option<AgentEvent>,
        run: Option<(Uuid, u64)>,
    ) -> Result<ClientIngest, String> {
        sqlite_client_link::log(self, mission_id, client_id, seq, event, run).await
    }
    fn is_persistent(&self) -> bool {
        true
    }
    async fn list_missions(&self, limit: usize, offset: usize) -> Result<Vec<Mission>, String> {
        SqliteMissionStore::list_missions(self, limit, offset).await
    }
    async fn list_missions_filtered(
        &self,
        filter: &MissionFilter,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<Mission>, String> {
        SqliteMissionStore::list_missions_filtered(self, filter, limit, offset).await
    }
    async fn find_missions_by_id_prefix(
        &self,
        prefix: &str,
        limit: usize,
    ) -> Result<Vec<Mission>, String> {
        SqliteMissionStore::find_missions_by_id_prefix(self, prefix, limit).await
    }
    async fn count_missions_by_status(&self) -> Result<MissionStatusCounts, String> {
        SqliteMissionStore::count_missions_by_status(self).await
    }
    async fn count_missions_updated_since(
        &self,
        since: &str,
    ) -> Result<MissionStatusCounts, String> {
        SqliteMissionStore::count_missions_updated_since(self, since).await
    }
    async fn restore_mission_status(
        &self,
        id: Uuid,
        snapshot: &super::MissionStatusSnapshot,
    ) -> Result<(), String> {
        SqliteMissionStore::restore_mission_status(self, id, snapshot).await
    }
    async fn set_terminal_evidence(&self, id: Uuid, evidence: &str) -> Result<(), String> {
        SqliteMissionStore::set_terminal_evidence(self, id, evidence).await
    }
    async fn get_mission(&self, id: Uuid) -> Result<Option<Mission>, String> {
        SqliteMissionStore::get_mission(self, id).await
    }

    async fn append_cloud_event(
        &self,
        id: Uuid,
        event: crate::api::cloud_agents::Event,
    ) -> Result<(), String> {
        cloud::event(self, id, event).await
    }
    async fn cloud_events(&self, id: Uuid) -> Result<Vec<crate::api::cloud_agents::Event>, String> {
        cloud::events(self, id).await
    }
    async fn cloud_executions(&self) -> Result<Vec<crate::api::cloud_agents::Execution>, String> {
        cloud::list(self).await
    }
    async fn save_cloud_execution(
        &self,
        execution: crate::api::cloud_agents::Execution,
        expected: Option<u64>,
        title: Option<String>,
        project: Option<String>,
        tags: Vec<String>,
    ) -> Result<crate::api::cloud_agents::Execution, String> {
        cloud::save(self, execution, expected, title, project, tags).await
    }

    async fn machine_transfers(&self, id: Uuid) -> Result<Vec<super::transfer::Transfer>, String> {
        machine_transfer::list(self, id).await
    }
    async fn committed_machine_transfers(
        &self,
        ids: &[Uuid],
    ) -> Result<HashMap<Uuid, super::transfer::Transfer>, String> {
        machine_transfer::committed(self, ids).await
    }
    async fn save_machine_transfer(
        &self,
        action: super::transfer::Transfer,
        expected: Option<u64>,
    ) -> Result<super::transfer::Transfer, String> {
        machine_transfer::save(self, action, expected).await
    }
    async fn begin_mission_run(
        &self,
        mission_id: Uuid,
        owner_actor_id: &str,
        scope_unit: Option<&str>,
    ) -> Result<MissionRun, String> {
        SqliteMissionStore::begin_mission_run(self, mission_id, owner_actor_id, scope_unit).await
    }
    async fn get_active_mission_run(&self, mission_id: Uuid) -> Result<Option<MissionRun>, String> {
        SqliteMissionStore::get_active_mission_run(self, mission_id).await
    }
    async fn get_latest_mission_run(&self, mission_id: Uuid) -> Result<Option<MissionRun>, String> {
        SqliteMissionStore::get_latest_mission_run(self, mission_id).await
    }
    async fn list_active_mission_runs(&self) -> Result<Vec<MissionRun>, String> {
        SqliteMissionStore::list_active_mission_runs(self).await
    }
    async fn heartbeat_mission_run(
        &self,
        run_id: Uuid,
        generation: u64,
        state: MissionExecutionState,
        scope_unit: Option<&str>,
    ) -> Result<bool, String> {
        SqliteMissionStore::heartbeat_mission_run(self, run_id, generation, state, scope_unit).await
    }
    async fn finish_mission_run(
        &self,
        run_id: Uuid,
        generation: u64,
        terminal_reason: Option<&str>,
    ) -> Result<bool, String> {
        SqliteMissionStore::finish_mission_run(self, run_id, generation, terminal_reason).await
    }
    async fn register_tool_execution(
        &self,
        execution: &MissionToolExecution,
    ) -> Result<(), String> {
        SqliteMissionStore::register_tool_execution(self, execution).await
    }
    async fn finish_tool_execution(
        &self,
        run_id: Uuid,
        tool_call_id: &str,
        state: MissionToolExecutionState,
        exit_status: Option<i32>,
        failure_class: Option<&str>,
    ) -> Result<bool, String> {
        SqliteMissionStore::finish_tool_execution(
            self,
            run_id,
            tool_call_id,
            state,
            exit_status,
            failure_class,
        )
        .await
    }
    async fn list_active_tool_executions(
        &self,
        run_id: Uuid,
    ) -> Result<Vec<MissionToolExecution>, String> {
        SqliteMissionStore::list_active_tool_executions(self, run_id).await
    }
    async fn get_initial_user_message(&self, id: Uuid) -> Result<Option<String>, String> {
        SqliteMissionStore::get_initial_user_message(self, id).await
    }
    async fn create_mission_with_parent_and_placement(
        &self,
        title: Option<&str>,
        workspace_id: Option<Uuid>,
        agent: Option<&str>,
        model_override: Option<&str>,
        model_effort: Option<&str>,
        fast_mode: bool,
        backend: Option<&str>,
        config_profile: Option<&str>,
        parent_mission_id: Option<Uuid>,
        working_directory: Option<&str>,
        requires_local_disk: bool,
        assigned_id: Option<Uuid>,
    ) -> Result<Mission, String> {
        SqliteMissionStore::create_mission_with_parent_and_placement(
            self,
            title,
            workspace_id,
            agent,
            model_override,
            model_effort,
            fast_mode,
            backend,
            config_profile,
            parent_mission_id,
            working_directory,
            requires_local_disk,
            assigned_id,
        )
        .await
    }
    async fn create_mission_with_parent(
        &self,
        title: Option<&str>,
        workspace_id: Option<Uuid>,
        agent: Option<&str>,
        model_override: Option<&str>,
        model_effort: Option<&str>,
        fast_mode: bool,
        backend: Option<&str>,
        config_profile: Option<&str>,
        parent_mission_id: Option<Uuid>,
        working_directory: Option<&str>,
    ) -> Result<Mission, String> {
        SqliteMissionStore::create_mission_with_parent(
            self,
            title,
            workspace_id,
            agent,
            model_override,
            model_effort,
            fast_mode,
            backend,
            config_profile,
            parent_mission_id,
            working_directory,
        )
        .await
    }
    async fn reparent_child_missions(&self, from: Uuid, to: Uuid) -> Result<Vec<Uuid>, String> {
        SqliteMissionStore::reparent_child_missions(self, from, to).await
    }
    async fn get_child_missions(&self, parent_id: Uuid) -> Result<Vec<Mission>, String> {
        SqliteMissionStore::get_child_missions(self, parent_id).await
    }
    async fn get_mission_metadata(&self, id: Uuid) -> Result<Option<Mission>, String> {
        SqliteMissionStore::get_mission_metadata(self, id).await
    }
    async fn existing_mission_ids(
        &self,
        ids: &[Uuid],
    ) -> Result<std::collections::HashSet<Uuid>, String> {
        SqliteMissionStore::existing_mission_ids(self, ids).await
    }
    async fn list_hermes_root_missions(&self) -> Result<Vec<Mission>, String> {
        SqliteMissionStore::list_hermes_root_missions(self).await
    }
    async fn set_mission_requires_local_disk(
        &self,
        id: Uuid,
        requires_local_disk: bool,
    ) -> Result<(), String> {
        SqliteMissionStore::set_mission_requires_local_disk(self, id, requires_local_disk).await
    }
    async fn update_mission_status(&self, id: Uuid, status: MissionStatus) -> Result<(), String> {
        SqliteMissionStore::update_mission_status(self, id, status).await
    }
    async fn set_mission_scheduling(
        &self,
        id: Uuid,
        scheduling: &MissionScheduling,
    ) -> Result<(), String> {
        SqliteMissionStore::set_mission_scheduling(self, id, scheduling).await
    }
    async fn update_mission_status_with_reason(
        &self,
        id: Uuid,
        status: MissionStatus,
        terminal_reason: Option<&str>,
    ) -> Result<(), String> {
        SqliteMissionStore::update_mission_status_with_reason(self, id, status, terminal_reason)
            .await
    }
    async fn update_mission_history(
        &self,
        id: Uuid,
        _history: &[MissionHistoryEntry],
    ) -> Result<(), String> {
        SqliteMissionStore::update_mission_history(self, id, _history).await
    }
    async fn set_mission_first_viewed_at_if_unset(
        &self,
        id: Uuid,
        timestamp: &str,
    ) -> Result<Option<String>, String> {
        SqliteMissionStore::set_mission_first_viewed_at_if_unset(self, id, timestamp).await
    }
    async fn acknowledge_stale_awaiting_user_missions(
        &self,
        grace_seconds: u64,
    ) -> Result<Vec<Uuid>, String> {
        SqliteMissionStore::acknowledge_stale_awaiting_user_missions(self, grace_seconds).await
    }
    async fn get_waiting_background_mission_ids(&self) -> Result<Vec<Uuid>, String> {
        SqliteMissionStore::get_waiting_background_mission_ids(self).await
    }
    async fn update_mission_desktop_sessions(
        &self,
        id: Uuid,
        sessions: &[DesktopSessionInfo],
    ) -> Result<(), String> {
        SqliteMissionStore::update_mission_desktop_sessions(self, id, sessions).await
    }
    async fn update_mission_title(&self, id: Uuid, title: &str) -> Result<(), String> {
        SqliteMissionStore::update_mission_title(self, id, title).await
    }
    async fn save_control_queue(&self, _user_id: &str, payload: &str) -> Result<(), String> {
        SqliteMissionStore::save_control_queue(self, _user_id, payload).await
    }
    async fn load_control_queue(&self, _user_id: &str) -> Result<String, String> {
        SqliteMissionStore::load_control_queue(self, _user_id).await
    }
    async fn update_mission_run_settings(
        &self,
        id: Uuid,
        backend: Option<&str>,
        agent: Option<Option<&str>>,
        model_override: Option<Option<&str>>,
        model_effort: Option<Option<&str>>,
        fast_mode: Option<bool>,
        service_tier: Option<crate::codex_speed::Tier>,
        config_profile: Option<Option<&str>>,
        session_id: &str,
    ) -> Result<Mission, String> {
        SqliteMissionStore::update_mission_run_settings(
            self,
            id,
            backend,
            agent,
            model_override,
            model_effort,
            fast_mode,
            service_tier,
            config_profile,
            session_id,
        )
        .await
    }
    async fn update_mission_metadata(
        &self,
        id: Uuid,
        title: Option<Option<&str>>,
        short_description: Option<Option<&str>>,
        metadata_source: Option<Option<&str>>,
        metadata_model: Option<Option<&str>>,
        metadata_version: Option<Option<&str>>,
    ) -> Result<(), String> {
        SqliteMissionStore::update_mission_metadata(
            self,
            id,
            title,
            short_description,
            metadata_source,
            metadata_model,
            metadata_version,
        )
        .await
    }
    async fn update_mission_project(
        &self,
        id: Uuid,
        patch: MissionProjectPatch,
    ) -> Result<(), String> {
        SqliteMissionStore::update_mission_project(self, id, patch).await
    }
    async fn set_mission_origin(
        &self,
        id: Uuid,
        origin: &str,
        origin_session_id: Option<&str>,
    ) -> Result<(), String> {
        SqliteMissionStore::set_mission_origin(self, id, origin, origin_session_id).await
    }
    async fn get_mission_activity(
        &self,
        ids: &[Uuid],
    ) -> Result<std::collections::HashMap<Uuid, (Option<String>, Option<String>)>, String> {
        SqliteMissionStore::get_mission_activity(self, ids).await
    }
    async fn get_mission_summaries(
        &self,
        ids: &[Uuid],
    ) -> Result<std::collections::HashMap<Uuid, MissionSummary>, String> {
        SqliteMissionStore::get_mission_summaries(self, ids).await
    }
    async fn set_mission_awaiting_kind(
        &self,
        id: Uuid,
        kind: Option<AwaitingKind>,
    ) -> Result<(), String> {
        SqliteMissionStore::set_mission_awaiting_kind(self, id, kind).await
    }
    async fn native_prompt_attempted(&self, id: Uuid, backend: &str) -> Result<bool, String> {
        SqliteMissionStore::native_prompt_attempted(self, id, backend).await
    }
    async fn claim_native_prompt(
        &self,
        id: Uuid,
        backend: &str,
        session_id: Option<&str>,
        run: Option<&super::SessionUpdateRun>,
        claim_id: Uuid,
    ) -> Result<bool, String> {
        SqliteMissionStore::claim_native_prompt(self, id, backend, session_id, run, claim_id).await
    }
    async fn release_native_prompt_no_launch(
        &self,
        id: Uuid,
        backend: &str,
        run: Option<&super::SessionUpdateRun>,
        claim_id: Uuid,
    ) -> Result<bool, String> {
        SqliteMissionStore::release_native_prompt_no_launch(self, id, backend, run, claim_id).await
    }
    async fn update_mission_session_id(
        &self,
        id: Uuid,
        session_id: &str,
        backend: &str,
        run: Option<&super::SessionUpdateRun>,
    ) -> Result<bool, String> {
        SqliteMissionStore::update_mission_session_id(self, id, session_id, backend, run).await
    }
    async fn clear_unsubmitted_session_id(
        &self,
        id: Uuid,
        session_id: &str,
        backend: &str,
        run: &super::SessionUpdateRun,
    ) -> Result<bool, String> {
        SqliteMissionStore::clear_unsubmitted_session_id(self, id, session_id, backend, run).await
    }
    async fn update_mission_goal(
        &self,
        id: Uuid,
        goal_mode: bool,
        goal_objective: Option<&str>,
    ) -> Result<(), String> {
        SqliteMissionStore::update_mission_goal(self, id, goal_mode, goal_objective).await
    }
    async fn update_mission_tree(&self, id: Uuid, tree: &AgentTreeNode) -> Result<(), String> {
        SqliteMissionStore::update_mission_tree(self, id, tree).await
    }
    async fn get_mission_tree(&self, id: Uuid) -> Result<Option<AgentTreeNode>, String> {
        SqliteMissionStore::get_mission_tree(self, id).await
    }
    async fn delete_mission(&self, id: Uuid) -> Result<bool, String> {
        SqliteMissionStore::delete_mission(self, id).await
    }
    async fn delete_empty_untitled_missions_excluding(
        &self,
        exclude: &[Uuid],
    ) -> Result<usize, String> {
        SqliteMissionStore::delete_empty_untitled_missions_excluding(self, exclude).await
    }
    async fn get_stale_active_missions(&self, stale_hours: u64) -> Result<Vec<Mission>, String> {
        SqliteMissionStore::get_stale_active_missions(self, stale_hours).await
    }
    async fn get_all_active_missions(&self) -> Result<Vec<Mission>, String> {
        SqliteMissionStore::get_all_active_missions(self).await
    }
    async fn set_deferred_goal(
        &self,
        mission_id: Uuid,
        goal: Option<String>,
    ) -> Result<(), String> {
        SqliteMissionStore::set_deferred_goal(self, mission_id, goal).await
    }
    async fn get_deferred_goal(&self, mission_id: Uuid) -> Result<Option<String>, String> {
        SqliteMissionStore::get_deferred_goal(self, mission_id).await
    }
    async fn set_mission_paused_at(
        &self,
        mission_id: Uuid,
        paused_at: Option<String>,
    ) -> Result<(), String> {
        SqliteMissionStore::set_mission_paused_at(self, mission_id, paused_at).await
    }
    async fn get_scheduled_pending_missions(&self) -> Result<Vec<Mission>, String> {
        SqliteMissionStore::get_scheduled_pending_missions(self).await
    }
    async fn get_recent_server_shutdown_mission_ids(
        &self,
        max_age_hours: u64,
    ) -> Result<Vec<Uuid>, String> {
        SqliteMissionStore::get_recent_server_shutdown_mission_ids(self, max_age_hours).await
    }
    async fn insert_mission_summary(
        &self,
        mission_id: Uuid,
        summary: &str,
        key_files: &[String],
        success: bool,
    ) -> Result<(), String> {
        SqliteMissionStore::insert_mission_summary(self, mission_id, summary, key_files, success)
            .await
    }
    async fn latest_assistant_text(&self, mission_id: Uuid) -> Result<Option<String>, String> {
        SqliteMissionStore::latest_assistant_text(self, mission_id).await
    }
    async fn get_remote_log_offset(&self, job_id: Uuid) -> Option<u64> {
        SqliteMissionStore::get_remote_log_offset(self, job_id).await
    }
    async fn set_remote_log_offset(&self, job_id: Uuid, offset: u64) {
        SqliteMissionStore::set_remote_log_offset(self, job_id, offset).await
    }
    async fn log_event(&self, mission_id: Uuid, event: &AgentEvent) -> Result<(), String> {
        SqliteMissionStore::log_event(self, mission_id, event).await
    }
    async fn log_events(&self, events: Vec<(Uuid, AgentEvent)>) -> Vec<Result<(), String>> {
        SqliteMissionStore::log_events(self, events).await
    }
    async fn get_latest_events(
        &self,
        mission_id: Uuid,
        limit: usize,
    ) -> Result<Vec<StoredEvent>, String> {
        SqliteMissionStore::get_latest_events(self, mission_id, limit).await
    }
    async fn get_events(
        &self,
        mission_id: Uuid,
        event_types: Option<&[&str]>,
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> Result<Vec<StoredEvent>, String> {
        SqliteMissionStore::get_events(self, mission_id, event_types, limit, offset).await
    }
    async fn get_events_since(
        &self,
        mission_id: Uuid,
        since_seq: i64,
        event_types: Option<&[&str]>,
        limit: Option<usize>,
    ) -> Result<Vec<StoredEvent>, String> {
        SqliteMissionStore::get_events_since(self, mission_id, since_seq, event_types, limit).await
    }
    async fn get_events_before(
        &self,
        mission_id: Uuid,
        before_seq: i64,
        event_types: Option<&[&str]>,
        limit: Option<usize>,
    ) -> Result<Vec<StoredEvent>, String> {
        SqliteMissionStore::get_events_before(self, mission_id, before_seq, event_types, limit)
            .await
    }
    async fn get_status_events_global(
        &self,
        before_ts: Option<&str>,
        limit: usize,
    ) -> Result<Vec<StoredEvent>, String> {
        SqliteMissionStore::get_status_events_global(self, before_ts, limit).await
    }
    async fn get_events_for_tool_call(
        &self,
        mission_id: Uuid,
        tool_call_id: &str,
    ) -> Result<Vec<StoredEvent>, String> {
        SqliteMissionStore::get_events_for_tool_call(self, mission_id, tool_call_id).await
    }
    async fn get_recent_tool_call_ids(
        &self,
        mission_id: Uuid,
        limit: usize,
    ) -> Result<Vec<String>, String> {
        SqliteMissionStore::get_recent_tool_call_ids(self, mission_id, limit).await
    }
    async fn get_tool_call_summaries(
        &self,
        mission_id: Uuid,
        tool_call_ids: &[String],
    ) -> Result<HashMap<String, ToolCallSummary>, String> {
        SqliteMissionStore::get_tool_call_summaries(self, mission_id, tool_call_ids).await
    }
    async fn max_event_sequence(&self, mission_id: Uuid) -> Result<i64, String> {
        SqliteMissionStore::max_event_sequence(self, mission_id).await
    }
    async fn nth_recent_event_sequence(
        &self,
        mission_id: Uuid,
        anchor_types: &[&str],
        n: usize,
    ) -> Result<Option<i64>, String> {
        SqliteMissionStore::nth_recent_event_sequence(self, mission_id, anchor_types, n).await
    }
    async fn count_events(
        &self,
        mission_id: Uuid,
        event_types: Option<&[&str]>,
    ) -> Result<usize, String> {
        SqliteMissionStore::count_events(self, mission_id, event_types).await
    }
    async fn count_events_by_type(
        &self,
        mission_id: Uuid,
        event_types: Option<&[&str]>,
    ) -> Result<HashMap<String, usize>, String> {
        SqliteMissionStore::count_events_by_type(self, mission_id, event_types).await
    }
    async fn get_total_cost_cents(&self) -> Result<u64, String> {
        SqliteMissionStore::get_total_cost_cents(self).await
    }
    async fn get_cost_by_source(&self) -> Result<(u64, u64, u64), String> {
        SqliteMissionStore::get_cost_by_source(self).await
    }
    async fn get_total_cost_cents_since(&self, since: &str) -> Result<u64, String> {
        SqliteMissionStore::get_total_cost_cents_since(self, since).await
    }
    async fn get_cost_by_source_since(&self, since: &str) -> Result<(u64, u64, u64), String> {
        SqliteMissionStore::get_cost_by_source_since(self, since).await
    }
    async fn get_usage_by_model(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<ModelUsageStats>, String> {
        SqliteMissionStore::get_usage_by_model(self, since).await
    }
    async fn get_usage_by_day(&self, since: Option<&str>) -> Result<Vec<DailyUsageStats>, String> {
        SqliteMissionStore::get_usage_by_day(self, since).await
    }
    async fn get_usage_by_hour(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<HourlyUsageStats>, String> {
        SqliteMissionStore::get_usage_by_hour(self, since).await
    }
    async fn record_proxy_usage(
        &self,
        model: &str,
        input_tokens: u64,
        output_tokens: u64,
        cost_cents: u64,
    ) -> Result<(), String> {
        SqliteMissionStore::record_proxy_usage(self, model, input_tokens, output_tokens, cost_cents)
            .await
    }
    async fn record_proxy_usage_attributed(
        &self,
        record: &super::ProxyUsageRecord,
    ) -> Result<(), String> {
        SqliteMissionStore::record_proxy_usage_attributed(self, record).await
    }
    async fn get_usage_records(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<super::UsageRecord>, String> {
        SqliteMissionStore::get_usage_records(self, since).await
    }
    async fn get_proxy_usage_by_model(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<ModelUsageStats>, String> {
        SqliteMissionStore::get_proxy_usage_by_model(self, since).await
    }
    async fn get_proxy_usage_by_day(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<DailyUsageStats>, String> {
        SqliteMissionStore::get_proxy_usage_by_day(self, since).await
    }
    async fn get_proxy_usage_by_hour(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<HourlyUsageStats>, String> {
        SqliteMissionStore::get_proxy_usage_by_hour(self, since).await
    }
    async fn record_proxy_outcome(&self, record: &super::ProxyOutcomeRecord) -> Result<(), String> {
        SqliteMissionStore::record_proxy_outcome(self, record).await
    }
    async fn get_proxy_outcomes(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<super::ProxyOutcomeRecord>, String> {
        SqliteMissionStore::get_proxy_outcomes(self, since).await
    }
    async fn create_automation(&self, automation: Automation) -> Result<Automation, String> {
        SqliteMissionStore::create_automation(self, automation).await
    }
    async fn get_mission_automations(&self, mission_id: Uuid) -> Result<Vec<Automation>, String> {
        SqliteMissionStore::get_mission_automations(self, mission_id).await
    }
    async fn list_active_automations(&self) -> Result<Vec<Automation>, String> {
        SqliteMissionStore::list_active_automations(self).await
    }
    async fn get_automation(&self, id: Uuid) -> Result<Option<Automation>, String> {
        SqliteMissionStore::get_automation(self, id).await
    }
    async fn update_automation_active(&self, id: Uuid, active: bool) -> Result<(), String> {
        SqliteMissionStore::update_automation_active(self, id, active).await
    }
    async fn update_automation_last_triggered(&self, id: Uuid) -> Result<(), String> {
        SqliteMissionStore::update_automation_last_triggered(self, id).await
    }
    async fn delete_automation(&self, id: Uuid) -> Result<bool, String> {
        SqliteMissionStore::delete_automation(self, id).await
    }
    async fn update_automation(&self, automation: Automation) -> Result<(), String> {
        SqliteMissionStore::update_automation(self, automation).await
    }
    async fn get_automation_by_webhook_id(
        &self,
        webhook_id: &str,
    ) -> Result<Option<Automation>, String> {
        SqliteMissionStore::get_automation_by_webhook_id(self, webhook_id).await
    }
    async fn create_automation_execution(
        &self,
        execution: AutomationExecution,
    ) -> Result<AutomationExecution, String> {
        SqliteMissionStore::create_automation_execution(self, execution).await
    }
    async fn update_automation_execution(
        &self,
        execution: AutomationExecution,
    ) -> Result<(), String> {
        SqliteMissionStore::update_automation_execution(self, execution).await
    }
    async fn stage_scheduled_delivery(
        &self,
        automation: &Automation,
        execution: AutomationExecution,
    ) -> Result<bool, String> {
        SqliteMissionStore::stage_scheduled_delivery(self, automation, execution).await
    }
    async fn list_scheduled_deliveries(&self) -> Result<Vec<AutomationExecution>, String> {
        SqliteMissionStore::list_scheduled_deliveries(self).await
    }
    async fn can_admit_scheduled_delivery(&self, mission: Uuid, id: Uuid) -> Result<bool, String> {
        SqliteMissionStore::can_admit_scheduled_delivery(self, mission, id).await
    }
    async fn fence_mission_wakeups(&self, mission: Uuid) -> Result<(), String> {
        SqliteMissionStore::fence_mission_wakeups(self, mission).await
    }
    async fn wakeup_creation_allowed(
        &self,
        mission: Uuid,
        generation: u64,
    ) -> Result<bool, String> {
        SqliteMissionStore::wakeup_creation_allowed(self, mission, generation).await
    }
    async fn cancel_mission_continuations(&self, mission: Uuid) -> Result<(), String> {
        SqliteMissionStore::cancel_mission_continuations(self, mission).await
    }
    async fn cancel_mission_continuations_through(
        &self,
        mission: Uuid,
        generation: u64,
    ) -> Result<(), String> {
        SqliteMissionStore::cancel_mission_continuations_through(self, mission, generation).await
    }
    async fn cancel_scheduled_delivery(&self, id: Uuid) -> Result<(), String> {
        SqliteMissionStore::cancel_scheduled_delivery(self, id).await
    }
    async fn get_automation_executions(
        &self,
        automation_id: Uuid,
        limit: Option<usize>,
    ) -> Result<Vec<AutomationExecution>, String> {
        SqliteMissionStore::get_automation_executions(self, automation_id, limit).await
    }
    async fn get_mission_automation_executions(
        &self,
        mission_id: Uuid,
        limit: Option<usize>,
    ) -> Result<Vec<AutomationExecution>, String> {
        SqliteMissionStore::get_mission_automation_executions(self, mission_id, limit).await
    }
    async fn complete_turn_executions_for_mission(
        &self,
        mission_id: Uuid,
        occurrence: Option<Uuid>,
        success: bool,
        error: Option<String>,
    ) -> Result<u32, String> {
        SqliteMissionStore::complete_turn_executions_for_mission(
            self, mission_id, occurrence, success, error,
        )
        .await
    }
    async fn bind_scheduled_remote_job(
        &self,
        mission: Uuid,
        message: Option<Uuid>,
        previous_job: Uuid,
        job: Uuid,
    ) -> Result<u32, String> {
        SqliteMissionStore::bind_scheduled_remote_job(self, mission, message, previous_job, job)
            .await
    }
    async fn scheduled_remote_delivery(
        &self,
        mission: Uuid,
        message: Uuid,
    ) -> Result<Option<(Uuid, bool)>, String> {
        SqliteMissionStore::scheduled_remote_delivery(self, mission, message).await
    }
    async fn complete_scheduled_remote_job(
        &self,
        mission: Uuid,
        job: Uuid,
        success: Option<bool>,
        error: Option<String>,
    ) -> Result<u32, String> {
        SqliteMissionStore::complete_scheduled_remote_job(self, mission, job, success, error).await
    }
    async fn handoff_scheduled_executions(
        &self,
        mission: Uuid,
        from: Vec<Uuid>,
        to: Uuid,
    ) -> Result<u32, String> {
        SqliteMissionStore::handoff_scheduled_executions(self, mission, from, to).await
    }
    async fn update_mission_mode(&self, id: Uuid, mode: MissionMode) -> Result<(), String> {
        SqliteMissionStore::update_mission_mode(self, id, mode).await
    }
    async fn list_assistant_missions(&self) -> Result<Vec<Mission>, String> {
        SqliteMissionStore::list_assistant_missions(self).await
    }
    async fn create_telegram_channel(
        &self,
        channel: TelegramChannel,
    ) -> Result<TelegramChannel, String> {
        SqliteMissionStore::create_telegram_channel(self, channel).await
    }
    async fn get_telegram_channel(&self, id: Uuid) -> Result<Option<TelegramChannel>, String> {
        SqliteMissionStore::get_telegram_channel(self, id).await
    }
    async fn list_telegram_channels(
        &self,
        mission_id: Uuid,
    ) -> Result<Vec<TelegramChannel>, String> {
        SqliteMissionStore::list_telegram_channels(self, mission_id).await
    }
    async fn list_all_active_telegram_channels(&self) -> Result<Vec<TelegramChannel>, String> {
        SqliteMissionStore::list_all_active_telegram_channels(self).await
    }
    async fn update_telegram_channel(&self, channel: TelegramChannel) -> Result<(), String> {
        SqliteMissionStore::update_telegram_channel(self, channel).await
    }
    async fn delete_telegram_channel(&self, id: Uuid) -> Result<bool, String> {
        SqliteMissionStore::delete_telegram_channel(self, id).await
    }
    async fn list_all_telegram_channels(&self) -> Result<Vec<TelegramChannel>, String> {
        SqliteMissionStore::list_all_telegram_channels(self).await
    }
    async fn upsert_telegram_user(&self, user: TelegramUser) -> Result<TelegramUser, String> {
        SqliteMissionStore::upsert_telegram_user(self, user).await
    }
    async fn get_telegram_user(
        &self,
        telegram_user_id: i64,
    ) -> Result<Option<TelegramUser>, String> {
        SqliteMissionStore::get_telegram_user(self, telegram_user_id).await
    }
    async fn get_or_create_telegram_user_cursor(
        &self,
        telegram_user_id: i64,
    ) -> Result<TelegramUserCursor, String> {
        SqliteMissionStore::get_or_create_telegram_user_cursor(self, telegram_user_id).await
    }
    async fn update_telegram_user_last_status_at(
        &self,
        telegram_user_id: i64,
        last_status_at: &str,
        last_seen_event_sequence_by_mission_json: &str,
    ) -> Result<(), String> {
        SqliteMissionStore::update_telegram_user_last_status_at(
            self,
            telegram_user_id,
            last_status_at,
            last_seen_event_sequence_by_mission_json,
        )
        .await
    }
    async fn update_telegram_user_last_digest_at(
        &self,
        telegram_user_id: i64,
        last_digest_at: &str,
    ) -> Result<(), String> {
        SqliteMissionStore::update_telegram_user_last_digest_at(
            self,
            telegram_user_id,
            last_digest_at,
        )
        .await
    }
    async fn update_telegram_user_last_alert_ack_at(
        &self,
        telegram_user_id: i64,
        last_alert_ack_at: &str,
    ) -> Result<(), String> {
        SqliteMissionStore::update_telegram_user_last_alert_ack_at(
            self,
            telegram_user_id,
            last_alert_ack_at,
        )
        .await
    }
    async fn upsert_telegram_mission_subscription(
        &self,
        subscription: TelegramMissionSubscription,
    ) -> Result<TelegramMissionSubscription, String> {
        SqliteMissionStore::upsert_telegram_mission_subscription(self, subscription).await
    }
    async fn list_telegram_mission_subscriptions(
        &self,
        telegram_user_id: i64,
    ) -> Result<Vec<TelegramMissionSubscription>, String> {
        SqliteMissionStore::list_telegram_mission_subscriptions(self, telegram_user_id).await
    }
    async fn create_telegram_alert_preference(
        &self,
        preference: TelegramAlertPreference,
    ) -> Result<TelegramAlertPreference, String> {
        SqliteMissionStore::create_telegram_alert_preference(self, preference).await
    }
    async fn list_telegram_alert_preferences(
        &self,
        telegram_user_id: i64,
    ) -> Result<Vec<TelegramAlertPreference>, String> {
        SqliteMissionStore::list_telegram_alert_preferences(self, telegram_user_id).await
    }
    async fn create_telegram_alert_if_absent(
        &self,
        alert: TelegramAlert,
    ) -> Result<Option<TelegramAlert>, String> {
        SqliteMissionStore::create_telegram_alert_if_absent(self, alert).await
    }
    async fn list_pending_telegram_alerts(
        &self,
        telegram_user_id: i64,
        limit: usize,
    ) -> Result<Vec<TelegramAlert>, String> {
        SqliteMissionStore::list_pending_telegram_alerts(self, telegram_user_id, limit).await
    }
    async fn list_telegram_alerts_for_missions(
        &self,
        mission_ids: &[Uuid],
    ) -> Result<Vec<TelegramAlert>, String> {
        SqliteMissionStore::list_telegram_alerts_for_missions(self, mission_ids).await
    }
    async fn mark_telegram_alert_sent(
        &self,
        id: Uuid,
        telegram_message_id: Option<i64>,
        sent_at: &str,
    ) -> Result<(), String> {
        SqliteMissionStore::mark_telegram_alert_sent(self, id, telegram_message_id, sent_at).await
    }
    async fn get_telegram_alert_by_message_id(
        &self,
        telegram_user_id: i64,
        telegram_message_id: i64,
    ) -> Result<Option<TelegramAlert>, String> {
        SqliteMissionStore::get_telegram_alert_by_message_id(
            self,
            telegram_user_id,
            telegram_message_id,
        )
        .await
    }
    async fn acknowledge_pending_telegram_alerts_for_mission(
        &self,
        telegram_user_id: i64,
        mission_id: Uuid,
        acknowledged_at: &str,
    ) -> Result<usize, String> {
        SqliteMissionStore::acknowledge_pending_telegram_alerts_for_mission(
            self,
            telegram_user_id,
            mission_id,
            acknowledged_at,
        )
        .await
    }
    async fn acknowledge_pending_telegram_alert(
        &self,
        telegram_user_id: i64,
        alert_id: Uuid,
        acknowledged_at: &str,
    ) -> Result<bool, String> {
        SqliteMissionStore::acknowledge_pending_telegram_alert(
            self,
            telegram_user_id,
            alert_id,
            acknowledged_at,
        )
        .await
    }
    async fn mark_telegram_alert_failed(&self, id: Uuid, error: &str) -> Result<(), String> {
        SqliteMissionStore::mark_telegram_alert_failed(self, id, error).await
    }
    async fn recover_stale_telegram_alerts(
        &self,
        before: &str,
        limit: usize,
    ) -> Result<usize, String> {
        SqliteMissionStore::recover_stale_telegram_alerts(self, before, limit).await
    }
    async fn create_paloma_decision(
        &self,
        decision: PalomaDecision,
    ) -> Result<PalomaDecision, String> {
        SqliteMissionStore::create_paloma_decision(self, decision).await
    }
    async fn list_paloma_decisions(&self, limit: usize) -> Result<Vec<PalomaDecision>, String> {
        SqliteMissionStore::list_paloma_decisions(self, limit).await
    }
    async fn claim_paloma_scheduler_job(
        &self,
        name: &str,
        lease_owner: &str,
        now: &str,
        lease_expires_at: &str,
    ) -> Result<bool, String> {
        SqliteMissionStore::claim_paloma_scheduler_job(
            self,
            name,
            lease_owner,
            now,
            lease_expires_at,
        )
        .await
    }
    async fn finish_paloma_scheduler_job(
        &self,
        name: &str,
        lease_owner: &str,
        finished_at: &str,
        error: Option<&str>,
    ) -> Result<(), String> {
        SqliteMissionStore::finish_paloma_scheduler_job(self, name, lease_owner, finished_at, error)
            .await
    }
    async fn list_paloma_scheduler_jobs(&self) -> Result<Vec<PalomaSchedulerJob>, String> {
        SqliteMissionStore::list_paloma_scheduler_jobs(self).await
    }
    async fn get_paloma_mission_card(
        &self,
        mission_id: Uuid,
    ) -> Result<Option<PalomaMissionCard>, String> {
        SqliteMissionStore::get_paloma_mission_card(self, mission_id).await
    }
    async fn upsert_paloma_mission_card(
        &self,
        card: PalomaMissionCard,
    ) -> Result<PalomaMissionCard, String> {
        SqliteMissionStore::upsert_paloma_mission_card(self, card).await
    }
    async fn touch_paloma_mission_card(
        &self,
        mission_id: Uuid,
        content_hash: &str,
        last_edit_ts: &str,
    ) -> Result<(), String> {
        SqliteMissionStore::touch_paloma_mission_card(self, mission_id, content_hash, last_edit_ts)
            .await
    }
    async fn archive_paloma_mission_card(&self, mission_id: Uuid) -> Result<(), String> {
        SqliteMissionStore::archive_paloma_mission_card(self, mission_id).await
    }
    async fn list_active_paloma_mission_cards(
        &self,
        telegram_user_id: i64,
    ) -> Result<Vec<PalomaMissionCard>, String> {
        SqliteMissionStore::list_active_paloma_mission_cards(self, telegram_user_id).await
    }
    async fn get_paloma_cooldown_state(
        &self,
        telegram_user_id: i64,
        mission_id: Uuid,
        alert_class: &str,
    ) -> Result<Option<PalomaCooldownState>, String> {
        SqliteMissionStore::get_paloma_cooldown_state(
            self,
            telegram_user_id,
            mission_id,
            alert_class,
        )
        .await
    }
    async fn upsert_paloma_cooldown_state(
        &self,
        state: PalomaCooldownState,
    ) -> Result<PalomaCooldownState, String> {
        SqliteMissionStore::upsert_paloma_cooldown_state(self, state).await
    }
    async fn reset_paloma_cooldown_for_mission(&self, mission_id: Uuid) -> Result<(), String> {
        SqliteMissionStore::reset_paloma_cooldown_for_mission(self, mission_id).await
    }
    async fn get_paloma_user_preferences(
        &self,
        telegram_user_id: i64,
    ) -> Result<Option<PalomaUserPreferences>, String> {
        SqliteMissionStore::get_paloma_user_preferences(self, telegram_user_id).await
    }
    async fn upsert_paloma_user_preferences(
        &self,
        preferences: PalomaUserPreferences,
    ) -> Result<PalomaUserPreferences, String> {
        SqliteMissionStore::upsert_paloma_user_preferences(self, preferences).await
    }
    async fn refresh_pending_telegram_alert_body(
        &self,
        telegram_user_id: i64,
        mission_id: Uuid,
        event_kind: &str,
        title: &str,
        body: &str,
        importance: &str,
    ) -> Result<bool, String> {
        SqliteMissionStore::refresh_pending_telegram_alert_body(
            self,
            telegram_user_id,
            mission_id,
            event_kind,
            title,
            body,
            importance,
        )
        .await
    }
    async fn count_paloma_sent_alerts_since(
        &self,
        telegram_user_id: i64,
        since: &str,
    ) -> Result<i64, String> {
        SqliteMissionStore::count_paloma_sent_alerts_since(self, telegram_user_id, since).await
    }
    async fn consolidate_telegram_structured_memory(
        &self,
        channel_id: Uuid,
        limit: usize,
    ) -> Result<usize, String> {
        SqliteMissionStore::consolidate_telegram_structured_memory(self, channel_id, limit).await
    }
    async fn get_telegram_chat_mission(
        &self,
        channel_id: Uuid,
        chat_id: i64,
    ) -> Result<Option<TelegramChatMission>, String> {
        SqliteMissionStore::get_telegram_chat_mission(self, channel_id, chat_id).await
    }
    async fn create_telegram_chat_mission(
        &self,
        mapping: TelegramChatMission,
    ) -> Result<TelegramChatMission, String> {
        SqliteMissionStore::create_telegram_chat_mission(self, mapping).await
    }
    async fn update_telegram_chat_mission_title(
        &self,
        channel_id: Uuid,
        chat_id: i64,
        chat_title: Option<String>,
    ) -> Result<(), String> {
        SqliteMissionStore::update_telegram_chat_mission_title(
            self, channel_id, chat_id, chat_title,
        )
        .await
    }
    async fn get_telegram_chat_mission_by_mission_id(
        &self,
        mission_id: Uuid,
    ) -> Result<Option<TelegramChatMission>, String> {
        SqliteMissionStore::get_telegram_chat_mission_by_mission_id(self, mission_id).await
    }
    async fn list_telegram_chat_missions(
        &self,
        channel_id: Uuid,
    ) -> Result<Vec<TelegramChatMission>, String> {
        SqliteMissionStore::list_telegram_chat_missions(self, channel_id).await
    }
    async fn create_telegram_scheduled_message(
        &self,
        message: TelegramScheduledMessage,
    ) -> Result<TelegramScheduledMessage, String> {
        SqliteMissionStore::create_telegram_scheduled_message(self, message).await
    }
    async fn list_due_telegram_scheduled_messages(
        &self,
        channel_id: Uuid,
        send_at: &str,
        limit: usize,
    ) -> Result<Vec<TelegramScheduledMessage>, String> {
        SqliteMissionStore::list_due_telegram_scheduled_messages(self, channel_id, send_at, limit)
            .await
    }
    async fn list_telegram_scheduled_messages(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        limit: usize,
    ) -> Result<Vec<TelegramScheduledMessage>, String> {
        SqliteMissionStore::list_telegram_scheduled_messages(self, channel_id, chat_id, limit).await
    }
    async fn claim_telegram_scheduled_message(&self, id: Uuid) -> Result<bool, String> {
        SqliteMissionStore::claim_telegram_scheduled_message(self, id).await
    }
    async fn recover_stale_sending_scheduled_messages(
        &self,
        max_age_secs: i64,
    ) -> Result<u32, String> {
        SqliteMissionStore::recover_stale_sending_scheduled_messages(self, max_age_secs).await
    }
    async fn mark_telegram_scheduled_message_sent(
        &self,
        id: Uuid,
        sent_at: &str,
    ) -> Result<(), String> {
        SqliteMissionStore::mark_telegram_scheduled_message_sent(self, id, sent_at).await
    }
    async fn mark_telegram_scheduled_message_failed(
        &self,
        id: Uuid,
        error: &str,
    ) -> Result<(), String> {
        SqliteMissionStore::mark_telegram_scheduled_message_failed(self, id, error).await
    }
    async fn upsert_telegram_structured_memory(
        &self,
        entry: TelegramStructuredMemoryEntry,
    ) -> Result<TelegramStructuredMemoryEntry, String> {
        SqliteMissionStore::upsert_telegram_structured_memory(self, entry).await
    }
    async fn list_telegram_structured_memory(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        subject_user_id: Option<i64>,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemoryEntry>, String> {
        SqliteMissionStore::list_telegram_structured_memory(
            self,
            channel_id,
            chat_id,
            subject_user_id,
            limit,
        )
        .await
    }
    async fn search_telegram_structured_memory(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        query: &str,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemoryEntry>, String> {
        SqliteMissionStore::search_telegram_structured_memory(
            self, channel_id, chat_id, query, limit,
        )
        .await
    }
    async fn search_telegram_structured_memory_hybrid(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        subject_user_id: Option<i64>,
        query: &str,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemorySearchHit>, String> {
        SqliteMissionStore::search_telegram_structured_memory_hybrid(
            self,
            channel_id,
            chat_id,
            subject_user_id,
            query,
            limit,
        )
        .await
    }
    async fn list_telegram_memory_context(
        &self,
        channel_id: Uuid,
        chat_id: i64,
        subject_user_id: Option<i64>,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemoryEntry>, String> {
        SqliteMissionStore::list_telegram_memory_context(
            self,
            channel_id,
            chat_id,
            subject_user_id,
            limit,
        )
        .await
    }
    async fn search_telegram_memory_context(
        &self,
        channel_id: Uuid,
        chat_id: i64,
        subject_user_id: Option<i64>,
        query: &str,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemoryEntry>, String> {
        SqliteMissionStore::search_telegram_memory_context(
            self,
            channel_id,
            chat_id,
            subject_user_id,
            query,
            limit,
        )
        .await
    }
    async fn create_telegram_action_execution(
        &self,
        execution: TelegramActionExecution,
    ) -> Result<TelegramActionExecution, String> {
        SqliteMissionStore::create_telegram_action_execution(self, execution).await
    }
    async fn list_telegram_action_executions(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        limit: usize,
    ) -> Result<Vec<TelegramActionExecution>, String> {
        SqliteMissionStore::list_telegram_action_executions(self, channel_id, chat_id, limit).await
    }
    async fn mark_telegram_action_execution_by_scheduled_message(
        &self,
        scheduled_message_id: Uuid,
        status: TelegramActionExecutionStatus,
        last_error: Option<&str>,
        updated_at: &str,
    ) -> Result<(), String> {
        SqliteMissionStore::mark_telegram_action_execution_by_scheduled_message(
            self,
            scheduled_message_id,
            status,
            last_error,
            updated_at,
        )
        .await
    }
    async fn upsert_telegram_conversation(
        &self,
        conversation: TelegramConversation,
    ) -> Result<TelegramConversation, String> {
        SqliteMissionStore::upsert_telegram_conversation(self, conversation).await
    }
    async fn get_telegram_conversation_by_chat(
        &self,
        channel_id: Uuid,
        chat_id: i64,
    ) -> Result<Option<TelegramConversation>, String> {
        SqliteMissionStore::get_telegram_conversation_by_chat(self, channel_id, chat_id).await
    }
    async fn list_telegram_conversations(
        &self,
        channel_id: Uuid,
        limit: usize,
    ) -> Result<Vec<TelegramConversation>, String> {
        SqliteMissionStore::list_telegram_conversations(self, channel_id, limit).await
    }
    async fn create_telegram_conversation_message(
        &self,
        message: TelegramConversationMessage,
    ) -> Result<TelegramConversationMessage, String> {
        SqliteMissionStore::create_telegram_conversation_message(self, message).await
    }
    async fn list_telegram_conversation_messages(
        &self,
        conversation_id: Uuid,
        limit: usize,
    ) -> Result<Vec<TelegramConversationMessage>, String> {
        SqliteMissionStore::list_telegram_conversation_messages(self, conversation_id, limit).await
    }
    async fn create_telegram_workflow(
        &self,
        workflow: TelegramWorkflow,
    ) -> Result<TelegramWorkflow, String> {
        SqliteMissionStore::create_telegram_workflow(self, workflow).await
    }
    async fn update_telegram_workflow(&self, workflow: TelegramWorkflow) -> Result<(), String> {
        SqliteMissionStore::update_telegram_workflow(self, workflow).await
    }
    async fn timeout_stale_telegram_workflows(&self, max_age_secs: i64) -> Result<u32, String> {
        SqliteMissionStore::timeout_stale_telegram_workflows(self, max_age_secs).await
    }
    async fn register_webhook_update(
        &self,
        channel_id: Uuid,
        update_id: i64,
    ) -> Result<bool, String> {
        SqliteMissionStore::register_webhook_update(self, channel_id, update_id).await
    }
    async fn cleanup_webhook_dedup(&self, max_age_secs: i64) -> Result<u32, String> {
        SqliteMissionStore::cleanup_webhook_dedup(self, max_age_secs).await
    }
    async fn list_telegram_workflows(
        &self,
        channel_id: Uuid,
        limit: usize,
    ) -> Result<Vec<TelegramWorkflow>, String> {
        SqliteMissionStore::list_telegram_workflows(self, channel_id, limit).await
    }
    async fn get_pending_telegram_workflow_for_target_chat(
        &self,
        channel_id: Uuid,
        target_chat_id: i64,
    ) -> Result<Option<TelegramWorkflow>, String> {
        SqliteMissionStore::get_pending_telegram_workflow_for_target_chat(
            self,
            channel_id,
            target_chat_id,
        )
        .await
    }
    async fn get_pending_telegram_workflow_for_target_message(
        &self,
        channel_id: Uuid,
        target_chat_id: i64,
        request_message_id: i64,
    ) -> Result<Option<TelegramWorkflow>, String> {
        SqliteMissionStore::get_pending_telegram_workflow_for_target_message(
            self,
            channel_id,
            target_chat_id,
            request_message_id,
        )
        .await
    }
    async fn create_telegram_workflow_event(
        &self,
        event: TelegramWorkflowEvent,
    ) -> Result<TelegramWorkflowEvent, String> {
        SqliteMissionStore::create_telegram_workflow_event(self, event).await
    }
    async fn list_telegram_workflow_events(
        &self,
        workflow_id: Uuid,
        limit: usize,
    ) -> Result<Vec<TelegramWorkflowEvent>, String> {
        SqliteMissionStore::list_telegram_workflow_events(self, workflow_id, limit).await
    }
    async fn import_mission_bundle(
        &self,
        bundle: super::MissionBundle,
        options: super::MissionImportOptions,
    ) -> Result<Uuid, String> {
        SqliteMissionStore::import_mission_bundle(self, bundle, options).await
    }
    async fn upsert_board_tasks(
        &self,
        boss_mission_id: Uuid,
        tasks: Vec<NewBoardTask>,
    ) -> Result<Vec<BoardTask>, String> {
        SqliteMissionStore::upsert_board_tasks(self, boss_mission_id, tasks).await
    }
    async fn list_board_tasks(&self, boss_mission_id: Uuid) -> Result<Vec<BoardTask>, String> {
        SqliteMissionStore::list_board_tasks(self, boss_mission_id).await
    }
    async fn list_board_tasks_for_project(&self, project: &str) -> Result<Vec<BoardTask>, String> {
        SqliteMissionStore::list_board_tasks_for_project(self, project).await
    }
    async fn list_active_board_missions(&self) -> Result<Vec<Uuid>, String> {
        SqliteMissionStore::list_active_board_missions(self).await
    }
    async fn get_board_task(&self, task_id: Uuid) -> Result<Option<BoardTask>, String> {
        SqliteMissionStore::get_board_task(self, task_id).await
    }
    async fn get_board_task_by_worker(
        &self,
        worker_mission_id: Uuid,
    ) -> Result<Option<BoardTask>, String> {
        SqliteMissionStore::get_board_task_by_worker(self, worker_mission_id).await
    }
    async fn save_board_task(&self, task: &BoardTask) -> Result<(), String> {
        SqliteMissionStore::save_board_task(self, task).await
    }
    async fn create_task_attempt(&self, attempt: TaskAttempt) -> Result<TaskAttempt, String> {
        SqliteMissionStore::create_task_attempt(self, attempt).await
    }
    async fn finish_task_attempt(
        &self,
        task_id: Uuid,
        attempt_number: u32,
        terminal_class: &str,
        commit_sha: Option<&str>,
        changed_files: &[String],
        verification_evidence: &serde_json::Value,
        cost_cents: Option<i64>,
    ) -> Result<(), String> {
        SqliteMissionStore::finish_task_attempt(
            self,
            task_id,
            attempt_number,
            terminal_class,
            commit_sha,
            changed_files,
            verification_evidence,
            cost_cents,
        )
        .await
    }
    async fn list_task_attempts(&self, task_id: Uuid) -> Result<Vec<TaskAttempt>, String> {
        SqliteMissionStore::list_task_attempts(self, task_id).await
    }
    async fn enqueue_board_outbox(&self, item: BoardOutboxItem) -> Result<BoardOutboxItem, String> {
        SqliteMissionStore::enqueue_board_outbox(self, item).await
    }
    async fn acknowledge_board_outbox(&self, idempotency_key: &str) -> Result<(), String> {
        SqliteMissionStore::acknowledge_board_outbox(self, idempotency_key).await
    }
    async fn pending_client_delivery_ids(&self) -> Result<Vec<Uuid>, String> {
        SqliteMissionStore::pending_client_delivery_ids(self).await
    }
    async fn list_pending_board_outbox_filtered(
        &self,
        limit: usize,
        client: Option<bool>,
    ) -> Result<Vec<BoardOutboxItem>, String> {
        SqliteMissionStore::list_pending_board_outbox_filtered(self, limit, client).await
    }
    async fn search_index_coverage(&self) -> Result<super::SearchIndexCoverage, String> {
        SqliteMissionStore::search_index_coverage_sqlite(self).await
    }
    async fn search_conversations(
        &self,
        query: &super::ConversationSearchQuery,
    ) -> Result<super::ConversationSearchResponse, String> {
        SqliteMissionStore::search_conversations_sqlite(self, query).await
    }
    async fn get_passage_context(
        &self,
        mission_id: Uuid,
        params: &super::PassageContextQuery,
    ) -> Result<Option<super::PassageContextResponse>, String> {
        SqliteMissionStore::get_passage_context_sqlite(self, mission_id, params).await
    }
}
