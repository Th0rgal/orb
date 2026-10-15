//! Client link: one outbound WebSocket from an Orb install to core.
//!
//! Orb streams the full event log of the missions it runs locally, so every
//! other client (iOS, dashboard, another Orb) sees them through the normal
//! `/api/control/stream` and `/api/control/ws` channels. Core is the record:
//! every event is persisted before it is acknowledged, and the per-client
//! cursor makes replay after a disconnect exact (no loss, no duplicates).
//!
//! Protocol (JSON text frames, tagged by `type`):
//! - client → core: `hello {client_id}` (first frame), `event {mission_id,
//!   run_id, generation, seq, event}`, `cursor {mission_id}`, `ping`.
//! - core → client: `welcome`, `ack {mission_id, seq}`, `gap {mission_id,
//!   expected}`, `rejected {mission_id, seq, reason}` (permanent),
//!   `retry {mission_id, seq, reason}` (transient), `cursor {mission_id,
//!   last_seq}`, `pong`.
//!
//! Sequences start at 1 per (mission, client) and must be contiguous. Each
//! event carries the run receipt it belongs to; events from a superseded run
//! are rejected so a stale runner cannot write into the current transcript.
use super::*;
use crate::api::mission_store::{ClientIngest, MissionStore, CLIENT_LINK_UNSUPPORTED};
use axum::extract::ws::{Message as WsMessage, WebSocket, WebSocketUpgrade};
use std::sync::{Mutex as StdMutex, OnceLock};
use std::time::{Duration, Instant};

/// A client with no frame for this long is shown as offline (mission paused).
pub const OFFLINE_AFTER: Duration = Duration::from_secs(45);
const MAX_FRAME_BYTES: usize = 4 * 1024 * 1024;

/// Events an Orb client may contribute. Deliberately narrower than
/// `AgentEvent`: status, settings, titles and signing requests stay
/// core-owned, and the mission id always comes from the frame.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientEvent {
    UserMessage {
        id: Uuid,
        content: String,
    },
    AssistantMessage {
        id: Uuid,
        content: String,
        #[serde(default = "yes")]
        success: bool,
        #[serde(default)]
        model: Option<String>,
    },
    Thinking {
        content: String,
        #[serde(default)]
        done: bool,
    },
    TextDelta {
        content: String,
    },
    TextOp {
        bubble_id: String,
        ops: Vec<TextOp>,
    },
    ToolCall {
        tool_call_id: String,
        name: String,
        #[serde(default)]
        args: serde_json::Value,
    },
    ToolResult {
        tool_call_id: String,
        name: String,
        #[serde(default)]
        result: serde_json::Value,
    },
    Error {
        message: String,
        #[serde(default)]
        resumable: bool,
    },
    AgentPhase {
        phase: String,
        #[serde(default)]
        detail: Option<String>,
        #[serde(default)]
        agent: Option<String>,
    },
    MissionActivity {
        label: String,
        tool_name: String,
    },
}

fn yes() -> bool {
    true
}

