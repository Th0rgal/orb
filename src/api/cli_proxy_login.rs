//! Browser/device login mediated by CLIProxyAPI's management API. The UI never
//! receives the management key or OAuth tokens; only CLIProxyAPI exchanges and
//! renews the login. Existing account UUIDs remain stable across reconnects.
use crate::ai_providers::ProviderType;
use axum::{
    extract::{Path as AxumPath, State},
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

type ApiError = (StatusCode, String);
const SESSION_TTL: Duration = Duration::from_secs(15 * 60);

#[derive(Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
enum LoginStatus {
    Pending,
    Completing,
    Completed,
    Failed,
}

struct LoginSession {
    provider: ProviderType,
    target: Option<uuid::Uuid>,
    previous_accounts: HashMap<String, String>,
    state: String,
    auth_url: String,
    status: LoginStatus,
    message: Option<String>,
    created: Instant,
}

type Session = Arc<Mutex<LoginSession>>;
fn sessions() -> &'static Mutex<HashMap<String, Session>> {
    static SESSIONS: OnceLock<Mutex<HashMap<String, Session>>> = OnceLock::new();
    SESSIONS.get_or_init(Default::default)
}

pub(crate) struct ManagementClient {
    base: String,
    key: String,
    http: reqwest::Client,
}
impl ManagementClient {
    pub(crate) fn configured() -> Result<Self, ApiError> {
        let key = super::oauth_owner::management_key().ok_or((
            StatusCode::SERVICE_UNAVAILABLE,
            "Subscription login needs CLIProxyAPI management access configured on the backend."
                .into(),
        ))?;
        let base = super::oauth_owner::cli_proxy_endpoint()
            .ok_or((
                StatusCode::SERVICE_UNAVAILABLE,
                "CLIProxyAPI is disabled.".into(),
            ))?
            .base_url;
        let base = base.trim_end_matches('/').trim_end_matches("/v1");
        let url = url::Url::parse(base).map_err(|_| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                "Invalid CLIProxyAPI endpoint configuration.".into(),
            )
        })?;
        if !matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "::1")) {
            return Err((
                StatusCode::SERVICE_UNAVAILABLE,
                "CLIProxyAPI management must use a loopback endpoint.".into(),
            ));
        }
        Ok(Self {
            base: format!("{base}/v0/management"),
            key,
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(20))
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .map_err(|_| {
                    (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "Could not initialize login client.".into(),
                    )
                })?,
        })
    }
    pub(crate) async fn request(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, ApiError> {
        let mut request = self
            .http
            .request(method, format!("{}{path}", self.base))
            .bearer_auth(&self.key);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                "Could not reach CLIProxyAPI. Try again shortly.".into(),
            )
        })?;
        if !response.status().is_success() {
            // Do not relay provider bodies or headers: they can contain OAuth codes/tokens.
            return Err((StatusCode::BAD_GATEWAY, format!("CLIProxyAPI login request failed (HTTP {}). Check its management configuration.", response.status())));
        }
        response.json().await.map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                "CLIProxyAPI returned an invalid login response.".into(),
            )
        })
    }
    async fn status(&self, state: &str) -> Result<Value, ApiError> {
        let query: String = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("state", state)
            .finish();
        self.request(
            reqwest::Method::GET,
            &format!("/get-auth-status?{query}"),
            None,
        )
        .await
    }
    async fn cancel(&self, state: &str) -> Result<(), ApiError> {
        let query: String = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("state", state)
            .finish();
        self.request(
            reqwest::Method::DELETE,
            &format!("/oauth-session?{query}"),
            None,
        )
        .await?;
        Ok(())
    }
}

