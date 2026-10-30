//! Opt-in Orb usage telemetry forwarded to a telemetry hub
//! (`Th0rgal/telemetry-hub`, `POST /v2/ns/<ns>/ingest`).
//!
//! Off by default. When the owner turns it on, clients POST UI events
//! (`orb.approval.v1`, `orb.page.v1`, `orb.action.v1`) to
//! `/api/usage-telemetry/events`, Core adds `orb.turn.v1` (and, behind a
//! second opt-in, `orb.prompt.v1` with secrets scrubbed), and a background
//! task batches them to the owner's namespace. Never `community`.
//!
//! The allowlist of schemas and fields is `shared/orb-spec/fixtures/
//! usage-telemetry.json`, shared with every client. Fields not listed there
//! are dropped, so payloads and secrets cannot ride along. The hub token is
//! stored encrypted and never logged; prompts are never logged.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use axum::{
    extract::State,
    http::StatusCode,
    response::Json,
    routing::{get, post, put},
    Router,
};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::env_crypto;
use crate::settings::OrbTelemetrySettings;

use super::control::AgentEvent;
use super::routes::AppState;

pub const DEFAULT_HUB_URL: &str = "https://telemetry.thomas.md";
/// Events per POST.
const BATCH_SIZE: usize = 200;
/// Events kept while the hub is unreachable; the oldest go first.
const QUEUE_CAP: usize = 5_000;
const FLUSH_INTERVAL: Duration = Duration::from_secs(30);
const MAX_BACKOFF: Duration = Duration::from_secs(600);

const SPEC_JSON: &str = include_str!("../../shared/orb-spec/fixtures/usage-telemetry.json");

// ---------------------------------------------------------------------------
// Allowlist (from the shared fixture)

#[derive(Debug, Clone)]
enum FieldType {
    Uint,
    Bool,
    Ident,
    Client,
    Schema,
    Enum(Vec<String>),
}

struct Spec {
    quick_close_ms: u64,
    clients: Vec<String>,
    client_schemas: Vec<String>,
    schemas: HashMap<String, BTreeMap<String, FieldType>>,
    common: BTreeMap<String, FieldType>,
    ident: Regex,
}

fn field_type(value: &Value) -> FieldType {
    match value {
        Value::Array(items) => FieldType::Enum(
            items
                .iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect(),
        ),
        Value::String(s) if s == "uint" => FieldType::Uint,
        Value::String(s) if s == "bool" => FieldType::Bool,
        Value::String(s) if s == "client" => FieldType::Client,
        Value::String(s) if s == "schema" => FieldType::Schema,
        _ => FieldType::Ident,
    }
}

fn fields(value: &Value) -> BTreeMap<String, FieldType> {
    value
        .as_object()
        .map(|m| m.iter().map(|(k, v)| (k.clone(), field_type(v))).collect())
        .unwrap_or_default()
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

fn spec() -> &'static Spec {
    static SPEC: OnceLock<Spec> = OnceLock::new();
    SPEC.get_or_init(|| {
        let raw: Value = serde_json::from_str(SPEC_JSON).expect("usage-telemetry.json parses");
        Spec {
            quick_close_ms: raw["quick_close_ms"].as_u64().unwrap_or(2000),
            clients: strings(&raw["clients"]),
            client_schemas: strings(&raw["client_schemas"]),
            schemas: raw["schemas"]
                .as_object()
                .expect("schemas")
                .iter()
                .map(|(k, v)| (k.clone(), fields(v)))
                .collect(),
            common: fields(&raw["common"]),
            ident: Regex::new(raw["ident_pattern"].as_str().expect("ident_pattern"))
                .expect("ident_pattern compiles"),
        }
    })
}

fn keep(spec: &Spec, ty: &FieldType, value: &Value) -> bool {
    match ty {
        FieldType::Uint => value.is_u64(),
        FieldType::Bool => value.is_boolean(),
        FieldType::Ident => value.as_str().is_some_and(|s| spec.ident.is_match(s)),
        FieldType::Client => value
            .as_str()
            .is_some_and(|s| spec.clients.iter().any(|c| c == s)),
        FieldType::Schema => value.is_string(),
        FieldType::Enum(allowed) => value
            .as_str()
            .is_some_and(|s| allowed.iter().any(|a| a == s)),
    }
}