impl ClientEvent {
    pub fn into_agent_event(self, mission_id: Uuid, client_id: &str) -> AgentEvent {
        let mid = Some(mission_id);
        match self {
            ClientEvent::UserMessage { id, content } => AgentEvent::UserMessage {
                id,
                content,
                queued: false,
                mission_id: mid,
                source: Some(format!("orb-client:{client_id}")),
            },
            ClientEvent::AssistantMessage {
                id,
                content,
                success,
                model,
            } => AgentEvent::AssistantMessage {
                id,
                content,
                success,
                cost_cents: 0,
                cost_source: crate::agents::CostSource::Unknown,
                usage: None,
                model,
                model_normalized: None,
                mission_id: mid,
                shared_files: None,
                resumable: false,
                completion_evidence: None,
            },
            ClientEvent::Thinking { content, done } => AgentEvent::Thinking {
                content,
                done,
                mission_id: mid,
            },
            ClientEvent::TextDelta { content } => AgentEvent::TextDelta {
                content,
                mission_id: mid,
            },
            ClientEvent::TextOp { bubble_id, ops } => AgentEvent::TextOp {
                mission_id,
                bubble_id,
                ops,
            },
            ClientEvent::ToolCall {
                tool_call_id,
                name,
                args,
            } => AgentEvent::ToolCall {
                tool_call_id,
                name,
                args,
                mission_id: mid,
            },
            ClientEvent::ToolResult {
                tool_call_id,
                name,
                result,
            } => AgentEvent::ToolResult {
                tool_call_id,
                name,
                result,
                mission_id: mid,
            },
            ClientEvent::Error { message, resumable } => AgentEvent::Error {
                message,
                mission_id: mid,
                resumable,
            },
            ClientEvent::AgentPhase {
                phase,
                detail,
                agent,
            } => AgentEvent::AgentPhase {
                phase,
                detail,
                agent,
                mission_id: mid,
            },
            ClientEvent::MissionActivity { label, tool_name } => AgentEvent::MissionActivity {
                label,
                tool_name,
                mission_id: mid,
            },
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Inbound {
    Hello { client_id: String },
    Event(EventFrame),
    Cursor { mission_id: Uuid },
    Ping,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Reply {
    Welcome {
        client_id: String,
    },
    Ack {
        mission_id: Uuid,
        seq: u64,
    },
    Gap {
        mission_id: Uuid,
        expected: u64,
    },
    Rejected {
        mission_id: Uuid,
        seq: u64,
        reason: String,
    },
    Retry {
        mission_id: Uuid,
        seq: u64,
        reason: String,
    },
    Cursor {
        mission_id: Uuid,
        last_seq: u64,
    },
    Pong,
}

// === Presence ===

#[derive(Debug, Clone, Serialize)]
pub struct Presence {
    pub client_id: String,
    pub online: bool,
    pub connected_at: String,
    pub last_seen_at: String,
}

struct Link {
    conn_id: Uuid,
    connected_at: String,
    last_seen_at: String,
    last_seen: Instant,
}

type Registry = StdMutex<HashMap<(String, String), Link>>;

fn registry() -> &'static Registry {
    static R: OnceLock<Registry> = OnceLock::new();
    R.get_or_init(Default::default)
}

/// Register a new socket for this install; it replaces any older one.
fn register(user_id: &str, client_id: &str, conn_id: Uuid) {
    let now = crate::api::mission_store::now_string();
    registry().lock().expect("client link registry").insert(
        (user_id.into(), client_id.into()),
        Link {
            conn_id,
            connected_at: now.clone(),
            last_seen_at: now,
            last_seen: Instant::now(),
        },
    );
}

/// Refresh liveness, but only for the current socket: a superseded socket
/// that is still draining must not reclaim the registration.
fn touch(user_id: &str, client_id: &str, conn_id: Uuid) {
    let mut map = registry().lock().expect("client link registry");
    if let Some(link) = map
        .get_mut(&(user_id.to_string(), client_id.to_string()))
        .filter(|link| link.conn_id == conn_id)
    {
        link.last_seen_at = crate::api::mission_store::now_string();
        link.last_seen = Instant::now();
    }
}

fn drop_link(user_id: &str, client_id: &str, conn_id: Uuid) {
    let mut map = registry().lock().expect("client link registry");
    let key = (user_id.to_string(), client_id.to_string());
    if map.get(&key).is_some_and(|l| l.conn_id == conn_id) {
        map.remove(&key);
    }
}

pub fn presence(user_id: &str, client_id: &str) -> Presence {
    let map = registry().lock().expect("client link registry");
    match map.get(&(user_id.to_string(), client_id.to_string())) {
        Some(l) => Presence {
            client_id: client_id.into(),
            online: l.last_seen.elapsed() < OFFLINE_AFTER,
            connected_at: l.connected_at.clone(),
            last_seen_at: l.last_seen_at.clone(),
        },
        None => Presence {
            client_id: client_id.into(),
            online: false,
            connected_at: String::new(),
            last_seen_at: String::new(),
        },
    }
}

// === Ingest ===

/// One `event` frame from the client.
#[derive(Debug, Deserialize)]
pub struct EventFrame {
    pub mission_id: Uuid,
    pub run_id: Uuid,
    pub generation: u64,
    pub seq: u64,
    pub event: serde_json::Value,
}

/// Persist then publish one client event. The event and its cursor commit in
/// one transaction, so an acknowledged event is durable and a replay is never
/// stored twice.
pub async fn ingest(
    store: &Arc<dyn MissionStore>,
    events_tx: &broadcast::Sender<AgentEvent>,
    client_id: &str,
    frame: EventFrame,
) -> Reply {
    let EventFrame {
        mission_id,
        run_id,
        generation,
        seq,
        event,
    } = frame;
    let retry = |reason: String| Reply::Retry {
        mission_id,
        seq,
        reason,
    };
    let reject = |reason: &str| Reply::Rejected {
        mission_id,
        seq,
        reason: reason.into(),
    };
    if seq == 0 {
        return reject("sequences start at 1");
    }
    match worker_location::resolved_client_owner(store, mission_id).await {
        Ok(Some(owner)) if owner == client_id => {}
        Ok(_) => return reject("mission is not run by this computer"),
        Err(e) => return retry(e),
    }
    let event: ClientEvent = match serde_json::from_value(event) {
        Ok(event) => event,
        Err(e) => return reject(&format!("unsupported event: {e}")),
    };
    let lock = worker_location::dispatch_lock(&format!("client-link:{mission_id}"));
    let _guard = lock.lock().await;
    // Fence under the lock: a stopped or transferred run cannot append.
    match machine_transfer::check_client_receipt_in(
        store,
        mission_id,
        Some(run_id),
        Some(generation),
    )
    .await
    {
        Ok(Some(_)) => {}
        Ok(None) => return reject("mission has no active local run"),
        Err((StatusCode::CONFLICT, reason)) => return reject(&reason),
        Err((_, reason)) => return retry(reason),
    }
    let event = event.into_agent_event(mission_id, client_id);
    match store
        .log_client_event(mission_id, client_id, seq, event.clone())
        .await
    {
        Ok(ClientIngest::Stored) => {
            let _ = events_tx.send(event);
            Reply::Ack { mission_id, seq }
        }
        Ok(ClientIngest::Duplicate) => Reply::Ack { mission_id, seq },
        Ok(ClientIngest::Gap { expected }) => Reply::Gap {
            mission_id,
            expected,
        },
        Err(e) if e == CLIENT_LINK_UNSUPPORTED => reject(&e),
        Err(e) => retry(e),
    }
}

// === HTTP ===

pub async fn client_link_ws(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    ws: WebSocketUpgrade,
) -> Response {
    ws.max_message_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| link_loop(state, user, socket))
}

/// Presence of the computer that runs a client-placed mission. Other clients
/// show the mission as paused while `online` is false.
pub async fn mission_client_presence(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let owner = worker_location::resolved_client_owner(&control.mission_store, id)
        .await
        .map_err(internal_error)?;
    let Some(owner) = owner else {
        return Ok(Json(serde_json::json!({ "client_placed": false })));
    };
    let p = presence(&user.id, &owner);
    Ok(Json(
        serde_json::json!({ "client_placed": true, "presence": p }),
    ))
}

async fn send(
    sender: &mut futures::stream::SplitSink<WebSocket, WsMessage>,
    reply: &Reply,
) -> bool {
    match serde_json::to_string(reply) {
        Ok(text) => sender.send(WsMessage::Text(text)).await.is_ok(),
        Err(_) => true,
    }
}

async fn link_loop(state: Arc<AppState>, user: AuthUser, socket: WebSocket) {
    let control = control_for_user(&state, &user).await;
    let (mut sender, mut receiver) = socket.split();
    let conn_id = Uuid::new_v4();

    // The first frame must identify the computer.
    let client_id = match tokio::time::timeout(Duration::from_secs(10), receiver.next()).await {
        Ok(Some(Ok(WsMessage::Text(text)))) => match serde_json::from_str::<Inbound>(&text) {
            Ok(Inbound::Hello { client_id }) if Uuid::parse_str(&client_id).is_ok() => client_id,
            _ => return,
        },
        _ => return,
    };
    register(&user.id, &client_id, conn_id);
    tracing::info!(%conn_id, user_id = %user.id, %client_id, "Client link opened");
    if !send(
        &mut sender,
        &Reply::Welcome {
            client_id: client_id.clone(),
        },
    )
    .await
    {
        drop_link(&user.id, &client_id, conn_id);
        return;
    }

    let mut ping = tokio::time::interval(Duration::from_secs(15));
    ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = ping.tick() => {
                if super::super::routes::is_shutdown_initiated() {
                    break;
                }
                if sender.send(WsMessage::Ping(Vec::new())).await.is_err() {
                    break;
                }
            }
            frame = receiver.next() => {
                let text = match frame {
                    Some(Ok(WsMessage::Text(text))) => text,
                    Some(Ok(WsMessage::Pong(_) | WsMessage::Ping(_))) => {
                        touch(&user.id, &client_id, conn_id);
                        continue;
                    }
                    Some(Ok(WsMessage::Binary(_))) => continue,
                    _ => break,
                };
                touch(&user.id, &client_id, conn_id);
                let reply = match serde_json::from_str::<Inbound>(&text) {
                    Ok(Inbound::Event(frame)) => {
                        ingest(&control.mission_store, &control.events_tx, &client_id, frame).await
                    }
                    Ok(Inbound::Cursor { mission_id }) => {
                        match control.mission_store.client_event_cursor(mission_id, &client_id).await {
                            Ok(last_seq) => Reply::Cursor { mission_id, last_seq },
                            Err(reason) if reason == CLIENT_LINK_UNSUPPORTED => Reply::Rejected { mission_id, seq: 0, reason },
                            Err(reason) => Reply::Retry { mission_id, seq: 0, reason },
                        }
                    }
                    Ok(Inbound::Ping) => Reply::Pong,
                    Ok(Inbound::Hello { .. }) | Err(_) => continue,
                };
                if !send(&mut sender, &reply).await {
                    break;
                }
            }
        }
    }
    drop_link(&user.id, &client_id, conn_id);
    tracing::info!(%conn_id, user_id = %user.id, %client_id, "Client link closed");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::mission_store::{now_string, SqliteMissionStore};
    use crate::local_origin::{Origin, Snapshot};

