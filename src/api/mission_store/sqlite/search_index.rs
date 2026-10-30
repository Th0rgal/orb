//! Full-history SQLite FTS5 conversation search projection, incremental
//! maintenance, resumable background backfill, and bounded passage context.

use super::super::{
    build_search_excerpt_utf16, ConversationSearchHit, ConversationSearchQuery,
    ConversationSearchResponse, ConversationSearchRole, ConversationSearchSort, MissionStatus,
    PassageContextMessage, PassageContextQuery, PassageContextResponse, SearchIndexCoverage,
    SearchIndexState, StoredEvent,
};
use super::{now_string, SqliteMissionStore};
use crate::api::cloud_agents::Execution as CloudExecution;
use chrono::{DateTime, Utc};
use rusqlite::{params, types::Value as SqlValue, Connection, OptionalExtension};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Weak;
use tokio::sync::Mutex;
use uuid::Uuid;

pub(crate) const SEARCH_SCHEMA_VERSION: u32 = 2;
const BACKFILL_BATCH_SIZE: usize = 50;
const FTS_CANDIDATE_CAP: usize = 240;
const MAX_TOOL_SUMMARY_BYTES: usize = 4096;
const CONTEXT_EVENT_RADIUS: i64 = 60;
const CONTEXT_MAX_PAYLOAD_BYTES: usize = 4096;

fn parse_mission_status(raw: &str) -> MissionStatus {
    if raw == "archived" {
        return MissionStatus::Acknowledged;
    }
    serde_json::from_value(serde_json::Value::String(raw.to_string()))
        .unwrap_or(MissionStatus::Completed)
}