/// Reduce an event to its allowlisted fields. `from_client` events may only
/// use the client schemas. Rejects unknown schemas and clients.
pub fn sanitize(event: &Value, from_client: bool) -> Result<Map<String, Value>, &'static str> {
    let spec = spec();
    let schema = event
        .get("schema")
        .and_then(Value::as_str)
        .ok_or("missing schema")?;
    let schema_fields = spec.schemas.get(schema).ok_or("unknown schema")?;
    if from_client && !spec.client_schemas.iter().any(|s| s == schema) {
        return Err("core-only schema");
    }
    let client_ok = event
        .get("client")
        .is_some_and(|c| keep(spec, &FieldType::Client, c));
    if !client_ok {
        return Err("unknown client");
    }
    let mut out = Map::new();
    for (key, ty) in spec.common.iter().chain(schema_fields.iter()) {
        if let Some(value) = event.get(key) {
            if keep(spec, ty, value) {
                out.insert(key.clone(), value.clone());
            }
        }
    }
    if schema == "orb.page.v1" {
        if let Some(dwell) = out.get("dwell_ms").and_then(Value::as_u64) {
            out.insert(
                "quick_close".into(),
                Value::Bool(dwell < spec.quick_close_ms),
            );
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Secret scrubbing

fn scrub_patterns() -> &'static [(Regex, &'static str)] {
    static PATTERNS: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        [
            (
                r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----",
                "[REDACTED]",
            ),
            (
                r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}",
                "[REDACTED]",
            ),
            (r"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}", "[REDACTED]"),
            (r"\btl_(?:live|test)_[A-Za-z0-9]{8,}", "[REDACTED]"),
            (r"\bgh[pousr]_[A-Za-z0-9]{20,}", "[REDACTED]"),
            (r"\bgithub_pat_[A-Za-z0-9_]{20,}", "[REDACTED]"),
            (r"\bAKIA[0-9A-Z]{16}\b", "[REDACTED]"),
            (r"\bxox[abpr]-[A-Za-z0-9-]{10,}", "[REDACTED]"),
            (r"\bAIza[0-9A-Za-z_-]{35}", "[REDACTED]"),
            (r"(?i)\b(bearer\s+)[A-Za-z0-9._~+/-]{16,}=*", "${1}[REDACTED]"),
            (
                r"(?i)\b([A-Z0-9_-]*(?:secret|token|password|passwd|api_?key|private_?key)[A-Z0-9_-]*)(['\x22]?\s*[:=]\s*['\x22]?)([^\s'\x22]{4,})",
                "${1}${2}[REDACTED]",
            ),
            (r"://[^/\s:@]+:[^/\s@]+@", "://[REDACTED]@"),
        ]
        .into_iter()
        .map(|(re, rep)| (Regex::new(re).expect("scrub regex compiles"), rep))
        .collect()
    })
}

/// Replace API keys, tokens, passwords, private keys and URL credentials.
pub fn scrub_secrets(text: &str) -> String {
    scrub_patterns()
        .iter()
        .fold(text.to_string(), |acc, (re, rep)| {
            re.replace_all(&acc, *rep).into_owned()
        })
}

// ---------------------------------------------------------------------------
// Queue and flushing

/// Where and as whom to send. `None` on the sink means telemetry is off.
#[derive(Clone)]
pub struct HubTarget {
    pub url: String,
    pub namespace: String,
    pub token: String,
    pub prompts: bool,
}

impl std::fmt::Debug for HubTarget {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HubTarget")
            .field("url", &self.url)
            .field("namespace", &self.namespace)
            .field("token", &"<redacted>")
            .finish()
    }
}

#[derive(Default)]
struct Queue {
    events: VecDeque<Value>,
    blobs: BTreeMap<String, String>,
    failures: u32,
    retry_at: Option<Instant>,
    last_error: Option<String>,
}

#[derive(Default)]
struct TurnState {
    started: Option<Instant>,
    last_prompt_digest: Option<String>,
    resent: bool,
}

/// Buffers events and sends them to the hub. One per process ([`global`]).
#[derive(Default)]
pub struct Sink {
    target: Mutex<Option<HubTarget>>,
    queue: Mutex<Queue>,
    turns: Mutex<HashMap<Uuid, TurnState>>,
    wake: tokio::sync::Notify,
}