    struct Fixture {
        _temp: tempfile::TempDir,
        store: Arc<dyn MissionStore>,
        id: Uuid,
        run: Uuid,
        client: String,
    }

    async fn fixture() -> Fixture {
        let temp = tempfile::tempdir().unwrap();
        let store = SqliteMissionStore::new(temp.path().to_path_buf(), "client-link")
            .await
            .unwrap();
        let (client, id, run) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
        store
            .sync_local_origin(Snapshot {
                origin: Origin {
                    service_tier: None,
                    cyber_access: None,
                    id,
                    run_id: run,
                    client_id: client,
                    title: "Local task".into(),
                    project: "test".into(),
                    backend: "claudecode".into(),
                    model: None,
                    effort: None,
                    cwd: "/local/work".into(),
                    prompt: "Work locally".into(),
                    created_at: now_string(),
                    tags: vec![],
                },
                sequence: 1,
                text: String::new(),
                status: "active".into(),
                error: None,
            })
            .await
            .unwrap();
        Fixture {
            _temp: temp,
            store: Arc::new(store),
            id,
            run,
            client: client.to_string(),
        }
    }

    fn frame(f: &Fixture, seq: u64, event: serde_json::Value) -> EventFrame {
        EventFrame {
            mission_id: f.id,
            run_id: f.run,
            generation: 1,
            seq,
            event,
        }
    }

