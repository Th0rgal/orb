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
    async fn save(&self, data: &Persisted) -> Result<(), String> {
        let text = serde_json::to_string_pretty(data).map_err(|e| e.to_string())?;
        if let Some(dir) = self.path.parent() {
            tokio::fs::create_dir_all(dir)
                .await
                .map_err(|e| e.to_string())?;
        }
        let tmp = self.path.with_extension("json.tmp");
        tokio::fs::write(&tmp, text)
            .await
            .map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            tokio::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))
                .await
                .map_err(|e| e.to_string())?;
        }
        tokio::fs::rename(&tmp, &self.path)
            .await
            .map_err(|e| e.to_string())
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
        // Last-used is informational; a failed write must not fail the request.
        let _ = self.save(&data).await;
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

/// Quoted Bitwarden project names for ids (unknown ids shown shortened).
async fn project_names(state: &Arc<AppState>, ids: &[String]) -> Vec<String> {
    let projects = super::bitwarden::list_projects_raw(state)
        .await
        .unwrap_or_default();
    ids.iter()
        .map(|id| {
            projects
                .iter()
                .find(|p| &p.id == id)
                .map(|p| quoted(&p.name))
                .unwrap_or_else(|| quoted(&id.chars().take(8).collect::<String>()))
        })
        .collect()
}

/// `secret "NAME" in "project"` for a secret id.
async fn secret_label(state: &Arc<AppState>, id: &str) -> String {
    let broker = super::secret_broker::broker(state);
    let found = broker
        .list_all(state, false)
        .await
        .ok()
        .and_then(|all| all.into_iter().find(|s| s.id == id));
    match found {
        Some(s) => {
            let project = project_names(state, &s.project_id.into_iter().collect::<Vec<_>>())
                .await
                .join("");
            format!("secret {} in {project}", quoted(&s.key))
        }
        None => format!("unknown secret {}", quoted(id)),
    }
}

/// A mission-controlled string, safe to show in a biometric prompt.
pub(crate) fn quoted(raw: &str) -> String {
    let clean: String = raw
        .chars()
        // Drop control, zero-width and bidirectional override characters.
        .filter(|c| {
            !c.is_control()
                && !matches!(*c as u32, 0x200b..=0x200f | 0x202a..=0x202e | 0x2060..=0x2069 | 0xfeff)
        })
        .take(60)
        .collect::<String>()
        .replace('"', "'");
    format!("\"{clean}\"")
}

fn typed<T: serde::de::DeserializeOwned>(body: &str) -> Result<T, String> {
    // Parse exactly as the handler will (serde rejects duplicate fields), so the
    // description cannot differ from what gets executed.
    serde_json::from_str(if body.trim().is_empty() { "{}" } else { body })
        .map_err(|e| format!("Body does not match this operation: {e}"))
}

fn no_body(body: &str) -> Result<(), String> {
    if body.is_empty() {
        Ok(())
    } else {
        Err("This operation takes no body".into())
    }
}

