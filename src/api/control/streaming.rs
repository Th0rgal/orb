//! SSE/WebSocket streaming and text_op stream merging.

use super::*;

/// Stream control session events via SSE.
#[derive(Debug, Deserialize)]
pub struct StreamQuery {
    /// Optional mission filter. When set, the server only emits events whose
    /// `mission_id` matches (plus the connection-scoped `status` /
    /// `stream_lagged` events the dashboard relies on). Cuts cross-mission
    /// noise to zero for a focused tab. Omit the param to receive every
    /// event the user can see (used by the mission list / debug overlay).
    #[serde(default, alias = "mission_id")]
    pub mission: Option<Uuid>,
    /// Optional comma-separated event-kind filter, e.g. `kinds=fido`. A kind
    /// matches an event whose SSE name equals it or starts with `<kind>_`
    /// (`fido` matches `fido_sign_request`). The initial status snapshot and
    /// `stream_lagged` are always sent. Lets the mobile apps' background
    /// FIDO monitor skip every mission event.
    #[serde(default)]
    pub kinds: Option<String>,
    #[serde(default)]
    pub profile: Option<String>,
}

/// Bounded offscreen hints never contain prompts, tool arguments or results.
fn presentation_hint(event: &AgentEvent) -> Option<serde_json::Value> {
    let mission_id = event.mission_id()?;
    let label = match event {
        AgentEvent::MissionActivity { label, .. } => {
            Some(label.chars().take(160).collect::<String>())
        }
        AgentEvent::MissionStatusChanged { .. }
        | AgentEvent::AssistantMessage { .. }
        | AgentEvent::Error { .. }
        | AgentEvent::UserMessage { .. }
        | AgentEvent::MissionTitleChanged { .. }
        | AgentEvent::MissionMetadataUpdated { .. } => None,
        _ => return None,
    };
    Some(
        serde_json::json!({ "mission_id": mission_id, "kind": event.event_name(), "label": label }),
    )
}

/// Parse `StreamQuery::kinds` into a filter; `None` means "every event".
pub(crate) fn parse_stream_kinds(raw: Option<&str>) -> Option<Vec<String>> {
    let kinds: Vec<String> = raw?
        .split(',')
        .map(|k| k.trim().to_ascii_lowercase())
        .filter(|k| !k.is_empty())
        .collect();
    (!kinds.is_empty()).then_some(kinds)
}

pub(crate) fn stream_kind_matches(kinds: &[String], event_name: &str) -> bool {
    kinds.iter().any(|k| {
        event_name == k
            || (event_name.len() > k.len()
                && event_name.starts_with(k.as_str())
                && event_name.as_bytes()[k.len()] == b'_')
    })
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(super) enum ControlWsClientMessage {
    Resume { since_seq: i64 },
}

#[derive(Debug, Serialize)]
pub(super) struct ControlWsHeartbeat {
    pub(super) seq: i64,
}

pub(super) fn suffix_prefix_overlap_len(existing: &str, incoming: &str) -> usize {
    let max_overlap = existing.chars().count().min(incoming.chars().count());
    for overlap_chars in (1..=max_overlap).rev() {
        let existing_start = existing
            .char_indices()
            .nth(existing.chars().count() - overlap_chars)
            .map(|(idx, _)| idx)
            .unwrap_or(0);
        let incoming_end = incoming
            .char_indices()
            .nth(overlap_chars)
            .map(|(idx, _)| idx)
            .unwrap_or(incoming.len());
        if existing[existing_start..] == incoming[..incoming_end] {
            return incoming_end;
        }
    }
    0
}

pub(super) fn merge_text_stream_fragment(buffer: &mut String, fragment: &str) {
    if fragment.is_empty() {
        return;
    }
    if buffer.is_empty() || fragment.starts_with(buffer.as_str()) {
        *buffer = fragment.to_string();
        return;
    }
    if buffer.starts_with(fragment) {
        return;
    }

    let overlap = suffix_prefix_overlap_len(buffer, fragment);
    buffer.push_str(&fragment[overlap..]);
}

pub const STREAM_MAX_OPEN_TAIL_BYTES: u32 = 4096;

static STREAM_BOUNDED_COMMIT_SHADOW_COUNTER: std::sync::OnceLock<crate::orb_spec::ShadowCounter> =
    std::sync::OnceLock::new();

pub fn stream_bounded_commit_shadow_counter() -> &'static crate::orb_spec::ShadowCounter {
    STREAM_BOUNDED_COMMIT_SHADOW_COUNTER.get_or_init(crate::orb_spec::ShadowCounter::new)
}

