//! Bitwarden Secrets Manager (`bws`) integration API endpoints.
//!
//! Exposes Machine Account project & secret management over `/api/bitwarden/*`.
//! Secret values are NEVER returned in list responses; revealing or mutating a
//! secret uses dedicated endpoints that Orb clients gate behind Touch ID (macOS)
//! or Face ID (iOS).

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;

use axum::{
    extract::{Path as AxumPath, State},
    http::StatusCode,
    response::Json,
    routing::{get, post, put},
    Router,
};
use serde::{Deserialize, Serialize};
use tokio::process::Command;

use crate::env_crypto;
use crate::settings::BitwardenSettings;

use super::routes::AppState;

/// Canonical Bitwarden project ID for `paloma` in Thomas's Bitwarden Secrets Manager.
pub const PALOMA_BITWARDEN_PROJECT_ID: &str = "297f3106-758f-43d5-8a4b-b460007558c8";

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/status", get(get_status))
        .route("/config", put(update_config))
        .route("/projects", get(list_projects))
        .route(
            "/projects/:project_id/secrets",
            get(list_project_secrets).post(create_project_secret),
        )
        .route("/secrets/:secret_id/reveal", get(reveal_secret))
        .route(
            "/secrets/:secret_id",
            put(update_secret).delete(delete_secret),
        )
        .route("/secrets", get(list_every_secret))
        .route("/broker", get(get_broker))
        .route("/requests/:request_id/approve", post(approve_request))
        .route("/requests/:request_id/reject", post(reject_request))
        .route("/grants/:grant_id", axum::routing::delete(revoke_grant))
        .route("/default-access/:slug", put(set_default_access))
}