pub(super) const SEARCH_SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS mission_search_docs (
    doc_id INTEGER PRIMARY KEY AUTOINCREMENT,
    doc_key TEXT NOT NULL UNIQUE,
    mission_id TEXT NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    locator TEXT NOT NULL,
    role TEXT NOT NULL,
    sequence INTEGER,
    event_id TEXT,
    timestamp TEXT NOT NULL,
    title_text TEXT NOT NULL DEFAULT '',
    body_text TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_mission_search_docs_mission
    ON mission_search_docs(mission_id, sequence);
CREATE INDEX IF NOT EXISTS idx_mission_search_docs_role_ts
    ON mission_search_docs(role, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_missions_search_meta
    ON missions(id, project, status)
    WHERE tags IS NULL OR tags NOT LIKE '%"superseded%';

CREATE VIRTUAL TABLE IF NOT EXISTS mission_search_fts USING fts5(
    title_text,
    body_text,
    content='mission_search_docs',
    content_rowid='doc_id',
    tokenize='unicode61 remove_diacritics 2',
    prefix='2 3'
);

CREATE TRIGGER IF NOT EXISTS trg_mission_search_docs_ai
AFTER INSERT ON mission_search_docs BEGIN
    INSERT INTO mission_search_fts(rowid, title_text, body_text)
    VALUES (new.doc_id, new.title_text, new.body_text);
END;

CREATE TRIGGER IF NOT EXISTS trg_mission_search_docs_ad
AFTER DELETE ON mission_search_docs BEGIN
    INSERT INTO mission_search_fts(mission_search_fts, rowid, title_text, body_text)
    VALUES ('delete', old.doc_id, old.title_text, old.body_text);
END;

CREATE TRIGGER IF NOT EXISTS trg_mission_search_docs_au
AFTER UPDATE ON mission_search_docs BEGIN
    INSERT INTO mission_search_fts(mission_search_fts, rowid, title_text, body_text)
    VALUES ('delete', old.doc_id, old.title_text, old.body_text);
    INSERT INTO mission_search_fts(rowid, title_text, body_text)
    VALUES (new.doc_id, new.title_text, new.body_text);
END;

CREATE TRIGGER IF NOT EXISTS trg_missions_search_ad
AFTER DELETE ON missions BEGIN
    DELETE FROM mission_search_docs WHERE mission_id = old.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_missions_search_title_ai
AFTER INSERT ON missions BEGIN
    INSERT INTO mission_search_docs(
        doc_key, mission_id, locator, role, sequence, event_id, timestamp, title_text, body_text
    )
    VALUES (
        new.id || ':title',
        new.id,
        'title',
        'title',
        NULL,
        NULL,
        new.updated_at,
        TRIM(COALESCE(new.title, '') || ' ' || new.id),
        TRIM(
            COALESCE(new.short_description, '') || ' ' ||
            COALESCE(new.goal_objective, '') || ' ' ||
            COALESCE(new.project, '') || ' ' ||
            COALESCE(new.track, '')
        )
    )
    ON CONFLICT(doc_key) DO UPDATE SET
        timestamp = excluded.timestamp,
        title_text = excluded.title_text,
        body_text = excluded.body_text
    WHERE mission_search_docs.title_text <> excluded.title_text
       OR mission_search_docs.body_text <> excluded.body_text;
END;

CREATE TRIGGER IF NOT EXISTS trg_missions_search_title_au
AFTER UPDATE OF title, short_description, goal_objective, project, track ON missions
WHEN COALESCE(old.title, '') <> COALESCE(new.title, '')
  OR COALESCE(old.short_description, '') <> COALESCE(new.short_description, '')
  OR COALESCE(old.goal_objective, '') <> COALESCE(new.goal_objective, '')
  OR COALESCE(old.project, '') <> COALESCE(new.project, '')
  OR COALESCE(old.track, '') <> COALESCE(new.track, '')
BEGIN
    INSERT INTO mission_search_docs(
        doc_key, mission_id, locator, role, sequence, event_id, timestamp, title_text, body_text
    )
    VALUES (
        new.id || ':title',
        new.id,
        'title',
        'title',
        NULL,
        NULL,
        new.updated_at,
        TRIM(COALESCE(new.title, '') || ' ' || new.id),
        TRIM(
            COALESCE(new.short_description, '') || ' ' ||
            COALESCE(new.goal_objective, '') || ' ' ||
            COALESCE(new.project, '') || ' ' ||
            COALESCE(new.track, '')
        )
    )
    ON CONFLICT(doc_key) DO UPDATE SET
        timestamp = excluded.timestamp,
        title_text = excluded.title_text,
        body_text = excluded.body_text
    WHERE mission_search_docs.title_text <> excluded.title_text
       OR mission_search_docs.body_text <> excluded.body_text;
END;

CREATE TABLE IF NOT EXISTS mission_search_state (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    schema_version INTEGER NOT NULL,
    cursor_mission_id TEXT,
    backfill_complete INTEGER NOT NULL DEFAULT 0,
    indexed_missions INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);
"#;

#[derive(Debug, Clone)]
struct DesiredDoc {
    doc_key: String,
    locator: String,
    role: String,
    sequence: Option<i64>,
    event_id: Option<String>,
    timestamp: String,
    title_text: String,
    body_text: String,
}

#[derive(Debug, Clone)]
struct CompiledSearchQuery {
    fts_expr: String,
    highlight_terms: Vec<String>,
    exact_phrases: Vec<String>,
    raw_lower: String,
}

/// Initialize the FTS5 search schema and watermark without rebuilding or
/// scanning existing tables during startup.
pub(super) fn ensure_schema(conn: &Connection) -> Result<bool, String> {
    // Fix any older trigger revision cleanly before installing current triggers.
    conn.execute_batch("DROP TRIGGER IF EXISTS trg_mission_search_docs_au;")
        .map_err(|e| format!("Failed to refresh search trigger: {e}"))?;
    conn.execute_batch(SEARCH_SCHEMA)
        .map_err(|e| format!("Failed to initialize conversation search schema: {e}"))?;
    conn.execute_batch(
        "INSERT INTO mission_search_fts(mission_search_fts, rank) VALUES('rank', 'bm25(8.0, 1.0)');",
    )
    .map_err(|e| format!("Failed to configure FTS5 rank weights: {e}"))?;

    let state: Option<(u32, bool)> = conn
        .query_row(
            "SELECT schema_version, backfill_complete != 0 FROM mission_search_state WHERE singleton = 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|e| format!("Failed to read search state: {e}"))?;

    let now = now_string();
    match state {
        Some((ver, complete)) if ver == SEARCH_SCHEMA_VERSION => Ok(!complete),
        Some(_) => {
            // Schema version bumped: reset watermark and clear docs in fast DDL/DML;
            // bounded background batches rebuild from authoritative tables.
            conn.execute_batch(
                "DELETE FROM mission_search_docs;
                 INSERT INTO mission_search_fts(mission_search_fts) VALUES('rebuild');",
            )
            .map_err(|e| format!("Failed to reset search projection on version change: {e}"))?;
            let has_missions: bool = conn
                .query_row("SELECT EXISTS(SELECT 1 FROM missions LIMIT 1)", [], |r| {
                    r.get(0)
                })
                .map_err(|e| e.to_string())?;
            conn.execute(
                "INSERT INTO mission_search_state(singleton, schema_version, cursor_mission_id, backfill_complete, indexed_missions, updated_at)
                 VALUES (1, ?1, NULL, ?2, 0, ?3)
                 ON CONFLICT(singleton) DO UPDATE SET
                     schema_version = excluded.schema_version,
                     cursor_mission_id = NULL,
                     backfill_complete = excluded.backfill_complete,
                     indexed_missions = 0,
                     updated_at = excluded.updated_at",
                params![SEARCH_SCHEMA_VERSION, i64::from(!has_missions), now],
            )
            .map_err(|e| format!("Failed to update search state: {e}"))?;
            Ok(has_missions)
        }
        None => {
            let has_missions: bool = conn
                .query_row("SELECT EXISTS(SELECT 1 FROM missions LIMIT 1)", [], |r| {
                    r.get(0)
                })
                .map_err(|e| e.to_string())?;
            conn.execute(
                "INSERT INTO mission_search_state(singleton, schema_version, cursor_mission_id, backfill_complete, indexed_missions, updated_at)
                 VALUES (1, ?1, NULL, ?2, 0, ?3)",
                params![SEARCH_SCHEMA_VERSION, i64::from(!has_missions), now],
            )
            .map_err(|e| format!("Failed to initialize search state: {e}"))?;
            Ok(has_missions)
        }
    }
}

/// Spawn a non-blocking, Weak-referenced background task that backfills
/// unindexed existing conversations in bounded batches. Dropping the store
/// drops the strong `Arc<Mutex<Connection>>`, causing the worker to exit cleanly.
pub(super) fn spawn_background_backfill(conn: Weak<Mutex<Connection>>, content_dir: PathBuf) {
    let Ok(handle) = tokio::runtime::Handle::try_current() else {
        return;
    };
    handle.spawn(async move {
        // Yield briefly after store open so startup traffic lands first.
        tokio::time::sleep(std::time::Duration::from_millis(15)).await;
        loop {
            let Some(strong) = conn.upgrade() else {
                break;
            };
            let dir = content_dir.clone();
            let batch_res = tokio::task::spawn_blocking(move || {
                let mut guard = strong.blocking_lock();
                backfill_batch_sync(&mut guard, &dir, BACKFILL_BATCH_SIZE)
            })
            .await;
            match batch_res {
                Ok(Ok(true)) => {
                    tokio::time::sleep(std::time::Duration::from_millis(8)).await;
                }
                Ok(Ok(false)) => break,
                Ok(Err(err)) => {
                    tracing::warn!("Conversation search background backfill paused: {err}");
                    break;
                }
                Err(_) => break,
            }
        }
    });
}

/// Process up to `batch_size` missions from the persisted cursor. Returns
/// `Ok(true)` while more batches remain, `Ok(false)` once backfill is complete.
pub(super) fn backfill_batch_sync(
    conn: &mut Connection,
    content_dir: &Path,
    batch_size: usize,
) -> Result<bool, String> {
    let batch_size = batch_size.clamp(1, 500);
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    let state: Option<(Option<String>, bool, i64)> = tx
        .query_row(
            "SELECT cursor_mission_id, backfill_complete != 0, indexed_missions
             FROM mission_search_state WHERE singleton = 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(|e| e.to_string())?;

    let (cursor, complete, indexed_so_far) = match state {
        Some((_, true, _)) => return Ok(false),
        Some(tuple) => tuple,
        None => (None, false, 0),
    };
    let _ = complete;

    let mission_ids: Vec<String> = if let Some(ref after) = cursor {
        let mut stmt = tx
            .prepare("SELECT id FROM missions WHERE id > ?1 ORDER BY id ASC LIMIT ?2")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![after, batch_size as i64], |r| r.get(0))
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<String>, _>>()
            .map_err(|e| e.to_string())?;
        rows
    } else {
        let mut stmt = tx
            .prepare("SELECT id FROM missions ORDER BY id ASC LIMIT ?1")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![batch_size as i64], |r| r.get(0))
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<String>, _>>()
            .map_err(|e| e.to_string())?;
        rows
    };

    let now = now_string();
    if mission_ids.is_empty() {
        tx.execute(
            "UPDATE mission_search_state
             SET backfill_complete = 1, updated_at = ?1
             WHERE singleton = 1",
            params![now],
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
        return Ok(false);
    }

    for mid in &mission_ids {
        reconcile_mission_docs(&tx, content_dir, mid)?;
    }

    let next_cursor = mission_ids.last().cloned();
    let new_indexed = indexed_so_far + mission_ids.len() as i64;
    let has_more: bool = if let Some(ref c) = next_cursor {
        tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM missions WHERE id > ?1 LIMIT 1)",
            params![c],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?
    } else {
        false
    };

    tx.execute(
        "UPDATE mission_search_state
         SET cursor_mission_id = ?1,
             backfill_complete = ?2,
             indexed_missions = ?3,
             updated_at = ?4
         WHERE singleton = 1",
        params![next_cursor, i64::from(!has_more), new_indexed, now],
    )
    .map_err(|e| e.to_string())?;
    if !has_more {
        tx.execute_batch("INSERT INTO mission_search_fts(mission_search_fts) VALUES('optimize');")
            .map_err(|e| e.to_string())?;
    }

    tx.commit().map_err(|e| e.to_string())?;
    Ok(has_more)
}

fn upsert_search_doc(conn: &Connection, mission_id: &str, doc: &DesiredDoc) -> Result<(), String> {
    conn.execute(
        "INSERT INTO mission_search_docs(
            doc_key, mission_id, locator, role, sequence, event_id, timestamp, title_text, body_text
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        ON CONFLICT(doc_key) DO UPDATE SET
            locator = excluded.locator,
            role = excluded.role,
            sequence = excluded.sequence,
            event_id = excluded.event_id,
            timestamp = excluded.timestamp,
            title_text = excluded.title_text,
            body_text = excluded.body_text
        WHERE mission_search_docs.title_text <> excluded.title_text
           OR mission_search_docs.body_text <> excluded.body_text
           OR mission_search_docs.locator <> excluded.locator
           OR COALESCE(mission_search_docs.sequence, -1) <> COALESCE(excluded.sequence, -1)",
        params![
            doc.doc_key,
            mission_id,
            doc.locator,
            doc.role,
            doc.sequence,
            doc.event_id,
            doc.timestamp,
            doc.title_text,
            doc.body_text,
        ],
    )
    .map_err(|e| format!("Failed to upsert search doc: {e}"))?;
    Ok(())
}

const RESUME_PROMPT_EXACT: &str = "Your previous turn was interrupted before it finished. Check what is already done, then continue from there. Do not redo finished work.";

pub(crate) fn is_automatic_user_message(content: &str, metadata: &serde_json::Value) -> bool {
    if let Some(source) = metadata.get("source").and_then(|v| v.as_str()) {
        if matches!(
            source,
            "background-task"
                | "scheduler"
                | "idle-worker-watchdog"
                | "transport_auto_resume"
                | "remote-build-terminal"
                | "task-board"
        ) {
            return true;
        }
    }
    if metadata.get("backgroundWake").is_some()
        || metadata.get("resumePrompt").and_then(|v| v.as_bool()) == Some(true)
    {
        return true;
    }
    let trimmed = content.trim();
    if trimmed == RESUME_PROMPT_EXACT {
        return true;
    }
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("[automatic recovery]")
        || lower.starts_with("[automatic resume after a usage limit]")
    {
        return true;
    }
    if trimmed.starts_with("Background task `") && trimmed.ends_with("\n\nContinue from here.") {
        return true;
    }
    false
}

pub(crate) fn is_orchestration_tool_name(tool_name: Option<&str>) -> bool {
    let Some(raw) = tool_name.map(str::trim).filter(|s| !s.is_empty()) else {
        return false;
    };
    let lower = raw.to_ascii_lowercase();
    let mut n = lower.strip_prefix("functions.").unwrap_or(&lower);
    if n.starts_with("mcp__") {
        if let Some(idx) = n.rfind("__") {
            if idx > 3 {
                n = &n[idx + 2..];
            }
        }
    }
    if let Some(idx) = n.rfind('.') {
        n = &n[idx + 1..];
    }
    if let Some(idx) = n.rfind(':') {
        n = &n[idx + 1..];
    }
    n = n.strip_prefix("mcp_").unwrap_or(n);
    for root in ["sandboxed", "orchestrator", "paloma"] {
        if let Some(mut rest) = n.strip_prefix(root) {
            while let Some(next) = rest
                .strip_prefix("_sh")
                .or_else(|| rest.strip_prefix("-sh"))
                .or_else(|| rest.strip_prefix("_assistant"))
                .or_else(|| rest.strip_prefix("-assistant"))
                .or_else(|| rest.strip_prefix("_orchestrator"))
                .or_else(|| rest.strip_prefix("-orchestrator"))
            {
                rest = next;
            }
            if let Some(stripped) = rest.strip_prefix('_').or_else(|| rest.strip_prefix('-')) {
                n = stripped;
                break;
            }
        }
    }
    matches!(
        n,
        "start_mission"
            | "create_mission"
            | "spawn_worker"
            | "spawn_managed_machine"
            | "destroy_managed_machine"
    )
}

pub(crate) fn is_generated_remote_job_status_text(
    content: &str,
    metadata: &serde_json::Value,
) -> bool {
    if metadata.get("kind").and_then(|v| v.as_str()) == Some("remote_job_status")
        || metadata.get("remote_job_status").and_then(|v| v.as_bool()) == Some(true)
    {
        return true;
    }
    let trimmed = content.trim();
    if let Some(rest) = trimmed.strip_prefix("Remote job ") {
        if rest.len() > 38
            && rest.contains(" on node '")
            && (rest.ends_with(" is now queued")
                || rest.ends_with(" is now running")
                || rest.ends_with(" is now finished"))
        {
            return true;
        }
    }
    if let Some(rest) = trimmed.strip_prefix("Dispatched job ") {
        if rest.len() > 38 && rest.contains(" to remote node '") {
            return true;
        }
    }
    false
}

/// Extract compact, secret-safe target descriptors from a `tool_call` payload.
/// Raw command lines, file contents, and tool outputs (`tool_result`) are
/// deliberately excluded so logs/secrets never enter the search index.
pub(crate) fn extract_safe_tool_target(tool_name: Option<&str>, raw_args: &str) -> Option<String> {
    let name = tool_name?.trim();
    if name.is_empty() {
        return None;
    }
    let lower_name = name.to_ascii_lowercase();
    if lower_name.contains("secret")
        || lower_name.contains("token")
        || lower_name.contains("credential")
        || lower_name.contains("password")
        || lower_name.contains("auth")
    {
        return None;
    }
    let parsed: serde_json::Value = serde_json::from_str(raw_args).ok()?;
    let obj = parsed.as_object()?;
    const SAFE_TARGET_KEYS: &[&str] = &[
        "path",
        "file_path",
        "filePath",
        "Path",
        "pattern",
        "Pattern",
        "query",
        "Query",
        "url",
        "symbol",
        "workdir",
        "cwd",
        "description",
        "toolSummary",
        "subagent_type",
    ];
    let mut parts = Vec::new();
    for key in SAFE_TARGET_KEYS {
        if let Some(val) = obj.get(*key).and_then(|v| v.as_str()) {
            let clean = val.trim();
            if !clean.is_empty() && clean.len() <= 240 {
                parts.push(clean.to_string());
            }
        }
    }
    if parts.is_empty() {
        Some(name.to_string())
    } else {
        Some(format!("{name} {}", parts.join(" ")))
    }
}

/// Incremental hook invoked inside `log_event_sync` once an event is persisted.
/// Ignores streaming deltas, reasoning traces, and raw tool outputs (`O(0)` SQL
/// work on hot streaming paths) and performs `O(1)` indexed updates on canonical
/// user/assistant/tool boundaries.
#[allow(clippy::too_many_arguments)]
pub(crate) fn on_event_persisted(
    conn: &Connection,
    mission_id: Uuid,
    sequence: i64,
    event_type: &str,
    timestamp: &str,
    event_id: Option<&str>,
    tool_name: Option<&str>,
    resolved_content: &str,
    metadata: &serde_json::Value,
) -> Result<(), String> {
    match event_type {
        "user_message" | "assistant_message_canonical" | "assistant_message" | "tool_call" => {}
        _ => return Ok(()),
    }
    // If the search schema hasn't been installed on this connection (e.g. raw
    // admission-recovery handle), skip quietly.
    let mid = mission_id.to_string();
    let has_table: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='mission_search_docs')",
            [],
            |r| r.get(0),
        )
        .unwrap_or(false);
    if !has_table {
        return Ok(());
    }

    match event_type {
        "user_message" => {
            if metadata.get("queued").and_then(|v| v.as_bool()) == Some(true)
                || is_automatic_user_message(resolved_content, metadata)
            {
                return Ok(());
            }
            let body = resolved_content.trim();
            if body.is_empty() {
                return Ok(());
            }
            let eid = event_id.map(str::trim).filter(|s| !s.is_empty());
            let locator = match eid {
                Some(id) => format!("msg:id:{id}"),
                None => format!("msg:seq:{sequence}"),
            };
            upsert_search_doc(
                conn,
                &mid,
                &DesiredDoc {
                    doc_key: format!("{mid}:{locator}"),
                    locator,
                    role: "user".to_string(),
                    sequence: Some(sequence),
                    event_id: eid.map(ToString::to_string),
                    timestamp: timestamp.to_string(),
                    title_text: String::new(),
                    body_text: body.to_string(),
                },
            )
        }
        "assistant_message_canonical" => {
            let body = resolved_content.trim();
            if body.is_empty() || is_generated_remote_job_status_text(body, metadata) {
                return Ok(());
            }
            let bubble_id = metadata
                .get("bubble_id")
                .and_then(|v| v.as_str())
                .or(event_id)
                .unwrap_or("text_delta_latest");
            if bubble_id.starts_with("antigravity:") || bubble_id.starts_with("opencode:") {
                let locator = format!("msg:bubble:{bubble_id}");
                upsert_search_doc(
                    conn,
                    &mid,
                    &DesiredDoc {
                        doc_key: format!("{mid}:{locator}"),
                        locator,
                        role: "assistant".to_string(),
                        sequence: Some(sequence),
                        event_id: Some(bubble_id.to_string()),
                        timestamp: timestamp.to_string(),
                        title_text: String::new(),
                        body_text: body.to_string(),
                    },
                )
            } else {
                let turn_anchor = current_turn_anchor_seq(conn, &mid, sequence)?;
                let locator = format!("msg:seq:{sequence}");
                upsert_search_doc(
                    conn,
                    &mid,
                    &DesiredDoc {
                        doc_key: format!("{mid}:turn_reply:{turn_anchor}"),
                        locator,
                        role: "assistant".to_string(),
                        sequence: Some(sequence),
                        event_id: event_id.map(ToString::to_string),
                        timestamp: timestamp.to_string(),
                        title_text: String::new(),
                        body_text: body.to_string(),
                    },
                )
            }
        }
        "assistant_message" => {
            let body = resolved_content.trim();
            if body.is_empty() || is_generated_remote_job_status_text(body, metadata) {
                return Ok(());
            }
            let eid = event_id.map(str::trim).filter(|s| !s.is_empty());
            // Cloud turns index both prompt and answer via `on_cloud_execution_saved`
            // so `mission_events` receipt copies never create duplicate hits.
            if let Some(id) = eid {
                let cloud_doc_exists: bool = conn
                    .query_row(
                        "SELECT EXISTS(SELECT 1 FROM mission_search_docs WHERE doc_key = ?1)",
                        params![format!("{mid}:cloud:{id}:assistant")],
                        |r| r.get(0),
                    )
                    .unwrap_or(false);
                if cloud_doc_exists {
                    return Ok(());
                }
            }
            let turn_anchor = current_turn_anchor_seq(conn, &mid, sequence)?;
            if is_turn_native_receipt(conn, &mid, turn_anchor, body)? {
                return Ok(());
            }
            // Supersede any provisional `turn_reply` canonical doc for this turn.
            conn.execute(
                "DELETE FROM mission_search_docs WHERE doc_key = ?1",
                params![format!("{mid}:turn_reply:{turn_anchor}")],
            )
            .map_err(|e| e.to_string())?;

            let locator = match eid {
                Some(id) => format!("msg:id:{id}"),
                None => format!("msg:seq:{sequence}"),
            };
            upsert_search_doc(
                conn,
                &mid,
                &DesiredDoc {
                    doc_key: format!("{mid}:{locator}"),
                    locator,
                    role: "assistant".to_string(),
                    sequence: Some(sequence),
                    event_id: eid.map(ToString::to_string),
                    timestamp: timestamp.to_string(),
                    title_text: String::new(),
                    body_text: body.to_string(),
                },
            )
        }
        "tool_call" => {
            let turn_anchor = current_turn_anchor_seq(conn, &mid, sequence)?;
            // Assistant text emitted before a work tool call in the same turn is
            // intermediate narration folded into WorkFold, not a final agent message.
            if !is_orchestration_tool_name(tool_name) {
                conn.execute(
                    "DELETE FROM mission_search_docs
                     WHERE mission_id = ?1
                       AND role = 'assistant'
                       AND sequence >= ?2
                       AND sequence < ?3",
                    params![&mid, turn_anchor, sequence],
                )
                .map_err(|e| e.to_string())?;
            }
            let Some(summary) = extract_safe_tool_target(tool_name, resolved_content) else {
                return Ok(());
            };
            let locator = format!("turn:tools:{turn_anchor}");
            let doc_key = format!("{mid}:{locator}");
            let existing: Option<(Option<i64>, String)> = conn
                .query_row(
                    "SELECT sequence, body_text FROM mission_search_docs WHERE doc_key = ?1",
                    params![&doc_key],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()
                .map_err(|e| e.to_string())?;
            let (first_seq, merged_body) = match existing {
                Some((seq_opt, mut body)) => {
                    if !body.lines().any(|line| line == summary)
                        && body.len() + summary.len() < MAX_TOOL_SUMMARY_BYTES
                    {
                        if !body.is_empty() {
                            body.push('\n');
                        }
                        body.push_str(&summary);
                    }
                    (seq_opt.or(Some(sequence)), body)
                }
                None => (Some(sequence), summary),
            };
            upsert_search_doc(
                conn,
                &mid,
                &DesiredDoc {
                    doc_key,
                    locator,
                    role: "tool".to_string(),
                    sequence: first_seq,
                    event_id: None,
                    timestamp: timestamp.to_string(),
                    title_text: String::new(),
                    body_text: merged_body,
                },
            )
        }
        _ => Ok(()),
    }
}

fn current_turn_anchor_seq(conn: &Connection, mid: &str, sequence: i64) -> Result<i64, String> {
    conn.query_row(
        "SELECT COALESCE(MAX(sequence), 0)
         FROM mission_events
         WHERE mission_id = ?1
           AND event_type = 'user_message'
           AND sequence <= ?2",
        params![mid, sequence],
        |r| r.get(0),
    )
    .map_err(|e| e.to_string())
}

fn is_turn_native_receipt(
    conn: &Connection,
    mid: &str,
    turn_anchor_seq: i64,
    trimmed_reply: &str,
) -> Result<bool, String> {
    let mut stmt = conn
        .prepare(
            "SELECT content, content_file, event_id, metadata
             FROM mission_events
             WHERE mission_id = ?1
               AND sequence >= ?2
               AND event_type = 'assistant_message_canonical'
             ORDER BY sequence ASC",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![mid, turn_anchor_seq], |r| {
            Ok((
                r.get::<_, Option<String>>(0)?,
                r.get::<_, Option<String>>(1)?,
                r.get::<_, Option<String>>(2)?,
                r.get::<_, Option<String>>(3)?,
            ))
        })
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    let mut bubbles = Vec::new();
    for (inline, file, event_id, meta_raw) in rows {
        let metadata: serde_json::Value = meta_raw
            .as_deref()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or(serde_json::Value::Null);
        let bubble_id = metadata
            .get("bubble_id")
            .and_then(|v| v.as_str())
            .or(event_id.as_deref())
            .unwrap_or("text_delta_latest");
        if bubble_id.starts_with("antigravity:") || bubble_id.starts_with("opencode:") {
            let text = SqliteMissionStore::load_content(inline.as_deref(), file.as_deref());
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                bubbles.push(trimmed.to_string());
            }
        }
    }
    if bubbles.is_empty() {
        return Ok(false);
    }
    if bubbles.last().map(|s| s.trim()) == Some(trimmed_reply) {
        return Ok(true);
    }
    let joined = bubbles.join("");
    Ok(joined.trim() == trimmed_reply || bubbles.join("\n\n").trim() == trimmed_reply)
}

