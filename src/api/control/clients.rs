//! Orb clients that can own `placement:"client"` missions.
//!
//! A client-placed mission used to imply "the Orb desktop that created it".
//! Clients now register an explicit identity, platform and capability set so
//! Core can tell an iPhone runner from a Mac runner, route deliveries to the
//! owner, and show the right label. Registration is advisory metadata: it never
//! grants execution ownership, which stays with the `orb-client:<id>` run
//! receipt and the `worker-client:<id>` tag.
use super::*;
use serde::{Deserialize, Serialize};
use std::path::{Path as FsPath, PathBuf};

/// Capabilities a client may advertise. Unknown keys are preserved so newer
/// clients can add capabilities without a Core upgrade; these are the ones Core
/// and the official clients understand.
pub const KNOWN_CAPABILITIES: &[&str] = &[
    "local_agents",
    "unix_shell",
    "screen_observation",
    "keyboard_injection",
    "app_intents",
    "computer_use",
    "arbitrary_ui_injection",
];
pub const PLATFORMS: &[&str] = &["macos", "linux", "windows", "ios", "ipados", "android"];
/// A registration older than this is shown as offline. Execution liveness is
/// still the run heartbeat; this is only presence for pickers and labels.
pub const ONLINE_WINDOW_SECS: i64 = 120;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ClientRecord {
    pub client_id: String,
    pub platform: String,
    /// Execution runtime identifier, e.g. `tauri`, `ios`.
    pub runtime: String,
    pub name: String,
    #[serde(default)]
    pub capabilities: std::collections::BTreeMap<String, bool>,
    /// Harness ids the client can run locally (subset of Core backends).
    #[serde(default)]
    pub harnesses: Vec<String>,
    /// Free-form, size-limited detail (OS version, runtime version, probes).
    #[serde(default)]
    pub detail: serde_json::Value,
    pub registered_at: String,
    pub last_seen_at: String,
}

#[derive(Debug, Deserialize)]
pub struct RegisterClientRequest {
    pub client_id: String,
    pub platform: String,
    pub runtime: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub capabilities: std::collections::BTreeMap<String, bool>,
    #[serde(default)]
    pub harnesses: Vec<String>,
    #[serde(default)]
    pub detail: serde_json::Value,
}

fn dir(root: &FsPath, user: &str) -> PathBuf {
    // User ids are opaque; hash them so they are always a safe path segment.
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(user.as_bytes());
    root.join("orb-clients").join(hex::encode(&digest[..12]))
}

fn file(root: &FsPath, user: &str, client: Uuid) -> PathBuf {
    dir(root, user).join(format!("{client}.json"))
}

static WRITE: std::sync::Mutex<()> = std::sync::Mutex::new(());

impl RegisterClientRequest {
    pub fn validate(&self) -> Result<Uuid, String> {
        let id = Uuid::parse_str(self.client_id.trim()).map_err(|_| "Invalid client identity")?;
        if id.is_nil() {
            return Err("Invalid client identity".into());
        }
        if !PLATFORMS.contains(&self.platform.as_str()) {
            return Err(format!("Unsupported client platform {}", self.platform));
        }
        if self.runtime.is_empty()
            || self.runtime.len() > 64
            || !self
                .runtime
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        {
            return Err("Invalid client runtime".into());
        }
        if self.name.as_deref().is_some_and(|n| n.len() > 128) {
            return Err("Client name is too long".into());
        }
        if self.capabilities.len() > 64 || self.capabilities.keys().any(|k| k.len() > 64) {
            return Err("Too many client capabilities".into());
        }
        if self.harnesses.len() > 16 || self.harnesses.iter().any(|h| h.len() > 64) {
            return Err("Too many client harnesses".into());
        }
        if serde_json::to_vec(&self.detail).map_or(true, |b| b.len() > 16 * 1024) {
            return Err("Client detail exceeds 16 KiB".into());
        }
        Ok(id)
    }
}

/// Human label for a client-placed mission's owner. Never assumes a Mac.
pub fn label(platform: Option<&str>, name: Option<&str>) -> String {
    if let Some(name) = name.map(str::trim).filter(|n| !n.is_empty()) {
        return name.to_string();
    }
    match platform {
        Some("ios") => "iPhone".into(),
        Some("ipados") => "iPad".into(),
        Some("macos") => "Mac".into(),
        Some("android") => "Android device".into(),
        _ => "Orb client".into(),
    }
}

