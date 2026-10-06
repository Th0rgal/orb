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
    Ok(Json(hermes_model_options(&chains, &models)))
}
fn hermes_model_options(chains: &[crate::provider_health::ModelChain], models: &Value) -> Value {
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
    json!({"models":{"items":items}})
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
    worker::receipt(store, e, i).await?;
    outcome
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
        let body = json!({"input":e.turns[i].prompt,"session_id":session,"model":model});
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
        store
            .append_cloud_event(
                e.mission_id,
                Event {
                    run_id: run.clone(),
                    id: event["id"].as_str().ok_or("Missing event identity")?.into(),
                    kind: event["data"]["event"].as_str().unwrap_or("unknown").into(),
                    data: event["data"].clone(),
                },
            )
            .await?;
        let data = &event["data"];
        let kind = data["event"].as_str().unwrap_or("unknown");
        if kind == "message.delta" {
            e.turns[i]
                .result
                .get_or_insert_default()
                .push_str(data["delta"].as_str().unwrap_or(""));
        }
        if kind == "tool.started" {
            e.turns[i].detail = Some(format!("Using {}", data["tool"].as_str().unwrap_or("tool")));
        }
    }
    e.turns[i].cursor = events["cursor"].as_str().map(str::to_owned);
    if events["has_more"] == true {
        return Ok(());
    }
    let t = &mut e.turns[i];
    if let Some(output) = status["output"].as_str() {
        t.result = Some(output.into());
    }
    t.usage = status.get("usage").cloned();
    match status["status"].as_str() {
        Some("completed") => {
            t.phase = Phase::ResponseComplete;
            t.detail = None;
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
            t.artifacts =
                vec![json!({"kind":"hermes_approval","run_id":run,"request":status["approval"]})];
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
    Ok(())
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