fn provider_for(name: &str) -> Option<ProviderType> {
    match name {
        "anthropic" | "claude" => Some(ProviderType::Anthropic),
        "openai" | "codex" => Some(ProviderType::OpenAI),
        "xai" | "grok" => Some(ProviderType::Xai),
        "kimi" => Some(ProviderType::Kimi),
        "antigravity" => Some(ProviderType::Antigravity),
        _ => None,
    }
}
fn login_path(provider: ProviderType) -> &'static str {
    match provider {
        ProviderType::Anthropic => "/anthropic-auth-url",
        ProviderType::OpenAI => "/codex-auth-url",
        ProviderType::Xai => "/xai-auth-url",
        ProviderType::Kimi => "/kimi-auth-url",
        ProviderType::Antigravity => "/antigravity-auth-url",
        _ => unreachable!(),
    }
}
fn flow_for(provider: ProviderType, auth_url: &str) -> &'static str {
    if matches!(provider, ProviderType::Kimi | ProviderType::Xai) {
        return "device";
    }
    let redirect = url::Url::parse(auth_url).ok().and_then(|u| {
        u.query_pairs()
            .find(|(k, _)| k == "redirect_uri")
            .map(|(_, v)| v.into_owned())
    });
    if redirect
        .and_then(|v| url::Url::parse(&v).ok())
        .is_some_and(|u| matches!(u.host_str(), Some("localhost" | "127.0.0.1")))
    {
        "redirect"
    } else {
        "code"
    }
}

#[derive(serde::Deserialize)]
struct StartRequest {
    provider: String,
    #[serde(default)]
    provider_id: Option<uuid::Uuid>,
}
#[derive(serde::Serialize)]
struct StartResponse {
    session_id: String,
    auth_url: String,
    flow: &'static str,
    instructions: String,
}
#[derive(serde::Serialize)]
struct StatusResponse {
    status: LoginStatus,
    auth_url: String,
    message: Option<String>,
}
#[derive(serde::Deserialize)]
struct CallbackRequest {
    url: String,
}

async fn start_login(
    State(state): State<Arc<super::routes::AppState>>,
    Json(req): Json<StartRequest>,
) -> Result<Json<StartResponse>, ApiError> {
    let provider = provider_for(req.provider.trim()).ok_or((
        StatusCode::BAD_REQUEST,
        "This subscription is not supported by CLIProxyAPI.".into(),
    ))?;
    if let Some(id) = req.provider_id {
        let account = state
            .ai_providers
            .get(id)
            .await
            .ok_or((StatusCode::NOT_FOUND, "Account no longer exists.".into()))?;
        if account.provider_type != provider {
            return Err((
                StatusCode::BAD_REQUEST,
                "Reconnect provider does not match the selected account.".into(),
            ));
        }
    }
    if !super::oauth_owner::management_enabled() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "CLIProxyAPI subscription ownership is not enabled.".into(),
        ));
    }
    let previous_accounts = super::cli_proxy_accounts::auth_dir()
        .map(|dir| {
            super::cli_proxy_accounts::accounts_in(&dir)
                .into_iter()
                .filter(|a| a.provider == provider)
                .map(|a| (a.file, a.oauth.access_token))
                .collect()
        })
        .unwrap_or_default();
    let client = ManagementClient::configured()?;
    let response = client
        .request(reqwest::Method::GET, login_path(provider), None)
        .await?;
    let auth_url = response
        .get("url")
        .and_then(Value::as_str)
        .filter(|u| u.starts_with("https://"))
        .ok_or((
            StatusCode::BAD_GATEWAY,
            "CLIProxyAPI did not return an authorization page.".into(),
        ))?
        .to_string();
    let oauth_state = response
        .get("state")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or((
            StatusCode::BAD_GATEWAY,
            "CLIProxyAPI did not return a login session.".into(),
        ))?
        .to_string();
    let flow = flow_for(provider, &auth_url);
    let instructions = match flow {
        "device" => match response.get("user_code").and_then(Value::as_str) {
            Some(code) => format!("Approve code {code} in your browser. This page checks for completion automatically."),
            None => "Approve the sign-in in your browser. This page checks for completion automatically.".into(),
        },
        "redirect" => "After signing in, paste the final localhost redirect URL here if the browser cannot return to Orb.".into(),
        _ => "After signing in, paste the authorization code or final redirect URL here.".into(),
    };
    let id = uuid::Uuid::new_v4().to_string();
    sessions().lock().await.insert(
        id.clone(),
        Arc::new(Mutex::new(LoginSession {
            provider,
            target: req.provider_id,
            previous_accounts,
            state: oauth_state,
            auth_url: auth_url.clone(),
            status: LoginStatus::Pending,
            message: None,
            created: Instant::now(),
        })),
    );
    let expired_id = id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(SESSION_TTL).await;
        if let Some(session) = sessions().lock().await.remove(&expired_id) {
            let session = session.lock().await;
            if matches!(
                session.status,
                LoginStatus::Pending | LoginStatus::Completing
            ) {
                if let Ok(client) = ManagementClient::configured() {
                    let _ = client.cancel(&session.state).await;
                }
            }
        }
    });
    Ok(Json(StartResponse {
        session_id: id,
        auth_url,
        flow,
        instructions,
    }))
}

