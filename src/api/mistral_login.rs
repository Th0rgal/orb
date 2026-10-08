//! Mistral's Vibe browser sign-in protocol (PKCE), also used by the official
//! Vibe CLI. Provisioned keys stay in the backend's provider store, never the UI.
use crate::ai_providers::{AIProvider, ProviderType};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::RngCore;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::{Arc, OnceLock},
    time::Duration,
};
use tokio::sync::Mutex;

const API: &str = "https://console.mistral.ai/api";
type Error = (StatusCode, String);
type App = Arc<super::routes::AppState>;
struct Session {
    process: String,
    poll_url: String,
    verifier: String,
    expires: chrono::DateTime<chrono::Utc>,
    target: Option<uuid::Uuid>,
    status: &'static str,
    message: Option<&'static str>,
}
fn sessions() -> &'static Mutex<HashMap<String, Arc<Mutex<Session>>>> {
    static SESSIONS: OnceLock<Mutex<HashMap<String, Arc<Mutex<Session>>>>> = OnceLock::new();
    SESSIONS.get_or_init(Default::default)
}
fn failure(message: &str) -> Error {
    (StatusCode::BAD_GATEWAY, message.into())
}
fn client() -> Result<reqwest::Client, Error> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| failure("Could not initialize Mistral sign-in."))
}
async fn payload(response: reqwest::Response) -> Result<Value, Error> {
    if !response.status().is_success() {
        return Err(failure("Mistral sign-in request failed. Try again."));
    }
    response
        .json()
        .await
        .map_err(|_| failure("Invalid Mistral sign-in response."))
}
fn field<'a>(value: &'a Value, name: &str) -> Result<&'a str, Error> {
    value
        .get(name)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| failure("Incomplete Mistral sign-in response."))
}
fn allowed_url(value: &str, poll: bool) -> bool {
    let Ok(url) = url::Url::parse(value) else {
        return false;
    };
    url.scheme() == "https"
        && url.host_str() == Some("console.mistral.ai")
        && url.port_or_known_default() == Some(443)
        && url.username().is_empty()
        && url.password().is_none()
        && url.fragment().is_none()
        && (!poll || url.path().starts_with("/api/vibe/sign-in/"))
}
fn pkce() -> (String, String) {
    let mut bytes = [0u8; 64];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    let verifier = URL_SAFE_NO_PAD.encode(bytes);
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    (verifier, challenge)
}
#[derive(serde::Deserialize)]
struct Start {
    provider: String,
    provider_id: Option<uuid::Uuid>,
}
async fn start(State(state): State<App>, Json(request): Json<Start>) -> Result<Json<Value>, Error> {
    if request.provider != "mistral" {
        return Err((StatusCode::BAD_REQUEST, "Expected Mistral.".into()));
    }
    if let Some(id) = request.provider_id {
        let account = state
            .ai_providers
            .get(id)
            .await
            .ok_or((StatusCode::NOT_FOUND, "Account no longer exists.".into()))?;
        if account.provider_type != ProviderType::Mistral || !account.mistral_subscription {
            return Err((
                StatusCode::BAD_REQUEST,
                "Select a Mistral subscription account to reconnect.".into(),
            ));
        }
    }
    let (verifier, challenge) = pkce();
    let value = payload(
        client()?
            .post(format!("{API}/vibe/sign-in"))
            .json(&json!({"code_challenge":challenge,"code_challenge_method":"S256"}))
            .send()
            .await
            .map_err(|_| failure("Could not reach Mistral sign-in."))?,
    )
    .await?;
    let process = field(&value, "process_id")?.to_owned();
    if !process
        .bytes()
        .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err(failure("Invalid Mistral process identifier."));
    }
    let auth_url = field(&value, "sign_in_url")?.to_owned();
    let poll_url = field(&value, "poll_url")?.to_owned();
    if !allowed_url(&auth_url, false) || !allowed_url(&poll_url, true) {
        return Err(failure(
            "Mistral returned an unexpected sign-in destination.",
        ));
    }
    let expires = chrono::DateTime::parse_from_rfc3339(field(&value, "expires_at")?)
        .map_err(|_| failure("Invalid Mistral expiry."))?
        .with_timezone(&chrono::Utc);
    let expires = expires.min(chrono::Utc::now() + chrono::Duration::minutes(15));
    let id = format!("mistral-{}", uuid::Uuid::new_v4());
    let mut all = sessions().lock().await;
    // Keep abandoned browser attempts bounded without retaining their PKCE secrets.
    all.retain(|_, s| {
        s.try_lock()
            .map_or(true, |s| s.expires > chrono::Utc::now())
    });
    if all.len() >= 64 {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "Too many pending Mistral logins.".into(),
        ));
    }
    all.insert(
        id.clone(),
        Arc::new(Mutex::new(Session {
            process,
            poll_url,
            verifier,
            expires,
            target: request.provider_id,
            status: "pending",
            message: None,
        })),
    );
    Ok(Json(
        json!({"session_id":id,"auth_url":auth_url,"flow":"device",
        "instructions":"Sign in to Mistral and approve Vibe access. This page checks for completion automatically. Usage follows your Mistral plan and pay-as-you-go settings."}),
    ))
}
async fn session(id: &str) -> Result<Arc<Mutex<Session>>, Error> {
    sessions().lock().await.get(id).cloned().ok_or((
        StatusCode::NOT_FOUND,
        "Mistral login expired or was cancelled.".into(),
    ))
}
fn response(s: &Session) -> Json<Value> {
    Json(json!({"status":s.status,"message":s.message}))
}
async fn status(State(state): State<App>, Path(id): Path<String>) -> Result<Json<Value>, Error> {
    let session = session(&id).await?;
    let mut s = session.lock().await;
    if s.status != "pending" {
        return Ok(response(&s));
    }
    if chrono::Utc::now() >= s.expires {
        s.status = "failed";
        s.message = Some("Mistral login expired. Try again.");
        s.verifier.clear();
        return Ok(response(&s));
    }
    let client = client()?;
    let result = client
        .get(&s.poll_url)
        .send()
        .await
        .map_err(|_| failure("Could not check Mistral sign-in."))?;
    if result.status() == StatusCode::GONE {
        s.status = "failed";
        s.message = Some("Mistral login expired. Try again.");
        s.verifier.clear();
        return Ok(response(&s));
    }
    let value = payload(result).await?;
    match field(&value, "status")? {
        "pending" => return Ok(response(&s)),
        "completed" => {}
        _ => {
            s.status = "failed";
            s.message = Some("Mistral sign-in was denied or expired.");
            s.verifier.clear();
            return Ok(response(&s));
        }
    }
    let exchange = field(&value, "exchange_token")?;
    // A key exchange is single-use. Do not replay after an uncertain response.
    s.status = "failed";
    s.message = Some("Could not finish Mistral sign-in. Start a new login.");
    let result = client
        .post(format!("{API}/vibe/sign-in/{}/exchange", s.process))
        .json(&json!({"exchange_token":exchange,"code_verifier":s.verifier}))
        .send()
        .await;
    s.verifier.clear();
    let value = payload(
        result.map_err(|_| failure("Could not finish Mistral sign-in. Start a new login."))?,
    )
    .await?;
    let key = field(&value, "api_key")?.to_owned();
    let mut account = if let Some(id) = s.target {
        let account = state
            .ai_providers
            .get(id)
            .await
            .ok_or((StatusCode::NOT_FOUND, "Account no longer exists.".into()))?;
        if account.provider_type != ProviderType::Mistral || !account.mistral_subscription {
            return Err((
                StatusCode::CONFLICT,
                "Account changed while signing in.".into(),
            ));
        }
        account
    } else {
        AIProvider::new(ProviderType::Mistral, "Mistral Vibe".into())
    };
    account.api_key = Some(key);
    account.mistral_subscription = true;
    account.use_for_backends = Some(vec!["opencode".into()]);
    account.updated_at = chrono::Utc::now();
    state
        .ai_providers
        .persist_account(account)
        .await
        .map_err(|_| failure("Could not save the Mistral account. Start a new login."))?;
    super::ai_providers::sync_store_to_opencode(
        &state.ai_providers,
        &state.config.working_dir,
        ProviderType::Mistral,
    )
    .await;
    s.status = "completed";
    s.message = None;
    Ok(response(&s))
}
async fn cancel(Path(id): Path<String>) -> Result<Json<Value>, Error> {
    if let Some(session) = sessions().lock().await.remove(&id) {
        let mut s = session.lock().await;
        s.status = "failed";
        s.verifier.clear();
    }
    Ok(Json(json!({"status":"ok"})))
}
pub(super) fn routes() -> Router<App> {
    Router::new()
        .route("/mistral-login", post(start))
        .route("/mistral-login/:id", get(status).delete(cancel))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn login_destinations_are_confined_to_mistral() {
        assert!(allowed_url(
            "https://console.mistral.ai/vibe/sign-in/123",
            false
        ));
        assert!(allowed_url(
            "https://console.mistral.ai/api/vibe/sign-in/123",
            true
        ));
        for url in [
            "http://console.mistral.ai/api/vibe/sign-in/a",
            "https://evil.test/api/vibe/sign-in/a",
            "https://console.mistral.ai.evil.test/",
            "https://user@console.mistral.ai/",
            "https://console.mistral.ai:444/",
            "https://console.mistral.ai/api/vibe/sign-in/../keys",
            "https://console.mistral.ai/api/keys",
        ] {
            assert!(!allowed_url(url, true), "{url}");
        }
    }
    #[test]
    fn pkce_is_random_and_uses_s256() {
        let (verifier, challenge) = pkce();
        assert!((43..=128).contains(&verifier.len()));
        assert_eq!(
            challenge,
            URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
        );
        assert_ne!(verifier, pkce().0);
    }
    #[tokio::test]
    async fn subscription_is_durable_and_private() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("providers.json");
        let store = crate::ai_providers::AIProviderStore::new(path.clone()).await;
        let mut account = AIProvider::new(ProviderType::Mistral, "Mistral Vibe".into());
        account.api_key = Some("test-only-key".into());
        account.mistral_subscription = true;
        let id = account.id;
        store.persist_account(account).await.unwrap();
        let reloaded = crate::ai_providers::AIProviderStore::new(path.clone()).await;
        let saved = reloaded.get(id).await.unwrap();
        assert!(saved.mistral_subscription);
        assert!(saved.is_default);
        assert_eq!(saved.api_key.as_deref(), Some("test-only-key"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }
    #[tokio::test]
    async fn failed_persistence_does_not_publish_the_account() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("unusable-parent");
        std::fs::write(&path, "not a directory").unwrap();
        let store = crate::ai_providers::AIProviderStore::new(path.join("providers.json")).await;
        let account = AIProvider::new(ProviderType::Mistral, "Mistral Vibe".into());
        let id = account.id;
        assert!(store.persist_account(account).await.is_err());
        assert!(store.get(id).await.is_none());
    }
}
