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
//!   expected}`, `rejected {mission_id, seq, reason}` (permanent; the
//!   sequence is consumed so later events still flow),
//!   `retry {mission_id, seq, reason}` (transient), `cursor {mission_id,
//!   last_seq}`, `pong`.
//!
//! Remote start (core → client): `start {request_id, prompt, backend, …}`
//! asks an online computer to begin a new local mission; it answers
//! `start_result {request_id, ok, mission_id?, error?}`. `hello` may carry the
//! computer's `name` and `harnesses`, refreshed later with `capabilities`.
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
        #[serde(default)]
        cost_cents: u64,
        #[serde(default)]
        cost_source: crate::agents::CostSource,
        #[serde(default)]
        usage: Option<crate::cost::TokenUsage>,
        #[serde(default)]
        model_normalized: Option<String>,
        #[serde(default)]
        resumable: bool,
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
    GoalIteration {
        iteration: u32,
        objective: String,
    },
    GoalStatus {
        status: String,
        objective: String,
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
                cost_cents,
                cost_source,
                usage,
                model_normalized,
                resumable,
            } => AgentEvent::AssistantMessage {
                id,
                content,
                success,
                cost_cents,
                cost_source,
                usage,
                model,
                model_normalized,
                mission_id: mid,
                // Local runs have no Core-side shared files or completion
                // evidence; those are produced by Core runners only.
                shared_files: None,
                resumable,
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
            ClientEvent::GoalIteration {
                iteration,
                objective,
            } => AgentEvent::GoalIteration {
                iteration,
                objective,
                mission_id: mid,
            },
            ClientEvent::GoalStatus { status, objective } => AgentEvent::GoalStatus {
                status,
                objective,
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
    Hello {
        client_id: String,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        harnesses: serde_json::Value,
    },
    Event(EventFrame),
    Cursor {
        mission_id: Uuid,
    },
    Capabilities {
        #[serde(default)]
        harnesses: serde_json::Value,
    },
    StartResult(StartResult),
    Ping,
}

/// A computer's answer to a remote `start`.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct StartResult {
    pub request_id: Uuid,
    pub ok: bool,
    #[serde(default)]
    pub mission_id: Option<Uuid>,
    #[serde(default)]
    pub error: Option<String>,
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
    name: String,
    /// Opaque harness list reported by Orb: `[{backend, name?, models?}]`.
    harnesses: serde_json::Value,
    /// Frames for this socket (remote start).
    outbox: tokio::sync::mpsc::UnboundedSender<String>,
}

/// One known computer, as listed to other clients.
#[derive(Debug, Clone, Serialize)]
pub struct Computer {
    pub client_id: String,
    pub name: String,
    pub online: bool,
    pub connected_at: String,
    pub last_seen_at: String,
    pub harnesses: serde_json::Value,
}

type Registry = StdMutex<HashMap<(String, String), Link>>;

fn registry() -> &'static Registry {
    static R: OnceLock<Registry> = OnceLock::new();
    R.get_or_init(Default::default)
}

/// Register a new socket for this install; it replaces any older one.
fn register(
    user_id: &str,
    client_id: &str,
    conn_id: Uuid,
    name: Option<String>,
    harnesses: serde_json::Value,
    outbox: tokio::sync::mpsc::UnboundedSender<String>,
) {
    let now = crate::api::mission_store::now_string();
    let name = name
        .map(|n| n.trim().chars().take(80).collect::<String>())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| "Computer".into());
    registry().lock().expect("client link registry").insert(
        (user_id.into(), client_id.into()),
        Link {
            conn_id,
            connected_at: now.clone(),
            last_seen_at: now,
            last_seen: Instant::now(),
            name,
            harnesses,
            outbox,
        },
    );
}

fn set_harnesses(user_id: &str, client_id: &str, conn_id: Uuid, harnesses: serde_json::Value) {
    let mut map = registry().lock().expect("client link registry");
    if let Some(link) = map
        .get_mut(&(user_id.to_string(), client_id.to_string()))
        .filter(|link| link.conn_id == conn_id)
    {
        link.harnesses = harnesses;
    }
}