    fn call(id: &str) -> serde_json::Value {
        serde_json::json!({ "type": "tool_call", "tool_call_id": id, "name": "Bash", "args": {} })
    }

    #[tokio::test]
    async fn persists_publishes_and_dedupes_contiguously() {
        let f = fixture().await;
        let (tx, mut rx) = broadcast::channel(16);
        let id = f.id;
        let before = f
            .store
            .get_events(id, None, None, None)
            .await
            .unwrap()
            .len();

        let r = ingest(&f.store, &tx, &f.client, frame(&f, 1, call("a"))).await;
        assert_eq!(
            r,
            Reply::Ack {
                mission_id: id,
                seq: 1
            }
        );
        assert_eq!(rx.try_recv().unwrap().mission_id(), Some(id));

        // Replay after reconnect: acknowledged again, not stored twice.
        let r = ingest(&f.store, &tx, &f.client, frame(&f, 1, call("a"))).await;
        assert_eq!(
            r,
            Reply::Ack {
                mission_id: id,
                seq: 1
            }
        );
        assert!(rx.try_recv().is_err());

        // A hole is refused so the client replays from the cursor.
        let r = ingest(&f.store, &tx, &f.client, frame(&f, 3, call("c"))).await;
        assert_eq!(
            r,
            Reply::Gap {
                mission_id: id,
                expected: 2
            }
        );

        let r = ingest(&f.store, &tx, &f.client, frame(&f, 2, call("b"))).await;
        assert_eq!(
            r,
            Reply::Ack {
                mission_id: id,
                seq: 2
            }
        );
        let after = f
            .store
            .get_events(id, None, None, None)
            .await
            .unwrap()
            .len();
        assert_eq!(after - before, 2);
        assert_eq!(f.store.client_event_cursor(id, &f.client).await.unwrap(), 2);
    }