pub fn register(
    root: &FsPath,
    user: &str,
    req: RegisterClientRequest,
) -> Result<ClientRecord, String> {
    let id = req.validate()?;
    let _guard = WRITE
        .lock()
        .map_err(|_| "Client registry lock unavailable")?;
    let path = file(root, user, id);
    let now = now_string();
    let registered_at = read_file(&path)?
        .map(|old| old.registered_at)
        .unwrap_or_else(|| now.clone());
    let mut capabilities = req.capabilities;
    // An unmentioned known capability is an explicit "no", so agents and
    // pickers never have to guess what an older client can do.
    for known in KNOWN_CAPABILITIES {
        capabilities.entry((*known).to_string()).or_insert(false);
    }
    let record = ClientRecord {
        client_id: id.to_string(),
        name: req
            .name
            .clone()
            .filter(|n| !n.trim().is_empty())
            .unwrap_or_else(|| label(Some(&req.platform), None)),
        platform: req.platform,
        runtime: req.runtime,
        capabilities,
        harnesses: req.harnesses,
        detail: req.detail,
        registered_at,
        last_seen_at: now,
    };
    std::fs::create_dir_all(dir(root, user)).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(
        &tmp,
        serde_json::to_vec_pretty(&record).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    Ok(record)
}

fn read_file(path: &FsPath) -> Result<Option<ClientRecord>, String> {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|_| "Client registration is unreadable".into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

pub fn get(root: &FsPath, user: &str, client: Uuid) -> Result<Option<ClientRecord>, String> {
    read_file(&file(root, user, client))
}

/// Tag recording the owning client's platform so every Orb surface can label a
/// client-placed mission ("iPhone", "Mac") without another lookup.
pub const PLATFORM_TAG: &str = "client-platform:";

pub fn list(root: &FsPath, user: &str) -> Result<Vec<ClientRecord>, String> {
    let entries = match std::fs::read_dir(dir(root, user)) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.to_string()),
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        if let Ok(Some(record)) = read_file(&path) {
            out.push(record);
        }
    }
    out.sort_by(|a, b| b.last_seen_at.cmp(&a.last_seen_at));
    Ok(out)
}

pub fn online(record: &ClientRecord, now: chrono::DateTime<chrono::Utc>) -> bool {
    chrono::DateTime::parse_from_rfc3339(&record.last_seen_at)
        .map(|seen| (now - seen.with_timezone(&chrono::Utc)).num_seconds() <= ONLINE_WINDOW_SECS)
        .unwrap_or(false)
}

fn view(record: &ClientRecord) -> serde_json::Value {
    let mut value = serde_json::to_value(record).unwrap_or_default();
    value["online"] = serde_json::Value::Bool(online(record, chrono::Utc::now()));
    value["label"] = serde_json::Value::String(label(Some(&record.platform), Some(&record.name)));
    value
}

pub async fn register_client(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(req): Json<RegisterClientRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let record = register(&state.config.working_dir, &user.id, req)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    Ok(Json(view(&record)))
}

pub async fn list_clients(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let records = list(&state.config.working_dir, &user.id).map_err(internal_error)?;
    Ok(Json(serde_json::json!({
        "clients": records.iter().map(view).collect::<Vec<_>>(),
    })))
}

/// Pending prompts and follow-ups for every mission this client owns. Unlike
/// `client-run` `inbox_all`, this needs no anchor mission, so a freshly
/// installed client can receive its first delegated task.
pub async fn client_inbox(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(client): Path<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let id = Uuid::parse_str(&client)
        .ok()
        .filter(|id| !id.is_nil())
        .ok_or((
            StatusCode::BAD_REQUEST,
            "Invalid client identity".to_string(),
        ))?;
    let control = control_for_user(&state, &user).await;
    let messages = machine_transfer::client_inbox(&control, &id.to_string()).await?;
    Ok(Json(serde_json::json!({ "messages": messages })))
}

/// Structured event from a client-run harness, in Orb's normalized protocol.
/// Only transcript-shaped variants are accepted: a client can never forge
/// status, settings or ownership events through this path.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientEvent {
    Thinking {
        content: String,
        #[serde(default)]
        done: bool,
    },
    TextDelta {
        content: String,
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
    Activity {
        label: String,
        tool_name: String,
    },
}

#[derive(Debug, Deserialize)]
pub struct ClientEventsRequest {
    pub run_id: Option<Uuid>,
    pub generation: Option<u64>,
    pub events: Vec<ClientEvent>,
}

pub const MAX_EVENTS_PER_BATCH: usize = 256;
const MAX_FIELD_BYTES: usize = 512 * 1024;

impl ClientEvent {
    fn into_agent_event(self, mission: Uuid) -> Result<AgentEvent, String> {
        let check = |s: &str| {
            if s.len() > MAX_FIELD_BYTES {
                Err("Client event exceeds 512 KiB".to_string())
            } else {
                Ok(())
            }
        };
        let json_len = |v: &serde_json::Value| serde_json::to_vec(v).map_or(0, |b| b.len());
        Ok(match self {
            Self::Thinking { content, done } => {
                check(&content)?;
                AgentEvent::Thinking {
                    content,
                    done,
                    mission_id: Some(mission),
                }
            }
            Self::TextDelta { content } => {
                check(&content)?;
                AgentEvent::TextDelta {
                    content,
                    mission_id: Some(mission),
                }
            }
            Self::ToolCall {
                tool_call_id,
                name,
                args,
            } => {
                if tool_call_id.is_empty() || tool_call_id.len() > 256 || name.len() > 256 {
                    return Err("Invalid tool call identity".into());
                }
                if json_len(&args) > MAX_FIELD_BYTES {
                    return Err("Client event exceeds 512 KiB".into());
                }
                AgentEvent::ToolCall {
                    tool_call_id,
                    name,
                    args,
                    mission_id: Some(mission),
                }
            }
            Self::ToolResult {
                tool_call_id,
                name,
                result,
            } => {
                if tool_call_id.is_empty() || tool_call_id.len() > 256 || name.len() > 256 {
                    return Err("Invalid tool call identity".into());
                }
                if json_len(&result) > MAX_FIELD_BYTES {
                    return Err("Client event exceeds 512 KiB".into());
                }
                AgentEvent::ToolResult {
                    tool_call_id,
                    name,
                    result,
                    mission_id: Some(mission),
                }
            }
            Self::Error { message, resumable } => {
                check(&message)?;
                AgentEvent::Error {
                    message,
                    resumable,
                    mission_id: Some(mission),
                }
            }
            Self::Activity { label, tool_name } => {
                if label.len() > 512 || tool_name.len() > 256 {
                    return Err("Invalid activity".into());
                }
                AgentEvent::MissionActivity {
                    label,
                    tool_name,
                    mission_id: Some(mission),
                }
            }
        })
    }
}