#[derive(Debug, Clone, Serialize)]
pub struct BitwardenStatusResponse {
    pub configured: bool,
    pub token_source: Option<String>,
    pub token_hint: Option<String>,
    pub bws_installed: bool,
    pub bws_version: Option<String>,
    pub server_url: Option<String>,
    pub default_project_id: String,
    pub project_bindings: BTreeMap<String, String>,
    /// Paloma project slug -> Bitwarden projects readable without approval.
    pub default_access: BTreeMap<String, Vec<String>>,
    pub pending_requests: usize,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpdateBitwardenConfigRequest {
    /// New Machine Account access token (`BWS_ACCESS_TOKEN`).
    /// Pass `Some("")` to clear the settings-stored token, or omit (`None`) to keep existing.
    #[serde(default)]
    pub access_token: Option<String>,
    /// Optional custom server URL (`None` = unchanged, `Some("")` = clear).
    #[serde(default)]
    pub server_url: Option<String>,
    /// Default Bitwarden project UUID to display.
    #[serde(default)]
    pub default_project_id: Option<String>,
    /// Mapping from Paloma project slug -> Bitwarden project UUID.
    #[serde(default)]
    pub project_bindings: Option<BTreeMap<String, String>>,
    /// Skip live token validation with `bws` (useful if configuring offline).
    #[serde(default)]
    pub skip_validation: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BitwardenProject {
    pub id: String,
    pub name: String,
    #[serde(rename = "organizationId", default)]
    pub organization_id: Option<String>,
    #[serde(rename = "creationDate", default)]
    pub creation_date: Option<String>,
    #[serde(rename = "revisionDate", default)]
    pub revision_date: Option<String>,
}

/// Summary of a Bitwarden secret with the secret value stripped.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BitwardenSecretSummary {
    pub id: String,
    pub key: String,
    #[serde(default)]
    pub note: String,
    #[serde(rename = "projectId", default)]
    pub project_id: Option<String>,
    #[serde(rename = "organizationId", default)]
    pub organization_id: Option<String>,
    #[serde(rename = "creationDate", default)]
    pub creation_date: Option<String>,
    #[serde(rename = "revisionDate", default)]
    pub revision_date: Option<String>,
}

/// Full Bitwarden secret including decrypted plaintext `value` (only returned on `/reveal`, create, or edit).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BitwardenSecretDetail {
    pub id: String,
    pub key: String,
    pub value: String,
    #[serde(default)]
    pub note: String,
    #[serde(rename = "projectId", default)]
    pub project_id: Option<String>,
    #[serde(rename = "organizationId", default)]
    pub organization_id: Option<String>,
    #[serde(rename = "creationDate", default)]
    pub creation_date: Option<String>,
    #[serde(rename = "revisionDate", default)]
    pub revision_date: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateBitwardenSecretRequest {
    pub key: String,
    pub value: String,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpdateBitwardenSecretRequest {
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub value: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub project_id: Option<String>,
}

/// Load the 32-byte AES-256-GCM key used for `env_crypto` values.
pub(crate) async fn load_encryption_key(working_dir: &Path) -> Option<[u8; 32]> {
    if let Ok(Some(key)) = env_crypto::load_private_key_from_env() {
        return Some(key);
    }
    let key_file = working_dir.join(".sandboxed-sh").join("private_key");
    if let Ok(contents) = tokio::fs::read_to_string(&key_file).await {
        let trimmed = contents.trim();
        if !trimmed.is_empty() {
            if let Ok(key) = env_crypto::parse_key_hex(trimmed) {
                return Some(key);
            }
        }
    }
    env_crypto::ensure_private_key().await.ok()
}

/// Produce a safe, non-sensitive hint for an access token (never reveals the secret part).
fn mask_token_hint(token: &str) -> String {
    let trimmed = token.trim();
    if trimmed.len() <= 12 {
        return "••••••••".to_string();
    }
    // Bitwarden machine tokens have format `0.<access_token_id>.<secret>:<key>`
    if let Some((prefix, _)) = trimmed.split_once(':') {
        let parts: Vec<&str> = prefix.split('.').collect();
        if parts.len() >= 2 && parts[1].len() >= 8 {
            let id_part = parts[1];
            return format!(
                "{}.{}…•{}",
                parts[0],
                &id_part[..8],
                &trimmed[trimmed.len().saturating_sub(4)..]
            );
        }
    }
    format!(
        "{}…{}",
        &trimmed[..6],
        &trimmed[trimmed.len().saturating_sub(4)..]
    )
}

/// Resolve `(token, source_label)` from:
/// 1. `settings.bitwarden.encrypted_access_token`
/// 2. `BWS_ACCESS_TOKEN` environment variable
///
/// Core is the only holder of the token: missions get secrets through the
/// broker (`secret_broker.rs`), never the token itself.
async fn resolve_access_token(state: &Arc<AppState>) -> Option<(String, &'static str)> {
    let bw = state.settings.get_bitwarden().await;
    let crypto_key = load_encryption_key(&state.config.working_dir).await;

    if let Some(enc) = bw.encrypted_access_token.as_deref() {
        let trimmed = enc.trim();
        if !trimmed.is_empty() {
            if let Some(key) = crypto_key.as_ref() {
                if let Ok(decrypted) = env_crypto::decrypt_value(key, trimmed) {
                    if !decrypted.trim().is_empty() {
                        return Some((decrypted.trim().to_string(), "settings"));
                    }
                }
            } else if !env_crypto::is_encrypted(trimmed) {
                return Some((trimmed.to_string(), "settings"));
            }
        }
    }

    if let Ok(env_token) = std::env::var("BWS_ACCESS_TOKEN") {
        let trimmed = env_token.trim();
        if !trimmed.is_empty() {
            return Some((trimmed.to_string(), "environment"));
        }
    }

    None
}

fn effective_bindings(bw: &BitwardenSettings) -> (String, BTreeMap<String, String>) {
    let default_project_id = bw
        .default_project_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(PALOMA_BITWARDEN_PROJECT_ID)
        .to_string();
    let mut bindings = bw.project_bindings.clone();
    bindings
        .entry("paloma".to_string())
        .or_insert_with(|| default_project_id.clone());
    (default_project_id, bindings)
}

async fn detect_bws_version() -> Option<String> {
    let output = Command::new("bws").arg("--version").output().await.ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if text.is_empty() {
        Some("bws".to_string())
    } else {
        Some(text)
    }
}

/// The token travels in the child's environment, never argv, where any local
/// user could read it from the process list. The child gets no other parent
/// environment. User-supplied positionals follow `--` so a value starting with
/// `-` cannot be parsed as a flag such as `--server-url`.
fn bws_command(
    token: &str,
    server_url: Option<&str>,
    args: &[&str],
    positionals: &[&str],
) -> Command {
    let mut cmd = Command::new("bws");
    cmd.env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("BWS_ACCESS_TOKEN", token);
    if let Some(home) = std::env::var_os("HOME") {
        cmd.env("HOME", home);
    }
    if let Some(url) = server_url.map(str::trim).filter(|s| !s.is_empty()) {
        cmd.env("BWS_SERVER_URL", url);
    }
    cmd.args(args)
        .args(["--color", "no", "--"])
        .args(positionals);
    cmd
}

fn is_rate_limited(stderr: &[u8]) -> bool {
    let text = String::from_utf8_lossy(stderr);
    text.contains("429") || text.contains("Too Many Requests") || text.contains("Slow down")
}

async fn run_bws(
    token: &str,
    server_url: Option<&str>,
    args: &[&str],
    positionals: &[&str],
) -> Result<String, (StatusCode, String)> {
    // Bitwarden answers bursts (e.g. "Approve all") with 429 "Slow down"; a
    // rate-limited call was not applied, so retrying it is safe.
    let mut attempt = 0u32;
    let output = loop {
        let output = bws_command(token, server_url, args, positionals).output().await.map_err(|e| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                format!("Failed to execute `bws` CLI: {e}. Ensure Bitwarden Secrets CLI (`bws`) is installed on the backend host."),
            )
        })?;
        if output.status.success() || attempt >= 4 || !is_rate_limited(&output.stderr) {
            break output;
        }
        attempt += 1;
        tokio::time::sleep(std::time::Duration::from_millis(1000 << (attempt - 1))).await;
    };

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let detail = if !stderr.is_empty() {
            stderr
        } else if !stdout.is_empty() {
            stdout
        } else {
            format!("bws exited with status {}", output.status)
        };
        let status = if detail.to_lowercase().contains("unauthorized")
            || detail.to_lowercase().contains("invalid access token")
            || detail.to_lowercase().contains("401")
        {
            StatusCode::UNAUTHORIZED
        } else if detail.to_lowercase().contains("not found")
            || detail.to_lowercase().contains("404")
        {
            StatusCode::NOT_FOUND
        } else {
            StatusCode::BAD_GATEWAY
        };
        return Err((status, detail));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// GET /api/bitwarden/status
async fn get_status(State(state): State<Arc<AppState>>) -> Json<BitwardenStatusResponse> {
    let bw = state.settings.get_bitwarden().await;
    let resolved = resolve_access_token(&state).await;
    let bws_version = detect_bws_version().await;
    let (default_project_id, project_bindings) = effective_bindings(&bw);

    Json(BitwardenStatusResponse {
        configured: resolved.is_some(),
        token_source: resolved.as_ref().map(|(_, src)| (*src).to_string()),
        token_hint: resolved.as_ref().map(|(tok, _)| mask_token_hint(tok)),
        bws_installed: bws_version.is_some(),
        bws_version,
        server_url: bw.server_url,
        default_project_id,
        project_bindings,
        default_access: bw.default_access,
        pending_requests: super::secret_broker::broker(&state).pending_count().await,
    })
}

/// PUT /api/bitwarden/config
async fn update_config(
    State(state): State<Arc<AppState>>,
    Json(req): Json<UpdateBitwardenConfigRequest>,
) -> Result<Json<BitwardenStatusResponse>, (StatusCode, String)> {
    let mut bw = state.settings.get_bitwarden().await;

    if let Some(server_url) = req.server_url {
        let trimmed = server_url.trim();
        bw.server_url = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
    }

    if let Some(default_project_id) = req.default_project_id {
        let trimmed = default_project_id.trim();
        bw.default_project_id = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
    }

    if let Some(bindings) = req.project_bindings {
        bw.project_bindings = bindings
            .into_iter()
            .filter_map(|(k, v)| {
                let k = k.trim().to_string();
                let v = v.trim().to_string();
                if k.is_empty() || v.is_empty() {
                    None
                } else {
                    Some((k, v))
                }
            })
            .collect();
    }

    if let Some(raw_token) = req.access_token {
        let trimmed = raw_token.trim();
        if trimmed.is_empty() {
            bw.encrypted_access_token = None;
        } else {
            if !req.skip_validation && detect_bws_version().await.is_some() {
                run_bws(
                    trimmed,
                    bw.server_url.as_deref(),
                    &["project", "list", "--output", "json"],
                    &[],
                )
                .await?;
            }
            let key = load_encryption_key(&state.config.working_dir)
                .await
                .ok_or_else(|| {
                    (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "Encryption key unavailable".to_string(),
                    )
                })?;
            let encrypted = env_crypto::encrypt_value(&key, trimmed).map_err(|e| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("Failed to encrypt Bitwarden access token: {e}"),
                )
            })?;
            bw.encrypted_access_token = Some(encrypted);
        }
    }

    state.settings.set_bitwarden(bw).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to save Bitwarden settings: {e}"),
        )
    })?;

    Ok(get_status(State(state)).await)
}

