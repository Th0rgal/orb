//! boat.dev implementation of [`super::ManagedProvider`].
//!
//! Only the REST surface the scoped Core key may use is touched: create,
//! read, update (rename / TTL), stop, exec, file write and usage. Delete is
//! not assumed: `destroy` stops the sandbox, which ends billing, and boat
//! removes a stopped disk after 14 days.

use std::time::Duration;

use async_trait::async_trait;
use serde_json::{json, Value};

use super::{ManagedProvider, ProviderMachine, ProviderUsage, SpawnSpec};

pub const DEFAULT_API_BASE: &str = "https://boat.dev/api/v1";

#[derive(Clone)]
pub struct BoatProvider {
    http: reqwest::Client,
    base: String,
    key: String,
}

impl std::fmt::Debug for BoatProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the key.
        f.debug_struct("BoatProvider")
            .field("base", &self.base)
            .finish()
    }
}

impl BoatProvider {
    pub fn new(base: impl Into<String>, key: impl Into<String>) -> Self {
        Self {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(60))
                .connect_timeout(Duration::from_secs(10))
                .build()
                .unwrap_or_default(),
            base: base.into().trim_end_matches('/').to_string(),
            key: key.into(),
        }
    }

    pub fn from_env() -> Option<Self> {
        let key = std::env::var("BOAT_API_KEY")
            .ok()
            .filter(|k| !k.trim().is_empty())?;
        // Keep the key in memory only: harness processes spawned by Core must
        // not inherit an account-level provider credential.
        std::env::remove_var("BOAT_API_KEY");
        let base = std::env::var("BOAT_API_BASE").unwrap_or_else(|_| DEFAULT_API_BASE.into());
        Some(Self::new(base, key.trim()))
    }

    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
        idempotency_key: Option<&str>,
        timeout: Option<Duration>,
    ) -> Result<Value, String> {
        let mut req = self
            .http
            .request(method.clone(), format!("{}{}", self.base, path))
            .bearer_auth(&self.key);
        if let Some(key) = idempotency_key {
            req = req.header("Idempotency-Key", key);
        }
        if let Some(t) = timeout {
            req = req.timeout(t);
        }
        if let Some(body) = body {
            req = req.json(&body);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| format!("boat {method} {path}: {}", e.without_url()))?;
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            let code = serde_json::from_str::<Value>(&text)
                .ok()
                .and_then(|v| {
                    v.get("code")
                        .or_else(|| v.get("error"))
                        .and_then(Value::as_str)
                        .map(str::to_string)
                })
                .unwrap_or_default();
            return Err(format!(
                "boat {method} {path} -> HTTP {} {code}",
                status.as_u16()
            ));
        }
        if text.trim().is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_str(&text).map_err(|e| format!("boat {path}: bad JSON: {e}"))
    }
}

fn machine_from(v: &Value) -> Option<ProviderMachine> {
    let sb = v.get("sandbox").unwrap_or(v);
    Some(ProviderMachine {
        provider_id: sb.get("id")?.as_str()?.to_string(),
        state: sb
            .get("state")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string(),
        name: sb
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
    })
}

/// boat states that mean the machine is up and accepting commands.
pub fn is_ready_state(state: &str) -> bool {
    matches!(state, "ready" | "idle" | "running" | "busy")
}

/// boat states after which nothing is billed.
pub fn is_stopped_state(state: &str) -> bool {
    matches!(
        state,
        "archived" | "stopped" | "deleted" | "error" | "archiving"
    )
}

