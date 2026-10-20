//! SQLite-based mission store with full event logging.
#[path = "sqlite_cloud.rs"]
mod cloud;
#[cfg(test)]
mod filter_tests;
#[cfg(test)]
mod id_prefix_tests;
#[path = "sqlite_transfer.rs"]
mod machine_transfer;
#[path = "sqlite_client_link.rs"]
mod sqlite_client_link;
#[path = "sqlite_local_origin.rs"]
mod sqlite_local_origin;
#[path = "sqlite_usage.rs"]
mod usage;
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

fn usage_cost_with_read_side_estimate(
    model: &str,
    stored_cost_cents: u64,
    cost_source: &str,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
) -> u64 {
    if stored_cost_cents > 0 && cost_source == "actual" {
        return stored_cost_cents;
    }
    let estimated = crate::cost::cost_cents_from_usage(
        model,
        &crate::cost::TokenUsage {
            input_tokens,
            output_tokens,
            cache_creation_input_tokens: Some(cache_creation_tokens),
            cache_read_input_tokens: Some(cache_read_tokens),
        },
    );
    if estimated > 0 {
        return estimated;
    }
    stored_cost_cents
}

fn usage_model_key(raw_model: &str, stored_normalized_model: &str) -> String {
    let raw_model = raw_model.trim();
    if !raw_model.is_empty() {
        return crate::cost::normalized_model(raw_model);
    }
    stored_normalized_model.trim().to_string()
}

#[derive(serde::Serialize)]
struct AssistantCostMetadata {
    amount_cents: u64,
    currency: &'static str,
    source: crate::agents::CostSource,
}

#[derive(serde::Serialize)]
struct AssistantMessageMetadata {
    success: bool,
    cost_cents: u64,
    cost: AssistantCostMetadata,
    #[serde(skip_serializing_if = "Option::is_none")]
    usage: Option<crate::cost::TokenUsage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model_normalized: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    shared_files: Option<Vec<crate::api::control::SharedFile>>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    resumable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    completion_evidence: Option<crate::agents::CompletionEvidence>,
}

struct AssistantMessageMetadataInput<'a> {
    success: bool,
    cost_cents: u64,
    cost_source: crate::agents::CostSource,
    usage: &'a Option<crate::cost::TokenUsage>,
    model: &'a Option<String>,
    model_normalized: &'a Option<String>,
    shared_files: &'a Option<Vec<crate::api::control::SharedFile>>,
    resumable: bool,
    completion_evidence: &'a Option<crate::agents::CompletionEvidence>,
}

fn assistant_message_metadata(input: AssistantMessageMetadataInput<'_>) -> serde_json::Value {
    let metadata = AssistantMessageMetadata {
        success: input.success,
        cost_cents: input.cost_cents,
        cost: AssistantCostMetadata {
            amount_cents: input.cost_cents,
            currency: COST_CURRENCY_USD,
            source: input.cost_source,
        },
        usage: input.usage.clone(),
        model: input.model.clone(),
        model_normalized: input.model_normalized.clone(),
        shared_files: input.shared_files.clone(),
        resumable: input.resumable,
        completion_evidence: input.completion_evidence.clone(),
    };
    serde_json::to_value(metadata).expect("assistant metadata should serialize")
}

fn fold_search_char(ch: char) -> char {
    match ch {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' => 'a',
        'ç' => 'c',
        'è' | 'é' | 'ê' | 'ë' => 'e',
        'ì' | 'í' | 'î' | 'ï' => 'i',
        'ñ' => 'n',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' => 'o',
        'ù' | 'ú' | 'û' | 'ü' => 'u',
        'ý' | 'ÿ' => 'y',
        _ => ch,
    }
}

fn normalize_search_text(value: &str) -> String {
    let mut normalized = String::with_capacity(value.len());
    let mut prev_space = true;
    for ch in value.chars().flat_map(|ch| ch.to_lowercase()) {
        let folded = fold_search_char(ch);
        if folded.is_ascii_alphanumeric() {
            normalized.push(folded);
            prev_space = false;
        } else if !prev_space {
            normalized.push(' ');
            prev_space = true;
        }
    }
    normalized.trim().to_string()
}

fn tokenize_search_text(value: &str) -> Vec<String> {
    normalize_search_text(value)
        .split_whitespace()
        .filter(|token| token.len() >= 2 && !TELEGRAM_MEMORY_SEARCH_STOPWORDS.contains(token))
        .map(ToOwned::to_owned)
        .collect()
}

fn build_telegram_memory_search_text(entry: &TelegramStructuredMemoryEntry) -> String {
    let mut parts = Vec::new();
    if let Some(label) = entry.label.as_deref() {
        parts.push(label);
    }
    parts.push(entry.value.as_str());
    if let Some(display_name) = entry.subject_display_name.as_deref() {
        parts.push(display_name);
    }
    if let Some(username) = entry.subject_username.as_deref() {
        parts.push(username);
    }
    match entry.kind {
        TelegramStructuredMemoryKind::Fact => parts.push("fact"),
        TelegramStructuredMemoryKind::Preference => parts.push("preference"),
        TelegramStructuredMemoryKind::Task => parts.push("task"),
        TelegramStructuredMemoryKind::Note => parts.push("note"),
    }
    normalize_search_text(&parts.join(" "))
}

fn build_fts_query_from_tokens(tokens: &[String], normalized_query: &str) -> Option<String> {
    if !tokens.is_empty() {
        return Some(
            tokens
                .iter()
                .map(|token| format!("\"{}\"*", token.replace('"', "\"\"")))
                .collect::<Vec<_>>()
                .join(" "),
        );
    }

    if normalized_query.is_empty() {
        None
    } else {
        Some(format!("\"{}\"", normalized_query.replace('"', "\"\"")))
    }
}

fn scope_rank(scope: &TelegramStructuredMemoryScope) -> i32 {
    match scope {
        TelegramStructuredMemoryScope::User => 0,
        TelegramStructuredMemoryScope::Chat => 1,
        TelegramStructuredMemoryScope::Channel => 2,
    }
}

fn scope_score(scope: &TelegramStructuredMemoryScope) -> f64 {
    match scope {
        TelegramStructuredMemoryScope::User => 6.0,
        TelegramStructuredMemoryScope::Chat => 5.0,
        TelegramStructuredMemoryScope::Channel => 3.0,
    }
}

fn recency_score(updated_at: &str) -> f64 {
    let Ok(updated_at) = chrono::DateTime::parse_from_rfc3339(updated_at) else {
        return 0.0;
    };
    let age_hours = (Utc::now() - updated_at.with_timezone(&Utc))
        .num_hours()
        .max(0) as f64;
    if age_hours <= 24.0 {
        4.0
    } else if age_hours <= 24.0 * 7.0 {
        2.0
    } else if age_hours <= 24.0 * 30.0 {
        1.0
    } else {
        0.0
    }
}

fn score_memory_entry(
    entry: &TelegramStructuredMemoryEntry,
    normalized_query: &str,
    core_query: &str,
    query_tokens: &[String],
    fts_score: Option<f64>,
) -> Option<TelegramStructuredMemorySearchHit> {
    if normalized_query.is_empty() {
        return None;
    }

    let normalized_label = entry
        .label
        .as_deref()
        .map(normalize_search_text)
        .unwrap_or_default();
    let normalized_value = normalize_search_text(&entry.value);
    let normalized_subject = normalize_search_text(
        &[
            entry.subject_display_name.as_deref().unwrap_or_default(),
            entry.subject_username.as_deref().unwrap_or_default(),
        ]
        .join(" "),
    );
    let search_text = build_telegram_memory_search_text(entry);
    let entry_tokens: HashSet<String> = tokenize_search_text(&search_text).into_iter().collect();

    let mut score = 0.0;
    let mut reasons = Vec::new();
    let mut matched_terms = Vec::new();

    if !core_query.is_empty() {
        if !normalized_label.is_empty() && normalized_label == core_query {
            score += 95.0;
            reasons.push("exact_core_label".to_string());
        } else if !normalized_label.is_empty() && normalized_label.contains(core_query) {
            score += 48.0;
            reasons.push("label_contains_core_query".to_string());
        }

        if normalized_value == core_query {
            score += 80.0;
            reasons.push("exact_core_value".to_string());
        } else if normalized_value.contains(core_query) {
            score += 42.0;
            reasons.push("value_contains_core_query".to_string());
        }
    }

    if !normalized_label.is_empty() && normalized_label == normalized_query {
        score += 80.0;
        reasons.push("exact_label".to_string());
    } else if !normalized_label.is_empty() && normalized_label.contains(normalized_query) {
        score += 40.0;
        reasons.push("label_contains_query".to_string());
    }

    if normalized_value == normalized_query {
        score += 70.0;
        reasons.push("exact_value".to_string());
    } else if normalized_value.contains(normalized_query) {
        score += 35.0;
        reasons.push("value_contains_query".to_string());
    }

    if !normalized_subject.is_empty() && normalized_subject.contains(normalized_query) {
        score += 24.0;
        reasons.push("subject_contains_query".to_string());
    }

    if !normalized_label.is_empty()
        && normalized_label.split_whitespace().count() == 1
        && TELEGRAM_MEMORY_SEARCH_STOPWORDS.contains(&normalized_label.as_str())
    {
        score -= 36.0;
        reasons.push("suspicious_label".to_string());
    }

    let mut token_matches = 0usize;
    for token in query_tokens {
        if entry_tokens.contains(token) {
            token_matches += 1;
            matched_terms.push(token.clone());
        }
    }
    if token_matches > 0 {
        let ratio = token_matches as f64 / query_tokens.len().max(1) as f64;
        score += 30.0 * ratio;
        reasons.push("token_overlap".to_string());
    }

    if let Some(fts_score) = fts_score {
        score += fts_score;
        reasons.push("full_text".to_string());
    }

    // Require at least one relevance signal (token overlap or FTS match)
    // before adding scope/recency bonuses. Without this gate, every
    // candidate receives a positive base score from scope+recency alone.
    if score <= 0.0 {
        return None;
    }

    score += scope_score(&entry.scope);
    score += recency_score(&entry.updated_at);

    matched_terms.sort();
    matched_terms.dedup();
    reasons.sort();
    reasons.dedup();

    Some(TelegramStructuredMemorySearchHit {
        entry: entry.clone(),
        score,
        matched_terms,
        reasons,
    })
}

/// Parse a UUID from a database string, logging a warning and falling back to
/// the nil UUID when the value is malformed.  This prevents silent data
/// corruption that `Uuid::parse_str(...).unwrap_or_default()` would introduce
/// without any diagnostic.
fn parse_uuid_or_nil(raw: &str) -> Uuid {
    Uuid::parse_str(raw).unwrap_or_else(|e| {
        tracing::warn!(
            raw_value = %raw,
            error = %e,
            "Corrupt UUID in database; substituting nil UUID"
        );
        Uuid::nil()
    })
}

fn apply_text_ops(buffer: &mut String, ops: &[TextOp]) {
    for op in ops {
        match op {
            TextOp::Insert { pos, text } => {
                let mut chars: Vec<char> = buffer.chars().collect();
                let pos = (*pos).min(chars.len());
                chars.splice(pos..pos, text.chars());
                *buffer = chars.into_iter().collect();
            }
            TextOp::Replace { range, text } => {
                let mut chars: Vec<char> = buffer.chars().collect();
                let start = range.0.min(chars.len());
                let end = range.1.min(chars.len()).max(start);
                chars.splice(start..end, text.chars());
                *buffer = chars.into_iter().collect();
            }
            TextOp::Snapshot { text, .. } => *buffer = text.clone(),
            TextOp::Finalize => {}
        }
    }
}