    #[tokio::test]
    async fn rejects_other_computers_stale_runs_and_core_owned_events() {
        let f = fixture().await;
        let (tx, _rx) = broadcast::channel(16);
        let other = Uuid::new_v4().to_string();
        assert!(matches!(
            ingest(&f.store, &tx, &other, frame(&f, 1, call("a"))).await,
            Reply::Rejected { .. }
        ));
        let status = serde_json::json!({ "type": "mission_status_changed", "status": "completed" });
        assert!(matches!(
            ingest(&f.store, &tx, &f.client, frame(&f, 1, status)).await,
            Reply::Rejected { .. }
        ));
        let mut stale = frame(&f, 1, call("a"));
        stale.run_id = Uuid::new_v4();
        assert!(matches!(
            ingest(&f.store, &tx, &f.client, stale).await,
            Reply::Rejected { .. }
        ));
        let mut stale = frame(&f, 1, call("a"));
        stale.generation = 2;
        assert!(matches!(
            ingest(&f.store, &tx, &f.client, stale).await,
            Reply::Rejected { .. }
        ));
        let mut unknown = frame(&f, 1, call("a"));
        unknown.mission_id = Uuid::new_v4();
        assert!(matches!(
            ingest(&f.store, &tx, &f.client, unknown).await,
            Reply::Rejected { .. }
        ));
        assert_eq!(
            f.store.client_event_cursor(f.id, &f.client).await.unwrap(),
            0
        );
    }

    #[test]
    fn presence_follows_the_current_socket_only() {
        let (user, client, old) = ("u", Uuid::new_v4().to_string(), Uuid::new_v4());
        assert!(!presence(user, &client).online);
        register(user, &client, old);
        assert!(presence(user, &client).online);
        // Reconnect overlap: the draining old socket must not reclaim the
        // registration, and its close must not evict the replacement.
        let new = Uuid::new_v4();
        register(user, &client, new);
        touch(user, &client, old);
        drop_link(user, &client, old);
        assert!(presence(user, &client).online);
        drop_link(user, &client, new);
        assert!(!presence(user, &client).online);
    }
}