async fn session_for(id: &str) -> Result<Session, ApiError> {
    sessions().lock().await.get(id).cloned().ok_or((
        StatusCode::NOT_FOUND,
        "Login session expired. Start sign-in again.".into(),
    ))
}
fn response(s: &LoginSession) -> Json<StatusResponse> {
    Json(StatusResponse {
        status: s.status,
        auth_url: s.auth_url.clone(),
        message: s.message.clone(),
    })
}
fn select_login_account(
    accounts: Vec<super::cli_proxy_accounts::ProxyAccount>,
    provider: ProviderType,
    previous: &HashMap<String, String>,
) -> Option<super::cli_proxy_accounts::ProxyAccount> {
    let changed: Vec<_> = accounts
        .into_iter()
        .filter(|a| {
            a.provider == provider
                && !a.disabled
                && a.oauth.expires_at > chrono::Utc::now().timestamp_millis()
                && previous.get(&a.file) != Some(&a.oauth.access_token)
        })
        .collect();
    let new: Vec<_> = changed
        .iter()
        .filter(|a| !previous.contains_key(&a.file))
        .collect();
    match new.as_slice() {
        [account] => Some((*account).clone()),
        [] if changed.len() == 1 => changed.into_iter().next(),
        _ => None,
    }
}

fn identity_matches(
    p: &crate::ai_providers::AIProvider,
    a: &super::cli_proxy_accounts::ProxyAccount,
) -> bool {
    p.account_email
        .as_deref()
        .filter(|email| Some(*email) != p.cli_proxy_auth_file.as_deref())
        .is_none_or(|email| a.identity != a.file && email.eq_ignore_ascii_case(&a.identity))
}

