//! Minimal JWT auth for the dashboard (single-tenant).
//!
//! - Dashboard submits a password to `/api/auth/login`
//! - Server returns a JWT valid for ~30 days
//! - When `DEV_MODE=false`, all API endpoints require `Authorization: Bearer <jwt>`
//!
//! # Security notes
//! - This is intentionally minimal; it is NOT multi-tenant and does not implement RLS.
//! - Use a strong `JWT_SECRET` in production.

use axum::{
    body::Body,
    extract::State,
    http::{Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Extension, Json,
};
use chrono::{Duration, Utc};
use jsonwebtoken::{DecodingKey, EncodingKey, Header, Validation};

use super::routes::AppState;
use super::types::{LoginRequest, LoginResponse};
use crate::config::{AuthMode, Config, UserAccount};
use crate::util::internal_error;

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct Claims {
    /// Subject (we only need a stable sentinel)
    sub: String,
    /// Username (for display/auditing)
    #[serde(default)]
    usr: String,
    /// Issued-at unix seconds
    iat: i64,
    /// Expiration unix seconds
    exp: i64,
}

#[derive(Debug, Clone)]
pub struct AuthUser {
    pub id: String,
    pub username: String,
}

fn configured_single_tenant_user_id() -> Option<String> {
    std::env::var("SANDBOXED_SINGLE_TENANT_USER_ID")
        .or_else(|_| std::env::var("SINGLE_TENANT_USER_ID"))
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn implicit_single_tenant_user_from_id(
    config: &Config,
    configured_user_id: Option<String>,
) -> AuthUser {
    if config.dev_mode {
        return AuthUser {
            id: "dev".to_string(),
            username: "dev".to_string(),
        };
    }

    let id = configured_user_id.unwrap_or_else(|| "default".to_string());
    AuthUser {
        username: id.clone(),
        id,
    }
}

/// Resolve the effective single-tenant user identity.
///
/// By default, authenticated single-tenant deployments use `default`, while
/// dev-mode sessions use `dev`. Operators can override the production
/// single-tenant identity with `SANDBOXED_SINGLE_TENANT_USER_ID` (or the
/// shorter `SINGLE_TENANT_USER_ID`) to keep using a legacy mission partition.
pub fn implicit_single_tenant_user(config: &Config) -> AuthUser {
    implicit_single_tenant_user_from_id(config, configured_single_tenant_user_id())
}

pub(crate) fn constant_time_eq_bytes(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (&x, &y) in a.iter().zip(b.iter()) {
        diff |= std::hint::black_box(x ^ y);
    }
    std::hint::black_box(diff) == 0
}

pub(crate) fn constant_time_eq(a: &str, b: &str) -> bool {
    constant_time_eq_bytes(a.as_bytes(), b.as_bytes())
}

fn verify_dummy_password_for_timing(password: &str, users: &[UserAccount]) {
    let uses_pbkdf2 = users
        .iter()
        .any(|u| u.password.trim().starts_with("pbkdf2:"));
    if uses_pbkdf2 {
        let mut dummy = [0u8; PASSWORD_DIGEST_LEN];
        pbkdf2::pbkdf2_hmac::<sha2::Sha256>(
            password.as_bytes(),
            &[0xa5u8; PASSWORD_SALT_LEN],
            PASSWORD_HASH_ITERATIONS,
            &mut dummy,
        );
        let _ = constant_time_eq_bytes(&dummy, &[0x5au8; PASSWORD_DIGEST_LEN]);
    } else {
        let _ = constant_time_eq(password, "dummy_password_for_timing");
    }
}

fn verify_configured_password_value(password: &str, configured: &str) -> bool {
    let configured = configured.trim();
    if configured.is_empty() {
        return false;
    }
    if configured.starts_with("pbkdf2:") {
        verify_password_hash(password, configured)
    } else {
        constant_time_eq(password, configured)
    }
}

const PASSWORD_HASH_ITERATIONS: u32 = 600_000;
const MIN_PASSWORD_HASH_ITERATIONS: u32 = 100_000;
const MAX_PASSWORD_HASH_ITERATIONS: u32 = 2_000_000;
const PASSWORD_SALT_LEN: usize = 32;
const MIN_PASSWORD_SALT_LEN: usize = 16;
const MAX_PASSWORD_SALT_LEN: usize = 64;
const PASSWORD_DIGEST_LEN: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasswordVerifyOutcome {
    Invalid,
    ValidCurrent,
    ValidNeedsRehash,
}

struct ParsedPasswordHash {
    iterations: u32,
    salt: Vec<u8>,
    expected_hash: [u8; PASSWORD_DIGEST_LEN],
}

fn parse_password_hash(stored: &str) -> Option<ParsedPasswordHash> {
    let mut parts = stored.split(':');
    let scheme = parts.next()?;
    let iterations_str = parts.next()?;
    let salt_hex = parts.next()?;
    let hash_hex = parts.next()?;
    if parts.next().is_some() || scheme != "pbkdf2" {
        return None;
    }

    if iterations_str.is_empty() || !iterations_str.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let iterations: u32 = iterations_str.parse().ok()?;
    if !(MIN_PASSWORD_HASH_ITERATIONS..=MAX_PASSWORD_HASH_ITERATIONS).contains(&iterations) {
        return None;
    }

    if salt_hex.len() < MIN_PASSWORD_SALT_LEN * 2
        || salt_hex.len() > MAX_PASSWORD_SALT_LEN * 2
        || salt_hex.len() % 2 != 0
    {
        return None;
    }
    if hash_hex.len() != PASSWORD_DIGEST_LEN * 2 {
        return None;
    }

    let salt = hex::decode(salt_hex).ok()?;
    if !(MIN_PASSWORD_SALT_LEN..=MAX_PASSWORD_SALT_LEN).contains(&salt.len()) {
        return None;
    }

    let mut expected_hash = [0u8; PASSWORD_DIGEST_LEN];
    hex::decode_to_slice(hash_hex, &mut expected_hash).ok()?;

    Some(ParsedPasswordHash {
        iterations,
        salt,
        expected_hash,
    })
}

pub fn hash_password(password: &str) -> String {
    use rand::{rngs::OsRng, RngCore};
    use sha2::Sha256;

    let mut salt = [0u8; PASSWORD_SALT_LEN];
    OsRng.fill_bytes(&mut salt);

    let mut hash = [0u8; PASSWORD_DIGEST_LEN];
    pbkdf2::pbkdf2_hmac::<Sha256>(
        password.as_bytes(),
        &salt,
        PASSWORD_HASH_ITERATIONS,
        &mut hash,
    );

    format!(
        "pbkdf2:{}:{}:{}",
        PASSWORD_HASH_ITERATIONS,
        hex::encode(salt),
        hex::encode(hash)
    )
}

pub fn verify_password_hash_outcome(password: &str, stored: &str) -> PasswordVerifyOutcome {
    use sha2::Sha256;

    let Some(parsed) = parse_password_hash(stored) else {
        return PasswordVerifyOutcome::Invalid;
    };

    let mut computed = [0u8; PASSWORD_DIGEST_LEN];
    pbkdf2::pbkdf2_hmac::<Sha256>(
        password.as_bytes(),
        &parsed.salt,
        parsed.iterations,
        &mut computed,
    );

    if !constant_time_eq_bytes(&computed, &parsed.expected_hash) {
        return PasswordVerifyOutcome::Invalid;
    }

    if parsed.iterations < PASSWORD_HASH_ITERATIONS || parsed.salt.len() < PASSWORD_SALT_LEN {
        PasswordVerifyOutcome::ValidNeedsRehash
    } else {
        PasswordVerifyOutcome::ValidCurrent
    }
}

pub fn verify_password_hash(password: &str, stored: &str) -> bool {
    !matches!(
        verify_password_hash_outcome(password, stored),
        PasswordVerifyOutcome::Invalid
    )
}

pub async fn verify_and_upgrade_stored_password(
    settings: &crate::settings::SettingsStore,
    password: &str,
) -> Option<bool> {
    let stored_auth = settings.get_auth_settings().await?;
    let current_hash = stored_auth.password_hash?;
    let password = password.trim();
    match verify_password_hash_outcome(password, &current_hash) {
        PasswordVerifyOutcome::Invalid => Some(false),
        PasswordVerifyOutcome::ValidCurrent => Some(true),
        PasswordVerifyOutcome::ValidNeedsRehash => {
            let upgraded = hash_password(password);
            if let Err(err) = settings
                .upgrade_password_hash_if_current(&current_hash, upgraded)
                .await
            {
                tracing::warn!(error = %err, "Failed to persist upgraded password hash");
            }
            Some(true)
        }
    }
}

pub(crate) fn issue_jwt(
    secret: &str,
    ttl_days: i64,
    user: &AuthUser,
) -> anyhow::Result<(String, i64)> {
    let now = Utc::now();
    let exp = now + Duration::days(ttl_days.max(1));
    let claims = Claims {
        sub: user.id.clone(),
        usr: user.username.clone(),
        iat: now.timestamp(),
        exp: exp.timestamp(),
    };
    let token = jsonwebtoken::encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )?;
    Ok((token, claims.exp))
}

fn verify_jwt(token: &str, secret: &str) -> anyhow::Result<Claims> {
    let validation = Validation::default();
    let token_data = jsonwebtoken::decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &validation,
    )?;
    Ok(token_data.claims)
}