/// Human description of a protected request, written by Core. Every value a
/// client or mission controls is quoted; the body is parsed with the handler's
/// own types, and a request that would not parse gets no challenge.
async fn describe(
    state: &Arc<AppState>,
    owner: &str,
    method: &Method,
    path: &str,
    body: &str,
) -> Result<String, String> {
    use super::bitwarden::{
        ApproveRequest, CreateBitwardenSecretRequest, DefaultAccessRequest,
        UpdateBitwardenConfigRequest, UpdateBitwardenSecretRequest,
    };
    let seg: Vec<&str> = path.trim_end_matches('/').split('/').collect();
    Ok(match (method, seg.as_slice()) {
        (&Method::POST, ["", "api", "bitwarden", "requests", id, action]) => {
            let snapshot = super::secret_broker::broker(state).snapshot().await;
            let r = snapshot["requests"]
                .as_array()
                .and_then(|a| a.iter().find(|r| r["id"].as_str() == Some(*id)))
                .cloned()
                .ok_or("Unknown request")?;
            let project = match r["project_id"].as_str() {
                Some(pid) => super::bitwarden::list_projects_raw(state)
                    .await
                    .ok()
                    .and_then(|ps| ps.into_iter().find(|p| p.id == pid))
                    .map(|p| quoted(&p.name))
                    .unwrap_or_else(|| quoted(pid)),
                None => "every project".into(),
            };
            let who = match serde_json::from_value::<super::approval_flow::RequesterSubject>(
                r["requester"].clone(),
            ) {
                Ok(subject) => subject.prompt_who(r["mission_title"].as_str()),
                Err(_) => match r["mission_id"]
                    .as_str()
                    .and_then(|s| Uuid::parse_str(s).ok())
                {
                    Some(mid) => super::approval_flow::RequesterSubject::mission(mid)
                        .prompt_who(r["mission_title"].as_str()),
                    None => format!(
                        "mission {}",
                        quoted(r["mission_title"].as_str().unwrap_or("untitled"))
                    ),
                },
            };
            let target = match r["target_project_id"].as_str() {
                Some(pid) => super::bitwarden::list_projects_raw(state)
                    .await
                    .ok()
                    .and_then(|ps| ps.into_iter().find(|p| p.id == pid))
                    .map(|p| quoted(&p.name))
                    .unwrap_or_else(|| quoted(pid)),
                None => "an unknown project".into(),
            };
            let what = match (r["kind"].as_str(), r["key"].as_str()) {
                (Some("write"), Some(k)) => format!("WRITE secret {} into {project}", quoted(k)),
                (Some("delete"), Some(k)) => format!("DELETE secret {} from {project}", quoted(k)),
                (Some("move"), Some(k)) => {
                    format!("MOVE secret {} from {project} to {target}", quoted(k))
                }
                (_, Some(k)) => format!("read secret {} from {project}", quoted(k)),
                _ => format!("read {project}"),
            };
            match *action {
                "reject" => {
                    no_body(body)?;
                    format!("Decline: {who} wants to {what}")
                }
                "approve" => {
                    let req: ApproveRequest = typed(body)?;
                    if matches!(r["kind"].as_str(), Some("write" | "delete" | "move")) {
                        format!("Allow {who} to {what}")
                    } else {
                        let default_hours = if matches!(
                            serde_json::from_value::<super::approval_flow::RequesterSubject>(
                                r["requester"].clone()
                            ),
                            Ok(super::approval_flow::RequesterSubject::ExternalSession { .. })
                        ) {
                            1
                        } else {
                            super::secret_broker::DEFAULT_GRANT_TTL_HOURS
                        };
                        let hours = req.ttl_hours.unwrap_or(default_hours).clamp(1, 24 * 30);
                        // Mirror SecretBroker::approve: an empty scope means the
                        // secret if one was asked, else every project, else the project.
                        let effective = match req.scope.as_deref().unwrap_or("") {
                            "" if r["key"].is_string() => "secret",
                            "" if r["all_projects"] == true => "all",
                            "" if r["project_id"].is_string() => "project",
                            other => other,
                        };
                        let scope = match effective {
                            "all" => format!("grant: ALL projects for {hours} h"),
                            "project" => format!("grant: whole project {project} for {hours} h"),
                            "secret" if r["key"].is_string() => {
                                format!("grant: this secret only for {hours} h")
                            }
                            other => return Err(format!("Unsupported scope {}", quoted(other))),
                        };
                        format!("Allow {who} to {what}; {scope}")
                    }
                }
                _ => return Err("Unknown request action".into()),
            }
        }
        (&Method::POST, ["", "api", "mission-access", id, action @ ("approve" | "deny")]) => {
            let ttl = if *action == "approve" {
                typed::<super::mission_access::ApproveBody>(body)?.ttl_hours
            } else {
                no_body(body)?;
                None
            };
            super::mission_access::describe_for_approval(state, owner, id, action, ttl).await?
        }
        (&Method::POST, ["", "api", "privilege-access", id, action @ ("approve" | "deny")]) => {
            let ttl = if *action == "approve" {
                typed::<super::privilege_broker::ApprovePrivilegeBody>(body)?.ttl_minutes
            } else {
                no_body(body)?;
                None
            };
            super::privilege_broker::describe_for_approval(state, owner, id, action, ttl).await?
        }
        (&Method::POST, ["", "api", "privilege-access", "approve-all"]) => {
            let legacy: super::approval_queue::LegacyPrivilegeBatch = typed(body)?;
            super::approval_queue::describe(state, owner, &legacy.into_batch()).await?
        }
        (&Method::POST, ["", "api", "approvals", "approve-all"]) => {
            let batch: super::approval_queue::BatchBody = typed(body)?;
            super::approval_queue::describe(state, owner, &batch).await?
        }
        (&Method::POST, ["", "api", "privilege-access", "bunker"]) => {
            "Trigger Fleet Bunker Mode lockdown and revoke active privileged leases".into()
        }
        (&Method::POST, ["", "api", "privilege-access", "unbunker"]) => {
            no_body(body)?;
            "Exit Fleet Bunker Mode and restore normal privileged access policy".into()
        }
        (&Method::PUT, ["", "api", "bitwarden", "default-access", slug]) => {
            let req: DefaultAccessRequest = typed(body)?;
            let names = project_names(state, &req.project_ids).await;
            if names.is_empty() {
                format!("Remove all default secret access for {}", quoted(slug))
            } else {
                format!(
                    "Let {} missions read {} without asking",
                    quoted(slug),
                    names.join(", ")
                )
            }
        }
        (&Method::PUT, ["", "api", "usage-telemetry", "config"]) => {
            let req: super::usage_telemetry::ConfigRequest = typed(body)?;
            let mut changes = Vec::new();
            if let Some(on) = req.enabled {
                changes.push(format!(
                    "{} usage telemetry",
                    if on { "turn ON" } else { "turn off" }
                ));
            }
            if let Some(on) = req.prompts_enabled {
                changes.push(format!(
                    "{} sending prompts",
                    if on { "turn ON" } else { "turn off" }
                ));
            }
            if let Some(url) = req.hub_url.as_deref() {
                let shown = reqwest::Url::parse(url.trim())
                    .map(|u| u.origin().ascii_serialization())
                    .unwrap_or_else(|_| "an invalid URL".into());
                changes.push(format!("send to {}", quoted(&shown)));
            }
            if let Some(ns) = req.namespace.as_deref() {
                changes.push(format!("namespace {}", quoted(ns.trim())));
            }
            match req.token.as_deref().map(str::trim) {
                Some("") => changes.push("remove the hub token".to_string()),
                Some(_) => changes.push("replace the hub token".to_string()),
                None => {}
            }
            if changes.is_empty() {
                "Save usage telemetry settings".to_string()
            } else {
                format!("Usage telemetry: {}", changes.join(", "))
            }
        }
        (&Method::PUT, ["", "api", "bitwarden", "config"]) => {
            let req: UpdateBitwardenConfigRequest = typed(body)?;
            let mut changes = Vec::new();
            // Mirror update_config: empty strings clear, bindings replace the whole map.
            match req.access_token.as_deref().map(str::trim) {
                Some("") => changes.push("REMOVE the machine token".to_string()),
                Some(_) => changes.push("replace the machine token".to_string()),
                None => {}
            }
            match req.server_url.as_deref().map(str::trim) {
                Some("") => changes.push("reset the server URL to Bitwarden Cloud".to_string()),
                Some(u) => changes.push(format!("set the server URL to {}", quoted(u))),
                None => {}
            }
            match req.default_project_id.as_deref().map(str::trim) {
                Some("") => changes.push("clear the default project".to_string()),
                Some(pid) => {
                    let name = project_names(state, &[pid.to_string()]).await.join("");
                    changes.push(format!("set the default project to {name}"));
                }
                None => {}
            }
            if let Some(b) = &req.project_bindings {
                let mut list = Vec::new();
                for (slug, id) in b
                    .iter()
                    .filter(|(k, v)| !k.trim().is_empty() && !v.trim().is_empty())
                {
                    let name = project_names(state, &[id.trim().to_string()])
                        .await
                        .join("");
                    list.push(format!("{} → {name}", quoted(slug.trim())));
                }
                if list.is_empty() {
                    changes.push("REMOVE all project bindings".to_string());
                } else {
                    changes.push(format!(
                        "replace ALL project bindings with {}",
                        list.join(", ")
                    ));
                }
            }
            if req.skip_validation {
                changes.push("skip token validation".to_string());
            }
            if changes.is_empty() {
                "Update Bitwarden settings".into()
            } else {
                format!("Bitwarden: {}", changes.join("; "))
            }
        }
        (&Method::GET, ["", "api", "bitwarden", "secrets", id, "reveal"]) => {
            no_body(body)?;
            format!("Reveal the value of {}", secret_label(state, id).await)
        }
        (&Method::POST, ["", "api", "bitwarden", "projects", pid, "secrets"]) => {
            let req: CreateBitwardenSecretRequest = typed(body)?;
            let project = project_names(state, &[pid.to_string()]).await.join("");
            format!("Create secret {} in {project}", quoted(&req.key))
        }
        (&Method::PUT, ["", "api", "bitwarden", "secrets", id]) => {
            let req: UpdateBitwardenSecretRequest = typed(body)?;
            let mut changes = Vec::new();
            if let Some(k) = req.key.as_deref().map(str::trim).filter(|k| !k.is_empty()) {
                changes.push(format!("name {}", quoted(k)));
            }
            if req.value.is_some() {
                changes.push("value".to_string());
            }
            if req.note.is_some() {
                changes.push("note".to_string());
            }
            if let Some(pid) = req
                .project_id
                .as_deref()
                .map(str::trim)
                .filter(|p| !p.is_empty())
            {
                let name = project_names(state, &[pid.to_string()]).await.join("");
                changes.push(format!("MOVE to project {name}"));
            }
            format!(
                "Edit {}: {}",
                secret_label(state, id).await,
                changes.join(", ")
            )
        }
        (&Method::DELETE, ["", "api", "bitwarden", "secrets", id]) => {
            no_body(body)?;
            format!("Delete {}", secret_label(state, id).await)
        }
        (&Method::DELETE, ["", "api", "approvals", "devices", id]) => {
            no_body(body)?;
            let name = approvals(state)
                .data
                .lock()
                .await
                .devices
                .iter()
                .find(|d| d.id.to_string() == *id)
                .map(|d| format!("{} ({})", quoted(&d.name), quoted(&d.platform)))
                .unwrap_or_else(|| "an unknown device".into());
            format!("Remove approval device {name}")
        }
        (&Method::PUT, ["", "api", "approvals", "mode"]) => {
            let req: ModeRequest = typed(body)?;
            format!(
                "Set approval mode to {}",
                format!("{:?}", req.mode).to_lowercase()
            )
        }
        (&Method::POST, ["", "api", "approvals", "devices"]) => {
            let req: EnrollRequest = typed(body)?;
            format!(
                "Enroll approval device {} ({})",
                quoted(&req.name),
                quoted(&req.platform)
            )
        }
        (&Method::GET, ["", "api", "settings", "backup"]) => {
            no_body(body)?;
            "Download a backup of backend settings and keys".into()
        }
        (&Method::POST, ["", "api", "settings", "restore"]) => {
            "Restore backend settings from a backup".into()
        }
        (&Method::POST, ["", "api", "mcp", "external-sessions"]) => {
            let req: crate::control_mcp::gateway::CreateExternalSessionRequest = typed(body)?;
            req.describe_for_approval()
        }
        _ => return Err("This request does not need a device approval".into()),
    })
}