/// Incremental hook invoked inside `sqlite_cloud::save` transaction so cloud
/// prompts and answers are indexed from their canonical `cloud_executions` row.
pub(crate) fn on_cloud_execution_saved(
    conn: &Connection,
    execution: &CloudExecution,
    updated_at: &str,
) -> Result<(), String> {
    let has_table: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='mission_search_docs')",
            [],
            |r| r.get(0),
        )
        .unwrap_or(false);
    if !has_table {
        return Ok(());
    }
    let mid = execution.mission_id.to_string();
    for turn in &execution.turns {
        let prompt = turn.prompt.trim();
        if !prompt.is_empty() {
            let locator = format!("cloud:{}:prompt", turn.key);
            upsert_search_doc(
                conn,
                &mid,
                &DesiredDoc {
                    doc_key: format!("{mid}:cloud:{}:user", turn.key),
                    locator,
                    role: "user".to_string(),
                    sequence: None,
                    event_id: Some(turn.key.clone()),
                    timestamp: updated_at.to_string(),
                    title_text: String::new(),
                    body_text: prompt.to_string(),
                },
            )?;
        }
        if let Some(answer) = turn
            .result
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            // Remove any duplicate `msg:id:<turn.key>` row if one was created first.
            conn.execute(
                "DELETE FROM mission_search_docs WHERE doc_key = ?1",
                params![format!("{mid}:msg:id:{}", turn.key)],
            )
            .map_err(|e| e.to_string())?;
            let locator = format!("cloud:{}:answer", turn.key);
            upsert_search_doc(
                conn,
                &mid,
                &DesiredDoc {
                    doc_key: format!("{mid}:cloud:{}:assistant", turn.key),
                    locator,
                    role: "assistant".to_string(),
                    sequence: None,
                    event_id: Some(turn.key.clone()),
                    timestamp: updated_at.to_string(),
                    title_text: String::new(),
                    body_text: answer.to_string(),
                },
            )?;
        }
    }
    Ok(())
}

