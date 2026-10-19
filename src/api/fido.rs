//! FIDO signing relay — forwards signing requests from container workspaces
//! to the iOS app for approval (auto-approve or Face ID).
//!
//! Requests are announced on the control SSE stream (`FidoSignRequest`; the
//! mobile apps subscribe with `/api/control/stream?kinds=fido`) and listed by
//! `GET /api/fido/pending`, so an app that was closed or backgrounded when a
//! request arrived can show it on open. There is no APNs/FCM channel in Core,
//! so nothing is pushed to a device that is not connected.

use axum::{extract::State, http::StatusCode, Json};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{oneshot, Mutex};
use uuid::Uuid;

use super::control::AgentEvent;

/// Hub that holds pending FIDO signing requests, each waiting for an iOS
/// app response via a oneshot channel.
pub struct FidoSigningHub {
    pending: Mutex<HashMap<Uuid, PendingEntry>>,
}

struct PendingEntry {
    tx: oneshot::Sender<FidoSignResponse>,
    info: PendingFidoRequest,
}

/// A pending request as listed by `GET /api/fido/pending`. Field names match
/// the `fido_sign_request` SSE event so clients can share one decoder.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct PendingFidoRequest {
    pub request_id: Uuid,
    pub key_type: String,
    pub key_fingerprint: String,
    pub origin: String,
    pub hostname: Option<String>,
    pub workspace: Option<String>,
    pub expires_at: String,
    #[serde(skip)]
    expires: chrono::DateTime<chrono::Utc>,
}

#[derive(Serialize)]
pub struct FidoPendingResponse {
    pub requests: Vec<PendingFidoRequest>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FidoSignResponse {
    pub approved: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Request body from the FIDO agent proxy.
#[derive(Debug, Deserialize)]
pub struct FidoRequestBody {
    /// SSH key type (e.g. "sk-ssh-ed25519@openssh.com")
    pub key_type: String,
    /// SHA256 fingerprint of the key
    pub key_fingerprint: String,
    /// What triggered the signing (e.g. "ssh git@github.com")
    pub origin: String,
    /// Remote hostname (if known)
    #[serde(default)]
    pub hostname: Option<String>,
    /// Workspace name for context
    #[serde(default)]
    pub workspace: Option<String>,
}

/// Response returned to the FIDO agent proxy.
#[derive(Serialize)]
pub struct FidoRequestResponse {
    pub request_id: Uuid,
    pub approved: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Request body from the iOS app to approve/deny.
#[derive(Debug, Deserialize)]
pub struct FidoRespondBody {
    pub request_id: Uuid,
    pub approved: bool,
}

impl Default for FidoSigningHub {
    fn default() -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
        }
    }
}

impl FidoSigningHub {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a new pending request, returning its listing entry and a
    /// receiver that resolves when the app responds.
    pub async fn register(
        &self,
        body: &FidoRequestBody,
        expires: chrono::DateTime<chrono::Utc>,
    ) -> (PendingFidoRequest, oneshot::Receiver<FidoSignResponse>) {
        let info = PendingFidoRequest {
            request_id: Uuid::new_v4(),
            key_type: body.key_type.clone(),
            key_fingerprint: body.key_fingerprint.clone(),
            origin: body.origin.clone(),
            hostname: body.hostname.clone(),
            workspace: body.workspace.clone(),
            expires_at: expires.to_rfc3339(),
            expires,
        };
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(
            info.request_id,
            PendingEntry {
                tx,
                info: info.clone(),
            },
        );
        (info, rx)
    }

    /// Unexpired pending requests, oldest deadline first.
    pub async fn list_pending(
        &self,
        now: chrono::DateTime<chrono::Utc>,
    ) -> Vec<PendingFidoRequest> {
        let mut out: Vec<_> = self
            .pending
            .lock()
            .await
            .values()
            .filter(|e| e.info.expires > now)
            .map(|e| e.info.clone())
            .collect();
        out.sort_by_key(|r| r.expires);
        out
    }

    /// Resolve a pending request (called when the iOS app responds).
    /// Returns true if the request existed and was resolved.
    pub async fn resolve(&self, request_id: Uuid, response: FidoSignResponse) -> bool {
        if let Some(entry) = self.pending.lock().await.remove(&request_id) {
            let _ = entry.tx.send(response);
            true
        } else {
            false
        }
    }