#[async_trait]
impl ManagedProvider for BoatProvider {
    fn name(&self) -> &'static str {
        "boat"
    }

    async fn spawn(&self, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        let mut body = json!({
            "type": spec.size,
            "ttlSeconds": spec.ttl_seconds,
            // The account's base environment carries GitHub and agent
            // credentials; managed nodes must never receive them.
            "noEnv": true,
        });
        if let Some(image) = spec.image.as_deref().filter(|i| !i.is_empty()) {
            body["from"] = json!(image);
        }
        let v = self
            .call(
                reqwest::Method::POST,
                "/sandboxes",
                Some(body),
                Some(&spec.idempotency_key),
                Some(Duration::from_secs(120)),
            )
            .await?;
        let machine = machine_from(&v).ok_or("boat create: no sandbox id in response")?;
        // Tag it so the reconciler can tell our machines from research ones.
        let _ = self
            .call(
                reqwest::Method::PATCH,
                &format!("/sandboxes/{}", machine.provider_id),
                Some(json!({"name": spec.name})),
                None,
                None,
            )
            .await;
        Ok(machine)
    }

    async fn get(&self, provider_id: &str) -> Result<ProviderMachine, String> {
        let v = self
            .call(
                reqwest::Method::GET,
                &format!("/sandboxes/{provider_id}"),
                None,
                None,
                None,
            )
            .await?;
        machine_from(&v).ok_or_else(|| "boat get: no sandbox".to_string())
    }

    async fn list(&self) -> Result<Vec<ProviderMachine>, String> {
        let mut out = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..20 {
            let path = match &cursor {
                Some(c) => format!("/sandboxes?limit=200&cursor={c}"),
                None => "/sandboxes?limit=200".to_string(),
            };
            let v = self
                .call(reqwest::Method::GET, &path, None, None, None)
                .await?;
            if let Some(items) = v.get("sandboxes").and_then(Value::as_array) {
                out.extend(items.iter().filter_map(machine_from));
            }
            cursor = v
                .get("nextCursor")
                .or_else(|| v.get("cursor"))
                .and_then(Value::as_str)
                .map(str::to_string);
            if cursor.is_none() {
                break;
            }
        }
        Ok(out)
    }

    async fn destroy(&self, provider_id: &str) -> Result<(), String> {
        // Prefer a real delete when the key allows it; otherwise stop.
        match self
            .call(
                reqwest::Method::DELETE,
                &format!("/sandboxes/{provider_id}"),
                None,
                None,
                None,
            )
            .await
        {
            Ok(_) => return Ok(()),
            Err(e) if e.contains("HTTP 404") => return Ok(()),
            Err(_) => {}
        }
        match self
            .call(
                reqwest::Method::POST,
                &format!("/sandboxes/{provider_id}/stop"),
                Some(json!({})),
                None,
                None,
            )
            .await
        {
            Ok(_) => Ok(()),
            // Already stopped / gone.
            Err(e) if e.contains("HTTP 404") || e.contains("HTTP 409") => Ok(()),
            Err(e) => Err(e),
        }
    }

    async fn extend(&self, provider_id: &str, ttl_seconds: u64) -> Result<(), String> {
        self.call(
            reqwest::Method::PATCH,
            &format!("/sandboxes/{provider_id}"),
            Some(json!({"ttlSeconds": ttl_seconds})),
            None,
            None,
        )
        .await
        .map(|_| ())
    }

    async fn write_file(&self, provider_id: &str, path: &str, content: &str) -> Result<(), String> {
        self.call(
            reqwest::Method::PUT,
            &format!("/sandboxes/{provider_id}/files"),
            Some(json!({"path": path, "content": content})),
            None,
            None,
        )
        .await
        .map(|_| ())
    }

    async fn exec(
        &self,
        provider_id: &str,
        command: &str,
        timeout_secs: u64,
    ) -> Result<Value, String> {
        self.call(
            reqwest::Method::POST,
            &format!("/sandboxes/{provider_id}/commands"),
            Some(json!({"command": command, "timeoutSeconds": timeout_secs.clamp(1, 600)})),
            None,
            Some(Duration::from_secs(timeout_secs + 30)),
        )
        .await
    }

    async fn usage(&self, provider_id: &str) -> Result<ProviderUsage, String> {
        let v = self
            .call(
                reqwest::Method::GET,
                &format!("/sandboxes/{provider_id}/usage"),
                None,
                None,
                None,
            )
            .await?;
        Ok(ProviderUsage {
            dollars: v.get("dollars").and_then(Value::as_f64).unwrap_or(0.0),
            seconds: v.get("seconds").and_then(Value::as_u64).unwrap_or(0),
            running: v.get("running").and_then(Value::as_bool).unwrap_or(false),
        })
    }
}