type MissionSearchMetaRow = (
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    String,
);

/// Reconcile the entire search document set for one mission from authoritative
/// SQLite rows (`missions`, `cloud_executions`, `mission_events` + spilled files).
pub(crate) fn reconcile_mission_docs(
    conn: &Connection,
    content_dir: &Path,
    mission_id: &str,
) -> Result<(), String> {
    let meta_row: Option<MissionSearchMetaRow> = conn
        .query_row(
            "SELECT title, short_description, goal_objective, project, track, updated_at
             FROM missions WHERE id = ?1",
            params![mission_id],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                ))
            },
        )
        .optional()
        .map_err(|e| e.to_string())?;

    let Some((title, short_desc, goal_obj, project, track, updated_at)) = meta_row else {
        conn.execute(
            "DELETE FROM mission_search_docs WHERE mission_id = ?1",
            params![mission_id],
        )
        .map_err(|e| e.to_string())?;
        return Ok(());
    };

    let mut desired: Vec<DesiredDoc> = Vec::new();
    let title_text = format!("{} {}", title.as_deref().unwrap_or(""), mission_id)
        .trim()
        .to_string();
    let meta_body = [
        short_desc.as_deref().unwrap_or(""),
        goal_obj.as_deref().unwrap_or(""),
        project.as_deref().unwrap_or(""),
        track.as_deref().unwrap_or(""),
    ]
    .into_iter()
    .filter(|s| !s.trim().is_empty())
    .collect::<Vec<_>>()
    .join(" ");

    desired.push(DesiredDoc {
        doc_key: format!("{mission_id}:title"),
        locator: "title".to_string(),
        role: "title".to_string(),
        sequence: None,
        event_id: None,
        timestamp: updated_at.clone(),
        title_text,
        body_text: meta_body,
    });

    let mut cloud_turn_keys = HashSet::new();
    let cloud_json: Option<String> = conn
        .query_row(
            "SELECT data FROM cloud_executions WHERE mission_id = ?1",
            params![mission_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    if let Some(raw_cloud) = cloud_json {
        if let Ok(exec) = serde_json::from_str::<CloudExecution>(&raw_cloud) {
            for turn in exec.turns {
                cloud_turn_keys.insert(turn.key.clone());
                let prompt = turn.prompt.trim();
                if !prompt.is_empty() {
                    desired.push(DesiredDoc {
                        doc_key: format!("{mission_id}:cloud:{}:user", turn.key),
                        locator: format!("cloud:{}:prompt", turn.key),
                        role: "user".to_string(),
                        sequence: None,
                        event_id: Some(turn.key.clone()),
                        timestamp: updated_at.clone(),
                        title_text: String::new(),
                        body_text: prompt.to_string(),
                    });
                }
                if let Some(ans) = turn
                    .result
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                {
                    desired.push(DesiredDoc {
                        doc_key: format!("{mission_id}:cloud:{}:assistant", turn.key),
                        locator: format!("cloud:{}:answer", turn.key),
                        role: "assistant".to_string(),
                        sequence: None,
                        event_id: Some(turn.key),
                        timestamp: updated_at.clone(),
                        title_text: String::new(),
                        body_text: ans.to_string(),
                    });
                }
            }
        }
    }

    let _ = content_dir;
    let folded_events = load_and_fold_mission_events(conn, mission_id, &cloud_turn_keys, None)?;
    desired.extend(folded_events);

    let mut existing_stmt = conn
        .prepare("SELECT doc_key FROM mission_search_docs WHERE mission_id = ?1")
        .map_err(|e| e.to_string())?;
    let existing_keys: HashSet<String> = existing_stmt
        .query_map(params![mission_id], |r| r.get(0))
        .map_err(|e| e.to_string())?
        .collect::<Result<HashSet<String>, _>>()
        .map_err(|e| e.to_string())?;
    drop(existing_stmt);

    let desired_keys: HashSet<&str> = desired.iter().map(|d| d.doc_key.as_str()).collect();
    for old_key in existing_keys {
        if !desired_keys.contains(old_key.as_str()) {
            conn.execute(
                "DELETE FROM mission_search_docs WHERE doc_key = ?1",
                params![old_key],
            )
            .map_err(|e| e.to_string())?;
        }
    }
    for doc in &desired {
        upsert_search_doc(conn, mission_id, doc)?;
    }
    Ok(())
}

fn load_and_fold_mission_events(
    conn: &Connection,
    mission_id: &str,
    cloud_turn_keys: &HashSet<String>,
    seq_bounds: Option<(i64, i64)>,
) -> Result<Vec<DesiredDoc>, String> {
    let sql = if seq_bounds.is_some() {
        "SELECT sequence, event_type, timestamp, event_id, tool_name, content, content_file, metadata
         FROM mission_events
         WHERE mission_id = ?1
           AND sequence BETWEEN ?2 AND ?3
           AND event_type IN ('user_message', 'assistant_message_canonical', 'assistant_message', 'tool_call')
         ORDER BY sequence ASC"
    } else {
        "SELECT sequence, event_type, timestamp, event_id, tool_name, content, content_file, metadata
         FROM mission_events
         WHERE mission_id = ?1
           AND event_type IN ('user_message', 'assistant_message_canonical', 'assistant_message', 'tool_call')
         ORDER BY sequence ASC"
    };

    let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
    type RawRow = (
        i64,
        String,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
    );
    let parse_row = |r: &rusqlite::Row<'_>| -> rusqlite::Result<RawRow> {
        Ok((
            r.get(0)?,
            r.get(1)?,
            r.get(2)?,
            r.get(3)?,
            r.get(4)?,
            r.get(5)?,
            r.get(6)?,
            r.get(7)?,
        ))
    };
    let rows: Vec<RawRow> = if let Some((lo, hi)) = seq_bounds {
        stmt.query_map(params![mission_id, lo, hi], parse_row)
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?
    } else {
        stmt.query_map(params![mission_id], parse_row)
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?
    };

    let mut docs = Vec::new();
    let mut turn_anchor_seq: i64 = 0;
    let mut turn_native_bubbles: Vec<String> = Vec::new();
    let mut turn_pending_assistant: Vec<DesiredDoc> = Vec::new();
    let mut turn_pending_canonical: Option<DesiredDoc> = None;
    let mut turn_tools: Vec<String> = Vec::new();
    let mut turn_tools_first_seq: Option<i64> = None;
    let mut turn_tools_ts = String::new();

    let flush_turn = |docs: &mut Vec<DesiredDoc>,
                      anchor_seq: i64,
                      pending_assistant: &mut Vec<DesiredDoc>,
                      pending_canonical: &mut Option<DesiredDoc>,
                      tools: &mut Vec<String>,
                      tools_first_seq: &mut Option<i64>,
                      tools_ts: &mut String,
                      native_bubbles: &mut Vec<String>| {
        docs.append(pending_assistant);
        if let Some(canon) = pending_canonical.take() {
            docs.push(canon);
        }
        if !tools.is_empty() {
            let locator = format!("turn:tools:{anchor_seq}");
            docs.push(DesiredDoc {
                doc_key: format!("{mission_id}:{locator}"),
                locator,
                role: "tool".to_string(),
                sequence: *tools_first_seq,
                event_id: None,
                timestamp: std::mem::take(tools_ts),
                title_text: String::new(),
                body_text: tools.join("\n"),
            });
            tools.clear();
            *tools_first_seq = None;
        }
        native_bubbles.clear();
    };

    for (seq, event_type, ts, event_id, tool_name, content_inline, content_file, metadata_str) in
        rows
    {
        let content =
            SqliteMissionStore::load_content(content_inline.as_deref(), content_file.as_deref());
        let metadata: serde_json::Value = metadata_str
            .as_deref()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or(serde_json::Value::Null);

        match event_type.as_str() {
            "user_message" => {
                if metadata.get("queued").and_then(|v| v.as_bool()) == Some(true) {
                    continue;
                }
                flush_turn(
                    &mut docs,
                    turn_anchor_seq,
                    &mut turn_pending_assistant,
                    &mut turn_pending_canonical,
                    &mut turn_tools,
                    &mut turn_tools_first_seq,
                    &mut turn_tools_ts,
                    &mut turn_native_bubbles,
                );
                turn_anchor_seq = seq;
                if is_automatic_user_message(&content, &metadata) {
                    continue;
                }
                let body = content.trim();
                if body.is_empty() {
                    continue;
                }
                let eid = event_id.as_deref().map(str::trim).filter(|s| !s.is_empty());
                let locator = match eid {
                    Some(id) => format!("msg:id:{id}"),
                    None => format!("msg:seq:{seq}"),
                };
                docs.push(DesiredDoc {
                    doc_key: format!("{mission_id}:{locator}"),
                    locator,
                    role: "user".to_string(),
                    sequence: Some(seq),
                    event_id: eid.map(ToString::to_string),
                    timestamp: ts,
                    title_text: String::new(),
                    body_text: body.to_string(),
                });
            }
            "assistant_message_canonical" => {
                let body = content.trim();
                if body.is_empty() || is_generated_remote_job_status_text(body, &metadata) {
                    continue;
                }
                let bubble_id = metadata
                    .get("bubble_id")
                    .and_then(|v| v.as_str())
                    .or(event_id.as_deref())
                    .unwrap_or("text_delta_latest");
                if bubble_id.starts_with("antigravity:") || bubble_id.starts_with("opencode:") {
                    turn_native_bubbles.push(body.to_string());
                    let locator = format!("msg:bubble:{bubble_id}");
                    let doc_key = format!("{mission_id}:{locator}");
                    let next_doc = DesiredDoc {
                        doc_key: doc_key.clone(),
                        locator,
                        role: "assistant".to_string(),
                        sequence: Some(seq),
                        event_id: Some(bubble_id.to_string()),
                        timestamp: ts,
                        title_text: String::new(),
                        body_text: body.to_string(),
                    };
                    if let Some(existing) = turn_pending_assistant
                        .iter_mut()
                        .find(|d| d.doc_key == doc_key)
                    {
                        *existing = next_doc;
                    } else {
                        turn_pending_assistant.push(next_doc);
                    }
                } else {
                    turn_pending_canonical = Some(DesiredDoc {
                        doc_key: format!("{mission_id}:turn_reply:{turn_anchor_seq}"),
                        locator: format!("msg:seq:{seq}"),
                        role: "assistant".to_string(),
                        sequence: Some(seq),
                        event_id,
                        timestamp: ts,
                        title_text: String::new(),
                        body_text: body.to_string(),
                    });
                }
            }
            "assistant_message" => {
                let body = content.trim();
                if body.is_empty() || is_generated_remote_job_status_text(body, &metadata) {
                    continue;
                }
                let eid = event_id.as_deref().map(str::trim).filter(|s| !s.is_empty());
                if let Some(id) = eid {
                    if cloud_turn_keys.contains(id) {
                        continue;
                    }
                }
                if !turn_native_bubbles.is_empty() {
                    let is_receipt = turn_native_bubbles.last().map(|s| s.as_str()) == Some(body)
                        || turn_native_bubbles.join("").trim() == body
                        || turn_native_bubbles.join("\n\n").trim() == body;
                    if is_receipt {
                        continue;
                    }
                }
                turn_pending_canonical = None;
                let locator = match eid {
                    Some(id) => format!("msg:id:{id}"),
                    None => format!("msg:seq:{seq}"),
                };
                turn_pending_assistant.push(DesiredDoc {
                    doc_key: format!("{mission_id}:{locator}"),
                    locator,
                    role: "assistant".to_string(),
                    sequence: Some(seq),
                    event_id: eid.map(ToString::to_string),
                    timestamp: ts,
                    title_text: String::new(),
                    body_text: body.to_string(),
                });
            }
            "tool_call" => {
                if !is_orchestration_tool_name(tool_name.as_deref()) {
                    turn_pending_assistant.clear();
                    turn_pending_canonical = None;
                }
                if let Some(summary) = extract_safe_tool_target(tool_name.as_deref(), &content) {
                    let current_len: usize = turn_tools.iter().map(|s| s.len() + 1).sum();
                    if !turn_tools.iter().any(|existing| existing == &summary)
                        && current_len + summary.len() <= MAX_TOOL_SUMMARY_BYTES
                    {
                        if turn_tools_first_seq.is_none() {
                            turn_tools_first_seq = Some(seq);
                        }
                        turn_tools_ts = ts;
                        turn_tools.push(summary);
                    }
                }
            }
            _ => {}
        }
    }

    flush_turn(
        &mut docs,
        turn_anchor_seq,
        &mut turn_pending_assistant,
        &mut turn_pending_canonical,
        &mut turn_tools,
        &mut turn_tools_first_seq,
        &mut turn_tools_ts,
        &mut turn_native_bubbles,
    );

    Ok(docs)
}