pub fn global() -> &'static Arc<Sink> {
    static SINK: OnceLock<Arc<Sink>> = OnceLock::new();
    SINK.get_or_init(|| Arc::new(Sink::default()))
}

fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

fn digest(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

impl Sink {
    pub fn set_target(&self, target: Option<HubTarget>) {
        let off = target.is_none();
        *self.target.lock().unwrap() = target;
        if off {
            // Turning telemetry off discards anything not yet sent.
            *self.queue.lock().unwrap() = Queue::default();
            self.turns.lock().unwrap().clear();
        }
    }

    pub fn enabled(&self) -> bool {
        self.target.lock().unwrap().is_some()
    }

    fn prompts_enabled(&self) -> bool {
        self.target
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|t| t.prompts)
    }

    pub fn queued(&self) -> usize {
        self.queue.lock().unwrap().events.len()
    }

    fn push(&self, mut event: Map<String, Value>, blob: Option<(String, String)>) {
        event
            .entry("event_id")
            .or_insert_with(|| Value::String(Uuid::new_v4().to_string()));
        event
            .entry("ts")
            .or_insert_with(|| Value::String(now_iso()));
        let mut queue = self.queue.lock().unwrap();
        queue.events.push_back(Value::Object(event));
        while queue.events.len() > QUEUE_CAP {
            queue.events.pop_front();
        }
        if let Some((key, text)) = blob {
            queue.blobs.insert(key, text);
        }
        if queue.events.len() >= BATCH_SIZE {
            self.wake.notify_one();
        }
    }

    /// Accept events from a client. Returns how many were kept; all are
    /// dropped while telemetry is off.
    pub fn accept_client(&self, events: &[Value]) -> usize {
        if !self.enabled() {
            return 0;
        }
        events
            .iter()
            .filter_map(|e| sanitize(e, true).ok())
            .map(|e| self.push(e, None))
            .count()
    }

    /// Record a Core-side event (already shaped as an allowlisted event).
    pub fn record(&self, event: Value) {
        if !self.enabled() {
            return;
        }
        if let Ok(event) = sanitize(&event, false) {
            self.push(event, None);
        }
    }

    /// Feed control events: user messages start a turn (and, if allowed,
    /// emit a scrubbed prompt), assistant messages end it.
    pub fn observe(&self, event: &AgentEvent, harness: Option<&str>) {
        if !self.enabled() {
            return;
        }
        match event {
            AgentEvent::UserMessage {
                content,
                queued: false,
                mission_id: Some(mission_id),
                source,
                ..
            } if source.as_deref().is_some_and(|s| s.starts_with("api:")) => {
                let prompt_digest = digest(content);
                {
                    let mut turns = self.turns.lock().unwrap();
                    let turn = turns.entry(*mission_id).or_default();
                    turn.resent = turn.last_prompt_digest.as_deref() == Some(&prompt_digest);
                    turn.last_prompt_digest = Some(prompt_digest);
                    turn.started = Some(Instant::now());
                }
                if self.prompts_enabled() {
                    let scrubbed = scrub_secrets(content);
                    let key = digest(&scrubbed);
                    let event = serde_json::json!({
                        "schema": "orb.prompt.v1",
                        "client": "core",
                        "session_id": mission_id.to_string(),
                        "prompt_digest": key,
                        "chars": scrubbed.chars().count(),
                    });
                    if let Ok(event) = sanitize(&event, false) {
                        self.push(event, Some((key, scrubbed)));
                    }
                }
            }
            AgentEvent::AssistantMessage {
                success,
                cost_cents,
                usage,
                model,
                mission_id: Some(mission_id),
                ..
            } => {
                let turn = self.turns.lock().unwrap().remove(mission_id);
                let mut event = serde_json::json!({
                    "schema": "orb.turn.v1",
                    "client": "core",
                    "session_id": mission_id.to_string(),
                    "cost_cents": cost_cents,
                    "interrupted": !success,
                    "resent": turn.as_ref().is_some_and(|t| t.resent),
                });
                let obj = event.as_object_mut().unwrap();
                if let Some(model) = model {
                    obj.insert("model".into(), model.clone().into());
                }
                if let Some(harness) = harness {
                    obj.insert("harness".into(), harness.into());
                }
                if let Some(usage) = usage {
                    obj.insert("input_tokens".into(), usage.input_tokens.into());
                    obj.insert("output_tokens".into(), usage.output_tokens.into());
                    if let Some(cached) = usage.cache_read_input_tokens {
                        obj.insert("cache_read_tokens".into(), cached.into());
                    }
                }
                if let Some(started) = turn.and_then(|t| t.started) {
                    obj.insert(
                        "latency_ms".into(),
                        (started.elapsed().as_millis() as u64).into(),
                    );
                }
                self.record(event);
            }
            _ => {}
        }
    }

    /// Send up to one batch. Failed batches stay queued and back off;
    /// a permanent 4xx (bad token, wrong namespace) drops the batch.
    pub async fn flush_once(&self, client: &reqwest::Client) -> Result<usize, String> {
        let Some(target) = self.target.lock().unwrap().clone() else {
            return Ok(0);
        };
        let (events, blobs) = {
            let queue = self.queue.lock().unwrap();
            if queue.events.is_empty() || queue.retry_at.is_some_and(|t| Instant::now() < t) {
                return Ok(0);
            }
            let events: Vec<Value> = queue.events.iter().take(BATCH_SIZE).cloned().collect();
            let blobs: BTreeMap<String, String> = events
                .iter()
                .filter_map(|e| e.get("prompt_digest").and_then(Value::as_str))
                .filter_map(|k| queue.blobs.get(k).map(|v| (k.to_string(), v.clone())))
                .collect();
            (events, blobs)
        };
        let count = events.len();
        let url = format!(
            "{}/v2/ns/{}/ingest",
            target.url.trim_end_matches('/'),
            target.namespace
        );
        let result = client
            .post(&url)
            .bearer_auth(&target.token)
            .timeout(Duration::from_secs(20))
            .json(&serde_json::json!({ "events": events, "blobs": blobs }))
            .send()
            .await;
        let mut queue = self.queue.lock().unwrap();
        let outcome = match result {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) => {
                let status = resp.status();
                let retry = status.is_server_error()
                    || status == reqwest::StatusCode::TOO_MANY_REQUESTS
                    || status == reqwest::StatusCode::REQUEST_TIMEOUT;
                Err((format!("hub returned {status}"), retry))
            }
            // reqwest errors carry the URL, never the bearer token.
            Err(e) => Err((format!("hub unreachable: {}", e.without_url()), true)),
        };
        if matches!(outcome, Ok(()) | Err((_, false))) {
            {
                for _ in 0..count.min(queue.events.len()) {
                    queue.events.pop_front();
                }
                for key in blobs.keys() {
                    queue.blobs.remove(key);
                }
            }
        }
        match outcome {
            Ok(()) => {
                queue.failures = 0;
                queue.retry_at = None;
                queue.last_error = None;
                Ok(count)
            }
            Err((message, retry)) => {
                if retry {
                    queue.failures = queue.failures.saturating_add(1);
                    let backoff = FLUSH_INTERVAL
                        .saturating_mul(1 << queue.failures.min(5))
                        .min(MAX_BACKOFF);
                    queue.retry_at = Some(Instant::now() + backoff);
                }
                tracing::warn!(
                    events = count,
                    retry,
                    "usage telemetry flush failed: {message}"
                );
                queue.last_error = Some(message.clone());
                Err(message)
            }
        }
    }

    #[cfg(test)]
    fn clear_backoff(&self) {
        self.queue.lock().unwrap().retry_at = None;
    }
}