async fn require_token_and_url(
    state: &Arc<AppState>,
) -> Result<(String, Option<String>), (StatusCode, String)> {
    let bw = state.settings.get_bitwarden().await;
    let (token, _) = resolve_access_token(state).await.ok_or_else(|| {
        (
            StatusCode::PRECONDITION_REQUIRED,
            "Bitwarden Machine Account access token is not configured.".to_string(),
        )
    })?;
    Ok((token, bw.server_url))
}

/// GET /api/bitwarden/projects
async fn list_projects(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<BitwardenProject>>, (StatusCode, String)> {
    let (token, server_url) = require_token_and_url(&state).await?;
    let stdout = run_bws(
        &token,
        server_url.as_deref(),
        &["project", "list", "--output", "json"],
        &[],
    )
    .await?;
    let mut projects: Vec<BitwardenProject> = serde_json::from_str(&stdout).map_err(|e| {
        (
            StatusCode::BAD_GATEWAY,
            format!("Invalid JSON from `bws project list`: {e}"),
        )
    })?;
    projects.sort_by_key(|p| p.name.to_lowercase());
    Ok(Json(projects))
}

/// GET /api/bitwarden/projects/:project_id/secrets
async fn list_project_secrets(
    State(state): State<Arc<AppState>>,
    AxumPath(project_id): AxumPath<String>,
) -> Result<Json<Vec<BitwardenSecretSummary>>, (StatusCode, String)> {
    let project_id = project_id.trim();
    if project_id.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "project_id is required".to_string(),
        ));
    }
    let (token, server_url) = require_token_and_url(&state).await?;
    let stdout = run_bws(
        &token,
        server_url.as_deref(),
        &["secret", "list", "--output", "json"],
        &[project_id],
    )
    .await?;
    let mut secrets: Vec<BitwardenSecretSummary> = serde_json::from_str(&stdout).map_err(|e| {
        (
            StatusCode::BAD_GATEWAY,
            format!("Invalid JSON from `bws secret list`: {e}"),
        )
    })?;
    secrets.sort_by_key(|s| s.key.to_lowercase());
    Ok(Json(secrets))
}