fn authority_host(authority: &str) -> Option<&str> {
    let authority = authority.trim();
    if authority.is_empty()
        || authority
            .chars()
            .any(|c| matches!(c, '/' | '@' | '?' | '#' | ' ' | '\t'))
    {
        return None;
    }
    if let Some(rest) = authority.strip_prefix('[') {
        let (ipv6, after) = rest.split_once(']')?;
        if !after.is_empty() {
            let port = after.strip_prefix(':')?;
            if port.is_empty() || !port.chars().all(|c| c.is_ascii_digit()) {
                return None;
            }
        }
        return Some(ipv6);
    }
    if let Some((host, port)) = authority.rsplit_once(':') {
        if !host.contains(':') {
            if port.is_empty() || !port.chars().all(|c| c.is_ascii_digit()) {
                return None;
            }
            return Some(host);
        }
    }
    Some(authority)
}

fn is_loopback_authority_host(host: &str) -> bool {
    crate::config::is_loopback_host(host) || host.eq_ignore_ascii_case("tauri.localhost")
}

fn is_loopback_origin(origin: &str) -> bool {
    let origin = origin.trim();
    if origin.is_empty() || origin.eq_ignore_ascii_case("null") {
        return false;
    }
    let Some((scheme, rest)) = origin.split_once("://") else {
        return false;
    };
    if !matches!(
        scheme.to_ascii_lowercase().as_str(),
        "http" | "https" | "ws" | "wss" | "tauri" | "asset"
    ) {
        return false;
    }
    let authority = rest.strip_suffix('/').unwrap_or(rest);
    authority_host(authority).is_some_and(is_loopback_authority_host)
}