/// Resolve the hub target from settings. `None` (telemetry off) unless it is
/// enabled with a namespace other than `community` and a token.
pub async fn resolve_target(
    settings: &OrbTelemetrySettings,
    working_dir: &std::path::Path,
) -> Option<HubTarget> {
    if !settings.enabled {
        return None;
    }
    let namespace = settings
        .namespace
        .as_deref()
        .map(str::trim)
        .filter(|ns| valid_namespace(ns))?;
    let encrypted = settings.encrypted_token.as_deref()?.trim();
    let key = super::bitwarden::load_encryption_key(working_dir).await?;
    let token = env_crypto::decrypt_value(&key, encrypted).ok()?;
    Some(HubTarget {
        url: settings
            .hub_url
            .clone()
            .unwrap_or_else(|| DEFAULT_HUB_URL.to_string()),
        namespace: namespace.to_string(),
        token: token.trim().to_string(),
        prompts: settings.prompts_enabled,
    })
}

fn hub_url_allowed(url: &str) -> bool {
    let Ok(parsed) = reqwest::Url::parse(url) else {
        return false;
    };
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return false;
    }
    match parsed.scheme() {
        "https" => parsed.host().is_some(),
        "http" => matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "[::1]")),
        _ => false,
    }
}

fn valid_namespace(ns: &str) -> bool {
    ns != "community"
        && (1..=40).contains(&ns.len())
        && ns
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
}

