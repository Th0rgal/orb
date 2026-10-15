//! Device-signed approvals.
//!
//! A dashboard JWT proves "a client of this backend", not "Thomas approved
//! this". Sensitive operations (approving mission secret requests, changing
//! default access, revealing or editing secrets, managing devices) also need
//! a signature from an enrolled device key that lives in hardware and only
//! signs after a fresh biometric check:
//!
//! - macOS / iOS: Secure Enclave P-256 key with `.biometryCurrentSet`.
//! - Android: Keystore (StrongBox when present) EC P-256 key requiring
//!   `BIOMETRIC_STRONG` for every use.
//!
//! Flow: the client asks `POST /api/approvals/challenge` for the exact
//! request it is about to send (method, path, SHA-256 of the body). Core
//! returns a one-time payload, valid 2 minutes. The device shows the action,
//! asks for biometrics, signs the payload (ECDSA P-256 / SHA-256, DER), and the
//! client sends the request with `X-Paloma-Approval: <challenge>.<device>.<sig>`.
//! The middleware recomputes method/path/body hash, so a signature approves
//! exactly one request.
//!
//! Enrollment: a new device is added by a request signed by an enrolled
//! device, or with a one-time code that only root on the Core host can create
//! (`<working_dir>/.sandboxed-sh/approval_enrollment_code`, deleted on use).
//!
//! Mode (`off` / `warn` / `enforce`) is stored with the devices; `warn` logs
//! unsigned requests and lets them through, `enforce` rejects them.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use axum::{
    body::{to_bytes, Body},
    extract::{Path as AxumPath, State},
    http::{Method, Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Json, Response},
    routing::{delete, get, post, put},
    Router,
};
use base64::Engine as _;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;
use uuid::Uuid;

use super::routes::AppState;

pub const HEADER: &str = "x-paloma-approval";
const CHALLENGE_TTL_SECS: i64 = 120;
const MAX_BODY: usize = 256 * 1024;
/// DER prefix of a P-256 SubjectPublicKeyInfo; the 65-byte point follows.
const P256_SPKI_PREFIX: [u8; 26] = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
    0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Off,
    #[default]
    Warn,
    Enforce,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: Uuid,
    pub name: String,
    /// `macos`, `ios` or `android`.
    pub platform: String,
    /// Base64 DER SubjectPublicKeyInfo of a P-256 key.
    pub public_key: String,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub last_used_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub revoked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Persisted {
    #[serde(default)]
    mode: Mode,
    #[serde(default)]
    devices: Vec<Device>,
}

#[derive(Debug, Clone)]
struct Challenge {
    method: String,
    path: String,
    body_sha256: String,
    payload: String,
    expires_at: DateTime<Utc>,
}

pub struct Approvals {
    path: PathBuf,
    code_path: PathBuf,
    data: Mutex<Persisted>,
    challenges: Mutex<HashMap<Uuid, Challenge>>,
}

static APPROVALS: OnceLock<Arc<Approvals>> = OnceLock::new();

pub fn approvals(state: &AppState) -> Arc<Approvals> {
    APPROVALS
        .get_or_init(|| {
            let dir = state.config.working_dir.join(".sandboxed-sh");
            let path = dir.join("approval_devices.json");
            // Fail closed: an unreadable or corrupt device file means enforce
            // (with no devices) rather than silently falling back to warn.
            let data = match std::fs::read_to_string(&path) {
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Persisted::default(),
                Ok(text) => serde_json::from_str(&text).unwrap_or_else(|e| {
                    tracing::error!("approval_devices.json is corrupt ({e}); enforcing approvals");
                    Persisted {
                        mode: Mode::Enforce,
                        devices: Vec::new(),
                    }
                }),
                Err(e) => {
                    tracing::error!("approval_devices.json unreadable ({e}); enforcing approvals");
                    Persisted {
                        mode: Mode::Enforce,
                        devices: Vec::new(),
                    }
                }
            };
            Arc::new(Approvals {
                path,
                code_path: dir.join("approval_enrollment_code"),
                data: Mutex::new(data),
                challenges: Mutex::new(HashMap::new()),
            })
        })
        .clone()
}