/// Stream normalized harness events from the owning client into the mission's
/// history and live SSE. Requires the same run receipt as transcript writes.
pub async fn append_client_events(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<ClientEventsRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if req.events.len() > MAX_EVENTS_PER_BATCH {
        return Err((
            StatusCode::BAD_REQUEST,
            "Too many events in one batch".into(),
        ));
    }
    let events = req
        .events
        .into_iter()
        .map(|e| e.into_agent_event(id))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    let control = control_for_user(&state, &user).await;
    let Some(mission) = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
    else {
        return Err((StatusCode::NOT_FOUND, "Mission not found".into()));
    };
    if !client_placement::is_tagged(&mission.project.tags) {
        return Err((
            StatusCode::CONFLICT,
            "event append is only for client-placed missions".into(),
        ));
    }
    machine_transfer::check_client_receipt(&control, id, req.run_id, req.generation).await?;
    let accepted = events.len();
    for event in events {
        control
            .mission_store
            .log_event(id, &event)
            .await
            .map_err(internal_error)?;
        let _ = control.events_tx.send(event);
    }
    Ok(Json(
        serde_json::json!({ "ok": true, "accepted": accepted }),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(id: &str, platform: &str) -> RegisterClientRequest {
        serde_json::from_value(serde_json::json!({
            "client_id": id,
            "platform": platform,
            "runtime": "ios",
            "name": "Thomas's iPhone",
            "capabilities": {"local_agents": true, "arbitrary_ui_injection": false},
            "harnesses": ["codex"],
        }))
        .unwrap()
    }

    #[test]
    fn registration_round_trips_and_keeps_first_seen() {
        let temp = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4().to_string();
        let first = register(temp.path(), "user-1", request(&id, "ios")).unwrap();
        let second = register(temp.path(), "user-1", request(&id, "ios")).unwrap();
        assert_eq!(first.registered_at, second.registered_at);
        assert_eq!(
            second.capabilities.get("arbitrary_ui_injection"),
            Some(&false)
        );
        assert_eq!(list(temp.path(), "user-1").unwrap().len(), 1);
        // Registrations are per user.
        assert!(list(temp.path(), "user-2").unwrap().is_empty());
        let listed = &list(temp.path(), "user-1").unwrap()[0];
        assert_eq!(listed.platform, "ios");
        // Known capabilities the client did not mention are explicit `false`.
        assert_eq!(listed.capabilities.get("keyboard_injection"), Some(&false));
    }

    #[test]
    fn registration_rejects_bad_identity_and_platform() {
        let temp = tempfile::tempdir().unwrap();
        assert!(register(temp.path(), "u", request("not-a-uuid", "ios")).is_err());
        assert!(register(temp.path(), "u", request(&Uuid::nil().to_string(), "ios")).is_err());
        assert!(register(
            temp.path(),
            "u",
            request(&Uuid::new_v4().to_string(), "tvos")
        )
        .is_err());
    }

    #[test]
    fn labels_never_assume_a_mac() {
        assert_eq!(label(Some("ios"), None), "iPhone");
        assert_eq!(label(Some("macos"), None), "Mac");
        assert_eq!(label(None, None), "Orb client");
        assert_eq!(label(Some("ios"), Some("Pocket")), "Pocket");
    }

    #[test]
    fn client_events_cannot_forge_status() {
        let parsed: Result<ClientEvent, _> = serde_json::from_value(
            serde_json::json!({"type":"mission_status_changed","status":"completed"}),
        );
        assert!(parsed.is_err());
        let ok: ClientEvent = serde_json::from_value(serde_json::json!({
            "type":"tool_call","tool_call_id":"c1","name":"computer.screenshot","args":{}
        }))
        .unwrap();
        let mission = Uuid::new_v4();
        match ok.into_agent_event(mission).unwrap() {
            AgentEvent::ToolCall { mission_id, .. } => assert_eq!(mission_id, Some(mission)),
            other => panic!("unexpected {other:?}"),
        }
    }
}