async fn login_status(
    State(state): State<Arc<super::routes::AppState>>,
    AxumPath(id): AxumPath<String>,
) -> Result<Json<StatusResponse>, ApiError> {
    let session = session_for(&id).await?;
    let mut s = session.lock().await;
    if matches!(s.status, LoginStatus::Completed | LoginStatus::Failed) {
        return Ok(response(&s));
    }
    if s.created.elapsed() >= SESSION_TTL {
        s.status = LoginStatus::Failed;
        s.message = Some("Login session expired. Try again.".into());
        return Ok(response(&s));
    }
    let result = ManagementClient::configured()?.status(&s.state).await?;
    match result.get("status").and_then(Value::as_str) {
        Some("ok") => {
            let accounts = super::cli_proxy_accounts::auth_dir()
                .map(|dir| super::cli_proxy_accounts::accounts_in(&dir))
                .unwrap_or_default();
            let Some(account) = select_login_account(accounts, s.provider, &s.previous_accounts)
            else {
                s.status = LoginStatus::Failed;
                s.message = Some(
                    "Could not identify the completed login safely. Try reconnecting again.".into(),
                );
                return Ok(response(&s));
            };
            let rows = state.ai_providers.list().await;
            let target = if let Some(id) = s.target {
                Some(
                    rows.iter()
                        .find(|p| p.id == id)
                        .ok_or((StatusCode::NOT_FOUND, "Account no longer exists.".into()))?,
                )
            } else {
                rows.iter().find(|p| {
                    p.provider_type == s.provider
                        && account.identity != account.file
                        && p.account_email
                            .as_deref()
                            .is_some_and(|email| email.eq_ignore_ascii_case(&account.identity))
                })
            };
            if let Some(p) = target {
                if !identity_matches(p, &account) {
                    s.status = LoginStatus::Failed;
                    s.message = Some(format!(
                        "Sign-in succeeded for another account. Reconnect using {}.",
                        p.account_email.as_deref().unwrap_or(&p.name)
                    ));
                    return Ok(response(&s));
                }
            }
            if s.provider == ProviderType::Antigravity {
                // Reserve an explicit route so Claude models cannot silently use
                // a Claude subscription when Antigravity was selected.
                ManagementClient::configured()?
                    .request(
                        reqwest::Method::PATCH,
                        "/auth-files/fields",
                        Some(json!({"name":account.file,"prefix":"antigravity"})),
                    )
                    .await?;
            }
            if let Some(p) = target {
                if p.cli_proxy_auth_file
                    .as_deref()
                    .is_some_and(|file| file != account.file)
                {
                    super::cli_proxy_accounts::set_enabled(p, false).await?;
                }
            }
            let id = super::cli_proxy_accounts::bind_login(
                &state.ai_providers,
                target.map(|p| p.id),
                account,
            )
            .await
            .ok_or((StatusCode::NOT_FOUND, "Account no longer exists.".into()))?;
            if let Some(p) = state.ai_providers.get(id).await {
                super::cli_proxy_accounts::set_enabled(&p, p.enabled).await?;
            }
            super::cli_proxy_accounts::reconcile(&state.ai_providers).await;
            if s.provider == ProviderType::Antigravity {
                let state = Arc::clone(&state);
                tokio::spawn(async move {
                    let _ = super::providers::refresh_model_catalog(State(state)).await;
                });
            }
            s.status = LoginStatus::Completed;
            s.message = Some("Connected. The subscription login will renew automatically.".into());
        }
        Some("error") => {
            s.status = LoginStatus::Failed;
            s.message = Some("Authorization failed or expired. Start sign-in again.".into());
        }
        Some("wait") => {}
        _ => {
            return Err((
                StatusCode::BAD_GATEWAY,
                "Unexpected login status from CLIProxyAPI.".into(),
            ))
        }
    }
    Ok(response(&s))
}

fn callback_payload(
    provider: ProviderType,
    input: &str,
    expected_state: &str,
) -> Result<Value, ApiError> {
    let bad = || {
        (
            StatusCode::BAD_REQUEST,
            "Paste the authorization code or callback URL from this sign-in attempt.".into(),
        )
    };
    let input = input.trim();
    let (code, got_state) = if input.starts_with("http://") || input.starts_with("https://") {
        let u = url::Url::parse(input).map_err(|_| bad())?;
        // Parse only. Never fetch a user-supplied URL or forward its path.
        if !matches!(
            u.host_str(),
            Some("localhost" | "127.0.0.1" | "claude.ai" | "console.anthropic.com")
        ) {
            return Err(bad());
        }
        let code = u
            .query_pairs()
            .find(|(k, _)| k == "code")
            .map(|(_, v)| v.into_owned())
            .ok_or_else(bad)?;
        let state = u
            .query_pairs()
            .find(|(k, _)| k == "state")
            .map(|(_, v)| v.into_owned());
        (code, state)
    } else if provider == ProviderType::Anthropic {
        let (code, state) = input
            .split_once('#')
            .map(|(c, s)| (c.to_string(), Some(s.to_string())))
            .unwrap_or((input.to_string(), None));
        (code, state)
    } else {
        return Err(bad());
    };
    if code.is_empty() || got_state.as_deref().is_some_and(|s| s != expected_state) {
        return Err(bad());
    }
    if provider != ProviderType::Anthropic && got_state.as_deref() != Some(expected_state) {
        return Err(bad());
    }
    Ok(json!({"provider": provider.id(), "code":code, "state":expected_state}))
}