/// Compile arbitrary user input into a safe SQLite FTS5 query expression with
/// zero possibility of FTS syntax injection (`NEAR`, unbalanced `"`, `*`, `:`,
/// boolean keywords, parentheses, or punctuation).
fn compile_fts_query(raw: &str) -> Option<CompiledSearchQuery> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    let mut exact_phrases: Vec<String> = Vec::new();
    let mut highlight_terms: Vec<String> = Vec::new();
    let mut fts_clauses: Vec<String> = Vec::new();

    // Parse balanced `"..."` segments as exact phrases; unbalanced quotes treat
    // the remainder as ordinary tokens rather than throwing a syntax error.
    let mut rest = trimmed;
    let mut loose_segments: Vec<&str> = Vec::new();
    while let Some(open_idx) = rest.find('"') {
        let before = &rest[..open_idx];
        if !before.trim().is_empty() {
            loose_segments.push(before);
        }
        let after_open = &rest[open_idx + 1..];
        if let Some(close_rel) = after_open.find('"') {
            let phrase_raw = &after_open[..close_rel];
            let tokens = tokenize_unicode61(phrase_raw);
            if !tokens.is_empty() {
                let joined = tokens.join(" ");
                exact_phrases.push(joined.to_lowercase());
                highlight_terms.push(phrase_raw.trim().to_string());
                let escaped = tokens
                    .iter()
                    .map(|t| t.replace('"', "\"\""))
                    .collect::<Vec<_>>()
                    .join(" ");
                fts_clauses.push(format!("\"{escaped}\""));
            }
            rest = &after_open[close_rel + 1..];
        } else {
            // Unclosed quote: treat remaining text as ordinary tokens.
            loose_segments.push(after_open);
            rest = "";
            break;
        }
    }
    if !rest.trim().is_empty() {
        loose_segments.push(rest);
    }

    let trailing_prefix_eligible = !trimmed.ends_with('"');
    let loose_words: Vec<&str> = loose_segments
        .iter()
        .flat_map(|seg| seg.split_whitespace())
        .collect();
    for (w_idx, word) in loose_words.iter().copied().enumerate() {
        let is_last_word = trailing_prefix_eligible && (w_idx + 1 == loose_words.len());
        let subtokens = tokenize_unicode61(word);
        if subtokens.is_empty() {
            continue;
        }
        let clean_word = word
            .trim_matches(|c: char| !c.is_alphanumeric() && c != '_' && c != '-')
            .to_string();
        if !clean_word.is_empty() {
            highlight_terms.push(clean_word);
        }
        for (i, tok) in subtokens.iter().enumerate() {
            highlight_terms.push(tok.clone());
            let escaped = tok.replace('"', "\"\"");
            let is_final_subtoken = is_last_word && (i + 1 == subtokens.len());
            if is_final_subtoken && (subtokens.len() == 1 || tok.chars().count() >= 2) {
                fts_clauses.push(format!("\"{escaped}\"*"));
            } else {
                fts_clauses.push(format!("\"{escaped}\""));
            }
        }
    }

    if fts_clauses.is_empty() {
        return None;
    }

    // Deduplicate highlight terms longest-first so full identifiers highlight cleanly.
    highlight_terms.sort_by(|a, b| b.len().cmp(&a.len()).then_with(|| a.cmp(b)));
    highlight_terms.dedup_by(|a, b| a.eq_ignore_ascii_case(b));

    Some(CompiledSearchQuery {
        fts_expr: fts_clauses.join(" AND "),
        highlight_terms,
        exact_phrases,
        raw_lower: trimmed.trim_matches('"').to_lowercase(),
    })
}