impl Approvals {
    async fn save(&self, data: &Persisted) {
        let Ok(text) = serde_json::to_string_pretty(data) else {
            return;
        };
        if let Some(dir) = self.path.parent() {
            let _ = tokio::fs::create_dir_all(dir).await;
        }
        let tmp = self.path.with_extension("json.tmp");
        if tokio::fs::write(&tmp, text).await.is_ok() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ =
                    tokio::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600)).await;
            }
            let _ = tokio::fs::rename(&tmp, &self.path).await;
        }
    }

    pub async fn mode(&self) -> Mode {
        self.data.lock().await.mode
    }

    async fn issue(
        &self,
        method: &str,
        path: &str,
        body_sha256: &str,
        summary: &str,
    ) -> (Uuid, Challenge) {
        let id = Uuid::new_v4();
        let expires_at = Utc::now() + chrono::Duration::seconds(CHALLENGE_TTL_SECS);
        let summary: String = summary.chars().filter(|c| *c != '\n').take(300).collect();
        let payload = payload_text(
            id,
            method,
            path,
            body_sha256,
            expires_at.timestamp(),
            &summary,
        );
        let c = Challenge {
            method: method.to_string(),
            path: path.to_string(),
            body_sha256: body_sha256.to_string(),
            payload,
            expires_at,
        };
        let mut all = self.challenges.lock().await;
        let now = Utc::now();
        all.retain(|_, c| c.expires_at > now);
        all.insert(id, c.clone());
        (id, c)
    }

    /// Check a signed approval for exactly this request. Consumes the challenge.
    pub async fn verify(
        &self,
        header: &str,
        method: &str,
        path: &str,
        body: &[u8],
    ) -> Result<Uuid, String> {
        let mut parts = header.trim().splitn(3, '.');
        let (Some(cid), Some(did), Some(sig)) = (parts.next(), parts.next(), parts.next()) else {
            return Err("Malformed approval header".into());
        };
        let cid = Uuid::parse_str(cid).map_err(|_| "Malformed challenge id")?;
        let did = Uuid::parse_str(did).map_err(|_| "Malformed device id")?;
        let sig = base64::engine::general_purpose::STANDARD
            .decode(sig)
            .map_err(|_| "Malformed signature")?;
        let challenge = self
            .challenges
            .lock()
            .await
            .remove(&cid)
            .ok_or("Unknown or already used approval challenge")?;
        if challenge.expires_at < Utc::now() {
            return Err("Approval challenge expired".into());
        }
        if challenge.method != method
            || challenge.path != path
            || challenge.body_sha256 != sha256_hex(body)
        {
            return Err("Approval was signed for a different request".into());
        }
        let mut data = self.data.lock().await;
        let device = data
            .devices
            .iter_mut()
            .find(|d| d.id == did && d.revoked_at.is_none())
            .ok_or("Unknown or revoked device")?;
        verify_signature(&device.public_key, challenge.payload.as_bytes(), &sig)?;
        device.last_used_at = Some(Utc::now());
        let id = device.id;
        self.save(&data).await;
        Ok(id)
    }

    async fn take_enrollment_code(&self, code: &str) -> bool {
        let Ok(stored) = tokio::fs::read_to_string(&self.code_path).await else {
            return false;
        };
        let stored = stored.trim();
        if stored.len() < 8 || !constant_time_eq(stored.as_bytes(), code.trim().as_bytes()) {
            return false;
        }
        tokio::fs::remove_file(&self.code_path).await.is_ok()
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

pub fn payload_text(
    id: Uuid,
    method: &str,
    path: &str,
    body_sha256: &str,
    expires: i64,
    summary: &str,
) -> String {
    format!("paloma-approval-v1\n{id}\n{method} {path}\n{body_sha256}\n{expires}\n{summary}")
}

fn public_point(spki_b64: &str) -> Result<Vec<u8>, String> {
    let der = base64::engine::general_purpose::STANDARD
        .decode(spki_b64.trim())
        .map_err(|_| "Public key is not base64")?;
    if der.len() != P256_SPKI_PREFIX.len() + 65 || der[..P256_SPKI_PREFIX.len()] != P256_SPKI_PREFIX
    {
        return Err("Public key must be a P-256 SubjectPublicKeyInfo".into());
    }
    Ok(der[P256_SPKI_PREFIX.len()..].to_vec())
}

pub fn verify_signature(spki_b64: &str, message: &[u8], der_sig: &[u8]) -> Result<(), String> {
    let point = public_point(spki_b64)?;
    ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_ASN1, point)
        .verify(message, der_sig)
        .map_err(|_| "Device signature does not verify".to_string())
}