/// Enforce loopback-only invariants whenever unauthenticated `dev_mode` is active.
///
/// Blocks non-loopback listener configs, DNS-rebinding / reverse-proxy exposure
/// via non-loopback `Host` headers, and Cross-Site WebSocket/HTTP Hijacking via
/// browser `Origin` headers.
pub(crate) fn ensure_dev_mode_loopback_request(
    headers: &axum::http::HeaderMap,
    config: &Config,
) -> Result<(), (StatusCode, &'static str)> {
    if !crate::config::is_loopback_host(&config.host) {
        return Err((
            StatusCode::FORBIDDEN,
            "Unauthenticated dev mode requires a loopback listener",
        ));
    }
    if let Some(raw_host) = headers.get(axum::http::header::HOST) {
        let Ok(host_str) = raw_host.to_str() else {
            return Err((StatusCode::FORBIDDEN, "Invalid Host header"));
        };
        if !authority_host(host_str).is_some_and(is_loopback_authority_host) {
            return Err((
                StatusCode::FORBIDDEN,
                "Unauthenticated dev mode requires a loopback Host header",
            ));
        }
    }
    if let Some(raw_origin) = headers.get(axum::http::header::ORIGIN) {
        let Ok(origin_str) = raw_origin.to_str() else {
            return Err((StatusCode::FORBIDDEN, "Invalid Origin header"));
        };
        if !is_loopback_origin(origin_str) {
            return Err((
                StatusCode::FORBIDDEN,
                "Unauthenticated dev mode rejects non-loopback Origin",
            ));
        }
    }
    Ok(())
}

/// Extract `jwt.<token>` from `Sec-WebSocket-Protocol` and authenticate a
/// subprotocol-authenticated WebSocket upgrade (`/api/console/ws`,
/// `/api/workspaces/:id/shell`, `/api/desktop/stream`, `/api/monitoring/ws`).
///
/// Returns `Ok(Some(token))` for authenticated sessions, or `Ok(None)` in
/// loopback-only `dev_mode`.
pub(crate) fn authenticate_websocket_protocols(
    headers: &axum::http::HeaderMap,
    config: &Config,
) -> Result<Option<String>, (StatusCode, &'static str)> {
    if config.auth.auth_required(config.dev_mode) {
        let raw = headers
            .get("sec-websocket-protocol")
            .and_then(|v| v.to_str().ok())
            .ok_or((StatusCode::UNAUTHORIZED, "Missing websocket JWT"))?;
        let token = raw
            .split(',')
            .map(str::trim)
            .find_map(|part| part.strip_prefix("jwt.").filter(|rest| !rest.is_empty()))
            .ok_or((StatusCode::UNAUTHORIZED, "Missing websocket JWT"))?;
        authenticate_token(config, token)
            .map_err(|_| (StatusCode::UNAUTHORIZED, "Invalid or expired token"))?;
        Ok(Some(token.to_string()))
    } else {
        ensure_dev_mode_loopback_request(headers, config)?;
        Ok(None)
    }
}