fn tokenize_unicode61(input: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for ch in input.chars() {
        if ch.is_alphanumeric() {
            for lc in ch.to_lowercase() {
                cur.push(lc);
            }
        } else if !cur.is_empty() {
            out.push(std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

fn raw_tags_have_btw_marker(raw_tags: Option<&str>) -> bool {
    let Some(raw) = raw_tags else {
        return false;
    };
    raw.contains("\"btw-parent:") || raw.contains("\"btw-subagent\"")
}

fn ancestor_chain_has_btw_marker(
    conn: &Connection,
    start_parent: Option<Uuid>,
    memo: &mut HashMap<Uuid, bool>,
) -> Result<bool, String> {
    let Some(first) = start_parent else {
        return Ok(false);
    };
    if let Some(&cached) = memo.get(&first) {
        return Ok(cached);
    }
    let mut stmt = conn
        .prepare_cached("SELECT parent_mission_id, tags FROM missions WHERE id = ?1")
        .map_err(|e| e.to_string())?;
    let mut visited: Vec<Uuid> = Vec::new();
    let mut seen = HashSet::new();
    let mut cursor = Some(first);
    let mut found = false;
    while let Some(id) = cursor.filter(|id| seen.len() < 16 && seen.insert(*id)) {
        if let Some(&cached) = memo.get(&id) {
            found = cached;
            break;
        }
        visited.push(id);
        let row: Option<(Option<String>, Option<String>)> = stmt
            .query_row(params![id.to_string()], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()
            .map_err(|e| e.to_string())?;
        let Some((next_parent, tags)) = row else {
            break;
        };
        if raw_tags_have_btw_marker(tags.as_deref()) {
            found = true;
            break;
        }
        cursor = next_parent.and_then(|s| Uuid::parse_str(&s).ok());
    }
    for id in visited {
        memo.insert(id, found);
    }
    Ok(found)
}

pub(super) fn read_coverage_sync(conn: &Connection) -> Result<SearchIndexCoverage, String> {
    let total_missions: usize = conn
        .query_row(
            "SELECT COUNT(*) FROM missions m
             WHERE (m.tags IS NULL OR (m.tags NOT LIKE '%\"superseded%' AND m.tags NOT LIKE '%\"btw-parent:%' AND m.tags NOT LIKE '%\"btw-subagent\"%'))
               AND (m.parent_mission_id IS NULL OR NOT EXISTS (
                   SELECT 1 FROM missions p
                   WHERE p.id = m.parent_mission_id
                     AND p.tags IS NOT NULL
                     AND (p.tags LIKE '%\"btw-parent:%' OR p.tags LIKE '%\"btw-subagent\"%')
               ))",
            [],
            |r| r.get::<_, i64>(0),
        )
        .map(|n| n.max(0) as usize)
        .map_err(|e| e.to_string())?;

    let state: Option<(u32, bool, i64)> = conn
        .query_row(
            "SELECT schema_version, backfill_complete != 0, indexed_missions
             FROM mission_search_state WHERE singleton = 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(|e| e.to_string())?;

    match state {
        Some((schema_version, true, _)) => Ok(SearchIndexCoverage {
            schema_version,
            state: SearchIndexState::Ready,
            indexed_missions: total_missions,
            total_missions,
        }),
        Some((schema_version, false, indexed)) => Ok(SearchIndexCoverage {
            schema_version,
            state: if total_missions == 0 {
                SearchIndexState::Ready
            } else {
                SearchIndexState::Indexing
            },
            indexed_missions: (indexed.max(0) as usize).min(total_missions),
            total_missions,
        }),
        None => Ok(SearchIndexCoverage {
            schema_version: SEARCH_SCHEMA_VERSION,
            state: if total_missions == 0 {
                SearchIndexState::Ready
            } else {
                SearchIndexState::Indexing
            },
            indexed_missions: 0,
            total_missions,
        }),
    }
}

fn recency_tiebreak_bonus(ts: &str, now_utc: DateTime<Utc>) -> f64 {
    let Ok(parsed) = DateTime::parse_from_rfc3339(ts) else {
        return 0.0;
    };
    let age_hours = (now_utc - parsed.with_timezone(&Utc)).num_hours().max(0) as f64;
    // Gentle 0..1.5 bonus decaying smoothly over ~30 days: breaks ties among
    // similar BM25 matches without burying older exact identifier/title hits.
    1.5 / (1.0 + age_hours / (24.0 * 14.0))
}

impl SqliteMissionStore {
    #[cfg(test)]
    pub(crate) async fn backfill_search_batch(&self, batch_size: usize) -> Result<bool, String> {
        let conn = self.conn.clone();
        let content_dir = self.content_dir.clone();
        tokio::task::spawn_blocking(move || {
            let mut guard = conn.blocking_lock();
            backfill_batch_sync(&mut guard, &content_dir, batch_size)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    #[cfg(test)]
    pub(crate) async fn rebuild_search_index(&self) -> Result<SearchIndexCoverage, String> {
        let conn = self.conn.clone();
        let content_dir = self.content_dir.clone();
        tokio::task::spawn_blocking(move || {
            let mut guard = conn.blocking_lock();
            let now = now_string();
            guard
                .execute_batch(
                    "DELETE FROM mission_search_docs;
                     INSERT INTO mission_search_fts(mission_search_fts) VALUES('rebuild');",
                )
                .map_err(|e| e.to_string())?;
            let has_missions: bool = guard
                .query_row("SELECT EXISTS(SELECT 1 FROM missions LIMIT 1)", [], |r| {
                    r.get(0)
                })
                .map_err(|e| e.to_string())?;
            guard
                .execute(
                    "INSERT INTO mission_search_state(singleton, schema_version, cursor_mission_id, backfill_complete, indexed_missions, updated_at)
                     VALUES (1, ?1, NULL, ?2, 0, ?3)
                     ON CONFLICT(singleton) DO UPDATE SET
                         schema_version = excluded.schema_version,
                         cursor_mission_id = NULL,
                         backfill_complete = excluded.backfill_complete,
                         indexed_missions = 0,
                         updated_at = excluded.updated_at",
                    params![SEARCH_SCHEMA_VERSION, i64::from(!has_missions), now],
                )
                .map_err(|e| e.to_string())?;
            while backfill_batch_sync(&mut guard, &content_dir, 200)? {}
            read_coverage_sync(&guard)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn search_index_coverage_sqlite(&self) -> Result<SearchIndexCoverage, String> {
        let reader = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = reader.blocking_lock();
            read_coverage_sync(&conn)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn search_conversations_sqlite(
        &self,
        query: &ConversationSearchQuery,
    ) -> Result<ConversationSearchResponse, String> {
        let reader = self.reader();
        let query = query.clone();
        tokio::task::spawn_blocking(move || {
            let conn = reader.blocking_lock();
            let coverage = read_coverage_sync(&conn)?;
            let Some(compiled) = compile_fts_query(&query.query) else {
                return Ok(ConversationSearchResponse {
                    hits: Vec::new(),
                    next_cursor: None,
                    coverage,
                });
            };

            let limit = query.limit.unwrap_or(30).clamp(1, 100);
            let max_per_mission = query.max_per_mission.unwrap_or(2).clamp(1, 10);
            let offset = query
                .cursor
                .as_deref()
                .and_then(|c| c.parse::<usize>().ok())
                .unwrap_or(0);

            let candidate_cap = FTS_CANDIDATE_CAP.max((offset + limit) * max_per_mission * 3);
            let mut base_params: Vec<SqlValue> = vec![SqlValue::Text(compiled.fts_expr.clone())];
            let mut filter_clauses =
                String::from(" AND (m.tags IS NULL OR m.tags NOT LIKE '%\"superseded%')");

            if let Some(mid) = query.mission_id {
                base_params.push(SqlValue::Text(mid.to_string()));
                filter_clauses.push_str(&format!(" AND d.mission_id = ?{}", base_params.len()));
            } else {
                filter_clauses.push_str(
                    " AND (m.tags IS NULL OR (m.tags NOT LIKE '%\"btw-parent:%' AND m.tags NOT LIKE '%\"btw-subagent\"%'))",
                );
            }
            if !query.include_archived {
                filter_clauses.push_str(" AND m.status <> 'acknowledged'");
            }
            if let Some(ref proj) = query.project {
                let p = proj.trim();
                if !p.is_empty() {
                    base_params.push(SqlValue::Text(p.to_string()));
                    filter_clauses.push_str(&format!(" AND m.project = ?{}", base_params.len()));
                }
            }
            match query.role {
                ConversationSearchRole::All => {
                    if !query.include_tools {
                        filter_clauses.push_str(" AND d.role <> 'tool'");
                    }
                }
                ConversationSearchRole::User => filter_clauses.push_str(" AND d.role = 'user'"),
                ConversationSearchRole::Assistant => {
                    filter_clauses.push_str(" AND d.role = 'assistant'")
                }
                ConversationSearchRole::Title => filter_clauses.push_str(" AND d.role = 'title'"),
                ConversationSearchRole::Tool => filter_clauses.push_str(" AND d.role = 'tool'"),
            }
            if let Some(ref since) = query.since {
                let s = since.trim();
                if !s.is_empty() {
                    base_params.push(SqlValue::Text(s.to_string()));
                    filter_clauses.push_str(&format!(" AND d.timestamp >= ?{}", base_params.len()));
                }
            }
            if let Some(ref until) = query.until {
                let u = until.trim();
                if !u.is_empty() {
                    base_params.push(SqlValue::Text(u.to_string()));
                    filter_clauses.push_str(&format!(" AND d.timestamp <= ?{}", base_params.len()));
                }
            }

            // Pin join order (`mission_search_fts -> d (PK) -> m (idx_missions_search_meta)`)
            // via `CROSS JOIN` so SQLite uses FTS5's native rank iterator (`INDEX 32`) without
            // a temp B-tree sort on `Relevance`, and hydrate full `body_text` columns only for
            // the `<= candidate_cap` winning `doc_id`s.
            let mut full_params = base_params;
            full_params.push(SqlValue::Integer(candidate_cap as i64));
            let cap_idx = full_params.len();
            let order_clause = match query.sort {
                ConversationSearchSort::Relevance => "mission_search_fts.rank ASC",
                ConversationSearchSort::Recent => "d.timestamp DESC",
            };
            let full_sql = format!(
                "SELECT d.doc_id, -mission_search_fts.rank AS lexical_score
                 FROM mission_search_fts
                 CROSS JOIN mission_search_docs d ON d.doc_id = mission_search_fts.rowid
                 CROSS JOIN missions m ON m.id = d.mission_id
                 WHERE mission_search_fts MATCH ?1{filter_clauses}
                 ORDER BY {order_clause}
                 LIMIT ?{cap_idx}"
            );
            let mut full_stmt = conn.prepare(&full_sql).map_err(|e| e.to_string())?;
            let winners: Vec<(i64, f64)> = full_stmt
                .query_map(rusqlite::params_from_iter(full_params.iter()), |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            struct Candidate {
                mission_id: Uuid,
                title: Option<String>,
                short_description: Option<String>,
                project: Option<String>,
                status: MissionStatus,
                backend: String,
                updated_at: String,
                parent_mission_id: Option<Uuid>,
                locator: String,
                role: String,
                sequence: Option<i64>,
                event_id: Option<String>,
                timestamp: String,
                title_text: String,
                body_text: String,
                score: f64,
            }

            let now_utc = Utc::now();
            let mut hydrate_stmt = conn
                .prepare_cached(
                    "SELECT
                        d.mission_id,
                        m.title,
                        m.short_description,
                        m.project,
                        m.status,
                        m.backend,
                        m.updated_at,
                        m.parent_mission_id,
                        d.locator,
                        d.role,
                        d.sequence,
                        d.event_id,
                        d.timestamp,
                        d.title_text,
                        d.body_text
                     FROM mission_search_docs d
                     JOIN missions m ON m.id = d.mission_id
                     WHERE d.doc_id = ?1",
                )
                .map_err(|e| e.to_string())?;

            let mut btw_parent_memo: HashMap<Uuid, bool> = HashMap::new();
            let mut candidates: Vec<Candidate> = Vec::with_capacity(winners.len());
            for (doc_id, lexical_score) in winners {
                let Some(row_tuple) = hydrate_stmt
                    .query_row(params![doc_id], |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, Option<String>>(1)?,
                            r.get::<_, Option<String>>(2)?,
                            r.get::<_, Option<String>>(3)?,
                            r.get::<_, String>(4)?,
                            r.get::<_, String>(5)?,
                            r.get::<_, String>(6)?,
                            r.get::<_, Option<String>>(7)?,
                            r.get::<_, String>(8)?,
                            r.get::<_, String>(9)?,
                            r.get::<_, Option<i64>>(10)?,
                            r.get::<_, Option<String>>(11)?,
                            r.get::<_, String>(12)?,
                            r.get::<_, String>(13)?,
                            r.get::<_, String>(14)?,
                        ))
                    })
                    .optional()
                    .map_err(|e| e.to_string())?
                else {
                    continue;
                };
                let (
                    mid_str,
                    title,
                    short_description,
                    project,
                    status_str,
                    backend,
                    updated_at,
                    parent_str,
                    locator,
                    role,
                    sequence,
                    event_id,
                    timestamp,
                    title_text,
                    body_text,
                ) = row_tuple;
                let Ok(mission_id) = Uuid::parse_str(&mid_str) else {
                    continue;
                };
                let parent_mission_id = parent_str.and_then(|s| Uuid::parse_str(&s).ok());
                if query.mission_id.is_none()
                    && ancestor_chain_has_btw_marker(&conn, parent_mission_id, &mut btw_parent_memo)?
                {
                    continue;
                }
                let status = parse_mission_status(&status_str);

                let mut score = lexical_score.max(0.01);
                if !compiled.raw_lower.is_empty() {
                    let title_lower = title.as_deref().unwrap_or("").to_lowercase();
                    if title_lower == compiled.raw_lower
                        || mid_str
                            .to_ascii_lowercase()
                            .starts_with(&compiled.raw_lower)
                    {
                        score += 30.0;
                    } else if title_lower.contains(&compiled.raw_lower) {
                        score += 14.0;
                    }
                    let body_lower = body_text.to_lowercase();
                    if body_lower.contains(&compiled.raw_lower) {
                        score += 10.0;
                    }
                    for phrase in &compiled.exact_phrases {
                        if !body_lower.contains(phrase)
                            && !title_text.to_lowercase().contains(phrase)
                        {
                            score *= 0.25;
                        }
                    }
                }
                score += recency_tiebreak_bonus(&timestamp, now_utc);

                candidates.push(Candidate {
                    mission_id,
                    title,
                    short_description,
                    project,
                    status,
                    backend,
                    updated_at,
                    parent_mission_id,
                    locator,
                    role,
                    sequence,
                    event_id,
                    timestamp,
                    title_text,
                    body_text,
                    score,
                });
            }

            match query.sort {
                ConversationSearchSort::Relevance => {
                    candidates.sort_by(|a, b| {
                        b.score
                            .total_cmp(&a.score)
                            .then_with(|| b.timestamp.cmp(&a.timestamp))
                    });
                }
                ConversationSearchSort::Recent => {
                    candidates.sort_by(|a, b| {
                        b.timestamp
                            .cmp(&a.timestamp)
                            .then_with(|| b.score.total_cmp(&a.score))
                    });
                }
            }

            // Count matches per conversation and keep up to `max_per_mission`
            // passages per conversation, grouped together under the conversation's
            // strongest/newest rank so long threads never monopolize page 1.
            let mut total_per_mission: HashMap<Uuid, usize> = HashMap::new();
            let mut bucket_per_mission: HashMap<Uuid, Vec<Candidate>> = HashMap::new();
            let mut mission_order: Vec<Uuid> = Vec::new();
            for cand in candidates {
                let count = total_per_mission.entry(cand.mission_id).or_insert(0);
                *count += 1;
                let bucket = bucket_per_mission
                    .entry(cand.mission_id)
                    .or_insert_with(|| {
                        mission_order.push(cand.mission_id);
                        Vec::with_capacity(max_per_mission)
                    });
                if bucket.len() < max_per_mission {
                    bucket.push(cand);
                }
            }

            let mut ordered: Vec<(Candidate, usize)> = Vec::new();
            for mid in mission_order {
                let m_count = total_per_mission.get(&mid).copied().unwrap_or(1);
                if let Some(bucket) = bucket_per_mission.remove(&mid) {
                    for cand in bucket {
                        ordered.push((cand, m_count));
                    }
                }
            }

            let total_grouped = ordered.len();
            let page_slice = ordered.into_iter().skip(offset).take(limit);
            let mut hits = Vec::with_capacity(limit);
            for (cand, mission_match_count) in page_slice {
                let source_text = if cand.role == "title" {
                    let combined = [cand.title.as_deref().unwrap_or(""), cand.body_text.as_str()]
                        .into_iter()
                        .filter(|s| !s.trim().is_empty())
                        .collect::<Vec<_>>()
                        .join(" — ");
                    if combined.is_empty() {
                        cand.title_text.clone()
                    } else {
                        combined
                    }
                } else {
                    cand.body_text.clone()
                };
                let (excerpt, highlights) =
                    build_search_excerpt_utf16(&source_text, &compiled.highlight_terms, 180);
                hits.push(ConversationSearchHit {
                    mission_id: cand.mission_id,
                    title: cand.title,
                    short_description: cand.short_description,
                    project: cand.project,
                    status: cand.status,
                    backend: cand.backend,
                    updated_at: cand.updated_at,
                    parent_mission_id: cand.parent_mission_id,
                    locator: cand.locator,
                    role: cand.role,
                    sequence: cand.sequence,
                    event_id: cand.event_id,
                    timestamp: cand.timestamp,
                    excerpt,
                    highlights,
                    mission_match_count,
                    score: cand.score,
                });
            }

            let next_cursor =
                (offset + hits.len() < total_grouped).then(|| (offset + hits.len()).to_string());

            Ok(ConversationSearchResponse {
                hits,
                next_cursor,
                coverage,
            })
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_passage_context_sqlite(
        &self,
        mission_id: Uuid,
        params: &PassageContextQuery,
    ) -> Result<Option<PassageContextResponse>, String> {
        let reader = self.reader();
        let params = params.clone();
        tokio::task::spawn_blocking(move || {
            let conn = reader.blocking_lock();
            let mid = mission_id.to_string();

            type MissionContextHeaderRow = (Option<String>, Option<String>, String, String, String);
            let mission_row: Option<MissionContextHeaderRow> = conn
                .query_row(
                    "SELECT title, project, status, backend, updated_at
                     FROM missions WHERE id = ?1",
                    params![&mid],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
                )
                .optional()
                .map_err(|e| e.to_string())?;

            let Some((title, project, status_str, backend, updated_at)) = mission_row else {
                return Ok(None);
            };
            let status = parse_mission_status(&status_str);

            let highlight_terms = params
                .query
                .as_deref()
                .and_then(compile_fts_query)
                .map(|c| c.highlight_terms)
                .unwrap_or_default();
            let before = params.before.unwrap_or(2).min(12);
            let after = params.after.unwrap_or(2).min(12);

            let mut cloud_turn_keys = HashSet::new();
            let mut cloud_msgs: Vec<DesiredDoc> = Vec::new();
            if let Some(raw_cloud) = conn
                .query_row(
                    "SELECT data FROM cloud_executions WHERE mission_id = ?1",
                    params![&mid],
                    |r| r.get::<_, String>(0),
                )
                .optional()
                .map_err(|e| e.to_string())?
            {
                if let Ok(exec) = serde_json::from_str::<CloudExecution>(&raw_cloud) {
                    for turn in exec.turns {
                        cloud_turn_keys.insert(turn.key.clone());
                        if !turn.prompt.trim().is_empty() {
                            cloud_msgs.push(DesiredDoc {
                                doc_key: String::new(),
                                locator: format!("cloud:{}:prompt", turn.key),
                                role: "user".to_string(),
                                sequence: None,
                                event_id: Some(turn.key.clone()),
                                timestamp: updated_at.clone(),
                                title_text: String::new(),
                                body_text: turn.prompt.trim().to_string(),
                            });
                        }
                        if let Some(ans) = turn
                            .result
                            .as_deref()
                            .map(str::trim)
                            .filter(|s| !s.is_empty())
                        {
                            cloud_msgs.push(DesiredDoc {
                                doc_key: String::new(),
                                locator: format!("cloud:{}:answer", turn.key),
                                role: "assistant".to_string(),
                                sequence: None,
                                event_id: Some(turn.key),
                                timestamp: updated_at.clone(),
                                title_text: String::new(),
                                body_text: ans.to_string(),
                            });
                        }
                    }
                    if params.locator.starts_with("cloud:") || params.locator == "title" {
                        let target_pos = if params.locator == "title" {
                            cloud_msgs.len().checked_sub(1)
                        } else {
                            cloud_msgs.iter().position(|m| m.locator == params.locator)
                        };
                        let (slice, mut target_found) = slice_context_docs(
                            &cloud_msgs,
                            target_pos,
                            before,
                            after,
                            &highlight_terms,
                        );
                        if params.locator == "title" {
                            target_found = true;
                        }
                        return Ok(Some(PassageContextResponse {
                            mission_id,
                            title,
                            project,
                            status,
                            backend,
                            updated_at,
                            locator: params.locator,
                            target_found,
                            target_sequence: None,
                            messages: slice,
                            events: Vec::new(),
                        }));
                    }
                }
            }

            // Resolve target sequence in `mission_events` without scanning the full table.
            let resolved_seq = resolve_locator_sequence(&conn, &mid, &params)?;

            let max_seq: i64 = conn
                .query_row(
                    "SELECT COALESCE(MAX(sequence), 0) FROM mission_events WHERE mission_id = ?1",
                    params![&mid],
                    |r| r.get(0),
                )
                .unwrap_or(0);

            let anchor_seq = resolved_seq.or(params.sequence).unwrap_or(max_seq);
            let lo_seq = find_window_lower_bound(&conn, &mid, anchor_seq, (before + 4) as i64)?;
            let hi_seq =
                find_window_upper_bound(&conn, &mid, anchor_seq, (after + 4) as i64, max_seq)?;

            let mut folded = load_and_fold_mission_events(
                &conn,
                &mid,
                &cloud_turn_keys,
                Some((lo_seq, hi_seq)),
            )?;
            // Exclude tool summaries unless the locator explicitly points to a tool doc.
            if !params.locator.starts_with("turn:tools:") {
                folded.retain(|d| d.role != "tool");
            }

            let target_pos = if params.locator == "title" {
                folded.len().checked_sub(1)
            } else {
                folded
                    .iter()
                    .position(|d| d.locator == params.locator)
                    .or_else(|| {
                        params.event_id.as_deref().and_then(|eid| {
                            folded
                                .iter()
                                .position(|d| d.event_id.as_deref() == Some(eid))
                        })
                    })
                    .or_else(|| {
                        resolved_seq
                            .and_then(|seq| folded.iter().position(|d| d.sequence == Some(seq)))
                    })
            };

            let (messages, mut target_found) =
                slice_context_docs(&folded, target_pos, before, after, &highlight_terms);
            if params.locator == "title" {
                target_found = true;
            }

            let events = if params.include_events && max_seq > 0 {
                let ev_lo = (anchor_seq - CONTEXT_EVENT_RADIUS).max(1);
                let ev_hi = (anchor_seq + CONTEXT_EVENT_RADIUS).min(max_seq);
                load_stored_events_range(&conn, &mid, ev_lo, ev_hi)?
            } else {
                Vec::new()
            };

            Ok(Some(PassageContextResponse {
                mission_id,
                title,
                project,
                status,
                backend,
                updated_at,
                locator: params.locator,
                target_found,
                target_sequence: resolved_seq,
                messages,
                events,
            }))
        })
        .await
        .map_err(|e| e.to_string())?
    }
}

fn resolve_locator_sequence(
    conn: &Connection,
    mid: &str,
    params: &PassageContextQuery,
) -> Result<Option<i64>, String> {
    if params.locator == "title" {
        return Ok(None);
    }
    if let Some(seq_str) = params
        .locator
        .strip_prefix("msg:seq:")
        .or_else(|| params.locator.strip_prefix("turn:tools:"))
    {
        if let Ok(seq) = seq_str.parse::<i64>() {
            let exists: Option<i64> = conn
                .query_row(
                    "SELECT sequence FROM mission_events WHERE mission_id = ?1 AND sequence = ?2 LIMIT 1",
                    params![mid, seq],
                    |r| r.get(0),
                )
                .optional()
                .map_err(|e| e.to_string())?;
            if exists.is_some() {
                return Ok(exists);
            }
        }
    }
    if let Some(eid) = params
        .locator
        .strip_prefix("msg:id:")
        .or_else(|| params.locator.strip_prefix("msg:bubble:"))
        .or(params.event_id.as_deref())
    {
        let found: Option<i64> = conn
            .query_row(
                "SELECT sequence FROM mission_events
                 WHERE mission_id = ?1 AND event_id = ?2
                 ORDER BY sequence DESC LIMIT 1",
                params![mid, eid],
                |r| r.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        if found.is_some() {
            return Ok(found);
        }
    }
    if let Some(seq) = params.sequence {
        let found: Option<i64> = conn
            .query_row(
                "SELECT sequence FROM mission_events WHERE mission_id = ?1 AND sequence = ?2 LIMIT 1",
                params![mid, seq],
                |r| r.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        return Ok(found);
    }
    Ok(None)
}

fn find_window_lower_bound(
    conn: &Connection,
    mid: &str,
    anchor_seq: i64,
    user_turns_back: i64,
) -> Result<i64, String> {
    let seq: Option<i64> = conn
        .query_row(
            "SELECT MIN(sequence) FROM (
                SELECT sequence FROM mission_events
                WHERE mission_id = ?1
                  AND sequence <= ?2
                  AND event_type IN ('user_message', 'assistant_message', 'assistant_message_canonical')
                ORDER BY sequence DESC
                LIMIT ?3
            )",
            params![mid, anchor_seq, user_turns_back * 4],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?
        .flatten();
    Ok(seq.unwrap_or(1).saturating_sub(10).max(1))
}

fn find_window_upper_bound(
    conn: &Connection,
    mid: &str,
    anchor_seq: i64,
    user_turns_forward: i64,
    max_seq: i64,
) -> Result<i64, String> {
    let seq: Option<i64> = conn
        .query_row(
            "SELECT MAX(sequence) FROM (
                SELECT sequence FROM mission_events
                WHERE mission_id = ?1
                  AND sequence >= ?2
                  AND event_type IN ('user_message', 'assistant_message', 'assistant_message_canonical')
                ORDER BY sequence ASC
                LIMIT ?3
            )",
            params![mid, anchor_seq, user_turns_forward * 4],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?
        .flatten();
    Ok(seq
        .unwrap_or(max_seq)
        .saturating_add(10)
        .min(max_seq.max(1)))
}

fn slice_context_docs(
    docs: &[DesiredDoc],
    target_pos: Option<usize>,
    before: usize,
    after: usize,
    highlight_terms: &[String],
) -> (Vec<PassageContextMessage>, bool) {
    if docs.is_empty() {
        return (Vec::new(), false);
    }
    let (start, end, mut found) = if let Some(idx) = target_pos {
        (
            idx.saturating_sub(before),
            (idx + after + 1).min(docs.len()),
            true,
        )
    } else {
        let len = docs.len();
        (len.saturating_sub(before + after + 1), len, false)
    };
    let mut out = Vec::with_capacity(end.saturating_sub(start));
    for (off, doc) in docs[start..end].iter().enumerate() {
        let idx = start + off;
        let is_target = Some(idx) == target_pos;
        let max_chars = if is_target { 1_600 } else { 700 };
        let (content, highlights) =
            build_search_excerpt_utf16(&doc.body_text, highlight_terms, max_chars);
        if is_target && !highlight_terms.is_empty() && highlights.is_empty() {
            // The message locator still exists, but the matched text was edited out.
            found = false;
        }
        out.push(PassageContextMessage {
            locator: doc.locator.clone(),
            role: doc.role.clone(),
            sequence: doc.sequence,
            event_id: doc.event_id.clone(),
            timestamp: doc.timestamp.clone(),
            content,
            highlights,
            is_target,
        });
    }
    (out, found)
}

fn load_stored_events_range(
    conn: &Connection,
    mid: &str,
    lo_seq: i64,
    hi_seq: i64,
) -> Result<Vec<StoredEvent>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT id, mission_id, sequence, event_type, timestamp, event_id,
                    tool_call_id, tool_name, content, content_file, metadata
             FROM mission_events
             WHERE mission_id = ?1
               AND sequence BETWEEN ?2 AND ?3
               AND event_type IN (
                   'user_message',
                   'assistant_message',
                   'assistant_message_canonical',
                   'text_delta',
                   'text_op',
                   'thinking',
                   'tool_call',
                   'tool_result',
                   'error',
                   'mission_status_changed'
               )
             ORDER BY sequence ASC",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![mid, lo_seq, hi_seq], |row| {
            let id: i64 = row.get(0)?;
            let mission_str: String = row.get(1)?;
            let sequence: i64 = row.get(2)?;
            let event_type: String = row.get(3)?;
            let timestamp: String = row.get(4)?;
            let event_id: Option<String> = row.get(5)?;
            let tool_call_id: Option<String> = row.get(6)?;
            let tool_name: Option<String> = row.get(7)?;
            let content_inline: Option<String> = row.get(8)?;
            let content_file: Option<String> = row.get(9)?;
            let metadata_str: Option<String> = row.get(10)?;
            Ok((
                id,
                mission_str,
                sequence,
                event_type,
                timestamp,
                event_id,
                tool_call_id,
                tool_name,
                content_inline,
                content_file,
                metadata_str,
            ))
        })
        .map_err(|e| e.to_string())?;

    let mut out = Vec::new();
    for r in rows {
        let (
            id,
            mission_str,
            sequence,
            event_type,
            timestamp,
            event_id,
            tool_call_id,
            tool_name,
            content_inline,
            content_file,
            metadata_str,
        ) = r.map_err(|e| e.to_string())?;
        let Ok(mission_id) = Uuid::parse_str(&mission_str) else {
            continue;
        };
        let mut content =
            SqliteMissionStore::load_content(content_inline.as_deref(), content_file.as_deref());
        let mut metadata: serde_json::Value = metadata_str
            .as_deref()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_else(|| serde_json::json!({}));
        if (event_type == "tool_call" || event_type == "tool_result")
            && content.len() > CONTEXT_MAX_PAYLOAD_BYTES
        {
            let mut cut = CONTEXT_MAX_PAYLOAD_BYTES;
            while cut > 0 && !content.is_char_boundary(cut) {
                cut -= 1;
            }
            content.truncate(cut);
            if let Some(obj) = metadata.as_object_mut() {
                obj.insert("truncated".to_string(), serde_json::json!(true));
            }
        }
        out.push(StoredEvent {
            id,
            mission_id,
            sequence,
            event_type,
            timestamp,
            event_id,
            tool_call_id,
            tool_name,
            content,
            metadata,
        });
    }
    Ok(out)
}
