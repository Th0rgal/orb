//! REST surface for managed machines.
//!
//! Protected (dashboard JWT): list / spawn / extend / destroy / reconcile.
//! Public, self-authenticated: `enroll` (one-time token), `relay/poll` and
//! `relay/respond` (node credential), and the loopback `relay/tunnel` that
//! Core's own node client uses (node credential as bearer, like a real node).

#![allow(clippy::result_large_err)] // axum Response as the early-return error

use std::sync::Arc;
use std::time::Duration;

use axum::{
    body::Bytes,
    extract::{Path, Query},
    http::{HeaderMap, Method, StatusCode, Uri},
    response::{IntoResponse, Response},
    routing::{any, get, post},
    Json, Router,
};
use base64::Engine;
use serde::Deserialize;
use serde_json::json;

use super::routes::AppState;
use crate::managed::relay::{RelayError, RelayRequest, RelayResponse};
use crate::managed::{ManagedError, ManagedManager, SpawnRequest};

fn manager() -> Result<Arc<ManagedManager>, Response> {
    crate::managed::global().ok_or_else(|| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"error":"disabled","message":"Managed machines are not initialised"})),
        )
            .into_response()
    })
}

fn err(e: ManagedError) -> Response {
    let status = StatusCode::from_u16(e.status).unwrap_or(StatusCode::BAD_REQUEST);
    (status, Json(e)).into_response()
}

pub fn protected_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/managed-machines", get(list).post(spawn))
        .route("/api/managed-machines/reconcile", post(reconcile))
        .route(
            "/api/managed-machines/settings",
            get(get_settings).put(put_settings),
        )
        .route("/api/managed-machines/:id", get(get_one).delete(destroy))
        .route("/api/managed-machines/:id/extend", post(extend))
}

pub fn public_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/managed-machines/enroll", post(enroll))
        .route("/api/managed-machines/relay/poll", get(relay_poll))
        .route(
            "/api/managed-machines/relay/respond",
            post(relay_respond).layer(axum::extract::DefaultBodyLimit::max(1024 * 1024 * 1024)),
        )
        .route(
            "/api/managed-machines/relay/tunnel/:id/*path",
            any(relay_tunnel).layer(axum::extract::DefaultBodyLimit::max(1024 * 1024 * 1024)),
        )
}

#[derive(Deserialize)]
struct ListQuery {
    history_hours: Option<i64>,
}

async fn list(Query(q): Query<ListQuery>) -> Response {
    match manager() {
        Ok(m) => Json(
            m.list(q.history_hours.unwrap_or(24).clamp(0, 24 * 30))
                .await,
        )
        .into_response(),
        Err(r) => r,
    }
}

async fn get_one(Path(id): Path<String>) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    match m.get(&id).await {
        Some(machine) => Json(machine).into_response(),
        None => err(ManagedError {
            error: "not_found",
            message: "Unknown managed machine".into(),
            status: 404,
        }),
    }
}

async fn spawn(
    axum::Extension(user): axum::Extension<crate::api::auth::AuthUser>,
    Json(mut req): Json<SpawnRequest>,
) -> Response {
    // The owner's tenant comes from the authenticated caller, never the body.
    req.owner_user_id = Some(user.id.clone());
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    match m.spawn(req).await {
        Ok(machine) => (StatusCode::CREATED, Json(machine)).into_response(),
        Err(e) => err(e),
    }
}

#[derive(Deserialize)]
struct ExtendBody {
    ttl_minutes: u64,
}

async fn extend(Path(id): Path<String>, Json(body): Json<ExtendBody>) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    match m.extend(&id, body.ttl_minutes).await {
        Ok(machine) => Json(machine).into_response(),
        Err(e) => err(e),
    }
}

async fn destroy(Path(id): Path<String>) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    match m.destroy(&id, "requested").await {
        Ok(machine) => Json(machine).into_response(),
        Err(e) => err(e),
    }
}

async fn get_settings() -> Response {
    match manager() {
        Ok(m) => Json(m.runtime_settings()).into_response(),
        Err(r) => r,
    }
}

async fn put_settings(Json(body): Json<crate::managed::RuntimeSettings>) -> Response {
    match manager() {
        Ok(m) => {
            m.set_runtime_settings(body);
            Json(m.runtime_settings()).into_response()
        }
        Err(r) => r,
    }
}

async fn reconcile() -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    match m.reconcile_once().await {
        Ok(report) => Json(report).into_response(),
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            Json(json!({"error":"provider_error","message":e})),
        )
            .into_response(),
    }
}

// ---------------------------------------------------------------- public