async fn login_callback(
    AxumPath(id): AxumPath<String>,
    Json(req): Json<CallbackRequest>,
) -> Result<Json<StatusResponse>, ApiError> {
    let session = session_for(&id).await?;
    let mut s = session.lock().await;
    if !matches!(s.status, LoginStatus::Pending | LoginStatus::Completing) {
        return Err((
            StatusCode::CONFLICT,
            "This login session has already finished.".into(),
        ));
    }
    if matches!(s.provider, ProviderType::Kimi | ProviderType::Xai) {
        return Err((
            StatusCode::BAD_REQUEST,
            "Complete sign-in in your browser; no callback is needed.".into(),
        ));
    }
    let payload = callback_payload(s.provider, &req.url, &s.state)?;
    ManagementClient::configured()?
        .request(reqwest::Method::POST, "/oauth-callback", Some(payload))
        .await?;
    s.status = LoginStatus::Completing;
    s.message = Some("Authorization accepted. Finishing sign-in…".into());
    Ok(response(&s))
}

async fn cancel_login(AxumPath(id): AxumPath<String>) -> Result<Json<Value>, ApiError> {
    let session = session_for(&id).await?;
    let mut s = session.lock().await;
    if matches!(s.status, LoginStatus::Pending | LoginStatus::Completing) {
        ManagementClient::configured()?.cancel(&s.state).await?;
        s.status = LoginStatus::Failed;
        s.message = Some("Sign-in cancelled.".into());
    }
    Ok(Json(json!({"status":"ok"})))
}

async fn login_capabilities() -> Json<Value> {
    let available =
        super::oauth_owner::management_enabled() && ManagementClient::configured().is_ok();
    let mut providers = vec![json!({"id":"mistral", "name":"Mistral Vibe"})];
    if available {
        providers.extend([
            json!({"id":"anthropic", "name":"Claude Pro/Max"}),
            json!({"id":"openai", "name":"ChatGPT Plus/Pro"}),
            json!({"id":"xai", "name":"SuperGrok"}),
            json!({"id":"kimi", "name":"Kimi Code"}),
            json!({"id":"antigravity", "name":"Google Antigravity"}),
        ]);
    }
    Json(json!({"available": true, "providers": providers}))
}