pub async fn login(
    State(state): State<std::sync::Arc<AppState>>,
    Json(req): Json<LoginRequest>,
) -> Result<Json<LoginResponse>, (StatusCode, String)> {
    let auth_mode = state.config.auth.auth_mode(state.config.dev_mode);
    let user = match auth_mode {
        AuthMode::MultiUser => {
            let username = req.username.as_deref().unwrap_or("").trim();
            if username.is_empty() {
                return Err((StatusCode::UNAUTHORIZED, "Username required".to_string()));
            }
            // Find user and verify password. Use a single generic error message
            // for both invalid username and invalid password to prevent username enumeration.
            let account = state
                .config
                .auth
                .users
                .iter()
                .find(|u| u.username.trim() == username);

            let valid = match account {
                Some(acc) => verify_configured_password_value(req.password.trim(), &acc.password),
                None => {
                    verify_dummy_password_for_timing(req.password.trim(), &state.config.auth.users);
                    false
                }
            };

            if !valid {
                return Err((
                    StatusCode::UNAUTHORIZED,
                    "Invalid username or password".to_string(),
                ));
            }

            // account is guaranteed Some here: the None branch above sets valid=false,
            // and we returned early on !valid.
            let account = account.expect("account must be Some when valid is true");
            let effective_id = effective_user_id(account);

            AuthUser {
                id: effective_id,
                username: account.username.clone(),
            }
        }
        AuthMode::SingleTenant | AuthMode::Disabled => {
            let valid =
                match verify_and_upgrade_stored_password(&state.settings, &req.password).await {
                    Some(valid) => valid,
                    None => {
                        let expected = state
                            .config
                            .auth
                            .dashboard_password
                            .as_deref()
                            .unwrap_or("");
                        verify_configured_password_value(req.password.trim(), expected)
                    }
                };

            if !valid {
                return Err((StatusCode::UNAUTHORIZED, "Invalid password".to_string()));
            }

            implicit_single_tenant_user(&state.config)
        }
    };

    let secret = state.config.auth.jwt_secret.as_deref().ok_or_else(|| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            "JWT_SECRET not configured".to_string(),
        )
    })?;

    let (token, exp) =
        issue_jwt(secret, state.config.auth.jwt_ttl_days, &user).map_err(internal_error)?;

    Ok(Json(LoginResponse { token, exp }))
}

/// Resolve an [`AuthUser`] from a bare JWT, mirroring `require_auth` exactly
/// (dev-mode bypass included). Exists for handlers that receive the token
/// outside the `Authorization` header — browser WebSocket clients cannot set
/// request headers, so they pass the JWT as a query parameter instead.
pub fn authenticate_token(
    config: &crate::config::Config,
    token: &str,
) -> Result<AuthUser, (StatusCode, &'static str)> {
    if config.dev_mode {
        if !crate::config::is_loopback_host(&config.host) {
            return Err((
                StatusCode::FORBIDDEN,
                "Unauthenticated dev mode requires a loopback listener",
            ));
        }
        return Ok(implicit_single_tenant_user(config));
    }
    let secret = config.auth.jwt_secret.as_deref().ok_or((
        StatusCode::INTERNAL_SERVER_ERROR,
        "JWT_SECRET not configured",
    ))?;
    if token.is_empty() {
        return Err((StatusCode::UNAUTHORIZED, "Missing Authorization header"));
    }
    let claims = verify_jwt(token, secret)
        .map_err(|_| (StatusCode::UNAUTHORIZED, "Invalid or expired token"))?;
    match config.auth.auth_mode(config.dev_mode) {
        AuthMode::MultiUser => user_for_claims(&claims, &config.auth.users)
            .or_else(|| github_user_for_claims(&claims, config))
            .ok_or((StatusCode::UNAUTHORIZED, "Invalid user")),
        AuthMode::SingleTenant => Ok(AuthUser {
            id: claims.sub,
            username: claims.usr,
        }),
        AuthMode::Disabled => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "Authentication not configured",
        )),
    }
}

pub async fn require_auth(
    State(state): State<std::sync::Arc<AppState>>,
    mut req: Request<Body>,
    next: Next,
) -> Response {
    let auth_header = req
        .headers()
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");

    let token = auth_header
        .strip_prefix("Bearer ")
        .or_else(|| auth_header.strip_prefix("bearer "))
        .unwrap_or("");

    if token.starts_with("mcp1.") {
        let path = req.uri().path();
        let wait_route = req.method().as_str() == "GET" && {
            let seg: Vec<&str> = path.trim_end_matches('/').split('/').collect();
            matches!(seg.as_slice(), ["", "api", "mcp", "requests", _, _, "wait"])
        };
        let allowed = wait_route
            || matches!(
                (req.method().as_str(), path),
                ("GET", "/api/mcp/capabilities")
                    | ("POST", "/api/mcp/call")
                    | ("POST", "/api/mcp/renew")
            );
        if !allowed {
            return (
                StatusCode::FORBIDDEN,
                "MCP sessions only authorize the MCP gateway",
            )
                .into_response();
        }
        let verified = if req.uri().path() == "/api/mcp/renew" {
            crate::control_mcp::gateway::verify_for_renewal(&state, token)
        } else {
            crate::control_mcp::gateway::verify(&state, token)
        };
        return match verified {
            Ok(principal) => {
                if principal.mission_id.is_none()
                    && crate::api::privilege_broker::store(&state)
                        .bunker_state()
                        .await
                        >= crate::api::privilege_broker::BunkerState::HardLockdown
                {
                    return (
                        StatusCode::FORBIDDEN,
                        "Bunker HardLockdown is active; external MCP sessions are suspended",
                    )
                        .into_response();
                }
                req.extensions_mut().insert(principal);
                next.run(req).await
            }
            Err(_) => (StatusCode::UNAUTHORIZED, "Invalid or expired MCP session").into_response(),
        };
    }
    if token.starts_with("ctx1.") {
        return if super::context_auth::permits(&state.config, token, req.uri().path(), req.method())
        {
            next.run(req).await
        } else {
            (
                StatusCode::FORBIDDEN,
                "Context grant does not authorize this operation",
            )
                .into_response()
        };
    }
    if !state.config.auth.auth_required(state.config.dev_mode) {
        if let Err((status, message)) =
            ensure_dev_mode_loopback_request(req.headers(), &state.config)
        {
            return (status, message).into_response();
        }
    }
    match authenticate_token(&state.config, token) {
        Ok(user) => {
            req.extensions_mut().insert(user);
            next.run(req).await
        }
        Err((status, message)) => (status, message).into_response(),
    }
}