const SCHEMA: &str = r#"
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

            Ok::<_, String>((conn, readers))
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))??;
        let (conn, readers) = conn;

        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
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

    fn ensure_telegram_memory_search_index(conn: &Connection) -> Result<(), String> {
        conn.execute_batch(
            "CREATE VIRTUAL TABLE IF NOT EXISTS telegram_structured_memory_fts
             USING fts5(
                entry_id UNINDEXED,
                channel_id UNINDEXED,
                chat_id UNINDEXED,
                scope UNINDEXED,
                subject_user_id UNINDEXED,
                search_text,
                tokenize = 'unicode61 remove_diacritics 2'
             );",
        )
        .map_err(|e| {
            format!(
                "Failed to create telegram_structured_memory_fts table: {}",
                e
            )
        })
    }

    fn rebuild_telegram_memory_search_index(conn: &Connection) -> Result<(), String> {
        Self::ensure_telegram_memory_search_index(conn)?;

        conn.execute("DELETE FROM telegram_structured_memory_fts", [])
            .map_err(|e| format!("Failed to clear telegram memory search index: {}", e))?;

        let mut stmt = conn
            .prepare(
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory",
            )
            .map_err(|e| format!("Failed to scan telegram structured memory: {}", e))?;

        let entries = stmt
            .query_map([], row_to_telegram_structured_memory)
            .map_err(|e| format!("Failed to query telegram structured memory: {}", e))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Failed to collect telegram structured memory rows: {}", e))?;

        for entry in entries {
            conn.execute(
                "INSERT INTO telegram_structured_memory_fts (
                    entry_id, channel_id, chat_id, scope, subject_user_id, search_text
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    entry.id.to_string(),
                    entry.channel_id.to_string(),
                    entry.chat_id,
                    match entry.scope {
                        TelegramStructuredMemoryScope::Chat => "chat",
                        TelegramStructuredMemoryScope::User => "user",
                        TelegramStructuredMemoryScope::Channel => "channel",
                    },
                    entry.subject_user_id,
                    build_telegram_memory_search_text(&entry),
                ],
            )
            .map_err(|e| format!("Failed to populate telegram memory search index: {}", e))?;
        }

        Ok(())
    }

    fn upsert_telegram_memory_search_index_entry(
        conn: &Connection,
        entry: &TelegramStructuredMemoryEntry,
    ) -> Result<(), String> {
        Self::ensure_telegram_memory_search_index(conn)?;

        conn.execute(
            "DELETE FROM telegram_structured_memory_fts WHERE entry_id = ?1",
            params![entry.id.to_string()],
        )
        .map_err(|e| {
            format!(
                "Failed to replace telegram memory search index entry: {}",
                e
            )
        })?;

        conn.execute(
            "INSERT INTO telegram_structured_memory_fts (
                entry_id, channel_id, chat_id, scope, subject_user_id, search_text
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                entry.id.to_string(),
                entry.channel_id.to_string(),
                entry.chat_id,
                match entry.scope {
                    TelegramStructuredMemoryScope::Chat => "chat",
                    TelegramStructuredMemoryScope::User => "user",
                    TelegramStructuredMemoryScope::Channel => "channel",
                },
                entry.subject_user_id,
                build_telegram_memory_search_text(entry),
            ],
        )
        .map_err(|e| format!("Failed to upsert telegram memory search index entry: {}", e))?;

        Ok(())
    }

    fn load_telegram_structured_memory_for_upsert(
        conn: &Connection,
        entry: &TelegramStructuredMemoryEntry,
        scope: &str,
        kind: &str,
        normalized_label: &str,
    ) -> Result<Option<TelegramStructuredMemoryEntry>, String> {
        let sql = match entry.scope {
            TelegramStructuredMemoryScope::User if entry.subject_user_id.is_some() => {
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory
                 WHERE channel_id = ?1
                   AND scope = ?2
                   AND subject_user_id = ?3
                   AND kind = ?4
                   AND normalized_label = ?5
                 LIMIT 1"
            }
            TelegramStructuredMemoryScope::Channel => {
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory
                 WHERE channel_id = ?1
                   AND scope = ?2
                   AND kind = ?3
                   AND normalized_label = ?4
                 LIMIT 1"
            }
            _ => {
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory
                 WHERE channel_id = ?1
                   AND scope = ?2
                   AND chat_id = ?3
                   AND kind = ?4
                   AND normalized_label = ?5
                 LIMIT 1"
            }
        };

        let mut stmt = conn.prepare(sql).map_err(|e| {
            format!(
                "Failed to prepare telegram structured memory lookup after upsert: {}",
                e
            )
        })?;

        let entry = match entry.scope {
            TelegramStructuredMemoryScope::User if entry.subject_user_id.is_some() => stmt
                .query_row(
                    params![
                        entry.channel_id.to_string(),
                        scope,
                        entry.subject_user_id,
                        kind,
                        normalized_label
                    ],
                    row_to_telegram_structured_memory,
                )
                .optional(),
            TelegramStructuredMemoryScope::Channel => stmt
                .query_row(
                    params![entry.channel_id.to_string(), scope, kind, normalized_label],
                    row_to_telegram_structured_memory,
                )
                .optional(),
            _ => stmt
                .query_row(
                    params![
                        entry.channel_id.to_string(),
                        scope,
                        entry.chat_id,
                        kind,
                        normalized_label
                    ],
                    row_to_telegram_structured_memory,
                )
                .optional(),
        }
        .map_err(|e| {
            format!(
                "Failed to load telegram structured memory row after upsert: {}",
                e
            )
        })?;

        Ok(entry)
    }

    /// Run database migrations for existing databases.
    /// CREATE TABLE IF NOT EXISTS doesn't add columns to existing tables,
    /// so we need to handle schema changes manually.
    fn run_migrations(conn: &Connection) -> Result<(), String> {
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
                ON telegram_scheduled_messages(channel_id, status, send_at);",
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
                ON telegram_structured_memory(channel_id, normalized_label, updated_at DESC);",
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
                ON telegram_action_executions(scheduled_message_id);",
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
                ON telegram_conversations(channel_id, updated_at DESC);",
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
                ON telegram_conversation_messages(channel_id, chat_id, created_at DESC);",
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
                ON telegram_workflows(channel_id, target_chat_id, status, updated_at DESC);",
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
                ON telegram_workflow_events(workflow_id, created_at DESC);",
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
    fn migrate_automations_table(conn: &Connection) -> Result<(), String> {
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

    fn ensure_automation_indexes(conn: &Connection) -> Result<(), String> {
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

/// Map one row of [`MISSION_LIST_COLUMNS`] onto a `Mission`.
/// Positional getters — only valid for that exact column list.
fn row_to_mission(row: &rusqlite::Row<'_>) -> rusqlite::Result<Mission> {
    let id_str: String = row.get(0)?;
    let status_str: String = row.get(1)?;
    let workspace_id_str: String = row.get(8)?;
    let desktop_sessions_json: Option<String> = row.get(17)?;
    let backend: String = row.get(18)?;
    let session_id: Option<String> = row.get(19)?;
    let terminal_reason: Option<String> = row.get(20)?;
    let config_profile: Option<String> = row.get(21)?;
    let (project, awaiting_kind, last_status_change_at) = read_project_columns(row, 32)?;

    Ok(Mission {
        id: parse_uuid_or_nil(&id_str),
        status: parse_status(&status_str),
        title: row.get(2)?,
        short_description: row.get(3)?,
        metadata_updated_at: row.get(4)?,
        metadata_source: row.get(5)?,
        metadata_model: row.get(6)?,
        metadata_version: row.get(7)?,
        workspace_id: Uuid::parse_str(&workspace_id_str)
            .unwrap_or(crate::workspace::DEFAULT_WORKSPACE_ID),
        workspace_name: row.get(9)?,
        agent: row.get(10)?,
        model_override: row.get(11)?,
        model_effort: row.get(12)?,
        fast_mode: row.get::<_, i32>(41)? != 0,
        service_tier: read_service_tier(row)?,
        backend,
        config_profile,
        history: vec![], // Loaded separately if needed
        created_at: row.get(13)?,
        updated_at: row.get(14)?,
        interrupted_at: row.get(15)?,
        paused_at: row.get(31).ok().flatten(),
        resumable: row.get::<_, i32>(16)? != 0,
        desktop_sessions: desktop_sessions_json
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default(),
        session_id,
        terminal_reason,
        terminal_evidence: None,
        parent_mission_id: row
            .get::<_, Option<String>>(22)?
            .and_then(|s| Uuid::parse_str(&s).ok()),
        working_directory: row.get(23)?,
        mission_mode: row
            .get::<_, Option<String>>(24)?
            .and_then(|s| serde_json::from_value(serde_json::Value::String(s)).ok())
            .unwrap_or_default(),
        goal_mode: row.get::<_, i32>(25).unwrap_or(0) != 0,
        goal_objective: row.get(26).ok().flatten(),
        first_viewed_at: row.get(27).ok().flatten(),
        scheduling: MissionScheduling {
            priority: row.get::<_, i32>(28).unwrap_or(0),
            not_before: row.get(29).ok().flatten(),
            deadline: row.get(30).ok().flatten(),
        },
        project,
        activity: MissionActivity {
            last_status_change_at,
            ..Default::default()
        },
        awaiting_kind,
        origin: row.get(42).ok().flatten(),
        origin_session_id: row.get(43).ok().flatten(),
        requires_local_disk: row.get::<_, i32>(44).unwrap_or(1) != 0,
    })
}

/// Column list shared by every query that maps rows through the same
/// `Mission` projection. The row getters below are positional, so the two
/// listings MUST select the same columns in the same order — keeping one
/// const is what stops them drifting.
const MISSION_LIST_COLUMNS: &str = "id, status, title, short_description, metadata_updated_at, metadata_source, metadata_model, metadata_version, workspace_id, workspace_name, agent, model_override, \
     model_effort, \
     created_at, updated_at, interrupted_at, resumable, desktop_sessions, \
     COALESCE(backend, 'opencode') as backend, session_id, terminal_reason, \
     config_profile, parent_mission_id, working_directory, \
     COALESCE(mission_mode, 'task') as mission_mode, \
     COALESCE(goal_mode, 0) as goal_mode, goal_objective, first_viewed_at, \
     COALESCE(priority, 0) as priority, not_before, deadline, paused_at, \
     project, track, intent, github_pr, tags, desired_state, next_check_at, awaiting_kind, last_status_change_at, \
     COALESCE(fast_mode, 0) as fast_mode, origin, origin_session_id, COALESCE(requires_local_disk, 1) as requires_local_disk, service_tier";

fn read_service_tier(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<Option<crate::codex_speed::Tier>> {
    row.get::<_, Option<String>>("service_tier")?
        .map(|tier| {
            serde_json::from_value(serde_json::Value::String(tier)).map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })
        })
        .transpose()
}

fn parse_status(s: &str) -> MissionStatus {
    match s {
        "pending" => MissionStatus::Pending,
        "active" => MissionStatus::Active,
        "awaiting_user" => MissionStatus::AwaitingUser,
        "acknowledged" => MissionStatus::Acknowledged,
        "waiting_background" => MissionStatus::WaitingBackground,
        "completed" => MissionStatus::Completed,
        "failed" => MissionStatus::Failed,
        "interrupted" => MissionStatus::Interrupted,
        "blocked" => MissionStatus::Blocked,
        "not_feasible" => MissionStatus::NotFeasible,
        "paused" => MissionStatus::Paused,
        _ => MissionStatus::Pending,
    }
}

fn status_to_string(status: MissionStatus) -> &'static str {
    match status {
        MissionStatus::Pending => "pending",
        MissionStatus::Active => "active",
        MissionStatus::AwaitingUser => "awaiting_user",
        MissionStatus::Acknowledged => "acknowledged",
        MissionStatus::WaitingBackground => "waiting_background",
        MissionStatus::Completed => "completed",
        MissionStatus::Failed => "failed",
        MissionStatus::Interrupted => "interrupted",
        MissionStatus::Blocked => "blocked",
        MissionStatus::NotFeasible => "not_feasible",
        MissionStatus::Paused => "paused",
    }
}

fn parse_mission_run_row(row: &rusqlite::Row<'_>) -> Result<MissionRun, rusqlite::Error> {
    let run_id: String = row.get(0)?;
    let mission_id: String = row.get(1)?;
    let state: String = row.get(3)?;
    Ok(MissionRun {
        run_id: parse_uuid_or_nil(&run_id),
        mission_id: parse_uuid_or_nil(&mission_id),
        generation: row.get::<_, i64>(2)?.max(0) as u64,
        execution_state: MissionExecutionState::parse(&state)
            .unwrap_or(MissionExecutionState::Terminal),
        owner_actor_id: row.get(4)?,
        scope_unit: row.get(5)?,
        started_at: row.get(6)?,
        heartbeat_at: row.get(7)?,
        stopping_at: row.get(8)?,
        ended_at: row.get(9)?,
        terminal_reason: row.get(10)?,
    })
}

fn parse_tool_execution_row(
    row: &rusqlite::Row<'_>,
) -> Result<MissionToolExecution, rusqlite::Error> {
    let run_id: String = row.get(1)?;
    let state: String = row.get(3)?;
    let durable_job_id: Option<String> = row.get(8)?;
    Ok(MissionToolExecution {
        tool_call_id: row.get(0)?,
        run_id: parse_uuid_or_nil(&run_id),
        tool_kind: row.get(2)?,
        state: MissionToolExecutionState::parse(&state).unwrap_or(MissionToolExecutionState::Stale),
        started_at: row.get(4)?,
        heartbeat_at: row.get(5)?,
        deadline_at: row.get(6)?,
        process_pid: row.get::<_, Option<i64>>(7)?.map(|pid| pid.max(0) as u32),
        durable_job_id: durable_job_id.and_then(|id| Uuid::parse_str(&id).ok()),
        completed_at: row.get(9)?,
        exit_status: row.get(10)?,
        failure_class: row.get(11)?,
    })
}

/// Serialize mission tags to a JSON array string for storage. `None` when empty
/// (keeps the column NULL rather than `"[]"`).
fn tags_to_json(tags: &[String]) -> Option<String> {
    if tags.is_empty() {
        None
    } else {
        serde_json::to_string(tags).ok()
    }
}

/// Parse a stored JSON array of tags. Tolerates NULL / malformed values.
fn tags_from_json(raw: Option<String>) -> Vec<String> {
    raw.as_deref()
        .and_then(|s| serde_json::from_str::<Vec<String>>(s).ok())
        .unwrap_or_default()
}

/// Read the trailing project/activity columns from a mission row in the
/// canonical order `project, track, intent, github_pr, tags, desired_state,
/// next_check_at, awaiting_kind, last_status_change_at` starting at `base`.
/// Shared by the full SELECTs so the index math lives in one place. Returns the
/// project metadata, the awaiting classification, and `last_status_change_at`.
fn read_project_columns(
    row: &rusqlite::Row,
    base: usize,
) -> rusqlite::Result<(MissionProject, Option<AwaitingKind>, Option<String>)> {
    let project = MissionProject {
        project: row.get(base)?,
        track: row.get(base + 1)?,
        intent: row.get(base + 2)?,
        github_pr: row.get(base + 3)?,
        tags: tags_from_json(row.get(base + 4)?),
        desired_state: row.get(base + 5)?,
        next_check_at: row.get(base + 6)?,
    };
    let awaiting_kind = row
        .get::<_, Option<String>>(base + 7)?
        .as_deref()
        .and_then(AwaitingKind::from_str_opt);
    let last_status_change_at: Option<String> = row.get(base + 8)?;
    Ok((project, awaiting_kind, last_status_change_at))
}

/// Synchronous body of `log_event`, so callers can run it inside a larger
/// transaction (the client link commits an event with its ingest cursor).
pub(super) fn log_event_sync(
    conn: &rusqlite::Connection,
    content_dir: &std::path::Path,
    mission_id: Uuid,
    event: &AgentEvent,
) -> Result<(), String> {
    if matches!(event, AgentEvent::UserMessage { queued: true, .. }) {
        // Keep queued messages out of persisted mission history until they actually start.
        return Ok(());
    }

    let now = now_string();
    let mid = mission_id.to_string();

    if let AgentEvent::TextOp { bubble_id, ops, .. } = event {
        let bubble_id = bubble_id.clone();
        let ops = ops.clone();
        let has_finalize = ops.iter().any(|op| matches!(op, TextOp::Finalize));
        return (|| -> Result<(), String> {
            // A finalized native step is immutable. A log reset may replay
            // it; do not create duplicate canonical rows or reopen the step.
            if bubble_id.starts_with("antigravity:") && conn.query_row(
                    "SELECT EXISTS(SELECT 1 FROM mission_events WHERE mission_id=?1 AND event_type='assistant_message_canonical' AND event_id=?2)",
                    params![&mid, &bubble_id], |row| row.get::<_, bool>(0)
                ).unwrap_or(false) { return Ok(()); }
            if has_finalize {
                let mut stmt = conn
                    .prepare(
                        "SELECT content, content_file
                             FROM mission_events
                             WHERE mission_id = ?1
                               AND event_type = 'text_op'
                               AND json_extract(metadata, '$.bubble_id') = ?2
                             ORDER BY sequence ASC",
                    )
                    .map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![&mid, &bubble_id], |row| {
                        let content: Option<String> = row.get(0)?;
                        let content_file: Option<String> = row.get(1)?;
                        Ok(SqliteMissionStore::load_content(
                            content.as_deref(),
                            content_file.as_deref(),
                        ))
                    })
                    .map_err(|e| e.to_string())?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| e.to_string())?;
                drop(stmt);

                let mut content = String::new();
                for row in rows {
                    let row_ops: Vec<TextOp> = serde_json::from_str(&row).unwrap_or_default();
                    apply_text_ops(&mut content, &row_ops);
                }
                apply_text_ops(&mut content, &ops);

                conn.execute(
                    "DELETE FROM mission_events
                         WHERE mission_id = ?1
                           AND event_type = 'text_op'
                           AND json_extract(metadata, '$.bubble_id') = ?2",
                    params![&mid, &bubble_id],
                )
                .map_err(|e| e.to_string())?;

                let sequence: i64 = conn
                        .query_row(
                            "SELECT COALESCE(MAX(sequence), 0) + 1 FROM mission_events WHERE mission_id = ?1",
                            params![&mid],
                            |row| row.get(0),
                        )
                        .unwrap_or(1);
                let (content_inline, content_file) = SqliteMissionStore::store_content(
                    content_dir,
                    mission_id,
                    sequence,
                    "assistant_message_canonical",
                    &content,
                );
                conn.execute(
                        "INSERT INTO mission_events
                         (mission_id, sequence, event_type, timestamp, event_id, content, content_file, metadata)
                         VALUES (?1, ?2, 'assistant_message_canonical', ?3, ?4, ?5, ?6, ?7)",
                        params![
                            &mid,
                            sequence,
                            &now,
                            &bubble_id,
                            content_inline,
                            content_file,
                            serde_json::json!({
                                "bubble_id": bubble_id,
                                "canonical_from": "text_op",
                                "revision": ops.iter().filter_map(|op| if let TextOp::Snapshot { revision, .. } = op { Some(*revision) } else { None }).max()
                            })
                            .to_string(),
                        ],
                    )
                    .map_err(|e| e.to_string())?;
            } else {
                let sequence: i64 = conn
                        .query_row(
                            "SELECT COALESCE(MAX(sequence), 0) + 1 FROM mission_events WHERE mission_id = ?1",
                            params![&mid],
                            |row| row.get(0),
                        )
                        .unwrap_or(1);
                let content = serde_json::to_string(&ops).unwrap_or_else(|_| "[]".to_string());
                let (content_inline, content_file) = SqliteMissionStore::store_content(
                    content_dir,
                    mission_id,
                    sequence,
                    "text_op",
                    &content,
                );
                conn.execute(
                        "INSERT INTO mission_events
                         (mission_id, sequence, event_type, timestamp, content, content_file, metadata)
                         VALUES (?1, ?2, 'text_op', ?3, ?4, ?5, ?6)",
                        params![
                            &mid,
                            sequence,
                            &now,
                            content_inline,
                            content_file,
                            serde_json::json!({ "bubble_id": bubble_id }).to_string(),
                        ],
                    )
                    .map_err(|e| e.to_string())?;
            }

            Ok(())
        })();
    }

    // Extract event data
    let (event_type, event_id, tool_call_id, tool_name, content, metadata) = match event {
        AgentEvent::UserMessage {
            id,
            content,
            queued,
            source,
            ..
        } => (
            "user_message",
            Some(id.to_string()),
            None,
            None,
            if source.as_deref() == Some("scheduler") {
                crate::api::control::deferred_messages::strip(content)
            } else {
                content.clone()
            },
            {
                // Always record `queued`; record `source` only when present so
                // the persisted metadata is the forensic record of who/what
                // posted this message (audit/attribution).
                let mut meta = serde_json::Map::new();
                meta.insert("queued".to_string(), serde_json::json!(queued));
                if let Some(src) = source {
                    meta.insert("source".to_string(), serde_json::json!(src));
                    if src == "scheduler" {
                        let messages = crate::api::control::deferred_messages::decode(content).1;
                        if !messages.is_empty() {
                            meta.insert("messages".into(), serde_json::json!(messages));
                        }
                    }
                }
                serde_json::Value::Object(meta)
            },
        ),
        AgentEvent::AssistantMessage {
            id,
            content,
            success,
            cost_cents,
            cost_source,
            usage,
            model,
            model_normalized,
            shared_files,
            resumable,
            completion_evidence,
            ..
        } => (
            "assistant_message",
            Some(id.to_string()),
            None,
            None,
            content.clone(),
            assistant_message_metadata(AssistantMessageMetadataInput {
                success: *success,
                cost_cents: *cost_cents,
                cost_source: *cost_source,
                usage,
                model,
                model_normalized,
                shared_files,
                resumable: *resumable,
                completion_evidence,
            }),
        ),
        AgentEvent::Thinking { content, done, .. } => (
            "thinking",
            None,
            None,
            None,
            content.clone(),
            serde_json::json!({ "done": done }),
        ),
        AgentEvent::ToolCall {
            tool_call_id,
            name,
            args,
            ..
        } => (
            "tool_call",
            None,
            Some(tool_call_id.clone()),
            Some(name.clone()),
            args.to_string(),
            serde_json::json!({}),
        ),
        AgentEvent::ToolResult {
            tool_call_id,
            name,
            result,
            ..
        } => (
            "tool_result",
            None,
            Some(tool_call_id.clone()),
            Some(name.clone()),
            result.to_string(),
            serde_json::json!({}),
        ),
        AgentEvent::Error {
            message, resumable, ..
        } => (
            "error",
            None,
            None,
            None,
            message.clone(),
            serde_json::json!({ "resumable": resumable }),
        ),
        AgentEvent::TextDelta { content, .. } => (
            "text_delta",
            Some("text_delta_latest".to_string()),
            None,
            None,
            content.clone(),
            serde_json::json!({}),
        ),
        AgentEvent::TextOp { .. } => return Ok(()),
        AgentEvent::MissionStatusChanged {
            status,
            summary,
            execution,
            completion,
            ..
        } => (
            "mission_status_changed",
            None,
            None,
            None,
            summary.clone().unwrap_or_default(),
            serde_json::json!({ "status": status.to_string(), "execution": execution, "completion": completion }),
        ),
        AgentEvent::MissionMetadataUpdated {
            title,
            short_description,
            metadata_updated_at,
            updated_at,
            metadata_source,
            metadata_model,
            metadata_version,
            ..
        } => (
            "mission_metadata_updated",
            None,
            None,
            None,
            title.clone().unwrap_or_default(),
            serde_json::json!({
                "title": title,
                "short_description": short_description,
                "metadata_updated_at": metadata_updated_at,
                "updated_at": updated_at,
                "metadata_source": metadata_source,
                "metadata_model": metadata_model,
                "metadata_version": metadata_version
            }),
        ),
        AgentEvent::MissionSettingsUpdated {
            backend,
            agent,
            model_override,
            model_effort,
            config_profile,
            session_id,
            updated_at,
            ..
        } => (
            "mission_settings_updated",
            None,
            None,
            None,
            backend.clone(),
            serde_json::json!({
                "backend": backend,
                "agent": agent,
                "model_override": model_override,
                "model_effort": model_effort,
                "config_profile": config_profile,
                "session_id": session_id,
                "updated_at": updated_at
            }),
        ),
        AgentEvent::GoalIteration {
            iteration,
            objective,
            ..
        } => (
            "goal_iteration",
            None,
            None,
            None,
            objective.clone(),
            serde_json::json!({ "iteration": iteration }),
        ),
        AgentEvent::GoalStatus {
            status, objective, ..
        } => (
            "goal_status",
            None,
            None,
            None,
            objective.clone(),
            serde_json::json!({ "status": status }),
        ),
        // Skip events that are less important for debugging
        AgentEvent::Status { .. }
        | AgentEvent::AgentPhase { .. }
        | AgentEvent::AgentTree { .. }
        | AgentEvent::Progress { .. }
        | AgentEvent::SessionIdUpdate { .. }
        | AgentEvent::MissionActivity { .. }
        | AgentEvent::MissionTitleChanged { .. }
        | AgentEvent::FidoSignRequest { .. } => return Ok(()),
    };

    let event_type = event_type.to_string();
    let metadata_str = metadata.to_string();

    (|| -> Result<(), String> {
        // If this event has an event_id that already exists for this mission,
        // update the existing row's metadata instead of inserting a duplicate.
        if let Some(ref eid) = event_id {
            let existing: Option<i64> = conn
                .query_row(
                    "SELECT id FROM mission_events WHERE mission_id = ?1 AND event_id = ?2",
                    params![&mid, eid],
                    |row| row.get(0),
                )
                .optional()
                .unwrap_or(None);

            if let Some(row_id) = existing {
                let (content_inline, content_file) = SqliteMissionStore::store_content(
                    content_dir,
                    mission_id,
                    row_id,
                    &event_type,
                    &content,
                );
                if event_type == "text_delta" {
                    let sequence: i64 = conn
                            .query_row(
                                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM mission_events WHERE mission_id = ?1",
                                params![&mid],
                                |row| row.get(0),
                            )
                            .unwrap_or(1);
                    conn.execute(
                            "UPDATE mission_events
                             SET sequence = ?1, metadata = ?2, timestamp = ?3, content = ?4, content_file = ?5
                             WHERE id = ?6",
                            params![sequence, metadata_str, now, content_inline, content_file, row_id],
                        )
                        .map_err(|e| e.to_string())?;
                } else {
                    conn.execute(
                        "UPDATE mission_events
                             SET metadata = ?1, timestamp = ?2, content = ?3, content_file = ?4
                             WHERE id = ?5",
                        params![metadata_str, now, content_inline, content_file, row_id],
                    )
                    .map_err(|e| e.to_string())?;
                }
                return Ok(());
            }
        }

        // Get next sequence
        let sequence: i64 = conn
            .query_row(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM mission_events WHERE mission_id = ?1",
                params![&mid],
                |row| row.get(0),
            )
            .unwrap_or(1);

        // Store content
        let (content_inline, content_file) = SqliteMissionStore::store_content(
            content_dir,
            mission_id,
            sequence,
            &event_type,
            &content,
        );

        conn.execute(
                "INSERT INTO mission_events
                 (mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    mid,
                    sequence,
                    event_type,
                    now,
                    event_id,
                    tool_call_id,
                    tool_name,
                    content_inline,
                    content_file,
                    metadata_str,
                ],
            )
            .map_err(|e| e.to_string())?;

        Ok(())
    })()
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
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(&format!(
                    "SELECT {MISSION_LIST_COLUMNS}
                     FROM missions
                     ORDER BY updated_at DESC
                     LIMIT ?1 OFFSET ?2"
                ))
                .map_err(|e| e.to_string())?;

            let missions = stmt
                .query_map(params![limit as i64, offset as i64], row_to_mission)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(missions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    /// Exact filtered listing: the predicate runs in SQL, so a match is found
    /// however deep it sits in the fleet (the generic scan gives up after
    /// 5 000 rows, which is why old conversations showed zero workers).
    ///
    /// `tag` is the one field SQL only narrows: `tags` is a JSON TEXT column
    /// and some rows hold malformed blobs, so `json_each` would fail the whole
    /// query. A `LIKE` prefilter selects candidates and
    /// [`MissionFilter::matches`] makes the final call — which means the
    /// prefilter can over-select, hence the accumulate-until-satisfied loop.
    async fn list_missions_filtered(
        &self,
        filter: &MissionFilter,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<Mission>, String> {
        if filter.is_empty() {
            return self.list_missions(limit, offset).await;
        }
        let conn = self.reader();
        let filter = filter.clone();
        tokio::task::spawn_blocking(move || {
            const PAGE: i64 = 200;
            let conn = conn.blocking_lock();

            let mut clauses: Vec<String> = Vec::new();
            let mut binds: Vec<String> = Vec::new();
            let bind =
                |clause: &str, value: &str, clauses: &mut Vec<String>, binds: &mut Vec<String>| {
                    binds.push(value.to_string());
                    clauses.push(clause.replace("?n", &format!("?{}", binds.len())));
                };
            if let Some(v) = filter.status.as_deref() {
                bind("status = ?n", v, &mut clauses, &mut binds);
            }
            if let Some(v) = filter.project.as_deref() {
                bind("project = ?n", v, &mut clauses, &mut binds);
            }
            if let Some(v) = filter.project_prefix.as_deref() {
                // Range bounds, not `LIKE ?n || '-%'`: a LIKE whose pattern is
                // a concatenation expression is never index-optimised, so the
                // family lookup degraded into a full `SCAN missions` — on the
                // fleets this feature exists for, while holding the connection
                // mutex. `'-'` is 0x2D and `'.'` is 0x2E, so [`family-`,
                // `family.`) is exactly the set of `family-*` values under
                // BINARY collation, and both branches can use
                // idx_missions_project_track.
                binds.push(v.to_string());
                let exact = binds.len();
                binds.push(format!("{v}-"));
                let lower = binds.len();
                binds.push(format!("{v}."));
                let upper = binds.len();
                clauses.push(format!(
                    "(project = ?{exact} OR (project >= ?{lower} AND project < ?{upper}))"
                ));
            }
            if let Some(v) = filter.track.as_deref() {
                bind("track = ?n", v, &mut clauses, &mut binds);
            }
            if let Some(v) = filter.origin_session_id.as_deref() {
                bind("origin_session_id = ?n", v, &mut clauses, &mut binds);
            }
            if let Some(v) = filter.tag.as_deref() {
                // Match the tag's JSON *serialization*, quotes included: a tag
                // holding a quote/backslash/newline is escaped inside the
                // column, so a raw-text LIKE would exclude it in SQL and the
                // Rust re-check below would never get to see it.
                //
                // Then neutralise LIKE's own wildcards. Tags are free-form, so
                // `?tag=%` would otherwise select nearly every row and make the
                // loop page through them holding the connection lock — a
                // selective prefilter is what keeps this off the critical path.
                // Escape the escape character first, or `\` would be doubled.
                let encoded = serde_json::to_string(v).unwrap_or_else(|_| format!("\"{v}\""));
                let pattern = encoded
                    .replace('\\', "\\\\")
                    .replace('%', "\\%")
                    .replace('_', "\\_");
                bind(
                    r"tags LIKE '%' || ?n || '%' ESCAPE '\'",
                    &pattern,
                    &mut clauses,
                    &mut binds,
                );
            }
            if filter.attention_only {
                clauses.push(
                    "status NOT IN ('acknowledged', 'completed')".to_string(),
                );
                // Tags are a JSON array. The superseded token is stored as
                // the JSON string `"superseded"`; this is a prefilter — the
                // Rust `matches` call below is the authority.
                let encoded = serde_json::to_string(SUPERSEDED_TAG)
                    .unwrap_or_else(|_| format!("\"{SUPERSEDED_TAG}\""));
                let pattern = encoded
                    .replace('\\', "\\\\")
                    .replace('%', "\\%")
                    .replace('_', "\\_");
                bind(
                    r"(tags IS NULL OR tags = '' OR tags = '[]' OR tags NOT LIKE '%' || ?n || '%' ESCAPE '\')",
                    &pattern,
                    &mut clauses,
                    &mut binds,
                );
            }
            let where_sql = if clauses.is_empty() {
                String::new()
            } else {
                format!("WHERE {}", clauses.join(" AND "))
            };

            let sql = format!(
                "SELECT {MISSION_LIST_COLUMNS} FROM missions {where_sql} \
                 ORDER BY updated_at DESC LIMIT ?{} OFFSET ?{}",
                binds.len() + 1,
                binds.len() + 2
            );
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;

            let want = offset.saturating_add(limit);
            let mut matched: Vec<Mission> = Vec::new();
            let mut sql_offset: i64 = 0;
            loop {
                let mut args: Vec<&dyn rusqlite::ToSql> =
                    binds.iter().map(|v| v as &dyn rusqlite::ToSql).collect();
                args.push(&PAGE);
                args.push(&sql_offset);

                let page = stmt
                    .query_map(args.as_slice(), row_to_mission)
                    .map_err(|e| e.to_string())?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| e.to_string())?;
                let page_len = page.len();
                for mission in page {
                    // The tag prefilter can over-select; this is the authority.
                    if filter.matches(&mission) {
                        matched.push(mission);
                        if matched.len() >= want {
                            break;
                        }
                    }
                }
                if matched.len() >= want || (page_len as i64) < PAGE {
                    break;
                }
                sql_offset += PAGE;
            }
            Ok(matched.into_iter().skip(offset).take(limit).collect())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    /// Indexed prefix seek on the primary key: `id` is TEXT PRIMARY KEY, so
    /// the range bounds below use its implicit index instead of scanning.
    async fn find_missions_by_id_prefix(
        &self,
        prefix: &str,
        limit: usize,
    ) -> Result<Vec<Mission>, String> {
        let prefix = prefix.to_ascii_lowercase();
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // Half-open range over the PK. Incrementing the last byte gives the
            // exclusive upper bound for "everything starting with prefix";
            // mission ids are lowercase hex + hyphens, so the successor is
            // always representable.
            let mut upper = prefix.clone().into_bytes();
            match upper.last_mut() {
                Some(byte) if *byte < 0xFF => *byte += 1,
                _ => upper.push(0),
            }
            let upper = String::from_utf8_lossy(&upper).to_string();
            let mut stmt = conn
                .prepare(&format!(
                    "SELECT {MISSION_LIST_COLUMNS} FROM missions \
                     WHERE id >= ?1 AND id < ?2 \
                     ORDER BY updated_at DESC LIMIT ?3"
                ))
                .map_err(|e| e.to_string())?;
            let missions = stmt
                .query_map(params![prefix, upper, limit as i64], row_to_mission)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(missions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn count_missions_by_status(&self) -> Result<MissionStatusCounts, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare("SELECT status, COUNT(*) FROM missions GROUP BY status")
                .map_err(|e| e.to_string())?;

            let rows = stmt
                .query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                })
                .map_err(|e| e.to_string())?;

            let mut counts = MissionStatusCounts::default();
            for row in rows {
                let (status, count) = row.map_err(|e| e.to_string())?;
                let count = usize::try_from(count).unwrap_or(0);
                counts.add(parse_status(&status), count);
            }
            Ok(counts)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn count_missions_updated_since(
        &self,
        since: &str,
    ) -> Result<MissionStatusCounts, String> {
        let conn = self.conn.clone();
        let since = since.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT status, COUNT(*) FROM missions WHERE updated_at >= ?1 GROUP BY status",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![since], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                })
                .map_err(|e| e.to_string())?;
            let mut counts = MissionStatusCounts::default();
            for row in rows {
                let (status, count) = row.map_err(|e| e.to_string())?;
                let count = usize::try_from(count).unwrap_or(0);
                counts.add(parse_status(&status), count);
            }
            Ok(counts)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn restore_mission_status(
        &self,
        id: Uuid,
        snapshot: &super::MissionStatusSnapshot,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let snapshot = snapshot.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(|e| e.to_string())?;
            let changed = tx
                .execute(
                    "UPDATE missions SET status=?2, interrupted_at=?3, paused_at=?4, resumable=?5,
                 terminal_reason=?6, first_viewed_at=?7, awaiting_kind=?8,
                 last_status_change_at=?9 WHERE id=?1 AND (status='active' OR status=?2)",
                    params![
                        id.to_string(),
                        status_to_string(snapshot.status),
                        snapshot.interrupted_at,
                        snapshot.paused_at,
                        snapshot.resumable,
                        snapshot.terminal_reason,
                        snapshot.first_viewed_at,
                        snapshot.awaiting_kind.map(|kind| kind.as_str().to_string()),
                        snapshot.last_status_change_at
                    ],
                )
                .map_err(|e| e.to_string())?;
            if changed != 1 {
                return Err("mission status changed during rejected activation".into());
            }
            // Evidence uses a side table, not a positional missions column.
            if let Some(evidence) = snapshot.terminal_evidence {
                tx.execute("INSERT INTO mission_terminal_evidence(mission_id, evidence, recorded_at) VALUES (?1, ?2, ?3)
                    ON CONFLICT(mission_id) DO UPDATE SET evidence=excluded.evidence", params![id.to_string(), evidence, now_string()]).map_err(|e| e.to_string())?;
            } else {
                tx.execute("DELETE FROM mission_terminal_evidence WHERE mission_id=?1", params![id.to_string()]).map_err(|e| e.to_string())?;
            }
            tx.commit().map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn set_terminal_evidence(&self, id: Uuid, evidence: &str) -> Result<(), String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let evidence = evidence.chars().take(2000).collect::<String>();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO mission_terminal_evidence (mission_id, evidence, recorded_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(mission_id) DO UPDATE SET evidence = ?2, recorded_at = ?3",
                params![id_str, evidence, now_string()],
            )
            .map(|_| ())
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_mission(&self, id: Uuid) -> Result<Option<Mission>, String> {
        let conn = self.reader();
        let id_str = id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();

            // Get mission
            let mut stmt = conn
                .prepare(
                    "SELECT id, status, title, short_description, metadata_updated_at, metadata_source, metadata_model, metadata_version, workspace_id, workspace_name, agent, model_override,
                            model_effort,
                            created_at, updated_at, interrupted_at, resumable, desktop_sessions,
                            COALESCE(backend, 'opencode') as backend, session_id, terminal_reason,
                            config_profile, parent_mission_id, working_directory,
                            COALESCE(mission_mode, 'task') as mission_mode, COALESCE(goal_mode, 0) as goal_mode, goal_objective, first_viewed_at,
                            COALESCE(priority, 0) as priority, not_before, deadline, paused_at,
                            project, track, intent, github_pr, tags, desired_state, next_check_at, awaiting_kind, last_status_change_at,
                            COALESCE(fast_mode, 0) as fast_mode, origin, origin_session_id, COALESCE(requires_local_disk, 1) as requires_local_disk, service_tier FROM missions WHERE id = ?1",
                )
                .map_err(|e| e.to_string())?;

            let mission: Option<Mission> = stmt
                .query_row(params![&id_str], |row| {
                    let id_str: String = row.get(0)?;
                    let status_str: String = row.get(1)?;
                    let workspace_id_str: String = row.get(8)?;
                    let desktop_sessions_json: Option<String> = row.get(17)?;
                    let backend: String = row.get(18)?;
                    let session_id: Option<String> = row.get(19)?;
                    let terminal_reason: Option<String> = row.get(20)?;
                    let config_profile: Option<String> = row.get(21)?;
                    let (project, awaiting_kind, last_status_change_at) =
                        read_project_columns(row, 32)?;

                    Ok(Mission {
                        id: parse_uuid_or_nil(&id_str),
                        status: parse_status(&status_str),
                        title: row.get(2)?,
                        short_description: row.get(3)?,
                        metadata_updated_at: row.get(4)?,
                        metadata_source: row.get(5)?,
                        metadata_model: row.get(6)?,
                        metadata_version: row.get(7)?,
                        workspace_id: Uuid::parse_str(&workspace_id_str)
                            .unwrap_or(crate::workspace::DEFAULT_WORKSPACE_ID),
                        workspace_name: row.get(9)?,
                        agent: row.get(10)?,
                        model_override: row.get(11)?,
                        model_effort: row.get(12)?,
                        fast_mode: row.get::<_, i32>(41)? != 0,
                        service_tier: read_service_tier(row)?,
                        backend,
                        config_profile,
                        history: vec![],
                        created_at: row.get(13)?,
                        updated_at: row.get(14)?,
                        interrupted_at: row.get(15)?,
                        paused_at: row.get(31).ok().flatten(),
                        resumable: row.get::<_, i32>(16)? != 0,
                        desktop_sessions: desktop_sessions_json
                            .and_then(|s| serde_json::from_str(&s).ok())
                            .unwrap_or_default(),
                        session_id,
                        terminal_reason,
                        terminal_evidence: None,
                        parent_mission_id: row.get::<_, Option<String>>(22)?.and_then(|s| Uuid::parse_str(&s).ok()),
                        working_directory: row.get(23)?,
                        mission_mode: row.get::<_, Option<String>>(24)?
                            .and_then(|s| serde_json::from_value(serde_json::Value::String(s)).ok())
                            .unwrap_or_default(),
                            goal_mode: row.get::<_, i32>(25).unwrap_or(0) != 0,
                            goal_objective: row.get(26).ok().flatten(),
                            first_viewed_at: row.get(27).ok().flatten(),
                            scheduling: MissionScheduling {
                                priority: row.get::<_, i32>(28).unwrap_or(0),
                                not_before: row.get(29).ok().flatten(),
                                deadline: row.get(30).ok().flatten(),
                            },
                            project,
                            activity: MissionActivity {
                                last_status_change_at,
                                ..Default::default()
                            },
                            awaiting_kind,
                            origin: row.get(42).ok().flatten(),
                            origin_session_id: row.get(43).ok().flatten(),
                            requires_local_disk: row.get::<_, i32>(44).unwrap_or(1) != 0,
                    })
                })
                .optional()
                .map_err(|e| e.to_string())?;

            // Load history from events (limited to last 200 messages for performance)
            // Full history can be retrieved via get_events() if needed
            if let Some(mut m) = mission {
                let mut history_stmt = conn
                    .prepare(
                        "SELECT event_type, content, content_file FROM (
                             SELECT event_type, content, content_file, sequence
                             FROM mission_events
                             WHERE mission_id = ?1 AND event_type IN ('user_message', 'assistant_message')
                             ORDER BY sequence DESC
                             LIMIT 200
                         ) ORDER BY sequence ASC",
                    )
                    .map_err(|e| e.to_string())?;

                let history: Vec<MissionHistoryEntry> = history_stmt
                    .query_map(params![&id_str], |row| {
                        let event_type: String = row.get(0)?;
                        let content: Option<String> = row.get(1)?;
                        let content_file: Option<String> = row.get(2)?;
                        let full_content =
                            SqliteMissionStore::load_content(content.as_deref(), content_file.as_deref());
                        Ok(MissionHistoryEntry {
                            role: if event_type == "user_message" {
                                "user".to_string()
                            } else {
                                "assistant".to_string()
                            },
                            content: full_content,
                        })
                    })
                    .map_err(|e| e.to_string())?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| e.to_string())?;

                m.history = history;
                if m.backend.starts_with("cloud_") {
                    let data: Option<String> = conn.query_row("SELECT data FROM cloud_executions WHERE mission_id=?1", [&id_str], |row| row.get(0)).optional().map_err(|e| e.to_string())?;
                    if let Some(data) = data {
                        let execution: crate::api::cloud_agents::Execution = serde_json::from_str(&data).map_err(|e| e.to_string())?;
                        m.history.clear();
                        for turn in execution.turns.iter().rev().take(100).collect::<Vec<_>>().into_iter().rev() {
                            m.history.push(MissionHistoryEntry {role:"user".into(),content:turn.prompt.clone()});
                            if let Some(result) = &turn.result { m.history.push(MissionHistoryEntry{role:"assistant".into(),content:result.clone()}); }
                        }
                    }
                }

                // Guard evidence lives in its own side table (see
                // run_migrations); the single-mission read is the one path
                // that carries it — list projections stay lean.
                m.terminal_evidence = conn
                    .query_row(
                        "SELECT evidence FROM mission_terminal_evidence WHERE mission_id = ?1",
                        params![&id_str],
                        |row| row.get::<_, String>(0),
                    )
                    .ok();
                Ok(Some(m))
            } else {
                Ok(None)
            }
        })
        .await
        .map_err(|e| e.to_string())?
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
        let conn = self.conn.clone();
        let owner_actor_id = owner_actor_id.to_string();
        let scope_unit = scope_unit.map(str::to_string);
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction().map_err(|error| error.to_string())?;
            machine_transfer::guard_start(&tx, mission_id)?;
            machine_transfer::guard_placement(&tx,mission_id,&owner_actor_id,scope_unit.as_deref())?;
            let cwd=scope_unit.as_deref().and_then(|s|s.strip_prefix("orb-cwd:"));
            machine_transfer::guard_workspace(&tx,mission_id,cwd)?;
            let mission_status = tx
                .query_row(
                    "SELECT status FROM missions WHERE id = ?1",
                    params![mission_id.to_string()],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(|error| error.to_string())?;
            let Some(mission_status) = mission_status else {
                return Err(format!("mission not found: {mission_id}"));
            };
            if mission_status == "acknowledged" {
                return Err(format!(
                    "acknowledged mission {mission_id} cannot acquire a non-terminal run"
                ));
            }
            if !owner_actor_id.starts_with("orb-client:") && !matches!(mission_status.as_str(), "pending" | "active") {
                return Err(format!(
                    "mission {mission_id} has status {mission_status}; activate it before acquiring a non-terminal run"
                ));
            }
            if let Some(existing) = tx
                .query_row(
                    "SELECT run_id, mission_id, generation, execution_state, owner_actor_id, scope_unit, started_at, heartbeat_at, stopping_at, ended_at, terminal_reason
                     FROM mission_runs WHERE mission_id = ?1 AND execution_state <> 'terminal'",
                    params![mission_id.to_string()],
                    parse_mission_run_row,
                )
                .optional()
                .map_err(|error| error.to_string())?
            {
                return Err(format!(
                    "mission {mission_id} already has non-terminal run {} generation {}",
                    existing.run_id, existing.generation
                ));
            }
            if owner_actor_id.starts_with("orb-client:") {
                tx.execute("UPDATE missions SET status='active',updated_at=?2,working_directory=COALESCE(?3,working_directory) WHERE id=?1",params![mission_id.to_string(),now_string(),cwd]).map_err(|e|e.to_string())?;
            }
            let generation = tx
                .query_row(
                    "SELECT COALESCE(MAX(generation), 0) + 1 FROM mission_runs WHERE mission_id = ?1",
                    params![mission_id.to_string()],
                    |row| row.get::<_, i64>(0),
                )
                .map_err(|error| error.to_string())?
                .max(1) as u64;
            let now = now_string();
            let run = MissionRun {
                run_id: Uuid::new_v4(),
                mission_id,
                generation,
                execution_state: MissionExecutionState::Starting,
                owner_actor_id,
                scope_unit,
                started_at: now.clone(),
                heartbeat_at: now,
                stopping_at: None,
                ended_at: None,
                terminal_reason: None,
            };
            tx.execute(
                "INSERT INTO mission_runs (run_id, mission_id, generation, execution_state, owner_actor_id, scope_unit, started_at, heartbeat_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    run.run_id.to_string(),
                    run.mission_id.to_string(),
                    run.generation as i64,
                    run.execution_state.as_str(),
                    run.owner_actor_id,
                    run.scope_unit,
                    run.started_at,
                    run.heartbeat_at,
                ],
            )
            .map_err(|error| error.to_string())?;
            tx.commit().map_err(|error| error.to_string())?;
            Ok(run)
        })
        .await
        .map_err(|error| error.to_string())?
    }

    async fn get_active_mission_run(&self, mission_id: Uuid) -> Result<Option<MissionRun>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT run_id, mission_id, generation, execution_state, owner_actor_id, scope_unit, started_at, heartbeat_at, stopping_at, ended_at, terminal_reason
                 FROM mission_runs WHERE mission_id = ?1 AND execution_state <> 'terminal'",
                params![mission_id.to_string()],
                parse_mission_run_row,
            )
            .optional()
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    async fn get_latest_mission_run(&self, mission_id: Uuid) -> Result<Option<MissionRun>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT run_id, mission_id, generation, execution_state, owner_actor_id, scope_unit, started_at, heartbeat_at, stopping_at, ended_at, terminal_reason
                 FROM mission_runs WHERE mission_id = ?1 ORDER BY generation DESC LIMIT 1",
                params![mission_id.to_string()],
                parse_mission_run_row,
            )
            .optional()
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    async fn list_active_mission_runs(&self) -> Result<Vec<MissionRun>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT run_id, mission_id, generation, execution_state, owner_actor_id, scope_unit, started_at, heartbeat_at, stopping_at, ended_at, terminal_reason
                     FROM mission_runs WHERE execution_state <> 'terminal' ORDER BY started_at ASC",
                )
                .map_err(|error| error.to_string())?;
            let rows = stmt
                .query_map([], parse_mission_run_row)
                .map_err(|error| error.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|error| error.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|error| error.to_string())?
    }

    async fn heartbeat_mission_run(
        &self,
        run_id: Uuid,
        generation: u64,
        state: MissionExecutionState,
        scope_unit: Option<&str>,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let now = now_string();
        let scope_unit = scope_unit.map(str::to_string);
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE mission_runs SET execution_state = ?1, heartbeat_at = ?2,
                    scope_unit = COALESCE(?3, scope_unit),
                    stopping_at = CASE WHEN ?1 = 'stopping' THEN COALESCE(stopping_at, ?2) ELSE stopping_at END
                 WHERE run_id = ?4 AND generation = ?5 AND execution_state <> 'terminal'",
                params![state.as_str(), now, scope_unit, run_id.to_string(), generation as i64],
            )
            .map(|changed| changed == 1)
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    async fn finish_mission_run(
        &self,
        run_id: Uuid,
        generation: u64,
        terminal_reason: Option<&str>,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let now = now_string();
        let terminal_reason = terminal_reason.map(str::to_string);
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE mission_runs SET execution_state = 'terminal', heartbeat_at = ?1,
                    ended_at = ?1, terminal_reason = ?2
                 WHERE run_id = ?3 AND generation = ?4 AND execution_state <> 'terminal'",
                params![now, terminal_reason, run_id.to_string(), generation as i64],
            )
            .map(|changed| changed == 1)
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    async fn register_tool_execution(
        &self,
        execution: &MissionToolExecution,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let execution = execution.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO mission_tool_executions (tool_call_id, run_id, tool_kind, state, started_at, heartbeat_at, deadline_at, process_pid, durable_job_id, completed_at, exit_status, failure_class)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                 ON CONFLICT(run_id, tool_call_id) DO UPDATE SET
                    tool_kind = excluded.tool_kind, state = excluded.state,
                    heartbeat_at = excluded.heartbeat_at, deadline_at = excluded.deadline_at,
                    process_pid = COALESCE(excluded.process_pid, process_pid),
                    durable_job_id = COALESCE(excluded.durable_job_id, durable_job_id)",
                params![
                    execution.tool_call_id,
                    execution.run_id.to_string(),
                    execution.tool_kind,
                    execution.state.as_str(),
                    execution.started_at,
                    execution.heartbeat_at,
                    execution.deadline_at,
                    execution.process_pid.map(i64::from),
                    execution.durable_job_id.map(|id| id.to_string()),
                    execution.completed_at,
                    execution.exit_status,
                    execution.failure_class,
                ],
            )
            .map(|_| ())
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    async fn finish_tool_execution(
        &self,
        run_id: Uuid,
        tool_call_id: &str,
        state: MissionToolExecutionState,
        exit_status: Option<i32>,
        failure_class: Option<&str>,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let tool_call_id = tool_call_id.to_string();
        let failure_class = failure_class.map(str::to_string);
        let now = now_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE mission_tool_executions SET state = ?1, heartbeat_at = ?2,
                    completed_at = ?2, exit_status = ?3, failure_class = ?4
                 WHERE run_id = ?5 AND tool_call_id = ?6",
                params![
                    state.as_str(),
                    now,
                    exit_status,
                    failure_class,
                    run_id.to_string(),
                    tool_call_id
                ],
            )
            .map(|changed| changed == 1)
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    async fn list_active_tool_executions(
        &self,
        run_id: Uuid,
    ) -> Result<Vec<MissionToolExecution>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT tool_call_id, run_id, tool_kind, state, started_at, heartbeat_at, deadline_at, process_pid, durable_job_id, completed_at, exit_status, failure_class
                     FROM mission_tool_executions WHERE run_id = ?1 AND state IN ('provisional', 'running') ORDER BY started_at ASC",
                )
                .map_err(|error| error.to_string())?;
            let rows = stmt
                .query_map(params![run_id.to_string()], parse_tool_execution_row)
                .map_err(|error| error.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|error| error.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|error| error.to_string())?
    }

    async fn get_initial_user_message(&self, id: Uuid) -> Result<Option<String>, String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let row = conn
                .query_row(
                    "SELECT content, content_file FROM mission_events
                     WHERE mission_id = ?1 AND event_type = 'user_message'
                     ORDER BY sequence ASC LIMIT 1",
                    params![id_str],
                    |row| {
                        Ok((
                            row.get::<_, Option<String>>(0)?,
                            row.get::<_, Option<String>>(1)?,
                        ))
                    },
                )
                .optional()
                .map_err(|error| error.to_string())?;
            match row {
                Some((Some(content), _)) => Ok(Some(content)),
                Some((None, Some(path))) => std::fs::read_to_string(&path)
                    .map(Some)
                    .map_err(|error| format!("read initial mission prompt {path}: {error}")),
                _ => Ok(None),
            }
        })
        .await
        .map_err(|error| error.to_string())?
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
        let conn = self.conn.clone();
        let now = now_string();
        let id = assigned_id.unwrap_or_else(Uuid::new_v4);
        // Inherit workspace from parent mission when not explicitly provided.
        let workspace_id = if let Some(ws) = workspace_id {
            ws
        } else if let Some(parent_id) = parent_mission_id {
            match self.get_mission(parent_id).await {
                Ok(Some(parent)) => parent.workspace_id,
                _ => crate::workspace::DEFAULT_WORKSPACE_ID,
            }
        } else {
            crate::workspace::DEFAULT_WORKSPACE_ID
        };
        let backend = backend.unwrap_or("claudecode").to_string();
        let metadata_source = title.and_then(|value| {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(METADATA_SOURCE_USER.to_string())
            }
        });
        let metadata_updated_at = metadata_source.as_ref().map(|_| now.clone());
        // Generate session_id for conversation persistence (used by Claude Code --session-id)
        let session_id = Uuid::new_v4().to_string();

        let mission = Mission {
            id,
            status: MissionStatus::Pending,
            title: title.map(|s| s.to_string()),
            short_description: None,
            metadata_updated_at,
            metadata_source,
            metadata_model: None,
            metadata_version: None,
            workspace_id,
            workspace_name: None,
            agent: agent.map(|s| s.to_string()),
            model_override: model_override.map(|s| s.to_string()),
            model_effort: model_effort.map(|s| s.to_string()),
            fast_mode,
            service_tier: None,
            backend: backend.clone(),
            config_profile: config_profile.map(|s| s.to_string()),
            history: vec![],
            created_at: now.clone(),
            updated_at: now.clone(),
            interrupted_at: None,
            paused_at: None,
            resumable: false,
            desktop_sessions: Vec::new(),
            session_id: (!matches!(backend.as_str(), "grok" | "antigravity" | "vibe"))
                .then(|| session_id.clone()),
            terminal_reason: None,
            terminal_evidence: None,
            parent_mission_id,
            working_directory: working_directory.map(|s| s.to_string()),
            requires_local_disk,
            mission_mode: MissionMode::default(),
            goal_mode: false,
            goal_objective: None,
            first_viewed_at: None,
            scheduling: Default::default(),
            project: MissionProject::default(),
            activity: MissionActivity::default(),
            awaiting_kind: None,
            origin: None,
            origin_session_id: None,
        };

        let m = mission.clone();
        let mission_mode_str = serde_json::to_value(&m.mission_mode)
            .ok()
            .and_then(|v| v.as_str().map(|s| s.to_string()))
            .unwrap_or_else(|| "task".to_string());
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO missions (id, status, title, short_description, metadata_updated_at, metadata_source, metadata_model, metadata_version, workspace_id, agent, model_override, model_effort, backend, config_profile, created_at, updated_at, resumable, session_id, parent_mission_id, working_directory, mission_mode, goal_mode, goal_objective, last_status_change_at, fast_mode, requires_local_disk)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26)",
                params![
                    m.id.to_string(),
                    status_to_string(m.status),
                    m.title,
                    m.short_description,
                    m.metadata_updated_at,
                    m.metadata_source,
                    m.metadata_model,
                    m.metadata_version,
                    m.workspace_id.to_string(),
                    m.agent,
                    m.model_override,
                    m.model_effort,
                    m.backend,
                    m.config_profile,
                    m.created_at,
                    m.updated_at,
                    0,
                    m.session_id,
                    m.parent_mission_id.map(|id| id.to_string()),
                    m.working_directory,
                    mission_mode_str,
                    if m.goal_mode { 1i64 } else { 0i64 },
                    m.goal_objective,
                    m.created_at,
                    if m.fast_mode { 1i64 } else { 0i64 },
                    if m.requires_local_disk { 1i64 } else { 0i64 },
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;

        Ok(mission)
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
        self.create_mission_with_parent_and_placement(
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
            true,
            None,
        )
        .await
    }

    async fn reparent_child_missions(&self, from: Uuid, to: Uuid) -> Result<Vec<Uuid>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare("UPDATE missions SET parent_mission_id = ?2 WHERE parent_mission_id = ?1 RETURNING id")
                .map_err(|e| e.to_string())?;
            let moved = stmt
                .query_map(params![from.to_string(), to.to_string()], |row| row.get::<_, String>(0))
                .map_err(|e| e.to_string())?
                .filter_map(|id| id.ok().and_then(|id| Uuid::parse_str(&id).ok()))
                .collect();
            Ok(moved)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_child_missions(&self, parent_id: Uuid) -> Result<Vec<Mission>, String> {
        let conn = self.conn.clone();
        let parent_id_str = parent_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare("SELECT id, status, title, short_description, metadata_updated_at, metadata_source, metadata_model, metadata_version, workspace_id, agent, model_override, model_effort, backend, config_profile, created_at, updated_at, interrupted_at, resumable, session_id, terminal_reason, parent_mission_id, working_directory, COALESCE(mission_mode, 'task') as mission_mode, COALESCE(fast_mode, 0) as fast_mode, COALESCE(requires_local_disk, 1) as requires_local_disk, service_tier FROM missions WHERE parent_mission_id = ?1")
                .map_err(|e| e.to_string())?;
            let missions = stmt
                .query_map(params![parent_id_str], |row| {
                    Ok(Mission {
                        id: Uuid::parse_str(&row.get::<_, String>(0)?).unwrap_or_default(),
                        status: parse_status(&row.get::<_, String>(1)?),
                        title: row.get(2)?,
                        short_description: row.get(3)?,
                        metadata_updated_at: row.get(4)?,
                        metadata_source: row.get(5)?,
                        metadata_model: row.get(6)?,
                        metadata_version: row.get(7)?,
                        workspace_id: Uuid::parse_str(&row.get::<_, String>(8)?).unwrap_or_default(),
                        workspace_name: None,
                        agent: row.get(9)?,
                        model_override: row.get(10)?,
                        model_effort: row.get(11)?,
                        fast_mode: row.get::<_, i32>(23)? != 0,
                        service_tier: read_service_tier(row)?,
                        backend: row.get::<_, String>(12)?,
                        config_profile: row.get(13)?,
                        history: vec![],
                        created_at: row.get(14)?,
                        updated_at: row.get(15)?,
                        interrupted_at: row.get(16)?,
                        paused_at: None,
                        resumable: row.get::<_, i32>(17)? != 0,
                        desktop_sessions: Vec::new(),
                        session_id: row.get(18)?,
                        terminal_reason: row.get(19)?,
                        terminal_evidence: None,
                        parent_mission_id: row.get::<_, Option<String>>(20)?.and_then(|s| Uuid::parse_str(&s).ok()),
                        working_directory: row.get(21)?,
                        requires_local_disk: row.get::<_, i32>(24)? != 0,
                        mission_mode: row.get::<_, Option<String>>(22)?
                            .and_then(|s| serde_json::from_value(serde_json::Value::String(s)).ok())
                            .unwrap_or_default(),
                            goal_mode: false,
                            goal_objective: None,
                            first_viewed_at: None,
                            scheduling: Default::default(),
                            project: MissionProject::default(),
                            activity: MissionActivity::default(),
                            awaiting_kind: None,
                            origin: None,
                            origin_session_id: None,
                    })
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(missions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn set_mission_requires_local_disk(
        &self,
        id: Uuid,
        requires_local_disk: bool,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET requires_local_disk = ?1, updated_at = ?2 WHERE id = ?3",
                params![
                    if requires_local_disk { 1i64 } else { 0i64 },
                    now_string(),
                    id.to_string()
                ],
            )
            .map_err(|error| error.to_string())
            .and_then(|updated| {
                (updated == 1)
                    .then_some(())
                    .ok_or_else(|| format!("mission {id} not found while persisting placement"))
            })
        })
        .await
        .map_err(|error| error.to_string())?
    }

    async fn update_mission_status(&self, id: Uuid, status: MissionStatus) -> Result<(), String> {
        self.update_mission_status_with_reason(id, status, None)
            .await
    }

    async fn set_mission_scheduling(
        &self,
        id: Uuid,
        scheduling: &MissionScheduling,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let priority = scheduling.priority;
        let not_before = scheduling.not_before.clone();
        let deadline = scheduling.deadline.clone();
        let now = now_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET priority = ?1, not_before = ?2, deadline = ?3, updated_at = ?4 WHERE id = ?5",
                params![priority, not_before, deadline, now, id.to_string()],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn update_mission_status_with_reason(
        &self,
        id: Uuid,
        status: MissionStatus,
        terminal_reason: Option<&str>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let now = now_string();
        let interrupted_at =
            if matches!(status, MissionStatus::Interrupted | MissionStatus::Blocked) {
                Some(now.clone())
            } else {
                None
            };
        // Failed missions with LlmError are also resumable (transient API errors).
        // AwaitingUser missions are also resumable (the user can send another
        // message at any time to wake the agent back up).
        let resumable = matches!(
            status,
            MissionStatus::Interrupted
                | MissionStatus::Blocked
                | MissionStatus::Failed
                | MissionStatus::AwaitingUser
                | MissionStatus::Acknowledged
                | MissionStatus::WaitingBackground
        );
        let terminal_reason = terminal_reason.map(|s| s.to_string());
        // Transitioning back to Active means the user just sent a new message —
        // clear `first_viewed_at` so the next AwaitingUser round starts fresh
        // (and so the "opened" dot disappears once the agent picks up again).
        let clear_first_viewed_at = matches!(status, MissionStatus::Active);
        // `awaiting_kind` only describes an `AwaitingUser` mission. Any status
        // change away from AwaitingUser must clear it so a stale classification
        // can't leak to consumers once the mission is running/terminal again.
        let clear_awaiting_kind = !matches!(status, MissionStatus::AwaitingUser);

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            if status == MissionStatus::Acknowledged {
                let active_run = conn
                    .query_row(
                        "SELECT run_id FROM mission_runs WHERE mission_id = ?1 AND execution_state <> 'terminal' LIMIT 1",
                        params![id.to_string()],
                        |row| row.get::<_, String>(0),
                    )
                    .optional()
                    .map_err(|error| error.to_string())?;
                if let Some(run_id) = active_run {
                    return Err(format!(
                        "mission {id} cannot be acknowledged while run {run_id} is non-terminal"
                    ));
                }
            }
            // Read the old status before the UPDATE so we can decide whether
            // to invalidate the Paloma cooldown. Wiping cooldown on a
            // no-op status write (e.g. heartbeat that re-sets Active=Active)
            // would let "still running" alerts skip past the user's
            // exponential backoff and arrive too soon.
            let previous_status: Option<String> = conn
                .query_row(
                    "SELECT status FROM missions WHERE id = ?1",
                    params![id.to_string()],
                    |row| row.get(0),
                )
                .ok();
            let updated = if clear_first_viewed_at {
                conn.execute(
                    "UPDATE missions SET status = ?1, updated_at = ?2, interrupted_at = ?3, resumable = ?4, terminal_reason = ?5, first_viewed_at = NULL, awaiting_kind = CASE WHEN ?7 THEN NULL ELSE awaiting_kind END, last_status_change_at = CASE WHEN status <> ?1 THEN ?2 ELSE last_status_change_at END WHERE id = ?6",
                    params![
                        status_to_string(status),
                        now,
                        interrupted_at,
                        if resumable { 1 } else { 0 },
                        terminal_reason,
                        id.to_string(),
                        clear_awaiting_kind,
                    ],
                )
                .map_err(|e| e.to_string())?
            } else {
                conn.execute(
                    "UPDATE missions SET status = ?1, updated_at = ?2, interrupted_at = ?3, resumable = ?4, terminal_reason = ?5, awaiting_kind = CASE WHEN ?7 THEN NULL ELSE awaiting_kind END, last_status_change_at = CASE WHEN status <> ?1 THEN ?2 ELSE last_status_change_at END WHERE id = ?6",
                    params![
                        status_to_string(status),
                        now,
                        interrupted_at,
                        if resumable { 1 } else { 0 },
                        terminal_reason,
                        id.to_string(),
                        clear_awaiting_kind,
                    ],
                )
                .map_err(|e| e.to_string())?
            };
            if updated != 1 {
                return Err(format!(
                    "mission {id} not found while updating status to {}",
                    status_to_string(status)
                ));
            }
            // Only reset cooldown on a *genuine* status transition. Best
            // effort — if the table is missing or the row is gone, nothing
            // to do.
            let status_changed = previous_status.as_deref() != Some(status_to_string(status));
            if status_changed {
                let _ = conn.execute(
                    "DELETE FROM paloma_cooldown_state WHERE mission_id = ?1",
                    params![id.to_string()],
                );
            }
            Ok::<(), String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(())
    }

    async fn update_mission_history(
        &self,
        id: Uuid,
        _history: &[MissionHistoryEntry],
    ) -> Result<(), String> {
        // For SQLite store, history is derived from events logged via log_event().
        // This method only updates the mission's updated_at timestamp.
        // Events are NOT inserted here to avoid race condition duplicates with the
        // event logger task that also inserts via log_event().
        let conn = self.conn.clone();
        let now = now_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();

            conn.execute(
                "UPDATE missions SET updated_at = ?1 WHERE id = ?2",
                params![&now, id.to_string()],
            )
            .map_err(|e| e.to_string())?;

            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn set_mission_first_viewed_at_if_unset(
        &self,
        id: Uuid,
        timestamp: &str,
    ) -> Result<Option<String>, String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let ts = timestamp.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let updated = conn
                .execute(
                    "UPDATE missions SET first_viewed_at = ?1 WHERE id = ?2 AND (first_viewed_at IS NULL OR first_viewed_at < ?1)",
                    params![&ts, &id_str],
                )
                .map_err(|e| e.to_string())?;
            Ok(if updated > 0 { Some(ts) } else { None })
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn acknowledge_stale_awaiting_user_missions(
        &self,
        grace_seconds: u64,
    ) -> Result<Vec<Uuid>, String> {
        let conn = self.conn.clone();
        let cutoff = (Utc::now() - chrono::Duration::seconds(grace_seconds as i64)).to_rfc3339();
        let now = now_string();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction().map_err(|e| e.to_string())?;
            let ids: Vec<Uuid> = {
                let mut stmt = tx
                    .prepare(
                        "SELECT id FROM missions
                         WHERE status = 'awaiting_user'
                           AND first_viewed_at IS NOT NULL
                           AND first_viewed_at <= ?1
                           AND NOT EXISTS (
                               SELECT 1 FROM mission_runs r
                               WHERE r.mission_id = missions.id AND r.execution_state <> 'terminal'
                           )",
                    )
                    .map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![&cutoff], |row| {
                        let id_str: String = row.get(0)?;
                        Ok(parse_uuid_or_nil(&id_str))
                    })
                    .map_err(|e| e.to_string())?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| e.to_string())?;
                rows
            };
            if !ids.is_empty() {
                tx.execute(
                    "UPDATE missions SET status = 'acknowledged', updated_at = ?1
                     WHERE status = 'awaiting_user'
                       AND first_viewed_at IS NOT NULL
                       AND first_viewed_at <= ?2
                       AND NOT EXISTS (
                           SELECT 1 FROM mission_runs r
                           WHERE r.mission_id = missions.id AND r.execution_state <> 'terminal'
                       )",
                    params![&now, &cutoff],
                )
                .map_err(|e| e.to_string())?;
            }
            tx.commit().map_err(|e| e.to_string())?;
            Ok(ids)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_waiting_background_mission_ids(&self) -> Result<Vec<Uuid>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare("SELECT id FROM missions WHERE status = 'waiting_background'")
                .map_err(|e| e.to_string())?;
            let ids = stmt
                .query_map([], |row| {
                    let id_str: String = row.get(0)?;
                    Ok(parse_uuid_or_nil(&id_str))
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(ids)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn update_mission_desktop_sessions(
        &self,
        id: Uuid,
        sessions: &[DesktopSessionInfo],
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let now = now_string();
        let sessions_json = serde_json::to_string(sessions).unwrap_or_else(|_| "[]".to_string());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET desktop_sessions = ?1, updated_at = ?2 WHERE id = ?3",
                params![sessions_json, now, id.to_string()],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn update_mission_title(&self, id: Uuid, title: &str) -> Result<(), String> {
        let conn = self.conn.clone();
        let now = now_string();
        let title = title.to_string();
        let source = "user".to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions
                 SET title = ?1,
                     metadata_source = ?2,
                     metadata_model = NULL,
                     metadata_version = NULL,
                     metadata_updated_at = ?3,
                     updated_at = ?4
                 WHERE id = ?5",
                params![title, source, now.clone(), now, id.to_string()],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn save_control_queue(&self, _user_id: &str, payload: &str) -> Result<(), String> {
        let conn = self.conn.clone();
        let payload = payload.to_string();
        let now = now_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO control_queue (id, payload, updated_at) VALUES (1, ?1, ?2)
                 ON CONFLICT(id) DO UPDATE SET payload = ?1, updated_at = ?2",
                params![payload, now],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn load_control_queue(&self, _user_id: &str) -> Result<String, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let payload: Option<String> = conn
                .query_row(
                    "SELECT payload FROM control_queue WHERE id = 1",
                    [],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|e| e.to_string())?;
            Ok(payload.unwrap_or_default())
        })
        .await
        .map_err(|e| e.to_string())?
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
        let fast_mode = service_tier
            .map(|tier| tier == crate::codex_speed::Tier::Fast)
            .or(fast_mode);
        let conn = self.conn.clone();
        let now = now_string();
        let backend_set = backend.is_some();
        let agent_set = agent.is_some();
        let model_override_set = model_override.is_some();
        let model_effort_set = model_effort.is_some();
        let tier = service_tier
            .or(fast_mode.map(|fast| crate::codex_speed::Tier::from_legacy(None, fast)));
        let tier_set = tier.is_some();
        let tier = tier.map(|value| value.id().to_string());
        let fast_mode_set = fast_mode.is_some();
        let config_profile_set = config_profile.is_some();
        let backend = backend.map(ToString::to_string);
        let agent = agent.flatten().map(ToString::to_string);
        let model_override = model_override.flatten().map(ToString::to_string);
        let model_effort = model_effort.flatten().map(ToString::to_string);
        let config_profile = config_profile.flatten().map(ToString::to_string);
        let session_id = session_id.to_string();
        let id_str = id.to_string();

        tokio::task::spawn_blocking(move || {
            let mut connection = conn.blocking_lock();
            let conn = connection.transaction().map_err(|e| e.to_string())?;
            let (old_backend, old_session): (String, Option<String>) = conn.query_row(
                "SELECT COALESCE(backend, 'opencode'), session_id FROM missions WHERE id = ?1",
                params![id_str], |row| Ok((row.get(0)?, row.get(1)?)),
            ).map_err(|e| e.to_string())?;
            let target = backend.as_deref().unwrap_or(&old_backend);
            let selected_session = if target == old_backend {
                old_session
            } else {
                if let Some(previous) = old_session {
                    conn.execute(
                        "INSERT INTO mission_harness_sessions (mission_id, backend, session_id) VALUES (?1, ?2, ?3)
                         ON CONFLICT(mission_id, backend) DO UPDATE SET session_id = excluded.session_id",
                        params![id_str, old_backend, previous],
                    ).map_err(|e| e.to_string())?;
                }
                conn.query_row(
                    "SELECT session_id FROM mission_harness_sessions WHERE mission_id = ?1 AND backend = ?2",
                    params![id_str, target], |row| row.get::<_, String>(0),
                ).optional().map_err(|e| e.to_string())?
                    .or_else(|| (!matches!(target, "grok" | "antigravity" | "vibe")).then(|| session_id.clone()))
            };
            let changed = conn
                .execute(
                    "UPDATE missions
                     SET backend = CASE WHEN ?1 THEN ?2 ELSE backend END,
                         agent = CASE WHEN ?3 THEN ?4 ELSE agent END,
                         model_override = CASE WHEN ?5 THEN ?6 ELSE model_override END,
                         model_effort = CASE WHEN ?7 THEN ?8 ELSE model_effort END,
                         fast_mode = CASE WHEN ?9 THEN ?10 ELSE fast_mode END,
                         config_profile = CASE WHEN ?11 THEN ?12 ELSE config_profile END,
                         session_id = ?13,
                         service_tier = CASE WHEN ?16 THEN ?17 ELSE service_tier END,
                         updated_at = ?14
                     WHERE id = ?15",
                    params![
                        backend_set,
                        backend,
                        agent_set,
                        agent,
                        model_override_set,
                        model_override,
                        model_effort_set,
                        model_effort,
                        fast_mode_set,
                        fast_mode,
                        config_profile_set,
                        config_profile,
                        selected_session,
                        now,
                        id_str,
                        tier_set,
                        tier,
                    ],
                )
                .map_err(|e| e.to_string())?;
            if changed == 0 {
                return Err(format!("Mission {} not found", id_str));
            }
            conn.commit().map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())??;

        self.get_mission(id)
            .await?
            .ok_or_else(|| format!("Mission {} not found", id))
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
        if title.is_none()
            && short_description.is_none()
            && metadata_source.is_none()
            && metadata_model.is_none()
            && metadata_version.is_none()
        {
            return Ok(());
        }

        let conn = self.conn.clone();
        let now = now_string();
        let title_set = title.is_some();
        let short_description_set = short_description.is_some();
        let metadata_source_set = metadata_source.is_some();
        let metadata_model_set = metadata_model.is_some();
        let metadata_version_set = metadata_version.is_some();
        let title = title.flatten().map(|s| s.to_string());
        let short_description = short_description.flatten().map(|s| s.to_string());
        let metadata_source = metadata_source.flatten().map(|s| s.to_string());
        let metadata_model = metadata_model.flatten().map(|s| s.to_string());
        let metadata_version = metadata_version.flatten().map(|s| s.to_string());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions
                 SET title = CASE WHEN ?1 THEN ?2 ELSE title END,
                     short_description = CASE WHEN ?3 THEN ?4 ELSE short_description END,
                     metadata_source = CASE WHEN ?5 THEN ?6 ELSE metadata_source END,
                     metadata_model = CASE WHEN ?7 THEN ?8 ELSE metadata_model END,
                     metadata_version = CASE WHEN ?9 THEN ?10 ELSE metadata_version END,
                     metadata_updated_at = ?11,
                     updated_at = ?11
                 WHERE id = ?12",
                params![
                    title_set,
                    title,
                    short_description_set,
                    short_description,
                    metadata_source_set,
                    metadata_source,
                    metadata_model_set,
                    metadata_model,
                    metadata_version_set,
                    metadata_version,
                    now,
                    id.to_string()
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn update_mission_project(
        &self,
        id: Uuid,
        patch: MissionProjectPatch,
    ) -> Result<(), String> {
        if patch.is_empty() {
            return Ok(());
        }

        let conn = self.conn.clone();
        let now = now_string();
        let title_set = patch.title.is_some();
        let title = patch.title.flatten();
        let project_set = patch.project.is_some();
        let track_set = patch.track.is_some();
        let intent_set = patch.intent.is_some();
        let github_pr_set = patch.github_pr.is_some();
        let tags_set = patch.tags.is_some() || patch.tag_patch.is_some();
        let desired_state_set = patch.desired_state.is_some();
        let next_check_at_set = patch.next_check_at.is_some();
        let project = patch.project.flatten();
        let track = patch.track.flatten();
        let intent = patch.intent.flatten();
        let github_pr = patch.github_pr.flatten();
        let mut tags_json = patch.tags.as_deref().and_then(tags_to_json);
        let desired_state = patch.desired_state.flatten();
        let next_check_at = patch.next_check_at.flatten();

        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(|e| e.to_string())?;
            if let Some(delta) = patch.tag_patch {
                let raw: Option<String> = tx
                    .query_row(
                        "SELECT tags FROM missions WHERE id=?1",
                        params![id.to_string()],
                        |row| row.get(0),
                    )
                    .map_err(|e| e.to_string())?;
                let mut tags: Vec<String> = match tags_json.as_ref().or(raw.as_ref()) {
                    Some(raw) => serde_json::from_str(raw).map_err(|e| e.to_string())?,
                    None => Vec::new(),
                };
                delta.apply(&mut tags);
                tags_json = tags_to_json(&tags);
            }
            tx.execute(
                "UPDATE missions
                 SET project = CASE WHEN ?1 THEN ?2 ELSE project END,
                     track = CASE WHEN ?3 THEN ?4 ELSE track END,
                     intent = CASE WHEN ?5 THEN ?6 ELSE intent END,
                     github_pr = CASE WHEN ?7 THEN ?8 ELSE github_pr END,
                     tags = CASE WHEN ?9 THEN ?10 ELSE tags END,
                     desired_state = CASE WHEN ?11 THEN ?12 ELSE desired_state END,
                     next_check_at = CASE WHEN ?13 THEN ?14 ELSE next_check_at END,
                     updated_at = CASE WHEN ?19 THEN updated_at ELSE ?15 END,
                     title = CASE WHEN ?17 THEN ?18 ELSE title END
                 WHERE id = ?16",
                params![
                    project_set,
                    project,
                    track_set,
                    track,
                    intent_set,
                    intent,
                    github_pr_set,
                    github_pr,
                    tags_set,
                    tags_json,
                    desired_state_set,
                    desired_state,
                    next_check_at_set,
                    next_check_at,
                    now,
                    id.to_string(),
                    title_set,
                    title,
                    patch.preserve_updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            tx.commit().map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn set_mission_origin(
        &self,
        id: Uuid,
        origin: &str,
        origin_session_id: Option<&str>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let origin = origin.to_string();
        let origin_session_id = origin_session_id.map(|s| s.to_string());
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET origin = ?1, origin_session_id = ?2 WHERE id = ?3",
                params![origin, origin_session_id, id.to_string()],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_mission_activity(
        &self,
        ids: &[Uuid],
    ) -> Result<std::collections::HashMap<Uuid, (Option<String>, Option<String>)>, String> {
        if ids.is_empty() {
            return Ok(std::collections::HashMap::new());
        }
        let conn = self.reader();
        let id_strings: Vec<String> = ids.iter().map(|id| id.to_string()).collect();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let placeholders = vec!["?"; id_strings.len()].join(",");
            // last_agent_event_at = newest event of any kind; last_output_at =
            // newest assistant message (assistant text is logged as either
            // `assistant_message` or `assistant_message_canonical`). Backed by
            // idx_events_mission_timestamp.
            let sql = format!(
                "SELECT mission_id, MAX(timestamp) AS last_event, \
                 MAX(CASE WHEN event_type IN ('assistant_message', 'assistant_message_canonical') THEN timestamp END) AS last_output \
                 FROM mission_events WHERE mission_id IN ({placeholders}) GROUP BY mission_id"
            );
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(rusqlite::params_from_iter(id_strings.iter()), |row| {
                    let mid: String = row.get(0)?;
                    let last_event: Option<String> = row.get(1)?;
                    let last_output: Option<String> = row.get(2)?;
                    Ok((mid, last_event, last_output))
                })
                .map_err(|e| e.to_string())?;
            let mut out = std::collections::HashMap::new();
            for row in rows {
                let (mid, last_event, last_output) = row.map_err(|e| e.to_string())?;
                if let Ok(uuid) = Uuid::parse_str(&mid) {
                    out.insert(uuid, (last_event, last_output));
                }
            }
            Ok(out)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_mission_summaries(
        &self,
        ids: &[Uuid],
    ) -> Result<std::collections::HashMap<Uuid, MissionSummary>, String> {
        if ids.is_empty() {
            return Ok(std::collections::HashMap::new());
        }
        let conn = self.conn.clone();
        let id_strings: Vec<String> = ids.iter().map(|id| id.to_string()).collect();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let placeholders = vec!["?"; id_strings.len()].join(",");
            let sql = format!(
                "SELECT id, title, status, workspace_name, awaiting_kind, \
                 origin_session_id, updated_at, last_status_change_at \
                 FROM missions WHERE id IN ({placeholders})"
            );
            let now = chrono::Utc::now();
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(rusqlite::params_from_iter(id_strings.iter()), |row| {
                    let mid: String = row.get(0)?;
                    let status: String = row.get(2)?;
                    let awaiting_kind: Option<String> = row.get(4)?;
                    let origin_session_id: Option<String> = row.get(5)?;
                    let updated_at: String = row.get(6)?;
                    let last_status_change_at: Option<String> = row.get(7)?;
                    let persisted_clock = last_status_change_at
                        .as_deref()
                        .unwrap_or(updated_at.as_str());
                    let parsed_status =
                        serde_json::from_value::<crate::api::control::events::MissionStatus>(
                            serde_json::Value::String(status.clone()),
                        )
                        .unwrap_or(crate::api::control::events::MissionStatus::Active);
                    let needs_operator = crate::api::operator_attention::needs_operator(
                        &crate::api::operator_attention::OperatorAttentionInput {
                            status: parsed_status,
                            awaiting_kind: awaiting_kind.as_deref(),
                            has_origin_session: origin_session_id
                                .as_deref()
                                .is_some_and(|id| !id.is_empty()),
                            updated_at: persisted_clock,
                            waiting_for_user_tool: false,
                            wait_started_at: None,
                        },
                        now,
                    );
                    Ok((
                        mid,
                        MissionSummary {
                            title: row.get(1)?,
                            status,
                            workspace_name: row.get(3)?,
                            awaiting_kind,
                            needs_operator,
                            origin_session_id,
                            updated_at,
                        },
                    ))
                })
                .map_err(|e| e.to_string())?;
            let mut out = std::collections::HashMap::new();
            for row in rows {
                let (mid, summary) = row.map_err(|e| e.to_string())?;
                if let Ok(uuid) = Uuid::parse_str(&mid) {
                    out.insert(uuid, summary);
                }
            }
            Ok(out)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn set_mission_awaiting_kind(
        &self,
        id: Uuid,
        kind: Option<AwaitingKind>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let kind_str = kind.map(|k| k.as_str().to_string());
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET awaiting_kind = ?1 WHERE id = ?2",
                params![kind_str, id.to_string()],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn native_prompt_attempted(&self, id: Uuid, backend: &str) -> Result<bool, String> {
        let conn = self.conn.clone();
        let backend = backend.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row("SELECT EXISTS(SELECT 1 FROM mission_native_prompt_attempts WHERE mission_id = ?1 AND backend = ?2)", params![id.to_string(), backend], |r| r.get(0)).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    async fn claim_native_prompt(
        &self,
        id: Uuid,
        backend: &str,
        session_id: Option<&str>,
        run: Option<&super::SessionUpdateRun>,
        claim_id: Uuid,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let backend = backend.to_string();
        let session_id = session_id.map(str::to_string);
        let run_stamp = serde_json::to_string(&run).map_err(|e| e.to_string())?;
        let run = run.map(|r| (r.run_id.to_string(), r.generation));
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction().map_err(|e| e.to_string())?;
            let (current_backend, current_session): (String, Option<String>) = tx.query_row("SELECT COALESCE(backend, 'opencode'), session_id FROM missions WHERE id = ?1", [id.to_string()], |r| Ok((r.get(0)?, r.get(1)?))).map_err(|e| e.to_string())?;
            let latest: Option<(String, u64)> = tx.query_row("SELECT run_id, generation FROM mission_runs WHERE mission_id = ?1 ORDER BY generation DESC LIMIT 1", [id.to_string()], |r| Ok((r.get(0)?, r.get(1)?))).optional().map_err(|e| e.to_string())?;
            if backend.is_empty() || current_backend != backend || current_session != session_id || latest != run { return Ok(false); }
            let prior: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM mission_native_prompt_attempts WHERE mission_id = ?1 AND backend = ?2)", params![id.to_string(), backend], |r| r.get(0)).map_err(|e| e.to_string())?;
            if prior && session_id.is_none() { return Ok(false); }
            tx.execute("INSERT OR IGNORE INTO mission_native_prompt_attempts (mission_id, backend) VALUES (?1, ?2)", params![id.to_string(), backend]).map_err(|e| e.to_string())?;
            if !prior {
                tx.execute("INSERT INTO mission_native_prompt_claims (mission_id, backend, claim_id, run_stamp) VALUES (?1, ?2, ?3, ?4)", params![id.to_string(), backend, claim_id.to_string(), run_stamp]).map_err(|e| e.to_string())?;
            }
            tx.commit().map_err(|e| e.to_string())?;
            Ok(true)
        }).await.map_err(|e| e.to_string())?
    }

    async fn release_native_prompt_no_launch(
        &self,
        id: Uuid,
        backend: &str,
        run: Option<&super::SessionUpdateRun>,
        claim_id: Uuid,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let backend = backend.to_string();
        let run_stamp = serde_json::to_string(&run).map_err(|e| e.to_string())?;
        let run = run.map(|r| (r.run_id.to_string(), r.generation));
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction().map_err(|e| e.to_string())?;
            let (current_backend, session): (String, Option<String>) = tx.query_row("SELECT COALESCE(backend, 'opencode'), session_id FROM missions WHERE id = ?1", [id.to_string()], |r| Ok((r.get(0)?, r.get(1)?))).map_err(|e| e.to_string())?;
            let latest: Option<(String, u64)> = tx.query_row("SELECT run_id, generation FROM mission_runs WHERE mission_id = ?1 ORDER BY generation DESC LIMIT 1", [id.to_string()], |r| Ok((r.get(0)?, r.get(1)?))).optional().map_err(|e| e.to_string())?;
            if backend.is_empty() || current_backend != backend || session.is_some() || latest != run { return Ok(false); }
            let deleted = tx.execute("DELETE FROM mission_native_prompt_claims WHERE mission_id = ?1 AND backend = ?2 AND claim_id = ?3 AND run_stamp = ?4", params![id.to_string(), backend, claim_id.to_string(), run_stamp]).map_err(|e| e.to_string())?;
            if deleted != 1 { return Ok(false); }
            tx.execute("DELETE FROM mission_native_prompt_attempts WHERE mission_id = ?1 AND backend = ?2", params![id.to_string(), backend]).map_err(|e| e.to_string())?;
            tx.commit().map_err(|e| e.to_string())?;
            Ok(true)
        }).await.map_err(|e| e.to_string())?
    }

    async fn update_mission_session_id(
        &self,
        id: Uuid,
        session_id: &str,
        backend: &str,
        run: Option<&super::SessionUpdateRun>,
    ) -> Result<bool, String> {
        if backend.is_empty() {
            return Err("native session update requires harness provenance".into());
        }
        let conn = self.conn.clone();
        let now = now_string();
        let run = run.map(|r| (r.run_id.to_string(), r.generation));
        let session_id = session_id.to_string();
        let backend = backend.to_string();
        tokio::task::spawn_blocking(move || {
            let mut connection = conn.blocking_lock();
            let tx = connection.transaction().map_err(|e| e.to_string())?;
            let current_backend: String = tx.query_row(
                "SELECT COALESCE(backend, 'opencode') FROM missions WHERE id = ?1",
                params![id.to_string()], |row| row.get(0),
            ).map_err(|e| e.to_string())?;
            let latest: Option<(String, u64)> = tx.query_row(
                "SELECT run_id, generation FROM mission_runs WHERE mission_id = ?1 ORDER BY generation DESC LIMIT 1",
                params![id.to_string()], |row| Ok((row.get(0)?, row.get(1)?)),
            ).optional().map_err(|e| e.to_string())?;
            if latest != run {
                return Ok(false);
            }
            tx.execute(
                "INSERT INTO mission_harness_sessions (mission_id, backend, session_id) VALUES (?1, ?2, ?3)
                 ON CONFLICT(mission_id, backend) DO UPDATE SET session_id = excluded.session_id",
                params![id.to_string(), backend, session_id],
            ).map_err(|e| e.to_string())?;
            if current_backend == backend {
                tx.execute(
                    "UPDATE missions SET session_id = ?1, updated_at = ?2 WHERE id = ?3",
                    params![session_id, now, id.to_string()],
                ).map_err(|e| e.to_string())?;
            }
            tx.commit().map_err(|e| e.to_string())?;
            Ok(true)
        }).await.map_err(|e| e.to_string())?
    }

    async fn clear_unsubmitted_session_id(
        &self,
        id: Uuid,
        session_id: &str,
        backend: &str,
        run: &super::SessionUpdateRun,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let session_id = session_id.to_string();
        let backend = backend.to_string();
        let run = (run.run_id.to_string(), run.generation);
        tokio::task::spawn_blocking(move || {
            let mut c = conn.blocking_lock();
            let tx = c.transaction().map_err(|e| e.to_string())?;
            let latest: Option<(String,u64)> = tx.query_row(
                "SELECT run_id,generation FROM mission_runs WHERE mission_id=?1 ORDER BY generation DESC LIMIT 1",
                [id.to_string()], |row| Ok((row.get(0)?,row.get(1)?)),
            ).optional().map_err(|e| e.to_string())?;
            if latest != Some(run) { return Ok(false); }
            let removed = tx.execute("DELETE FROM mission_harness_sessions WHERE mission_id=?1 AND backend=?2 AND session_id=?3", params![id.to_string(),backend,session_id]).map_err(|e| e.to_string())?;
            if removed == 0 {
                // Without a recorded native session, only the mission's own
                // never-submitted placeholder identity may be cleared.
                let recorded: i64 = tx.query_row("SELECT COUNT(*) FROM mission_harness_sessions WHERE mission_id=?1 AND backend=?2", params![id.to_string(),backend], |row| row.get(0)).map_err(|e| e.to_string())?;
                if recorded > 0 { return Ok(false); }
            }
            let cleared = tx.execute("UPDATE missions SET session_id=NULL,updated_at=?4 WHERE id=?1 AND backend=?2 AND session_id=?3",params![id.to_string(),backend,session_id,now_string()]).map_err(|e| e.to_string())?;
            if removed == 0 && cleared == 0 { return Ok(false); }
            tx.commit().map_err(|e| e.to_string())?;
            Ok(true)
        }).await.map_err(|e| e.to_string())?
    }

    async fn update_mission_goal(
        &self,
        id: Uuid,
        goal_mode: bool,
        goal_objective: Option<&str>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let now = now_string();
        let goal_objective = goal_objective.map(|s| s.to_string());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET goal_mode = ?1, goal_objective = ?2, updated_at = ?3 WHERE id = ?4",
                params![
                    if goal_mode { 1i64 } else { 0i64 },
                    goal_objective,
                    now,
                    id.to_string()
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn update_mission_tree(&self, id: Uuid, tree: &AgentTreeNode) -> Result<(), String> {
        let conn = self.conn.clone();
        let now = now_string();
        let tree_json = serde_json::to_string(tree).map_err(|e| e.to_string())?;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT OR REPLACE INTO mission_trees (mission_id, tree_json, updated_at)
                 VALUES (?1, ?2, ?3)",
                params![id.to_string(), tree_json, now],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_mission_tree(&self, id: Uuid) -> Result<Option<AgentTreeNode>, String> {
        let conn = self.conn.clone();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let tree_json: Option<String> = conn
                .query_row(
                    "SELECT tree_json FROM mission_trees WHERE mission_id = ?1",
                    params![id.to_string()],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|e| e.to_string())?;

            if let Some(json) = tree_json {
                let tree: AgentTreeNode = serde_json::from_str(&json).map_err(|e| e.to_string())?;
                Ok(Some(tree))
            } else {
                Ok(None)
            }
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn delete_mission(&self, id: Uuid) -> Result<bool, String> {
        let conn = self.conn.clone();

        let removed = tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let rows = conn
                .execute(
                    "DELETE FROM missions WHERE id = ?1",
                    params![id.to_string()],
                )
                .map_err(|e| e.to_string())?;
            Ok::<bool, String>(rows > 0)
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(removed)
    }

    async fn delete_empty_untitled_missions_excluding(
        &self,
        exclude: &[Uuid],
    ) -> Result<usize, String> {
        let conn = self.conn.clone();
        let exclude_strs: Vec<String> = exclude.iter().map(|id| id.to_string()).collect();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();

            // Find missions to delete
            let mut stmt = conn
                .prepare(
                    "SELECT m.id, COALESCE(goal_mode, 0) as goal_mode, goal_objective FROM missions m
                     LEFT JOIN mission_events e ON m.id = e.mission_id AND e.event_type IN ('user_message', 'assistant_message')
                     WHERE m.status = 'active'
                       AND (m.title IS NULL OR m.title = '' OR m.title = 'Untitled Mission')
                     GROUP BY m.id
                     HAVING COUNT(e.id) = 0",
                )
                .map_err(|e| e.to_string())?;

            let to_delete: Vec<String> = stmt
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(|e| e.to_string())?
                .filter_map(|r| r.ok())
                .filter(|id| !exclude_strs.contains(id))
                .collect();

            let count = to_delete.len();
            for id in to_delete {
                conn.execute("DELETE FROM missions WHERE id = ?1", params![id])
                    .ok();
            }

            Ok(count)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_stale_active_missions(&self, stale_hours: u64) -> Result<Vec<Mission>, String> {
        if stale_hours == 0 {
            return Ok(Vec::new());
        }

        let conn = self.conn.clone();
        let cutoff = Utc::now() - chrono::Duration::hours(stale_hours as i64);
        let cutoff_str = cutoff.to_rfc3339();

        // A mission is stale only when *both* its metadata `updated_at` and
        // its newest event are older than the cutoff. Previously the query
        // looked at `updated_at` alone, but `updated_at` is bumped by
        // `update_mission_history` (assistant-turn boundary) and metadata
        // writes — not by individual `tool_call` / `tool_result` events. A
        // long agent run that's actively producing tool calls but no
        // assistant turns for >2h (e.g. waiting on a CI build via repeated
        // `gh run watch` invocations) would falsely trip this scan. Joining
        // against `mission_events.timestamp` ties the stale signal to real
        // activity.
        //
        // We compute `MAX(timestamp)` rather than the timestamp of the row
        // with the highest `sequence`: `log_event` updates an existing row
        // in-place when it sees a duplicate `event_id` (e.g. the
        // `text_delta_latest` row gets its `timestamp` rewritten on every
        // streamed delta), so a higher-sequence row can carry an *older*
        // timestamp than a refreshed lower-sequence row. The query is backed
        // by `idx_events_mission_timestamp(mission_id, timestamp DESC)` so
        // the per-mission MAX is an O(log n) seek; missions with no events
        // fall back to `updated_at` via COALESCE.
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // Must use MISSION_LIST_COLUMNS / row_to_mission so origin +
            // project.tags survive. A stub projection left those empty and
            // the 2h cleanup treated Hermes writers as untagged (#842 skip
            // never fired on 08306fdb / 203a49d5).
            let sql = format!(
                "SELECT {MISSION_LIST_COLUMNS} FROM missions
                 WHERE status = 'active'
                   AND max(
                         updated_at,
                         COALESCE(
                           (SELECT MAX(timestamp) FROM mission_events
                            WHERE mission_id = missions.id),
                           updated_at
                         )
                       ) < ?1"
            );
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;

            let missions = stmt
                .query_map(params![cutoff_str], row_to_mission)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(missions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_all_active_missions(&self) -> Result<Vec<Mission>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // Recovery decisions require placement tags, origin and project
            // metadata. A reduced projection silently classified native Orb
            // processes as orphaned Core runs after a service restart.
            let sql =
                format!("SELECT {MISSION_LIST_COLUMNS} FROM missions WHERE status = 'active'");
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
            let missions = stmt
                .query_map(params![], row_to_mission)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(missions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn set_deferred_goal(
        &self,
        mission_id: Uuid,
        goal: Option<String>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let id = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET deferred_goal = ?1 WHERE id = ?2",
                params![goal, id],
            )
            .map_err(|e| e.to_string())?;
            Ok::<(), String>(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_deferred_goal(&self, mission_id: Uuid) -> Result<Option<String>, String> {
        let conn = self.conn.clone();
        let id = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT deferred_goal FROM missions WHERE id = ?1",
                params![id],
                |row| row.get::<_, Option<String>>(0),
            )
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn set_mission_paused_at(
        &self,
        mission_id: Uuid,
        paused_at: Option<String>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let id = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET paused_at = ?1 WHERE id = ?2",
                params![paused_at, id],
            )
            .map_err(|e| e.to_string())?;
            Ok::<(), String>(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_scheduled_pending_missions(&self) -> Result<Vec<Mission>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let sql = format!(
                "SELECT id, status, title, workspace_id, workspace_name, agent, model_override,
                            created_at, updated_at, interrupted_at, resumable, desktop_sessions,
                            COALESCE(backend, 'opencode') as backend,
                            COALESCE(mission_mode, 'task') as mission_mode,
                            COALESCE(goal_mode, 0) as goal_mode,
                            goal_objective,
                            COALESCE(priority, 0) as priority, not_before, deadline
                     FROM missions
                     WHERE status = 'pending' AND deferred_goal IS NOT NULL{}
                     ORDER BY created_at ASC",
                crate::api::control::client_placement::SQL_EXCLUDE
            );
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;

            let missions = stmt
                .query_map(params![], |row| {
                    let id_str: String = row.get(0)?;
                    let status_str: String = row.get(1)?;
                    let workspace_id_str: String = row.get(3)?;
                    let desktop_sessions_json: Option<String> = row.get(11)?;
                    let backend: String = row.get(12)?;

                    Ok(Mission {
                        id: parse_uuid_or_nil(&id_str),
                        status: parse_status(&status_str),
                        title: row.get(2)?,
                        short_description: None,
                        metadata_updated_at: None,
                        metadata_source: None,
                        metadata_model: None,
                        metadata_version: None,
                        workspace_id: Uuid::parse_str(&workspace_id_str)
                            .unwrap_or(crate::workspace::DEFAULT_WORKSPACE_ID),
                        workspace_name: row.get(4)?,
                        agent: row.get(5)?,
                        model_override: row.get(6)?,
                        model_effort: None,
                        fast_mode: false,
                        service_tier: None,
                        backend,
                        config_profile: None,
                        history: vec![],
                        created_at: row.get(7)?,
                        updated_at: row.get(8)?,
                        interrupted_at: row.get(9)?,
                        paused_at: None,
                        resumable: row.get::<_, i32>(10)? != 0,
                        desktop_sessions: desktop_sessions_json
                            .and_then(|s| serde_json::from_str(&s).ok())
                            .unwrap_or_default(),
                        session_id: None,
                        terminal_reason: None,
                        terminal_evidence: None,
                        parent_mission_id: None,
                        working_directory: None,
                        requires_local_disk: true,
                        mission_mode: row
                            .get::<_, Option<String>>(13)?
                            .and_then(|s| serde_json::from_value(serde_json::Value::String(s)).ok())
                            .unwrap_or_default(),
                        goal_mode: row.get::<_, i32>(14).unwrap_or(0) != 0,
                        goal_objective: row.get(15).ok().flatten(),
                        first_viewed_at: None,
                        scheduling: MissionScheduling {
                            priority: row.get::<_, i32>(16).unwrap_or(0),
                            not_before: row.get(17).ok().flatten(),
                            deadline: row.get(18).ok().flatten(),
                        },
                        project: MissionProject::default(),
                        activity: MissionActivity::default(),
                        awaiting_kind: None,
                        origin: None,
                        origin_session_id: None,
                    })
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(missions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_recent_server_shutdown_mission_ids(
        &self,
        max_age_hours: u64,
    ) -> Result<Vec<Uuid>, String> {
        let conn = self.conn.clone();
        let cutoff = Utc::now() - chrono::Duration::hours(max_age_hours as i64);
        let cutoff_str = cutoff.to_rfc3339();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id
                     FROM missions
                     WHERE status = 'interrupted'
                       AND resumable = 1
                       AND terminal_reason IN ('server_shutdown', 'service_restart')
                       AND COALESCE(mission_mode, 'task') != 'assistant'
                       AND interrupted_at IS NOT NULL
                       AND interrupted_at >= ?1
                     ORDER BY interrupted_at ASC",
                )
                .map_err(|e| e.to_string())?;

            let mission_ids = stmt
                .query_map(params![cutoff_str], |row| {
                    let id_str: String = row.get(0)?;
                    Ok(parse_uuid_or_nil(&id_str))
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(mission_ids)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn insert_mission_summary(
        &self,
        mission_id: Uuid,
        summary: &str,
        key_files: &[String],
        success: bool,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let now = now_string();
        let summary = summary.to_string();
        let key_files_json = serde_json::to_string(key_files).unwrap_or_else(|_| "[]".to_string());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO mission_summaries (mission_id, summary, key_files, success, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    mission_id.to_string(),
                    summary,
                    key_files_json,
                    if success { 1 } else { 0 },
                    now,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn latest_assistant_text(&self, mission_id: Uuid) -> Result<Option<String>, String> {
        let conn = self.reader();
        let id_str = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let row = conn
                .query_row(
                    "SELECT content, content_file FROM mission_events
                     WHERE mission_id = ?1
                       AND event_type IN ('assistant_message', 'assistant_message_canonical')
                     ORDER BY sequence DESC LIMIT 1",
                    params![id_str],
                    |row| {
                        let content: Option<String> = row.get(0)?;
                        let content_file: Option<String> = row.get(1)?;
                        Ok((content, content_file))
                    },
                )
                .optional()
                .map_err(|e| e.to_string())?;
            Ok(match row {
                Some((content, content_file)) => {
                    let text = Self::load_content(content.as_deref(), content_file.as_deref());
                    let trimmed = text.trim();
                    if trimmed.is_empty() {
                        None
                    } else {
                        Some(trimmed.to_string())
                    }
                }
                None => None,
            })
        })
        .await
        .map_err(|e| e.to_string())?
    }

    // === Event logging methods ===

    async fn get_remote_log_offset(&self, job_id: Uuid) -> Option<u64> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT published_offset FROM remote_log_offsets WHERE job_id = ?1",
                params![job_id.to_string()],
                |row| row.get::<_, i64>(0),
            )
            .ok()
            .and_then(|v| u64::try_from(v).ok())
        })
        .await
        .ok()
        .flatten()
    }

    async fn set_remote_log_offset(&self, job_id: Uuid, offset: u64) {
        let conn = self.conn.clone();
        let _ = tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let _ = conn.execute(
                "INSERT INTO remote_log_offsets (job_id, published_offset, updated_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(job_id) DO UPDATE SET
                    published_offset = MAX(published_offset, excluded.published_offset),
                    updated_at = excluded.updated_at",
                params![job_id.to_string(), offset as i64, now_string()],
            );
            // Rows of long-finished jobs are useless; keep the table small.
            let _ = conn.execute(
                "DELETE FROM remote_log_offsets WHERE updated_at < ?1",
                params![(chrono::Utc::now() - chrono::Duration::days(14)).to_rfc3339()],
            );
        })
        .await;
    }

    async fn log_event(&self, mission_id: Uuid, event: &AgentEvent) -> Result<(), String> {
        let conn = self.conn.clone();
        let content_dir = self.content_dir.clone();
        let event = event.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            log_event_sync(&conn, &content_dir, mission_id, &event)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn log_events(&self, events: Vec<(Uuid, AgentEvent)>) -> Vec<Result<(), String>> {
        let count = events.len();
        let conn = self.conn.clone();
        let content_dir = self.content_dir.clone();
        let outcome = tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // One commit (one fsync) for the whole batch. A failing event only
            // rolls back its own statement; the others are still committed.
            if let Err(e) = conn.execute_batch("BEGIN IMMEDIATE") {
                return events
                    .iter()
                    .map(|(mid, ev)| log_event_sync(&conn, &content_dir, *mid, ev))
                    .collect::<Vec<_>>()
                    .into_iter()
                    .map(|r| r.map_err(|inner| format!("{inner} (no batch transaction: {e})")))
                    .collect();
            }
            let results: Vec<Result<(), String>> = events
                .iter()
                .map(|(mid, ev)| log_event_sync(&conn, &content_dir, *mid, ev))
                .collect();
            match conn.execute_batch("COMMIT") {
                Ok(()) => results,
                Err(e) => {
                    let _ = conn.execute_batch("ROLLBACK");
                    results
                        .into_iter()
                        .map(|_| Err(format!("batch commit failed: {e}")))
                        .collect()
                }
            }
        })
        .await;
        outcome.unwrap_or_else(|e| (0..count).map(|_| Err(e.to_string())).collect())
    }

    async fn get_latest_events(
        &self,
        mission_id: Uuid,
        limit: usize,
    ) -> Result<Vec<StoredEvent>, String> {
        let conn = self.conn.clone();
        let mid = mission_id.to_string();
        let limit = limit.clamp(1, 50_000) as i64;
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, mission_id, sequence, event_type, timestamp, event_id,
                            tool_call_id, tool_name, content, content_file, metadata
                     FROM mission_events
                     WHERE mission_id = ?1
                     ORDER BY sequence DESC
                     LIMIT ?2",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![mid, limit], |row| {
                    let content: Option<String> = row.get(8)?;
                    let content_file: Option<String> = row.get(9)?;
                    let full_content = SqliteMissionStore::load_content(
                        content.as_deref(),
                        content_file.as_deref(),
                    );
                    let metadata_str: String = row
                        .get::<_, Option<String>>(10)?
                        .unwrap_or_else(|| "{}".to_string());
                    let mid_str: String = row.get(1)?;
                    Ok(StoredEvent {
                        id: row.get(0)?,
                        mission_id: parse_uuid_or_nil(&mid_str),
                        sequence: row.get(2)?,
                        event_type: row.get(3)?,
                        timestamp: row.get(4)?,
                        event_id: row.get(5)?,
                        tool_call_id: row.get(6)?,
                        tool_name: row.get(7)?,
                        content: full_content,
                        metadata: serde_json::from_str(&metadata_str)
                            .unwrap_or(serde_json::json!({})),
                    })
                })
                .map_err(|e| e.to_string())?;
            let mut events = Vec::new();
            for row in rows {
                events.push(row.map_err(|e| e.to_string())?);
            }
            // SQL returned DESC; flip to ASC so callers can keep their
            // existing `iter().rev()` semantics for "walk newest first".
            events.reverse();
            Ok(events)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_events(
        &self,
        mission_id: Uuid,
        event_types: Option<&[&str]>,
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> Result<Vec<StoredEvent>, String> {
        let conn = self.reader();
        let mid = mission_id.to_string();
        let types: Option<Vec<String>> =
            event_types.map(|t| t.iter().map(|s| s.to_string()).collect());
        let limit = limit.unwrap_or(50000) as i64;
        let offset = offset.unwrap_or(0) as i64;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();

            let query = if types.is_some() {
                "SELECT id, mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata
                 FROM mission_events
                 WHERE mission_id = ?1 AND event_type IN (SELECT value FROM json_each(?2))
                 ORDER BY sequence ASC
                 LIMIT ?3 OFFSET ?4"
            } else {
                "SELECT id, mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata
                 FROM mission_events
                 WHERE mission_id = ?1
                 ORDER BY sequence ASC
                 LIMIT ?2 OFFSET ?3"
            };

            // Helper closure to parse a row into StoredEvent
            fn parse_row(row: &rusqlite::Row<'_>) -> Result<StoredEvent, rusqlite::Error> {
                let content: Option<String> = row.get(8)?;
                let content_file: Option<String> = row.get(9)?;
                let full_content = SqliteMissionStore::load_content(content.as_deref(), content_file.as_deref());
                let metadata_str: String = row.get::<_, Option<String>>(10)?.unwrap_or_else(|| "{}".to_string());
                let mid_str: String = row.get(1)?;

                Ok(StoredEvent {
                    id: row.get(0)?,
                    mission_id: parse_uuid_or_nil(&mid_str),
                    sequence: row.get(2)?,
                    event_type: row.get(3)?,
                    timestamp: row.get(4)?,
                    event_id: row.get(5)?,
                    tool_call_id: row.get(6)?,
                    tool_name: row.get(7)?,
                    content: full_content,
                    metadata: serde_json::from_str(&metadata_str).unwrap_or(serde_json::json!({})),
                })
            }

            let events: Vec<StoredEvent> = if let Some(types) = types {
                let types_json = serde_json::to_string(&types).unwrap_or_else(|_| "[]".to_string());
                let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
                let rows = stmt.query_map(params![&mid, &types_json, limit, offset], parse_row)
                    .map_err(|e| e.to_string())?;
                let mut result = Vec::new();
                for row in rows {
                    result.push(row.map_err(|e| e.to_string())?);
                }
                result
            } else {
                let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
                let rows = stmt.query_map(params![&mid, limit, offset], parse_row)
                    .map_err(|e| e.to_string())?;
                let mut result = Vec::new();
                for row in rows {
                    result.push(row.map_err(|e| e.to_string())?);
                }
                result
            };

            Ok(events)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_events_since(
        &self,
        mission_id: Uuid,
        since_seq: i64,
        event_types: Option<&[&str]>,
        limit: Option<usize>,
    ) -> Result<Vec<StoredEvent>, String> {
        let conn = self.reader();
        let mid = mission_id.to_string();
        let types: Option<Vec<String>> =
            event_types.map(|t| t.iter().map(|s| s.to_string()).collect());
        let limit = limit.unwrap_or(50000) as i64;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();

            let query = if types.is_some() {
                "SELECT id, mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata
                 FROM mission_events
                 WHERE mission_id = ?1 AND sequence > ?2 AND event_type IN (SELECT value FROM json_each(?3))
                 ORDER BY sequence ASC
                 LIMIT ?4"
            } else {
                "SELECT id, mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata
                 FROM mission_events
                 WHERE mission_id = ?1 AND sequence > ?2
                 ORDER BY sequence ASC
                 LIMIT ?3"
            };

            fn parse_row(row: &rusqlite::Row<'_>) -> Result<StoredEvent, rusqlite::Error> {
                let content: Option<String> = row.get(8)?;
                let content_file: Option<String> = row.get(9)?;
                let full_content = SqliteMissionStore::load_content(content.as_deref(), content_file.as_deref());
                let metadata_str: String = row.get::<_, Option<String>>(10)?.unwrap_or_else(|| "{}".to_string());
                let mid_str: String = row.get(1)?;

                Ok(StoredEvent {
                    id: row.get(0)?,
                    mission_id: parse_uuid_or_nil(&mid_str),
                    sequence: row.get(2)?,
                    event_type: row.get(3)?,
                    timestamp: row.get(4)?,
                    event_id: row.get(5)?,
                    tool_call_id: row.get(6)?,
                    tool_name: row.get(7)?,
                    content: full_content,
                    metadata: serde_json::from_str(&metadata_str).unwrap_or(serde_json::json!({})),
                })
            }

            let events: Vec<StoredEvent> = if let Some(types) = types {
                let types_json = serde_json::to_string(&types).unwrap_or_else(|_| "[]".to_string());
                let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![&mid, since_seq, &types_json, limit], parse_row)
                    .map_err(|e| e.to_string())?;
                let mut result = Vec::new();
                for row in rows {
                    result.push(row.map_err(|e| e.to_string())?);
                }
                result
            } else {
                let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![&mid, since_seq, limit], parse_row)
                    .map_err(|e| e.to_string())?;
                let mut result = Vec::new();
                for row in rows {
                    result.push(row.map_err(|e| e.to_string())?);
                }
                result
            };

            Ok(events)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_events_before(
        &self,
        mission_id: Uuid,
        before_seq: i64,
        event_types: Option<&[&str]>,
        limit: Option<usize>,
    ) -> Result<Vec<StoredEvent>, String> {
        let conn = self.reader();
        let mid = mission_id.to_string();
        let types: Option<Vec<String>> =
            event_types.map(|t| t.iter().map(|s| s.to_string()).collect());
        let limit = limit.unwrap_or(50000) as i64;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();

            // We want the N events immediately preceding `before_seq`,
            // but in chronological (ASC) order so the client can prepend
            // them without re-sorting. SQLite has no `ORDER BY DESC LIMIT
            // ... ORDER BY ASC` form, so do the DESC selection in a
            // subquery and reverse it in the outer query.
            let query = if types.is_some() {
                "SELECT id, mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata
                 FROM (
                   SELECT id, mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata
                   FROM mission_events
                   WHERE mission_id = ?1 AND sequence < ?2 AND event_type IN (SELECT value FROM json_each(?3))
                   ORDER BY sequence DESC
                   LIMIT ?4
                 )
                 ORDER BY sequence ASC"
            } else {
                "SELECT id, mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata
                 FROM (
                   SELECT id, mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata
                   FROM mission_events
                   WHERE mission_id = ?1 AND sequence < ?2
                   ORDER BY sequence DESC
                   LIMIT ?3
                 )
                 ORDER BY sequence ASC"
            };

            fn parse_row(row: &rusqlite::Row<'_>) -> Result<StoredEvent, rusqlite::Error> {
                let content: Option<String> = row.get(8)?;
                let content_file: Option<String> = row.get(9)?;
                let full_content = SqliteMissionStore::load_content(content.as_deref(), content_file.as_deref());
                let metadata_str: String = row.get::<_, Option<String>>(10)?.unwrap_or_else(|| "{}".to_string());
                let mid_str: String = row.get(1)?;

                Ok(StoredEvent {
                    id: row.get(0)?,
                    mission_id: parse_uuid_or_nil(&mid_str),
                    sequence: row.get(2)?,
                    event_type: row.get(3)?,
                    timestamp: row.get(4)?,
                    event_id: row.get(5)?,
                    tool_call_id: row.get(6)?,
                    tool_name: row.get(7)?,
                    content: full_content,
                    metadata: serde_json::from_str(&metadata_str).unwrap_or(serde_json::json!({})),
                })
            }

            let events: Vec<StoredEvent> = if let Some(types) = types {
                let types_json = serde_json::to_string(&types).unwrap_or_else(|_| "[]".to_string());
                let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![&mid, before_seq, &types_json, limit], parse_row)
                    .map_err(|e| e.to_string())?;
                let mut result = Vec::new();
                for row in rows {
                    result.push(row.map_err(|e| e.to_string())?);
                }
                result
            } else {
                let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![&mid, before_seq, limit], parse_row)
                    .map_err(|e| e.to_string())?;
                let mut result = Vec::new();
                for row in rows {
                    result.push(row.map_err(|e| e.to_string())?);
                }
                result
            };

            Ok(events)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_status_events_global(
        &self,
        before_ts: Option<&str>,
        limit: usize,
    ) -> Result<Vec<StoredEvent>, String> {
        let conn = self.conn.clone();
        let before_ts = before_ts.map(|s| s.to_string());
        let limit = limit.min(500) as i64;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();

            // Newest first across all missions. Backed by
            // idx_events_event_type; timestamps are ISO-8601 so lexical
            // ordering is chronological.
            let query = if before_ts.is_some() {
                "SELECT id, mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata
                 FROM mission_events
                 WHERE event_type = 'mission_status_changed' AND timestamp < ?1
                 ORDER BY timestamp DESC
                 LIMIT ?2"
            } else {
                "SELECT id, mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata
                 FROM mission_events
                 WHERE event_type = 'mission_status_changed'
                 ORDER BY timestamp DESC
                 LIMIT ?1"
            };

            fn parse_row(row: &rusqlite::Row<'_>) -> Result<StoredEvent, rusqlite::Error> {
                let content: Option<String> = row.get(8)?;
                let content_file: Option<String> = row.get(9)?;
                let full_content =
                    SqliteMissionStore::load_content(content.as_deref(), content_file.as_deref());
                let metadata_str: String =
                    row.get::<_, Option<String>>(10)?.unwrap_or_else(|| "{}".to_string());
                let mid_str: String = row.get(1)?;

                Ok(StoredEvent {
                    id: row.get(0)?,
                    mission_id: parse_uuid_or_nil(&mid_str),
                    sequence: row.get(2)?,
                    event_type: row.get(3)?,
                    timestamp: row.get(4)?,
                    event_id: row.get(5)?,
                    tool_call_id: row.get(6)?,
                    tool_name: row.get(7)?,
                    content: full_content,
                    metadata: serde_json::from_str(&metadata_str).unwrap_or(serde_json::json!({})),
                })
            }

            let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
            let events: Vec<StoredEvent> = if let Some(before) = before_ts {
                let rows = stmt
                    .query_map(params![&before, limit], parse_row)
                    .map_err(|e| e.to_string())?;
                rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?
            } else {
                let rows = stmt
                    .query_map(params![limit], parse_row)
                    .map_err(|e| e.to_string())?;
                rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?
            };

            Ok(events)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_events_for_tool_call(
        &self,
        mission_id: Uuid,
        tool_call_id: &str,
    ) -> Result<Vec<StoredEvent>, String> {
        let conn = self.conn.clone();
        let mid = mission_id.to_string();
        let tool_call_id = tool_call_id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, mission_id, sequence, event_type, timestamp, event_id, tool_call_id, tool_name, content, content_file, metadata
                     FROM mission_events
                     WHERE mission_id = ?1 AND tool_call_id = ?2
                     ORDER BY sequence ASC",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![&mid, &tool_call_id], |row| {
                    let content: Option<String> = row.get(8)?;
                    let content_file: Option<String> = row.get(9)?;
                    let full_content = SqliteMissionStore::load_content(
                        content.as_deref(),
                        content_file.as_deref(),
                    );
                    let metadata_str: String = row
                        .get::<_, Option<String>>(10)?
                        .unwrap_or_else(|| "{}".to_string());
                    let mid_str: String = row.get(1)?;

                    Ok(StoredEvent {
                        id: row.get(0)?,
                        mission_id: parse_uuid_or_nil(&mid_str),
                        sequence: row.get(2)?,
                        event_type: row.get(3)?,
                        timestamp: row.get(4)?,
                        event_id: row.get(5)?,
                        tool_call_id: row.get(6)?,
                        tool_name: row.get(7)?,
                        content: full_content,
                        metadata: serde_json::from_str(&metadata_str)
                            .unwrap_or(serde_json::json!({})),
                    })
                })
                .map_err(|e| e.to_string())?;
            let mut events = Vec::new();
            for row in rows {
                events.push(row.map_err(|e| e.to_string())?);
            }
            Ok(events)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_recent_tool_call_ids(
        &self,
        mission_id: Uuid,
        limit: usize,
    ) -> Result<Vec<String>, String> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let conn = self.conn.clone();
        let mid = mission_id.to_string();
        let limit = limit as i64;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT tool_call_id
                     FROM mission_events
                     WHERE mission_id = ?1
                       AND tool_call_id IS NOT NULL
                       AND event_type IN ('tool_call', 'tool_result')
                     GROUP BY tool_call_id
                     ORDER BY MAX(sequence) DESC
                     LIMIT ?2",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![&mid, limit], |row| row.get::<_, String>(0))
                .map_err(|e| e.to_string())?;
            let mut ids = Vec::new();
            for row in rows {
                ids.push(row.map_err(|e| e.to_string())?);
            }
            Ok(ids)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_tool_call_summaries(
        &self,
        mission_id: Uuid,
        tool_call_ids: &[String],
    ) -> Result<HashMap<String, ToolCallSummary>, String> {
        if tool_call_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let conn = self.conn.clone();
        let mid = mission_id.to_string();
        let ids = tool_call_ids.to_vec();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let ids_json = serde_json::to_string(&ids).unwrap_or_else(|_| "[]".to_string());
            let mut stmt = conn
                .prepare(
                    "SELECT tool_call_id, event_type, sequence, timestamp, content, content_file
                     FROM mission_events
                     WHERE mission_id = ?1
                       AND tool_call_id IN (SELECT value FROM json_each(?2))
                       AND event_type IN ('tool_call', 'tool_result')
                     ORDER BY sequence ASC",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![&mid, &ids_json], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, Option<String>>(5)?,
                    ))
                })
                .map_err(|e| e.to_string())?;
            let mut summaries: HashMap<String, ToolCallSummary> = HashMap::new();
            for row in rows {
                let (tool_call_id, event_type, sequence, timestamp, content, content_file) =
                    row.map_err(|e| e.to_string())?;
                let full_content =
                    SqliteMissionStore::load_content(content.as_deref(), content_file.as_deref());
                let summary = summaries.entry(tool_call_id).or_default();
                if event_type == "tool_call" {
                    summary.call_content_bytes = full_content.len();
                } else {
                    summary.has_result = true;
                    summary.result_sequence = Some(sequence);
                    summary.result_timestamp = Some(timestamp);
                    summary.result_content_bytes = full_content.len();
                }
            }
            Ok(summaries)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn max_event_sequence(&self, mission_id: Uuid) -> Result<i64, String> {
        let conn = self.conn.clone();
        let mid = mission_id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let max_seq: i64 = conn
                .query_row(
                    "SELECT COALESCE(MAX(sequence), 0) FROM mission_events WHERE mission_id = ?1",
                    params![&mid],
                    |row| row.get(0),
                )
                .unwrap_or(0);
            Ok(max_seq)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn nth_recent_event_sequence(
        &self,
        mission_id: Uuid,
        anchor_types: &[&str],
        n: usize,
    ) -> Result<Option<i64>, String> {
        if n == 0 {
            return Ok(None);
        }
        let conn = self.conn.clone();
        let mid = mission_id.to_string();
        let types: Vec<String> = anchor_types.iter().map(|s| s.to_string()).collect();
        // OFFSET is zero-based: the Nth-most-recent row is at offset N-1.
        let offset = (n - 1) as i64;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let types_json = serde_json::to_string(&types).unwrap_or_else(|_| "[]".to_string());
            // Backed by idx_events_mission_type_sequence (mission_id,
            // event_type, sequence) — the DESC walk + small OFFSET is cheap.
            let seq: Option<i64> = conn
                .query_row(
                    "SELECT sequence FROM mission_events
                     WHERE mission_id = ?1 AND event_type IN (SELECT value FROM json_each(?2))
                     ORDER BY sequence DESC
                     LIMIT 1 OFFSET ?3",
                    params![&mid, &types_json, offset],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|e| e.to_string())?;
            Ok(seq)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn count_events(
        &self,
        mission_id: Uuid,
        event_types: Option<&[&str]>,
    ) -> Result<usize, String> {
        let conn = self.conn.clone();
        let mid = mission_id.to_string();
        let types: Option<Vec<String>> =
            event_types.map(|t| t.iter().map(|s| s.to_string()).collect());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();

            let count: i64 = if let Some(types) = types {
                let types_json =
                    serde_json::to_string(&types).unwrap_or_else(|_| "[]".to_string());
                conn.query_row(
                    "SELECT COUNT(*) FROM mission_events WHERE mission_id = ?1 AND event_type IN (SELECT value FROM json_each(?2))",
                    params![&mid, &types_json],
                    |row| row.get(0),
                )
                .map_err(|e| e.to_string())?
            } else {
                conn.query_row(
                    "SELECT COUNT(*) FROM mission_events WHERE mission_id = ?1",
                    params![&mid],
                    |row| row.get(0),
                )
                .map_err(|e| e.to_string())?
            };

            Ok(count as usize)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn count_events_by_type(
        &self,
        mission_id: Uuid,
        event_types: Option<&[&str]>,
    ) -> Result<HashMap<String, usize>, String> {
        let conn = self.conn.clone();
        let mid = mission_id.to_string();
        let types: Option<Vec<String>> =
            event_types.map(|t| t.iter().map(|s| s.to_string()).collect());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let query = if types.is_some() {
                "SELECT event_type, COUNT(*)
                 FROM mission_events
                 WHERE mission_id = ?1 AND event_type IN (SELECT value FROM json_each(?2))
                 GROUP BY event_type"
            } else {
                "SELECT event_type, COUNT(*)
                 FROM mission_events
                 WHERE mission_id = ?1
                 GROUP BY event_type"
            };

            let mut counts = HashMap::new();
            if let Some(types) = types {
                let types_json = serde_json::to_string(&types).unwrap_or_else(|_| "[]".to_string());
                let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![&mid, &types_json], |row| {
                        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                    })
                    .map_err(|e| e.to_string())?;
                for row in rows {
                    let (event_type, count) = row.map_err(|e| e.to_string())?;
                    counts.insert(event_type, count as usize);
                }
            } else {
                let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![&mid], |row| {
                        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                    })
                    .map_err(|e| e.to_string())?;
                for row in rows {
                    let (event_type, count) = row.map_err(|e| e.to_string())?;
                    counts.insert(event_type, count as usize);
                }
            }
            Ok(counts)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_total_cost_cents(&self) -> Result<u64, String> {
        let conn = self.conn.lock().await;

        // Prefer normalized cost.amount_cents while remaining backward-compatible
        // with legacy flat cost_cents metadata. Clamp malformed negative values
        // to zero so aggregate cost invariants remain non-negative.
        let query = r#"
            WITH assistant_costs AS (
                SELECT CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) AS raw_cost
                FROM mission_events
                WHERE event_type = 'assistant_message'
            )
            SELECT COALESCE(
                SUM(CASE WHEN raw_cost > 0 THEN raw_cost ELSE 0 END),
                0
            ) as total_cost
            FROM assistant_costs
        "#;

        let total: i64 = conn
            .query_row(query, [], |row| row.get(0))
            .map_err(|e| e.to_string())?;

        u64::try_from(total).map_err(|_| format!("negative aggregate cost is invalid: {total}"))
    }

    async fn get_cost_by_source(&self) -> Result<(u64, u64, u64), String> {
        let conn = self.conn.lock().await;

        // Group costs by source provenance. Events may store cost in the
        // normalized shape (cost.amount_cents + cost.source) or in the legacy
        // flat shape (cost_cents, with no source — treated as unknown).
        let query = r#"
            WITH source_costs AS (
                SELECT
                    CAST(
                        COALESCE(
                            json_extract(metadata, '$.cost.amount_cents'),
                            json_extract(metadata, '$.cost_cents'),
                            0
                        ) AS INTEGER
                    ) AS raw_cost,
                    COALESCE(
                        json_extract(metadata, '$.cost.source'),
                        'unknown'
                    ) AS source
                FROM mission_events
                WHERE event_type = 'assistant_message'
            )
            SELECT
                source,
                COALESCE(SUM(CASE WHEN raw_cost > 0 THEN raw_cost ELSE 0 END), 0) AS total
            FROM source_costs
            GROUP BY source
        "#;

        let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                let source: String = row.get(0)?;
                let total: i64 = row.get(1)?;
                Ok((source, total.max(0) as u64))
            })
            .map_err(|e| e.to_string())?;

        let mut actual: u64 = 0;
        let mut estimated: u64 = 0;
        let mut unknown: u64 = 0;

        for row in rows {
            let (source, total) = row.map_err(|e| e.to_string())?;
            match source.as_str() {
                "actual" => actual = total,
                "estimated" => estimated = total,
                _ => unknown = unknown.saturating_add(total),
            }
        }

        Ok((actual, estimated, unknown))
    }

    async fn get_total_cost_cents_since(&self, since: &str) -> Result<u64, String> {
        let conn = self.conn.lock().await;
        let query = r#"
            WITH assistant_costs AS (
                SELECT CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) AS raw_cost
                FROM mission_events
                WHERE event_type = 'assistant_message'
                  AND timestamp >= ?1
            )
            SELECT COALESCE(
                SUM(CASE WHEN raw_cost > 0 THEN raw_cost ELSE 0 END),
                0
            ) as total_cost
            FROM assistant_costs
        "#;
        let total: i64 = conn
            .query_row(query, [since], |row| row.get(0))
            .map_err(|e| e.to_string())?;
        u64::try_from(total).map_err(|_| format!("negative aggregate cost is invalid: {total}"))
    }

    async fn get_cost_by_source_since(&self, since: &str) -> Result<(u64, u64, u64), String> {
        let conn = self.conn.lock().await;
        let query = r#"
            WITH source_costs AS (
                SELECT
                    CAST(
                        COALESCE(
                            json_extract(metadata, '$.cost.amount_cents'),
                            json_extract(metadata, '$.cost_cents'),
                            0
                        ) AS INTEGER
                    ) AS raw_cost,
                    COALESCE(
                        json_extract(metadata, '$.cost.source'),
                        'unknown'
                    ) AS source
                FROM mission_events
                WHERE event_type = 'assistant_message'
                  AND timestamp >= ?1
            )
            SELECT
                source,
                COALESCE(SUM(CASE WHEN raw_cost > 0 THEN raw_cost ELSE 0 END), 0) AS total
            FROM source_costs
            GROUP BY source
        "#;
        let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([since], |row| {
                let source: String = row.get(0)?;
                let total: i64 = row.get(1)?;
                Ok((source, total.max(0) as u64))
            })
            .map_err(|e| e.to_string())?;

        let mut actual: u64 = 0;
        let mut estimated: u64 = 0;
        let mut unknown: u64 = 0;
        for row in rows {
            let (source, total) = row.map_err(|e| e.to_string())?;
            match source.as_str() {
                "actual" => actual = total,
                "estimated" => estimated = total,
                _ => unknown = unknown.saturating_add(total),
            }
        }
        Ok((actual, estimated, unknown))
    }

    async fn get_usage_by_model(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<ModelUsageStats>, String> {
        let conn = self.conn.lock().await;

        // Read individual rows so stale stored `model_normalized` values can be
        // corrected with the current normalizer and estimated costs can be
        // recalculated under the corrected model.
        let base_query = r#"
            SELECT
                COALESCE(json_extract(metadata, '$.model'), '') AS raw_model,
                COALESCE(json_extract(metadata, '$.model_normalized'), '') AS stored_model,
                COALESCE(CAST(json_extract(metadata, '$.usage.input_tokens') AS INTEGER), 0) AS input_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.output_tokens') AS INTEGER), 0) AS output_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.cache_creation_input_tokens') AS INTEGER), 0) AS cache_creation_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.cache_read_input_tokens') AS INTEGER), 0) AS cache_read_tokens,
                COALESCE(
                    json_extract(metadata, '$.cost.source'),
                    ''
                ) AS cost_source,
                CASE WHEN CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) > 0
                THEN CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) ELSE 0 END AS cost_cents
            FROM mission_events
            WHERE event_type = 'assistant_message'
        "#;

        let sql = match since {
            Some(_) => format!("{base_query} AND timestamp >= ?1"),
            None => base_query.to_string(),
        };

        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let since_owned = since.map(|s| s.to_string());
        let params: Vec<&dyn rusqlite::ToSql> = match since_owned.as_ref() {
            Some(s) => vec![s],
            None => vec![],
        };
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                let raw_model: String = row.get(0)?;
                let stored_model: String = row.get(1)?;
                let input_tokens: i64 = row.get(2)?;
                let output_tokens: i64 = row.get(3)?;
                let cache_creation_tokens: i64 = row.get(4)?;
                let cache_read_tokens: i64 = row.get(5)?;
                let cost_source: String = row.get(6)?;
                let cost_cents: i64 = row.get(7)?;
                let model = usage_model_key(&raw_model, &stored_model);
                let input_tokens = input_tokens.max(0) as u64;
                let output_tokens = output_tokens.max(0) as u64;
                let cache_creation_tokens = cache_creation_tokens.max(0) as u64;
                let cache_read_tokens = cache_read_tokens.max(0) as u64;
                let stored_cost_cents = cost_cents.max(0) as u64;
                let cost_cents = usage_cost_with_read_side_estimate(
                    &model,
                    stored_cost_cents,
                    &cost_source,
                    input_tokens,
                    output_tokens,
                    cache_creation_tokens,
                    cache_read_tokens,
                );
                Ok(ModelUsageStats {
                    model,
                    requests: 1,
                    input_tokens,
                    output_tokens,
                    cache_creation_tokens,
                    cache_read_tokens,
                    cost_cents,
                })
            })
            .map_err(|e| e.to_string())?;

        let mut by_model: BTreeMap<String, ModelUsageStats> = BTreeMap::new();
        for r in rows {
            let row = r.map_err(|e| e.to_string())?;
            // Skip empty-model rows that carry no usage signal at all
            if row.model.is_empty()
                && row.input_tokens == 0
                && row.output_tokens == 0
                && row.cache_creation_tokens == 0
                && row.cache_read_tokens == 0
                && row.cost_cents == 0
            {
                continue;
            }
            let entry = by_model
                .entry(row.model.clone())
                .or_insert_with(|| ModelUsageStats {
                    model: row.model.clone(),
                    requests: 0,
                    input_tokens: 0,
                    output_tokens: 0,
                    cache_creation_tokens: 0,
                    cache_read_tokens: 0,
                    cost_cents: 0,
                });
            entry.requests = entry.requests.saturating_add(row.requests);
            entry.input_tokens = entry.input_tokens.saturating_add(row.input_tokens);
            entry.output_tokens = entry.output_tokens.saturating_add(row.output_tokens);
            entry.cache_creation_tokens = entry
                .cache_creation_tokens
                .saturating_add(row.cache_creation_tokens);
            entry.cache_read_tokens = entry
                .cache_read_tokens
                .saturating_add(row.cache_read_tokens);
            entry.cost_cents = entry.cost_cents.saturating_add(row.cost_cents);
        }
        let mut out: Vec<ModelUsageStats> = by_model.into_values().collect();
        out.sort_by(|a, b| {
            b.cost_cents
                .cmp(&a.cost_cents)
                .then_with(|| b.requests.cmp(&a.requests))
                .then_with(|| a.model.cmp(&b.model))
        });
        Ok(out)
    }

    async fn get_usage_by_day(&self, since: Option<&str>) -> Result<Vec<DailyUsageStats>, String> {
        let conn = self.conn.lock().await;

        // Group by the UTC date prefix of the ISO-8601 timestamp.
        // We rely on timestamps being stored in RFC3339 / ISO-8601 form, which
        // is what `now_string()` and SQLite's CURRENT_TIMESTAMP produce.
        let base_query = r#"
            SELECT
                substr(timestamp, 1, 10) AS day,
                COALESCE(json_extract(metadata, '$.model'), '') AS raw_model,
                COALESCE(json_extract(metadata, '$.model_normalized'), '') AS stored_model,
                COALESCE(CAST(json_extract(metadata, '$.usage.input_tokens') AS INTEGER), 0) AS input_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.output_tokens') AS INTEGER), 0) AS output_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.cache_creation_input_tokens') AS INTEGER), 0) AS cache_creation_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.cache_read_input_tokens') AS INTEGER), 0) AS cache_read_tokens,
                COALESCE(json_extract(metadata, '$.cost.source'), '') AS cost_source,
                CASE WHEN CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) > 0
                THEN CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) ELSE 0 END AS cost_cents
            FROM mission_events
            WHERE event_type = 'assistant_message'
        "#;

        let sql = match since {
            Some(_) => format!("{base_query} AND timestamp >= ?1 ORDER BY day ASC"),
            None => format!("{base_query} ORDER BY day ASC"),
        };

        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let since_owned = since.map(|s| s.to_string());
        let params: Vec<&dyn rusqlite::ToSql> = match since_owned.as_ref() {
            Some(s) => vec![s],
            None => vec![],
        };
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                let day: String = row.get(0)?;
                let raw_model: String = row.get(1)?;
                let stored_model: String = row.get(2)?;
                let input_tokens: i64 = row.get(3)?;
                let output_tokens: i64 = row.get(4)?;
                let cache_creation_tokens: i64 = row.get(5)?;
                let cache_read_tokens: i64 = row.get(6)?;
                let cost_source: String = row.get(7)?;
                let cost_cents: i64 = row.get(8)?;
                let model = usage_model_key(&raw_model, &stored_model);
                let input_tokens = input_tokens.max(0) as u64;
                let output_tokens = output_tokens.max(0) as u64;
                let cache_creation_tokens = cache_creation_tokens.max(0) as u64;
                let cache_read_tokens = cache_read_tokens.max(0) as u64;
                let cost_cents = usage_cost_with_read_side_estimate(
                    &model,
                    cost_cents.max(0) as u64,
                    &cost_source,
                    input_tokens,
                    output_tokens,
                    cache_creation_tokens,
                    cache_read_tokens,
                );
                Ok((
                    day,
                    1,
                    input_tokens,
                    output_tokens,
                    cache_read_tokens,
                    cost_cents,
                ))
            })
            .map_err(|e| e.to_string())?;

        let mut by_day: BTreeMap<String, DailyUsageStats> = BTreeMap::new();
        for r in rows {
            let (day, requests, input_tokens, output_tokens, cache_read_tokens, cost_cents) =
                r.map_err(|e| e.to_string())?;
            if day.is_empty() {
                continue;
            }
            let entry = by_day.entry(day.clone()).or_insert(DailyUsageStats {
                day,
                requests: 0,
                input_tokens: 0,
                output_tokens: 0,
                cache_read_tokens: 0,
                cost_cents: 0,
            });
            entry.requests = entry.requests.saturating_add(requests);
            entry.input_tokens = entry.input_tokens.saturating_add(input_tokens);
            entry.output_tokens = entry.output_tokens.saturating_add(output_tokens);
            entry.cache_read_tokens = entry.cache_read_tokens.saturating_add(cache_read_tokens);
            entry.cost_cents = entry.cost_cents.saturating_add(cost_cents);
        }
        Ok(by_day.into_values().collect())
    }

    async fn get_usage_by_hour(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<HourlyUsageStats>, String> {
        let conn = self.conn.lock().await;

        // Bucket by `YYYY-MM-DDTHH` (the first 13 chars of an RFC3339 stamp).
        // Same cost-source fallback as get_usage_by_day.
        let base_query = r#"
            SELECT
                substr(timestamp, 1, 13) AS hour,
                COALESCE(json_extract(metadata, '$.model'), '') AS raw_model,
                COALESCE(json_extract(metadata, '$.model_normalized'), '') AS stored_model,
                COALESCE(CAST(json_extract(metadata, '$.usage.input_tokens') AS INTEGER), 0) AS input_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.output_tokens') AS INTEGER), 0) AS output_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.cache_creation_input_tokens') AS INTEGER), 0) AS cache_creation_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.cache_read_input_tokens') AS INTEGER), 0) AS cache_read_tokens,
                COALESCE(json_extract(metadata, '$.cost.source'), '') AS cost_source,
                CASE WHEN CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) > 0
                THEN CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) ELSE 0 END AS cost_cents
            FROM mission_events
            WHERE event_type = 'assistant_message'
        "#;
        let sql = match since {
            Some(_) => format!("{base_query} AND timestamp >= ?1 ORDER BY hour ASC"),
            None => format!("{base_query} ORDER BY hour ASC"),
        };
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let since_owned = since.map(|s| s.to_string());
        let params: Vec<&dyn rusqlite::ToSql> = match since_owned.as_ref() {
            Some(s) => vec![s],
            None => vec![],
        };
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                let hour: String = row.get(0)?;
                let raw_model: String = row.get(1)?;
                let stored_model: String = row.get(2)?;
                let input_tokens: i64 = row.get(3)?;
                let output_tokens: i64 = row.get(4)?;
                let cache_creation_tokens: i64 = row.get(5)?;
                let cache_read_tokens: i64 = row.get(6)?;
                let cost_source: String = row.get(7)?;
                let cost_cents: i64 = row.get(8)?;
                let model = usage_model_key(&raw_model, &stored_model);
                let input_tokens = input_tokens.max(0) as u64;
                let output_tokens = output_tokens.max(0) as u64;
                let cache_creation_tokens = cache_creation_tokens.max(0) as u64;
                let cache_read_tokens = cache_read_tokens.max(0) as u64;
                let cost_cents = usage_cost_with_read_side_estimate(
                    &model,
                    cost_cents.max(0) as u64,
                    &cost_source,
                    input_tokens,
                    output_tokens,
                    cache_creation_tokens,
                    cache_read_tokens,
                );
                Ok((
                    hour,
                    1,
                    input_tokens,
                    output_tokens,
                    cache_read_tokens,
                    cost_cents,
                ))
            })
            .map_err(|e| e.to_string())?;
        let mut by_hour: BTreeMap<String, HourlyUsageStats> = BTreeMap::new();
        for r in rows {
            let (hour, requests, input_tokens, output_tokens, cache_read_tokens, cost_cents) =
                r.map_err(|e| e.to_string())?;
            if hour.is_empty() {
                continue;
            }
            let entry = by_hour.entry(hour.clone()).or_insert(HourlyUsageStats {
                hour,
                requests: 0,
                input_tokens: 0,
                output_tokens: 0,
                cache_read_tokens: 0,
                cost_cents: 0,
            });
            entry.requests = entry.requests.saturating_add(requests);
            entry.input_tokens = entry.input_tokens.saturating_add(input_tokens);
            entry.output_tokens = entry.output_tokens.saturating_add(output_tokens);
            entry.cache_read_tokens = entry.cache_read_tokens.saturating_add(cache_read_tokens);
            entry.cost_cents = entry.cost_cents.saturating_add(cost_cents);
        }
        Ok(by_hour.into_values().collect())
    }

    async fn record_proxy_usage(
        &self,
        model: &str,
        input_tokens: u64,
        output_tokens: u64,
        cost_cents: u64,
    ) -> Result<(), String> {
        let conn = self.conn.lock().await;
        conn.execute(
            "INSERT INTO proxy_usage (timestamp, model, input_tokens, output_tokens, cost_cents)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![
                chrono::Utc::now().to_rfc3339(),
                model,
                input_tokens as i64,
                output_tokens as i64,
                cost_cents as i64,
            ],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    async fn record_proxy_usage_attributed(
        &self,
        record: &super::ProxyUsageRecord,
    ) -> Result<(), String> {
        usage::record(self, record).await
    }

    async fn get_usage_records(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<super::UsageRecord>, String> {
        usage::records(self, since).await
    }

    async fn get_proxy_usage_by_model(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<ModelUsageStats>, String> {
        let conn = self.conn.lock().await;
        // Models are normalized and costs finalized at write time, so plain
        // SQL aggregation is enough (unlike mission_events, which re-derives
        // both from stored metadata on read).
        let base_query = r#"
            SELECT
                model,
                COUNT(*) AS requests,
                SUM(input_tokens) AS input_tokens,
                SUM(output_tokens) AS output_tokens,
                SUM(cache_creation_tokens) AS cache_creation_tokens,
                SUM(cache_read_tokens) AS cache_read_tokens,
                SUM(cost_cents) AS cost_cents
            FROM proxy_usage
        "#;
        let sql = match since {
            Some(_) => format!("{base_query} WHERE timestamp >= ?1 GROUP BY model"),
            None => format!("{base_query} GROUP BY model"),
        };
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let since_owned = since.map(|s| s.to_string());
        let params: Vec<&dyn rusqlite::ToSql> = match since_owned.as_ref() {
            Some(s) => vec![s],
            None => vec![],
        };
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                Ok(ModelUsageStats {
                    model: row.get(0)?,
                    requests: row.get::<_, i64>(1)?.max(0) as u64,
                    input_tokens: row.get::<_, i64>(2)?.max(0) as u64,
                    output_tokens: row.get::<_, i64>(3)?.max(0) as u64,
                    cache_creation_tokens: row.get::<_, i64>(4)?.max(0) as u64,
                    cache_read_tokens: row.get::<_, i64>(5)?.max(0) as u64,
                    cost_cents: row.get::<_, i64>(6)?.max(0) as u64,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())
    }

    async fn get_proxy_usage_by_day(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<DailyUsageStats>, String> {
        let conn = self.conn.lock().await;
        let base_query = r#"
            SELECT
                substr(timestamp, 1, 10) AS day,
                COUNT(*) AS requests,
                SUM(input_tokens) AS input_tokens,
                SUM(output_tokens) AS output_tokens,
                SUM(cache_read_tokens) AS cache_read_tokens,
                SUM(cost_cents) AS cost_cents
            FROM proxy_usage
        "#;
        let sql = match since {
            Some(_) => format!("{base_query} WHERE timestamp >= ?1 GROUP BY day ORDER BY day ASC"),
            None => format!("{base_query} GROUP BY day ORDER BY day ASC"),
        };
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let since_owned = since.map(|s| s.to_string());
        let params: Vec<&dyn rusqlite::ToSql> = match since_owned.as_ref() {
            Some(s) => vec![s],
            None => vec![],
        };
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                Ok(DailyUsageStats {
                    day: row.get(0)?,
                    requests: row.get::<_, i64>(1)?.max(0) as u64,
                    input_tokens: row.get::<_, i64>(2)?.max(0) as u64,
                    output_tokens: row.get::<_, i64>(3)?.max(0) as u64,
                    cache_read_tokens: row.get::<_, i64>(4)?.max(0) as u64,
                    cost_cents: row.get::<_, i64>(5)?.max(0) as u64,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())
    }

    async fn get_proxy_usage_by_hour(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<HourlyUsageStats>, String> {
        let conn = self.conn.lock().await;
        let base_query = r#"
            SELECT
                substr(timestamp, 1, 13) AS hour,
                COUNT(*) AS requests,
                SUM(input_tokens) AS input_tokens,
                SUM(output_tokens) AS output_tokens,
                SUM(cache_read_tokens) AS cache_read_tokens,
                SUM(cost_cents) AS cost_cents
            FROM proxy_usage
        "#;
        let sql = match since {
            Some(_) => {
                format!("{base_query} WHERE timestamp >= ?1 GROUP BY hour ORDER BY hour ASC")
            }
            None => format!("{base_query} GROUP BY hour ORDER BY hour ASC"),
        };
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let since_owned = since.map(|s| s.to_string());
        let params: Vec<&dyn rusqlite::ToSql> = match since_owned.as_ref() {
            Some(s) => vec![s],
            None => vec![],
        };
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                Ok(HourlyUsageStats {
                    hour: row.get(0)?,
                    requests: row.get::<_, i64>(1)?.max(0) as u64,
                    input_tokens: row.get::<_, i64>(2)?.max(0) as u64,
                    output_tokens: row.get::<_, i64>(3)?.max(0) as u64,
                    cache_read_tokens: row.get::<_, i64>(4)?.max(0) as u64,
                    cost_cents: row.get::<_, i64>(5)?.max(0) as u64,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())
    }

    async fn create_automation(&self, automation: Automation) -> Result<Automation, String> {
        let conn = self.conn.clone();

        // Serialize command source
        let (command_source_type, command_source_data) = match &automation.command_source {
            CommandSource::Library { name } => {
                ("library", serde_json::json!({ "name": name }).to_string())
            }
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

        // Serialize trigger
        let (trigger_type, trigger_data) = match &automation.trigger {
            TriggerType::Interval { seconds } => (
                "interval",
                serde_json::json!({ "seconds": seconds }).to_string(),
            ),
            TriggerType::Cron {
                expression,
                timezone,
            } => (
                "cron",
                serde_json::json!({ "expression": expression, "timezone": timezone }).to_string(),
            ),
            TriggerType::Webhook { config } => (
                "webhook",
                serde_json::to_string(config).map_err(|e| e.to_string())?,
            ),
            TriggerType::AgentFinished => ("agent_finished", "{}".to_string()),
            TriggerType::DurableJobTerminal { job_id } => (
                "durable_job_terminal",
                serde_json::json!({ "job_id": job_id }).to_string(),
            ),
            TriggerType::Telegram { config } => (
                "telegram",
                serde_json::to_string(config).map_err(|e| e.to_string())?,
            ),
        };

        // Serialize variables
        let variables_json =
            serde_json::to_string(&automation.variables).map_err(|e| e.to_string())?;

        let a = automation.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction()?;
            let stop_policy_str = match &a.stop_policy {
                StopPolicy::Never => "never".to_string(),
                StopPolicy::WhenMissionTerminal => "when_mission_terminal".to_string(),
                StopPolicy::WhenFailingConsecutively { count } => format!("consecutive_failures:{}", count),
                StopPolicy::WhenAllIssuesClosedAndPRsMerged { repo } => format!("all_issues_closed_and_prs_merged:{}", repo),
                StopPolicy::AfterFirstFire => "after_first_fire".to_string(),
            };
            let fresh_session_str = match a.fresh_session {
                FreshSession::Always => "always",
                FreshSession::Switch => "switch",
                FreshSession::Keep => "keep",
            };
            let driver_str = match a.driver {
                super::AutomationDriver::Scheduler => "scheduler",
                super::AutomationDriver::HarnessLoop => "harness_loop",
            };
            tx.execute(
                "INSERT INTO automations (id, mission_id, command_source_type, command_source_data,
                                         trigger_type, trigger_data, variables, active, stop_policy,
                                         fresh_session, driver, created_at, last_triggered_at, retry_max_retries,
                                         retry_delay_seconds, retry_backoff_multiplier)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                params![
                    a.id.to_string(),
                    a.mission_id.to_string(),
                    command_source_type,
                    command_source_data,
                    trigger_type,
                    trigger_data,
                    variables_json,
                    if a.active { 1 } else { 0 },
                    stop_policy_str,
                    fresh_session_str,
                    driver_str,
                    a.created_at,
                    a.last_triggered_at,
                    a.retry_config.max_retries as i64,
                    a.retry_config.retry_delay_seconds as i64,
                    a.retry_config.backoff_multiplier,
                ],
            )
            ?;
            if let Some(key) = a.active.then(|| crate::api::control::wakeup_supersession_key(a.variables.get("__wakeup_source").map(String::as_str), &a.trigger)).flatten() {
                let priors: Vec<(String, String, String, String)> = {
                    let mut stmt = tx.prepare("SELECT id, variables, trigger_type, trigger_data FROM automations WHERE mission_id = ? AND id != ?")?;
                    let rows = stmt.query_map(params![a.mission_id.to_string(), a.id.to_string()], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?.collect::<Result<Vec<_>, _>>()?;
                    rows
                };
                for (id, vars, kind, data) in priors {
                    let vars: std::collections::HashMap<String, String> = serde_json::from_str(&vars).unwrap_or_default();
                    let mut trigger: serde_json::Value = serde_json::from_str(&data).unwrap_or_default();
                    trigger["type"] = serde_json::Value::String(kind);
                    let Ok(trigger) = serde_json::from_value::<TriggerType>(trigger) else { continue };
                    if crate::api::control::wakeup_supersession_key(vars.get("__wakeup_source").map(String::as_str), &trigger).as_ref() == Some(&key) {
                        tx.execute("UPDATE automations SET active = 0 WHERE id = ?", [&id])?;
                        tx.execute("UPDATE automation_executions SET status = 'cancelled', completed_at = ? WHERE automation_id = ? AND trigger_source = 'durable_schedule' AND status NOT IN ('cancelled','skipped') AND COALESCE(json_extract(variables_used, '$.__delivery_accepted'), '') != 'true'", params![now_string(), id])?;
                    }
                }
            }
            tx.commit()
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
        .map_err(|e| e.to_string())?;

        Ok(automation)
    }

    async fn get_mission_automations(&self, mission_id: Uuid) -> Result<Vec<Automation>, String> {
        let conn = self.conn.clone();
        let mission_id_str = mission_id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare("SELECT id, mission_id, command_source_type, command_source_data,
                                trigger_type, trigger_data, variables, active, stop_policy, fresh_session, created_at, last_triggered_at,
                                retry_max_retries, retry_delay_seconds, retry_backoff_multiplier, driver
                         FROM automations WHERE mission_id = ? ORDER BY created_at DESC")
                .map_err(|e| e.to_string())?;

            let automations = stmt
                .query_map([mission_id_str], |row| {
                    Self::parse_automation_row(row)
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(automations)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn list_active_automations(&self) -> Result<Vec<Automation>, String> {
        let conn = self.reader();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, mission_id, command_source_type, command_source_data,
                            trigger_type, trigger_data, variables, active, stop_policy, fresh_session, created_at, last_triggered_at,
                            retry_max_retries, retry_delay_seconds, retry_backoff_multiplier, driver
                     FROM automations WHERE active = 1 ORDER BY created_at DESC",
                )
                .map_err(|e| e.to_string())?;

            let automations = stmt
                .query_map([], |row| {
                    Self::parse_automation_row(row)
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(automations)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn get_automation(&self, id: Uuid) -> Result<Option<Automation>, String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let result = conn
                .query_row(
                    "SELECT id, mission_id, command_source_type, command_source_data,
                            trigger_type, trigger_data, variables, active, stop_policy, fresh_session, created_at, last_triggered_at,
                            retry_max_retries, retry_delay_seconds, retry_backoff_multiplier, driver
                     FROM automations WHERE id = ?",
                    [id_str],
                    Self::parse_automation_row,
                )
                .optional()
                .map_err(|e| e.to_string())?;

            Ok(result)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn update_automation_active(&self, id: Uuid, active: bool) -> Result<(), String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE automations SET active = ? WHERE id = ?",
                params![if active { 1 } else { 0 }, id_str],
            )
            .map(|_| ())
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
        .map_err(|e| e.to_string())
    }

    async fn update_automation_last_triggered(&self, id: Uuid) -> Result<(), String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let now = now_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE automations SET last_triggered_at = ? WHERE id = ?",
                params![now, id_str],
            )
            .map(|_| ())
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
        .map_err(|e| e.to_string())
    }

    async fn delete_automation(&self, id: Uuid) -> Result<bool, String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let rows = conn
                .execute("DELETE FROM automations WHERE id = ?", params![id_str])
                .map_err(|e| e.to_string())?;
            Ok(rows > 0)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn update_automation(&self, automation: Automation) -> Result<(), String> {
        let conn = self.conn.clone();

        // Serialize command source
        let (command_source_type, command_source_data) = match &automation.command_source {
            CommandSource::Library { name } => {
                ("library", serde_json::json!({ "name": name }).to_string())
            }
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

        // Serialize trigger
        let (trigger_type, trigger_data) = match &automation.trigger {
            TriggerType::Interval { seconds } => (
                "interval",
                serde_json::json!({ "seconds": seconds }).to_string(),
            ),
            TriggerType::Cron {
                expression,
                timezone,
            } => (
                "cron",
                serde_json::json!({ "expression": expression, "timezone": timezone }).to_string(),
            ),
            TriggerType::Webhook { config } => (
                "webhook",
                serde_json::to_string(config).map_err(|e| e.to_string())?,
            ),
            TriggerType::AgentFinished => ("agent_finished", "{}".to_string()),
            TriggerType::DurableJobTerminal { job_id } => (
                "durable_job_terminal",
                serde_json::json!({ "job_id": job_id }).to_string(),
            ),
            TriggerType::Telegram { config } => (
                "telegram",
                serde_json::to_string(config).map_err(|e| e.to_string())?,
            ),
        };

        // Serialize variables
        let variables_json =
            serde_json::to_string(&automation.variables).map_err(|e| e.to_string())?;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let stop_policy_str = match &automation.stop_policy {
                StopPolicy::Never => "never".to_string(),
                StopPolicy::WhenMissionTerminal => "when_mission_terminal".to_string(),
                StopPolicy::WhenFailingConsecutively { count } => format!("consecutive_failures:{}", count),
                StopPolicy::WhenAllIssuesClosedAndPRsMerged { repo } => format!("all_issues_closed_and_prs_merged:{}", repo),
                StopPolicy::AfterFirstFire => "after_first_fire".to_string(),
            };
            let fresh_session_str = match automation.fresh_session {
                FreshSession::Always => "always",
                FreshSession::Switch => "switch",
                FreshSession::Keep => "keep",
            };
            conn.execute(
                "UPDATE automations SET command_source_type = ?, command_source_data = ?,
                                       trigger_type = ?, trigger_data = ?, variables = ?, active = ?,
                                       stop_policy = ?, fresh_session = ?, last_triggered_at = ?, retry_max_retries = ?, retry_delay_seconds = ?,
                                       retry_backoff_multiplier = ?
                  WHERE id = ?",
                params![
                    command_source_type,
                    command_source_data,
                    trigger_type,
                    trigger_data,
                    variables_json,
                    if automation.active { 1 } else { 0 },
                    stop_policy_str,
                    fresh_session_str,
                    automation.last_triggered_at,
                    automation.retry_config.max_retries as i64,
                    automation.retry_config.retry_delay_seconds as i64,
                    automation.retry_config.backoff_multiplier,
                    automation.id.to_string(),
                ],
            )
            .map(|_| ())
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
        .map_err(|e| e.to_string())
    }

    async fn get_automation_by_webhook_id(
        &self,
        webhook_id: &str,
    ) -> Result<Option<Automation>, String> {
        let conn = self.conn.clone();
        let webhook_id = webhook_id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let result = conn
                .query_row(
                    "SELECT id, mission_id, command_source_type, command_source_data,
                            trigger_type, trigger_data, variables, active, stop_policy, fresh_session, created_at, last_triggered_at,
                            retry_max_retries, retry_delay_seconds, retry_backoff_multiplier, driver
                     FROM automations
                     WHERE trigger_type = 'webhook' AND json_extract(trigger_data, '$.webhook_id') = ?",
                    [webhook_id],
                    Self::parse_automation_row,
                )
                .optional()
                .map_err(|e| e.to_string())?;

            Ok(result)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn create_automation_execution(
        &self,
        execution: AutomationExecution,
    ) -> Result<AutomationExecution, String> {
        let conn = self.conn.clone();

        let webhook_payload_json = execution
            .webhook_payload
            .as_ref()
            .map(|v| serde_json::to_string(v).unwrap_or_else(|_| "null".to_string()));

        let variables_used_json =
            serde_json::to_string(&execution.variables_used).unwrap_or_else(|_| "{}".to_string());

        let status_str = match execution.status {
            ExecutionStatus::Pending => "pending",
            ExecutionStatus::Running => "running",
            ExecutionStatus::Success => "success",
            ExecutionStatus::Failed => "failed",
            ExecutionStatus::Cancelled => "cancelled",
            ExecutionStatus::Skipped => "skipped",
        };

        let exec = execution.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO automation_executions (id, automation_id, mission_id, triggered_at,
                                                    trigger_source, status, webhook_payload, variables_used,
                                                    completed_at, error, retry_count)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                params![
                    exec.id.to_string(),
                    exec.automation_id.to_string(),
                    exec.mission_id.to_string(),
                    exec.triggered_at,
                    exec.trigger_source,
                    status_str,
                    webhook_payload_json,
                    variables_used_json,
                    exec.completed_at,
                    exec.error,
                    exec.retry_count as i64,
                ],
            )
            .map(|_| ())
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
        .map_err(|e| e.to_string())?;

        Ok(execution)
    }

    async fn update_automation_execution(
        &self,
        execution: AutomationExecution,
    ) -> Result<(), String> {
        let conn = self.conn.clone();

        let webhook_payload_json = execution
            .webhook_payload
            .as_ref()
            .map(|v| serde_json::to_string(v).unwrap_or_else(|_| "null".to_string()));

        let variables_used_json =
            serde_json::to_string(&execution.variables_used).unwrap_or_else(|_| "{}".to_string());

        let status_str = match execution.status {
            ExecutionStatus::Pending => "pending",
            ExecutionStatus::Running => "running",
            ExecutionStatus::Success => "success",
            ExecutionStatus::Failed => "failed",
            ExecutionStatus::Cancelled => "cancelled",
            ExecutionStatus::Skipped => "skipped",
        };

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE automation_executions SET status = CASE WHEN trigger_source = 'durable_schedule' AND (status IN ('success', 'failed') OR (json_extract(variables_used, '$.__delivery_accepted') = 'true' AND ?1 = 'pending')) THEN status ELSE ?1 END, webhook_payload = ?, variables_used = json_patch(json_patch(json_patch(?3, CASE WHEN json_type(variables_used, '$.__continuation_message_id') = 'text' THEN json_object('__continuation_message_id', json_extract(variables_used, '$.__continuation_message_id')) ELSE '{}' END), CASE WHEN json_type(variables_used, '$.__remote_job_id') = 'text' THEN json_object('__remote_job_id', json_extract(variables_used, '$.__remote_job_id')) ELSE '{}' END), CASE WHEN json_extract(variables_used, '$.__delivery_accepted') = 'true' THEN json_object('__delivery_accepted', 'true') ELSE '{}' END),
                                                 completed_at = CASE WHEN trigger_source = 'durable_schedule' AND status IN ('success','failed') THEN completed_at ELSE ? END, error = CASE WHEN trigger_source = 'durable_schedule' AND (status IN ('success','failed') OR (json_extract(variables_used, '$.__delivery_accepted') = 'true' AND ?1 IN ('pending','running'))) THEN error ELSE ? END, retry_count = ?
                 WHERE id = ? AND (trigger_source != 'durable_schedule' OR status NOT IN ('cancelled', 'skipped'))",
                params![
                    status_str,
                    webhook_payload_json,
                    variables_used_json,
                    execution.completed_at,
                    execution.error,
                    execution.retry_count as i64,
                    execution.id.to_string(),
                ],
            )
            .map(|_| ())
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
        .map_err(|e| e.to_string())
    }

    async fn stage_scheduled_delivery(
        &self,
        automation: &Automation,
        execution: AutomationExecution,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let automation = automation.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction().map_err(|e| e.to_string())?;
            let current: Option<(bool, Option<String>)> = tx.query_row(
                "SELECT active, last_triggered_at FROM automations WHERE id = ?",
                [automation.id.to_string()], |r| Ok((r.get(0)?, r.get(1)?))
            ).optional().map_err(|e| e.to_string())?;
            if current != Some((true, automation.last_triggered_at.clone())) { return Ok(false); }
            let pending: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM automation_executions WHERE automation_id = ? AND trigger_source = 'durable_schedule' AND status IN ('pending','running'))",
                [automation.id.to_string()], |r| r.get(0)
            ).map_err(|e| e.to_string())?;
            if pending { return Ok(false); }
            tx.execute("INSERT INTO automation_executions (id, automation_id, mission_id, triggered_at, trigger_source, status, variables_used, retry_count) VALUES (?, ?, ?, ?, 'durable_schedule', 'pending', ?, 0)",
                params![execution.id.to_string(), automation.id.to_string(), automation.mission_id.to_string(), execution.triggered_at,
                    serde_json::to_string(&execution.variables_used).map_err(|e| e.to_string())?]
            ).map_err(|e| e.to_string())?;
            tx.execute("UPDATE automations SET last_triggered_at = ?, active = ? WHERE id = ?", params![
                execution.triggered_at, !matches!(automation.stop_policy, StopPolicy::AfterFirstFire), automation.id.to_string()
            ]).map_err(|e| e.to_string())?;
            tx.commit().map_err(|e| e.to_string())?;
            Ok(true)
        }).await.map_err(|e| e.to_string())?
    }

    async fn list_scheduled_deliveries(&self) -> Result<Vec<AutomationExecution>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn.prepare("SELECT id, automation_id, mission_id, triggered_at, trigger_source, status, webhook_payload, variables_used, completed_at, error, retry_count FROM automation_executions WHERE trigger_source = 'durable_schedule' AND status NOT IN ('cancelled', 'skipped') AND (status IN ('pending','running') OR COALESCE(json_extract(variables_used, '$.__delivery_accepted'), '') != 'true') ORDER BY triggered_at, id").map_err(|e| e.to_string())?;
            let rows = stmt.query_map([], Self::parse_execution_row).map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?;
            Ok(rows)
        }).await.map_err(|e| e.to_string())?
    }

    async fn can_admit_scheduled_delivery(&self, mission: Uuid, id: Uuid) -> Result<bool, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            conn.blocking_lock().query_row("SELECT EXISTS (SELECT 1 FROM automation_executions WHERE id = ?1 AND mission_id = ?2 AND trigger_source = 'durable_schedule' AND status NOT IN ('cancelled', 'skipped'))",
                params![id.to_string(), mission.to_string()], |row| row.get(0)).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    async fn fence_mission_wakeups(&self, mission: Uuid) -> Result<(), String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            conn.blocking_lock().execute("INSERT INTO mission_wakeup_fences (mission_id, stopped_generation)
                VALUES (?1, COALESCE((SELECT MAX(generation) FROM mission_runs WHERE mission_id = ?1), 0))
                ON CONFLICT(mission_id) DO UPDATE SET stopped_generation = MAX(stopped_generation, excluded.stopped_generation)", [mission.to_string()])
                .map(|_| ()).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    async fn wakeup_creation_allowed(
        &self,
        mission: Uuid,
        generation: u64,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            conn.blocking_lock().query_row("SELECT
                COALESCE((SELECT MAX(generation) FROM mission_runs WHERE mission_id = ?1), 0) = ?2
                AND NOT EXISTS (SELECT 1 FROM mission_wakeup_fences WHERE mission_id = ?1 AND stopped_generation >= ?2)",
                params![mission.to_string(), generation as i64], |row| row.get(0)).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    async fn cancel_mission_continuations(&self, mission: Uuid) -> Result<(), String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock(); let tx = conn.transaction()?;
            tx.execute("UPDATE automations SET active = 0 WHERE mission_id = ? AND json_extract(variables, '$.__wakeup_source') IS NOT NULL", [mission.to_string()])?;
            tx.execute("UPDATE board_outbox SET state = 'acknowledged', acknowledged_at = ? WHERE id IN (SELECT id FROM automation_executions WHERE mission_id = ? AND trigger_source = 'durable_schedule') AND state = 'pending'", params![now_string(),mission.to_string()])?;
            tx.execute("UPDATE automation_executions SET status = 'cancelled', completed_at = ? WHERE mission_id = ? AND trigger_source = 'durable_schedule' AND (status IN ('pending','running') OR COALESCE(json_extract(variables_used, '$.__delivery_accepted'), '') != 'true')", params![now_string(),mission.to_string()])?;
            tx.commit()
        }).await.map_err(|e|e.to_string())?.map_err(|e|e.to_string())
    }

    async fn cancel_mission_continuations_through(
        &self,
        mission: Uuid,
        generation: u64,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock(); let tx = conn.transaction()?;
            tx.execute("INSERT INTO mission_wakeup_fences (mission_id, stopped_generation) VALUES (?1, ?2) ON CONFLICT(mission_id) DO UPDATE SET stopped_generation = MAX(stopped_generation, excluded.stopped_generation)", params![mission.to_string(), generation as i64])?;
            tx.execute("UPDATE automations SET active = 0 WHERE mission_id = ? AND json_extract(variables, '$.__wakeup_source') IS NOT NULL AND CAST(COALESCE(json_extract(variables, '$.__wakeup_run_generation'), '0') AS INTEGER) <= ?", params![mission.to_string(),generation as i64])?;
            tx.execute("UPDATE board_outbox SET state = 'acknowledged', acknowledged_at = ? WHERE id IN (SELECT id FROM automation_executions WHERE mission_id = ? AND trigger_source = 'durable_schedule' AND CAST(COALESCE(json_extract(variables_used, '$.__wakeup_run_generation'), '0') AS INTEGER) <= ?) AND state = 'pending'", params![now_string(),mission.to_string(),generation as i64])?;
            tx.execute("UPDATE automation_executions SET status = 'cancelled', completed_at = ? WHERE mission_id = ? AND trigger_source = 'durable_schedule' AND CAST(COALESCE(json_extract(variables_used, '$.__wakeup_run_generation'), '0') AS INTEGER) <= ? AND (status IN ('pending','running') OR COALESCE(json_extract(variables_used, '$.__delivery_accepted'), '') != 'true')", params![now_string(),mission.to_string(),generation as i64])?;
            tx.commit()
        }).await.map_err(|e|e.to_string())?.map_err(|e|e.to_string())
    }

    async fn cancel_scheduled_delivery(&self, id: Uuid) -> Result<(), String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction().map_err(|e| e.to_string())?;
            tx.execute("UPDATE automations SET active = 0 WHERE id = ?", [id.to_string()]).map_err(|e| e.to_string())?;
            tx.execute("UPDATE automation_executions SET status = 'cancelled', completed_at = ? WHERE automation_id = ? AND trigger_source = 'durable_schedule' AND (status = 'pending' OR (status IN ('success','failed') AND COALESCE(json_extract(variables_used, '$.__delivery_accepted'), '') != 'true'))", params![now_string(), id.to_string()]).map_err(|e| e.to_string())?;
            tx.commit().map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    async fn get_automation_executions(
        &self,
        automation_id: Uuid,
        limit: Option<usize>,
    ) -> Result<Vec<AutomationExecution>, String> {
        let conn = self.conn.clone();
        let automation_id_str = automation_id.to_string();
        let limit = limit.unwrap_or(100) as i64;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, automation_id, mission_id, triggered_at, trigger_source, status,
                            webhook_payload, variables_used, completed_at, error, retry_count
                     FROM automation_executions
                     WHERE automation_id = ?
                     ORDER BY triggered_at DESC
                     LIMIT ?",
                )
                .map_err(|e| e.to_string())?;

            let executions = stmt
                .query_map(params![automation_id_str, limit], |row| {
                    Self::parse_execution_row(row)
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(executions)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn get_mission_automation_executions(
        &self,
        mission_id: Uuid,
        limit: Option<usize>,
    ) -> Result<Vec<AutomationExecution>, String> {
        let conn = self.conn.clone();
        let mission_id_str = mission_id.to_string();
        let limit = limit.unwrap_or(100) as i64;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, automation_id, mission_id, triggered_at, trigger_source, status,
                            webhook_payload, variables_used, completed_at, error, retry_count
                     FROM automation_executions
                     WHERE mission_id = ?
                     ORDER BY triggered_at DESC
                     LIMIT ?",
                )
                .map_err(|e| e.to_string())?;

            let executions = stmt
                .query_map(params![mission_id_str, limit], |row| {
                    Self::parse_execution_row(row)
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(executions)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn complete_turn_executions_for_mission(
        &self,
        mission_id: Uuid,
        occurrence: Option<Uuid>,
        success: bool,
        error: Option<String>,
    ) -> Result<u32, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute("UPDATE automation_executions SET status = ?, completed_at = ?, error = ?
                WHERE mission_id = ? AND ((trigger_source != 'durable_schedule' AND status IN ('pending','running'))
                  OR (trigger_source = 'durable_schedule' AND status = 'running' AND COALESCE(json_extract(variables_used, '$.__continuation_message_id'), id) = ?))",
                params![if success { "success" } else { "failed" }, now_string(), error, mission_id.to_string(), occurrence.map(|id| id.to_string())])
                .map(|n| n as u32).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    async fn bind_scheduled_remote_job(
        &self,
        mission: Uuid,
        message: Option<Uuid>,
        previous_job: Uuid,
        job: Uuid,
    ) -> Result<u32, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            conn.blocking_lock().execute("UPDATE automation_executions SET variables_used = json_set(variables_used, '$.__remote_job_id', ?1)
                WHERE mission_id = ?2 AND trigger_source = 'durable_schedule' AND status = 'running'
                AND (COALESCE(json_extract(variables_used, '$.__continuation_message_id'), id) = ?3 OR json_extract(variables_used, '$.__remote_job_id') = ?4)",
                params![job.to_string(), mission.to_string(), message.map(|id| id.to_string()), previous_job.to_string()])
                .map(|n| n as u32).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    async fn scheduled_remote_delivery(
        &self,
        mission: Uuid,
        message: Uuid,
    ) -> Result<Option<(Uuid, bool)>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let row = conn.blocking_lock().query_row("SELECT json_extract(variables_used, '$.__remote_job_id'), COALESCE(json_extract(variables_used, '$.__delivery_accepted'), '') = 'true'
                FROM automation_executions WHERE mission_id = ?1 AND COALESCE(json_extract(variables_used, '$.__continuation_message_id'), id) = ?2
                AND trigger_source = 'durable_schedule' AND status NOT IN ('cancelled', 'skipped') AND json_type(variables_used, '$.__remote_job_id') = 'text' LIMIT 1",
                params![mission.to_string(), message.to_string()], |row| Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?))).optional().map_err(|e| e.to_string())?;
            row.map(|(id, accepted)| Uuid::parse_str(&id).map(|id| (id, accepted)).map_err(|e| e.to_string())).transpose()
        }).await.map_err(|e| e.to_string())?
    }

    async fn complete_scheduled_remote_job(
        &self,
        mission: Uuid,
        job: Uuid,
        success: Option<bool>,
        error: Option<String>,
    ) -> Result<u32, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            conn.blocking_lock().execute("UPDATE automation_executions SET status = COALESCE(?1, 'running'), completed_at = CASE WHEN ?1 IS NULL THEN completed_at ELSE ?2 END, error = ?3, variables_used = json_set(variables_used, '$.__delivery_accepted', 'true')
                WHERE mission_id = ?4 AND trigger_source = 'durable_schedule' AND status IN ('pending', 'running') AND json_extract(variables_used, '$.__remote_job_id') = ?5",
                params![success.map(|success| if success {"success"} else {"failed"}), now_string(), error, mission.to_string(), job.to_string()])
                .map(|n| n as u32).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    async fn handoff_scheduled_executions(
        &self,
        mission: Uuid,
        from: Vec<Uuid>,
        to: Uuid,
    ) -> Result<u32, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            conn.blocking_lock().execute("UPDATE automation_executions SET variables_used = json_set(variables_used, '$.__continuation_message_id', ?)
                WHERE mission_id = ? AND trigger_source = 'durable_schedule' AND status = 'running'
                AND COALESCE(json_extract(variables_used, '$.__continuation_message_id'), id) IN (SELECT value FROM json_each(?))",
                params![to.to_string(), mission.to_string(), serde_json::to_string(&from).map_err(|e| e.to_string())?])
                .map(|n| n as u32).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    async fn update_mission_mode(&self, id: Uuid, mode: MissionMode) -> Result<(), String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let mode_str = serde_json::to_value(&mode)
            .ok()
            .and_then(|v| v.as_str().map(|s| s.to_string()))
            .unwrap_or_else(|| "task".to_string());
        let now = now_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET mission_mode = ?1, updated_at = ?2 WHERE id = ?3",
                params![mode_str, now, id_str],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn list_assistant_missions(&self) -> Result<Vec<Mission>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, status, title, workspace_id, agent, backend, created_at, updated_at, mission_mode, short_description, COALESCE(goal_mode, 0) as goal_mode, goal_objective FROM missions WHERE mission_mode = 'assistant' ORDER BY updated_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let missions = stmt
                .query_map([], |row| {
                    let id_str: String = row.get(0).unwrap_or_default();
                    let status_str: String = row.get(1).unwrap_or_else(|_| "pending".to_string());
                    let workspace_id_str: String = row.get(3).unwrap_or_default();
                    let mode_str: String = row.get(8).unwrap_or_else(|_| "task".to_string());
                    Ok(Mission {
                        id: Uuid::parse_str(&id_str).unwrap_or_default(),
                        status: serde_json::from_value(serde_json::Value::String(status_str))
                            .unwrap_or(MissionStatus::Pending),
                        title: row.get(2).unwrap_or_default(),
                        short_description: row.get(9).unwrap_or_default(),
                        metadata_updated_at: None,
                        metadata_source: None,
                        metadata_model: None,
                        metadata_version: None,
                        workspace_id: Uuid::parse_str(&workspace_id_str).unwrap_or_default(),
                        workspace_name: None,
                        agent: row.get(4).unwrap_or_default(),
                        model_override: None,
                        model_effort: None,
                        fast_mode: false,
                        service_tier: None,
                        backend: row.get(5).unwrap_or_else(|_| "claudecode".to_string()),
                        config_profile: None,
                        history: vec![],
                        created_at: row.get(6).unwrap_or_default(),
                        updated_at: row.get(7).unwrap_or_default(),
                        interrupted_at: None,
                        paused_at: None,
                        resumable: false,
                        desktop_sessions: vec![],
                        session_id: None,
                        terminal_reason: None,
                        terminal_evidence: None,
                        parent_mission_id: None,
                        working_directory: None,
                        requires_local_disk: true,
                        mission_mode: serde_json::from_value(serde_json::Value::String(mode_str))
                            .unwrap_or_default(),
                        goal_mode: false,
                        goal_objective: None,
                        first_viewed_at: None,
                        scheduling: Default::default(),
                        project: MissionProject::default(),
                        activity: MissionActivity::default(),
                        awaiting_kind: None,
                        origin: None,
                        origin_session_id: None,
                    })
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(missions)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    // === Telegram Channel methods ===

    async fn create_telegram_channel(
        &self,
        channel: TelegramChannel,
    ) -> Result<TelegramChannel, String> {
        let conn = self.conn.clone();
        let c = channel.clone();
        let allowed_chat_ids_json =
            serde_json::to_string(&c.allowed_chat_ids).unwrap_or_else(|_| "[]".to_string());
        let trigger_mode_str = serde_json::to_value(&c.trigger_mode)
            .ok()
            .and_then(|v| v.as_str().map(|s| s.to_string()))
            .unwrap_or_else(|| "direct_message".to_string());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_channels (id, mission_id, bot_token, bot_username, allowed_chat_ids, trigger_mode, active, webhook_secret, instructions, created_at, updated_at, auto_create_missions, default_backend, default_model_override, default_model_effort, default_workspace_id, default_config_profile, default_agent)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
                params![
                    c.id.to_string(),
                    c.mission_id.to_string(),
                    c.bot_token,
                    c.bot_username,
                    allowed_chat_ids_json,
                    trigger_mode_str,
                    c.active as i32,
                    c.webhook_secret,
                    c.instructions,
                    c.created_at,
                    c.updated_at,
                    c.auto_create_missions as i32,
                    c.default_backend,
                    c.default_model_override,
                    c.default_model_effort,
                    c.default_workspace_id.map(|u| u.to_string()),
                    c.default_config_profile,
                    c.default_agent,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;

        Ok(channel)
    }

    async fn get_telegram_channel(&self, id: Uuid) -> Result<Option<TelegramChannel>, String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT id, mission_id, bot_token, bot_username, allowed_chat_ids, trigger_mode, active, webhook_secret, instructions, created_at, updated_at, auto_create_missions, default_backend, default_model_override, default_model_effort, default_workspace_id, default_config_profile, default_agent
                 FROM telegram_channels WHERE id = ?1",
                params![id_str],
                |row| Ok(row_to_telegram_channel(row)),
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_telegram_channels(
        &self,
        mission_id: Uuid,
    ) -> Result<Vec<TelegramChannel>, String> {
        let conn = self.conn.clone();
        let mission_id_str = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, mission_id, bot_token, bot_username, allowed_chat_ids, trigger_mode, active, webhook_secret, instructions, created_at, updated_at, auto_create_missions, default_backend, default_model_override, default_model_effort, default_workspace_id, default_config_profile, default_agent
                     FROM telegram_channels WHERE mission_id = ?1 ORDER BY created_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let channels = stmt
                .query_map(params![mission_id_str], |row| Ok(row_to_telegram_channel(row)))
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(channels)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_all_active_telegram_channels(&self) -> Result<Vec<TelegramChannel>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, mission_id, bot_token, bot_username, allowed_chat_ids, trigger_mode, active, webhook_secret, instructions, created_at, updated_at, auto_create_missions, default_backend, default_model_override, default_model_effort, default_workspace_id, default_config_profile, default_agent
                     FROM telegram_channels WHERE active = 1",
                )
                .map_err(|e| e.to_string())?;
            let channels = stmt
                .query_map([], |row| Ok(row_to_telegram_channel(row)))
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(channels)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn update_telegram_channel(&self, channel: TelegramChannel) -> Result<(), String> {
        let conn = self.conn.clone();
        let allowed_chat_ids_json =
            serde_json::to_string(&channel.allowed_chat_ids).unwrap_or_else(|_| "[]".to_string());
        let trigger_mode_str = serde_json::to_value(&channel.trigger_mode)
            .ok()
            .and_then(|v| v.as_str().map(|s| s.to_string()))
            .unwrap_or_else(|| "direct_message".to_string());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_channels SET bot_token = ?1, bot_username = ?2, allowed_chat_ids = ?3, trigger_mode = ?4, active = ?5, webhook_secret = ?6, instructions = ?7, updated_at = ?8, auto_create_missions = ?10, default_backend = ?11, default_model_override = ?12, default_model_effort = ?13, default_workspace_id = ?14, default_config_profile = ?15, default_agent = ?16 WHERE id = ?9",
                params![
                    channel.bot_token,
                    channel.bot_username,
                    allowed_chat_ids_json,
                    trigger_mode_str,
                    channel.active as i32,
                    channel.webhook_secret,
                    channel.instructions,
                    channel.updated_at,
                    channel.id.to_string(),
                    channel.auto_create_missions as i32,
                    channel.default_backend,
                    channel.default_model_override,
                    channel.default_model_effort,
                    channel.default_workspace_id.map(|u| u.to_string()),
                    channel.default_config_profile,
                    channel.default_agent,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn delete_telegram_channel(&self, id: Uuid) -> Result<bool, String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let deleted = conn
                .execute(
                    "DELETE FROM telegram_channels WHERE id = ?1",
                    params![id_str],
                )
                .map_err(|e| e.to_string())?;
            Ok(deleted > 0)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_all_telegram_channels(&self) -> Result<Vec<TelegramChannel>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, mission_id, bot_token, bot_username, allowed_chat_ids, trigger_mode, active, webhook_secret, instructions, created_at, updated_at, auto_create_missions, default_backend, default_model_override, default_model_effort, default_workspace_id, default_config_profile, default_agent
                     FROM telegram_channels ORDER BY created_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let channels = stmt
                .query_map([], |row| Ok(row_to_telegram_channel(row)))
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(channels)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn upsert_telegram_user(&self, user: TelegramUser) -> Result<TelegramUser, String> {
        let conn = self.conn.clone();
        let u = user.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_users
                 (id, telegram_user_id, username, display_name, role, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(telegram_user_id) DO UPDATE SET
                    username = excluded.username,
                    display_name = excluded.display_name,
                    role = excluded.role,
                    updated_at = excluded.updated_at",
                params![
                    u.id.to_string(),
                    u.telegram_user_id,
                    u.username,
                    u.display_name,
                    telegram_user_role_to_str(u.role),
                    u.created_at,
                    u.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(user)
    }

    async fn get_telegram_user(
        &self,
        telegram_user_id: i64,
    ) -> Result<Option<TelegramUser>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT id, telegram_user_id, username, display_name, role, created_at, updated_at
                 FROM telegram_users WHERE telegram_user_id = ?1",
                params![telegram_user_id],
                row_to_telegram_user,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_or_create_telegram_user_cursor(
        &self,
        telegram_user_id: i64,
    ) -> Result<TelegramUserCursor, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            if let Some(cursor) = conn
                .query_row(
                    "SELECT id, telegram_user_id, last_status_at, last_dashboard_seen_at,
                            last_alert_ack_at, last_digest_at,
                            last_seen_event_sequence_by_mission_json, created_at, updated_at
                     FROM telegram_user_cursors WHERE telegram_user_id = ?1",
                    params![telegram_user_id],
                    row_to_telegram_user_cursor,
                )
                .optional()
                .map_err(|e| e.to_string())?
            {
                return Ok(cursor);
            }

            let now = now_string();
            let cursor = TelegramUserCursor {
                id: Uuid::new_v4(),
                telegram_user_id,
                last_status_at: None,
                last_dashboard_seen_at: None,
                last_alert_ack_at: None,
                last_digest_at: None,
                last_seen_event_sequence_by_mission_json: "{}".to_string(),
                created_at: now.clone(),
                updated_at: now,
            };
            conn.execute(
                "INSERT INTO telegram_user_cursors
                 (id, telegram_user_id, last_status_at, last_dashboard_seen_at, last_alert_ack_at,
                  last_digest_at, last_seen_event_sequence_by_mission_json, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    cursor.id.to_string(),
                    cursor.telegram_user_id,
                    cursor.last_status_at,
                    cursor.last_dashboard_seen_at,
                    cursor.last_alert_ack_at,
                    cursor.last_digest_at,
                    cursor.last_seen_event_sequence_by_mission_json,
                    cursor.created_at,
                    cursor.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(cursor)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn update_telegram_user_last_status_at(
        &self,
        telegram_user_id: i64,
        last_status_at: &str,
        last_seen_event_sequence_by_mission_json: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let last_status_at = last_status_at.to_string();
        let sequence_json = last_seen_event_sequence_by_mission_json.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let now = now_string();
            conn.execute(
                "INSERT INTO telegram_user_cursors
                 (id, telegram_user_id, last_status_at, last_seen_event_sequence_by_mission_json, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(telegram_user_id) DO UPDATE SET
                    last_status_at = excluded.last_status_at,
                    last_seen_event_sequence_by_mission_json = excluded.last_seen_event_sequence_by_mission_json,
                    updated_at = excluded.updated_at",
                params![
                    Uuid::new_v4().to_string(),
                    telegram_user_id,
                    last_status_at,
                    sequence_json,
                    now,
                    now,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn update_telegram_user_last_digest_at(
        &self,
        telegram_user_id: i64,
        last_digest_at: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let last_digest_at = last_digest_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let now = now_string();
            conn.execute(
                "INSERT INTO telegram_user_cursors
                 (id, telegram_user_id, last_digest_at, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(telegram_user_id) DO UPDATE SET
                    last_digest_at = excluded.last_digest_at,
                    updated_at = excluded.updated_at",
                params![
                    Uuid::new_v4().to_string(),
                    telegram_user_id,
                    last_digest_at,
                    now,
                    now,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn update_telegram_user_last_alert_ack_at(
        &self,
        telegram_user_id: i64,
        last_alert_ack_at: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let last_alert_ack_at = last_alert_ack_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let now = now_string();
            conn.execute(
                "INSERT INTO telegram_user_cursors
                 (id, telegram_user_id, last_alert_ack_at, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(telegram_user_id) DO UPDATE SET
                    last_alert_ack_at = excluded.last_alert_ack_at,
                    updated_at = excluded.updated_at",
                params![
                    Uuid::new_v4().to_string(),
                    telegram_user_id,
                    last_alert_ack_at,
                    now,
                    now,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn upsert_telegram_mission_subscription(
        &self,
        subscription: TelegramMissionSubscription,
    ) -> Result<TelegramMissionSubscription, String> {
        let conn = self.conn.clone();
        let s = subscription.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_mission_subscriptions
                 (id, telegram_user_id, mission_id, interest_level, reason, expires_at, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(telegram_user_id, mission_id) DO UPDATE SET
                    interest_level = excluded.interest_level,
                    reason = excluded.reason,
                    expires_at = excluded.expires_at,
                    updated_at = excluded.updated_at",
                params![
                    s.id.to_string(),
                    s.telegram_user_id,
                    s.mission_id.to_string(),
                    telegram_interest_to_str(s.interest_level),
                    s.reason,
                    s.expires_at,
                    s.created_at,
                    s.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(subscription)
    }

    async fn list_telegram_mission_subscriptions(
        &self,
        telegram_user_id: i64,
    ) -> Result<Vec<TelegramMissionSubscription>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, telegram_user_id, mission_id, interest_level, reason, expires_at,
                            created_at, updated_at
                     FROM telegram_mission_subscriptions
                     WHERE telegram_user_id = ?1
                     ORDER BY updated_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(
                    params![telegram_user_id],
                    row_to_telegram_mission_subscription,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn create_telegram_alert_preference(
        &self,
        preference: TelegramAlertPreference,
    ) -> Result<TelegramAlertPreference, String> {
        let conn = self.conn.clone();
        let p = preference.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_alert_preferences
                 (id, telegram_user_id, scope, scope_value, rule_text, enabled,
                  created_from_message_id, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    p.id.to_string(),
                    p.telegram_user_id,
                    p.scope,
                    p.scope_value,
                    p.rule_text,
                    if p.enabled { 1 } else { 0 },
                    p.created_from_message_id,
                    p.created_at,
                    p.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(preference)
    }

    async fn list_telegram_alert_preferences(
        &self,
        telegram_user_id: i64,
    ) -> Result<Vec<TelegramAlertPreference>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, telegram_user_id, scope, scope_value, rule_text, enabled,
                            created_from_message_id, created_at, updated_at
                     FROM telegram_alert_preferences
                     WHERE telegram_user_id = ?1 AND enabled = 1
                     ORDER BY updated_at DESC, created_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![telegram_user_id], row_to_telegram_alert_preference)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn create_telegram_alert_if_absent(
        &self,
        alert: TelegramAlert,
    ) -> Result<Option<TelegramAlert>, String> {
        let conn = self.conn.clone();
        let a = alert.clone();
        let inserted = tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let changed = conn
                .execute(
                    "INSERT OR IGNORE INTO telegram_alerts
                     (id, telegram_user_id, mission_id, event_kind, importance, title, body,
                      status, telegram_message_id, last_error, created_at, sent_at, acknowledged_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                    params![
                        a.id.to_string(),
                        a.telegram_user_id,
                        a.mission_id.map(|id| id.to_string()),
                        a.event_kind,
                        a.importance,
                        a.title,
                        a.body,
                        a.status,
                        a.telegram_message_id,
                        a.last_error,
                        a.created_at,
                        a.sent_at,
                        a.acknowledged_at,
                    ],
                )
                .map_err(|e| e.to_string())?;
            Ok::<_, String>(changed > 0)
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(inserted.then_some(alert))
    }

    async fn list_pending_telegram_alerts(
        &self,
        telegram_user_id: i64,
        limit: usize,
    ) -> Result<Vec<TelegramAlert>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, telegram_user_id, mission_id, event_kind, importance, title, body,
                            status, telegram_message_id, last_error, created_at, sent_at, acknowledged_at
                     FROM telegram_alerts
                     WHERE telegram_user_id = ?1 AND status = 'pending'
                     ORDER BY created_at ASC
                     LIMIT ?2",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![telegram_user_id, limit as i64], row_to_telegram_alert)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_telegram_alerts_for_missions(
        &self,
        mission_ids: &[Uuid],
    ) -> Result<Vec<TelegramAlert>, String> {
        if mission_ids.is_empty() {
            return Ok(vec![]);
        }
        let conn = self.conn.clone();
        let id_strings: Vec<String> = mission_ids.iter().map(|id| id.to_string()).collect();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let placeholders = vec!["?"; id_strings.len()].join(",");
            let sql = format!(
                "SELECT id, telegram_user_id, mission_id, event_kind, importance, title, body,
                        status, telegram_message_id, last_error, created_at, sent_at, acknowledged_at
                 FROM telegram_alerts
                 WHERE mission_id IN ({placeholders})
                 ORDER BY created_at DESC"
            );
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(
                    rusqlite::params_from_iter(id_strings.iter()),
                    row_to_telegram_alert,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn mark_telegram_alert_sent(
        &self,
        id: Uuid,
        telegram_message_id: Option<i64>,
        sent_at: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let sent_at = sent_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_alerts
                 SET status = 'sent', telegram_message_id = ?2, sent_at = ?3, last_error = NULL
                 WHERE id = ?1",
                params![id.to_string(), telegram_message_id, sent_at],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_telegram_alert_by_message_id(
        &self,
        telegram_user_id: i64,
        telegram_message_id: i64,
    ) -> Result<Option<TelegramAlert>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, telegram_user_id, mission_id, event_kind, importance, title, body,
                            status, telegram_message_id, last_error, created_at, sent_at, acknowledged_at
                     FROM telegram_alerts
                     WHERE telegram_user_id = ?1
                       AND telegram_message_id = ?2
                     ORDER BY sent_at DESC, created_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let alerts = stmt
                .query_map(params![telegram_user_id, telegram_message_id], row_to_telegram_alert)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            if alerts.is_empty() {
                return Ok(None);
            }
            let first_mission_id = alerts[0].mission_id;
            if alerts
                .iter()
                .any(|alert| alert.mission_id != first_mission_id)
            {
                return Err("ambiguous_digest_reply".to_string());
            }
            Ok(alerts.into_iter().next())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn acknowledge_pending_telegram_alerts_for_mission(
        &self,
        telegram_user_id: i64,
        mission_id: Uuid,
        acknowledged_at: &str,
    ) -> Result<usize, String> {
        let conn = self.conn.clone();
        let acknowledged_at = acknowledged_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let changed = conn
                .execute(
                    "UPDATE telegram_alerts
                     SET status = 'acknowledged', acknowledged_at = ?3, last_error = NULL
                     WHERE telegram_user_id = ?1
                       AND mission_id = ?2
                       AND status = 'pending'",
                    params![telegram_user_id, mission_id.to_string(), acknowledged_at],
                )
                .map_err(|e| e.to_string())?;
            Ok(changed)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn acknowledge_pending_telegram_alert(
        &self,
        telegram_user_id: i64,
        alert_id: Uuid,
        acknowledged_at: &str,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let acknowledged_at = acknowledged_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let changed = conn
                .execute(
                    "UPDATE telegram_alerts
                     SET status = 'acknowledged', acknowledged_at = ?3, last_error = NULL
                     WHERE telegram_user_id = ?1
                       AND id = ?2
                       AND status = 'pending'",
                    params![telegram_user_id, alert_id.to_string(), acknowledged_at],
                )
                .map_err(|e| e.to_string())?;
            Ok(changed > 0)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn mark_telegram_alert_failed(&self, id: Uuid, error: &str) -> Result<(), String> {
        let conn = self.conn.clone();
        let error = error.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_alerts
                 SET status = 'pending', last_error = ?2
                 WHERE id = ?1 AND status = 'pending'",
                params![id.to_string(), error],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn recover_stale_telegram_alerts(
        &self,
        before: &str,
        limit: usize,
    ) -> Result<usize, String> {
        let conn = self.conn.clone();
        let before = before.to_string();
        let limit = limit.clamp(1, 10_000) as i64;
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let ids = {
                let mut stmt = conn
                    .prepare(
                        "SELECT id
                         FROM telegram_alerts
                         WHERE status = 'pending'
                           AND last_error IS NOT NULL
                           AND created_at <= ?1
                         ORDER BY created_at ASC
                         LIMIT ?2",
                    )
                    .map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![before, limit], |row| row.get::<_, String>(0))
                    .map_err(|e| e.to_string())?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| e.to_string())?;
                rows
            };

            for id in &ids {
                conn.execute(
                    "UPDATE telegram_alerts
                     SET last_error = NULL
                     WHERE id = ?1 AND status = 'pending'",
                    params![id],
                )
                .map_err(|e| e.to_string())?;
            }

            Ok(ids.len())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn create_paloma_decision(
        &self,
        decision: PalomaDecision,
    ) -> Result<PalomaDecision, String> {
        let conn = self.conn.clone();
        let stored = decision.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO paloma_decisions (
                    id, event_source, mission_id, user_id, channel, reason_code,
                    proposed_action, allowed, suppression_reason, policy_snapshot_json,
                    generated_text_hash, generated_text_preview, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                params![
                    decision.id.to_string(),
                    decision.event_source,
                    decision.mission_id.map(|id| id.to_string()),
                    decision.user_id,
                    decision.channel,
                    decision.reason_code,
                    decision.proposed_action,
                    if decision.allowed { 1 } else { 0 },
                    decision.suppression_reason,
                    decision.policy_snapshot_json,
                    decision.generated_text_hash,
                    decision.generated_text_preview,
                    decision.created_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            // Only the latest decisions are ever read. Without a bound, one
            // week of a looping scheduler left 16 million rows (13.6 GB with
            // indexes) in the production database.
            if conn.last_insert_rowid() % PALOMA_DECISION_PRUNE_EVERY == 0 {
                conn.execute(
                    "DELETE FROM paloma_decisions WHERE created_at < (
                         SELECT created_at FROM paloma_decisions
                         ORDER BY created_at DESC LIMIT 1 OFFSET ?1)",
                    params![PALOMA_DECISIONS_KEPT],
                )
                .map_err(|e| e.to_string())?;
            }
            Ok(stored)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_paloma_decisions(&self, limit: usize) -> Result<Vec<PalomaDecision>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, event_source, mission_id, user_id, channel, reason_code,
                            proposed_action, allowed, suppression_reason, policy_snapshot_json,
                            generated_text_hash, generated_text_preview, created_at
                     FROM paloma_decisions
                     ORDER BY created_at DESC
                     LIMIT ?1",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![limit as i64], row_to_paloma_decision)
                .map_err(|e| e.to_string())?;
            let mut decisions = Vec::new();
            for row in rows {
                decisions.push(row.map_err(|e| e.to_string())?);
            }
            Ok(decisions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn claim_paloma_scheduler_job(
        &self,
        name: &str,
        lease_owner: &str,
        now: &str,
        lease_expires_at: &str,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let name = name.to_string();
        let lease_owner = lease_owner.to_string();
        let now = now.to_string();
        let lease_expires_at = lease_expires_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT OR IGNORE INTO paloma_scheduler_jobs
                 (name, run_count, updated_at)
                 VALUES (?1, 0, ?2)",
                params![name, now],
            )
            .map_err(|e| e.to_string())?;
            let changed = conn
                .execute(
                    "UPDATE paloma_scheduler_jobs
                     SET lease_owner = ?2,
                         lease_expires_at = ?4,
                         last_started_at = ?3,
                         updated_at = ?3
                     WHERE name = ?1
                       AND (lease_expires_at IS NULL OR lease_expires_at <= ?3 OR lease_owner = ?2)",
                    params![name, lease_owner, now, lease_expires_at],
                )
                .map_err(|e| e.to_string())?;
            Ok(changed > 0)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn finish_paloma_scheduler_job(
        &self,
        name: &str,
        lease_owner: &str,
        finished_at: &str,
        error: Option<&str>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let name = name.to_string();
        let lease_owner = lease_owner.to_string();
        let finished_at = finished_at.to_string();
        let error = error.map(ToOwned::to_owned);
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE paloma_scheduler_jobs
                 SET lease_owner = NULL,
                     lease_expires_at = NULL,
                     last_finished_at = ?3,
                     last_error = ?4,
                     run_count = run_count + 1,
                     updated_at = ?3
                 WHERE name = ?1 AND lease_owner = ?2",
                params![name, lease_owner, finished_at, error],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_paloma_scheduler_jobs(&self) -> Result<Vec<PalomaSchedulerJob>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT name, lease_owner, lease_expires_at, last_started_at,
                            last_finished_at, last_error, run_count, updated_at
                     FROM paloma_scheduler_jobs
                     ORDER BY name ASC",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map([], row_to_paloma_scheduler_job)
                .map_err(|e| e.to_string())?;
            let mut jobs = Vec::new();
            for row in rows {
                jobs.push(row.map_err(|e| e.to_string())?);
            }
            Ok(jobs)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_paloma_mission_card(
        &self,
        mission_id: Uuid,
    ) -> Result<Option<PalomaMissionCard>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT mission_id, telegram_user_id, channel_id, chat_id, message_id,
                            content_hash, anchor_ts, last_edit_ts, version, archived
                     FROM paloma_mission_cards
                     WHERE mission_id = ?1",
                )
                .map_err(|e| e.to_string())?;
            let mut rows = stmt
                .query_map(params![mission_id.to_string()], row_to_paloma_mission_card)
                .map_err(|e| e.to_string())?;
            match rows.next() {
                Some(row) => Ok(Some(row.map_err(|e| e.to_string())?)),
                None => Ok(None),
            }
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn upsert_paloma_mission_card(
        &self,
        card: PalomaMissionCard,
    ) -> Result<PalomaMissionCard, String> {
        let conn = self.conn.clone();
        let c = card.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO paloma_mission_cards
                 (mission_id, telegram_user_id, channel_id, chat_id, message_id,
                  content_hash, anchor_ts, last_edit_ts, version, archived)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                 ON CONFLICT(mission_id) DO UPDATE SET
                    telegram_user_id = excluded.telegram_user_id,
                    channel_id = excluded.channel_id,
                    chat_id = excluded.chat_id,
                    message_id = excluded.message_id,
                    content_hash = excluded.content_hash,
                    anchor_ts = excluded.anchor_ts,
                    last_edit_ts = excluded.last_edit_ts,
                    version = excluded.version,
                    archived = excluded.archived",
                params![
                    c.mission_id.to_string(),
                    c.telegram_user_id,
                    c.channel_id.to_string(),
                    c.chat_id,
                    c.message_id,
                    c.content_hash,
                    c.anchor_ts,
                    c.last_edit_ts,
                    c.version,
                    if c.archived { 1 } else { 0 },
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(card)
    }

    async fn touch_paloma_mission_card(
        &self,
        mission_id: Uuid,
        content_hash: &str,
        last_edit_ts: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let mission_id = mission_id.to_string();
        let content_hash = content_hash.to_string();
        let last_edit_ts = last_edit_ts.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE paloma_mission_cards
                 SET content_hash = ?2,
                     last_edit_ts = ?3,
                     version = version + 1
                 WHERE mission_id = ?1",
                params![mission_id, content_hash, last_edit_ts],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn archive_paloma_mission_card(&self, mission_id: Uuid) -> Result<(), String> {
        let conn = self.conn.clone();
        let mission_id = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE paloma_mission_cards SET archived = 1 WHERE mission_id = ?1",
                params![mission_id],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_active_paloma_mission_cards(
        &self,
        telegram_user_id: i64,
    ) -> Result<Vec<PalomaMissionCard>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT mission_id, telegram_user_id, channel_id, chat_id, message_id,
                            content_hash, anchor_ts, last_edit_ts, version, archived
                     FROM paloma_mission_cards
                     WHERE telegram_user_id = ?1 AND archived = 0
                     ORDER BY last_edit_ts DESC",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![telegram_user_id], row_to_paloma_mission_card)
                .map_err(|e| e.to_string())?;
            let mut cards = Vec::new();
            for row in rows {
                cards.push(row.map_err(|e| e.to_string())?);
            }
            Ok(cards)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_paloma_cooldown_state(
        &self,
        telegram_user_id: i64,
        mission_id: Uuid,
        alert_class: &str,
    ) -> Result<Option<PalomaCooldownState>, String> {
        let conn = self.conn.clone();
        let alert_class = alert_class.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT mission_id, alert_class, telegram_user_id,
                            last_sent_at, next_eligible_at, backoff_step
                     FROM paloma_cooldown_state
                     WHERE mission_id = ?1 AND alert_class = ?2 AND telegram_user_id = ?3",
                )
                .map_err(|e| e.to_string())?;
            let mut rows = stmt
                .query_map(
                    params![mission_id.to_string(), alert_class, telegram_user_id],
                    row_to_paloma_cooldown_state,
                )
                .map_err(|e| e.to_string())?;
            match rows.next() {
                Some(row) => Ok(Some(row.map_err(|e| e.to_string())?)),
                None => Ok(None),
            }
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn upsert_paloma_cooldown_state(
        &self,
        state: PalomaCooldownState,
    ) -> Result<PalomaCooldownState, String> {
        let conn = self.conn.clone();
        let s = state.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO paloma_cooldown_state
                 (mission_id, alert_class, telegram_user_id,
                  last_sent_at, next_eligible_at, backoff_step)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(mission_id, alert_class, telegram_user_id) DO UPDATE SET
                    last_sent_at = excluded.last_sent_at,
                    next_eligible_at = excluded.next_eligible_at,
                    backoff_step = excluded.backoff_step",
                params![
                    s.mission_id.to_string(),
                    s.alert_class,
                    s.telegram_user_id,
                    s.last_sent_at,
                    s.next_eligible_at,
                    s.backoff_step,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(state)
    }

    async fn reset_paloma_cooldown_for_mission(&self, mission_id: Uuid) -> Result<(), String> {
        let conn = self.conn.clone();
        let mission_id = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "DELETE FROM paloma_cooldown_state WHERE mission_id = ?1",
                params![mission_id],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_paloma_user_preferences(
        &self,
        telegram_user_id: i64,
    ) -> Result<Option<PalomaUserPreferences>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT telegram_user_id, timezone, quiet_hours_start, quiet_hours_end,
                            max_interrupts_per_hour, max_interrupts_per_day,
                            failure_override_quiet, alert_class_overrides_json,
                            mission_overrides_json, digest_cadence, created_at, updated_at
                     FROM paloma_user_preferences
                     WHERE telegram_user_id = ?1",
                )
                .map_err(|e| e.to_string())?;
            let mut rows = stmt
                .query_map(params![telegram_user_id], row_to_paloma_user_preferences)
                .map_err(|e| e.to_string())?;
            match rows.next() {
                Some(row) => Ok(Some(row.map_err(|e| e.to_string())?)),
                None => Ok(None),
            }
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn upsert_paloma_user_preferences(
        &self,
        preferences: PalomaUserPreferences,
    ) -> Result<PalomaUserPreferences, String> {
        let conn = self.conn.clone();
        let p = preferences.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO paloma_user_preferences
                 (telegram_user_id, timezone, quiet_hours_start, quiet_hours_end,
                  max_interrupts_per_hour, max_interrupts_per_day, failure_override_quiet,
                  alert_class_overrides_json, mission_overrides_json, digest_cadence,
                  created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                 ON CONFLICT(telegram_user_id) DO UPDATE SET
                    timezone = excluded.timezone,
                    quiet_hours_start = excluded.quiet_hours_start,
                    quiet_hours_end = excluded.quiet_hours_end,
                    max_interrupts_per_hour = excluded.max_interrupts_per_hour,
                    max_interrupts_per_day = excluded.max_interrupts_per_day,
                    failure_override_quiet = excluded.failure_override_quiet,
                    alert_class_overrides_json = excluded.alert_class_overrides_json,
                    mission_overrides_json = excluded.mission_overrides_json,
                    digest_cadence = excluded.digest_cadence,
                    updated_at = excluded.updated_at",
                params![
                    p.telegram_user_id,
                    p.timezone,
                    p.quiet_hours_start,
                    p.quiet_hours_end,
                    p.max_interrupts_per_hour,
                    p.max_interrupts_per_day,
                    if p.failure_override_quiet { 1 } else { 0 },
                    p.alert_class_overrides_json,
                    p.mission_overrides_json,
                    p.digest_cadence,
                    p.created_at,
                    p.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(preferences)
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
        let conn = self.conn.clone();
        let event_kind = event_kind.to_string();
        let title = title.to_string();
        let body = body.to_string();
        let importance = importance.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let changed = conn
                .execute(
                    "UPDATE telegram_alerts
                     SET title = ?4, body = ?5, importance = ?6
                     WHERE telegram_user_id = ?1
                       AND mission_id = ?2
                       AND event_kind = ?3
                       AND status = 'pending'",
                    params![
                        telegram_user_id,
                        mission_id.to_string(),
                        event_kind,
                        title,
                        body,
                        importance,
                    ],
                )
                .map_err(|e| e.to_string())?;
            Ok(changed > 0)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn count_paloma_sent_alerts_since(
        &self,
        telegram_user_id: i64,
        since: &str,
    ) -> Result<i64, String> {
        let conn = self.conn.clone();
        let since = since.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // Rate-limit budget is "how many Telegram messages did we send
            // to this user in the window", not "how many alert rows we
            // marked sent". A digest folds N alerts into one Telegram
            // message; counting the rows would burn the user's budget N×
            // faster than reality.
            let count: i64 = conn
                .query_row(
                    "SELECT COUNT(DISTINCT telegram_message_id) FROM telegram_alerts
                     WHERE telegram_user_id = ?1
                       AND status = 'sent'
                       AND sent_at IS NOT NULL
                       AND telegram_message_id IS NOT NULL
                       AND sent_at >= ?2",
                    params![telegram_user_id, since],
                    |row| row.get(0),
                )
                .map_err(|e| e.to_string())?;
            Ok(count)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn consolidate_telegram_structured_memory(
        &self,
        channel_id: Uuid,
        limit: usize,
    ) -> Result<usize, String> {
        let conn = self.conn.clone();
        let channel_id = channel_id.to_string();
        let limit = limit.clamp(1, 10_000) as i64;
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "WITH ranked AS (
                         SELECT id, channel_id, scope, chat_id, subject_user_id, normalized_label,
                                ROW_NUMBER() OVER (
                                    PARTITION BY channel_id, scope, chat_id,
                                                 COALESCE(subject_user_id, -9223372036854775808),
                                                 normalized_label
                                    ORDER BY updated_at DESC, created_at DESC
                                ) AS row_rank,
                                MAX(updated_at) OVER (
                                    PARTITION BY channel_id, scope, chat_id,
                                                 COALESCE(subject_user_id, -9223372036854775808),
                                                 normalized_label
                                ) AS group_updated_at
                         FROM telegram_structured_memory
                         WHERE channel_id = ?1
                           AND kind IN ('fact', 'preference')
                           AND normalized_label IS NOT NULL
                           AND source_role = 'user'
                     ),
                     selected_groups AS (
                         SELECT DISTINCT channel_id, scope, chat_id, subject_user_id,
                                         normalized_label, group_updated_at
                         FROM ranked
                         ORDER BY group_updated_at DESC
                         LIMIT ?2
                     )
                     SELECT ranked.id
                     FROM ranked
                     WHERE ranked.row_rank > 1
                       AND EXISTS (
                           SELECT 1
                           FROM selected_groups
                           WHERE selected_groups.channel_id = ranked.channel_id
                             AND selected_groups.scope = ranked.scope
                             AND selected_groups.chat_id = ranked.chat_id
                             AND COALESCE(selected_groups.subject_user_id, -9223372036854775808)
                                 = COALESCE(ranked.subject_user_id, -9223372036854775808)
                             AND selected_groups.normalized_label = ranked.normalized_label
                       )",
                )
                .map_err(|e| e.to_string())?;
            let delete_ids = stmt
                .query_map(params![channel_id, limit], |row| row.get::<_, String>(0))
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            for id in &delete_ids {
                conn.execute(
                    "DELETE FROM telegram_structured_memory WHERE id = ?1",
                    params![id],
                )
                .map_err(|e| e.to_string())?;
                conn.execute(
                    "DELETE FROM telegram_structured_memory_fts WHERE entry_id = ?1",
                    params![id],
                )
                .map_err(|e| e.to_string())?;
            }

            Ok(delete_ids.len())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_telegram_chat_mission(
        &self,
        channel_id: Uuid,
        chat_id: i64,
    ) -> Result<Option<TelegramChatMission>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT id, channel_id, chat_id, mission_id, chat_title, created_at
                 FROM telegram_chat_missions WHERE channel_id = ?1 AND chat_id = ?2",
                params![channel_id_str, chat_id],
                |row| {
                    let id_str: String = row.get(0)?;
                    let ch_id_str: String = row.get(1)?;
                    let m_id_str: String = row.get(3)?;
                    Ok(TelegramChatMission {
                        id: Uuid::parse_str(&id_str).unwrap_or_default(),
                        channel_id: Uuid::parse_str(&ch_id_str).unwrap_or_default(),
                        chat_id: row.get(2)?,
                        mission_id: Uuid::parse_str(&m_id_str).unwrap_or_default(),
                        chat_title: row.get(4)?,
                        created_at: row.get(5)?,
                    })
                },
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn create_telegram_chat_mission(
        &self,
        mapping: TelegramChatMission,
    ) -> Result<TelegramChatMission, String> {
        let conn = self.conn.clone();
        let m = mapping.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_chat_missions (id, channel_id, chat_id, mission_id, chat_title, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    m.id.to_string(),
                    m.channel_id.to_string(),
                    m.chat_id,
                    m.mission_id.to_string(),
                    m.chat_title,
                    m.created_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(mapping)
    }

    async fn update_telegram_chat_mission_title(
        &self,
        channel_id: Uuid,
        chat_id: i64,
        chat_title: Option<String>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_chat_missions
                 SET chat_title = ?3
                 WHERE channel_id = ?1 AND chat_id = ?2",
                params![channel_id_str, chat_id, chat_title],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_telegram_chat_mission_by_mission_id(
        &self,
        mission_id: Uuid,
    ) -> Result<Option<TelegramChatMission>, String> {
        let conn = self.conn.clone();
        let mission_id_str = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT id, channel_id, chat_id, mission_id, chat_title, created_at
                 FROM telegram_chat_missions WHERE mission_id = ?1 LIMIT 1",
                params![mission_id_str],
                |row| {
                    let id_str: String = row.get(0)?;
                    let channel_id_str: String = row.get(1)?;
                    let mission_id_str2: String = row.get(3)?;
                    Ok(TelegramChatMission {
                        id: Uuid::parse_str(&id_str).unwrap_or_default(),
                        channel_id: Uuid::parse_str(&channel_id_str).unwrap_or_default(),
                        chat_id: row.get(2)?,
                        mission_id: Uuid::parse_str(&mission_id_str2).unwrap_or_default(),
                        chat_title: row.get(4)?,
                        created_at: row.get(5)?,
                    })
                },
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_telegram_chat_missions(
        &self,
        channel_id: Uuid,
    ) -> Result<Vec<TelegramChatMission>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, chat_id, mission_id, chat_title, created_at
                     FROM telegram_chat_missions WHERE channel_id = ?1 ORDER BY created_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let mappings = stmt
                .query_map(params![channel_id_str], |row| {
                    let id_str: String = row.get(0)?;
                    let ch_id_str: String = row.get(1)?;
                    let m_id_str: String = row.get(3)?;
                    Ok(TelegramChatMission {
                        id: Uuid::parse_str(&id_str).unwrap_or_default(),
                        channel_id: Uuid::parse_str(&ch_id_str).unwrap_or_default(),
                        chat_id: row.get(2)?,
                        mission_id: Uuid::parse_str(&m_id_str).unwrap_or_default(),
                        chat_title: row.get(4)?,
                        created_at: row.get(5)?,
                    })
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(mappings)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn create_telegram_scheduled_message(
        &self,
        message: TelegramScheduledMessage,
    ) -> Result<TelegramScheduledMessage, String> {
        let conn = self.conn.clone();
        let msg = message.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_scheduled_messages (
                    id, channel_id, source_mission_id, chat_id, chat_title, text,
                    send_at, sent_at, status, last_error, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    msg.id.to_string(),
                    msg.channel_id.to_string(),
                    msg.source_mission_id.map(|id| id.to_string()),
                    msg.chat_id,
                    msg.chat_title,
                    msg.text,
                    msg.send_at,
                    msg.sent_at,
                    match msg.status {
                        TelegramScheduledMessageStatus::Pending => "pending",
                        TelegramScheduledMessageStatus::Sent => "sent",
                        TelegramScheduledMessageStatus::Failed => "failed",
                    },
                    msg.last_error,
                    msg.created_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(message)
    }

    async fn list_due_telegram_scheduled_messages(
        &self,
        channel_id: Uuid,
        send_at: &str,
        limit: usize,
    ) -> Result<Vec<TelegramScheduledMessage>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        let send_at = send_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, source_mission_id, chat_id, chat_title, text,
                            send_at, sent_at, status, last_error, created_at
                     FROM telegram_scheduled_messages
                     WHERE channel_id = ?1
                       AND status = 'pending'
                       AND send_at <= ?2
                     ORDER BY send_at ASC
                     LIMIT ?3",
                )
                .map_err(|e| e.to_string())?;
            let messages = stmt
                .query_map(
                    params![channel_id_str, send_at, limit as i64],
                    row_to_telegram_scheduled_message,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(messages)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_telegram_scheduled_messages(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        limit: usize,
    ) -> Result<Vec<TelegramScheduledMessage>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let sql = if chat_id.is_some() {
                "SELECT id, channel_id, source_mission_id, chat_id, chat_title, text,
                        send_at, sent_at, status, last_error, created_at
                 FROM telegram_scheduled_messages
                 WHERE channel_id = ?1 AND chat_id = ?2
                 ORDER BY created_at DESC
                 LIMIT ?3"
            } else {
                "SELECT id, channel_id, source_mission_id, chat_id, chat_title, text,
                        send_at, sent_at, status, last_error, created_at
                 FROM telegram_scheduled_messages
                 WHERE channel_id = ?1
                 ORDER BY created_at DESC
                 LIMIT ?2"
            };
            let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
            let limit_i64 = limit as i64;
            let messages = if let Some(chat_id) = chat_id {
                stmt.query_map(
                    params![channel_id_str, chat_id, limit_i64],
                    row_to_telegram_scheduled_message,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?
            } else {
                stmt.query_map(
                    params![channel_id_str, limit_i64],
                    row_to_telegram_scheduled_message,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?
            };
            Ok(messages)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn claim_telegram_scheduled_message(&self, id: Uuid) -> Result<bool, String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let now = Utc::now().to_rfc3339();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let updated = conn
                .execute(
                    "UPDATE telegram_scheduled_messages
                     SET status = 'sending', sent_at = ?2
                     WHERE id = ?1 AND status = 'pending'",
                    params![id_str, now],
                )
                .map_err(|e| e.to_string())?;
            Ok(updated > 0)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn recover_stale_sending_scheduled_messages(
        &self,
        max_age_secs: i64,
    ) -> Result<u32, String> {
        let conn = self.conn.clone();
        let cutoff = (chrono::Utc::now() - chrono::Duration::seconds(max_age_secs)).to_rfc3339();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let updated = conn
                .execute(
                    "UPDATE telegram_scheduled_messages
                     SET status = 'pending', sent_at = NULL
                     WHERE status = 'sending'
                       AND sent_at IS NOT NULL AND sent_at < ?1",
                    params![cutoff],
                )
                .map_err(|e| e.to_string())?;
            Ok(updated as u32)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn mark_telegram_scheduled_message_sent(
        &self,
        id: Uuid,
        sent_at: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let sent_at = sent_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_scheduled_messages
                 SET status = 'sent', sent_at = ?1, last_error = NULL
                 WHERE id = ?2",
                params![sent_at, id_str],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn mark_telegram_scheduled_message_failed(
        &self,
        id: Uuid,
        error: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let error = error.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_scheduled_messages
                 SET status = 'failed', last_error = ?1
                 WHERE id = ?2",
                params![error, id_str],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn upsert_telegram_structured_memory(
        &self,
        entry: TelegramStructuredMemoryEntry,
    ) -> Result<TelegramStructuredMemoryEntry, String> {
        let conn = self.conn.clone();
        let entry_clone = entry.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let normalized_label = entry_clone
                .label
                .as_deref()
                .map(|label| label.trim().to_lowercase())
                .filter(|label| !label.is_empty());
            let kind = match entry_clone.kind {
                TelegramStructuredMemoryKind::Fact => "fact",
                TelegramStructuredMemoryKind::Note => "note",
                TelegramStructuredMemoryKind::Task => "task",
                TelegramStructuredMemoryKind::Preference => "preference",
            };
            let scope = match entry_clone.scope {
                TelegramStructuredMemoryScope::Chat => "chat",
                TelegramStructuredMemoryScope::User => "user",
                TelegramStructuredMemoryScope::Channel => "channel",
            };

            let is_upsertable_kind = matches!(
                entry_clone.kind,
                TelegramStructuredMemoryKind::Fact | TelegramStructuredMemoryKind::Preference
            ) && normalized_label.is_some();

            if is_upsertable_kind {
                let updated = match entry_clone.scope.clone() {
                    TelegramStructuredMemoryScope::User
                        if entry_clone.subject_user_id.is_some() =>
                    {
                        conn.execute(
                            "UPDATE telegram_structured_memory
                             SET mission_id = ?1,
                                 chat_id = ?2,
                                 value = ?3,
                                 subject_username = ?4,
                                 subject_display_name = ?5,
                                 source_message_id = ?6,
                                 source_role = ?7,
                                 updated_at = ?8
                             WHERE channel_id = ?9
                               AND scope = ?10
                               AND subject_user_id = ?11
                               AND kind = ?12
                               AND normalized_label = ?13",
                            params![
                                entry_clone.mission_id.map(|id| id.to_string()),
                                entry_clone.chat_id,
                                entry_clone.value.clone(),
                                entry_clone.subject_username.clone(),
                                entry_clone.subject_display_name.clone(),
                                entry_clone.source_message_id,
                                entry_clone.source_role.clone(),
                                entry_clone.updated_at.clone(),
                                entry_clone.channel_id.to_string(),
                                scope,
                                entry_clone.subject_user_id,
                                kind,
                                normalized_label,
                            ],
                        )
                        .map_err(|e| e.to_string())?;
                        conn.changes() > 0
                    }
                    TelegramStructuredMemoryScope::Channel => {
                        conn.execute(
                            "UPDATE telegram_structured_memory
                             SET mission_id = ?1,
                                 chat_id = ?2,
                                 value = ?3,
                                 source_message_id = ?4,
                                 source_role = ?5,
                                 updated_at = ?6
                             WHERE channel_id = ?7
                               AND scope = ?8
                               AND kind = ?9
                               AND normalized_label = ?10",
                            params![
                                entry_clone.mission_id.map(|id| id.to_string()),
                                entry_clone.chat_id,
                                entry_clone.value.clone(),
                                entry_clone.source_message_id,
                                entry_clone.source_role.clone(),
                                entry_clone.updated_at.clone(),
                                entry_clone.channel_id.to_string(),
                                scope,
                                kind,
                                normalized_label,
                            ],
                        )
                        .map_err(|e| e.to_string())?;
                        conn.changes() > 0
                    }
                    _ => {
                        conn.execute(
                            "UPDATE telegram_structured_memory
                             SET mission_id = ?1,
                                 value = ?2,
                                 source_message_id = ?3,
                                 source_role = ?4,
                                 updated_at = ?5
                             WHERE channel_id = ?6
                               AND scope = ?7
                               AND chat_id = ?8
                               AND kind = ?9
                               AND normalized_label = ?10",
                            params![
                                entry_clone.mission_id.map(|id| id.to_string()),
                                entry_clone.value.clone(),
                                entry_clone.source_message_id,
                                entry_clone.source_role.clone(),
                                entry_clone.updated_at.clone(),
                                entry_clone.channel_id.to_string(),
                                scope,
                                entry_clone.chat_id,
                                kind,
                                normalized_label,
                            ],
                        )
                        .map_err(|e| e.to_string())?;
                        conn.changes() > 0
                    }
                };

                if updated {
                    let updated_entry = Self::load_telegram_structured_memory_for_upsert(
                        &conn,
                        &entry_clone,
                        scope,
                        kind,
                        normalized_label.as_deref().unwrap_or_default(),
                    )?
                    .ok_or_else(|| {
                        "Updated telegram structured memory row could not be reloaded".to_string()
                    })?;
                    Self::upsert_telegram_memory_search_index_entry(&conn, &updated_entry)?;
                    return Ok::<_, String>(());
                }
            }

            conn.execute(
                "INSERT INTO telegram_structured_memory (
                    id, channel_id, chat_id, mission_id, scope, kind, label, normalized_label, value,
                    subject_user_id, subject_username, subject_display_name,
                    source_message_id, source_role, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
                params![
                    entry_clone.id.to_string(),
                    entry_clone.channel_id.to_string(),
                    entry_clone.chat_id,
                    entry_clone.mission_id.map(|id| id.to_string()),
                    scope,
                    kind,
                    entry_clone.label,
                    normalized_label,
                    entry_clone.value,
                    entry_clone.subject_user_id,
                    entry_clone.subject_username,
                    entry_clone.subject_display_name,
                    entry_clone.source_message_id,
                    entry_clone.source_role,
                    entry_clone.created_at,
                    entry_clone.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Self::upsert_telegram_memory_search_index_entry(&conn, &entry_clone)?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(entry)
    }

    async fn list_telegram_structured_memory(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        subject_user_id: Option<i64>,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemoryEntry>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // Build WHERE clause dynamically so all filters are applied
            // before the LIMIT truncation.
            let mut where_clauses = vec!["channel_id = ?1".to_string()];
            let mut param_idx = 2u32;
            if chat_id.is_some() {
                where_clauses.push(format!("chat_id = ?{}", param_idx));
                param_idx += 1;
            }
            if subject_user_id.is_some() {
                where_clauses.push(format!("subject_user_id = ?{}", param_idx));
                param_idx += 1;
            }
            let sql = format!(
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory
                 WHERE {}
                 ORDER BY updated_at DESC
                 LIMIT ?{}",
                where_clauses.join(" AND "),
                param_idx,
            );
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
            // Build params vec dynamically matching the WHERE clause above.
            let mut params_vec: Vec<Box<dyn rusqlite::types::ToSql>> =
                vec![Box::new(channel_id_str)];
            if let Some(cid) = chat_id {
                params_vec.push(Box::new(cid));
            }
            if let Some(suid) = subject_user_id {
                params_vec.push(Box::new(suid));
            }
            params_vec.push(Box::new(limit as i64));
            let param_refs: Vec<&dyn rusqlite::types::ToSql> =
                params_vec.iter().map(|p| p.as_ref()).collect();
            let entries = stmt
                .query_map(param_refs.as_slice(), row_to_telegram_structured_memory)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(entries)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn search_telegram_structured_memory(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        query: &str,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemoryEntry>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        let query = query.trim().to_lowercase();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let sql = if chat_id.is_some() {
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory
                 WHERE channel_id = ?1
                   AND chat_id = ?2
                   AND (
                     instr(lower(coalesce(label, '')), ?3) > 0
                     OR instr(lower(value), ?3) > 0
                   )
                 ORDER BY updated_at DESC
                 LIMIT ?4"
            } else {
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory
                 WHERE channel_id = ?1
                   AND (
                     instr(lower(coalesce(label, '')), ?2) > 0
                     OR instr(lower(value), ?2) > 0
                   )
                 ORDER BY updated_at DESC
                 LIMIT ?3"
            };
            let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
            let entries = if let Some(chat_id) = chat_id {
                stmt.query_map(
                    params![channel_id_str, chat_id, query, limit as i64],
                    row_to_telegram_structured_memory,
                )
            } else {
                stmt.query_map(
                    params![channel_id_str, query, limit as i64],
                    row_to_telegram_structured_memory,
                )
            }
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
            Ok(entries)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn search_telegram_structured_memory_hybrid(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        subject_user_id: Option<i64>,
        query: &str,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemorySearchHit>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        let normalized_query = normalize_search_text(query.trim());
        let query_tokens = tokenize_search_text(query);
        let core_query = query_tokens.join(" ");
        let fts_query = build_fts_query_from_tokens(&query_tokens, &normalized_query);

        tokio::task::spawn_blocking(move || {
            if normalized_query.is_empty() {
                return Ok(Vec::new());
            }

            let conn = conn.blocking_lock();
            let candidate_limit = (limit.max(8) * 8).min(TELEGRAM_MEMORY_SEARCH_MAX_CANDIDATES);

            let mut stmt = match chat_id {
                Some(_) => conn.prepare(
                    "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                            subject_user_id, subject_username, subject_display_name,
                            source_message_id, source_role, created_at, updated_at
                     FROM telegram_structured_memory
                     WHERE channel_id = ?1
                       AND (
                         scope = 'channel'
                         OR (scope = 'chat' AND chat_id = ?2)
                         OR (?3 IS NOT NULL AND scope = 'user' AND subject_user_id = ?3)
                       )
                     ORDER BY updated_at DESC
                     LIMIT ?4",
                ),
                None if subject_user_id.is_some() => conn.prepare(
                    "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                            subject_user_id, subject_username, subject_display_name,
                            source_message_id, source_role, created_at, updated_at
                     FROM telegram_structured_memory
                     WHERE channel_id = ?1
                       AND (
                         scope = 'channel'
                         OR (scope = 'user' AND subject_user_id = ?2)
                       )
                     ORDER BY updated_at DESC
                     LIMIT ?3",
                ),
                None => conn.prepare(
                    "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                            subject_user_id, subject_username, subject_display_name,
                            source_message_id, source_role, created_at, updated_at
                     FROM telegram_structured_memory
                     WHERE channel_id = ?1
                     ORDER BY updated_at DESC
                     LIMIT ?2",
                ),
            }
            .map_err(|e| e.to_string())?;

            let mut candidates = match (chat_id, subject_user_id) {
                (Some(chat_id), subject_user_id) => stmt.query_map(
                    params![
                        channel_id_str.as_str(),
                        chat_id,
                        subject_user_id,
                        candidate_limit as i64
                    ],
                    row_to_telegram_structured_memory,
                ),
                (None, Some(subject_user_id)) => stmt.query_map(
                    params![
                        channel_id_str.as_str(),
                        subject_user_id,
                        candidate_limit as i64
                    ],
                    row_to_telegram_structured_memory,
                ),
                (None, None) => stmt.query_map(
                    params![channel_id_str.as_str(), candidate_limit as i64],
                    row_to_telegram_structured_memory,
                ),
            }
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;

            let mut fts_scores: HashMap<Uuid, f64> = HashMap::new();
            if let Some(fts_query) = fts_query {
                let mut stmt = match chat_id {
                    Some(_) => conn.prepare(
                        "SELECT entry_id, bm25(telegram_structured_memory_fts) AS rank
                         FROM telegram_structured_memory_fts
                         WHERE channel_id = ?1
                           AND (
                             scope = 'channel'
                             OR (scope = 'chat' AND chat_id = ?2)
                             OR (?3 IS NOT NULL AND scope = 'user' AND subject_user_id = ?3)
                           )
                           AND telegram_structured_memory_fts MATCH ?4
                         ORDER BY rank
                         LIMIT ?5",
                    ),
                    None if subject_user_id.is_some() => conn.prepare(
                        "SELECT entry_id, bm25(telegram_structured_memory_fts) AS rank
                         FROM telegram_structured_memory_fts
                         WHERE channel_id = ?1
                           AND (
                             scope = 'channel'
                             OR (scope = 'user' AND subject_user_id = ?2)
                           )
                           AND telegram_structured_memory_fts MATCH ?3
                         ORDER BY rank
                         LIMIT ?4",
                    ),
                    None => conn.prepare(
                        "SELECT entry_id, bm25(telegram_structured_memory_fts) AS rank
                         FROM telegram_structured_memory_fts
                         WHERE channel_id = ?1
                           AND telegram_structured_memory_fts MATCH ?2
                         ORDER BY rank
                         LIMIT ?3",
                    ),
                }
                .map_err(|e| e.to_string())?;

                let rows = match (chat_id, subject_user_id) {
                    (Some(chat_id), subject_user_id) => stmt.query_map(
                        params![
                            channel_id_str.as_str(),
                            chat_id,
                            subject_user_id,
                            fts_query.as_str(),
                            limit.max(8) as i64
                        ],
                        row_to_telegram_memory_search_rank,
                    ),
                    (None, Some(subject_user_id)) => stmt.query_map(
                        params![
                            channel_id_str.as_str(),
                            subject_user_id,
                            fts_query.as_str(),
                            limit.max(8) as i64
                        ],
                        row_to_telegram_memory_search_rank,
                    ),
                    (None, None) => stmt.query_map(
                        params![
                            channel_id_str.as_str(),
                            fts_query.as_str(),
                            limit.max(8) as i64
                        ],
                        row_to_telegram_memory_search_rank,
                    ),
                }
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

                for (entry_id, rank) in rows {
                    let entry_uuid = parse_uuid_or_nil(&entry_id);
                    if entry_uuid.is_nil() {
                        continue;
                    }
                    let weight = 18.0 / (1.0 + rank.abs());
                    fts_scores.insert(entry_uuid, weight);
                }
            }

            // Inject FTS-matched entries that fell outside the recency window
            // so older but highly relevant memories are not silently dropped.
            let candidate_ids: std::collections::HashSet<Uuid> =
                candidates.iter().map(|e| e.id).collect();
            for fts_id in fts_scores.keys() {
                if candidate_ids.contains(fts_id) {
                    continue;
                }
                let id_str = fts_id.to_string();
                if let Ok(mut stmt) = conn.prepare(
                    "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                            subject_user_id, subject_username, subject_display_name,
                            source_message_id, source_role, created_at, updated_at
                     FROM telegram_structured_memory
                     WHERE id = ?1",
                ) {
                    if let Ok(mut rows) =
                        stmt.query_map(params![id_str], row_to_telegram_structured_memory)
                    {
                        if let Some(Ok(entry)) = rows.next() {
                            candidates.push(entry);
                        }
                    }
                }
            }

            let mut hits = candidates
                .into_iter()
                .filter_map(|entry| {
                    score_memory_entry(
                        &entry,
                        &normalized_query,
                        &core_query,
                        &query_tokens,
                        fts_scores.get(&entry.id).copied(),
                    )
                })
                .collect::<Vec<_>>();

            hits.sort_by(|left, right| {
                right
                    .score
                    .total_cmp(&left.score)
                    .then_with(|| {
                        scope_rank(&left.entry.scope).cmp(&scope_rank(&right.entry.scope))
                    })
                    .then_with(|| right.entry.updated_at.cmp(&left.entry.updated_at))
            });
            hits.truncate(limit);
            Ok(hits)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_telegram_memory_context(
        &self,
        channel_id: Uuid,
        chat_id: i64,
        subject_user_id: Option<i64>,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemoryEntry>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                            subject_user_id, subject_username, subject_display_name,
                            source_message_id, source_role, created_at, updated_at
                     FROM telegram_structured_memory
                     WHERE channel_id = ?1
                       AND (
                         scope = 'channel'
                         OR (scope = 'chat' AND chat_id = ?2)
                         OR (?3 IS NOT NULL AND scope = 'user' AND subject_user_id = ?3)
                       )
                     ORDER BY
                       CASE scope
                         WHEN 'chat' THEN 0
                         WHEN 'user' THEN 1
                         ELSE 2
                       END,
                       updated_at DESC
                     LIMIT ?4",
                )
                .map_err(|e| e.to_string())?;
            let entries = stmt
                .query_map(
                    params![channel_id_str, chat_id, subject_user_id, limit as i64],
                    row_to_telegram_structured_memory,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(entries)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn search_telegram_memory_context(
        &self,
        channel_id: Uuid,
        chat_id: i64,
        subject_user_id: Option<i64>,
        query: &str,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemoryEntry>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        let query = query.trim().to_lowercase();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                            subject_user_id, subject_username, subject_display_name,
                            source_message_id, source_role, created_at, updated_at
                     FROM telegram_structured_memory
                     WHERE channel_id = ?1
                       AND (
                         scope = 'channel'
                         OR (scope = 'chat' AND chat_id = ?2)
                         OR (?3 IS NOT NULL AND scope = 'user' AND subject_user_id = ?3)
                       )
                       AND (
                         instr(lower(coalesce(label, '')), ?4) > 0
                         OR instr(lower(value), ?4) > 0
                         OR instr(lower(coalesce(subject_display_name, '')), ?4) > 0
                         OR instr(lower(coalesce(subject_username, '')), ?4) > 0
                       )
                     ORDER BY
                       CASE scope
                         WHEN 'chat' THEN 0
                         WHEN 'user' THEN 1
                         ELSE 2
                       END,
                       updated_at DESC
                     LIMIT ?5",
                )
                .map_err(|e| e.to_string())?;
            let entries = stmt
                .query_map(
                    params![
                        channel_id_str,
                        chat_id,
                        subject_user_id,
                        query,
                        limit as i64
                    ],
                    row_to_telegram_structured_memory,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(entries)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn create_telegram_action_execution(
        &self,
        execution: TelegramActionExecution,
    ) -> Result<TelegramActionExecution, String> {
        let conn = self.conn.clone();
        let execution_clone = execution.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_action_executions (
                    id, channel_id, source_mission_id, source_chat_id, target_chat_id, target_chat_title,
                    action_kind, target_kind, target_value, text, delay_seconds, scheduled_message_id,
                    status, last_error, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
                params![
                    execution_clone.id.to_string(),
                    execution_clone.channel_id.to_string(),
                    execution_clone.source_mission_id.map(|id| id.to_string()),
                    execution_clone.source_chat_id,
                    execution_clone.target_chat_id,
                    execution_clone.target_chat_title,
                    match execution_clone.action_kind {
                        TelegramActionExecutionKind::Send => "send",
                        TelegramActionExecutionKind::Reminder => "reminder",
                    },
                    execution_clone.target_kind,
                    execution_clone.target_value,
                    execution_clone.text,
                    execution_clone.delay_seconds as i64,
                    execution_clone.scheduled_message_id.map(|id| id.to_string()),
                    match execution_clone.status {
                        TelegramActionExecutionStatus::Pending => "pending",
                        TelegramActionExecutionStatus::Sent => "sent",
                        TelegramActionExecutionStatus::Failed => "failed",
                    },
                    execution_clone.last_error,
                    execution_clone.created_at,
                    execution_clone.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(execution)
    }

    async fn list_telegram_action_executions(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        limit: usize,
    ) -> Result<Vec<TelegramActionExecution>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let sql = if chat_id.is_some() {
                "SELECT id, channel_id, source_mission_id, source_chat_id, target_chat_id,
                        target_chat_title, action_kind, target_kind, target_value, text,
                        delay_seconds, scheduled_message_id, status, last_error, created_at, updated_at
                 FROM telegram_action_executions
                 WHERE channel_id = ?1 AND target_chat_id = ?2
                 ORDER BY updated_at DESC
                 LIMIT ?3"
            } else {
                "SELECT id, channel_id, source_mission_id, source_chat_id, target_chat_id,
                        target_chat_title, action_kind, target_kind, target_value, text,
                        delay_seconds, scheduled_message_id, status, last_error, created_at, updated_at
                 FROM telegram_action_executions
                 WHERE channel_id = ?1
                 ORDER BY updated_at DESC
                 LIMIT ?2"
            };
            let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
            let limit_i64 = limit as i64;
            let entries = if let Some(chat_id) = chat_id {
                stmt.query_map(
                    params![channel_id_str, chat_id, limit_i64],
                    row_to_telegram_action_execution,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?
            } else {
                stmt.query_map(
                    params![channel_id_str, limit_i64],
                    row_to_telegram_action_execution,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?
            };
            Ok(entries)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn mark_telegram_action_execution_by_scheduled_message(
        &self,
        scheduled_message_id: Uuid,
        status: TelegramActionExecutionStatus,
        last_error: Option<&str>,
        updated_at: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let scheduled_message_id = scheduled_message_id.to_string();
        let updated_at = updated_at.to_string();
        let last_error = last_error.map(ToOwned::to_owned);
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_action_executions
                 SET status = ?1,
                     last_error = ?2,
                     updated_at = ?3
                 WHERE scheduled_message_id = ?4",
                params![
                    match status {
                        TelegramActionExecutionStatus::Pending => "pending",
                        TelegramActionExecutionStatus::Sent => "sent",
                        TelegramActionExecutionStatus::Failed => "failed",
                    },
                    last_error,
                    updated_at,
                    scheduled_message_id,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn upsert_telegram_conversation(
        &self,
        conversation: TelegramConversation,
    ) -> Result<TelegramConversation, String> {
        let conn = self.conn.clone();
        let conversation_clone = conversation.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_conversations (
                    id, channel_id, chat_id, mission_id, chat_title, chat_type, last_message_at, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(channel_id, chat_id) DO UPDATE SET
                    mission_id = excluded.mission_id,
                    chat_title = coalesce(excluded.chat_title, telegram_conversations.chat_title),
                    chat_type = coalesce(excluded.chat_type, telegram_conversations.chat_type),
                    last_message_at = coalesce(excluded.last_message_at, telegram_conversations.last_message_at),
                    updated_at = excluded.updated_at",
                params![
                    conversation_clone.id.to_string(),
                    conversation_clone.channel_id.to_string(),
                    conversation_clone.chat_id,
                    conversation_clone.mission_id.map(|id| id.to_string()),
                    conversation_clone.chat_title.clone(),
                    conversation_clone.chat_type.clone(),
                    conversation_clone.last_message_at.clone(),
                    conversation_clone.created_at.clone(),
                    conversation_clone.updated_at.clone(),
                ],
            )
            .map_err(|e| e.to_string())?;

            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, chat_id, mission_id, chat_title, chat_type, last_message_at, created_at, updated_at
                     FROM telegram_conversations
                     WHERE channel_id = ?1 AND chat_id = ?2",
                )
                .map_err(|e| e.to_string())?;
            stmt.query_row(
                params![
                    conversation_clone.channel_id.to_string(),
                    conversation_clone.chat_id
                ],
                row_to_telegram_conversation,
            )
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_telegram_conversation_by_chat(
        &self,
        channel_id: Uuid,
        chat_id: i64,
    ) -> Result<Option<TelegramConversation>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, chat_id, mission_id, chat_title, chat_type, last_message_at, created_at, updated_at
                     FROM telegram_conversations
                     WHERE channel_id = ?1 AND chat_id = ?2",
                )
                .map_err(|e| e.to_string())?;
            stmt.query_row(
                params![channel_id.to_string(), chat_id],
                row_to_telegram_conversation,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_telegram_conversations(
        &self,
        channel_id: Uuid,
        limit: usize,
    ) -> Result<Vec<TelegramConversation>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, chat_id, mission_id, chat_title, chat_type, last_message_at, created_at, updated_at
                     FROM telegram_conversations
                     WHERE channel_id = ?1
                     ORDER BY coalesce(last_message_at, updated_at) DESC
                     LIMIT ?2",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(
                params![channel_id.to_string(), limit as i64],
                row_to_telegram_conversation,
            )
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn create_telegram_conversation_message(
        &self,
        message: TelegramConversationMessage,
    ) -> Result<TelegramConversationMessage, String> {
        let conn = self.conn.clone();
        let message_clone = message.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_conversation_messages (
                    id, conversation_id, channel_id, chat_id, mission_id, workflow_id, telegram_message_id,
                    direction, role, sender_user_id, sender_username, sender_display_name,
                    reply_to_message_id, text, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
                params![
                    message_clone.id.to_string(),
                    message_clone.conversation_id.to_string(),
                    message_clone.channel_id.to_string(),
                    message_clone.chat_id,
                    message_clone.mission_id.map(|id| id.to_string()),
                    message_clone.workflow_id.map(|id| id.to_string()),
                    message_clone.telegram_message_id,
                    match message_clone.direction {
                        TelegramConversationMessageDirection::Inbound => "inbound",
                        TelegramConversationMessageDirection::Outbound => "outbound",
                    },
                    message_clone.role.clone(),
                    message_clone.sender_user_id,
                    message_clone.sender_username.clone(),
                    message_clone.sender_display_name.clone(),
                    message_clone.reply_to_message_id,
                    message_clone.text.clone(),
                    message_clone.created_at.clone(),
                ],
            )
            .map_err(|e| e.to_string())?;
            conn.execute(
                "UPDATE telegram_conversations
                 SET last_message_at = ?1, updated_at = ?1
                 WHERE id = ?2",
                params![message_clone.created_at, message_clone.conversation_id.to_string()],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(message_clone)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_telegram_conversation_messages(
        &self,
        conversation_id: Uuid,
        limit: usize,
    ) -> Result<Vec<TelegramConversationMessage>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, conversation_id, channel_id, chat_id, mission_id, workflow_id, telegram_message_id,
                            direction, role, sender_user_id, sender_username, sender_display_name,
                            reply_to_message_id, text, created_at
                     FROM telegram_conversation_messages
                     WHERE conversation_id = ?1
                     ORDER BY created_at DESC
                     LIMIT ?2",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(
                params![conversation_id.to_string(), limit as i64],
                row_to_telegram_conversation_message,
            )
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn create_telegram_workflow(
        &self,
        workflow: TelegramWorkflow,
    ) -> Result<TelegramWorkflow, String> {
        let conn = self.conn.clone();
        let workflow_clone = workflow.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_workflows (
                    id, channel_id, origin_conversation_id, origin_chat_id, origin_mission_id,
                    target_conversation_id, target_chat_id, target_chat_title, target_chat_type,
                    target_request_message_id, initiated_by_user_id, initiated_by_username, kind,
                    status, request_text, latest_reply_text, summary, last_error, created_at,
                    updated_at, completed_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)",
                params![
                    workflow_clone.id.to_string(),
                    workflow_clone.channel_id.to_string(),
                    workflow_clone.origin_conversation_id.to_string(),
                    workflow_clone.origin_chat_id,
                    workflow_clone.origin_mission_id.map(|id| id.to_string()),
                    workflow_clone.target_conversation_id.map(|id| id.to_string()),
                    workflow_clone.target_chat_id,
                    workflow_clone.target_chat_title.clone(),
                    workflow_clone.target_chat_type.clone(),
                    workflow_clone.target_request_message_id,
                    workflow_clone.initiated_by_user_id,
                    workflow_clone.initiated_by_username.clone(),
                    match workflow_clone.kind {
                        TelegramWorkflowKind::RequestReply => "request_reply",
                    },
                    match workflow_clone.status {
                        TelegramWorkflowStatus::WaitingExternal => "waiting_external",
                        TelegramWorkflowStatus::RelayedToOrigin => "relayed_to_origin",
                        TelegramWorkflowStatus::Completed => "completed",
                        TelegramWorkflowStatus::Failed => "failed",
                        TelegramWorkflowStatus::Cancelled => "cancelled",
                    },
                    workflow_clone.request_text.clone(),
                    workflow_clone.latest_reply_text.clone(),
                    workflow_clone.summary.clone(),
                    workflow_clone.last_error.clone(),
                    workflow_clone.created_at.clone(),
                    workflow_clone.updated_at.clone(),
                    workflow_clone.completed_at.clone(),
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(workflow_clone)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn update_telegram_workflow(&self, workflow: TelegramWorkflow) -> Result<(), String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_workflows
                 SET target_conversation_id = ?1,
                     target_chat_id = ?2,
                     target_chat_title = ?3,
                     target_chat_type = ?4,
                     target_request_message_id = ?5,
                     status = ?6,
                     latest_reply_text = ?7,
                     summary = ?8,
                     last_error = ?9,
                     updated_at = ?10,
                     completed_at = ?11
                 WHERE id = ?12",
                params![
                    workflow.target_conversation_id.map(|id| id.to_string()),
                    workflow.target_chat_id,
                    workflow.target_chat_title,
                    workflow.target_chat_type,
                    workflow.target_request_message_id,
                    match workflow.status {
                        TelegramWorkflowStatus::WaitingExternal => "waiting_external",
                        TelegramWorkflowStatus::RelayedToOrigin => "relayed_to_origin",
                        TelegramWorkflowStatus::Completed => "completed",
                        TelegramWorkflowStatus::Failed => "failed",
                        TelegramWorkflowStatus::Cancelled => "cancelled",
                    },
                    workflow.latest_reply_text,
                    workflow.summary,
                    workflow.last_error,
                    workflow.updated_at,
                    workflow.completed_at,
                    workflow.id.to_string(),
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn timeout_stale_telegram_workflows(&self, max_age_secs: i64) -> Result<u32, String> {
        let conn = self.conn.clone();
        let now = now_string();
        // Calculate the cutoff timestamp in Rust (RFC 3339 format sorts lexicographically)
        let cutoff = chrono::Utc::now() - chrono::Duration::seconds(max_age_secs);
        let cutoff_str = cutoff.to_rfc3339();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let updated = conn
                .execute(
                    "UPDATE telegram_workflows
                     SET status = 'failed',
                         last_error = 'Timed out waiting for external reply',
                         updated_at = ?1,
                         completed_at = ?1
                     WHERE status = 'waiting_external'
                       AND updated_at < ?2",
                    params![now, cutoff_str],
                )
                .map_err(|e| e.to_string())?;
            Ok(updated as u32)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn register_webhook_update(
        &self,
        channel_id: Uuid,
        update_id: i64,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        let now = now_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // INSERT OR IGNORE: if the row already exists, nothing happens
            // and changes() returns 0.
            let inserted = conn
                .execute(
                    "INSERT OR IGNORE INTO telegram_webhook_dedup (channel_id, update_id, seen_at)
                     VALUES (?1, ?2, ?3)",
                    params![channel_id_str, update_id, now],
                )
                .map_err(|e| e.to_string())?;
            Ok(inserted > 0)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn cleanup_webhook_dedup(&self, max_age_secs: i64) -> Result<u32, String> {
        let conn = self.conn.clone();
        let cutoff = (chrono::Utc::now() - chrono::Duration::seconds(max_age_secs)).to_rfc3339();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let deleted = conn
                .execute(
                    "DELETE FROM telegram_webhook_dedup
                     WHERE seen_at < ?1",
                    params![cutoff],
                )
                .map_err(|e| e.to_string())?;
            Ok(deleted as u32)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    async fn list_telegram_workflows(
        &self,
        channel_id: Uuid,
        limit: usize,
    ) -> Result<Vec<TelegramWorkflow>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, origin_conversation_id, origin_chat_id, origin_mission_id,
                            target_conversation_id, target_chat_id, target_chat_title, target_chat_type,
                            target_request_message_id, initiated_by_user_id, initiated_by_username,
                            kind, status, request_text, latest_reply_text, summary, last_error,
                            created_at, updated_at, completed_at
                     FROM telegram_workflows
                     WHERE channel_id = ?1
                     ORDER BY updated_at DESC
                     LIMIT ?2",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(
                params![channel_id.to_string(), limit as i64],
                row_to_telegram_workflow,
            )
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_pending_telegram_workflow_for_target_chat(
        &self,
        channel_id: Uuid,
        target_chat_id: i64,
    ) -> Result<Option<TelegramWorkflow>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, origin_conversation_id, origin_chat_id, origin_mission_id,
                            target_conversation_id, target_chat_id, target_chat_title, target_chat_type,
                            target_request_message_id, initiated_by_user_id, initiated_by_username,
                            kind, status, request_text, latest_reply_text, summary, last_error,
                            created_at, updated_at, completed_at
                     FROM telegram_workflows
                     WHERE channel_id = ?1
                       AND target_chat_id = ?2
                       AND status = 'waiting_external'
                     ORDER BY updated_at DESC
                     LIMIT 1",
                )
                .map_err(|e| e.to_string())?;
            stmt.query_row(
                params![channel_id.to_string(), target_chat_id],
                row_to_telegram_workflow,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn get_pending_telegram_workflow_for_target_message(
        &self,
        channel_id: Uuid,
        target_chat_id: i64,
        request_message_id: i64,
    ) -> Result<Option<TelegramWorkflow>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, origin_conversation_id, origin_chat_id, origin_mission_id,
                            target_conversation_id, target_chat_id, target_chat_title, target_chat_type,
                            target_request_message_id, initiated_by_user_id, initiated_by_username,
                            kind, status, request_text, latest_reply_text, summary, last_error,
                            created_at, updated_at, completed_at
                     FROM telegram_workflows
                     WHERE channel_id = ?1
                       AND target_chat_id = ?2
                       AND target_request_message_id = ?3
                       AND status = 'waiting_external'
                     ORDER BY updated_at DESC
                     LIMIT 1",
                )
                .map_err(|e| e.to_string())?;
            stmt.query_row(
                params![channel_id.to_string(), target_chat_id, request_message_id],
                row_to_telegram_workflow,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn create_telegram_workflow_event(
        &self,
        event: TelegramWorkflowEvent,
    ) -> Result<TelegramWorkflowEvent, String> {
        let conn = self.conn.clone();
        let event_clone = event.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_workflow_events (
                    id, workflow_id, conversation_id, event_type, payload_json, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    event_clone.id.to_string(),
                    event_clone.workflow_id.to_string(),
                    event_clone.conversation_id.map(|id| id.to_string()),
                    event_clone.event_type.clone(),
                    event_clone.payload_json.clone(),
                    event_clone.created_at.clone(),
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(event_clone)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn list_telegram_workflow_events(
        &self,
        workflow_id: Uuid,
        limit: usize,
    ) -> Result<Vec<TelegramWorkflowEvent>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, workflow_id, conversation_id, event_type, payload_json, created_at
                     FROM telegram_workflow_events
                     WHERE workflow_id = ?1
                     ORDER BY created_at DESC
                     LIMIT ?2",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(
                    params![workflow_id.to_string(), limit as i64],
                    row_to_telegram_workflow_event,
                )
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    async fn import_mission_bundle(
        &self,
        bundle: super::MissionBundle,
        options: super::MissionImportOptions,
    ) -> Result<Uuid, String> {
        use super::MissionBundle;
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
                    super::AutomationDriver::Scheduler => "scheduler",
                    super::AutomationDriver::HarnessLoop => "harness_loop",
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

    // ---- Task board ------------------------------------------------------

    async fn upsert_board_tasks(
        &self,
        boss_mission_id: Uuid,
        tasks: Vec<NewBoardTask>,
    ) -> Result<Vec<BoardTask>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let now = now_string();
            let mut out = Vec::with_capacity(tasks.len());
            for t in tasks {
                let existing: Option<(String, String)> = conn
                    .query_row(
                        "SELECT id, status FROM board_tasks WHERE boss_mission_id = ?1 AND task_key = ?2",
                        params![boss_mission_id.to_string(), t.task_key],
                        |row| Ok((row.get(0)?, row.get(1)?)),
                    )
                    .optional()
                    .map_err(|e| format!("Failed to look up board task: {e}"))?;

                let depends_on_json = serde_json::to_string(&t.depends_on)
                    .map_err(|e| format!("Failed to serialize depends_on: {e}"))?;

                let row_id = match existing {
                    Some((id, status)) if status == "pending" => {
                        conn.execute(
                            "UPDATE board_tasks SET title = ?1, prompt = ?2, backend = ?3, \
                             model_override = ?4, model_effort = ?5, working_directory = ?6, \
                             repository = ?7, branch = ?8, role = ?9, acceptance_criteria = ?10, \
                             verification_command = ?11, design_domain = ?12, declared_write_set = ?13, \
                             risk_class = ?14, token_budget = ?15, cost_budget_cents = ?16, \
                             depends_on = ?17, updated_at = ?18 WHERE id = ?19",
                            params![
                                t.title,
                                t.prompt,
                                t.backend,
                                t.model_override,
                                t.model_effort,
                                t.working_directory,
                                t.repository,
                                t.branch,
                                t.role.to_string(),
                                serde_json::to_string(&t.acceptance_criteria).unwrap_or_else(|_| "[]".into()),
                                t.verification_command,
                                t.design_domain,
                                serde_json::to_string(&t.declared_write_set).unwrap_or_else(|_| "[]".into()),
                                t.risk_class,
                                t.token_budget.map(|value| value as i64),
                                t.cost_budget_cents,
                                depends_on_json,
                                now,
                                id,
                            ],
                        )
                        .map_err(|e| format!("Failed to update board task: {e}"))?;
                        id
                    }
                    Some((id, status)) if status == "running" => {
                        // A worker is already executing this task, so its
                        // prompt/backend/deps are frozen — but the OUTCOME
                        // CONTRACT may still be corrected. `plan_tasks` warns
                        // about missing acceptance criteria only after
                        // registration, and the scheduler can spawn the task
                        // within one pass (~3s), before the boss reads the
                        // warning. Letting the contract fields through means
                        // that correction still lands: verdict guidance and
                        // the retry prompt read them live, and a retry's
                        // worker contract delivers them.
                        conn.execute(
                            "UPDATE board_tasks SET acceptance_criteria = ?1, \
                             verification_command = ?2, risk_class = ?3, updated_at = ?4 \
                             WHERE id = ?5",
                            params![
                                serde_json::to_string(&t.acceptance_criteria)
                                    .unwrap_or_else(|_| "[]".into()),
                                t.verification_command,
                                t.risk_class,
                                now,
                                id,
                            ],
                        )
                        .map_err(|e| format!("Failed to update running task contract: {e}"))?;
                        id
                    }
                    Some((id, _)) => id, // settled/terminal: leave untouched
                    None => {
                        let id = Uuid::new_v4().to_string();
                        conn.execute(
                            "INSERT INTO board_tasks (id, boss_mission_id, task_key, title, prompt, \
                             backend, model_override, model_effort, working_directory, repository, branch, \
                             role, acceptance_criteria, verification_command, design_domain, declared_write_set, \
                             risk_class, token_budget, cost_budget_cents, depends_on, status, attempts, created_at, updated_at) \
                             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, \
                             ?15, ?16, ?17, ?18, ?19, ?20, 'pending', 0, ?21, ?21)",
                            params![
                                id,
                                boss_mission_id.to_string(),
                                t.task_key,
                                t.title,
                                t.prompt,
                                t.backend,
                                t.model_override,
                                t.model_effort,
                                t.working_directory,
                                t.repository,
                                t.branch,
                                t.role.to_string(),
                                serde_json::to_string(&t.acceptance_criteria).unwrap_or_else(|_| "[]".into()),
                                t.verification_command,
                                t.design_domain,
                                serde_json::to_string(&t.declared_write_set).unwrap_or_else(|_| "[]".into()),
                                t.risk_class,
                                t.token_budget.map(|value| value as i64),
                                t.cost_budget_cents,
                                depends_on_json,
                                now,
                            ],
                        )
                        .map_err(|e| format!("Failed to insert board task: {e}"))?;
                        id
                    }
                };

                let task = conn
                    .query_row(
                        &format!("SELECT {BOARD_TASK_COLUMNS} FROM board_tasks WHERE id = ?1"),
                        params![row_id],
                        parse_board_task_row,
                    )
                    .map_err(|e| format!("Failed to re-read board task: {e}"))?;
                out.push(task);
            }
            Ok(out)
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    async fn list_board_tasks(&self, boss_mission_id: Uuid) -> Result<Vec<BoardTask>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(&format!(
                    "SELECT {BOARD_TASK_COLUMNS} FROM board_tasks \
                     WHERE boss_mission_id = ?1 ORDER BY created_at ASC, task_key ASC"
                ))
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![boss_mission_id.to_string()], parse_board_task_row)
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    async fn list_board_tasks_for_project(&self, project: &str) -> Result<Vec<BoardTask>, String> {
        let conn = self.conn.clone();
        let project = project.to_string();
        // Qualify every column so the missions join can't shadow board task
        // columns (both tables have id/status/created_at/...).
        let columns = BOARD_TASK_COLUMNS
            .split(',')
            .map(|column| format!("bt.{}", column.trim()))
            .collect::<Vec<_>>()
            .join(", ");
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(&format!(
                    "SELECT {columns} FROM board_tasks bt \
                     JOIN missions m ON m.id = bt.boss_mission_id \
                     WHERE {BOARD_TASK_PROJECT_FAMILY_PREDICATE} \
                     ORDER BY bt.created_at ASC, bt.task_key ASC"
                ))
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![project], parse_board_task_row)
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    async fn list_active_board_missions(&self) -> Result<Vec<Uuid>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT DISTINCT boss_mission_id FROM board_tasks \
                     WHERE status IN ('pending', 'running', 'settled')",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(|e| e.to_string())?;
            let mut out = Vec::new();
            for r in rows {
                let s = r.map_err(|e| e.to_string())?;
                if let Ok(id) = Uuid::parse_str(&s) {
                    out.push(id);
                }
            }
            Ok(out)
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    async fn get_board_task(&self, task_id: Uuid) -> Result<Option<BoardTask>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                &format!("SELECT {BOARD_TASK_COLUMNS} FROM board_tasks WHERE id = ?1"),
                params![task_id.to_string()],
                parse_board_task_row,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    async fn get_board_task_by_worker(
        &self,
        worker_mission_id: Uuid,
    ) -> Result<Option<BoardTask>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                &format!(
                    "SELECT {BOARD_TASK_COLUMNS} FROM board_tasks \
                     WHERE worker_mission_id = ?1 ORDER BY updated_at DESC LIMIT 1"
                ),
                params![worker_mission_id.to_string()],
                parse_board_task_row,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    async fn save_board_task(&self, task: &BoardTask) -> Result<(), String> {
        let conn = self.conn.clone();
        let t = task.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let depends_on_json = serde_json::to_string(&t.depends_on)
                .map_err(|e| format!("Failed to serialize depends_on: {e}"))?;
            let updated = conn
                .execute(
                    "UPDATE board_tasks SET task_key = ?1, title = ?2, prompt = ?3, backend = ?4, \
                     model_override = ?5, model_effort = ?6, working_directory = ?7, repository = ?8, \
                     branch = ?9, role = ?10, acceptance_criteria = ?11, verification_command = ?12, \
                     design_domain = ?13, declared_write_set = ?14, risk_class = ?15, token_budget = ?16, \
                     cost_budget_cents = ?17, depends_on = ?18, status = ?19, outcome = ?20, \
                     worker_mission_id = ?21, prior_worker_mission_id = ?22, prior_outcome = ?23, \
                     prior_result_digest = ?24, attempts = ?25, result_digest = ?26, notes = ?27, \
                     updated_at = ?28 WHERE id = ?29",
                    params![
                        t.task_key,
                        t.title,
                        t.prompt,
                        t.backend,
                        t.model_override,
                        t.model_effort,
                        t.working_directory,
                        t.repository,
                        t.branch,
                        t.role.to_string(),
                        serde_json::to_string(&t.acceptance_criteria).unwrap_or_else(|_| "[]".into()),
                        t.verification_command,
                        t.design_domain,
                        serde_json::to_string(&t.declared_write_set).unwrap_or_else(|_| "[]".into()),
                        t.risk_class,
                        t.token_budget.map(|value| value as i64),
                        t.cost_budget_cents,
                        depends_on_json,
                        t.status.to_string(),
                        t.outcome.map(|o| o.to_string()),
                        t.worker_mission_id.map(|id| id.to_string()),
                        t.prior_worker_mission_id.map(|id| id.to_string()),
                        t.prior_outcome.map(|o| o.to_string()),
                        t.prior_result_digest,
                        t.attempts as i64,
                        t.result_digest,
                        t.notes,
                        now_string(),
                        t.id.to_string(),
                    ],
                )
                .map_err(|e| format!("Failed to save board task: {e}"))?;
            if updated == 0 {
                return Err(format!("Board task {} not found", t.id));
            }
            Ok(())
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    async fn create_task_attempt(&self, attempt: TaskAttempt) -> Result<TaskAttempt, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO task_attempts (id, task_id, attempt_number, mission_id, backend, model, role, \
                 run_id, commit_sha, changed_files, verification_evidence, cost_cents, terminal_class, started_at, finished_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15) \
                 ON CONFLICT(task_id, attempt_number) DO NOTHING",
                params![
                    attempt.id.to_string(), attempt.task_id.to_string(), attempt.attempt_number as i64,
                    attempt.mission_id.to_string(), attempt.backend, attempt.model,
                    attempt.role.to_string(), attempt.run_id.map(|id| id.to_string()), attempt.commit_sha,
                    serde_json::to_string(&attempt.changed_files).unwrap_or_else(|_| "[]".into()),
                    attempt.verification_evidence.to_string(), attempt.cost_cents,
                    attempt.terminal_class, attempt.started_at, attempt.finished_at,
                ],
            ).map_err(|error| format!("Failed to create task attempt: {error}"))?;
            conn.query_row(
                "SELECT id, task_id, attempt_number, mission_id, backend, model, role, run_id, commit_sha, \
                 changed_files, verification_evidence, cost_cents, terminal_class, started_at, finished_at \
                 FROM task_attempts WHERE task_id = ?1 AND attempt_number = ?2",
                params![attempt.task_id.to_string(), attempt.attempt_number as i64],
                parse_task_attempt_row,
            ).map_err(|error| format!("Failed to read task attempt: {error}"))
        }).await.map_err(|error| format!("Task join error: {error}"))?
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
        let conn = self.conn.clone();
        let terminal_class = terminal_class.to_string();
        let commit_sha = commit_sha.map(str::to_string);
        let changed_files = serde_json::to_string(changed_files).map_err(|e| e.to_string())?;
        let verification_evidence = verification_evidence.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let updated = conn.execute(
                "UPDATE task_attempts SET terminal_class = ?1, commit_sha = ?2, changed_files = ?3, \
                 verification_evidence = ?4, cost_cents = ?5, finished_at = ?6 \
                 WHERE task_id = ?7 AND attempt_number = ?8",
                params![terminal_class, commit_sha, changed_files, verification_evidence, cost_cents,
                    now_string(), task_id.to_string(), attempt_number as i64],
            ).map_err(|error| format!("Failed to finish task attempt: {error}"))?;
            (updated > 0).then_some(()).ok_or_else(|| "Task attempt not found".to_string())
        }).await.map_err(|error| format!("Task join error: {error}"))?
    }

    async fn list_task_attempts(&self, task_id: Uuid) -> Result<Vec<TaskAttempt>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut statement = conn.prepare(
                "SELECT id, task_id, attempt_number, mission_id, backend, model, role, run_id, commit_sha, \
                 changed_files, verification_evidence, cost_cents, terminal_class, started_at, finished_at \
                 FROM task_attempts WHERE task_id = ?1 ORDER BY attempt_number"
            ).map_err(|error| error.to_string())?;
            let rows = statement.query_map(params![task_id.to_string()], parse_task_attempt_row)
                .map_err(|error| error.to_string())?
                .collect::<Result<Vec<_>, _>>().map_err(|error| error.to_string())?;
            Ok(rows)
        }).await.map_err(|error| format!("Task join error: {error}"))?
    }

    async fn enqueue_board_outbox(&self, item: BoardOutboxItem) -> Result<BoardOutboxItem, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO board_outbox (id, boss_mission_id, task_id, delivery_kind, idempotency_key, \
                 payload, state, attempts, created_at, acknowledged_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) ON CONFLICT(idempotency_key) DO NOTHING",
                params![item.id.to_string(), item.boss_mission_id.to_string(), item.task_id.map(|id| id.to_string()),
                    item.delivery_kind, item.idempotency_key, item.payload.to_string(), item.state,
                    item.attempts as i64, item.created_at, item.acknowledged_at],
            ).map_err(|error| format!("Failed to enqueue board delivery: {error}"))?;
            conn.query_row(
                "SELECT id, boss_mission_id, task_id, delivery_kind, idempotency_key, payload, state, attempts, \
                 created_at, acknowledged_at FROM board_outbox WHERE idempotency_key = ?1",
                params![item.idempotency_key], parse_board_outbox_row,
            ).map_err(|error| format!("Failed to read board delivery: {error}"))
        }).await.map_err(|error| format!("Task join error: {error}"))?
    }

    async fn acknowledge_board_outbox(&self, idempotency_key: &str) -> Result<(), String> {
        let conn = self.conn.clone();
        let key = idempotency_key.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE board_outbox SET state = 'acknowledged', acknowledged_at = ?1 WHERE idempotency_key = ?2",
                params![now_string(), key],
            ).map(|_| ()).map_err(|error| error.to_string())
        }).await.map_err(|error| format!("Task join error: {error}"))?
    }

    async fn pending_client_delivery_ids(&self) -> Result<Vec<Uuid>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut statement = conn.prepare("SELECT id FROM board_outbox WHERE state != 'acknowledged' AND delivery_kind = 'client_message'").map_err(|e| e.to_string())?;
            let ids = statement.query_map([], |row| row.get::<_, String>(0)).map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?;
            ids.into_iter().map(|id| Uuid::parse_str(&id).map_err(|e| e.to_string())).collect()
        }).await.map_err(|e| format!("Task join error: {e}"))?
    }

    async fn list_pending_board_outbox_filtered(
        &self,
        limit: usize,
        client: Option<bool>,
    ) -> Result<Vec<BoardOutboxItem>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut statement = conn.prepare(
                "SELECT id, boss_mission_id, task_id, delivery_kind, idempotency_key, payload, state, attempts, \
                 created_at, acknowledged_at FROM board_outbox WHERE state != 'acknowledged' AND (?2 IS NULL OR (delivery_kind = 'client_message') = ?2) ORDER BY created_at LIMIT ?1"
            ).map_err(|error| error.to_string())?;
            let rows = statement.query_map(params![limit.min(1000) as i64, client], parse_board_outbox_row)
                .map_err(|error| error.to_string())?
                .collect::<Result<Vec<_>, _>>().map_err(|error| error.to_string())?;
            Ok(rows)
        }).await.map_err(|error| format!("Task join error: {error}"))?
    }
}

/// Byte-exact family match: `?1` itself or `?1-` as a literal prefix.
/// Deliberately NOT `LIKE` — its `_` wildcard would make `foo_bar` match
/// `fooXbar-*`, and its ASCII case-folding would merge differently-cased
/// slugs; `substr`/`||` compare bytes, matching `project_prefix` semantics.
const BOARD_TASK_PROJECT_FAMILY_PREDICATE: &str =
    "(m.project = ?1 OR substr(m.project, 1, length(?1) + 1) = ?1 || '-')";

/// Column list shared by every board task SELECT so `parse_board_task_row`
/// indices stay in sync.
const BOARD_TASK_COLUMNS: &str = "id, boss_mission_id, task_key, title, prompt, backend, \
    model_override, model_effort, working_directory, repository, branch, role, acceptance_criteria, \
    verification_command, design_domain, declared_write_set, risk_class, token_budget, cost_budget_cents, \
    depends_on, status, outcome, worker_mission_id, prior_worker_mission_id, prior_outcome, \
    prior_result_digest, attempts, result_digest, notes, created_at, updated_at";

fn parse_board_task_row(row: &rusqlite::Row<'_>) -> Result<BoardTask, rusqlite::Error> {
    let id: String = row.get(0)?;
    let boss_mission_id: String = row.get(1)?;
    let acceptance_criteria: String = row.get(12)?;
    let declared_write_set: String = row.get(15)?;
    let token_budget: Option<i64> = row.get(17)?;
    let depends_on_json: String = row.get(19)?;
    let status_str: String = row.get(20)?;
    let outcome_str: Option<String> = row.get(21)?;
    let worker_mission_id: Option<String> = row.get(22)?;
    let prior_worker_mission_id: Option<String> = row.get(23)?;
    let prior_outcome: Option<String> = row.get(24)?;
    let attempts: i64 = row.get(26)?;
    Ok(BoardTask {
        id: Uuid::parse_str(&id)
            .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
        boss_mission_id: Uuid::parse_str(&boss_mission_id)
            .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
        task_key: row.get(2)?,
        title: row.get(3)?,
        prompt: row.get(4)?,
        backend: row.get(5)?,
        model_override: row.get(6)?,
        model_effort: row.get(7)?,
        working_directory: row.get(8)?,
        repository: row.get(9)?,
        branch: row.get(10)?,
        role: BoardTaskRole::parse(&row.get::<_, String>(11)?),
        acceptance_criteria: serde_json::from_str(&acceptance_criteria).unwrap_or_default(),
        verification_command: row.get(13)?,
        design_domain: row.get(14)?,
        declared_write_set: serde_json::from_str(&declared_write_set).unwrap_or_default(),
        risk_class: row.get(16)?,
        token_budget: token_budget.map(|value| value.max(0) as u64),
        cost_budget_cents: row.get(18)?,
        depends_on: serde_json::from_str(&depends_on_json).unwrap_or_default(),
        status: BoardTaskStatus::parse(&status_str).unwrap_or(BoardTaskStatus::Pending),
        outcome: outcome_str.as_deref().and_then(BoardTaskOutcome::parse),
        worker_mission_id: worker_mission_id.and_then(|s| Uuid::parse_str(&s).ok()),
        prior_worker_mission_id: prior_worker_mission_id.and_then(|s| Uuid::parse_str(&s).ok()),
        prior_outcome: prior_outcome.as_deref().and_then(BoardTaskOutcome::parse),
        prior_result_digest: row.get(25)?,
        attempts: attempts as u32,
        result_digest: row.get(27)?,
        notes: row.get(28)?,
        created_at: row.get(29)?,
        updated_at: row.get(30)?,
    })
}

fn parse_task_attempt_row(row: &rusqlite::Row<'_>) -> Result<TaskAttempt, rusqlite::Error> {
    let id: String = row.get(0)?;
    let task_id: String = row.get(1)?;
    let attempt_number: i64 = row.get(2)?;
    let mission_id: String = row.get(3)?;
    let role: String = row.get(6)?;
    let run_id: Option<String> = row.get(7)?;
    let changed_files: String = row.get(9)?;
    let evidence: String = row.get(10)?;
    Ok(TaskAttempt {
        id: Uuid::parse_str(&id).unwrap_or_default(),
        task_id: Uuid::parse_str(&task_id).unwrap_or_default(),
        attempt_number: attempt_number.max(0) as u32,
        mission_id: Uuid::parse_str(&mission_id).unwrap_or_default(),
        backend: row.get(4)?,
        model: row.get(5)?,
        role: BoardTaskRole::parse(&role),
        run_id: run_id.and_then(|value| Uuid::parse_str(&value).ok()),
        commit_sha: row.get(8)?,
        changed_files: serde_json::from_str(&changed_files).unwrap_or_default(),
        verification_evidence: serde_json::from_str(&evidence).unwrap_or_default(),
        cost_cents: row.get(11)?,
        terminal_class: row.get(12)?,
        started_at: row.get(13)?,
        finished_at: row.get(14)?,
    })
}

fn parse_board_outbox_row(row: &rusqlite::Row<'_>) -> Result<BoardOutboxItem, rusqlite::Error> {
    let id: String = row.get(0)?;
    let boss_mission_id: String = row.get(1)?;
    let task_id: Option<String> = row.get(2)?;
    let payload: String = row.get(5)?;
    let attempts: i64 = row.get(7)?;
    Ok(BoardOutboxItem {
        id: Uuid::parse_str(&id).unwrap_or_default(),
        boss_mission_id: Uuid::parse_str(&boss_mission_id).unwrap_or_default(),
        task_id: task_id.and_then(|value| Uuid::parse_str(&value).ok()),
        delivery_kind: row.get(3)?,
        idempotency_key: row.get(4)?,
        payload: serde_json::from_str(&payload).unwrap_or_default(),
        state: row.get(6)?,
        attempts: attempts.max(0) as u32,
        created_at: row.get(8)?,
        acknowledged_at: row.get(9)?,
    })
}

fn telegram_user_role_to_str(role: TelegramUserRole) -> &'static str {
    match role {
        TelegramUserRole::Owner => "owner",
        TelegramUserRole::TrustedFriend => "trusted_friend",
        TelegramUserRole::Observer => "observer",
        TelegramUserRole::Blocked => "blocked",
    }
}

fn parse_telegram_user_role(raw: String) -> TelegramUserRole {
    match raw.as_str() {
        "owner" => TelegramUserRole::Owner,
        "trusted_friend" => TelegramUserRole::TrustedFriend,
        "blocked" => TelegramUserRole::Blocked,
        _ => TelegramUserRole::Observer,
    }
}

fn telegram_interest_to_str(level: TelegramMissionInterestLevel) -> &'static str {
    match level {
        TelegramMissionInterestLevel::Muted => "muted",
        TelegramMissionInterestLevel::Normal => "normal",
        TelegramMissionInterestLevel::High => "high",
    }
}

fn parse_telegram_interest(raw: String) -> TelegramMissionInterestLevel {
    match raw.as_str() {
        "muted" => TelegramMissionInterestLevel::Muted,
        "high" => TelegramMissionInterestLevel::High,
        _ => TelegramMissionInterestLevel::Normal,
    }
}

fn row_to_telegram_user(row: &rusqlite::Row<'_>) -> Result<TelegramUser, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let role_str: String = row.get(4)?;
    Ok(TelegramUser {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        telegram_user_id: row.get(1)?,
        username: row.get(2)?,
        display_name: row.get(3)?,
        role: parse_telegram_user_role(role_str),
        created_at: row.get(5)?,
        updated_at: row.get(6)?,
    })
}

fn row_to_telegram_user_cursor(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramUserCursor, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    Ok(TelegramUserCursor {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        telegram_user_id: row.get(1)?,
        last_status_at: row.get(2)?,
        last_dashboard_seen_at: row.get(3)?,
        last_alert_ack_at: row.get(4)?,
        last_digest_at: row.get(5)?,
        last_seen_event_sequence_by_mission_json: row.get(6)?,
        created_at: row.get(7)?,
        updated_at: row.get(8)?,
    })
}

fn row_to_telegram_mission_subscription(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramMissionSubscription, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let mission_id_str: String = row.get(2)?;
    let interest_str: String = row.get(3)?;
    Ok(TelegramMissionSubscription {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        telegram_user_id: row.get(1)?,
        mission_id: Uuid::parse_str(&mission_id_str).unwrap_or_default(),
        interest_level: parse_telegram_interest(interest_str),
        reason: row.get(4)?,
        expires_at: row.get(5)?,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
    })
}

fn row_to_telegram_alert(row: &rusqlite::Row<'_>) -> Result<TelegramAlert, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let mission_id_str: Option<String> = row.get(2)?;
    Ok(TelegramAlert {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        telegram_user_id: row.get(1)?,
        mission_id: mission_id_str
            .as_deref()
            .and_then(|value| Uuid::parse_str(value).ok()),
        event_kind: row.get(3)?,
        importance: row.get(4)?,
        title: row.get(5)?,
        body: row.get(6)?,
        status: row.get(7)?,
        telegram_message_id: row.get(8)?,
        last_error: row.get(9)?,
        created_at: row.get(10)?,
        sent_at: row.get(11)?,
        acknowledged_at: row.get(12)?,
    })
}

fn row_to_telegram_alert_preference(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramAlertPreference, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let enabled: i32 = row.get(5)?;
    Ok(TelegramAlertPreference {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        telegram_user_id: row.get(1)?,
        scope: row.get(2)?,
        scope_value: row.get(3)?,
        rule_text: row.get(4)?,
        enabled: enabled != 0,
        created_from_message_id: row.get(6)?,
        created_at: row.get(7)?,
        updated_at: row.get(8)?,
    })
}

/// Parse a Telegram channel from a SQLite row.
/// Column order: id(0), mission_id(1), bot_token(2), bot_username(3),
///   allowed_chat_ids(4), trigger_mode(5), active(6), webhook_secret(7),
///   instructions(8), created_at(9), updated_at(10),
///   auto_create_missions(11), default_backend(12), default_model_override(13),
///   default_model_effort(14), default_workspace_id(15), default_config_profile(16),
///   default_agent(17)
fn row_to_telegram_channel(row: &rusqlite::Row<'_>) -> TelegramChannel {
    let id_str: String = row.get(0).unwrap_or_default();
    let mission_id_str: String = row.get(1).unwrap_or_default();
    let allowed_chat_ids_json: String = row.get(4).unwrap_or_else(|_| "[]".to_string());
    let trigger_mode_str: String = row.get(5).unwrap_or_else(|_| "direct_message".to_string());
    let default_ws_str: Option<String> = row.get(15).unwrap_or_default();

    TelegramChannel {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        mission_id: Uuid::parse_str(&mission_id_str).unwrap_or_default(),
        bot_token: row.get(2).unwrap_or_default(),
        bot_username: row.get(3).unwrap_or_default(),
        allowed_chat_ids: serde_json::from_str(&allowed_chat_ids_json).unwrap_or_default(),
        trigger_mode: serde_json::from_value(serde_json::Value::String(trigger_mode_str))
            .unwrap_or_default(),
        active: row.get::<_, i32>(6).unwrap_or(0) != 0,
        webhook_secret: row.get(7).unwrap_or_default(),
        instructions: row.get(8).unwrap_or_default(),
        auto_create_missions: row.get::<_, i32>(11).unwrap_or(0) != 0,
        default_backend: row.get(12).unwrap_or_default(),
        default_model_override: row.get(13).unwrap_or_default(),
        default_model_effort: row.get(14).unwrap_or_default(),
        default_workspace_id: default_ws_str.and_then(|s| Uuid::parse_str(&s).ok()),
        default_config_profile: row.get(16).unwrap_or_default(),
        default_agent: row.get(17).unwrap_or_default(),
        created_at: row.get(9).unwrap_or_default(),
        updated_at: row.get(10).unwrap_or_default(),
    }
}

fn row_to_paloma_decision(row: &rusqlite::Row<'_>) -> rusqlite::Result<PalomaDecision> {
    let id_str: String = row.get(0)?;
    let mission_id_str: Option<String> = row.get(2)?;
    let allowed: i32 = row.get(7)?;
    Ok(PalomaDecision {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        event_source: row.get(1)?,
        mission_id: mission_id_str.and_then(|id| Uuid::parse_str(&id).ok()),
        user_id: row.get(3)?,
        channel: row.get(4)?,
        reason_code: row.get(5)?,
        proposed_action: row.get(6)?,
        allowed: allowed != 0,
        suppression_reason: row.get(8)?,
        policy_snapshot_json: row.get(9)?,
        generated_text_hash: row.get(10)?,
        generated_text_preview: row.get(11)?,
        created_at: row.get(12)?,
    })
}

fn row_to_paloma_user_preferences(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<PalomaUserPreferences> {
    let failure_override: i64 = row.get(6)?;
    Ok(PalomaUserPreferences {
        telegram_user_id: row.get(0)?,
        timezone: row.get(1)?,
        quiet_hours_start: row.get(2)?,
        quiet_hours_end: row.get(3)?,
        max_interrupts_per_hour: row.get(4)?,
        max_interrupts_per_day: row.get(5)?,
        failure_override_quiet: failure_override != 0,
        alert_class_overrides_json: row.get(7)?,
        mission_overrides_json: row.get(8)?,
        digest_cadence: row.get(9)?,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
    })
}

fn row_to_paloma_cooldown_state(row: &rusqlite::Row<'_>) -> rusqlite::Result<PalomaCooldownState> {
    let mission_id_str: String = row.get(0)?;
    Ok(PalomaCooldownState {
        mission_id: Uuid::parse_str(&mission_id_str).unwrap_or_default(),
        alert_class: row.get(1)?,
        telegram_user_id: row.get(2)?,
        last_sent_at: row.get(3)?,
        next_eligible_at: row.get(4)?,
        backoff_step: row.get(5)?,
    })
}

fn row_to_paloma_mission_card(row: &rusqlite::Row<'_>) -> rusqlite::Result<PalomaMissionCard> {
    let mission_id_str: String = row.get(0)?;
    let channel_id_str: String = row.get(2)?;
    let archived: i64 = row.get(9)?;
    Ok(PalomaMissionCard {
        mission_id: Uuid::parse_str(&mission_id_str).unwrap_or_default(),
        telegram_user_id: row.get(1)?,
        channel_id: Uuid::parse_str(&channel_id_str).unwrap_or_default(),
        chat_id: row.get(3)?,
        message_id: row.get(4)?,
        content_hash: row.get(5)?,
        anchor_ts: row.get(6)?,
        last_edit_ts: row.get(7)?,
        version: row.get(8)?,
        archived: archived != 0,
    })
}

fn row_to_paloma_scheduler_job(row: &rusqlite::Row<'_>) -> rusqlite::Result<PalomaSchedulerJob> {
    Ok(PalomaSchedulerJob {
        name: row.get(0)?,
        lease_owner: row.get(1)?,
        lease_expires_at: row.get(2)?,
        last_started_at: row.get(3)?,
        last_finished_at: row.get(4)?,
        last_error: row.get(5)?,
        run_count: row.get(6)?,
        updated_at: row.get(7)?,
    })
}

fn parse_telegram_scheduled_status(raw: String) -> TelegramScheduledMessageStatus {
    match raw.as_str() {
        "sent" => TelegramScheduledMessageStatus::Sent,
        "failed" => TelegramScheduledMessageStatus::Failed,
        _ => TelegramScheduledMessageStatus::Pending,
    }
}

fn row_to_telegram_scheduled_message(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramScheduledMessage, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let channel_id_str: String = row.get(1)?;
    let source_mission_id_str: Option<String> = row.get(2)?;
    let status_str: String = row.get(8)?;

    Ok(TelegramScheduledMessage {
        id: parse_uuid_or_nil(&id_str),
        channel_id: parse_uuid_or_nil(&channel_id_str),
        source_mission_id: source_mission_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        chat_id: row.get(3)?,
        chat_title: row.get(4)?,
        text: row.get(5)?,
        send_at: row.get(6)?,
        sent_at: row.get(7)?,
        status: parse_telegram_scheduled_status(status_str),
        last_error: row.get(9)?,
        created_at: row.get(10)?,
    })
}

fn parse_telegram_structured_memory_kind(raw: String) -> TelegramStructuredMemoryKind {
    match raw.as_str() {
        "fact" => TelegramStructuredMemoryKind::Fact,
        "task" => TelegramStructuredMemoryKind::Task,
        "preference" => TelegramStructuredMemoryKind::Preference,
        _ => TelegramStructuredMemoryKind::Note,
    }
}

fn parse_telegram_structured_memory_scope(raw: String) -> TelegramStructuredMemoryScope {
    match raw.as_str() {
        "user" => TelegramStructuredMemoryScope::User,
        "channel" => TelegramStructuredMemoryScope::Channel,
        _ => TelegramStructuredMemoryScope::Chat,
    }
}

fn parse_telegram_action_execution_kind(raw: String) -> TelegramActionExecutionKind {
    match raw.as_str() {
        "reminder" => TelegramActionExecutionKind::Reminder,
        _ => TelegramActionExecutionKind::Send,
    }
}

fn parse_telegram_action_execution_status(raw: String) -> TelegramActionExecutionStatus {
    match raw.as_str() {
        "sent" => TelegramActionExecutionStatus::Sent,
        "failed" => TelegramActionExecutionStatus::Failed,
        _ => TelegramActionExecutionStatus::Pending,
    }
}

fn parse_telegram_conversation_message_direction(
    raw: String,
) -> TelegramConversationMessageDirection {
    match raw.as_str() {
        "outbound" => TelegramConversationMessageDirection::Outbound,
        _ => TelegramConversationMessageDirection::Inbound,
    }
}

fn parse_telegram_workflow_kind(raw: String) -> TelegramWorkflowKind {
    match raw.as_str() {
        "request_reply" => TelegramWorkflowKind::RequestReply,
        _ => TelegramWorkflowKind::RequestReply,
    }
}

fn parse_telegram_workflow_status(raw: String) -> TelegramWorkflowStatus {
    match raw.as_str() {
        "relayed_to_origin" => TelegramWorkflowStatus::RelayedToOrigin,
        "completed" => TelegramWorkflowStatus::Completed,
        "failed" => TelegramWorkflowStatus::Failed,
        "cancelled" => TelegramWorkflowStatus::Cancelled,
        _ => TelegramWorkflowStatus::WaitingExternal,
    }
}

fn row_to_telegram_structured_memory(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramStructuredMemoryEntry, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let channel_id_str: String = row.get(1)?;
    let mission_id_str: Option<String> = row.get(3)?;
    let scope_str: String = row.get(4)?;
    let kind_str: String = row.get(5)?;
    Ok(TelegramStructuredMemoryEntry {
        id: parse_uuid_or_nil(&id_str),
        channel_id: parse_uuid_or_nil(&channel_id_str),
        chat_id: row.get(2)?,
        mission_id: mission_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        scope: parse_telegram_structured_memory_scope(scope_str),
        kind: parse_telegram_structured_memory_kind(kind_str),
        label: row.get(6)?,
        value: row.get(7)?,
        subject_user_id: row.get(8)?,
        subject_username: row.get(9)?,
        subject_display_name: row.get(10)?,
        source_message_id: row.get(11)?,
        source_role: row.get(12)?,
        created_at: row.get(13)?,
        updated_at: row.get(14)?,
    })
}

fn row_to_telegram_memory_search_rank(
    row: &rusqlite::Row<'_>,
) -> Result<(String, f64), rusqlite::Error> {
    Ok((row.get(0)?, row.get(1)?))
}

fn row_to_telegram_action_execution(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramActionExecution, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let channel_id_str: String = row.get(1)?;
    let source_mission_id_str: Option<String> = row.get(2)?;
    let action_kind_str: String = row.get(6)?;
    let scheduled_message_id_str: Option<String> = row.get(11)?;
    let status_str: String = row.get(12)?;

    Ok(TelegramActionExecution {
        id: parse_uuid_or_nil(&id_str),
        channel_id: parse_uuid_or_nil(&channel_id_str),
        source_mission_id: source_mission_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        source_chat_id: row.get(3)?,
        target_chat_id: row.get(4)?,
        target_chat_title: row.get(5)?,
        action_kind: parse_telegram_action_execution_kind(action_kind_str),
        target_kind: row.get(7)?,
        target_value: row.get(8)?,
        text: row.get(9)?,
        delay_seconds: row.get::<_, i64>(10)?.max(0) as u64,
        scheduled_message_id: scheduled_message_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        status: parse_telegram_action_execution_status(status_str),
        last_error: row.get(13)?,
        created_at: row.get(14)?,
        updated_at: row.get(15)?,
    })
}

fn row_to_telegram_conversation(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramConversation, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let channel_id_str: String = row.get(1)?;
    let mission_id_str: Option<String> = row.get(3)?;
    Ok(TelegramConversation {
        id: parse_uuid_or_nil(&id_str),
        channel_id: parse_uuid_or_nil(&channel_id_str),
        chat_id: row.get(2)?,
        mission_id: mission_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        chat_title: row.get(4)?,
        chat_type: row.get(5)?,
        last_message_at: row.get(6)?,
        created_at: row.get(7)?,
        updated_at: row.get(8)?,
    })
}

fn row_to_telegram_conversation_message(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramConversationMessage, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let conversation_id_str: String = row.get(1)?;
    let channel_id_str: String = row.get(2)?;
    let mission_id_str: Option<String> = row.get(4)?;
    let workflow_id_str: Option<String> = row.get(5)?;
    let direction_str: String = row.get(7)?;
    Ok(TelegramConversationMessage {
        id: parse_uuid_or_nil(&id_str),
        conversation_id: parse_uuid_or_nil(&conversation_id_str),
        channel_id: parse_uuid_or_nil(&channel_id_str),
        chat_id: row.get(3)?,
        mission_id: mission_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        workflow_id: workflow_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        telegram_message_id: row.get(6)?,
        direction: parse_telegram_conversation_message_direction(direction_str),
        role: row.get(8)?,
        sender_user_id: row.get(9)?,
        sender_username: row.get(10)?,
        sender_display_name: row.get(11)?,
        reply_to_message_id: row.get(12)?,
        text: row.get(13)?,
        created_at: row.get(14)?,
    })
}

fn row_to_telegram_workflow(row: &rusqlite::Row<'_>) -> Result<TelegramWorkflow, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let channel_id_str: String = row.get(1)?;
    let origin_conversation_id_str: String = row.get(2)?;
    let origin_mission_id_str: Option<String> = row.get(4)?;
    let target_conversation_id_str: Option<String> = row.get(5)?;
    let kind_str: String = row.get(12)?;
    let status_str: String = row.get(13)?;
    Ok(TelegramWorkflow {
        id: parse_uuid_or_nil(&id_str),
        channel_id: parse_uuid_or_nil(&channel_id_str),
        origin_conversation_id: parse_uuid_or_nil(&origin_conversation_id_str),
        origin_chat_id: row.get(3)?,
        origin_mission_id: origin_mission_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        target_conversation_id: target_conversation_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        target_chat_id: row.get(6)?,
        target_chat_title: row.get(7)?,
        target_chat_type: row.get(8)?,
        target_request_message_id: row.get(9)?,
        initiated_by_user_id: row.get(10)?,
        initiated_by_username: row.get(11)?,
        kind: parse_telegram_workflow_kind(kind_str),
        status: parse_telegram_workflow_status(status_str),
        request_text: row.get(14)?,
        latest_reply_text: row.get(15)?,
        summary: row.get(16)?,
        last_error: row.get(17)?,
        created_at: row.get(18)?,
        updated_at: row.get(19)?,
        completed_at: row.get(20)?,
    })
}

fn row_to_telegram_workflow_event(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramWorkflowEvent, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let workflow_id_str: String = row.get(1)?;
    let conversation_id_str: Option<String> = row.get(2)?;
    Ok(TelegramWorkflowEvent {
        id: parse_uuid_or_nil(&id_str),
        workflow_id: parse_uuid_or_nil(&workflow_id_str),
        conversation_id: conversation_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        event_type: row.get(3)?,
        payload_json: row.get(4)?,
        created_at: row.get(5)?,
    })
}
