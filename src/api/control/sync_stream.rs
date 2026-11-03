//! Single multiplexed control WebSocket (`/api/control/sync`).
//!
//! Replaces N separate per-mission SSE streams + 1 offscreen presentation SSE
//! stream with a single heartbeat-monitored WebSocket per client:
//! - Authenticates via either `Authorization: Bearer <jwt>` (native iOS/Android
//!   clients) or `Sec-WebSocket-Protocol: orb-sync.v1, jwt.<jwt>` (browser /
//!   WKWebView `new WebSocket(...)`), plus loopback `dev_mode`.
//! - Carries offscreen `mission_presentation` hints (throttled to <= 1/s per
//!   mission), connection-scoped `status`, `fido_sign_request`, and dynamic
//!   per-mission `subscribe` / `unsubscribe` channels with `since_seq` replay.
//! - Sends server `heartbeat` frames every 10s and answers client `ping` frames
//!   with `pong` immediately so clients detect half-open NAT/Wi-Fi blackholes
//!   within seconds instead of waiting on TCP timeouts.

use super::*;
use crate::api::auth;

const SYNC_SUBPROTOCOL: &str = "orb-sync.v1";
const MAX_SUBSCRIPTIONS_PER_SOCKET: usize = 64;
const SYNC_REPLAY_LIMIT: usize = 500;
const HEARTBEAT_INTERVAL_SECS: u64 = 10;

#[derive(Debug, Default, Deserialize)]
pub struct ControlSyncQuery {
    /// Whether offscreen `mission_presentation` hints start enabled (default `true`).
    #[serde(default)]
    pub presentation: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum SyncClientMessage {
    Subscribe {
        mission_id: Uuid,
        #[serde(default)]
        since_seq: Option<i64>,
    },
    Unsubscribe {
        mission_id: Uuid,
    },
    SetPresentation {
        enabled: bool,
    },
    Ping {
        #[serde(default)]
        ts: Option<i64>,
    },
}

fn sync_presentation_hint(event: &AgentEvent) -> Option<serde_json::Value> {
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
    Some(serde_json::json!({
        "type": "mission_presentation",
        "mission_id": mission_id,
        "kind": event.event_name(),
        "label": label,
    }))
}

fn authenticate_sync_upgrade(
    headers: &HeaderMap,
    config: &Config,
) -> Result<(AuthUser, bool), (StatusCode, &'static str)> {
    let offered_sync_proto = headers
        .get("sec-websocket-protocol")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|raw| {
            raw.split(',')
                .any(|part| part.trim().eq_ignore_ascii_case(SYNC_SUBPROTOCOL))
        });

    if let Some(bearer) = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|raw| {
            raw.strip_prefix("Bearer ")
                .or_else(|| raw.strip_prefix("bearer "))
        })
        .map(str::trim)
        .filter(|tok| !tok.is_empty())
    {
        let user = auth::authenticate_token(config, bearer)?;
        return Ok((user, offered_sync_proto));
    }

    match auth::authenticate_websocket_protocols(headers, config)? {
        Some(token) => {
            let user = auth::authenticate_token(config, &token)?;
            Ok((user, offered_sync_proto))
        }
        None => Ok((
            auth::implicit_single_tenant_user(config),
            offered_sync_proto,
        )),
    }
}

pub async fn control_sync_ws(
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
    axum::extract::Query(query): axum::extract::Query<ControlSyncQuery>,
    headers: HeaderMap,
) -> Response {
    let (user, echo_proto) = match authenticate_sync_upgrade(&headers, &state.config) {
        Ok(ok) => ok,
        Err((status, message)) => return (status, message).into_response(),
    };
    let initial_presentation = query.presentation.unwrap_or(true);
    let ws = if echo_proto {
        ws.protocols([SYNC_SUBPROTOCOL])
    } else {
        ws
    };
    ws.on_upgrade(move |socket| control_sync_loop(state, user, initial_presentation, socket))
}

async fn send_raw_text(
    sender: &mut futures::stream::SplitSink<WebSocket, WsMessage>,
    metrics: &crate::api::control_metrics::ControlMetrics,
    payload: String,
) -> bool {
    metrics.record_sse_chunk(payload.len());
    sender.send(WsMessage::Text(payload)).await.is_ok()
}