pub fn routes() -> Router<Arc<super::routes::AppState>> {
    Router::new()
        .route(
            "/cli-proxy-login",
            get(login_capabilities).post(start_login),
        )
        .route(
            "/cli-proxy-login/:id",
            get(login_status).delete(cancel_login),
        )
        .route("/cli-proxy-login/:id/callback", post(login_callback))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn antigravity_login_is_distinct_from_google_native_login() {
        assert_eq!(provider_for("antigravity"), Some(ProviderType::Antigravity));
        assert_eq!(provider_for("google"), None);
        assert_eq!(
            login_path(ProviderType::Antigravity),
            "/antigravity-auth-url"
        );
        assert_eq!(flow_for(ProviderType::Antigravity, "https://accounts.google.com/auth?redirect_uri=http%3A%2F%2Flocalhost%3A51121%2Fcallback"), "redirect");
    }

    #[test]
    fn completed_login_prefers_new_file_and_rejects_ambiguity_or_wrong_identity() {
        let account = |file: &str, token: &str| {
            super::super::cli_proxy_accounts::parse_account(file, &json!({"type":"kimi","access_token":token,"refresh_token":"r","expired":"2099-01-01T00:00:00Z"})).unwrap()
        };
        let previous = HashMap::from([("old.json".into(), "old-token".into())]);
        let chosen = select_login_account(
            vec![account("old.json", "renewed"), account("new.json", "fresh")],
            ProviderType::Kimi,
            &previous,
        )
        .unwrap();
        assert_eq!(chosen.file, "new.json");
        assert!(select_login_account(
            vec![
                account("new.json", "fresh"),
                account("other.json", "fresh2")
            ],
            ProviderType::Kimi,
            &previous
        )
        .is_none());
        assert!(select_login_account(
            vec![account("old.json", "old-token")],
            ProviderType::Kimi,
            &previous
        )
        .is_none());
        let mut row = crate::ai_providers::AIProvider::new(ProviderType::Kimi, "Kimi".into());
        row.cli_proxy_auth_file = Some("old.json".into());
        row.account_email = Some("old.json".into());
        assert!(identity_matches(&row, &chosen));
        row.account_email = Some("user@example.com".into());
        assert!(!identity_matches(&row, &chosen));
    }

    #[test]
    fn callbacks_bind_state_without_fetching_arbitrary_urls() {
        let p = callback_payload(ProviderType::Anthropic, "code#our-state", "our-state").unwrap();
        assert_eq!(p["code"], "code");
        assert!(
            callback_payload(ProviderType::Anthropic, "code#other-state", "our-state").is_err()
        );
        assert!(callback_payload(
            ProviderType::OpenAI,
            "http://localhost:1455/auth/callback?code=a&state=other",
            "ours"
        )
        .is_err());
        assert!(callback_payload(
            ProviderType::OpenAI,
            "http://localhost:1455/auth/callback?code=a",
            "ours"
        )
        .is_err());
        assert!(callback_payload(
            ProviderType::OpenAI,
            "http://internal.service/?code=a&state=ours",
            "ours"
        )
        .is_err());
        assert!(callback_payload(
            ProviderType::OpenAI,
            "http://localhost:1455/auth/callback?code=a&state=ours",
            "ours"
        )
        .is_ok());
    }
    #[test]
    fn distinguishes_authorization_codes_from_device_flows() {
        assert_eq!(flow_for(ProviderType::Anthropic,"https://claude.ai/oauth/authorize?redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode"),"code");
        assert_eq!(flow_for(ProviderType::OpenAI,"https://auth.openai.com/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"),"redirect");
        assert_eq!(
            flow_for(ProviderType::Xai, "https://grok.com/device"),
            "device"
        );
    }
    #[tokio::test]
    async fn management_requests_keep_credentials_server_side() {
        use axum::{extract::Query, http::HeaderMap, routing::delete};
        let app = Router::new().route(
            "/get-auth-status",
            get(|headers: HeaderMap| async move {
                assert_eq!(headers["authorization"], "Bearer management-test-key");
                Json(json!({"status":"wait"}))
            }),
        );
        let app = app.route(
            "/oauth-session",
            delete(
                |headers: HeaderMap, Query(query): Query<HashMap<String, String>>| async move {
                    assert_eq!(headers["authorization"], "Bearer management-test-key");
                    assert_eq!(query["state"], "test-state");
                    Json(json!({"status":"ok","cancelled":true}))
                },
            ),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = ManagementClient {
            base: format!("http://{address}"),
            key: "management-test-key".into(),
            http: reqwest::Client::new(),
        };
        assert_eq!(client.status("test-state").await.unwrap()["status"], "wait");
        client.cancel("test-state").await.unwrap();
        server.abort();
    }
    #[tokio::test]
    async fn management_errors_hide_tokens_and_redirects_do_not_replay_credentials() {
        use axum::response::Redirect;
        let app = Router::new()
            .route(
                "/error",
                get(|| async { (StatusCode::BAD_REQUEST, "access_token=never-expose") }),
            )
            .route("/redirect", get(|| async { Redirect::temporary("/leak") }))
            .route(
                "/leak",
                get(|| async {
                    panic!("Management redirect must never be followed");
                    #[allow(unreachable_code)]
                    Json(json!({}))
                }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = ManagementClient {
            base: format!("http://{address}"),
            key: "server-secret".into(),
            http: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .unwrap(),
        };
        let error = client
            .request(reqwest::Method::GET, "/error", None)
            .await
            .unwrap_err();
        assert!(!error.1.contains("never-expose"));
        assert!(client
            .request(reqwest::Method::GET, "/redirect", None)
            .await
            .is_err());
        server.abort();
    }

    #[test]
    fn merged_router_builds() {
        let _ = crate::api::ai_providers::routes();
    }
}