/// GET /api/bitwarden/secrets/:secret_id/reveal
async fn reveal_secret(
    State(state): State<Arc<AppState>>,
    AxumPath(secret_id): AxumPath<String>,
) -> Result<Json<BitwardenSecretDetail>, (StatusCode, String)> {
    let secret_id = secret_id.trim();
    if secret_id.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "secret_id is required".to_string()));
    }
    let (token, server_url) = require_token_and_url(&state).await?;
    let stdout = run_bws(
        &token,
        server_url.as_deref(),
        &["secret", "get", "--output", "json"],
        &[secret_id],
    )
    .await?;
    let secret: BitwardenSecretDetail = serde_json::from_str(&stdout).map_err(|e| {
        (
            StatusCode::BAD_GATEWAY,
            format!("Invalid JSON from `bws secret get`: {e}"),
        )
    })?;
    Ok(Json(secret))
}

/// POST /api/bitwarden/projects/:project_id/secrets
async fn create_project_secret(
    State(state): State<Arc<AppState>>,
    AxumPath(project_id): AxumPath<String>,
    Json(req): Json<CreateBitwardenSecretRequest>,
) -> Result<Json<BitwardenSecretDetail>, (StatusCode, String)> {
    let project_id = project_id.trim();
    let key = req.key.trim();
    if project_id.is_empty() || key.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Both project_id and secret key are required".to_string(),
        ));
    }
    let (token, server_url) = require_token_and_url(&state).await?;
    super::secret_broker::broker(&state).invalidate_list().await;
    // `--flag=value` keeps a user value that starts with `-` from becoming a flag.
    let note = req
        .note
        .as_deref()
        .filter(|n| !n.is_empty())
        .map(|n| format!("--note={n}"));
    let mut args = vec!["secret", "create", "--output", "json"];
    args.extend(note.as_deref());
    let stdout = run_bws(
        &token,
        server_url.as_deref(),
        &args,
        &[key, &req.value, project_id],
    )
    .await?;
    let created: BitwardenSecretDetail = serde_json::from_str(&stdout).map_err(|e| {
        (
            StatusCode::BAD_GATEWAY,
            format!("Invalid JSON from `bws secret create`: {e}"),
        )
    })?;
    Ok(Json(created))
}