/// Operations that need a device signature.
pub fn is_protected(method: &Method, path: &str) -> bool {
    let p = path.trim_end_matches('/');
    let seg: Vec<&str> = p.split('/').collect();
    match (method, seg.as_slice()) {
        (&Method::POST, ["", "api", "bitwarden", "requests", _, "approve" | "reject"]) => true,
        (&Method::POST, ["", "api", "mission-access", _, "approve" | "deny"]) => true,
        (&Method::POST, ["", "api", "privilege-access", "bunker" | "unbunker" | "approve-all"]) => {
            true
        }
        (&Method::POST, ["", "api", "privilege-access", _, "approve" | "deny"]) => true,
        (&Method::PUT, ["", "api", "bitwarden", "default-access", _]) => true,
        (&Method::PUT, ["", "api", "bitwarden", "config"]) => true,
        // The hub URL and token decide where usage data (and prompts) go.
        (&Method::PUT, ["", "api", "usage-telemetry", "config"]) => true,
        (&Method::GET, ["", "api", "bitwarden", "secrets", _, "reveal"]) => true,
        (&Method::POST, ["", "api", "bitwarden", "projects", _, "secrets"]) => true,
        (&Method::PUT | &Method::DELETE, ["", "api", "bitwarden", "secrets", _]) => true,
        (&Method::DELETE, ["", "api", "approvals", "devices", _]) => true,
        (&Method::POST, ["", "api", "approvals", "approve-all"]) => true,
        (&Method::PUT, ["", "api", "approvals", "mode"]) => true,
        // A backup restore can rewrite device, grant and access state on disk.
        (&Method::POST, ["", "api", "settings", "restore"]) => true,
        // Backups contain the backend's private key and stored credentials.
        (&Method::GET, ["", "api", "settings", "backup"]) => true,
        (&Method::POST, ["", "api", "mcp", "external-sessions"]) => true,
        _ => false,
    }
}