/// Human description of a protected request, written by Core.
async fn describe(state: &Arc<AppState>, method: &Method, path: &str, body: &str) -> String {
    let seg: Vec<&str> = path.trim_end_matches('/').split('/').collect();
    let body: serde_json::Value = serde_json::from_str(body).unwrap_or_default();
    match (method, seg.as_slice()) {
        (&Method::POST, ["", "api", "bitwarden", "requests", id, action]) => {
            let snapshot = super::secret_broker::broker(state).snapshot().await;
            let r = snapshot["requests"]
                .as_array()
                .and_then(|a| a.iter().find(|r| r["id"].as_str() == Some(*id)))
                .cloned()
                .unwrap_or_default();
            let who = r["mission_title"].as_str().unwrap_or("a mission");
            let what = match (r["kind"].as_str(), r["key"].as_str()) {
                (Some("write"), Some(k)) => format!("store {k}"),
                (_, Some(k)) => format!("read {k}"),
                _ if r["all_projects"] == true => "read every project".into(),
                _ => "read a Bitwarden project".into(),
            };
            if *action == "reject" {
                format!("Decline: {who} wants to {what}")
            } else {
                let scope = match body["scope"].as_str() {
                    Some("all") => " (ALL projects, 24 h)",
                    Some("project") => " (whole project, 24 h)",
                    Some("secret") => " (this secret, 24 h)",
                    _ => "",
                };
                format!("Allow {who} to {what}{scope}")
            }
        }
        (&Method::PUT, ["", "api", "bitwarden", "default-access", slug]) => {
            let n = body["project_ids"].as_array().map(|a| a.len()).unwrap_or(0);
            format!("Set default secret access for {slug} to {n} Bitwarden project(s)")
        }
        (&Method::PUT, ["", "api", "bitwarden", "config"]) => {
            "Change the Bitwarden connection".into()
        }
        (&Method::GET, ["", "api", "bitwarden", "secrets", _, "reveal"]) => {
            "Reveal a secret value".into()
        }
        (&Method::POST, ["", "api", "bitwarden", "projects", _, "secrets"]) => {
            format!("Create secret {}", body["key"].as_str().unwrap_or(""))
        }
        (&Method::PUT, ["", "api", "bitwarden", "secrets", _]) => {
            format!("Edit secret {}", body["key"].as_str().unwrap_or(""))
        }
        (&Method::DELETE, ["", "api", "bitwarden", "secrets", _]) => "Delete a secret".into(),
        (&Method::DELETE, ["", "api", "approvals", "devices", _]) => {
            "Remove an approval device".into()
        }
        (&Method::PUT, ["", "api", "approvals", "mode"]) => {
            format!(
                "Set approval mode to {}",
                body["mode"].as_str().unwrap_or("?")
            )
        }
        (&Method::POST, ["", "api", "approvals", "devices"]) => {
            format!(
                "Enroll approval device {}",
                body["name"].as_str().unwrap_or("")
            )
        }
        (&Method::POST, ["", "api", "settings", "restore"]) => {
            "Restore backend settings from a backup".into()
        }
        _ => format!("{method} {path}"),
    }
}