/// Computers of this user with a live link, most recently seen first.
pub fn computers(user_id: &str) -> Vec<Computer> {
    let map = registry().lock().expect("client link registry");
    let mut list: Vec<Computer> = map
        .iter()
        .filter(|((user, _), _)| user == user_id)
        .map(|((_, client_id), l)| Computer {
            client_id: client_id.clone(),
            name: l.name.clone(),
            online: l.last_seen.elapsed() < OFFLINE_AFTER,
            connected_at: l.connected_at.clone(),
            last_seen_at: l.last_seen_at.clone(),
            harnesses: l.harnesses.clone(),
        })
        .collect();
    list.sort_by(|a, b| b.last_seen_at.cmp(&a.last_seen_at));
    list
}

type PendingStarts = StdMutex<HashMap<Uuid, tokio::sync::oneshot::Sender<StartResult>>>;

fn pending_starts() -> &'static PendingStarts {
    static P: OnceLock<PendingStarts> = OnceLock::new();
    P.get_or_init(Default::default)
}

/// Push `frame` to the computer's current socket, if it is online.
fn push(user_id: &str, client_id: &str, frame: &serde_json::Value) -> bool {
    let map = registry().lock().expect("client link registry");
    map.get(&(user_id.to_string(), client_id.to_string()))
        .filter(|l| l.last_seen.elapsed() < OFFLINE_AFTER)
        .is_some_and(|l| l.outbox.send(frame.to_string()).is_ok())
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

/// Whether `conn_id` is still the registered socket for this computer. A
/// replaced socket must not ingest: it could win a sequence number that the
/// replacement then sees acknowledged as a duplicate.
fn is_current(user_id: &str, client_id: &str, conn_id: Uuid) -> bool {
    registry()
        .lock()
        .expect("client link registry")
        .get(&(user_id.to_string(), client_id.to_string()))
        .is_some_and(|link| link.conn_id == conn_id)
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
    ingest_fenced(store, events_tx, client_id, frame, || true).await
}

/// `current` is re-checked under the mission lock, right before the commit,
/// so a socket replaced while its frame waited cannot claim the sequence.
async fn ingest_fenced(
    store: &Arc<dyn MissionStore>,
    events_tx: &broadcast::Sender<AgentEvent>,
    client_id: &str,
    frame: EventFrame,
    current: impl Fn() -> bool,
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
    let lock = worker_location::dispatch_lock(&format!("client-link:{mission_id}"));
    let _guard = lock.lock().await;
    // Decide under the lock (the fence must not race a stop), then commit.
    // A refused frame still consumes its sequence, so later events of the
    // client's current run are not wedged behind it.
    let verdict = match admit(store, client_id, mission_id, run_id, generation, event).await {
        Ok(verdict) => verdict,
        Err(reason) => return retry(reason),
    };
    if !current() {
        return retry("superseded by a newer connection".into());
    }
    let (event, refusal) = match verdict {
        Ok(event) => (Some(event), None),
        Err(reason) => (None, Some(reason)),
    };
    // Same rule as core's own logger: incremental thinking is live-only.
    let persist = event.as_ref().is_some_and(super::should_persist_event);
    match store
        .log_client_event(
            mission_id,
            client_id,
            seq,
            event.clone().filter(|_| persist),
            Some((run_id, generation)),
        )
        .await
    {
        Ok(ClientIngest::Stored) => match (event, refusal) {
            (Some(event), _) => {
                if persist {
                    prepersisted(mission_id, &event);
                }
                let _ = events_tx.send(event);
                Reply::Ack { mission_id, seq }
            }
            (None, reason) => reject(&reason.unwrap_or_default()),
        },
        Ok(ClientIngest::Refused) => {
            reject("Local execution receipt is stale or not owned by this computer")
        }
        // Already resolved earlier (stored or refused); the client moves on.
        Ok(ClientIngest::Duplicate) => Reply::Ack { mission_id, seq },
        Ok(ClientIngest::Gap { expected }) => Reply::Gap {
            mission_id,
            expected,
        },
        Err(e) if e == CLIENT_LINK_UNSUPPORTED => reject(&e),
        Err(e) => retry(e),
    }
}

/// `Ok(Ok(event))` to store, `Ok(Err(reason))` to refuse permanently,
/// `Err(reason)` for a transient failure the client should retry.
/// Ownership and liveness are checked by the store inside the ingest
/// transaction, so this hot path never loads the mission.
async fn admit(
    _store: &Arc<dyn MissionStore>,
    client_id: &str,
    mission_id: Uuid,
    _run_id: Uuid,
    _generation: u64,
    raw: serde_json::Value,
) -> Result<Result<AgentEvent, String>, String> {
    match serde_json::from_value::<ClientEvent>(raw) {
        Ok(event) => Ok(Ok(event.into_agent_event(mission_id, client_id))),
        Err(e) => Ok(Err(format!("unsupported event: {e}"))),
    }
}

// === Logger handshake ===

/// Exact copies of events already persisted by ingest, so the global event
/// logger (which persists everything broadcast on `events_tx`) skips exactly
/// those broadcasts and nothing else. Matching is on the serialized event,
/// never on its type alone; there is no time expiry (a lagging logger still
/// finds its ticket). A ticket whose broadcast the logger dropped can only
/// ever match a byte-identical event; the per-mission cap bounds memory.
/// Above the broadcast channel's capacity (8192), so a ticket outlives any
/// broadcast that can still reach the logger.
const TICKETS_PER_MISSION: usize = 16_384;
/// Bound across all missions. Normally the logger consumes tickets as fast
/// as they are made; only dropped broadcasts leave any behind.
const TICKETS_TOTAL: usize = 131_072;

type Tickets = StdMutex<HashMap<Uuid, std::collections::VecDeque<String>>>;

fn tickets() -> &'static Tickets {
    static T: OnceLock<Tickets> = OnceLock::new();
    T.get_or_init(Default::default)
}

