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
        self.call_bounded(method, path, body, idempotency_key, timeout, None)
            .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn call_bounded(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
        idempotency_key: Option<&str>,
        timeout: Option<Duration>,
        max_bytes: Option<usize>,
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
        let mut resp = req
            .send()
            .await
            .map_err(|e| format!("boat {method} {path}: {}", e.without_url()))?;
        let status = resp.status();
        let text = if let Some(limit) = max_bytes {
            let mut bytes = Vec::new();
            while let Some(chunk) = resp
                .chunk()
                .await
                .map_err(|_| "boat: response read failed")?
            {
                if chunk.len() > limit.saturating_sub(bytes.len()) {
                    return Err(
                        "boat: raw operation response exceeded limit; outcome uncertain".into(),
                    );
                }
                bytes.extend_from_slice(&chunk);
            }
            String::from_utf8(bytes).map_err(|_| "boat: invalid response encoding")?
        } else {
            resp.text().await.unwrap_or_default()
        };
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

/// Boat `from` names a saved snapshot/share; omitting it selects the provider
/// base image. `provider-default` is an explicit Core allowlist sentinel.
fn spawn_body(spec: &SpawnSpec) -> Value {
    let mut body = json!({
        "type": spec.size,
        "name": spec.name,
        "ttlSeconds": spec.ttl_seconds,
        // The account's base environment carries GitHub and agent
        // credentials; managed nodes must never receive them.
        "noEnv": true,
    });
    if let Some(image) = spec
        .image
        .as_deref()
        .filter(|i| !i.is_empty() && *i != "provider-default")
    {
        body["from"] = json!(image);
    }
    body
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
        deletable_at: None,
    })
}

/// boat states that mean the machine is up and accepting commands.
pub fn is_ready_state(state: &str) -> bool {
    matches!(state, "ready" | "idle" | "running" | "busy")
}

/// boat states after which nothing is billed.
/// boat answers `HTTP 400 stop_failed` for a sandbox that is not yet
/// stoppable (fresh, still booting): retry the delete.
pub fn stop_failed_retryable(error: &str) -> bool {
    error.contains("stop_failed")
}

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

    fn sizes(&self) -> &[super::SizeSpec] {
        &super::SIZES
    }

    fn supports_free_stop(&self) -> bool {
        true
    }

    fn supports_snapshots(&self) -> bool {
        true
    }

    fn is_ready_state(&self, state: &str) -> bool {
        is_ready_state(state)
    }

    fn is_stopped_state(&self, state: &str) -> bool {
        is_stopped_state(state)
    }

    async fn spawn(&self, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        let body = spawn_body(spec);
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
            // A sandbox that is still starting answers `stop_failed`: wait
            // for it to settle and retry the delete instead of leaving it.
            Err(e) if stop_failed_retryable(&e) => {
                let mut last = e;
                for attempt in 1..=3u64 {
                    tokio::time::sleep(Duration::from_secs(3 * attempt)).await;
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
                        Err(e) => last = e,
                    }
                }
                Err(last)
            }
            Err(e) => Err(e),
        }
    }

    async fn stop(&self, provider_id: &str) -> Result<(), String> {
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
            Err(e) if e.contains("HTTP 404") || e.contains("HTTP 409") => Ok(()),
            Err(e) => Err(e),
        }
    }

    async fn fork(&self, provider_id: &str, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        let v = self
            .call(
                reqwest::Method::POST,
                &format!("/sandboxes/{provider_id}/fork"),
                Some(json!({
                    "type": spec.size,
                    "name": spec.name,
                    "ttlSeconds": spec.ttl_seconds,
                    "noEnv": true
                })),
                Some(&spec.idempotency_key),
                Some(Duration::from_secs(120)),
            )
            .await?;
        let machine = machine_from(&v).ok_or("boat fork: no sandbox id in response")?;
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

    async fn save_snapshot(&self, provider_id: &str, name: &str) -> Result<(), String> {
        self.call(
            reqwest::Method::POST,
            "/saved-snapshots",
            Some(json!({"sandboxId": provider_id, "name": name})),
            None,
            Some(Duration::from_secs(60)),
        )
        .await
        .map(|_| ())
    }

    async fn snapshot(&self, name: &str) -> Result<super::ProviderSnapshot, String> {
        let v = self
            .call(
                reqwest::Method::GET,
                &format!("/saved-snapshots/{}", urlencoding::encode(name)),
                None,
                None,
                None,
            )
            .await?;
        let s = v.get("snapshot").unwrap_or(&v);
        Ok(super::ProviderSnapshot {
            name: name.to_string(),
            status: s
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string(),
            size_bytes: s.get("sizeBytes").and_then(Value::as_u64),
        })
    }

    async fn delete_snapshot(&self, name: &str) -> Result<(), String> {
        match self
            .call(
                reqwest::Method::DELETE,
                &format!("/saved-snapshots/{}", urlencoding::encode(name)),
                None,
                None,
                None,
            )
            .await
        {
            Ok(_) => Ok(()),
            Err(e) if e.contains("HTTP 404") => Ok(()),
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

    async fn raw_exec(
        &self,
        provider_id: &str,
        command: &str,
        timeout_secs: u64,
    ) -> Result<Value, String> {
        self.call_bounded(
            reqwest::Method::POST,
            &format!("/sandboxes/{provider_id}/commands"),
            Some(json!({"command": command, "timeoutSeconds": timeout_secs})),
            None,
            Some(Duration::from_secs(timeout_secs + 5)),
            Some(512 * 1024),
        )
        .await
    }

    async fn raw_write_file(
        &self,
        provider_id: &str,
        path: &str,
        content: &str,
    ) -> Result<(), String> {
        self.call_bounded(
            reqwest::Method::PUT,
            &format!("/sandboxes/{provider_id}/files"),
            Some(json!({"path": path, "content": content})),
            None,
            Some(Duration::from_secs(30)),
            Some(512 * 1024),
        )
        .await
        .map(|_| ())
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

#[cfg(test)]
mod raw_image_tests {
    use super::*;
    fn spec(image: &str) -> SpawnSpec {
        SpawnSpec {
            machine_id: "mmtest000".into(),
            size: "small".into(),
            cpu: 2,
            ram_gb: 4,
            ttl_seconds: 600,
            image: Some(image.into()),
            name: "test".into(),
            idempotency_key: "test".into(),
            bootstrap_script: None,
            gpu: None,
            arch: None,
            max_hourly_usd: None,
            preferred_offer_id: None,
            exclude_offer_ids: Vec::new(),
            allow_24h_commitment: false,
            provisioning_mode: crate::managed::ProvisioningMode::Worker,
        }
    }
    #[test]
    fn provider_default_omits_snapshot_but_never_injects_account_environment() {
        let body = spawn_body(&spec("provider-default"));
        assert!(body.get("from").is_none());
        assert_eq!(body["noEnv"], true);
        assert_eq!(body["ttlSeconds"], 600);
        assert_eq!(body["type"], "small");
    }
    #[test]
    fn named_images_still_use_from_without_account_environment() {
        let body = spawn_body(&spec("orb-node-base"));
        assert_eq!(body["from"], "orb-node-base");
        assert_eq!(body["noEnv"], true);
    }
}