/// Returns the effective user ID (id if non-empty, otherwise username).
fn effective_user_id(user: &UserAccount) -> String {
    if user.id.is_empty() {
        user.username.clone()
    } else {
        user.id.clone()
    }
}

fn user_for_claims(claims: &Claims, users: &[UserAccount]) -> Option<AuthUser> {
    users
        .iter()
        .find(|u| effective_user_id(u) == claims.sub)
        .map(|u| AuthUser {
            id: effective_user_id(u),
            username: u.username.clone(),
        })
}

fn github_user_for_claims(claims: &Claims, config: &Config) -> Option<AuthUser> {
    if !claims.sub.starts_with("github:") || claims.usr.trim().is_empty() {
        return None;
    }
    if !config.auth.github_enabled() || !config.auth.github_user_allowed(&claims.usr) {
        return None;
    }
    Some(AuthUser {
        id: claims.sub.clone(),
        username: claims.usr.clone(),
    })
}

// ─── Auth status & password change endpoints ─────────────────────────────

#[derive(Debug, serde::Serialize)]
pub struct AuthStatusResponse {
    pub auth_mode: String,
    pub password_source: String, // "dashboard", "environment", "none"
    pub password_changed_at: Option<String>,
    pub dev_mode: bool,
}

pub async fn auth_status(
    State(state): State<std::sync::Arc<AppState>>,
) -> Json<AuthStatusResponse> {
    let auth_mode = match state.config.auth.auth_mode(state.config.dev_mode) {
        AuthMode::Disabled => "disabled",
        AuthMode::SingleTenant => "single_tenant",
        AuthMode::MultiUser => "multi_user",
    };

    let stored_auth = state.settings.get_auth_settings().await;
    let has_stored_hash = stored_auth
        .as_ref()
        .and_then(|a| a.password_hash.as_ref())
        .is_some();
    let has_env_password = state.config.auth.dashboard_password.is_some();

    let password_source = if has_stored_hash {
        "dashboard"
    } else if has_env_password {
        "environment"
    } else {
        "none"
    };

    let password_changed_at = stored_auth.and_then(|a| a.password_changed_at);

    Json(AuthStatusResponse {
        auth_mode: auth_mode.to_string(),
        password_source: password_source.to_string(),
        password_changed_at,
        dev_mode: state.config.dev_mode,
    })
}

#[derive(Debug, serde::Deserialize)]
pub struct ChangePasswordRequest {
    pub current_password: Option<String>,
    pub new_password: String,
}

