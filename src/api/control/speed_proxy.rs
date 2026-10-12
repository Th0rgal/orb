//! A live, turn-scoped proxy capability. Routing credentials stay on Core;
//! Codex receives only a revocable capability for its selected model and tier.
use crate::{api::oauth_owner::CliProxyEndpoint, codex_speed::Tier};
use axum::{
    body::{Body, Bytes},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use futures::StreamExt;
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, LazyLock, Mutex,
    },
};
use tokio_util::sync::CancellationToken;

struct Selection {
    model: String,
    tier: Tier,
    prefixes: Vec<String>,
    endpoint: CliProxyEndpoint,
    cursor: AtomicUsize,
    cancel: CancellationToken,
}
static SCOPES: LazyLock<Mutex<HashMap<String, Arc<Selection>>>> = LazyLock::new(Default::default);
pub(crate) struct Scope {
    token: String,
    cancel: CancellationToken,
}
impl Drop for Scope {
    fn drop(&mut self) {
        self.cancel.cancel();
        if let Ok(mut scopes) = SCOPES.lock() {
            scopes.remove(&self.token);
        }
    }
}
pub(crate) fn register(
    base: &str,
    model: &str,
    tier: Tier,
    prefixes: Vec<String>,
    endpoint: CliProxyEndpoint,
) -> Result<(Scope, CliProxyEndpoint), String> {
    if prefixes.is_empty() {
        return Err("No compatible subscription route is available".into());
    }
    let token = uuid::Uuid::new_v4().to_string();
    let cancel = CancellationToken::new();
    SCOPES
        .lock()
        .map_err(|_| "Speed routing unavailable")?
        .insert(
            token.clone(),
            Arc::new(Selection {
                model: model.rsplit('/').next().unwrap_or(model).into(),
                tier,
                prefixes,
                endpoint: endpoint.clone(),
                cursor: AtomicUsize::new(0),
                cancel: cancel.clone(),
            }),
        );
    let scoped = CliProxyEndpoint {
        base_url: format!("{}/api/llm/codex-speed", base.trim_end_matches('/')),
        api_key: token.clone(),
        identity_url: Some(endpoint.base_url),
    };
    Ok((Scope { token, cancel }, scoped))
}
fn selection(headers: &HeaderMap) -> Option<Arc<Selection>> {
    let token = headers
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")?;
    SCOPES
        .lock()
        .ok()?
        .get(token)
        .cloned()
        .filter(|scope| !scope.cancel.is_cancelled())
}
fn refusal(status: StatusCode, message: &str) -> Response {
    (status,axum::Json(serde_json::json!({"error":{"message":message,"code":"unsupported_service_tier","type":"error"}}))).into_response()
}
pub async fn models(headers: HeaderMap) -> Response {
    let Some(scope) = selection(&headers) else {
        return refusal(
            StatusCode::UNAUTHORIZED,
            "Speed capability expired; resume the mission before retrying.",
        );
    };
    axum::Json(serde_json::json!({"object":"list","data":[{"id":scope.model,"object":"model","owned_by":"openai"}]})).into_response()
}
pub async fn responses(headers: HeaderMap, body: Bytes) -> Response {
    let Some(scope) = selection(&headers) else {
        return refusal(
            StatusCode::UNAUTHORIZED,
            "Speed capability expired; resume the mission before retrying.",
        );
    };
    let mut request: serde_json::Value = match serde_json::from_slice(&body) {
        Ok(value) => value,
        Err(_) => return refusal(StatusCode::BAD_REQUEST, "Invalid Codex request"),
    };
    if request
        .get("previous_response_id")
        .is_some_and(|value| !value.is_null())
    {
        return refusal(StatusCode::BAD_REQUEST,"Codex must replay conversation input on this subscription route; previous_response_id is unsupported.");
    }
    if request["model"].as_str() != Some(&scope.model)
        || request
            .get("service_tier")
            .is_some_and(|value| !value.is_null() && value.as_str() != Some(scope.tier.wire()))
    {
        return refusal(StatusCode::BAD_REQUEST,"Codex did not apply the selected model and speed. No request was sent to a subscription.");
    }
    // The custom-provider CLI can omit service_tier. This revocable capability
    // already binds the operator-selected tier; transport owns its wire value.
    request["service_tier"] = serde_json::json!(scope.tier.wire());
    let client = match reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
    {
        Ok(client) => client,
        Err(_) => {
            return refusal(
                StatusCode::SERVICE_UNAVAILABLE,
                "Speed transport unavailable",
            )
        }
    };
    let start = scope.cursor.load(Ordering::Relaxed);
    let mut last = None;
    for offset in 0..scope.prefixes.len() {
        let index = (start + offset) % scope.prefixes.len();
        request["model"] = serde_json::json!(format!("{}/{}", scope.prefixes[index], scope.model));
        let pending = client
            .post(format!("{}/responses", scope.endpoint.openai_v1_url()))
            .bearer_auth(&scope.endpoint.api_key)
            .header(header::CONTENT_TYPE, "application/json")
            .json(&request)
            .send();
        let response = tokio::select! {_ = scope.cancel.cancelled()=>return refusal(StatusCode::CONFLICT,"Codex turn stopped"),response=pending=>match response{Ok(response)=>response,Err(_)=>{scope.cursor.store(index+1,Ordering::Relaxed);continue;}}};
        if response.status().as_u16() == 429
            || response.status().as_u16() == 401
            || response.status().as_u16() == 403
            || response.status().is_server_error()
        {
            scope.cursor.store(index + 1, Ordering::Relaxed);
            last = Some(response);
            continue;
        }
        return relay(response, scope.cancel.clone());
    }
    match last{Some(response)=>relay(response,scope.cancel.clone()),None=>refusal(StatusCode::SERVICE_UNAVAILABLE,"Compatible subscriptions are temporarily unavailable. The selected speed was not downgraded.")}
}
fn relay(response: reqwest::Response, cancel: CancellationToken) -> Response {
    let status = response.status();
    let headers = response.headers().clone();
    let stream = futures::stream::unfold(
        (response.bytes_stream(), cancel),
        |(mut source, cancel)| async move {
            tokio::select! {_ = cancel.cancelled()=>None,item=source.next()=>item.map(|item|(item,(source,cancel)))}
        },
    );
    let mut out = Response::new(Body::from_stream(stream));
    *out.status_mut() = status;
    for (key, value) in &headers {
        if key == header::CONTENT_TYPE
            || key == header::RETRY_AFTER
            || key.as_str().starts_with("x-codex-")
        {
            out.headers_mut().insert(key.clone(), value.clone());
        }
    }
    out
}
