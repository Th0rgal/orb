//! Paloma is a server-owned Hermes profile, never a browser-held credential.
use super::*;
use crate::{
    api::{auth::AuthUser, mission_store::MissionStore, routes::AppState, system},
    config::Config,
};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Extension, Json,
};
use serde_json::json;
use std::{sync::Arc, time::Duration};

type Error = (StatusCode, String);
pub fn allowed(user: &str) -> bool {
    std::env::var("HERMES_CLOUD_OWNER").is_ok_and(|owner| owner == user)
}
struct Hermes {
    client: reqwest::Client,
    url: String,
    key: String,
}
impl Hermes {
    async fn connect(config: &Config, user: &str) -> Result<Self, String> {
        if !allowed(user) {
            return Err("Hermes is not connected for this account".into());
        }
        Ok(Self {
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(20))
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .map_err(|e| e.to_string())?,
            url: system::hermes_api_server_url(config),
            key: system::hermes_api_server_key_for_config(config).await?,
        })
    }
    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
        key: Option<&str>,
    ) -> Result<Value, String> {
        let mut req = self
            .client
            .request(method, format!("{}{}", self.url, path))
            .bearer_auth(&self.key);
        if let Some(body) = body {
            req = req.json(&body);
        }
        if let Some(key) = key {
            req = req.header("Idempotency-Key", key);
        }
        let response = req
            .send()
            .await
            .map_err(|_| "Hermes connection lost; execution will be reconciled")?;
        if !response.status().is_success() {
            return Err(match response.status().as_u16() {
                400 | 422 => {
                    "Hermes rejected this turn; check the selected model and profile configuration"
                }
                401 | 403 => "Hermes authorization failed; reconnect the profile",
                404 => "Hermes execution or capability is unavailable; no replacement was launched",
                409 => "Hermes request conflicts with an existing operation",
                _ => "Hermes request failed; execution will be reconciled",
            }
            .into());
        }
        response
            .json()
            .await
            .map_err(|_| "Invalid Hermes response".into())
    }
    async fn get(&self, path: &str) -> Result<Value, String> {
        self.call(reqwest::Method::GET, path, None, None).await
    }
    async fn capabilities(&self) -> Result<(), String> {
        let c = self.get("/v1/capabilities").await?;
        if c.pointer("/features/runs_idempotency/durable")
            .and_then(Value::as_bool)
            != Some(true)
            || c.pointer("/features/run_events_replay")
                .and_then(Value::as_bool)
                != Some(true)
        {
            return Err("Update Hermes to support durable run submission and event replay".into());
        }
        Ok(())
    }
}
async fn probe(h: &Hermes) -> Result<(), String> {
    tokio::time::timeout(Duration::from_millis(750), h.capabilities())
        .await
        .unwrap_or_else(|_| {
            Err("Hermes is not responding; other cloud services remain available".into())
        })
}
pub async fn account(state: &AppState, user: &str) -> Account {
    let result = async {
        let h = Hermes::connect(&state.config, user).await?;
        probe(&h).await
    }
    .await;
    Account {
        id: "paloma".into(),
        provider: Provider::Hermes,
        label: "Paloma".into(),
        available: result.is_ok(),
        experimental: false,
        reason: result.err(),
        capabilities: Capabilities {
            models: true,
            attachments: true,
            follow_up: true,
            cancel: true,
            detailed_events: true,
            ..Default::default()
        },
    }
}
pub async fn options(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<Value>, Error> {
    let h = Hermes::connect(&state.config, &user.id)
        .await
        .map_err(bad)?;
    h.capabilities().await.map_err(bad)?;
    let models = h.get("/v1/models").await.map_err(bad)?;
    let chains = state.chain_store.list().await;
    let direct_models = crate::api::proxy::collect_routable_catalog_models(&state).await;
    Ok(Json(hermes_model_options_with_catalog(
        &chains,
        &models,
        &direct_models,
    )))
}
fn hermes_effort_options() -> Value {
    json!([
        {"id": "", "name": "Default"},
        {"id": "none", "name": "Off"},
        {"id": "low", "name": "Low"},
        {"id": "medium", "name": "Medium"},
        {"id": "high", "name": "High"},
        {"id": "xhigh", "name": "Extra High"}
    ])
}
fn hermes_model_options(chains: &[crate::provider_health::ModelChain], models: &Value) -> Value {
    hermes_model_options_with_catalog(chains, models, &[])
}
fn hermes_model_options_with_catalog(
    chains: &[crate::provider_health::ModelChain],
    models: &Value,
    direct_models: &[crate::api::providers::CatalogModelOption],
) -> Value {
    let mut seen = std::collections::HashSet::from([String::new(), "hermes-agent".to_string()]);
    let mut items = vec![json!({"id":"","name":"Profile default"})];
    for chain in chains {
        let id = if chain.id.starts_with("builtin/") {
            chain.id.clone()
        } else {
            format!("builtin/{}", chain.id)
        };
        if seen.insert(id.clone()) {
            let name = if chain.name.trim().is_empty() || chain.name == id {
                id.clone()
            } else {
                format!("{} · {id}", chain.name.trim())
            };
            items.push(json!({"id":id,"name":name}));
        }
    }
    for id in models["data"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| m["id"].as_str())
    {
        if seen.insert(id.to_string()) {
            items.push(json!({"id":id,"name":id}));
        }
    }
    for m in direct_models {
        let id = if !m.value.trim().is_empty() && m.value.contains('/') {
            m.value.clone()
        } else if m.id.contains('/') {
            m.id.clone()
        } else {
            format!("{}/{}", m.provider_id, m.id)
        };
        if seen.insert(id.clone()) {
            let name = if m.name.trim().is_empty() || m.name == m.id || m.name == id {
                id.clone()
            } else {
                format!("{} · {id}", m.name.trim())
            };
            items.push(json!({"id":id,"name":name}));
        }
    }
    json!({"models":{"items":items},"efforts":hermes_effort_options()})
}
fn turn_effort(turn: &Turn, selection: &Selection) -> Option<String> {
    let params = if !turn.model_params.is_empty() {
        &turn.model_params
    } else {
        &selection.model_params
    };
    params
        .iter()
        .find(|p| matches!(p.id.as_str(), "effort" | "reasoning_effort"))
        .map(|p| p.value.trim().to_ascii_lowercase())
        .filter(|v| !v.is_empty() && v != "default")
}
fn effort_to_hermes_reasoning(effort: Option<&str>) -> Option<Value> {
    match effort {
        Some("none") => Some(json!({"enabled": false})),
        Some(e @ ("minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra")) => {
            Some(json!({"enabled": true, "effort": e}))
        }
        _ => None,
    }
}
fn bad(error: String) -> Error {
    (StatusCode::BAD_GATEWAY, error)
}
fn run_path(run: &str, suffix: &str) -> Result<String, String> {
    if run.is_empty()
        || !run
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return Err("Invalid Hermes run identity".into());
    }
    Ok(format!("/v1/runs/{run}{suffix}"))
}
pub async fn approval(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, Error> {
    let store = state.control.get_or_spawn(&user).await.mission_store;
    let e = store
        .cloud_executions()
        .await
        .map_err(bad)?
        .into_iter()
        .find(|e| e.mission_id == id && e.selection.provider == Provider::Hermes)
        .ok_or((StatusCode::NOT_FOUND, "Hermes mission not found".into()))?;
    let run = body["run_id"]
        .as_str()
        .ok_or((StatusCode::BAD_REQUEST, "Missing run identity".into()))?;
    let request = body["request_id"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or((StatusCode::BAD_REQUEST, "Missing approval identity".into()))?;
    let choice = body["choice"]
        .as_str()
        .ok_or((StatusCode::BAD_REQUEST, "Missing approval choice".into()))?;
    if !e.turns.iter().any(|t| {
        t.external_id.as_deref() == Some(run)
            && t.phase == Phase::WaitingUser
            && t.artifacts.iter().any(|a| {
                a["request"]["request_id"] == request
                    && a["request"]["choices"]
                        .as_array()
                        .is_some_and(|choices| choices.iter().any(|c| c == choice))
            })
    }) {
        return Err((
            StatusCode::CONFLICT,
            "Approval no longer belongs to the active turn".into(),
        ));
    }
    let h = Hermes::connect(&state.config, &user.id)
        .await
        .map_err(bad)?;
    let payload = json!({"choice":body["choice"],"request_id":body["request_id"]});
    Ok(Json(
        h.call(
            reqwest::Method::POST,
            &run_path(run, "/approval").map_err(bad)?,
            Some(payload),
            None,
        )
        .await
        .map_err(bad)?,
    ))
}
pub async fn tick(
    store: &Arc<dyn MissionStore>,
    mut e: Execution,
    config: &Config,
    user: &str,
) -> Result<(), String> {
    let mission_id = e.mission_id;
    for step in 0..12 {
        let Some(i) = e.turns.iter().position(|t| !t.phase.terminal()) else {
            return Ok(());
        };
        if e.turns[i].phase == Phase::Incompatible {
            return Ok(());
        }
        let outcome = observe(store, &mut e, i, config, user).await;
        if let Err(error) = &outcome {
            if (error.contains("authorization failed") || error.contains("not connected"))
                && matches!(e.turns[i].phase, Phase::Queued | Phase::Running)
            {
                e.turns[i].phase = Phase::ReconnectRequired;
            }
            if error.starts_with("Hermes rejected this turn") {
                e.turns[i].phase = Phase::Failed;
            }
            e.turns[i].detail = Some(error.clone());
        }
        let phase = e.turns[i].phase;
        worker::receipt(store, e.clone(), i).await?;
        if outcome.is_err() || !matches!(phase, Phase::Running | Phase::CancelRequested) {
            return outcome;
        }
        if step + 1 < 12 {
            tokio::time::sleep(Duration::from_millis(350)).await;
            let Some(fresh) = store
                .cloud_executions()
                .await?
                .into_iter()
                .find(|row| row.mission_id == mission_id)
            else {
                return Ok(());
            };
            e = fresh;
        }
    }
    Ok(())
}
async fn observe(
    store: &Arc<dyn MissionStore>,
    e: &mut Execution,
    i: usize,
    config: &Config,
    user: &str,
) -> Result<(), String> {
    let h = Hermes::connect(config, user).await?;
    observe_with_client(store, e, i, &h).await
}
async fn observe_with_client(
    store: &Arc<dyn MissionStore>,
    e: &mut Execution,
    i: usize,
    h: &Hermes,
) -> Result<(), String> {
    if e.selection.account != "paloma" {
        e.turns[i].phase = Phase::Incompatible;
        return Err("Unknown Hermes profile".into());
    }
    if e.turns[i].external_id.is_none() {
        h.capabilities().await?;
        let session = format!("orb_{}", e.mission_id.simple());
        // The stable routing key creates the conversation within the idempotent
        // run admission. No separate, ambiguously acknowledged session POST.
        if e.turns[i].phase == Phase::Queued
            || (e.turns[i].phase == Phase::ReconnectRequired && e.turns[i].cursor.is_none())
        {
            e.turns[i].phase = Phase::Submitting;
            e.turns[i].cursor = Some(format!("submission:{}", chrono::Utc::now().timestamp()));
            *e = worker::save(store, e.clone()).await?;
        }
        let submitted = e.turns[i]
            .cursor
            .as_deref()
            .and_then(|v| v.strip_prefix("submission:"))
            .and_then(|v| v.parse::<i64>().ok());
        if !submitted
            .is_some_and(|s| (0..20 * 60 * 60).contains(&(chrono::Utc::now().timestamp() - s)))
        {
            e.turns[i].phase = Phase::SubmissionUncertain;
            return Err(
                "Submission recovery window expired; inspect Hermes before retrying".into(),
            );
        }
        let model = e.turns[i]
            .model
            .as_ref()
            .or(e.selection.model.as_ref())
            .filter(|s| !s.is_empty());
        let mut body = json!({"input":e.turns[i].prompt,"session_id":session,"model":model});
        let effort = turn_effort(&e.turns[i], &e.selection);
        if let Some(reasoning) = effort_to_hermes_reasoning(effort.as_deref()) {
            body["model_options"] = json!({"reasoning": reasoning});
        }
        let key = format!("orb:{}:{}", e.mission_id, e.turns[i].key);
        let result = h
            .call(reqwest::Method::POST, "/v1/runs", Some(body), Some(&key))
            .await?;
        let run = result["run_id"]
            .as_str()
            .ok_or("Hermes did not return a run identity")?;
        run_path(run, "")?;
        e.external_id = Some(session);
        e.turns[i].external_id = Some(run.into());
        e.turns[i].cursor = None;
        e.turns[i].phase = Phase::Running;
        // Persist acceptance before any status/event calls.
        worker::receipt(store, e.clone(), i).await?;
    }
    let run = e.turns[i].external_id.clone().ok_or("Missing Hermes run")?;
    if e.turns[i].phase == Phase::CancelRequested {
        h.call(
            reqwest::Method::POST,
            &run_path(&run, "/stop")?,
            Some(json!({})),
            None,
        )
        .await?;
    }
    let status = h.get(&run_path(&run, "")?).await?;
    if let Some(session) = status["session_id"].as_str() {
        e.turns[i].session_id = Some(session.into());
    }
    let cursor = e.turns[i]
        .cursor
        .as_deref()
        .unwrap_or("0")
        .parse::<u64>()
        .map_err(|_| "Invalid event cursor")?;
    let events = h
        .get(&run_path(
            &run,
            &format!("/events?format=json&after={cursor}"),
        )?)
        .await?;
    for event in events["events"].as_array().into_iter().flatten() {
        let event_id = event["id"].as_str().ok_or("Missing event identity")?;
        store
            .append_cloud_event(
                e.mission_id,
                Event {
                    run_id: run.clone(),
                    id: event_id.into(),
                    kind: event["data"]["event"].as_str().unwrap_or("unknown").into(),
                    data: event["data"].clone(),
                },
            )
            .await?;
        let data = &event["data"];
        let kind = data["event"].as_str().unwrap_or("unknown");
        match kind {
            "message.delta" => {
                e.turns[i]
                    .result
                    .get_or_insert_default()
                    .push_str(data["delta"].as_str().unwrap_or(""));
            }
            "reasoning.available" => {
                let text = data["text"].as_str().unwrap_or("").trim();
                if !text.is_empty() {
                    let duplicate = e.turns[i].steps.iter().rev().any(|s| {
                        s["kind"] == "think" && s["text"].as_str().map(str::trim) == Some(text)
                    });
                    if !duplicate {
                        e.turns[i].steps.push(json!({
                            "kind": "think",
                            "id": format!("think_{run}_{event_id}"),
                            "text": text,
                            "done": true,
                            "source": "event"
                        }));
                    }
                    if e.turns[i].result.as_deref().unwrap_or("").is_empty() {
                        e.turns[i].detail = Some("Thinking…".into());
                    }
                }
            }
            "tool.started" | "subagent.start" => {
                let tool_name = data["tool"]
                    .as_str()
                    .or_else(|| data["task"].as_str())
                    .unwrap_or("tool");
                let preview = data["preview"].as_str().unwrap_or("");
                let call_id = format!("tool_{run}_{event_id}");
                e.turns[i].detail = Some(format!("Using {tool_name}"));
                e.turns[i].steps.push(json!({
                    "kind": "tool",
                    "id": call_id,
                    "call_id": call_id,
                    "name": tool_name,
                    "status": "running",
                    "done": false,
                    "input": preview,
                    "args": if preview.is_empty() { Value::Null } else { json!({"preview": preview}) }
                }));
            }
            "tool.completed" | "subagent.complete" => {
                let tool_name = data["tool"].as_str().unwrap_or("tool");
                let preview = data["preview"]
                    .as_str()
                    .or_else(|| data["summary"].as_str())
                    .unwrap_or("");
                let is_err = data["error"].as_bool().unwrap_or(false)
                    || data["status"].as_str() == Some("failed");
                let final_status = if is_err { "failed" } else { "completed" };
                let pos = e.turns[i]
                    .steps
                    .iter()
                    .rposition(|s| {
                        s["kind"] == "tool"
                            && s["status"] == "running"
                            && s["name"].as_str() == Some(tool_name)
                    })
                    .or_else(|| {
                        e.turns[i]
                            .steps
                            .iter()
                            .rposition(|s| s["kind"] == "tool" && s["status"] == "running")
                    });
                if let Some(idx) = pos {
                    let step = &mut e.turns[i].steps[idx];
                    step["status"] = json!(final_status);
                    step["done"] = json!(true);
                    if !preview.is_empty() {
                        step["output"] = json!(preview);
                        step["result"] = json!(preview);
                    }
                    if is_err {
                        step["error"] = json!(if preview.is_empty() {
                            "Tool failed"
                        } else {
                            preview
                        });
                    }
                    if let Some(dur) = data.get("duration") {
                        step["duration"] = dur.clone();
                    }
                } else {
                    let call_id = format!("tool_{run}_{event_id}");
                    e.turns[i].steps.push(json!({
                        "kind": "tool",
                        "id": call_id,
                        "call_id": call_id,
                        "name": tool_name,
                        "status": final_status,
                        "done": true,
                        "output": preview,
                        "result": if preview.is_empty() { Value::Null } else { json!(preview) }
                    }));
                }
            }
            _ => {}
        }
    }
    e.turns[i].cursor = events["cursor"].as_str().map(str::to_owned);
    if events["has_more"] == true {
        return Ok(());
    }
    let is_completed = status["status"].as_str() == Some("completed");
    {
        let t = &mut e.turns[i];
        if let Some(output) = status["output"].as_str() {
            t.result = Some(output.into());
        }
        // Hermes `_relay_thinking` also fires `reasoning.available` on the final
        // non-tool turn using `final_response[:500]`. Remove any event-sourced
        // thought that merely echoes the final response.
        if let Some(res) = t
            .result
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
        {
            t.steps.retain(|step| {
                if step["kind"] != "think" || step["source"] != "event" {
                    return true;
                }
                let Some(st) = step["text"].as_str().map(str::trim) else {
                    return true;
                };
                !(!st.is_empty() && (res.starts_with(st) || st.starts_with(&res)))
            });
        }
        t.usage = status.get("usage").cloned();
        match status["status"].as_str() {
            Some("completed") => {
                t.phase = Phase::ResponseComplete;
                t.detail = None;
                for step in &mut t.steps {
                    if step["kind"] == "tool" && step["status"] == "running" {
                        step["status"] = json!("completed");
                        step["done"] = json!(true);
                    }
                }
            }
            Some("failed") => {
                t.phase = Phase::Failed;
                t.detail = Some("Hermes run failed. The conversation is preserved.".into());
            }
            Some("cancelled" | "interrupted") => {
                t.phase = Phase::Cancelled;
                t.detail =
                    Some("Turn interrupted. Continue in the same conversation when ready.".into());
            }
            Some("waiting_for_approval") => {
                t.phase = Phase::WaitingUser;
                t.detail = Some("Waiting for your approval".into());
                t.artifacts = vec![
                    json!({"kind":"hermes_approval","run_id":run,"request":status["approval"]}),
                ];
            }
            Some("stopping") => {
                t.phase = Phase::CancelRequested;
            }
            Some("running" | "queued") => {
                if t.phase != Phase::CancelRequested {
                    t.phase = Phase::Running;
                }
                t.artifacts.clear();
            }
            _ => return Err("Unknown Hermes run state; waiting for reconciliation".into()),
        }
    }
    if is_completed {
        if let Some(session_id) = e.turns[i]
            .session_id
            .clone()
            .or_else(|| e.external_id.clone())
        {
            enrich_steps_from_session_messages(h, &session_id, &mut e.turns[i]).await;
        }
    }
    Ok(())
}

async fn enrich_steps_from_session_messages(h: &Hermes, session_id: &str, turn: &mut Turn) {
    if !session_id
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b':'))
    {
        return;
    }
    let Ok(resp) = h
        .get(&format!("/api/sessions/{session_id}/messages?order=oldest"))
        .await
    else {
        return;
    };
    let Some(messages) = resp["messages"].as_array() else {
        return;
    };
    let start_idx = messages
        .iter()
        .rposition(|m| m["role"].as_str() == Some("user"))
        .map(|idx| idx + 1)
        .unwrap_or(0);
    let mut reasonings = Vec::new();
    for m in &messages[start_idx..] {
        if m["role"].as_str() != Some("assistant") {
            continue;
        }
        if let Some(r) = m["reasoning_content"]
            .as_str()
            .or_else(|| m["reasoning"].as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            reasonings.push(r.to_string());
        }
    }
    for (idx, r) in reasonings.into_iter().enumerate().rev() {
        let already = turn.steps.iter().any(|s| {
            s["kind"] == "think"
                && s["text"]
                    .as_str()
                    .map(str::trim)
                    .is_some_and(|t| t == r || t.contains(&r) || r.contains(t))
        });
        if !already {
            let run_key = turn.external_id.as_deref().unwrap_or(session_id);
            turn.steps.insert(
                0,
                json!({
                    "kind": "think",
                    "id": format!("session_think_{run_key}_{idx}"),
                    "text": r,
                    "done": true,
                    "source": "session"
                }),
            );
        }
    }
}

