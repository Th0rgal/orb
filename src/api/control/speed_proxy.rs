//! A live, turn-scoped proxy capability. Routing credentials stay on Core;
//! Codex receives only a revocable capability for its selected model and tier.
use crate::{api::oauth_owner::CliProxyEndpoint, codex_speed::Tier};
use axum::{
    body::{Body, Bytes},
    extract::State,
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use futures::StreamExt;
use std::{
    collections::HashMap,
    sync::{Arc, LazyLock, Mutex},
};
use tokio_util::sync::CancellationToken;

struct Selection {
    model: String,
    tier: Tier,
    mission_id: uuid::Uuid,
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
    mission_id: uuid::Uuid,
    endpoint: CliProxyEndpoint,
) -> Result<(Scope, CliProxyEndpoint), String> {
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
                mission_id,
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
/// This capability binds caller/model/tier, while Core alone selects accounts.
pub(super) fn prepare_request(
    headers: &HeaderMap,
    body: &Bytes,
    secret: &str,
) -> Result<(HeaderMap, Bytes, CancellationToken), Response> {
    let Some(scope) = selection(headers) else {
        return Err(refusal(
            StatusCode::UNAUTHORIZED,
            "Codex capability expired; resume the mission before retrying.",
        ));
    };
    let mut request: serde_json::Value = match serde_json::from_slice(body) {
        Ok(value) => value,
        Err(_) => return Err(refusal(StatusCode::BAD_REQUEST, "Invalid Codex request")),
    };
    if request
        .get("previous_response_id")
        .is_some_and(|value| !value.is_null())
    {
        return Err(refusal(StatusCode::BAD_REQUEST,"Codex must replay conversation input on this subscription route; previous_response_id is unsupported."));
    }
    if request["model"].as_str() != Some(&scope.model)
        || request
            .get("service_tier")
            .is_some_and(|value| !value.is_null() && value.as_str() != Some(scope.tier.wire()))
    {
        return Err(refusal(StatusCode::BAD_REQUEST,"Codex did not apply the selected model and speed. No request was sent to a subscription."));
    }
    // The custom-provider CLI can omit service_tier. This revocable capability
    // already binds the operator-selected tier; transport owns its wire value.
    request["service_tier"] = serde_json::json!(scope.tier.wire());
    let mut trusted = HeaderMap::new();
    trusted.insert(
        header::AUTHORIZATION,
        format!("Bearer {secret}")
            .parse()
            .map_err(|_| refusal(StatusCode::SERVICE_UNAVAILABLE, "Core routing unavailable"))?,
    );
    trusted.insert(
        "x-sandboxed-mission-id",
        scope.mission_id.to_string().parse().unwrap(),
    );
    trusted.insert(
        "x-sandboxed-codex-speed",
        scope.tier.wire().parse().unwrap(),
    );
    trusted.insert(
        "x-sandboxed-codex-subscription-only",
        "true".parse().unwrap(),
    );
    // Caller-supplied identity headers are intentionally discarded.
    Ok((
        trusted,
        Bytes::from(serde_json::to_vec(&request).unwrap()),
        scope.cancel.clone(),
    ))
}

pub async fn responses(
    State(state): State<Arc<crate::api::routes::AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let (trusted, body, cancel) = match prepare_request(&headers, &body, &state.proxy_secret) {
        Ok(prepared) => prepared,
        Err(response) => return response,
    };
    let response = tokio::select! {
        _ = cancel.cancelled() => return refusal(StatusCode::CONFLICT, "Codex turn stopped"),
        response = crate::api::proxy::responses(State(state), trusted, body) => response,
    };
    let (parts, body) = response.into_parts();
    let stream = futures::stream::unfold(
        (body.into_data_stream(), cancel),
        |(mut source, cancel)| async move {
            tokio::select! { _ = cancel.cancelled() => None, item = source.next() => item.map(|item| (item, (source, cancel))) }
        },
    );
    Response::from_parts(parts, Body::from_stream(stream))
}