#[derive(Deserialize)]
struct EnrollBody {
    machine_id: String,
    enroll_token: String,
}

async fn enroll(Json(body): Json<EnrollBody>) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    match m.enroll(&body.machine_id, &body.enroll_token).await {
        Ok((node_id, node_token)) => {
            Json(json!({"node_id": node_id, "node_token": node_token})).into_response()
        }
        Err(e) => err(e),
    }
}

async fn node_auth(
    m: &ManagedManager,
    headers: &HeaderMap,
    machine_id: &str,
) -> Result<crate::managed::ManagedMachine, Response> {
    let token = crate::remote_node::bearer_token(headers).unwrap_or_default();
    match m.machine_for_token(machine_id, token).await {
        Some(machine) => Ok(machine),
        // 410 tells a dial-out node to stop: its machine is gone or the
        // credential is no longer valid.
        None => Err((StatusCode::GONE, "machine not live").into_response()),
    }
}

fn header_machine(headers: &HeaderMap) -> String {
    headers
        .get("x-orb-machine-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_string()
}

async fn relay_poll(headers: HeaderMap) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    let mid = header_machine(&headers);
    let machine = match node_auth(&m, &headers, &mid).await {
        Ok(machine) => machine,
        Err(r) => return r,
    };
    let requests = m.relay.poll(&machine.id, Duration::from_secs(25), 32).await;
    if m.relay.is_closed(&machine.id).await {
        return (StatusCode::GONE, "machine not live").into_response();
    }
    Json(requests).into_response()
}

async fn relay_respond(headers: HeaderMap, Json(resp): Json<RelayResponse>) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    let mid = header_machine(&headers);
    let machine = match node_auth(&m, &headers, &mid).await {
        Ok(machine) => machine,
        Err(r) => return r,
    };
    let delivered = m.relay.respond(&machine.id, resp).await;
    Json(json!({"delivered": delivered})).into_response()
}

/// Headers never forwarded through the tunnel in either direction.
fn hop_by_hop(name: &str) -> bool {
    matches!(
        name,
        "host"
            | "connection"
            | "content-length"
            | "transfer-encoding"
            | "keep-alive"
            | "upgrade"
            | "proxy-connection"
            | "te"
            | "trailer"
    )
}

async fn relay_tunnel(
    Path((id, _path)): Path<(String, String)>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let m = match manager() {
        Ok(m) => m,
        Err(r) => return r,
    };
    let machine = match node_auth(&m, &headers, &id).await {
        Ok(machine) => machine,
        Err(_) => return (StatusCode::UNAUTHORIZED, "unauthorized").into_response(),
    };
    let prefix = format!("/api/managed-machines/relay/tunnel/{}", machine.id);
    let path_and_query = uri
        .path_and_query()
        .map(|p| p.as_str().to_string())
        .unwrap_or_default();
    let node_path = path_and_query
        .strip_prefix(&prefix)
        .unwrap_or("/")
        .to_string();
    let request = RelayRequest {
        id: uuid::Uuid::new_v4().to_string(),
        method: method.to_string(),
        path: if node_path.is_empty() {
            "/".into()
        } else {
            node_path
        },
        headers: headers
            .iter()
            .filter(|(k, _)| !hop_by_hop(k.as_str()))
            .filter_map(|(k, v)| Some((k.to_string(), v.to_str().ok()?.to_string())))
            .collect(),
        body_b64: base64::engine::general_purpose::STANDARD.encode(&body),
        timeout_secs: 0,
    };
    // Long enough for `/execute`, which blocks for the whole command.
    match m
        .relay
        .call(&machine.id, request, Duration::from_secs(2 * 60 * 60))
        .await
    {
        Ok(resp) => {
            let body = base64::engine::general_purpose::STANDARD
                .decode(resp.body_b64.as_bytes())
                .unwrap_or_default();
            let mut builder = Response::builder()
                .status(StatusCode::from_u16(resp.status).unwrap_or(StatusCode::BAD_GATEWAY));
            for (k, v) in resp.headers {
                if !hop_by_hop(&k.to_ascii_lowercase()) {
                    builder = builder.header(k, v);
                }
            }
            builder
                .body(axum::body::Body::from(body))
                .unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response())
        }
        Err(RelayError::NodeNotConnected) => (
            StatusCode::SERVICE_UNAVAILABLE,
            "managed node is not connected",
        )
            .into_response(),
        Err(RelayError::Timeout) => {
            (StatusCode::GATEWAY_TIMEOUT, "managed node did not answer").into_response()
        }
        Err(RelayError::Closed) => (StatusCode::GONE, "managed machine destroyed").into_response(),
    }
}