pub fn evaluate_stream_bounded_commit_gate(
    prev_len: u32,
    prev_commit: u32,
    prev_checkpoint: u32,
    new_len: u32,
    raw_commit: u32,
    max_open_tail_bytes: u32,
) -> crate::orb_spec::StreamBoundedCommitVerdict {
    let input = crate::orb_spec::StreamBoundedCommitInput {
        prev_len,
        prev_commit,
        prev_checkpoint,
        new_len,
        raw_commit,
        max_open_tail_bytes,
    };
    let verdict = crate::orb_spec::stream_bounded_commit_step(input);
    let valid = max_open_tail_bytes > 0
        && prev_commit <= prev_checkpoint
        && prev_checkpoint <= prev_len
        && prev_len <= new_len;
    let clamped_raw = raw_commit.min(new_len);
    let next_commit = prev_commit.max(clamped_raw);
    let base_checkpoint = prev_checkpoint.max(next_commit);
    let cap_floor = new_len.saturating_sub(max_open_tail_bytes);
    let host_next_checkpoint = if valid {
        base_checkpoint.max(cap_floor)
    } else {
        prev_checkpoint
    };
    let host_forced = valid && host_next_checkpoint > next_commit;
    let sim = crate::orb_spec::shadow::RefinementSimulation::<
        (bool, u32),
        (bool, u32),
        crate::orb_spec::StreamBoundedCommitInput,
        u8,
        u8,
    > {
        subsystem: "orb_stream_bounded_commit_step",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = crate::orb_spec::stream_bounded_commit_step(*ev);
            (
                (v.admitted, v.next_checkpoint),
                vec![u8::from(v.checkpoint_forced)],
            )
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let ctx = crate::orb_spec::shadow::EventContext {
        now_ms: u64::from(new_len),
        fresh_nonce: u64::from(prev_len),
        idempotency_key: u64::from(raw_commit),
        boot_id_matches: true,
        schema_id: 2,
    };
    stream_bounded_commit_shadow_counter().with_ring(|ring| {
        let _ = sim.observe_step(
            &(false, prev_checkpoint),
            &(valid, host_next_checkpoint),
            &input,
            &[u8::from(host_forced)],
            ctx,
            ring,
        );
    });
    verdict
}

pub(super) fn text_op_events_for_stream(
    ev: AgentEvent,
    text_buffers: &mut HashMap<Uuid, String>,
) -> Vec<AgentEvent> {
    match ev {
        AgentEvent::TextDelta {
            content,
            mission_id: Some(mission_id),
        } => {
            let previous = text_buffers.entry(mission_id).or_default();
            let prev_bytes = previous.len().min(u32::MAX as usize) as u32;
            let prev_raw_commit = previous
                .rfind("\n\n")
                .map(|idx| (idx + 2).min(u32::MAX as usize) as u32)
                .unwrap_or(0);
            let prev_checkpoint =
                prev_raw_commit.max(prev_bytes.saturating_sub(STREAM_MAX_OPEN_TAIL_BYTES));
            let previous_len = previous.chars().count();
            let mut next = previous.clone();
            merge_text_stream_fragment(&mut next, &content);
            let new_bytes = next.len().min(u32::MAX as usize) as u32;
            let raw_commit = next
                .rfind("\n\n")
                .map(|idx| (idx + 2).min(u32::MAX as usize) as u32)
                .unwrap_or(prev_raw_commit);
            let commit_verdict = evaluate_stream_bounded_commit_gate(
                prev_bytes,
                prev_raw_commit,
                prev_checkpoint,
                new_bytes.max(prev_bytes),
                raw_commit,
                STREAM_MAX_OPEN_TAIL_BYTES,
            );
            debug_assert!(
                commit_verdict.admitted
                    && new_bytes
                        .max(prev_bytes)
                        .saturating_sub(commit_verdict.next_checkpoint)
                        <= STREAM_MAX_OPEN_TAIL_BYTES
            );
            let ops = if previous.is_empty() {
                vec![TextOp::Insert {
                    pos: 0,
                    text: next.clone(),
                }]
            } else {
                vec![TextOp::Replace {
                    range: (0, previous_len),
                    text: next.clone(),
                }]
            };
            *previous = next;
            vec![AgentEvent::TextOp {
                mission_id,
                bubble_id: "text_delta_latest".to_string(),
                ops,
            }]
        }
        // A delivered user message starts a new turn, and a mission leaving
        // Active cuts the running one. Either way the next turn's text must
        // start from an empty buffer: a carried buffer made the new reply's
        // first snapshot `previous turn + new text` (the glued Send now reply).
        AgentEvent::UserMessage {
            queued: false,
            mission_id: Some(mission_id),
            ..
        } => {
            text_buffers.remove(&mission_id);
            vec![ev]
        }
        AgentEvent::MissionStatusChanged {
            mission_id, status, ..
        } if status != MissionStatus::Active && text_buffers.remove(&mission_id).is_some() => {
            vec![
                AgentEvent::TextOp {
                    mission_id,
                    bubble_id: "text_delta_latest".to_string(),
                    ops: vec![TextOp::Finalize],
                },
                ev,
            ]
        }
        AgentEvent::AssistantMessage {
            mission_id: Some(mission_id),
            ..
        } if text_buffers.remove(&mission_id).is_some() => {
            vec![
                AgentEvent::TextOp {
                    mission_id,
                    bubble_id: "text_delta_latest".to_string(),
                    ops: vec![TextOp::Finalize],
                },
                ev,
            ]
        }
        _ => vec![ev],
    }
}

pub(super) fn stored_event_to_agent_event(
    event: &mission_store::StoredEvent,
) -> Option<AgentEvent> {
    let mission_id = Some(event.mission_id);
    match event.event_type.as_str() {
        "user_message" => Some(AgentEvent::UserMessage {
            id: event
                .event_id
                .as_deref()
                .and_then(|id| Uuid::parse_str(id).ok())
                .unwrap_or_else(Uuid::new_v4),
            content: if event
                .metadata
                .get("source")
                .and_then(serde_json::Value::as_str)
                == Some("scheduler")
            {
                let messages = event
                    .metadata
                    .get("messages")
                    .cloned()
                    .and_then(|v| serde_json::from_value(v).ok())
                    .unwrap_or_default();
                deferred_messages::wrap(&event.content, messages)
            } else {
                event.content.clone()
            },
            queued: false,
            mission_id,
            source: event
                .metadata
                .get("source")
                .and_then(|v| v.as_str())
                .map(str::to_string),
        }),
        "assistant_message" => {
            let meta = event.metadata.as_object();
            Some(AgentEvent::AssistantMessage {
                id: event
                    .event_id
                    .as_deref()
                    .and_then(|id| Uuid::parse_str(id).ok())
                    .unwrap_or_else(Uuid::new_v4),
                content: event.content.clone(),
                success: meta
                    .and_then(|m| m.get("success"))
                    .and_then(|v| v.as_bool())
                    .unwrap_or(true),
                cost_cents: meta
                    .and_then(|m| m.get("cost_cents"))
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0),
                cost_source: crate::agents::CostSource::Unknown,
                usage: None,
                model: meta
                    .and_then(|m| m.get("model"))
                    .and_then(|v| v.as_str())
                    .map(ToString::to_string),
                model_normalized: meta
                    .and_then(|m| m.get("model_normalized"))
                    .and_then(|v| v.as_str())
                    .map(ToString::to_string),
                mission_id,
                shared_files: None,
                resumable: meta
                    .and_then(|m| m.get("resumable"))
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false),
                completion_evidence: meta
                    .and_then(|m| m.get("completion_evidence"))
                    .and_then(|v| serde_json::from_value(v.clone()).ok()),
            })
        }
        "thinking" => Some(AgentEvent::Thinking {
            content: event.content.clone(),
            done: event
                .metadata
                .as_object()
                .and_then(|m| m.get("done"))
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
            mission_id,
        }),
        "text_delta" => Some(AgentEvent::TextDelta {
            content: event.content.clone(),
            mission_id,
        }),
        "text_op" => Some(AgentEvent::TextOp {
            mission_id: event.mission_id,
            bubble_id: event
                .metadata
                .as_object()
                .and_then(|m| m.get("bubble_id"))
                .and_then(|v| v.as_str())
                .map(ToString::to_string)
                .or_else(|| event.event_id.clone())
                .unwrap_or_else(|| format!("event-{}", event.id)),
            ops: serde_json::from_str(&event.content).unwrap_or_default(),
        }),
        "assistant_message_canonical" => Some(AgentEvent::AssistantMessage {
            id: event
                .event_id
                .as_deref()
                .and_then(|id| Uuid::parse_str(id).ok())
                .unwrap_or_else(Uuid::new_v4),
            content: event.content.clone(),
            success: true,
            cost_cents: 0,
            cost_source: crate::agents::CostSource::Unknown,
            usage: None,
            model: None,
            model_normalized: None,
            mission_id,
            shared_files: None,
            resumable: false,
            completion_evidence: None,
        }),
        "tool_call" => Some(AgentEvent::ToolCall {
            tool_call_id: event
                .tool_call_id
                .clone()
                .unwrap_or_else(|| format!("event-{}", event.id)),
            name: event
                .tool_name
                .clone()
                .unwrap_or_else(|| "unknown".to_string()),
            args: serde_json::from_str(&event.content).unwrap_or(serde_json::Value::Null),
            mission_id,
        }),
        "tool_result" => Some(AgentEvent::ToolResult {
            tool_call_id: event.tool_call_id.clone().unwrap_or_default(),
            name: event
                .tool_name
                .clone()
                .unwrap_or_else(|| "unknown".to_string()),
            result: serde_json::from_str(&event.content)
                .unwrap_or_else(|_| serde_json::Value::String(event.content.clone())),
            mission_id,
        }),
        "error" => Some(AgentEvent::Error {
            message: event.content.clone(),
            mission_id,
            resumable: event
                .metadata
                .as_object()
                .and_then(|m| m.get("resumable"))
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
        }),
        "mission_status_changed" => {
            let status = event
                .metadata
                .as_object()
                .and_then(|m| m.get("status"))
                .and_then(|v| v.as_str())
                .and_then(|s| serde_json::from_value::<MissionStatus>(serde_json::json!(s)).ok())?;
            Some(AgentEvent::MissionStatusChanged {
                completion: event
                    .metadata
                    .get("completion")
                    .cloned()
                    .and_then(|value| serde_json::from_value(value).ok()),
                execution: event
                    .metadata
                    .get("execution")
                    .cloned()
                    .and_then(|value| serde_json::from_value(value).ok()),
                mission_id: event.mission_id,
                status,
                summary: None,
            })
        }
        "agent_phase" | "phase" => Some(AgentEvent::AgentPhase {
            phase: event.content.clone(),
            detail: event
                .metadata
                .as_object()
                .and_then(|m| m.get("detail"))
                .and_then(|v| v.as_str())
                .map(ToString::to_string),
            agent: event
                .metadata
                .as_object()
                .and_then(|m| m.get("agent"))
                .and_then(|v| v.as_str())
                .map(ToString::to_string),
            mission_id,
        }),
        "goal_iteration" => Some(AgentEvent::GoalIteration {
            iteration: event
                .metadata
                .as_object()
                .and_then(|m| m.get("iteration"))
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u32,
            objective: event.content.clone(),
            mission_id,
        }),
        "goal_status" => Some(AgentEvent::GoalStatus {
            status: event
                .metadata
                .as_object()
                .and_then(|m| m.get("status"))
                .and_then(|v| v.as_str())
                .unwrap_or("active")
                .to_string(),
            objective: event.content.clone(),
            mission_id,
        }),
        _ => None,
    }
}