#[derive(Debug, Default, Deserialize)]
pub struct HermesSettingsUpdateRequest {
    pub default_model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub use_sandboxed_router: Option<bool>,
    pub memory_enabled: Option<bool>,
    pub user_profile_enabled: Option<bool>,
    pub memory_char_limit: Option<u64>,
    pub user_char_limit: Option<u64>,
    pub compression_enabled: Option<bool>,
    pub compression_threshold: Option<f64>,
    pub telegram_tool_progress: Option<String>,
    pub telegram_cleanup_progress: Option<bool>,
    pub soul_markdown: Option<String>,
    pub restart_service: Option<bool>,
}

pub async fn settings(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<Value>, Error> {
    if !allowed(&user.id) {
        return Err((
            StatusCode::FORBIDDEN,
            "Hermes is not connected for this account".into(),
        ));
    }
    Ok(Json(build_hermes_settings_payload(&state, &user.id).await))
}

pub async fn update_settings(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(req): Json<HermesSettingsUpdateRequest>,
) -> Result<Json<Value>, Error> {
    if !allowed(&user.id) {
        return Err((
            StatusCode::FORBIDDEN,
            "Hermes is not connected for this account".into(),
        ));
    }
    if let Some(effort) = req.reasoning_effort.as_deref() {
        if !matches!(
            effort,
            "" | "default"
                | "none"
                | "minimal"
                | "low"
                | "medium"
                | "high"
                | "xhigh"
                | "max"
                | "ultra"
        ) {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("Unsupported reasoning effort: {effort}"),
            ));
        }
    }
    if let Some(progress) = req.telegram_tool_progress.as_deref() {
        if !matches!(progress, "off" | "new" | "edit" | "all" | "verbose") {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("Unsupported Telegram tool_progress value: {progress}"),
            ));
        }
    }
    let runtime_name = system::assistant_runtime_name(&state.config);
    let config_path = format!("/var/lib/{runtime_name}/config.yaml");
    let soul_path = format!("/var/lib/{runtime_name}/SOUL.md");

    if let Ok(raw_yaml) = tokio::fs::read_to_string(&config_path).await {
        let mut doc: serde_yaml::Value = serde_yaml::from_str(&raw_yaml)
            .unwrap_or_else(|_| serde_yaml::Value::Mapping(Default::default()));
        if let Some(root) = doc.as_mapping_mut() {
            let model_key = serde_yaml::Value::String("model".into());
            if !root.contains_key(&model_key) {
                root.insert(
                    model_key.clone(),
                    serde_yaml::Value::Mapping(Default::default()),
                );
            }
            if let Some(model_map) = root
                .get_mut(&model_key)
                .and_then(serde_yaml::Value::as_mapping_mut)
            {
                if let Some(default_model) = &req.default_model {
                    let trimmed = default_model.trim();
                    if !trimmed.is_empty() {
                        model_map.insert(
                            serde_yaml::Value::String("default".into()),
                            serde_yaml::Value::String(trimmed.into()),
                        );
                    }
                }
                if let Some(effort) = &req.reasoning_effort {
                    let trimmed = effort.trim();
                    let k = serde_yaml::Value::String("reasoning_effort".into());
                    if trimmed.is_empty() || trimmed == "default" {
                        model_map.remove(&k);
                    } else {
                        model_map.insert(k, serde_yaml::Value::String(trimmed.into()));
                    }
                }
                if req.use_sandboxed_router == Some(true) {
                    let expected_base = format!("{}/v1", system::local_api_url(&state.config));
                    model_map.insert(
                        serde_yaml::Value::String("provider".into()),
                        serde_yaml::Value::String("custom".into()),
                    );
                    model_map.insert(
                        serde_yaml::Value::String("base_url".into()),
                        serde_yaml::Value::String(expected_base),
                    );
                    model_map.insert(
                        serde_yaml::Value::String("api_mode".into()),
                        serde_yaml::Value::String("chat_completions".into()),
                    );
                }
            }

            let memory_key = serde_yaml::Value::String("memory".into());
            if !root.contains_key(&memory_key) {
                root.insert(
                    memory_key.clone(),
                    serde_yaml::Value::Mapping(Default::default()),
                );
            }
            if let Some(mem_map) = root
                .get_mut(&memory_key)
                .and_then(serde_yaml::Value::as_mapping_mut)
            {
                if let Some(v) = req.memory_enabled {
                    mem_map.insert(
                        serde_yaml::Value::String("memory_enabled".into()),
                        serde_yaml::Value::Bool(v),
                    );
                }
                if let Some(v) = req.user_profile_enabled {
                    mem_map.insert(
                        serde_yaml::Value::String("user_profile_enabled".into()),
                        serde_yaml::Value::Bool(v),
                    );
                }
                if let Some(v) = req.memory_char_limit {
                    mem_map.insert(
                        serde_yaml::Value::String("memory_char_limit".into()),
                        serde_yaml::Value::Number(v.clamp(500, 32_000).into()),
                    );
                }
                if let Some(v) = req.user_char_limit {
                    mem_map.insert(
                        serde_yaml::Value::String("user_char_limit".into()),
                        serde_yaml::Value::Number(v.clamp(250, 16_000).into()),
                    );
                }
            }

            if req.telegram_tool_progress.is_some() || req.telegram_cleanup_progress.is_some() {
                let display_key = serde_yaml::Value::String("display".into());
                if !root.contains_key(&display_key) {
                    root.insert(
                        display_key.clone(),
                        serde_yaml::Value::Mapping(Default::default()),
                    );
                }
                if let Some(display_map) = root
                    .get_mut(&display_key)
                    .and_then(serde_yaml::Value::as_mapping_mut)
                {
                    let platforms_key = serde_yaml::Value::String("platforms".into());
                    if !display_map.contains_key(&platforms_key) {
                        display_map.insert(
                            platforms_key.clone(),
                            serde_yaml::Value::Mapping(Default::default()),
                        );
                    }
                    if let Some(platforms_map) = display_map
                        .get_mut(&platforms_key)
                        .and_then(serde_yaml::Value::as_mapping_mut)
                    {
                        let tg_key = serde_yaml::Value::String("telegram".into());
                        if !platforms_map.contains_key(&tg_key) {
                            platforms_map.insert(
                                tg_key.clone(),
                                serde_yaml::Value::Mapping(Default::default()),
                            );
                        }
                        if let Some(tg_map) = platforms_map
                            .get_mut(&tg_key)
                            .and_then(serde_yaml::Value::as_mapping_mut)
                        {
                            if let Some(p) = &req.telegram_tool_progress {
                                tg_map.insert(
                                    serde_yaml::Value::String("tool_progress".into()),
                                    serde_yaml::Value::String(p.clone()),
                                );
                            }
                            if let Some(c) = req.telegram_cleanup_progress {
                                tg_map.insert(
                                    serde_yaml::Value::String("cleanup_progress".into()),
                                    serde_yaml::Value::Bool(c),
                                );
                            }
                        }
                    }
                }
            }

            if req.compression_enabled.is_some() || req.compression_threshold.is_some() {
                let comp_key = serde_yaml::Value::String("compression".into());
                if !root.contains_key(&comp_key) {
                    root.insert(
                        comp_key.clone(),
                        serde_yaml::Value::Mapping(Default::default()),
                    );
                }
                if let Some(comp_map) = root
                    .get_mut(&comp_key)
                    .and_then(serde_yaml::Value::as_mapping_mut)
                {
                    if let Some(en) = req.compression_enabled {
                        comp_map.insert(
                            serde_yaml::Value::String("enabled".into()),
                            serde_yaml::Value::Bool(en),
                        );
                    }
                    if let Some(th) = req.compression_threshold {
                        if let Ok(val) = serde_yaml::to_value(th.clamp(0.1, 0.95)) {
                            comp_map.insert(serde_yaml::Value::String("threshold".into()), val);
                        }
                    }
                }
            }
        }
        let serialized = serde_yaml::to_string(&doc)
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
        system::write_private_file(&config_path, &serialized)
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    }

    if let Some(default_model) = req.default_model.as_deref().map(str::trim) {
        if !default_model.is_empty() {
            let updates = [("HERMES_ASSISTANT_MODEL", default_model)];
            for env_path in system::hermes_env_paths(runtime_name) {
                if let Ok(contents) = tokio::fs::read_to_string(&env_path).await {
                    let _ = system::write_private_file(
                        &env_path,
                        &system::upsert_env_lines(&contents, &updates),
                    )
                    .await;
                }
            }
        }
    }

    if let Some(soul) = &req.soul_markdown {
        system::write_private_file(&soul_path, soul)
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    }

    if req.restart_service == Some(true) {
        let service_name = format!("{runtime_name}.service");
        let _ = tokio::process::Command::new("systemctl")
            .args(["restart", &service_name])
            .status()
            .await;
    }

    Ok(Json(build_hermes_settings_payload(&state, &user.id).await))
}