/// PUT /api/bitwarden/secrets/:secret_id
async fn update_secret(
    State(state): State<Arc<AppState>>,
    AxumPath(secret_id): AxumPath<String>,
    Json(req): Json<UpdateBitwardenSecretRequest>,
) -> Result<Json<BitwardenSecretDetail>, (StatusCode, String)> {
    let secret_id = secret_id.trim();
    if secret_id.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "secret_id is required".to_string()));
    }
    if req.key.is_none() && req.value.is_none() && req.note.is_none() && req.project_id.is_none() {
        return Err((
            StatusCode::BAD_REQUEST,
            "At least one of key, value, note, or project_id must be provided".to_string(),
        ));
    }
    let (token, server_url) = require_token_and_url(&state).await?;
    super::secret_broker::broker(&state).invalidate_list().await;
    let key = req
        .key
        .as_deref()
        .map(str::trim)
        .filter(|k| !k.is_empty())
        .map(|k| format!("--key={k}"));
    let value = req.value.as_deref().map(|v| format!("--value={v}"));
    let note = req.note.as_deref().map(|n| format!("--note={n}"));
    let project = req
        .project_id
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(|p| format!("--project-id={p}"));
    let mut args: Vec<&str> = vec!["secret", "edit", "--output", "json"];
    args.extend(
        [&key, &value, &note, &project]
            .into_iter()
            .filter_map(|o| o.as_deref()),
    );

    let stdout = run_bws(&token, server_url.as_deref(), &args, &[secret_id]).await?;
    let updated: BitwardenSecretDetail = serde_json::from_str(&stdout).map_err(|e| {
        (
            StatusCode::BAD_GATEWAY,
            format!("Invalid JSON from `bws secret edit`: {e}"),
        )
    })?;
    Ok(Json(updated))
}

/// DELETE /api/bitwarden/secrets/:secret_id
async fn delete_secret(
    State(state): State<Arc<AppState>>,
    AxumPath(secret_id): AxumPath<String>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let secret_id = secret_id.trim();
    if secret_id.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "secret_id is required".to_string()));
    }
    let (token, server_url) = require_token_and_url(&state).await?;
    super::secret_broker::broker(&state).invalidate_list().await;
    run_bws(
        &token,
        server_url.as_deref(),
        &["secret", "delete", "--output", "none"],
        &[secret_id],
    )
    .await?;
    Ok(Json(serde_json::json!({ "success": true })))
}

type ApiError = (StatusCode, String);

fn parse_json<T: serde::de::DeserializeOwned>(stdout: &str, what: &str) -> Result<T, ApiError> {
    serde_json::from_str(stdout).map_err(|e| {
        (
            StatusCode::BAD_GATEWAY,
            format!("Invalid JSON from `bws {what}`: {e}"),
        )
    })
}

/// Every Bitwarden project the machine account can read.
pub(crate) async fn list_projects_raw(
    state: &Arc<AppState>,
) -> Result<Vec<BitwardenProject>, ApiError> {
    let (token, server_url) = require_token_and_url(state).await?;
    let stdout = run_bws(
        &token,
        server_url.as_deref(),
        &["project", "list", "--output", "json"],
        &[],
    )
    .await?;
    let mut projects: Vec<BitwardenProject> = parse_json(&stdout, "project list")?;
    projects.sort_by_key(|p| p.name.to_lowercase());
    Ok(projects)
}

/// Every secret (values stripped) across every readable project.
pub(crate) async fn list_all_secrets(
    state: &Arc<AppState>,
) -> Result<Vec<BitwardenSecretSummary>, ApiError> {
    let (token, server_url) = require_token_and_url(state).await?;
    let stdout = run_bws(
        &token,
        server_url.as_deref(),
        &["secret", "list", "--output", "json"],
        &[],
    )
    .await?;
    let mut secrets: Vec<BitwardenSecretSummary> = parse_json(&stdout, "secret list")?;
    secrets.sort_by_key(|s| s.key.to_lowercase());
    Ok(secrets)
}