pub(super) async fn send_ws_json<T: Serialize>(
    sender: &mut futures::stream::SplitSink<WebSocket, WsMessage>,
    value: &T,
) -> bool {
    match serde_json::to_string(value) {
        Ok(payload) => sender.send(WsMessage::Text(payload)).await.is_ok(),
        Err(err) => {
            tracing::warn!(error = %err, "Failed to serialize control WebSocket payload");
            true
        }
    }
}

pub async fn control_ws(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    axum::extract::Query(query): axum::extract::Query<StreamQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    ws.on_upgrade(move |socket| control_ws_loop(state, user, query.mission, socket))
}

pub(super) async fn control_ws_loop(
    state: Arc<AppState>,
    user: AuthUser,
    mission_filter: Option<Uuid>,
    socket: WebSocket,
) {
    let control = control_for_user(&state, &user).await;
    let mut rx = control.events_tx.subscribe();
    let mut mission_rx = if let Some(mid) = mission_filter {
        let mut map = control.mission_channels.write().await;
        let entry = map.entry(mid).or_insert_with(|| {
            let (tx, _rx) = broadcast::channel::<AgentEvent>(8192);
            tx
        });
        Some(entry.subscribe())
    } else {
        None
    };
    let ws_id = Uuid::new_v4();
    tracing::info!(
        ws_id = %ws_id,
        user_id = %user.id,
        username = %user.username,
        mission_filter = ?mission_filter,
        "Control WebSocket opened"
    );

    let initial = control.status.read().await.clone();
    let (mut sender, mut receiver) = socket.split();
    let mut latest_seq = match mission_filter {
        Some(mid) => control
            .mission_store
            .max_event_sequence(mid)
            .await
            .unwrap_or(0),
        None => 0,
    };
    let mut text_op_buffers: HashMap<Uuid, String> = HashMap::new();
    let initial_status = AgentEvent::Status {
        state: initial.state,
        queue_len: initial.queue_len,
        mission_id: initial.mission_id,
    };
    if !send_ws_json(&mut sender, &initial_status).await {
        return;
    }

    let mut heartbeat_interval = tokio::time::interval(std::time::Duration::from_secs(15));
    heartbeat_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut shutdown_check_interval = tokio::time::interval(std::time::Duration::from_secs(1));
    shutdown_check_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            _ = shutdown_check_interval.tick() => {
                if super::super::routes::is_shutdown_initiated() {
                    break;
                }
            }
            _ = heartbeat_interval.tick() => {
                if let Some(mid) = mission_filter {
                    latest_seq = control.mission_store.max_event_sequence(mid).await.unwrap_or(latest_seq);
                }
                if !send_ws_json(&mut sender, &ControlWsHeartbeat { seq: latest_seq }).await {
                    break;
                }
            }
            client_msg = receiver.next() => {
                match client_msg {
                    Some(Ok(WsMessage::Text(text))) => {
                        match serde_json::from_str::<ControlWsClientMessage>(&text) {
                            Ok(ControlWsClientMessage::Resume { since_seq }) => {
                                if let Some(mid) = mission_filter {
                                    match control.mission_store.get_events_since(mid, since_seq, None, None).await {
                                        Ok(events) => {
                                            for event in events {
                                                latest_seq = latest_seq.max(event.sequence);
                                                if let Some(agent_event) = stored_event_to_agent_event(&event) {
                                                    let outbound = text_op_events_for_stream(agent_event, &mut text_op_buffers);
                                                    for agent_event in outbound {
                                                        if !send_ws_json(&mut sender, &agent_event).await {
                                                            return;
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        Err(err) => {
                                            let error = AgentEvent::Error {
                                                message: format!("Failed to resume stream: {err}"),
                                                mission_id: Some(mid),
                                                resumable: true,
                                            };
                                            if !send_ws_json(&mut sender, &error).await {
                                                return;
                                            }
                                        }
                                    }
                                }
                            }
                            Err(err) => {
                                tracing::debug!(ws_id = %ws_id, error = %err, "Ignoring malformed control WebSocket client message");
                            }
                        }
                    }
                    Some(Ok(WsMessage::Close(_))) | None => break,
                    Some(Ok(_)) => {}
                    Some(Err(err)) => {
                        tracing::warn!(ws_id = %ws_id, error = %err, "Control WebSocket receive error");
                        break;
                    }
                }
            }
            ev_result = async {
                match mission_rx.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => std::future::pending().await,
                }
            }, if mission_rx.is_some() => {
                match ev_result {
                    Ok(ev) => {
                        if let Some(mid) = ev.mission_id() {
                            latest_seq = control.mission_store.max_event_sequence(mid).await.unwrap_or(latest_seq);
                        }
                        let outbound = text_op_events_for_stream(ev, &mut text_op_buffers);
                        for ev in outbound {
                            if !send_ws_json(&mut sender, &ev).await {
                                return;
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
            result = rx.recv() => {
                match result {
                    Ok(ev) => {
                        let mission_id = ev.mission_id();
                        if mission_rx.is_some() {
                            let is_status = matches!(&ev, AgentEvent::Status { .. });
                            let is_fido = matches!(&ev, AgentEvent::FidoSignRequest { .. });
                            if !is_status && !is_fido {
                                continue;
                            }
                        } else if let Some(filter) = mission_filter {
                            let is_status = matches!(&ev, AgentEvent::Status { .. });
                            if !is_status && mission_id != Some(filter) {
                                continue;
                            }
                        }
                        if let Some(mid) = mission_id {
                            latest_seq = control.mission_store.max_event_sequence(mid).await.unwrap_or(latest_seq);
                        }
                        let outbound = text_op_events_for_stream(ev, &mut text_op_buffers);
                        for ev in outbound {
                            if !send_ws_json(&mut sender, &ev).await {
                                return;
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }

    tracing::info!(
        ws_id = %ws_id,
        user_id = %user.id,
        username = %user.username,
        "Control WebSocket closed"
    );
}

pub async fn stream(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    axum::extract::Query(query): axum::extract::Query<StreamQuery>,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let presentation = query.profile.as_deref() == Some("presentation");
    let mission_filter = query.mission;
    // Clients also send kinds=mission_presentation: older servers then send
    // no mission payloads instead of silently falling back to a full stream.
    let kinds_filter = if presentation {
        None
    } else {
        parse_stream_kinds(query.kinds.as_deref())
    };
    // P3-#20: when a mission filter is set, subscribe to that mission's
    // dedicated channel — the fan-out task in spawn_control_session
    // mirrors events from the global tx into per-mission txs. Avoids
    // every connected SSE client iterating all events for missions
    // they don't care about. Status events are connection-scoped so we
    // *also* subscribe to the global channel and merge both streams
    // for the duration of the connection.
    let mut rx = control.events_tx.subscribe();
    let mut mission_rx = if let Some(mid) = mission_filter {
        let mut map = control.mission_channels.write().await;
        let entry = map.entry(mid).or_insert_with(|| {
            let (tx, _rx) = broadcast::channel::<AgentEvent>(8192);
            tx
        });
        Some(entry.subscribe())
    } else {
        None
    };
    let stream_id = Uuid::new_v4();
    tracing::info!(
        stream_id = %stream_id,
        user_id = %user.id,
        username = %user.username,
        mission_filter = ?mission_filter,
        "Control SSE stream opened"
    );

    // Emit an initial status snapshot immediately.
    let initial = control.status.read().await.clone();

    struct StreamDropGuard {
        stream_id: Uuid,
        user_id: String,
        username: String,
    }

    impl Drop for StreamDropGuard {
        fn drop(&mut self) {
            tracing::info!(
                stream_id = %self.stream_id,
                user_id = %self.user_id,
                username = %self.username,
                "Control SSE stream closed"
            );
        }
    }

    let drop_guard = StreamDropGuard {
        stream_id,
        user_id: user.id.clone(),
        username: user.username.clone(),
    };

    // Clone the metrics Arc into the stream closure so we can record
    // each delivered chunk + per-mission broadcast count (P0-#3).
    let metrics = state.control_metrics.clone();

    let stream = async_stream::stream! {
        let _guard = drop_guard;
        match Event::default().event("status").json_data(AgentEvent::Status {
            state: initial.state,
            queue_len: initial.queue_len,
            mission_id: initial.mission_id,
        }) {
            Ok(init_ev) => yield Ok(init_ev),
            Err(e) => {
                tracing::error!("Failed to serialize initial SSE status event: {e}");
            }
        }

        // Keepalive interval to prevent connection timeouts during long LLM calls.
        let mut keepalive_interval = tokio::time::interval(std::time::Duration::from_secs(15));
        keepalive_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut shutdown_check_interval = tokio::time::interval(std::time::Duration::from_secs(1));
        shutdown_check_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut text_op_buffers: HashMap<Uuid, String> = HashMap::new();
        let mut activity_sent: HashMap<Uuid, std::time::Instant> = HashMap::new();

        loop {
            tokio::select! {
                _ = shutdown_check_interval.tick() => {
                    if super::super::routes::is_shutdown_initiated() {
                        tracing::info!(
                            stream_id = %stream_id,
                            user_id = %user.id,
                            username = %user.username,
                            "Control SSE stream closing for graceful shutdown"
                        );
                        break;
                    }
                }
                // P3-#20: read from either the per-mission channel (when
                // a mission filter is set) or the global broadcast (when
                // it isn't). The select arm using `as_mut().unwrap()` is
                // guarded by the `if mission_rx.is_some()` precondition
                // so the unwrap can't panic; tokio::select treats false
                // preconditions as disabled arms.
                ev_result = async {
                    match mission_rx.as_mut() {
                        Some(rx) => rx.recv().await,
                        None => std::future::pending().await,
                    }
                }, if mission_rx.is_some() => {
                    match ev_result {
                        Ok(ev) => {
                            let mission_id = ev.mission_id();
                            if let Some(kinds) = kinds_filter.as_deref() {
                                if !stream_kind_matches(kinds, ev.event_name()) {
                                    continue;
                                }
                            }
                            // Per-mission channel only carries events that
                            // already match the filter (the fan-out task
                            // is the gate); no further filtering needed.
                            if presentation {
                                if let AgentEvent::MissionActivity { mission_id: Some(id), .. } = &ev {
                                    if activity_sent.get(id).is_some_and(|at| at.elapsed() < std::time::Duration::from_secs(1)) { continue; }
                                    if activity_sent.len() >= 512 { activity_sent.clear(); }
                                    activity_sent.insert(*id, std::time::Instant::now());
                                }
                                if let Some(hint) = presentation_hint(&ev) {
                                    if let Ok(payload) = serde_json::to_string(&hint) {
                                        metrics.record_sse_chunk(payload.len());
                                        yield Ok(Event::default().event("mission_presentation").data(payload));
                                    }
                                }
                                continue;
                            }
                            match &ev {
                                AgentEvent::Thinking { .. } => {
                                    tracing::trace!(
                                        stream_id = %stream_id,
                                        event = %ev.event_name(),
                                        mission_id = ?mission_id,
                                        "Control SSE event (per-mission)"
                                    );
                                }
                                _ => {
                                    tracing::debug!(
                                        stream_id = %stream_id,
                                        event = %ev.event_name(),
                                        mission_id = ?mission_id,
                                        "Control SSE event (per-mission)"
                                    );
                                }
                            }
                            let outbound = text_op_events_for_stream(ev, &mut text_op_buffers);
                            for ev in outbound {
                                match deferred_messages::stream_payload(&ev) {
                                    Ok(payload) => {
                                        metrics.record_sse_chunk(payload.len());
                                        metrics.record_broadcast(ev.mission_id());
                                        yield Ok(Event::default()
                                            .event(ev.event_name())
                                            .data(payload));
                                    }
                                    Err(e) => {
                                        tracing::error!(
                                            stream_id = %stream_id,
                                            event = %ev.event_name(),
                                            error = %e,
                                            "Failed to serialize SSE event; dropping"
                                        );
                                    }
                                }
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(dropped)) => {
                            metrics.record_broadcast_lag(dropped);
                            tracing::warn!(stream_id = %stream_id, dropped, "Per-mission SSE lagged");
                            match Event::default()
                                .event("stream_lagged")
                                .json_data(serde_json::json!({ "dropped": dropped }))
                            {
                                Ok(sse) => yield Ok(sse),
                                Err(_) => {}
                            }
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
                result = rx.recv() => {
                    match result {
                        Ok(ev) => {
                            let mission_id = ev.mission_id();
                            if let Some(kinds) = kinds_filter.as_deref() {
                                if !stream_kind_matches(kinds, ev.event_name()) {
                                    continue;
                                }
                            }
                            // When a per-mission channel is active, the
                            // global arm only forwards connection-scoped
                            // events (Status, FidoSignRequest). Per-mission
                            // payloads are delivered above via the dedicated
                            // channel.
                            if mission_rx.is_some() {
                                let is_status = matches!(&ev, AgentEvent::Status { .. });
                                let is_fido = matches!(&ev, AgentEvent::FidoSignRequest { .. });
                                if !is_status && !is_fido {
                                    continue;
                                }
                            } else if let Some(filter) = mission_filter {
                                // Fallback: per-mission channel not present
                                // (e.g. first-event race). Apply the P1-#4
                                // filter directly.
                                let is_status = matches!(&ev, AgentEvent::Status { .. });
                                if !is_status && mission_id != Some(filter) {
                                    continue;
                                }
                            }
                            if presentation {
                                if let AgentEvent::MissionActivity { mission_id: Some(id), .. } = &ev {
                                    if activity_sent.get(id).is_some_and(|at| at.elapsed() < std::time::Duration::from_secs(1)) { continue; }
                                    if activity_sent.len() >= 512 { activity_sent.clear(); }
                                    activity_sent.insert(*id, std::time::Instant::now());
                                }
                                if let Some(hint) = presentation_hint(&ev) {
                                    if let Ok(payload) = serde_json::to_string(&hint) {
                                        metrics.record_sse_chunk(payload.len());
                                        yield Ok(Event::default().event("mission_presentation").data(payload));
                                    }
                                }
                                continue;
                            }
                            match &ev {
                                AgentEvent::Thinking { .. } => {
                                    tracing::trace!(
                                        stream_id = %stream_id,
                                        event = %ev.event_name(),
                                        mission_id = ?mission_id,
                                        "Control SSE event"
                                    );
                                }
                                _ => {
                                    tracing::debug!(
                                        stream_id = %stream_id,
                                        event = %ev.event_name(),
                                        mission_id = ?mission_id,
                                        "Control SSE event"
                                    );
                                }
                            }
                            // Serialize once so we can both ship the SSE
                            // frame and record an accurate byte count for
                            // the metrics endpoint (P0-#3). The payload
                            // size approximates the on-the-wire chunk
                            // length closely enough for p50/p99 use.
                            let outbound = text_op_events_for_stream(ev, &mut text_op_buffers);
                            for ev in outbound {
                                match deferred_messages::stream_payload(&ev) {
                                    Ok(payload) => {
                                        metrics.record_sse_chunk(payload.len());
                                        metrics.record_broadcast(ev.mission_id());
                                        yield Ok(Event::default()
                                            .event(ev.event_name())
                                            .data(payload));
                                    }
                                    Err(e) => {
                                        tracing::error!(
                                            stream_id = %stream_id,
                                            event = %ev.event_name(),
                                            error = %e,
                                            "Failed to serialize SSE event; dropping"
                                        );
                                    }
                                }
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(dropped)) => {
                            metrics.record_broadcast_lag(dropped);
                            // This receiver's cursor slipped behind the
                            // broadcast buffer's tail by `dropped` events.
                            // The stream itself is still alive — `recv()`
                            // will keep yielding fresh events on the next
                            // tick — so we deliberately don't emit an
                            // `error` event here. The dashboard treats
                            // `error` as fatal (red toast + system-error
                            // row in the chat) and it caused a confusing
                            // user-facing alert every time a chatty
                            // mission (text_delta burst, big tool result)
                            // outpaced the browser tab's event handler.
                            //
                            // Instead, emit a distinct `stream_lagged`
                            // event with the dropped count. The dashboard
                            // reacts by silently refetching the viewing
                            // mission via the existing `since_seq` path
                            // so any dropped events are recovered from
                            // the database. No user toast, no chat
                            // pollution.
                            tracing::warn!(
                                stream_id = %stream_id,
                                dropped = dropped,
                                "Control SSE stream lagged; signalling client refetch"
                            );
                            match Event::default()
                                .event("stream_lagged")
                                .json_data(serde_json::json!({ "dropped": dropped }))
                            {
                                Ok(sse) => yield Ok(sse),
                                Err(e) => {
                                    tracing::error!(
                                        stream_id = %stream_id,
                                        error = %e,
                                        "Failed to serialize SSE stream_lagged event"
                                    );
                                }
                            }
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
                _ = keepalive_interval.tick() => {
                    // Send SSE comment as keepalive (: comment\n\n)
                    let sse = Event::default().comment("keepalive");
                    yield Ok(sse);
                }
            }
        }
    };

    Ok(Sse::new(stream).keep_alive(
        axum::response::sse::KeepAlive::new()
            .interval(std::time::Duration::from_secs(15))
            .text("keepalive"),
    ))
}

#[cfg(test)]
mod presentation_tests {
    use super::*;
    #[test]
    fn legacy_android_filter_is_not_silently_ignored() {
        let id = Uuid::new_v4();
        let query: StreamQuery =
            serde_json::from_value(serde_json::json!({"mission_id":id})).unwrap();
        assert_eq!(query.mission, Some(id));
    }
    #[test]
    fn offscreen_hints_exclude_heavy_payloads_and_bound_labels() {
        let id = Some(Uuid::new_v4());
        assert!(presentation_hint(&AgentEvent::TextDelta {
            content: "private text".into(),
            mission_id: id
        })
        .is_none());
        assert!(presentation_hint(&AgentEvent::ToolResult {
            tool_call_id: "a".into(),
            name: "read".into(),
            result: serde_json::json!({"output":"private output"}),
            mission_id: id
        })
        .is_none());
        let hint = presentation_hint(&AgentEvent::MissionActivity {
            label: "x".repeat(10000),
            tool_name: "read".into(),
            mission_id: id,
        })
        .unwrap();
        assert_eq!(hint["label"].as_str().unwrap().len(), 160);
        assert!(hint.to_string().len() < 512);
    }
}
