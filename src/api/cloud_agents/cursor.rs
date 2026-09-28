//! Cursor public v1 API. No provider errors or credentials are copied to receipts.
use super::*;
use reqwest::{Client, Method};
use serde_json::json;
use std::time::Duration;
pub struct Cursor {
    client: Client,
    key: String,
}
impl Cursor {
    pub fn from_account(account: &str) -> Result<Self, String> {
        if account != "cursor-default" {
            return Err("Unknown Cursor account".into());
        }
        let key = std::env::var("CURSOR_CLOUD_API_KEY")
            .map_err(|_| "Cursor account needs reconnection")?;
        if key.trim().is_empty() {
            return Err("Cursor account needs reconnection".into());
        }
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| "Cannot initialize Cursor transport")?;
        Ok(Self { client, key })
    }
    pub async fn request(
        &self,
        method: Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, String> {
        let mut req = self
            .client
            .request(method, format!("https://api.cursor.com/v1/{path}"))
            .basic_auth(&self.key, Some(""));
        if let Some(body) = body {
            req = req.json(&body);
        }
        let response = req
            .send()
            .await
            .map_err(|_| "transport_uncertain".to_string())?;
        let status = response.status();
        if !status.is_success() {
            return Err(match status.as_u16() {
                401 | 403 => "reconnect_required",
                409 => "conflict",
                429 => "quota_exhausted",
                404 => "not_found",
                410 => "stream_expired",
                400 | 422 => "invalid_request",
                _ => "transport_uncertain",
            }
            .into());
        }
        response
            .json()
            .await
            .map_err(|_| "incompatible_response".into())
    }
    pub async fn agent(&self, id: &str) -> Result<Value, String> {
        validate_id(id)?;
        self.request(Method::GET, &format!("agents/{id}"), None)
            .await
    }
    pub async fn models(&self) -> Result<Value, String> {
        self.request(Method::GET, "models", None).await
    }
    pub async fn repositories(&self) -> Result<Value, String> {
        // Serialize discovery and cache errors as well as successes. Cursor permits
        // at most 30 repository requests per user/hour; reopening Orb is cheap.
        type Cached = Option<(String, std::time::Instant, Result<Value, String>)>;
        static CACHE: std::sync::OnceLock<tokio::sync::Mutex<Cached>> = std::sync::OnceLock::new();
        use sha2::{Digest, Sha256};
        let fingerprint = format!("{:x}", Sha256::digest(self.key.as_bytes()));
        let mut cache = CACHE
            .get_or_init(|| tokio::sync::Mutex::new(None))
            .lock()
            .await;
        if let Some((key, at, result)) = cache.as_ref() {
            if key == &fingerprint && at.elapsed() < Duration::from_secs(300) {
                return result.clone();
            }
        }
        let result = self.request(Method::GET, "repositories", None).await;
        *cache = Some((fingerprint, std::time::Instant::now(), result.clone()));
        result
    }
    pub async fn usage(&self, id: &str) -> Result<Value, String> {
        validate_id(id)?;
        self.request(Method::GET, &format!("agents/{id}/usage"), None)
            .await
    }
}
fn user_account(value: &Value) -> bool {
    match value.get("userId") {
        Some(Value::String(id)) => !id.trim().is_empty(),
        Some(Value::Number(id)) => id.as_u64().is_some_and(|id| id > 0),
        _ => false,
    }
}
fn validate_id(id: &str) -> Result<(), String> {
    if id.is_empty()
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        Err("Invalid external identifier".into())
    } else {
        Ok(())
    }
}
fn id(value: &Value, pointer: &str) -> Result<String, String> {
    let value = value
        .pointer(pointer)
        .and_then(Value::as_str)
        .ok_or("incompatible_response")?;
    validate_id(value)?;
    Ok(value.into())
}
#[async_trait::async_trait]
impl Adapter for Cursor {
    async fn availability(&self) -> Result<(), String> {
        let account = self.request(Method::GET, "me", None).await?;
        if user_account(&account) {
            Ok(())
        } else {
            Err("A Cursor user API key is required".into())
        }
    }
    async fn create(&self, execution: &Execution, turn: &Turn) -> Result<(String, String), String> {
        let mut body = json!({"agentId": format!("bc-{}", execution.mission_id), "prompt": {"text": turn.prompt}, "autoCreatePR": false, "workOnCurrentBranch": false});
        if let Some(repo) = &execution.selection.repository {
            body["repos"] = json!([{"url": repo, "startingRef": execution.selection.git_ref}]);
        }
        if let Some(model) = &execution.selection.model {
            body["model"] = json!({"id": model, "params": execution.selection.model_params});
        }
        let response = self.request(Method::POST, "agents", Some(body)).await?;
        let agent = id(&response, "/agent/id")?;
        if agent != format!("bc-{}", execution.mission_id) {
            return Err("incompatible_response".into());
        }
        Ok((agent, id(&response, "/run/id")?))
    }
    async fn follow_up(&self, agent: &str, turn: &Turn) -> Result<String, String> {
        validate_id(agent)?;
        let response = self
            .request(
                Method::POST,
                &format!("agents/{agent}/runs"),
                Some({
                    let mut body = json!({"prompt": {"text": turn.prompt}});
                    if let Some(model) = &turn.model {
                        body["model"] = json!({"id":model,"params":turn.model_params});
                    }
                    body
                }),
            )
            .await?;
        id(&response, "/run/id")
    }
    async fn observe(&self, agent: &str, run: &str) -> Result<Value, String> {
        validate_id(agent)?;
        validate_id(run)?;
        self.request(Method::GET, &format!("agents/{agent}/runs/{run}"), None)
            .await
    }
    async fn results(&self, agent: &str) -> Result<Value, String> {
        validate_id(agent)?;
        self.request(Method::GET, &format!("agents/{agent}/artifacts"), None)
            .await
    }
    async fn cancel(&self, agent: &str, run: &str) -> Result<(), String> {
        validate_id(agent)?;
        validate_id(run)?;
        self.request(
            Method::POST,
            &format!("agents/{agent}/runs/{run}/cancel"),
            Some(json!({})),
        )
        .await
        .map(|_| ())
    }
}
pub fn phase(status: &str) -> Phase {
    match status {
        "CREATING" => Phase::Submitting,
        "RUNNING" => Phase::Running,
        "FINISHED" => Phase::ResponseComplete,
        "ERROR" | "EXPIRED" => Phase::Failed,
        "CANCELLED" => Phase::Cancelled,
        _ => Phase::Incompatible,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn user_account_accepts_numeric_ids_but_rejects_service_keys() {
        assert!(user_account(&json!({"userId": 42})));
        assert!(user_account(&json!({"userId": "user-42"})));
        assert!(!user_account(&json!({"apiKeyName": "service"})));
        assert!(!user_account(&json!({"userId": null})));
        assert!(!user_account(&json!({"userId": ""})));
        assert!(!user_account(&json!({"userId": 0})));
    }
    #[test]
    fn agent_idle_is_not_a_run_result() {
        assert_eq!(phase("IDLE"), Phase::Incompatible);
        assert_eq!(phase("FINISHED"), Phase::ResponseComplete);
        assert!(validate_id("../../me").is_err());
    }
}
impl Cursor {
    /// One bounded observation window. Read the authoritative run on every tick,
    /// even when the stream has expired. Never parse opaque Last-Event-ID values.
    pub async fn stream_window(
        &self,
        agent: &str,
        run: &str,
        cursor: Option<&str>,
    ) -> Result<Vec<Event>, String> {
        use futures::StreamExt;
        use reqwest_eventsource::{Event as SseEvent, RequestBuilderExt};
        validate_id(agent)?;
        validate_id(run)?;
        let mut request = self
            .client
            .get(format!(
                "https://api.cursor.com/v1/agents/{agent}/runs/{run}/stream"
            ))
            .basic_auth(&self.key, Some(""));
        if let Some(cursor) = cursor {
            request = request.header("Last-Event-ID", cursor);
        }
        let mut stream = request.eventsource().map_err(|_| "stream_unavailable")?;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        let mut events = Vec::new();
        while events.len() < 200 {
            match tokio::time::timeout_at(deadline, stream.next()).await {
                Ok(Some(Ok(SseEvent::Message(message)))) => {
                    if message.event == "done" {
                        break;
                    }
                    // Framing events have no stable id and are read via GET run.
                    if message.id.is_empty() || message.data.len() > 256 * 1024 {
                        continue;
                    }
                    if !matches!(
                        message.event.as_str(),
                        "assistant" | "tool_call" | "status" | "result"
                    ) {
                        continue;
                    }
                    let data =
                        serde_json::from_str(&message.data).map_err(|_| "incompatible_response")?;
                    events.push(Event {
                        run_id: run.into(),
                        id: message.id,
                        kind: message.event,
                        data,
                    });
                }
                Ok(Some(Ok(SseEvent::Open))) => {}
                _ => break,
            }
        }
        stream.close();
        Ok(events)
    }
    pub async fn artifact_url(&self, agent: &str, path: &str) -> Result<Value, String> {
        validate_id(agent)?;
        if !path.starts_with("artifacts/") || path.split('/').any(|s| s == "..") {
            return Err("Invalid artifact path".into());
        }
        self.request(
            Method::GET,
            &format!(
                "agents/{agent}/artifacts/download?path={}",
                urlencoding::encode(path)
            ),
            None,
        )
        .await
    }
}