pub(crate) async fn get_secret(
    state: &Arc<AppState>,
    id: &str,
) -> Result<BitwardenSecretDetail, ApiError> {
    let (token, server_url) = require_token_and_url(state).await?;
    let stdout = run_bws(
        &token,
        server_url.as_deref(),
        &["secret", "get", "--output", "json"],
        &[id],
    )
    .await?;
    parse_json(&stdout, "secret get")
}

pub(crate) async fn create_secret(
    state: &Arc<AppState>,
    project_id: &str,
    key: &str,
    value: &str,
    note: Option<&str>,
) -> Result<BitwardenSecretDetail, ApiError> {
    let (token, server_url) = require_token_and_url(state).await?;
    let note = note
        .filter(|n| !n.is_empty())
        .map(|n| format!("--note={n}"));
    let mut args = vec!["secret", "create", "--output", "json"];
    args.extend(note.as_deref());
    let stdout = run_bws(
        &token,
        server_url.as_deref(),
        &args,
        &[key, value, project_id],
    )
    .await?;
    super::secret_broker::broker(state).invalidate_list().await;
    parse_json(&stdout, "secret create")
}

pub(crate) async fn edit_secret_value(
    state: &Arc<AppState>,
    id: &str,
    value: &str,
    note: Option<&str>,
) -> Result<BitwardenSecretDetail, ApiError> {
    let (token, server_url) = require_token_and_url(state).await?;
    let value = format!("--value={value}");
    let note = note.map(|n| format!("--note={n}"));
    let mut args: Vec<&str> = vec!["secret", "edit", "--output", "json", &value];
    args.extend(note.as_deref());
    let stdout = run_bws(&token, server_url.as_deref(), &args, &[id]).await?;
    super::secret_broker::broker(state).invalidate_list().await;
    parse_json(&stdout, "secret edit")
}

pub(crate) async fn delete_secret_by_id(state: &Arc<AppState>, id: &str) -> Result<(), ApiError> {
    let (token, server_url) = require_token_and_url(state).await?;
    run_bws(
        &token,
        server_url.as_deref(),
        &["secret", "delete", "--output", "none"],
        &[id],
    )
    .await?;
    super::secret_broker::broker(state).invalidate_list().await;
    Ok(())
}

pub(crate) async fn move_secret(
    state: &Arc<AppState>,
    id: &str,
    project_id: &str,
) -> Result<BitwardenSecretDetail, ApiError> {
    let (token, server_url) = require_token_and_url(state).await?;
    let project = format!("--project-id={project_id}");
    let stdout = run_bws(
        &token,
        server_url.as_deref(),
        &["secret", "edit", "--output", "json", &project],
        &[id],
    )
    .await?;
    super::secret_broker::broker(state).invalidate_list().await;
    parse_json(&stdout, "secret edit")
}

#[derive(Debug, Serialize)]
pub struct SecretWithProject {
    #[serde(flatten)]
    pub secret: BitwardenSecretSummary,
    #[serde(rename = "projectName")]
    pub project_name: Option<String>,
}

/// GET /api/bitwarden/secrets — names across every project, for the grouped view.
async fn list_every_secret(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<SecretWithProject>>, ApiError> {
    let names: BTreeMap<String, String> = list_projects_raw(&state)
        .await?
        .into_iter()
        .map(|p| (p.id, p.name))
        .collect();
    let secrets = super::secret_broker::broker(&state)
        .list_all(&state, true)
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, e))?;
    Ok(Json(
        secrets
            .into_iter()
            .map(|s| SecretWithProject {
                project_name: s.project_id.as_ref().and_then(|id| names.get(id).cloned()),
                secret: s,
            })
            .collect(),
    ))
}

/// GET /api/bitwarden/broker — pending/resolved requests, live grants, read log.
async fn get_broker(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    Json(super::secret_broker::broker(&state).snapshot().await)
}

#[derive(Debug, Deserialize)]
pub struct ApproveRequest {
    /// `secret`, `project` or `all` (reads only).
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub ttl_hours: Option<i64>,
}

fn parse_uuid(raw: &str) -> Result<uuid::Uuid, ApiError> {
    uuid::Uuid::parse_str(raw.trim())
        .map_err(|_| (StatusCode::BAD_REQUEST, "Invalid id".to_string()))
}