/// Protected operations that need a device signature even when the approval
/// mode is `off` or `warn`: granting a mission access to another mission is
/// only ever decided with Touch ID / Face ID.
pub fn always_signed(method: &Method, path: &str) -> bool {
    let seg: Vec<&str> = path.trim_end_matches('/').split('/').collect();
    matches!(
        (method, seg.as_slice()),
        (&Method::POST, ["", "api", "mission-access", _, "approve"])
            | (
                &Method::POST,
                [
                    "",
                    "api",
                    "privilege-access",
                    "bunker" | "unbunker" | "approve-all"
                ]
            )
            | (&Method::POST, ["", "api", "privilege-access", _, "approve"])
            | (&Method::POST, ["", "api", "approvals", "approve-all"])
            | (&Method::POST, ["", "api", "mcp", "external-sessions"])
    )
}

/// Decodes RFC 3986 unreserved percent-encodings (`-`, `_`, `~`) produced by
/// `CharacterSet.alphanumerics` on older iOS builds while keeping all other
/// percent sequences intact so `path.contains('%')` still blocks encoded
/// separators or traversal bytes.
pub(crate) fn normalize_unreserved_percent_encoding(path: &str) -> String {
    if !path.contains('%') {
        return path.to_string();
    }
    path.replace("%2D", "-")
        .replace("%2d", "-")
        .replace("%5F", "_")
        .replace("%5f", "_")
        .replace("%7E", "~")
        .replace("%7e", "~")
}