/// Operations that need a device signature.
pub fn is_protected(method: &Method, path: &str) -> bool {
    let p = path.trim_end_matches('/');
    let seg: Vec<&str> = p.split('/').collect();
    match (method, seg.as_slice()) {
        (&Method::POST, ["", "api", "bitwarden", "requests", _, "approve" | "reject"]) => true,
        (&Method::PUT, ["", "api", "bitwarden", "default-access", _]) => true,
        (&Method::PUT, ["", "api", "bitwarden", "config"]) => true,
        (&Method::GET, ["", "api", "bitwarden", "secrets", _, "reveal"]) => true,
        (&Method::POST, ["", "api", "bitwarden", "projects", _, "secrets"]) => true,
        (&Method::PUT | &Method::DELETE, ["", "api", "bitwarden", "secrets", _]) => true,
        (&Method::DELETE, ["", "api", "approvals", "devices", _]) => true,
        (&Method::PUT, ["", "api", "approvals", "mode"]) => true,
        // A backup restore can rewrite device, grant and access state on disk.
        (&Method::POST, ["", "api", "settings", "restore"]) => true,
        _ => false,
    }
}

/// Middleware: runs after authentication; only acts on protected operations.
pub async fn require_device_approval(
    State(state): State<Arc<AppState>>,
    req: Request<Body>,
    next: Next,
) -> Response {
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let guarded_prefix = path.starts_with("/api/bitwarden") || path.starts_with("/api/approvals");
    if guarded_prefix
        && (path.contains("//")
            || path.contains('%')
            || path.contains("/./")
            || path.contains("/../"))
    {
        return (StatusCode::BAD_REQUEST, "Unsupported path").into_response();
    }
    if !is_protected(&method, &path) {
        return next.run(req).await;
    }
    let store = approvals(&state);
    let mode = store.mode().await;
    if mode == Mode::Off {
        return next.run(req).await;
    }
    let header = req
        .headers()
        .get(HEADER)
        .and_then(|h| h.to_str().ok())
        .map(str::to_string);
    let (parts, body) = req.into_parts();
    let limit = if path.starts_with("/api/settings/restore") {
        512 * 1024 * 1024
    } else {
        MAX_BODY
    };
    let Ok(bytes) = to_bytes(body, limit).await else {
        return (StatusCode::PAYLOAD_TOO_LARGE, "Request body too large").into_response();
    };
    let verdict = match header {
        Some(h) => store.verify(&h, method.as_str(), &path, &bytes).await,
        None => Err(
            "This action needs approval from an enrolled device (Touch ID / Face ID / fingerprint)"
                .into(),
        ),
    };
    if let Err(e) = verdict {
        if mode == Mode::Enforce {
            return (
                StatusCode::FORBIDDEN,
                Json(json!({"error": e, "code": "device_approval_required"})),
            )
                .into_response();
        }
        tracing::warn!(%method, %path, "device approval missing or invalid (warn mode): {e}");
    }
    next.run(Request::from_parts(parts, Body::from(bytes)))
        .await
}

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/devices", get(list_devices).post(enroll_device))
        .route("/devices/:id", delete(revoke_device))
        .route("/challenge", post(challenge))
        .route("/mode", put(set_mode))
}

async fn list_devices(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let store = approvals(&state);
    let data = store.data.lock().await;
    Json(json!({
        "mode": data.mode,
        "devices": data.devices.iter().filter(|d| d.revoked_at.is_none()).collect::<Vec<_>>(),
        "enrollment_code_pending": store.code_path.exists(),
    }))
}

#[derive(Deserialize)]
struct ChallengeRequest {
    method: String,
    path: String,
    /// Exact body bytes the client will send (UTF-8); empty for none.
    #[serde(default)]
    body: String,
    /// For binary bodies (backup archives): hex SHA-256 of the exact bytes.
    #[serde(default)]
    body_sha256: Option<String>,
    /// Ignored: Core writes the summary the device displays.
    #[serde(default)]
    #[allow(dead_code)]
    summary: String,
}