async fn build_hermes_settings_payload(state: &Arc<AppState>, user_id: &str) -> Value {
    let runtime = system::build_hermes_runtime_summary(state).await;
    let runtime_name = system::assistant_runtime_name(&state.config);
    let sessions = system::read_hermes_session_rollup(runtime_name).await;
    let home_dir = format!("/var/lib/{runtime_name}");
    let config_path = format!("{home_dir}/config.yaml");
    let soul_path = format!("{home_dir}/SOUL.md");

    let raw_yaml = tokio::fs::read_to_string(&config_path)
        .await
        .unwrap_or_default();
    let yaml_val: serde_yaml::Value =
        serde_yaml::from_str(&raw_yaml).unwrap_or(serde_yaml::Value::Null);

    let default_model = yaml_val
        .get("model")
        .and_then(|m| m.get("default").or_else(|| m.get("name")))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or("")
        .to_string();
    let provider = yaml_val
        .get("model")
        .and_then(|m| m.get("provider"))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or("custom")
        .to_string();
    let base_url = yaml_val
        .get("model")
        .and_then(|m| m.get("base_url"))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or("")
        .to_string();
    let use_sandboxed_router = provider == "custom"
        && (base_url.is_empty()
            || base_url.contains("127.0.0.1:3000")
            || base_url.contains("localhost:3000"));
    let api_mode = yaml_val
        .get("model")
        .and_then(|m| m.get("api_mode"))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or("chat_completions")
        .to_string();
    let reasoning_effort = yaml_val
        .get("model")
        .and_then(|m| m.get("reasoning_effort"))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or("")
        .to_string();
    let memory_enabled = yaml_val
        .get("memory")
        .and_then(|m| m.get("memory_enabled"))
        .and_then(serde_yaml::Value::as_bool)
        .unwrap_or(true);
    let user_profile_enabled = yaml_val
        .get("memory")
        .and_then(|m| m.get("user_profile_enabled"))
        .and_then(serde_yaml::Value::as_bool)
        .unwrap_or(true);
    let memory_char_limit = yaml_val
        .get("memory")
        .and_then(|m| m.get("memory_char_limit"))
        .and_then(serde_yaml::Value::as_u64)
        .unwrap_or(4000);
    let user_char_limit = yaml_val
        .get("memory")
        .and_then(|m| m.get("user_char_limit"))
        .and_then(serde_yaml::Value::as_u64)
        .unwrap_or(2000);
    let compression_enabled = yaml_val
        .get("compression")
        .and_then(|c| c.get("enabled"))
        .and_then(serde_yaml::Value::as_bool)
        .unwrap_or(true);
    let compression_threshold = yaml_val
        .get("compression")
        .and_then(|c| c.get("threshold"))
        .and_then(serde_yaml::Value::as_f64)
        .unwrap_or(0.5);
    let terminal_backend = yaml_val
        .get("terminal")
        .and_then(|t| t.get("backend"))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or("local")
        .to_string();
    let terminal_cwd = yaml_val
        .get("terminal")
        .and_then(|t| t.get("cwd"))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or("")
        .to_string();
    let telegram_tool_progress = yaml_val
        .get("display")
        .and_then(|d| d.get("platforms"))
        .and_then(|p| p.get("telegram"))
        .and_then(|tg| tg.get("tool_progress"))
        .map(|v| match v {
            serde_yaml::Value::Bool(false) => "off".to_string(),
            serde_yaml::Value::Bool(true) => "all".to_string(),
            serde_yaml::Value::String(s) => s.clone(),
            _ => "off".to_string(),
        })
        .unwrap_or_else(|| "off".to_string());
    let telegram_cleanup_progress = yaml_val
        .get("display")
        .and_then(|d| d.get("platforms"))
        .and_then(|p| p.get("telegram"))
        .and_then(|tg| tg.get("cleanup_progress"))
        .and_then(serde_yaml::Value::as_bool)
        .unwrap_or(true);
    let mcp_tools_count = yaml_val
        .get("mcp_servers")
        .and_then(|s| s.get("sandboxed_assistant"))
        .and_then(|a| a.get("tools"))
        .and_then(|t| t.get("include"))
        .and_then(serde_yaml::Value::as_sequence)
        .map(|seq| seq.len())
        .unwrap_or(0);

    let soul_markdown = tokio::fs::read_to_string(&soul_path)
        .await
        .unwrap_or_default();

    let mut capabilities = Value::Null;
    let mut jobs_total = 0usize;
    let mut jobs_enabled = 0usize;
    let mut hermes_models = json!({"data": []});
    if let Ok(h) = Hermes::connect(&state.config, user_id).await {
        if let Ok(c) = h.get("/v1/capabilities").await {
            capabilities = c;
        }
        if let Ok(m) = h.get("/v1/models").await {
            hermes_models = m;
        }
        if let Ok(j) = h.get("/api/jobs?include_disabled=true").await {
            if let Some(arr) = j["jobs"].as_array() {
                jobs_total = arr.len();
                jobs_enabled = arr
                    .iter()
                    .filter(|item| item["enabled"].as_bool().unwrap_or(true))
                    .count();
            }
        }
    }
    let chains = state.chain_store.list().await;
    let direct_models = crate::api::proxy::collect_routable_catalog_models(state).await;
    let options_val = hermes_model_options_with_catalog(&chains, &hermes_models, &direct_models);
    let models = options_val["models"]["items"]
        .as_array()
        .cloned()
        .unwrap_or_default();

    json!({
        "runtime": runtime,
        "sessions": sessions,
        "home_dir": home_dir,
        "config_path": config_path,
        "soul_path": soul_path,
        "default_model": default_model,
        "provider": provider,
        "base_url": base_url,
        "use_sandboxed_router": use_sandboxed_router,
        "api_mode": api_mode,
        "reasoning_effort": reasoning_effort,
        "memory_enabled": memory_enabled,
        "user_profile_enabled": user_profile_enabled,
        "memory_char_limit": memory_char_limit,
        "user_char_limit": user_char_limit,
        "compression_enabled": compression_enabled,
        "compression_threshold": compression_threshold,
        "terminal_backend": terminal_backend,
        "terminal_cwd": terminal_cwd,
        "telegram_tool_progress": telegram_tool_progress,
        "telegram_cleanup_progress": telegram_cleanup_progress,
        "mcp_tools_count": mcp_tools_count,
        "config": {
            "default_model": default_model,
            "provider": provider,
            "base_url": base_url,
            "use_sandboxed_router": use_sandboxed_router,
            "api_mode": api_mode,
            "reasoning_effort": reasoning_effort,
            "memory_enabled": memory_enabled,
            "user_profile_enabled": user_profile_enabled,
            "memory_char_limit": memory_char_limit,
            "user_char_limit": user_char_limit,
            "compression_enabled": compression_enabled,
            "compression_threshold": compression_threshold,
            "terminal_backend": terminal_backend,
            "terminal_cwd": terminal_cwd,
            "telegram_tool_progress": telegram_tool_progress,
            "telegram_cleanup_progress": telegram_cleanup_progress,
            "mcp_tools_count": mcp_tools_count,
        },
        "soul_markdown": soul_markdown,
        "capabilities": capabilities,
        "jobs": {
            "total": jobs_total,
            "enabled": jobs_enabled,
        },
        "models": models,
        "efforts": hermes_effort_options(),
    })
}