/// Load the target from settings and run the flush loop.
pub fn spawn(state: Arc<AppState>) {
    tokio::spawn(async move {
        let settings = state.settings.get_orb_telemetry().await;
        global().set_target(resolve_target(&settings, &state.config.working_dir).await);
        let sink = Arc::clone(global());
        loop {
            tokio::select! {
                _ = tokio::time::sleep(FLUSH_INTERVAL) => {}
                _ = sink.wake.notified() => {}
            }
            while let Ok(sent) = sink.flush_once(&state.http_client).await {
                if sent < BATCH_SIZE {
                    break;
                }
            }
        }
    });
}

// ---------------------------------------------------------------------------
// HTTP API (`/api/usage-telemetry`)

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/", get(get_status))
        .route("/config", put(update_config))
        .route("/events", post(post_events))
}

#[derive(Debug, Serialize)]
pub struct StatusResponse {
    pub enabled: bool,
    pub prompts_enabled: bool,
    pub active: bool,
    pub hub_url: String,
    pub namespace: Option<String>,
    pub token_configured: bool,
    pub queued: usize,
    pub last_error: Option<String>,
}

async fn get_status(State(state): State<Arc<AppState>>) -> Json<StatusResponse> {
    let settings = state.settings.get_orb_telemetry().await;
    let sink = global();
    Json(StatusResponse {
        enabled: settings.enabled,
        prompts_enabled: settings.prompts_enabled,
        active: sink.enabled(),
        hub_url: settings
            .hub_url
            .unwrap_or_else(|| DEFAULT_HUB_URL.to_string()),
        namespace: settings.namespace,
        token_configured: settings.encrypted_token.is_some(),
        queued: sink.queued(),
        last_error: sink.queue.lock().unwrap().last_error.clone(),
    })
}

#[derive(Debug, Deserialize)]
pub struct ConfigRequest {
    pub enabled: Option<bool>,
    pub prompts_enabled: Option<bool>,
    pub hub_url: Option<String>,
    pub namespace: Option<String>,
    /// `tl_live_` token; empty string clears it.
    pub token: Option<String>,
}

async fn update_config(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ConfigRequest>,
) -> Result<Json<StatusResponse>, (StatusCode, String)> {
    let mut settings = state.settings.get_orb_telemetry().await;
    if let Some(enabled) = req.enabled {
        settings.enabled = enabled;
    }
    if let Some(prompts) = req.prompts_enabled {
        settings.prompts_enabled = prompts;
    }
    if let Some(url) = req.hub_url {
        let url = url.trim().trim_end_matches('/');
        if !url.is_empty() && !hub_url_allowed(url) {
            return Err((
                StatusCode::BAD_REQUEST,
                "hub_url must be https (http only on loopback)".into(),
            ));
        }
        let url = (!url.is_empty()).then(|| url.to_string());
        // The stored token is only ever sent to the host it was entered for.
        if url != settings.hub_url && req.token.is_none() {
            settings.encrypted_token = None;
        }
        settings.hub_url = url;
    }
    if let Some(ns) = req.namespace {
        let ns = ns.trim();
        if !ns.is_empty() && !valid_namespace(ns) {
            return Err((
                StatusCode::BAD_REQUEST,
                "namespace must be [a-z0-9_-]{1,40} and not community".into(),
            ));
        }
        settings.namespace = (!ns.is_empty()).then(|| ns.to_string());
    }
    if let Some(token) = req.token {
        let token = token.trim();
        settings.encrypted_token = if token.is_empty() {
            None
        } else {
            let key = super::bitwarden::load_encryption_key(&state.config.working_dir)
                .await
                .ok_or((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Encryption key unavailable".to_string(),
                ))?;
            Some(env_crypto::encrypt_value(&key, token).map_err(|_| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Failed to encrypt telemetry token".to_string(),
                )
            })?)
        };
    }
    if settings.prompts_enabled && !settings.enabled {
        settings.prompts_enabled = false;
    }
    state
        .settings
        .set_orb_telemetry(settings.clone())
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    global().set_target(resolve_target(&settings, &state.config.working_dir).await);
    Ok(get_status(State(state)).await)
}