    /// Clean up a request that timed out (remove from pending map).
    pub async fn remove(&self, request_id: Uuid) {
        self.pending.lock().await.remove(&request_id);
    }
}

/// POST /api/fido/request — called by the FIDO agent proxy when an SSH
/// client needs a FIDO signature.  Blocks until the iOS app responds or
/// the 60-second timeout fires.
pub async fn post_fido_request(
    State(state): State<Arc<super::routes::AppState>>,
    Json(body): Json<FidoRequestBody>,
) -> Result<Json<FidoRequestResponse>, StatusCode> {
    let expires = chrono::Utc::now() + chrono::Duration::seconds(60);
    let (info, rx) = state.fido_hub.register(&body, expires).await;
    let request_id = info.request_id;

    tracing::info!(
        request_id = %request_id,
        key_type = %body.key_type,
        key_fingerprint = %body.key_fingerprint,
        origin = %body.origin,
        hostname = ?body.hostname,
        "FIDO signing request received"
    );

    // Broadcast to ALL connected SSE clients so the user sees the approval
    // request regardless of which browser tab / device they have open.
    let sessions = state.control.all_sessions().await;
    for session in &sessions {
        let _ = session.events_tx.send(AgentEvent::FidoSignRequest {
            request_id,
            key_type: body.key_type.clone(),
            key_fingerprint: body.key_fingerprint.clone(),
            origin: body.origin.clone(),
            hostname: body.hostname.clone(),
            workspace: body.workspace.clone(),
            expires_at: info.expires_at.clone(),
        });
    }

    // Wait for response with timeout.
    let response = match tokio::time::timeout(std::time::Duration::from_secs(60), rx).await {
        Ok(Ok(resp)) => {
            tracing::info!(
                request_id = %request_id,
                approved = resp.approved,
                "FIDO signing request resolved"
            );
            resp
        }
        _ => {
            // Timeout or channel dropped — auto-deny.
            state.fido_hub.remove(request_id).await;
            tracing::warn!(
                request_id = %request_id,
                "FIDO signing request timed out"
            );
            FidoSignResponse {
                approved: false,
                reason: Some("timeout".to_string()),
            }
        }
    };

    Ok(Json(FidoRequestResponse {
        request_id,
        approved: response.approved,
        reason: response.reason,
    }))
}

/// GET /api/fido/pending — unexpired signing requests still waiting for an
/// answer. The mobile apps call it on launch / foreground so a request made
/// while they were closed is shown on open. The hub is not partitioned by
/// user (requests come from workspace proxies and are broadcast to every
/// control session), so every authenticated user sees the same list, exactly
/// like the SSE event.
pub async fn get_fido_pending(
    State(state): State<Arc<super::routes::AppState>>,
) -> Json<FidoPendingResponse> {
    Json(FidoPendingResponse {
        requests: state.fido_hub.list_pending(chrono::Utc::now()).await,
    })
}

/// POST /api/fido/respond — called by the iOS app to approve or deny a
/// pending FIDO signing request.
pub async fn post_fido_respond(
    State(state): State<Arc<super::routes::AppState>>,
    Json(body): Json<FidoRespondBody>,
) -> Result<StatusCode, StatusCode> {
    let resolved = state
        .fido_hub
        .resolve(
            body.request_id,
            FidoSignResponse {
                approved: body.approved,
                reason: None,
            },
        )
        .await;

    if resolved {
        tracing::info!(
            request_id = %body.request_id,
            approved = body.approved,
            "FIDO signing request responded"
        );
        Ok(StatusCode::OK)
    } else {
        tracing::warn!(
            request_id = %body.request_id,
            "FIDO respond for unknown or expired request"
        );
        Err(StatusCode::NOT_FOUND)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(origin: &str) -> FidoRequestBody {
        FidoRequestBody {
            key_type: "sk-ssh-ed25519@openssh.com".into(),
            key_fingerprint: "SHA256:abc".into(),
            origin: origin.into(),
            hostname: Some("github.com".into()),
            workspace: None,
        }
    }

    #[tokio::test]
    async fn pending_lists_unexpired_until_resolved() {
        let hub = FidoSigningHub::new();
        let now = chrono::Utc::now();
        let (late, _rx1) = hub
            .register(&body("b"), now + chrono::Duration::seconds(60))
            .await;
        let (early, rx2) = hub
            .register(&body("a"), now + chrono::Duration::seconds(30))
            .await;
        let (_gone, _rx3) = hub
            .register(&body("c"), now - chrono::Duration::seconds(1))
            .await;

        let listed = hub.list_pending(now).await;
        assert_eq!(listed, vec![early.clone(), late.clone()]);

        assert!(
            hub.resolve(
                early.request_id,
                FidoSignResponse {
                    approved: true,
                    reason: None
                }
            )
            .await
        );
        assert!(rx2.await.unwrap().approved);
        assert_eq!(hub.list_pending(now).await, vec![late.clone()]);

        hub.remove(late.request_id).await;
        assert!(hub.list_pending(now).await.is_empty());
    }

    #[tokio::test]
    async fn pending_json_matches_sse_event_fields() {
        let hub = FidoSigningHub::new();
        let (info, _rx) = hub
            .register(
                &body("ssh git@github.com"),
                chrono::Utc::now() + chrono::Duration::seconds(60),
            )
            .await;
        let v = serde_json::to_value(FidoPendingResponse {
            requests: vec![info.clone()],
        })
        .unwrap();
        let r = &v["requests"][0];
        assert_eq!(r["request_id"], info.request_id.to_string());
        assert_eq!(r["origin"], "ssh git@github.com");
        assert_eq!(r["hostname"], "github.com");
        assert_eq!(r["expires_at"], info.expires_at);
        assert!(r.get("expires").is_none());
    }
}