async fn challenge(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ChallengeRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let method = req.method.trim().to_ascii_uppercase();
    let method_parsed = Method::from_bytes(method.as_bytes())
        .map_err(|_| (StatusCode::BAD_REQUEST, "Bad method".into()))?;
    let path = req.path.split('?').next().unwrap_or("").to_string();
    // Enrollment by an existing device signs the enroll request itself.
    let enroll =
        method_parsed == Method::POST && path.trim_end_matches('/') == "/api/approvals/devices";
    if !is_protected(&method_parsed, &path) && !enroll {
        return Err((
            StatusCode::BAD_REQUEST,
            "This request does not need a device approval".into(),
        ));
    }
    // The text the device shows comes from Core, not the client, so a
    // compromised page cannot describe one action while asking to sign another.
    let body_hash = match req.body_sha256.as_deref().map(str::trim) {
        Some(h) if h.len() == 64 && h.chars().all(|c| c.is_ascii_hexdigit()) => {
            h.to_ascii_lowercase()
        }
        Some(_) => {
            return Err((
                StatusCode::BAD_REQUEST,
                "body_sha256 must be 64 hex characters".into(),
            ))
        }
        None => sha256_hex(req.body.as_bytes()),
    };
    let summary = describe(&state, &method_parsed, &path, &req.body).await;
    let (id, c) = approvals(&state)
        .issue(&method, &path, &body_hash, &summary)
        .await;
    Ok(Json(
        json!({"challenge_id": id, "payload": c.payload, "expires_at": c.expires_at}),
    ))
}

#[derive(Deserialize)]
struct EnrollRequest {
    name: String,
    platform: String,
    public_key: String,
    #[serde(default)]
    enrollment_code: Option<String>,
}

async fn enroll_device(
    State(state): State<Arc<AppState>>,
    req: Request<Body>,
) -> Result<Json<Device>, (StatusCode, String)> {
    let store = approvals(&state);
    let header = req
        .headers()
        .get(HEADER)
        .and_then(|h| h.to_str().ok())
        .map(str::to_string);
    let path = req.uri().path().to_string();
    let bytes = to_bytes(req.into_body(), MAX_BODY)
        .await
        .map_err(|_| (StatusCode::PAYLOAD_TOO_LARGE, "Body too large".to_string()))?;
    let body: EnrollRequest =
        serde_json::from_slice(&bytes).map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;
    public_point(&body.public_key).map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    let platform = body.platform.trim().to_ascii_lowercase();
    if !["macos", "ios", "android"].contains(&platform.as_str()) {
        return Err((
            StatusCode::BAD_REQUEST,
            "platform must be macos, ios or android".into(),
        ));
    }
    let authorized = match (&header, &body.enrollment_code) {
        (Some(h), _) => store.verify(h, "POST", &path, &bytes).await.is_ok(),
        (None, Some(code)) => store.take_enrollment_code(code).await,
        _ => false,
    };
    if !authorized {
        return Err((
            StatusCode::FORBIDDEN,
            "Enrolling a device needs approval from an enrolled device, or the one-time code from the Core host".into(),
        ));
    }
    let device = Device {
        id: Uuid::new_v4(),
        name: body.name.trim().chars().take(80).collect(),
        platform,
        public_key: body.public_key.trim().to_string(),
        created_at: Utc::now(),
        last_used_at: None,
        revoked_at: None,
    };
    let mut data = store.data.lock().await;
    if data
        .devices
        .iter()
        .any(|d| d.revoked_at.is_none() && d.public_key == device.public_key)
    {
        return Err((StatusCode::CONFLICT, "This key is already enrolled".into()));
    }
    data.devices.push(device.clone());
    store.save(&data).await;
    Ok(Json(device))
}

async fn revoke_device(
    State(state): State<Arc<AppState>>,
    AxumPath(id): AxumPath<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let id = Uuid::parse_str(id.trim())
        .map_err(|_| (StatusCode::BAD_REQUEST, "Invalid id".to_string()))?;
    let store = approvals(&state);
    let mut data = store.data.lock().await;
    let d = data
        .devices
        .iter_mut()
        .find(|d| d.id == id && d.revoked_at.is_none())
        .ok_or((StatusCode::NOT_FOUND, "Device not found".to_string()))?;
    d.revoked_at = Some(Utc::now());
    store.save(&data).await;
    Ok(Json(json!({"success": true})))
}