fn prepersisted(mission_id: Uuid, event: &AgentEvent) {
    let Ok(text) = serde_json::to_string(event) else {
        return;
    };
    let mut map = tickets().lock().expect("client link tickets");
    let total: usize = map.values().map(|q| q.len()).sum();
    if total >= TICKETS_TOTAL {
        // Shed the largest backlog first (it is the one the logger dropped).
        if let Some(largest) = map.iter().max_by_key(|(_, q)| q.len()).map(|(id, _)| *id) {
            tracing::warn!(mission_id = %largest, "client link: shedding unconsumed logger tickets");
            map.remove(&largest);
        }
    }
    let queue = map.entry(mission_id).or_default();
    if queue.len() >= TICKETS_PER_MISSION {
        queue.pop_front();
    }
    queue.push_back(text);
}

/// Called by the event logger for every broadcast; true means "already
/// persisted by the client link, do not store again".
pub fn take_prepersisted(mission_id: Uuid, event: &AgentEvent) -> bool {
    let mut map = tickets().lock().expect("client link tickets");
    let Some(queue) = map.get_mut(&mission_id) else {
        return false;
    };
    let Ok(text) = serde_json::to_string(event) else {
        return false;
    };
    let Some(index) = queue.iter().position(|t| *t == text) else {
        return false;
    };
    queue.remove(index);
    if queue.is_empty() {
        map.remove(&mission_id);
    }
    true
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

/// Computers of this user that hold (or recently held) a client link.
pub async fn list_client_computers(
    Extension(user): Extension<AuthUser>,
) -> Json<serde_json::Value> {
    Json(serde_json::json!({ "computers": computers(&user.id) }))
}

#[derive(Debug, Deserialize, Serialize)]
pub struct RemoteStartRequest {
    pub prompt: String,
    pub backend: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub project: Option<String>,
    #[serde(default)]
    pub model_override: Option<String>,
    #[serde(default)]
    pub model_effort: Option<String>,
    #[serde(default)]
    pub working_directory: Option<String>,
}

const START_TIMEOUT: Duration = Duration::from_secs(90);

/// Start a new mission on one of the user's online computers. Orb runs it
/// locally, exactly as if it had been started there, and streams it back
/// over the link; this returns once that computer accepted or refused it.
pub async fn start_on_client_computer(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(client_id): Path<String>,
    Json(req): Json<RemoteStartRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if req.prompt.trim().is_empty() || req.backend.trim().is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "prompt and backend are required".into(),
        ));
    }
    let request_id = Uuid::new_v4();
    let (tx, rx) = tokio::sync::oneshot::channel();
    pending_starts()
        .lock()
        .expect("client link starts")
        .insert(request_id, tx);
    let mut frame = serde_json::to_value(&req).map_err(internal_error)?;
    frame["type"] = "start".into();
    frame["request_id"] = request_id.to_string().into();
    if !push(&user.id, &client_id, &frame) {
        pending_starts()
            .lock()
            .expect("client link starts")
            .remove(&request_id);
        return Err((
            StatusCode::CONFLICT,
            "That computer is offline. Open Orb on it and try again.".into(),
        ));
    }
    let result = tokio::time::timeout(START_TIMEOUT, rx).await;
    pending_starts()
        .lock()
        .expect("client link starts")
        .remove(&request_id);
    let result = match result {
        Ok(Ok(result)) => result,
        _ => {
            return Err((
                StatusCode::GATEWAY_TIMEOUT,
                "The computer did not confirm the start in time. Check it before retrying.".into(),
            ))
        }
    };
    let Some(mission_id) = result.mission_id.filter(|_| result.ok) else {
        return Err((
            StatusCode::CONFLICT,
            result
                .error
                .unwrap_or_else(|| "The computer refused to start the mission".into()),
        ));
    };
    let control = control_for_user(&state, &user).await;
    let mission = control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?;
    Ok(Json(
        serde_json::json!({ "mission_id": mission_id, "mission": mission }),
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
            Ok(Inbound::Hello {
                client_id,
                name,
                harnesses,
            }) if Uuid::parse_str(&client_id).is_ok() => (client_id, name, harnesses),
            _ => return,
        },
        _ => return,
    };
    let (client_id, name, harnesses) = client_id;
    let (outbox, mut outgoing) = tokio::sync::mpsc::unbounded_channel::<String>();
    register(&user.id, &client_id, conn_id, name, harnesses, outbox);
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
            Some(text) = outgoing.recv() => {
                if sender.send(WsMessage::Text(text)).await.is_err() {
                    break;
                }
            }
            frame = receiver.next() => {
                let text = match frame {
                    Some(Ok(WsMessage::Text(text))) => text,
                    Some(Ok(WsMessage::Pong(_) | WsMessage::Ping(_) | WsMessage::Binary(_))) => {
                        // A superseded socket retires even if it only pongs.
                        if !is_current(&user.id, &client_id, conn_id) {
                            break;
                        }
                        touch(&user.id, &client_id, conn_id);
                        continue;
                    }
                    _ => break,
                };
                if !is_current(&user.id, &client_id, conn_id) {
                    // Superseded by a newer socket from the same computer.
                    break;
                }
                touch(&user.id, &client_id, conn_id);
                let reply = match serde_json::from_str::<Inbound>(&text) {
                    Ok(Inbound::Event(frame)) => {
                        ingest_fenced(&control.mission_store, &control.events_tx, &client_id, frame, || {
                            is_current(&user.id, &client_id, conn_id)
                        })
                        .await
                    }
                    Ok(Inbound::Cursor { mission_id }) => {
                        match control.mission_store.client_event_cursor(mission_id, &client_id).await {
                            Ok(last_seq) => Reply::Cursor { mission_id, last_seq },
                            Err(reason) if reason == CLIENT_LINK_UNSUPPORTED => Reply::Rejected { mission_id, seq: 0, reason },
                            Err(reason) => Reply::Retry { mission_id, seq: 0, reason },
                        }
                    }
                    Ok(Inbound::Capabilities { harnesses }) => {
                        set_harnesses(&user.id, &client_id, conn_id, harnesses);
                        continue;
                    }
                    Ok(Inbound::StartResult(result)) => {
                        if let Some(waiter) = pending_starts()
                            .lock()
                            .expect("client link starts")
                            .remove(&result.request_id)
                        {
                            let _ = waiter.send(result);
                        }
                        continue;
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
        let mut stale = frame(&f, 2, call("a"));
        stale.run_id = Uuid::new_v4();
        assert!(matches!(
            ingest(&f.store, &tx, &f.client, stale).await,
            Reply::Rejected { .. }
        ));
        let mut stale = frame(&f, 3, call("a"));
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
        // Each refusal consumed its sequence: the next valid event (seq 4,
        // after the three refused frames of this client) is accepted.
        assert_eq!(
            f.store.client_event_cursor(f.id, &f.client).await.unwrap(),
            3
        );
        assert_eq!(
            ingest(&f.store, &tx, &f.client, frame(&f, 4, call("ok"))).await,
            Reply::Ack {
                mission_id: f.id,
                seq: 4
            }
        );
    }

    #[tokio::test]
    async fn goal_events_from_local_runs_are_relayed() {
        let f = fixture().await;
        let (tx, mut rx) = broadcast::channel(16);
        let goal =
            serde_json::json!({ "type": "goal_iteration", "iteration": 2, "objective": "ship" });
        assert_eq!(
            ingest(&f.store, &tx, &f.client, frame(&f, 1, goal)).await,
            Reply::Ack {
                mission_id: f.id,
                seq: 1
            }
        );
        assert!(matches!(
            rx.try_recv().unwrap(),
            AgentEvent::GoalIteration { iteration: 2, .. }
        ));
    }

    #[tokio::test]
    async fn logger_skips_ingested_events_and_partial_thinking_is_live_only() {
        let f = fixture().await;
        let (tx, mut rx) = broadcast::channel(16);
        let before = f
            .store
            .get_events(f.id, None, None, None)
            .await
            .unwrap()
            .len();
        let partial = serde_json::json!({ "type": "thinking", "content": "hm", "done": false });
        ingest(&f.store, &tx, &f.client, frame(&f, 1, partial)).await;
        let event = rx.try_recv().unwrap();
        assert!(!take_prepersisted(f.id, &event), "not persisted, no ticket");
        ingest(&f.store, &tx, &f.client, frame(&f, 2, call("a"))).await;
        let event = rx.try_recv().unwrap();
        // An unrelated core event of the same type is never mistaken for it.
        let other = AgentEvent::ToolCall {
            tool_call_id: "core".into(),
            name: "Bash".into(),
            args: serde_json::json!({}),
            mission_id: Some(f.id),
        };
        assert!(!take_prepersisted(f.id, &other));
        assert!(take_prepersisted(f.id, &event));
        assert!(!take_prepersisted(f.id, &event), "one ticket per event");
        let after = f
            .store
            .get_events(f.id, None, None, None)
            .await
            .unwrap()
            .len();
        assert_eq!(after - before, 1, "only the tool call is stored");
    }

    #[tokio::test]
    async fn remote_start_reaches_the_current_socket_and_lists_the_computer() {
        let (user, client) = ("start-user", Uuid::new_v4().to_string());
        assert!(!push(user, &client, &serde_json::json!({})), "offline");
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        register(
            user,
            &client,
            Uuid::new_v4(),
            Some("  Thomas's MacBook  ".into()),
            serde_json::json!([{ "backend": "claudecode" }]),
            tx,
        );
        let listed = computers(user);
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "Thomas's MacBook");
        assert!(listed[0].online);
        assert!(computers("someone-else").is_empty());
        assert!(push(user, &client, &serde_json::json!({ "type": "start" })));
        assert_eq!(rx.recv().await.unwrap(), r#"{"type":"start"}"#);
    }

    #[test]
    fn presence_follows_the_current_socket_only() {
        let (user, client, old) = ("u", Uuid::new_v4().to_string(), Uuid::new_v4());
        assert!(!presence(user, &client).online);
        register(
            user,
            &client,
            old,
            None,
            serde_json::Value::Null,
            tokio::sync::mpsc::unbounded_channel().0,
        );
        assert!(presence(user, &client).online);
        // Reconnect overlap: the draining old socket must not reclaim the
        // registration, and its close must not evict the replacement.
        let new = Uuid::new_v4();
        register(
            user,
            &client,
            new,
            None,
            serde_json::Value::Null,
            tokio::sync::mpsc::unbounded_channel().0,
        );
        touch(user, &client, old);
        drop_link(user, &client, old);
        assert!(presence(user, &client).online);
        assert!(!is_current(user, &client, old));
        assert!(is_current(user, &client, new));
        drop_link(user, &client, new);
        assert!(!presence(user, &client).online);
    }
}