/// Middleware: runs after authentication; only acts on protected operations.
pub async fn require_device_approval(
    State(state): State<Arc<AppState>>,
    mut req: Request<Body>,
    next: Next,
) -> Response {
    let method = req.method().clone();
    let raw_path = req.uri().path().to_string();
    let path = normalize_unreserved_percent_encoding(&raw_path);
    if path != raw_path {
        let pq = match req.uri().query() {
            Some(q) if !q.is_empty() => format!("{path}?{q}"),
            _ => path.clone(),
        };
        if let Ok(new_uri) = pq.parse::<axum::http::Uri>() {
            *req.uri_mut() = new_uri;
        }
    }
    let guarded_prefix = path.starts_with("/api/bitwarden")
        || path.starts_with("/api/approvals")
        || path.starts_with("/api/mission-access")
        || path.starts_with("/api/privilege-access")
        || path.starts_with("/api/mcp/external-sessions");
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
    let mode = if always_signed(&method, &path) {
        Mode::Enforce
    } else {
        store.mode().await
    };
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
        .route("/queue", get(super::approval_queue::queue))
        .route("/approve-all", post(super::approval_queue::approve_all))
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
    axum::Extension(user): axum::Extension<super::auth::AuthUser>,
    Json(req): Json<ChallengeRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let method = req.method.trim().to_ascii_uppercase();
    let method_parsed = Method::from_bytes(method.as_bytes())
        .map_err(|_| (StatusCode::BAD_REQUEST, "Bad method".into()))?;
    let path = normalize_unreserved_percent_encoding(req.path.split('?').next().unwrap_or(""));
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
    if req.body_sha256.is_some() && path.trim_end_matches('/') != "/api/settings/restore" {
        return Err((
            StatusCode::BAD_REQUEST,
            "body_sha256 is only for binary backup restores; send the JSON body".into(),
        ));
    }
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
    let summary = describe(&state, &user.id, &method_parsed, &path, &req.body)
        .await
        .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
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
    let path = normalize_unreserved_percent_encoding(req.uri().path());
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
    let trimmed_pubkey = body.public_key.trim().to_string();
    {
        let data = store.data.lock().await;
        if let Some(existing) = data
            .devices
            .iter()
            .find(|d| d.revoked_at.is_none() && d.public_key == trimmed_pubkey)
            .cloned()
        {
            return Ok(Json(existing));
        }
    }
    let has_active_platform_device = store
        .data
        .lock()
        .await
        .devices
        .iter()
        .any(|d| d.revoked_at.is_none() && d.platform == platform);
    let mode = store.mode().await;
    let authorized = match (&header, &body.enrollment_code) {
        (Some(h), _) => store.verify(h, "POST", &path, &bytes).await.is_ok(),
        (None, Some(code)) if !code.trim().is_empty() => store.take_enrollment_code(code).await,
        _ => mode == Mode::Warn && !has_active_platform_device,
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
        public_key: trimmed_pubkey,
        created_at: Utc::now(),
        last_used_at: None,
        revoked_at: None,
    };
    let mut data = store.data.lock().await;
    if let Some(existing) = data
        .devices
        .iter()
        .find(|d| d.revoked_at.is_none() && d.public_key == device.public_key)
        .cloned()
    {
        return Ok(Json(existing));
    }
    data.devices.push(device.clone());
    if let Err(e) = store.save(&data).await {
        data.devices.pop();
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Could not save the device: {e}"),
        ));
    }
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
    if let Err(e) = store.save(&data).await {
        if let Some(d) = data.devices.iter_mut().find(|d| d.id == id) {
            d.revoked_at = None;
        }
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Could not save: {e}"),
        ));
    }
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
    let previous = data.mode;
    data.mode = req.mode;
    if let Err(e) = store.save(&data).await {
        data.mode = previous;
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Could not save: {e}"),
        ));
    }
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

    #[tokio::test]
    async fn approve_all_signature_covers_exactly_the_listed_requests() {
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
        let path = "/api/approvals/approve-all";
        let item = |id: &str| {
            format!(
                r#"{{"kind":"privilege","id":"{id}","digest":"{}"}}"#,
                "a".repeat(64)
            )
        };
        let a = "00000000-0000-4000-8000-00000000000a";
        let b = "00000000-0000-4000-8000-00000000000b";
        let signed = format!(r#"{{"items":[{}]}}"#, item(a));
        let sign = |c: &Challenge| {
            let sig = kp.sign(&SystemRandom::new(), c.payload.as_bytes()).unwrap();
            base64::engine::general_purpose::STANDARD.encode(sig.as_ref())
        };
        // A request added after the challenge, or a tier changed, breaks the signature.
        let added = format!(r#"{{"items":[{},{}]}}"#, item(a), item(b));
        let tampered = signed.replace(r#""privilege""#, r#""secret""#);
        for body in [added.as_str(), tampered.as_str()] {
            let (id, c) = s
                .issue("POST", path, &sha256_hex(signed.as_bytes()), "approve all")
                .await;
            let header = format!("{id}.{device}.{}", sign(&c));
            assert!(s
                .verify(&header, "POST", path, body.as_bytes())
                .await
                .is_err());
        }
        let (id, c) = s
            .issue("POST", path, &sha256_hex(signed.as_bytes()), "approve all")
            .await;
        let header = format!("{id}.{device}.{}", sign(&c));
        assert!(s
            .verify(&header, "POST", path, signed.as_bytes())
            .await
            .is_ok());
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
        assert!(is_protected(
            &Method::POST,
            "/api/mission-access/abc/approve"
        ));
        assert!(is_protected(&Method::POST, "/api/mission-access/abc/deny"));
        assert!(always_signed(
            &Method::POST,
            "/api/mission-access/abc/approve"
        ));
        assert!(!always_signed(
            &Method::POST,
            "/api/bitwarden/requests/abc/approve"
        ));
        assert!(!is_protected(&Method::GET, "/api/mission-access"));
        for path in [
            "/api/approvals/approve-all",
            "/api/privilege-access/approve-all",
            "/api/mcp/external-sessions",
        ] {
            assert!(is_protected(&Method::POST, path), "{path}");
            assert!(always_signed(&Method::POST, path), "{path}");
        }
        assert!(!is_protected(&Method::GET, "/api/mcp/external-sessions"));
        assert!(!is_protected(
            &Method::DELETE,
            "/api/mcp/external-sessions/00000000-0000-4000-8000-000000000001"
        ));
    }

    #[test]
    fn quoted_strips_control_characters_and_caps_length() {
        let q = quoted("evil\nAllow: read\u{202e}x\"y");
        assert!(!q.contains('\n') && !q.contains('\u{202e}'));
        assert_eq!(quoted(&"a".repeat(200)).len(), 62);
    }

    #[test]
    fn normalize_unreserved_percent_encoding_decodes_uuid_hyphens_only() {
        assert_eq!(
            normalize_unreserved_percent_encoding(
                "/api/privilege-access/1722a8ac%2D49c5%2D4193%2D9317%2D7498a0dceffd/approve"
            ),
            "/api/privilege-access/1722a8ac-49c5-4193-9317-7498a0dceffd/approve"
        );
        assert!(
            normalize_unreserved_percent_encoding("/api/privilege-access/%2e%2e/approve")
                .contains('%')
        );
    }
}