#[derive(Deserialize)]
struct ModeRequest {
    mode: Mode,
}

async fn set_mode(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ModeRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let store = approvals(&state);
    let mut data = store.data.lock().await;
    if req.mode == Mode::Enforce && !data.devices.iter().any(|d| d.revoked_at.is_none()) {
        return Err((
            StatusCode::CONFLICT,
            "Enroll a device before enforcing".into(),
        ));
    }
    data.mode = req.mode;
    store.save(&data).await;
    Ok(Json(json!({"mode": data.mode})))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::rand::SystemRandom;
    use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_ASN1_SIGNING};

    fn keypair() -> (EcdsaKeyPair, String) {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng).unwrap();
        let kp = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, pkcs8.as_ref(), &rng)
            .unwrap();
        let mut spki = P256_SPKI_PREFIX.to_vec();
        spki.extend_from_slice(kp.public_key().as_ref());
        (kp, base64::engine::general_purpose::STANDARD.encode(spki))
    }

    fn store() -> Approvals {
        Approvals {
            path: std::env::temp_dir().join(format!("approvals-{}.json", Uuid::new_v4())),
            code_path: std::env::temp_dir().join(format!("code-{}", Uuid::new_v4())),
            data: Mutex::new(Persisted::default()),
            challenges: Mutex::new(HashMap::new()),
        }
    }

    #[tokio::test]
    async fn signature_approves_exactly_one_request() {
        let (kp, spki) = keypair();
        let s = store();
        let device = Uuid::new_v4();
        s.data.lock().await.devices.push(Device {
            id: device,
            name: "test".into(),
            platform: "macos".into(),
            public_key: spki,
            created_at: Utc::now(),
            last_used_at: None,
            revoked_at: None,
        });
        let path = "/api/bitwarden/requests/x/approve";
        let body = br#"{"scope":"secret"}"#;
        let sign = |c: &Challenge| {
            let sig = kp.sign(&SystemRandom::new(), c.payload.as_bytes()).unwrap();
            base64::engine::general_purpose::STANDARD.encode(sig.as_ref())
        };
        let (id, c) = s.issue("POST", path, &sha256_hex(body), "approve").await;
        let header = format!("{id}.{device}.{}", sign(&c));
        assert!(
            s.verify(&header, "POST", path, br#"{"scope":"all"}"#)
                .await
                .is_err(),
            "tampered body"
        );
        // The challenge is consumed even by a failed attempt.
        assert!(s.verify(&header, "POST", path, body).await.is_err());

        let (id, c) = s.issue("POST", path, &sha256_hex(body), "approve").await;
        let header = format!("{id}.{device}.{}", sign(&c));
        assert!(s.verify(&header, "POST", path, body).await.is_ok());
        assert!(
            s.verify(&header, "POST", path, body).await.is_err(),
            "replay"
        );

        let (other, _) = keypair();
        let (id, c) = s.issue("POST", path, &sha256_hex(body), "approve").await;
        let forged = other
            .sign(&SystemRandom::new(), c.payload.as_bytes())
            .unwrap();
        let header = format!(
            "{id}.{device}.{}",
            base64::engine::general_purpose::STANDARD.encode(forged.as_ref())
        );
        assert!(
            s.verify(&header, "POST", path, body).await.is_err(),
            "wrong key"
        );
    }

    #[test]
    fn protected_routes() {
        assert!(is_protected(
            &Method::POST,
            "/api/bitwarden/requests/abc/approve"
        ));
        assert!(is_protected(
            &Method::GET,
            "/api/bitwarden/secrets/abc/reveal"
        ));
        assert!(is_protected(
            &Method::PUT,
            "/api/bitwarden/default-access/minecraft"
        ));
        assert!(!is_protected(&Method::GET, "/api/bitwarden/secrets"));
        assert!(!is_protected(&Method::GET, "/api/bitwarden/broker"));
        assert!(!is_protected(&Method::DELETE, "/api/bitwarden/grants/abc"));
    }
}