#[derive(Debug, Deserialize)]
pub struct EventsRequest {
    pub events: Vec<Value>,
}

#[derive(Debug, Serialize)]
pub struct EventsResponse {
    pub enabled: bool,
    pub accepted: usize,
}

async fn post_events(Json(req): Json<EventsRequest>) -> (StatusCode, Json<EventsResponse>) {
    let sink = global();
    let accepted = sink.accept_client(&req.events[..req.events.len().min(BATCH_SIZE)]);
    (
        StatusCode::ACCEPTED,
        Json(EventsResponse {
            enabled: sink.enabled(),
            accepted,
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn fixture() -> Value {
        serde_json::from_str(SPEC_JSON).unwrap()
    }

    fn target(url: String) -> HubTarget {
        HubTarget {
            url,
            namespace: "th0rgal".into(),
            token: "tl_live_testtoken".into(),
            prompts: true,
        }
    }

    #[test]
    fn sanitize_matches_shared_fixture() {
        for case in fixture()["sanitize"].as_array().unwrap() {
            let out = sanitize(&case["in"], true).unwrap();
            assert_eq!(Value::Object(out), case["out"], "{}", case["name"]);
        }
        for case in fixture()["rejected"].as_array().unwrap() {
            assert!(sanitize(&case["in"], true).is_err(), "{}", case["reason"]);
        }
    }

    #[test]
    fn scrub_matches_shared_fixture() {
        for case in fixture()["scrub"].as_array().unwrap() {
            assert_eq!(
                scrub_secrets(case["in"].as_str().unwrap()),
                case["out"].as_str().unwrap()
            );
        }
    }

    #[tokio::test]
    async fn off_by_default_drops_everything() {
        let settings = crate::settings::Settings::default();
        assert!(settings.orb_telemetry.is_none());
        let defaults = OrbTelemetrySettings::default();
        assert!(!defaults.enabled && !defaults.prompts_enabled);
        let dir = tempfile::tempdir().unwrap();
        assert!(resolve_target(&defaults, dir.path()).await.is_none());

        let sink = Sink::default();
        let event = &fixture()["sanitize"][0]["in"];
        assert_eq!(sink.accept_client(std::slice::from_ref(event)), 0);
        sink.observe(
            &AgentEvent::UserMessage {
                id: Uuid::new_v4(),
                content: "hello".into(),
                queued: false,
                mission_id: Some(Uuid::new_v4()),
                source: Some("api:1".into()),
            },
            None,
        );
        assert_eq!(sink.queued(), 0);
        let client = reqwest::Client::new();
        assert_eq!(sink.flush_once(&client).await, Ok(0));
    }

    #[test]
    fn hub_url_requires_https_off_loopback() {
        assert!(hub_url_allowed("https://telemetry.thomas.md"));
        assert!(hub_url_allowed("http://127.0.0.1:18895"));
        assert!(!hub_url_allowed("http://169.254.169.254"));
        assert!(!hub_url_allowed("file:///etc/passwd"));
        assert!(!hub_url_allowed("https://telemetry.thomas.md@evil.example"));
    }

    #[test]
    fn community_namespace_is_refused() {
        assert!(!valid_namespace("community"));
        assert!(valid_namespace("th0rgal"));
        assert!(!valid_namespace("Th0rgal"));
    }

    #[test]
    fn prompts_are_scrubbed_into_blobs() {
        let sink = Sink::default();
        sink.set_target(Some(target("http://127.0.0.1:1".into())));
        let mission = Uuid::new_v4();
        let message = AgentEvent::UserMessage {
            id: Uuid::new_v4(),
            content: "deploy with OPENAI_API_KEY=supersecretvalue123".into(),
            queued: false,
            mission_id: Some(mission),
            source: Some("api:1".into()),
        };
        sink.observe(&message, Some("claudecode"));
        sink.observe(&message, Some("claudecode"));
        sink.observe(
            &AgentEvent::AssistantMessage {
                id: Uuid::new_v4(),
                content: "done".into(),
                success: true,
                cost_cents: 3,
                cost_source: crate::agents::CostSource::default(),
                usage: None,
                model: Some("claude-opus-5-5".into()),
                model_normalized: None,
                mission_id: Some(mission),
                shared_files: None,
                resumable: false,
                completion_evidence: None,
            },
            Some("claudecode"),
        );
        let queue = sink.queue.lock().unwrap();
        assert_eq!(queue.events.len(), 3);
        assert!(queue
            .blobs
            .values()
            .all(|b| b == "deploy with OPENAI_API_KEY=[REDACTED]"));
        let turn = &queue.events[2];
        assert_eq!(turn["schema"], "orb.turn.v1");
        assert_eq!(turn["harness"], "claudecode");
        assert_eq!(turn["resent"], true);
        assert!(turn.get("latency_ms").is_some());
        let serialized = serde_json::to_string(&queue.events).unwrap();
        assert!(!serialized.contains("supersecretvalue123"));
    }

    async fn hub(fail_first: usize) -> (String, Arc<AtomicUsize>, Arc<Mutex<Vec<Value>>>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let bodies = Arc::new(Mutex::new(Vec::new()));
        let (c, b) = (Arc::clone(&calls), Arc::clone(&bodies));
        let app = Router::new().route(
            "/v2/ns/th0rgal/ingest",
            post(
                move |headers: axum::http::HeaderMap, Json(body): Json<Value>| {
                    let (c, b) = (Arc::clone(&c), Arc::clone(&b));
                    async move {
                        assert_eq!(
                            headers["authorization"].to_str().unwrap(),
                            "Bearer tl_live_testtoken"
                        );
                        if c.fetch_add(1, Ordering::SeqCst) < fail_first {
                            return StatusCode::SERVICE_UNAVAILABLE;
                        }
                        b.lock().unwrap().push(body);
                        StatusCode::OK
                    }
                },
            ),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        (format!("http://{addr}"), calls, bodies)
    }

    fn action(n: usize) -> Value {
        serde_json::json!({
            "schema": "orb.action.v1",
            "event_id": format!("evt-action-{n:05}"),
            "client": "desktop",
            "action": "queue",
        })
    }

    #[tokio::test]
    async fn batches_events_per_post() {
        let (url, calls, bodies) = hub(0).await;
        let sink = Sink::default();
        sink.set_target(Some(target(url)));
        let events: Vec<Value> = (0..BATCH_SIZE + 5).map(action).collect();
        assert_eq!(sink.accept_client(&events[..BATCH_SIZE]), BATCH_SIZE);
        assert_eq!(sink.accept_client(&events[BATCH_SIZE..]), 5);
        let client = reqwest::Client::new();
        assert_eq!(sink.flush_once(&client).await, Ok(BATCH_SIZE));
        assert_eq!(sink.flush_once(&client).await, Ok(5));
        assert_eq!(sink.flush_once(&client).await, Ok(0));
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        let bodies = bodies.lock().unwrap();
        assert_eq!(bodies[0]["events"].as_array().unwrap().len(), BATCH_SIZE);
        assert_eq!(bodies[1]["events"][4]["event_id"], "evt-action-00204");
    }

    #[tokio::test]
    async fn retries_after_server_error_without_losing_events() {
        let (url, calls, bodies) = hub(1).await;
        let sink = Sink::default();
        sink.set_target(Some(target(url)));
        sink.accept_client(&[action(1), action(2)]);
        let client = reqwest::Client::new();
        assert!(sink.flush_once(&client).await.is_err());
        assert_eq!(sink.queued(), 2);
        // Backing off: no request until the retry time passes.
        assert_eq!(sink.flush_once(&client).await, Ok(0));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        sink.clear_backoff();
        assert_eq!(sink.flush_once(&client).await, Ok(2));
        assert_eq!(sink.queued(), 0);
        assert_eq!(bodies.lock().unwrap().len(), 1);
    }

    /// End-to-end against a running `telemetry-hub serve`:
    /// `ORB_TELEMETRY_E2E_URL=http://127.0.0.1:18895 ORB_TELEMETRY_E2E_TOKEN=tl_live_…
    /// cargo test --lib usage_telemetry::tests::e2e -- --ignored`
    #[tokio::test]
    #[ignore = "needs a local telemetry-hub"]
    async fn e2e_against_local_hub() {
        let url = std::env::var("ORB_TELEMETRY_E2E_URL").unwrap();
        let token = std::env::var("ORB_TELEMETRY_E2E_TOKEN").unwrap();
        let sink = Sink::default();
        sink.set_target(Some(HubTarget {
            url: url.clone(),
            namespace: "th0rgal".into(),
            token: token.clone(),
            prompts: true,
        }));
        let run = Uuid::new_v4().simple().to_string();
        let mut events: Vec<Value> = fixture()["sanitize"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["in"].clone())
            .collect();
        for event in &mut events {
            event["event_id"] = format!("{}-{run}", event["event_id"].as_str().unwrap()).into();
        }
        assert_eq!(sink.accept_client(&events), 3);
        let mission = Uuid::new_v4();
        let secret = format!("sk-ant-api03-{run}");
        sink.observe(
            &AgentEvent::UserMessage {
                id: Uuid::new_v4(),
                content: format!("e2e {run} with {secret}"),
                queued: false,
                mission_id: Some(mission),
                source: Some("api:e2e".into()),
            },
            Some("claudecode"),
        );
        sink.observe(
            &AgentEvent::AssistantMessage {
                id: Uuid::new_v4(),
                content: "done".into(),
                success: true,
                cost_cents: 7,
                cost_source: crate::agents::CostSource::default(),
                usage: Some(crate::cost::TokenUsage {
                    input_tokens: 1200,
                    output_tokens: 300,
                    cache_creation_input_tokens: None,
                    cache_read_input_tokens: Some(800),
                }),
                model: Some("claude-opus-5-5".into()),
                model_normalized: None,
                mission_id: Some(mission),
                shared_files: None,
                resumable: false,
                completion_evidence: None,
            },
            Some("claudecode"),
        );
        let client = reqwest::Client::new();
        assert_eq!(sink.flush_once(&client).await, Ok(5));

        let got: Value = client
            .get(format!("{url}/v2/ns/th0rgal/events?stream=orb&limit=5000"))
            .bearer_auth(&token)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let text = got.to_string();
        assert!(!text.contains(&secret), "secret reached the hub");
        let list = got
            .get("items")
            .and_then(Value::as_array)
            .expect("event list");
        let page = list
            .iter()
            .find(|e| e["event_id"] == format!("evt-page-0001-{run}").as_str())
            .expect("page event stored");
        assert_eq!(page["stream"], "orb");
        assert_eq!(page["quick_close"], true);
        let turn = list
            .iter()
            .find(|e| {
                e["schema"] == "orb.turn.v1" && e["session_id"] == mission.to_string().as_str()
            })
            .expect("turn event stored");
        assert_eq!(turn["input_tokens"], 1200);
        let prompt = list
            .iter()
            .find(|e| {
                e["schema"] == "orb.prompt.v1" && e["session_id"] == mission.to_string().as_str()
            })
            .expect("prompt event stored");
        let blob = client
            .get(format!(
                "{url}/v2/ns/th0rgal/blobs/{}",
                prompt["prompt_digest"].as_str().unwrap()
            ))
            .bearer_auth(&token)
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(
            blob.contains(&format!("e2e {run} with [REDACTED]")),
            "{blob}"
        );
        assert!(!blob.contains(&secret));
    }

    #[tokio::test]
    async fn turning_off_discards_the_queue() {
        let sink = Sink::default();
        sink.set_target(Some(target("http://127.0.0.1:1".into())));
        sink.accept_client(&[action(1)]);
        sink.set_target(None);
        assert_eq!(sink.queued(), 0);
    }
}