pub async fn change_password(
    State(state): State<std::sync::Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    Json(req): Json<ChangePasswordRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    // Multi-user mode: passwords are managed via SANDBOXED_USERS env var
    if state.config.auth.auth_mode(state.config.dev_mode) == AuthMode::MultiUser {
        return Err((
            StatusCode::BAD_REQUEST,
            "Password change is not available in multi-user mode. Manage passwords via the SANDBOXED_USERS environment variable.".to_string(),
        ));
    }

    // Determine whether a current password exists (stored hash or env var)
    let stored_auth = state.settings.get_auth_settings().await;
    let has_stored_hash = stored_auth
        .as_ref()
        .and_then(|a| a.password_hash.as_ref())
        .is_some();
    let has_env_password = state
        .config
        .auth
        .dashboard_password
        .as_ref()
        .map(|p| !p.is_empty())
        .unwrap_or(false);
    let has_existing_password = has_stored_hash || has_env_password;

    // If a password exists and auth is not disabled (dev mode), require the current password
    if has_existing_password && !state.config.dev_mode {
        let current = req.current_password.as_deref().unwrap_or("").trim();
        if current.is_empty() {
            return Err((
                StatusCode::BAD_REQUEST,
                "Current password is required".to_string(),
            ));
        }

        let current_valid = if has_stored_hash {
            let hash = stored_auth
                .as_ref()
                .expect("stored_auth must be Some when has_stored_hash is true")
                .password_hash
                .as_ref()
                .expect("password_hash must be Some when has_stored_hash is true");
            verify_password_hash(current, hash)
        } else {
            let expected = state
                .config
                .auth
                .dashboard_password
                .as_deref()
                .unwrap_or("");
            verify_configured_password_value(current, expected)
        };

        if !current_valid {
            return Err((
                StatusCode::UNAUTHORIZED,
                "Current password is incorrect".to_string(),
            ));
        }
    }

    // Validate new password
    let new_password = req.new_password.trim();
    if new_password.len() < 8 {
        return Err((
            StatusCode::BAD_REQUEST,
            "New password must be at least 8 characters".to_string(),
        ));
    }

    // Hash and persist
    let hashed = hash_password(new_password);
    let now = Utc::now().to_rfc3339();

    let auth_settings = crate::settings::AuthSettings {
        password_hash: Some(hashed),
        password_changed_at: Some(now.clone()),
    };

    state
        .settings
        .set_auth_settings(auth_settings)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to save password: {}", e),
            )
        })?;

    Ok(Json(serde_json::json!({
        "success": true,
        "password_changed_at": now
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{AuthConfig, ContextConfig};
    use std::path::PathBuf;

    fn test_config(dev_mode: bool) -> Config {
        Config {
            default_model: None,
            working_dir: PathBuf::from("/tmp"),
            host: "127.0.0.1".to_string(),
            port: 3000,
            max_iterations: 50,
            stale_mission_hours: 0,
            max_parallel_missions: 1,
            dev_mode,
            auth: AuthConfig::default(),
            context: ContextConfig::default(),
            opencode_base_url: "http://127.0.0.1:4096".to_string(),
            opencode_agent: None,
            opencode_permissive: false,
            library_path: PathBuf::from("/tmp/library"),
            default_backend: None,
            automations_enabled: true,
            paloma_webhook_forward_url: None,
            paloma_webhook_secret: None,
            max_concurrent_tasks: 5,
            spark_arbiter_url: None,
            spark_arbiter_token: None,
            spark_ssh_target: None,
            remote_nodes: crate::remote_node::RemoteNodeSettings::default(),
        }
    }

    #[test]
    fn implicit_single_tenant_user_defaults_to_default_outside_dev_mode() {
        let user = implicit_single_tenant_user_from_id(&test_config(false), None);
        assert_eq!(user.id, "default");
        assert_eq!(user.username, "default");
    }

    #[test]
    fn implicit_single_tenant_user_honors_override() {
        let user =
            implicit_single_tenant_user_from_id(&test_config(false), Some("legacy-prod".into()));
        assert_eq!(user.id, "legacy-prod");
        assert_eq!(user.username, "legacy-prod");
    }

    #[test]
    fn dev_mode_auth_blocks_non_loopback_bind_host_and_origin() {
        use axum::http::{header, HeaderMap, HeaderValue};

        let mut wildcard_cfg = test_config(true);
        wildcard_cfg.host = "0.0.0.0".to_string();
        assert_eq!(
            authenticate_token(&wildcard_cfg, "").unwrap_err().0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            authenticate_websocket_protocols(&HeaderMap::new(), &wildcard_cfg)
                .unwrap_err()
                .0,
            StatusCode::FORBIDDEN
        );

        let local_cfg = test_config(true);
        assert!(
            authenticate_websocket_protocols(&HeaderMap::new(), &local_cfg)
                .unwrap()
                .is_none()
        );

        let mut loopback_headers = HeaderMap::new();
        loopback_headers.insert(header::HOST, HeaderValue::from_static("localhost:3000"));
        loopback_headers.insert(
            header::ORIGIN,
            HeaderValue::from_static("http://localhost:3000"),
        );
        assert!(authenticate_websocket_protocols(&loopback_headers, &local_cfg).is_ok());

        let mut tauri_headers = HeaderMap::new();
        tauri_headers.insert(header::HOST, HeaderValue::from_static("127.0.0.1:3000"));
        tauri_headers.insert(
            header::ORIGIN,
            HeaderValue::from_static("tauri://localhost"),
        );
        assert!(authenticate_websocket_protocols(&tauri_headers, &local_cfg).is_ok());

        // Remote Host header (e.g. DNS rebinding or reverse proxy to public IP/domain)
        let mut remote_host_headers = HeaderMap::new();
        remote_host_headers.insert(header::HOST, HeaderValue::from_static("203.0.113.5:3000"));
        assert_eq!(
            authenticate_websocket_protocols(&remote_host_headers, &local_cfg)
                .unwrap_err()
                .0,
            StatusCode::FORBIDDEN
        );

        // Cross-site WebSocket hijacking via external or sandboxed-null Origin
        for bad_origin in [
            "https://evil.example",
            "http://192.168.1.50:3000",
            "null",
            "http://localhost@evil.example",
        ] {
            let mut cswsh_headers = HeaderMap::new();
            cswsh_headers.insert(header::HOST, HeaderValue::from_static("127.0.0.1:3000"));
            cswsh_headers.insert(header::ORIGIN, HeaderValue::from_str(bad_origin).unwrap());
            assert_eq!(
                authenticate_websocket_protocols(&cswsh_headers, &local_cfg)
                    .unwrap_err()
                    .0,
                StatusCode::FORBIDDEN,
                "expected {bad_origin} to be rejected"
            );
        }
    }

    #[test]
    fn non_dev_websocket_auth_always_requires_valid_jwt() {
        use axum::http::{HeaderMap, HeaderValue};

        // Even a misconfigured non-dev Config (AuthMode::Disabled) must fail closed.
        let unconfigured_non_dev = test_config(false);
        assert_eq!(
            authenticate_websocket_protocols(&HeaderMap::new(), &unconfigured_non_dev)
                .unwrap_err()
                .0,
            StatusCode::UNAUTHORIZED
        );

        let mut cfg = test_config(false);
        cfg.auth.dashboard_password = Some("strong-unique-passphrase".to_string());
        cfg.auth.jwt_secret = Some("real-random-jwt-secret-value-12345".to_string());

        // Missing Sec-WebSocket-Protocol -> 401 (exact PoC scenario with DEV_MODE=false)
        let mut poc_headers = HeaderMap::new();
        poc_headers.insert("sec-websocket-protocol", HeaderValue::from_static("pty"));
        assert_eq!(
            authenticate_websocket_protocols(&poc_headers, &cfg)
                .unwrap_err()
                .0,
            StatusCode::UNAUTHORIZED
        );

        // Valid JWT in subprotocol -> accepted
        let (jwt, _) = issue_jwt(
            cfg.auth.jwt_secret.as_deref().unwrap(),
            1,
            &AuthUser {
                id: "default".to_string(),
                username: "default".to_string(),
            },
        )
        .unwrap();
        let mut valid_headers = HeaderMap::new();
        valid_headers.insert(
            "sec-websocket-protocol",
            HeaderValue::from_str(&format!("sandboxed, jwt.{jwt}")).unwrap(),
        );
        assert_eq!(
            authenticate_websocket_protocols(&valid_headers, &cfg)
                .unwrap()
                .as_deref(),
            Some(jwt.as_str())
        );
    }

    fn legacy_hash_password_100k(password: &str, salt: &[u8]) -> String {
        let mut digest = [0u8; 32];
        pbkdf2::pbkdf2_hmac::<sha2::Sha256>(password.as_bytes(), salt, 100_000, &mut digest);
        format!(
            "pbkdf2:100000:{}:{}",
            hex::encode(salt),
            hex::encode(digest)
        )
    }

    #[test]
    fn hash_password_uses_600k_iterations_32_byte_salt_and_verifies() {
        let password = "correct-horse-battery-staple";
        let h1 = hash_password(password);
        let h2 = hash_password(password);
        assert_ne!(h1, h2);

        let parts: Vec<&str> = h1.split(':').collect();
        assert_eq!(parts.len(), 4);
        assert_eq!(parts[0], "pbkdf2");
        assert_eq!(parts[1], "600000");
        assert_eq!(hex::decode(parts[2]).unwrap().len(), 32);
        assert_eq!(hex::decode(parts[3]).unwrap().len(), 32);

        assert!(verify_password_hash(password, &h1));
        assert_eq!(
            verify_password_hash_outcome(password, &h1),
            PasswordVerifyOutcome::ValidCurrent
        );
        assert!(!verify_password_hash("wrong-horse-battery-staple", &h1));
        assert_eq!(
            verify_password_hash_outcome("wrong-horse-battery-staple", &h1),
            PasswordVerifyOutcome::Invalid
        );
    }

    #[test]
    fn legacy_100k_hash_verifies_and_flags_rehash() {
        let password = "legacy-stored-password";
        let legacy = legacy_hash_password_100k(password, &[0x42; 16]);

        assert!(verify_password_hash(password, &legacy));
        assert_eq!(
            verify_password_hash_outcome(password, &legacy),
            PasswordVerifyOutcome::ValidNeedsRehash
        );
        assert!(!verify_password_hash("incorrect-password", &legacy));
        assert_eq!(
            verify_password_hash_outcome("incorrect-password", &legacy),
            PasswordVerifyOutcome::Invalid
        );

        let short_salt_600k = {
            let salt = [0x11u8; 16];
            let mut digest = [0u8; 32];
            pbkdf2::pbkdf2_hmac::<sha2::Sha256>(
                password.as_bytes(),
                &salt,
                PASSWORD_HASH_ITERATIONS,
                &mut digest,
            );
            format!(
                "pbkdf2:{}:{}:{}",
                PASSWORD_HASH_ITERATIONS,
                hex::encode(salt),
                hex::encode(digest)
            )
        };
        assert_eq!(
            verify_password_hash_outcome(password, &short_salt_600k),
            PasswordVerifyOutcome::ValidNeedsRehash
        );
    }

    #[test]
    fn verify_password_hash_rejects_malformed_and_unreasonable_parameters() {
        let password = "test-password-123";
        let valid_salt_hex = hex::encode([0xabu8; 32]);
        let valid_digest_hex = {
            let mut digest = [0u8; 32];
            pbkdf2::pbkdf2_hmac::<sha2::Sha256>(
                password.as_bytes(),
                &[0xabu8; 32],
                100_000,
                &mut digest,
            );
            hex::encode(digest)
        };

        let cases = [
            "".to_string(),
            "plaintext".to_string(),
            format!("argon2:600000:{valid_salt_hex}:{valid_digest_hex}"),
            format!("pbkdf2:600000:{valid_salt_hex}"),
            format!("pbkdf2:600000:{valid_salt_hex}:{valid_digest_hex}:extra"),
            format!("pbkdf2:0:{valid_salt_hex}:{valid_digest_hex}"),
            format!("pbkdf2:1:{valid_salt_hex}:{valid_digest_hex}"),
            format!("pbkdf2:99999:{valid_salt_hex}:{valid_digest_hex}"),
            format!("pbkdf2:2000001:{valid_salt_hex}:{valid_digest_hex}"),
            format!("pbkdf2:4294967295:{valid_salt_hex}:{valid_digest_hex}"),
            format!("pbkdf2:99999999999999999999:{valid_salt_hex}:{valid_digest_hex}"),
            format!("pbkdf2:+600000:{valid_salt_hex}:{valid_digest_hex}"),
            format!("pbkdf2:-100000:{valid_salt_hex}:{valid_digest_hex}"),
            format!("pbkdf2:notanumber:{valid_salt_hex}:{valid_digest_hex}"),
            format!("pbkdf2:600000::{valid_digest_hex}"),
            format!(
                "pbkdf2:600000:{}:{valid_digest_hex}",
                hex::encode([0xabu8; 15])
            ),
            format!(
                "pbkdf2:600000:{}:{valid_digest_hex}",
                hex::encode([0xabu8; 65])
            ),
            format!("pbkdf2:600000:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz:{valid_digest_hex}"),
            format!("pbkdf2:600000:{valid_salt_hex}:"),
            format!("pbkdf2:600000:{valid_salt_hex}:{}", hex::encode([0xcd; 31])),
            format!("pbkdf2:600000:{valid_salt_hex}:{}", hex::encode([0xcd; 33])),
            format!("pbkdf2:600000:{valid_salt_hex}:{}", "g".repeat(64)),
        ];

        for malformed in cases {
            assert!(
                !verify_password_hash(password, &malformed),
                "expected malformed hash to be rejected"
            );
            assert_eq!(
                verify_password_hash_outcome(password, &malformed),
                PasswordVerifyOutcome::Invalid
            );
        }
    }

    #[tokio::test]
    async fn transparent_rehash_upgrades_legacy_store_and_preserves_concurrent_changes() {
        let dir = tempfile::tempdir().unwrap();
        let store = crate::settings::SettingsStore::new(dir.path()).await;

        assert_eq!(
            verify_and_upgrade_stored_password(&store, "any-password").await,
            None
        );

        let password = "upgrade-me-on-login";
        let legacy = legacy_hash_password_100k(password, &[0x77; 16]);
        let original_changed_at = "2026-01-01T00:00:00Z".to_string();
        store
            .set_auth_settings(crate::settings::AuthSettings {
                password_hash: Some(legacy.clone()),
                password_changed_at: Some(original_changed_at.clone()),
            })
            .await
            .unwrap();

        assert_eq!(
            verify_and_upgrade_stored_password(&store, "wrong-password").await,
            Some(false)
        );
        assert_eq!(
            store
                .get_auth_settings()
                .await
                .unwrap()
                .password_hash
                .as_deref(),
            Some(legacy.as_str())
        );

        assert_eq!(
            verify_and_upgrade_stored_password(&store, "  upgrade-me-on-login  ").await,
            Some(true)
        );
        let upgraded_auth = store.get_auth_settings().await.unwrap();
        assert_eq!(
            upgraded_auth.password_changed_at.as_deref(),
            Some(original_changed_at.as_str())
        );
        let upgraded_hash = upgraded_auth.password_hash.unwrap();
        assert_ne!(upgraded_hash, legacy);
        assert!(upgraded_hash.starts_with("pbkdf2:600000:"));
        assert_eq!(
            verify_password_hash_outcome(password, &upgraded_hash),
            PasswordVerifyOutcome::ValidCurrent
        );

        let reloaded = crate::settings::SettingsStore::new(dir.path()).await;
        assert_eq!(
            reloaded
                .get_auth_settings()
                .await
                .unwrap()
                .password_hash
                .as_deref(),
            Some(upgraded_hash.as_str())
        );

        let newer_password = "concurrently-rotated-password";
        let newer_hash = hash_password(newer_password);
        store
            .set_auth_settings(crate::settings::AuthSettings {
                password_hash: Some(newer_hash.clone()),
                password_changed_at: Some("2026-02-01T00:00:00Z".to_string()),
            })
            .await
            .unwrap();
        assert!(!store
            .upgrade_password_hash_if_current(&legacy, hash_password(password))
            .await
            .unwrap());
        assert_eq!(
            store
                .get_auth_settings()
                .await
                .unwrap()
                .password_hash
                .as_deref(),
            Some(newer_hash.as_str())
        );
    }

    #[test]
    fn configured_password_value_supports_plaintext_and_pbkdf2_without_mutation() {
        let password = "env-configured-password";
        assert!(verify_configured_password_value(password, password));
        assert!(!verify_configured_password_value("wrong", password));
        assert!(!verify_configured_password_value("", ""));

        let hashed = hash_password(password);
        assert!(verify_configured_password_value(password, &hashed));
        assert!(!verify_configured_password_value("wrong", &hashed));
        assert!(!verify_configured_password_value(
            "pbkdf2:0:aa:bb",
            "pbkdf2:0:aa:bb"
        ));
    }
}