async fn send_agent_event_frame(
    sender: &mut futures::stream::SplitSink<WebSocket, WsMessage>,
    metrics: &crate::api::control_metrics::ControlMetrics,
    ev: &AgentEvent,
    seq_override: Option<i64>,
) -> bool {
    let Ok(raw) = deferred_messages::stream_payload(ev) else {
        return true;
    };
    let payload = if let Some(seq) = seq_override {
        if let Ok(mut value) = serde_json::from_str::<serde_json::Value>(&raw) {
            if let Some(obj) = value.as_object_mut() {
                obj.entry("sequence".to_string())
                    .or_insert_with(|| serde_json::json!(seq));
            }
            serde_json::to_string(&value).unwrap_or(raw)
        } else {
            raw
        }
    } else {
        raw
    };
    metrics.record_broadcast(ev.mission_id());
    send_raw_text(sender, metrics, payload).await
}

async fn control_sync_loop(
    state: Arc<AppState>,
    user: AuthUser,
    mut presentation_enabled: bool,
    socket: WebSocket,
) {
    let control = control_for_user(&state, &user).await;
    let mut global_rx = control.events_tx.subscribe();
    let sync_id = Uuid::new_v4();
    tracing::info!(
        sync_id = %sync_id,
        user_id = %user.id,
        username = %user.username,
        presentation = presentation_enabled,
        "Control multiplexed sync WebSocket opened"
    );

    let metrics = state.control_metrics.clone();
    let initial = control.status.read().await.clone();
    let (mut sender, mut receiver) = socket.split();

    let ready_frame = serde_json::json!({
        "type": "sync_ready",
        "protocol": SYNC_SUBPROTOCOL,
        "heartbeat_secs": HEARTBEAT_INTERVAL_SECS,
        "presentation": presentation_enabled,
    });
    if !send_raw_text(&mut sender, &metrics, ready_frame.to_string()).await {
        return;
    }

    let initial_status = AgentEvent::Status {
        state: initial.state,
        queue_len: initial.queue_len,
        mission_id: initial.mission_id,
    };
    if !send_agent_event_frame(&mut sender, &metrics, &initial_status, None).await {
        return;
    }

    let mut subscribed_missions: HashSet<Uuid> = HashSet::new();
    let mut text_op_buffers: HashMap<Uuid, String> = HashMap::new();
    let mut activity_sent: HashMap<Uuid, std::time::Instant> = HashMap::new();

    let mut heartbeat_interval =
        tokio::time::interval(std::time::Duration::from_secs(HEARTBEAT_INTERVAL_SECS));
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
                let hb = serde_json::json!({
                    "type": "heartbeat",
                    "ts": chrono::Utc::now().timestamp_millis(),
                });
                if !send_raw_text(&mut sender, &metrics, hb.to_string()).await {
                    break;
                }
            }
            client_msg = receiver.next() => {
                match client_msg {
                    Some(Ok(WsMessage::Text(text))) => {
                        match serde_json::from_str::<SyncClientMessage>(&text) {
                            Ok(SyncClientMessage::Ping { ts }) => {
                                let pong = serde_json::json!({
                                    "type": "pong",
                                    "ts": ts,
                                    "server_ts": chrono::Utc::now().timestamp_millis(),
                                });
                                if !send_raw_text(&mut sender, &metrics, pong.to_string()).await {
                                    break;
                                }
                            }
                            Ok(SyncClientMessage::SetPresentation { enabled }) => {
                                presentation_enabled = enabled;
                            }
                            Ok(SyncClientMessage::Unsubscribe { mission_id }) => {
                                subscribed_missions.remove(&mission_id);
                                text_op_buffers.remove(&mission_id);
                                let ack = serde_json::json!({
                                    "type": "unsubscribed",
                                    "mission_id": mission_id,
                                });
                                if !send_raw_text(&mut sender, &metrics, ack.to_string()).await {
                                    break;
                                }
                            }
                            Ok(SyncClientMessage::Subscribe { mission_id, since_seq }) => {
                                if !subscribed_missions.contains(&mission_id)
                                    && subscribed_missions.len() >= MAX_SUBSCRIPTIONS_PER_SOCKET
                                {
                                    let err_frame = serde_json::json!({
                                        "type": "sync_error",
                                        "mission_id": mission_id,
                                        "message": "Maximum concurrent mission subscriptions reached",
                                    });
                                    if !send_raw_text(&mut sender, &metrics, err_frame.to_string()).await {
                                        break;
                                    }
                                    continue;
                                }
                                subscribed_missions.insert(mission_id);
                                text_op_buffers.remove(&mission_id);

                                let ack = serde_json::json!({
                                    "type": "subscribed",
                                    "mission_id": mission_id,
                                });
                                if !send_raw_text(&mut sender, &metrics, ack.to_string()).await {
                                    break;
                                }

                                if let Some(seq) = since_seq.filter(|&s| s >= 0) {
                                    match control
                                        .mission_store
                                        .get_events_since(
                                            mission_id,
                                            seq,
                                            None,
                                            Some(SYNC_REPLAY_LIMIT + 1),
                                        )
                                        .await
                                    {
                                        Ok(replayed) if replayed.len() > SYNC_REPLAY_LIMIT => {
                                            let lagged = serde_json::json!({
                                                "type": "stream_lagged",
                                                "mission_id": mission_id,
                                                "dropped": replayed.len(),
                                            });
                                            if !send_raw_text(&mut sender, &metrics, lagged.to_string()).await {
                                                break;
                                            }
                                        }
                                        Ok(replayed) => {
                                            for stored in replayed {
                                                let row_seq = stored.sequence;
                                                let Some(agent_ev) =
                                                    streaming::stored_event_to_agent_event(&stored)
                                                else {
                                                    continue;
                                                };
                                                let outbound = streaming::text_op_events_for_stream(
                                                    agent_ev,
                                                    &mut text_op_buffers,
                                                );
                                                for ev in outbound {
                                                    if !send_agent_event_frame(
                                                        &mut sender,
                                                        &metrics,
                                                        &ev,
                                                        Some(row_seq),
                                                    )
                                                    .await
                                                    {
                                                        return;
                                                    }
                                                }
                                            }
                                        }
                                        Err(err) => {
                                            tracing::warn!(
                                                sync_id = %sync_id,
                                                mission_id = %mission_id,
                                                since_seq = seq,
                                                error = %err,
                                                "Control sync replay failed; signalling lag"
                                            );
                                            let lagged = serde_json::json!({
                                                "type": "stream_lagged",
                                                "mission_id": mission_id,
                                                "dropped": 1,
                                            });
                                            if !send_raw_text(&mut sender, &metrics, lagged.to_string()).await {
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                            Err(err) => {
                                tracing::debug!(
                                    sync_id = %sync_id,
                                    error = %err,
                                    "Ignoring malformed control sync client message"
                                );
                            }
                        }
                    }
                    Some(Ok(WsMessage::Ping(payload))) => {
                        if sender.send(WsMessage::Pong(payload)).await.is_err() {
                            break;
                        }
                    }
                    Some(Ok(WsMessage::Close(_))) | None => break,
                    Some(Ok(_)) => {}
                    Some(Err(err)) => {
                        tracing::debug!(sync_id = %sync_id, error = %err, "Control sync WebSocket closed with error");
                        break;
                    }
                }
            }
            ev_res = global_rx.recv() => {
                match ev_res {
                    Ok(ev) => {
                        // Connection-scoped status & FIDO requests are always forwarded.
                        if matches!(&ev, AgentEvent::Status { .. } | AgentEvent::FidoSignRequest { .. }) {
                            if !send_agent_event_frame(&mut sender, &metrics, &ev, None).await {
                                break;
                            }
                            continue;
                        }

                        let Some(mid) = ev.mission_id() else {
                            continue;
                        };

                        // Forward presentation hint when enabled (throttled to 1/s for MissionActivity).
                        if presentation_enabled {
                            let throttle = if matches!(&ev, AgentEvent::MissionActivity { .. }) {
                                if activity_sent
                                    .get(&mid)
                                    .is_some_and(|at| at.elapsed() < std::time::Duration::from_secs(1))
                                {
                                    true
                                } else {
                                    if activity_sent.len() >= 512 {
                                        activity_sent.clear();
                                    }
                                    activity_sent.insert(mid, std::time::Instant::now());
                                    false
                                }
                            } else {
                                false
                            };
                            if !throttle {
                                if let Some(hint) = sync_presentation_hint(&ev) {
                                    if !send_raw_text(&mut sender, &metrics, hint.to_string()).await {
                                        break;
                                    }
                                }
                            }
                        }

                        // Forward full event stream for subscribed missions.
                        if subscribed_missions.contains(&mid) {
                            let outbound =
                                streaming::text_op_events_for_stream(ev, &mut text_op_buffers);
                            for out_ev in outbound {
                                if !send_agent_event_frame(&mut sender, &metrics, &out_ev, None).await {
                                    return;
                                }
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(dropped)) => {
                        metrics.record_broadcast_lag(dropped);
                        let lagged = serde_json::json!({
                            "type": "stream_lagged",
                            "dropped": dropped,
                        });
                        if !send_raw_text(&mut sender, &metrics, lagged.to_string()).await {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }

    tracing::info!(
        sync_id = %sync_id,
        user_id = %user.id,
        username = %user.username,
        "Control multiplexed sync WebSocket closed"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    #[test]
    fn authenticate_sync_upgrade_accepts_bearer_or_subprotocol_jwt() {
        let dir = tempfile::tempdir().unwrap();
        let mut cfg = Config::new(dir.path().to_path_buf());
        cfg.dev_mode = false;
        cfg.auth.jwt_secret = Some("test-sync-jwt-secret-0123456789abcdef".to_string());
        cfg.auth.dashboard_password = Some("pw".to_string());
        let expected_user = AuthUser {
            id: "default".to_string(),
            username: "thomas".to_string(),
        };
        let (jwt, _) =
            auth::issue_jwt(cfg.auth.jwt_secret.as_deref().unwrap(), 1, &expected_user).unwrap();

        // 1. Authorization: Bearer <jwt> (native mobile/CLI clients)
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {jwt}")).unwrap(),
        );
        let (u1, echo1) = authenticate_sync_upgrade(&headers, &cfg).unwrap();
        assert_eq!(u1.id, "default");
        assert!(!echo1);

        // 2. Sec-WebSocket-Protocol: orb-sync.v1, jwt.<token> (browser / Tauri WebView)
        let mut ws_headers = HeaderMap::new();
        ws_headers.insert(
            "sec-websocket-protocol",
            HeaderValue::from_str(&format!("orb-sync.v1, jwt.{jwt}")).unwrap(),
        );
        let (u2, echo2) = authenticate_sync_upgrade(&ws_headers, &cfg).unwrap();
        assert_eq!(u2.id, "default");
        assert!(echo2);

        // 3. Missing credentials rejected with 401
        let empty = HeaderMap::new();
        let err = authenticate_sync_upgrade(&empty, &cfg).unwrap_err();
        assert_eq!(err.0, StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn sync_presentation_hint_strips_sensitive_payloads() {
        let mid = Uuid::new_v4();
        let act = AgentEvent::MissionActivity {
            mission_id: Some(mid),
            label: "Running cargo test".to_string(),
            tool_name: String::new(),
        };
        let hint = sync_presentation_hint(&act).expect("activity produces presentation hint");
        assert_eq!(hint["type"], "mission_presentation");
        assert_eq!(hint["mission_id"], mid.to_string());
        assert_eq!(hint["kind"], "mission_activity");
        assert_eq!(hint["label"], "Running cargo test");

        // ToolCall carries arguments and must never be emitted as an offscreen hint.
        let tool = AgentEvent::ToolCall {
            tool_call_id: "tc-1".to_string(),
            name: "bash".to_string(),
            args: serde_json::json!({"cmd": "secret"}),
            mission_id: Some(mid),
        };
        assert!(sync_presentation_hint(&tool).is_none());
    }
}
