//! Event log aggregate: writes, paging, summaries and counts.

use super::*;

#[derive(serde::Serialize)]
pub(super) struct AssistantCostMetadata {
    pub(super) amount_cents: u64,
    pub(super) currency: &'static str,
    pub(super) source: crate::agents::CostSource,
}

#[derive(serde::Serialize)]
pub(super) struct AssistantMessageMetadata {
    pub(super) success: bool,
    pub(super) cost_cents: u64,
    pub(super) cost: AssistantCostMetadata,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) usage: Option<crate::cost::TokenUsage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) model_normalized: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) shared_files: Option<Vec<crate::api::control::SharedFile>>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(super) resumable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) completion_evidence: Option<crate::agents::CompletionEvidence>,
}

pub(super) struct AssistantMessageMetadataInput<'a> {
    pub(super) success: bool,
    pub(super) cost_cents: u64,
    pub(super) cost_source: crate::agents::CostSource,
    pub(super) usage: &'a Option<crate::cost::TokenUsage>,
    pub(super) model: &'a Option<String>,
    pub(super) model_normalized: &'a Option<String>,
    pub(super) shared_files: &'a Option<Vec<crate::api::control::SharedFile>>,
    pub(super) resumable: bool,
    pub(super) completion_evidence: &'a Option<crate::agents::CompletionEvidence>,
}

pub(super) fn assistant_message_metadata(
    input: AssistantMessageMetadataInput<'_>,
) -> serde_json::Value {
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

/// Parse a UUID from a database string, logging a warning and falling back to
/// the nil UUID when the value is malformed.  This prevents silent data
/// corruption that `Uuid::parse_str(...).unwrap_or_default()` would introduce
/// without any diagnostic.
pub(super) fn parse_uuid_or_nil(raw: &str) -> Uuid {
    Uuid::parse_str(raw).unwrap_or_else(|e| {
        tracing::warn!(
            raw_value = %raw,
            error = %e,
            "Corrupt UUID in database; substituting nil UUID"
        );
        Uuid::nil()
    })
}

pub(super) fn apply_text_ops(buffer: &mut String, ops: &[TextOp]) {
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

/// Synchronous body of `log_event`, so callers can run it inside a larger
/// transaction (the client link commits an event with its ingest cursor).
pub(in crate::api::mission_store) fn log_event_sync(
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
            if (bubble_id.starts_with("antigravity:") || bubble_id.starts_with("opencode:")) && conn.query_row(
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
impl SqliteMissionStore {
    pub(super) async fn log_event(
        &self,
        mission_id: Uuid,
        event: &AgentEvent,
    ) -> Result<(), String> {
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

    pub(super) async fn log_events(
        &self,
        events: Vec<(Uuid, AgentEvent)>,
    ) -> Vec<Result<(), String>> {
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

    pub(super) async fn get_latest_events(
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

    pub(super) async fn get_events(
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

    pub(super) async fn get_events_since(
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
                    let ev = row.map_err(|e| e.to_string())?;
                    let verdict = crate::api::mission_store::evaluate_cursor_page_gate(
                        Some(since_seq.max(0) as u64),
                        None,
                        ev.sequence.max(0) as u64,
                        true,
                        result.len() as u32,
                        ev.sequence > since_seq,
                    );
                    if verdict.include_item {
                        result.push(ev);
                    }
                }
                result
            } else {
                let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![&mid, since_seq, limit], parse_row)
                    .map_err(|e| e.to_string())?;
                let mut result = Vec::new();
                for row in rows {
                    let ev = row.map_err(|e| e.to_string())?;
                    let verdict = crate::api::mission_store::evaluate_cursor_page_gate(
                        Some(since_seq.max(0) as u64),
                        None,
                        ev.sequence.max(0) as u64,
                        true,
                        result.len() as u32,
                        ev.sequence > since_seq,
                    );
                    if verdict.include_item {
                        result.push(ev);
                    }
                }
                result
            };

            Ok(events)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_events_before(
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
                    let ev = row.map_err(|e| e.to_string())?;
                    let verdict = crate::api::mission_store::evaluate_cursor_page_gate(
                        None,
                        Some(before_seq.max(0) as u64),
                        ev.sequence.max(0) as u64,
                        true,
                        result.len() as u32,
                        ev.sequence < before_seq,
                    );
                    if verdict.include_item {
                        result.push(ev);
                    }
                }
                result
            } else {
                let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![&mid, before_seq, limit], parse_row)
                    .map_err(|e| e.to_string())?;
                let mut result = Vec::new();
                for row in rows {
                    let ev = row.map_err(|e| e.to_string())?;
                    let verdict = crate::api::mission_store::evaluate_cursor_page_gate(
                        None,
                        Some(before_seq.max(0) as u64),
                        ev.sequence.max(0) as u64,
                        true,
                        result.len() as u32,
                        ev.sequence < before_seq,
                    );
                    if verdict.include_item {
                        result.push(ev);
                    }
                }
                result
            };

            Ok(events)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_status_events_global(
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

    pub(super) async fn get_events_for_tool_call(
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

    pub(super) async fn get_recent_tool_call_ids(
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

    pub(super) async fn get_tool_call_summaries(
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

    pub(super) async fn max_event_sequence(&self, mission_id: Uuid) -> Result<i64, String> {
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

    pub(super) async fn nth_recent_event_sequence(
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

    pub(super) async fn count_events(
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

    pub(super) async fn count_events_by_type(
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
}