/// Read child attempts through Hermes-stamped provenance, including continuation tips.
/// This never changes the project's canonical conversation or execution placement.
pub async fn children(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> Result<Json<Value>, Error> {
    let store = state.control.get_or_spawn(&user).await.mission_store;
    let e = store
        .cloud_executions()
        .await
        .map_err(bad)?
        .into_iter()
        .find(|e| e.mission_id == id && e.selection.provider == Provider::Hermes)
        .ok_or((StatusCode::NOT_FOUND, "Hermes mission not found".into()))?;
    let sessions: std::collections::BTreeSet<_> = e
        .external_id
        .into_iter()
        .chain(e.turns.into_iter().filter_map(|t| t.session_id))
        .collect();
    let mut children = std::collections::BTreeMap::new();
    for session in sessions {
        let filter = crate::api::mission_store::MissionFilter {
            origin_session_id: Some(session),
            ..Default::default()
        };
        // Paginate so long-lived conversations do not lose their older attempts.
        let mut offset = 0;
        loop {
            let rows = store
                .list_missions_filtered(&filter, 100, offset)
                .await
                .map_err(bad)?;
            let count = rows.len();
            for m in rows {
                children.insert(m.id, json!({"id":m.id,"title":m.title,"status":m.status}));
            }
            if count < 100 {
                break;
            }
            offset += count;
        }
    }
    Ok(Json(
        json!({"missions":children.into_values().collect::<Vec<_>>()}),
    ))
}

#[cfg(test)]
#[path = "hermes_tests.rs"]
mod tests;
