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
    routing::{get, put},
    Router,
};
use serde::{Deserialize, Serialize};
use tokio::process::Command;

use crate::library::env_crypto;
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
async fn load_encryption_key(working_dir: &Path) -> Option<[u8; 32]> {
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
/// 3. Encrypted `BWS_ACCESS_TOKEN` in library workspace templates (`~/.sandboxed-sh/library/workspace-template/*.json`)
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

    // Fallback: inspect library workspace templates for `BWS_ACCESS_TOKEN`
    let mut candidate_dirs = vec![state.config.library_path.join("workspace-template")];
    let root_lib = std::path::PathBuf::from("/root/.sandboxed-sh/library/workspace-template");
    if !candidate_dirs.contains(&root_lib) {
        candidate_dirs.push(root_lib);
    }

    for dir in candidate_dirs {
        let Ok(mut entries) = tokio::fs::read_dir(&dir).await else {
            continue;
        };
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let Ok(text) = tokio::fs::read_to_string(&path).await else {
                continue;
            };
            let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
                continue;
            };
            let Some(raw_val) = json
                .get("env_vars")
                .and_then(|v| v.get("BWS_ACCESS_TOKEN"))
                .and_then(|v| v.as_str())
            else {
                continue;
            };
            let raw_trimmed = raw_val.trim();
            if raw_trimmed.is_empty() {
                continue;
            }
            if env_crypto::is_encrypted(raw_trimmed) {
                if let Some(key) = crypto_key.as_ref() {
                    if let Ok(decrypted) = env_crypto::decrypt_value(key, raw_trimmed) {
                        if !decrypted.trim().is_empty() {
                            return Some((decrypted.trim().to_string(), "library"));
                        }
                    }
                }
            } else {
                return Some((raw_trimmed.to_string(), "library"));
            }
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

async fn run_bws(
    token: &str,
    server_url: Option<&str>,
    args: &[&str],
) -> Result<String, (StatusCode, String)> {
    let mut cmd = Command::new("bws");
    cmd.args(args)
        .arg("--access-token")
        .arg(token)
        .arg("--color")
        .arg("no");
    if let Some(url) = server_url.map(str::trim).filter(|s| !s.is_empty()) {
        cmd.arg("--server-url").arg(url);
    }

    let output = cmd.output().await.map_err(|e| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            format!("Failed to execute `bws` CLI: {e}. Ensure Bitwarden Secrets CLI (`bws`) is installed on the backend host."),
        )
    })?;

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
    )
    .await?;
    let mut projects: Vec<BitwardenProject> = serde_json::from_str(&stdout).map_err(|e| {
        (
            StatusCode::BAD_GATEWAY,
            format!("Invalid JSON from `bws project list`: {e}"),
        )
    })?;
    projects.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
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
        &["secret", "list", project_id, "--output", "json"],
    )
    .await?;
    let mut secrets: Vec<BitwardenSecretSummary> = serde_json::from_str(&stdout).map_err(|e| {
        (
            StatusCode::BAD_GATEWAY,
            format!("Invalid JSON from `bws secret list`: {e}"),
        )
    })?;
    secrets.sort_by(|a, b| a.key.to_lowercase().cmp(&b.key.to_lowercase()));
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
        &["secret", "get", secret_id, "--output", "json"],
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
    let mut args = vec![
        "secret", "create", key, &req.value, project_id, "--output", "json",
    ];
    let note_owned;
    if let Some(note) = req.note.as_deref().filter(|n| !n.is_empty()) {
        note_owned = note.to_string();
        args.push("--note");
        args.push(&note_owned);
    }
    let stdout = run_bws(&token, server_url.as_deref(), &args).await?;
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
    let mut args: Vec<&str> = vec!["secret", "edit"];
    if let Some(key) = req.key.as_deref().map(str::trim).filter(|k| !k.is_empty()) {
        args.push("--key");
        args.push(key);
    }
    if let Some(value) = req.value.as_deref() {
        args.push("--value");
        args.push(value);
    }
    if let Some(note) = req.note.as_deref() {
        args.push("--note");
        args.push(note);
    }
    if let Some(project_id) = req
        .project_id
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty())
    {
        args.push("--project-id");
        args.push(project_id);
    }
    args.push("--output");
    args.push("json");
    args.push(secret_id);

    let stdout = run_bws(&token, server_url.as_deref(), &args).await?;
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
    run_bws(
        &token,
        server_url.as_deref(),
        &["secret", "delete", secret_id, "--output", "none"],
    )
    .await?;
    Ok(Json(serde_json::json!({ "success": true })))
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