/// POST /api/bitwarden/requests/:id/approve
async fn approve_request(
    State(state): State<Arc<AppState>>,
    AxumPath(request_id): AxumPath<String>,
    Json(req): Json<ApproveRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let id = parse_uuid(&request_id)?;
    let r = super::secret_broker::broker(&state)
        .approve(&state, id, req.scope.as_deref(), req.ttl_hours)
        .await
        .map_err(|e| (StatusCode::CONFLICT, e))?;
    Ok(Json(r.public()))
}

/// POST /api/bitwarden/requests/:id/reject
async fn reject_request(
    State(state): State<Arc<AppState>>,
    AxumPath(request_id): AxumPath<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let id = parse_uuid(&request_id)?;
    let r = super::secret_broker::broker(&state)
        .reject(id)
        .await
        .map_err(|e| (StatusCode::CONFLICT, e))?;
    Ok(Json(r.public()))
}

/// DELETE /api/bitwarden/grants/:id
async fn revoke_grant(
    State(state): State<Arc<AppState>>,
    AxumPath(grant_id): AxumPath<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let id = parse_uuid(&grant_id)?;
    if super::secret_broker::broker(&state).revoke(id).await {
        Ok(Json(serde_json::json!({ "success": true })))
    } else {
        Err((StatusCode::NOT_FOUND, "Grant not found".into()))
    }
}

#[derive(Debug, Deserialize)]
pub struct DefaultAccessRequest {
    pub project_ids: Vec<String>,
}

/// PUT /api/bitwarden/default-access/:slug
async fn set_default_access(
    State(state): State<Arc<AppState>>,
    AxumPath(slug): AxumPath<String>,
    Json(req): Json<DefaultAccessRequest>,
) -> Result<Json<BitwardenStatusResponse>, ApiError> {
    let slug = slug.trim().to_string();
    if slug.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "project slug is required".into()));
    }
    let mut ids: Vec<String> = req
        .project_ids
        .into_iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    ids.sort();
    ids.dedup();
    let mut bw = state.settings.get_bitwarden().await;
    // The explicit list supersedes the legacy single binding for this project.
    bw.project_bindings.remove(&slug);
    bw.default_access.insert(slug, ids);
    state.settings.set_bitwarden(bw).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to save Bitwarden settings: {e}"),
        )
    })?;
    Ok(get_status(State(state)).await)
}

#[cfg(test)]
mod bws_command_tests {
    use super::bws_command;

    #[test]
    fn token_is_passed_in_env_not_argv_and_positionals_follow_separator() {
        let cmd = bws_command(
            "secret-token",
            Some("https://vault.example"),
            &["secret", "get", "--output", "json"],
            &["--server-url=evil"],
        );
        let std = cmd.as_std();
        let args: Vec<_> = std
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert!(!args.iter().any(|a| a.contains("secret-token")));
        assert_eq!(
            args,
            [
                "secret",
                "get",
                "--output",
                "json",
                "--color",
                "no",
                "--",
                "--server-url=evil"
            ]
        );
        let envs: Vec<_> = std
            .get_envs()
            .map(|(k, v)| {
                (
                    k.to_string_lossy().into_owned(),
                    v.map(|v| v.to_string_lossy().into_owned()),
                )
            })
            .collect();
        assert!(envs.contains(&("BWS_ACCESS_TOKEN".into(), Some("secret-token".into()))));
        assert!(envs.contains(&(
            "BWS_SERVER_URL".into(),
            Some("https://vault.example".into())
        )));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn masks_bitwarden_machine_token_without_exposing_secret() {
        let sample = "0.297f3106-758f-43d5-8a4b-b460007558c8.supersecretvalue123456:base64key==";
        let hint = mask_token_hint(sample);
        assert_eq!(hint, "0.297f3106…•ey==");
        assert!(!hint.contains("supersecretvalue"));
    }

    #[test]
    fn effective_bindings_defaults_paloma_to_canonical_project() {
        let bw = BitwardenSettings::default();
        let (default_id, bindings) = effective_bindings(&bw);
        assert_eq!(default_id, PALOMA_BITWARDEN_PROJECT_ID);
        assert_eq!(
            bindings.get("paloma").map(String::as_str),
            Some(PALOMA_BITWARDEN_PROJECT_ID)
        );
    }
}
