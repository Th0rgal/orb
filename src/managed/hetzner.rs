//! Hetzner Cloud implementation of [`super::ManagedProvider`].
//!
//! Spawns x86_64 and ARM64 Ubuntu servers (`cpx22`..`ccx43`, `cax31`) tagged
//! atomically at creation with `labels: {"orb-managed": "true", "orb-id": ...}`
//! and `name: spec.name` (`orb-managed-<id>`). Worker VMs bootstrap `orb-node`
//! via cloud-init `user_data` over Core's reverse HTTP relay — no inbound SSH
//! ports or static guest secrets required.
//!
//! Stopped Hetzner servers still bill hourly, so `supports_free_stop()` is
//! `false`: `stop()` delegates to `destroy()` (`DELETE /v1/servers/{id}`).

use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde_json::{json, Value};

use super::{ManagedProvider, ProviderMachine, ProviderUsage, SizeSpec, SpawnSpec};

pub const DEFAULT_API_BASE: &str = "https://api.hetzner.cloud/v1";
const EU_FALLBACK_LOCATIONS: [&str; 3] = ["fsn1", "hel1", "nbg1"];

pub const HETZNER_SIZES: [SizeSpec; 8] = [
    SizeSpec {
        size: "cpx22",
        cpu: 2,
        ram_gb: 4,
        disk_gb: 80,
        usd_per_hour: 0.034,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "cpx32",
        cpu: 4,
        ram_gb: 8,
        disk_gb: 160,
        usd_per_hour: 0.062,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "cpx42",
        cpu: 8,
        ram_gb: 16,
        disk_gb: 320,
        usd_per_hour: 0.12,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "cax31",
        cpu: 8,
        ram_gb: 16,
        disk_gb: 160,
        usd_per_hour: 0.024,
        gpu: None,
        arch: "arm64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "cpx52",
        cpu: 12,
        ram_gb: 24,
        disk_gb: 480,
        usd_per_hour: 0.174,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "cpx62",
        cpu: 16,
        ram_gb: 32,
        disk_gb: 640,
        usd_per_hour: 0.225,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "ccx33",
        cpu: 8,
        ram_gb: 32,
        disk_gb: 240,
        usd_per_hour: 0.244,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "ccx43",
        cpu: 16,
        ram_gb: 64,
        disk_gb: 360,
        usd_per_hour: 0.484,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
];

pub fn map_size_alias(raw: &str, arch: Option<&str>) -> String {
    let lower = raw.trim().to_ascii_lowercase();
    if matches!(arch, Some(a) if a.eq_ignore_ascii_case("arm64") || a.eq_ignore_ascii_case("aarch64"))
        && matches!(lower.as_str(), "small" | "default" | "medium" | "large")
    {
        return "cax31".into();
    }
    match lower.as_str() {
        "small" | "cpx21" => "cpx22".into(),
        "default" | "medium" | "cpx31" => "cpx32".into(),
        "large" | "cpx41" => "cpx42".into(),
        "xlarge" | "cpx51" => "cpx62".into(),
        "cax21" => "cax31".into(),
        other => other.into(),
    }
}

pub fn hetzner_size_spec(raw: &str, arch: Option<&str>) -> Option<SizeSpec> {
    let mapped = map_size_alias(raw, arch);
    HETZNER_SIZES.iter().copied().find(|s| s.size == mapped)
}

pub(crate) fn format_hetzner_error(text: &str) -> String {
    let Ok(v) = serde_json::from_str::<Value>(text) else {
        return text.trim().chars().take(160).collect();
    };
    let Some(err) = v.get("error") else {
        return text.trim().chars().take(160).collect();
    };
    let code = err
        .get("code")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let message = err
        .get("message")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let fields: Vec<String> = err
        .pointer("/details/fields")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|f| {
                    let name = f.get("name").and_then(Value::as_str)?;
                    let msgs: Vec<&str> = f
                        .get("messages")
                        .and_then(Value::as_array)
                        .map(|ms| ms.iter().filter_map(Value::as_str).collect())
                        .unwrap_or_default();
                    if msgs.is_empty() {
                        Some(name.to_string())
                    } else {
                        Some(format!("{name}: {}", msgs.join(", ")))
                    }
                })
                .collect()
        })
        .unwrap_or_default();
    let mut out = match (code, message) {
        (Some(c), Some(m)) if c != m => format!("{c}: {m}"),
        (Some(c), _) => c.to_string(),
        (None, Some(m)) => m.to_string(),
        (None, None) => String::new(),
    };
    if !fields.is_empty() {
        let joined = fields.join("; ");
        if out.is_empty() {
            out = joined;
        } else {
            out = format!("{out} ({joined})");
        }
    }
    out
}

pub(crate) fn candidate_locations(primary: &str, server_type: &str) -> Vec<String> {
    let mut out = Vec::with_capacity(5);
    let mut push_unique = |loc: &str| {
        let trimmed = loc.trim();
        if !trimmed.is_empty() && !out.iter().any(|existing| existing == trimmed) {
            out.push(trimmed.to_string());
        }
    };
    push_unique(primary);
    for loc in EU_FALLBACK_LOCATIONS {
        push_unique(loc);
    }
    if server_type.starts_with("cax") {
        push_unique("sin");
    }
    out
}

pub(crate) fn is_location_retryable_error(err: &str) -> bool {
    let lower = err.to_ascii_lowercase();
    lower.contains("resource_unavailable")
        || lower.contains("unsupported_error")
        || lower.contains("placement_error")
        || lower.contains("http 503")
        || ((lower.contains("http 422") || lower.contains("http 409"))
            && (lower.contains("location")
                || lower.contains("datacenter")
                || lower.contains("unavailable")
                || lower.contains("disabled")))
}

#[derive(Clone)]
pub struct HetznerProvider {
    http: reqwest::Client,
    base: String,
    key: String,
    default_location: String,
}

impl std::fmt::Debug for HetznerProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HetznerProvider")
            .field("base", &self.base)
            .field("default_location", &self.default_location)
            .finish()
    }
}

impl HetznerProvider {
    pub fn new(base: impl Into<String>, key: impl Into<String>) -> Self {
        Self::with_location(base, key, std::env::var("HETZNER_DEFAULT_LOCATION").ok())
    }

    pub fn with_location(
        base: impl Into<String>,
        key: impl Into<String>,
        default_location: Option<String>,
    ) -> Self {
        let default_location = default_location
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "fsn1".into());
        Self {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(60))
                .connect_timeout(Duration::from_secs(10))
                .build()
                .unwrap_or_default(),
            base: base.into().trim_end_matches('/').to_string(),
            key: key.into(),
            default_location,
        }
    }

    pub fn default_location(&self) -> &str {
        &self.default_location
    }

    pub fn from_env() -> Option<Self> {
        let key = std::env::var("HETZNER_CLOUD_APIKEY")
            .or_else(|_| std::env::var("HCLOUD_TOKEN"))
            .ok()
            .filter(|k| !k.trim().is_empty())?;
        std::env::remove_var("HETZNER_CLOUD_APIKEY");
        std::env::remove_var("HCLOUD_TOKEN");
        let base =
            std::env::var("HETZNER_API_BASE").unwrap_or_else(|_| DEFAULT_API_BASE.to_string());
        Some(Self::new(base, key.trim()))
    }

    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, String> {
        let mut req = self
            .http
            .request(method.clone(), format!("{}{}", self.base, path))
            .bearer_auth(&self.key);
        if let Some(b) = body {
            req = req.json(&b);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| format!("hetzner {method} {path}: {}", e.without_url()))?;
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            let msg = format_hetzner_error(&text);
            return Err(format!(
                "hetzner {method} {path} -> HTTP {} {msg}",
                status.as_u16()
            ));
        }
        if text.trim().is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_str(&text).map_err(|e| format!("hetzner {path}: bad JSON: {e}"))
    }
}

pub(crate) fn spawn_body(spec: &SpawnSpec, location: &str) -> Value {
    let server_type = map_size_alias(&spec.size, spec.arch.as_deref());
    let image = match spec.image.as_deref() {
        Some(img) if !img.is_empty() && img != "orb-node-base" && img != "provider-default" => img,
        _ => "ubuntu-24.04",
    };
    let mut body = json!({
        "name": spec.name,
        "server_type": server_type,
        "image": image,
        "location": location,
        "start_after_create": true,
        "public_net": {
            "enable_ipv4": true,
            "enable_ipv6": true,
        },
        "labels": {
            "orb-managed": "true",
            "orb-id": spec.machine_id,
        }
    });
    if let Some(script) = spec.bootstrap_script.as_deref().filter(|s| !s.is_empty()) {
        body["user_data"] = json!(script);
    }
    body
}

fn machine_from(v: &Value) -> Option<ProviderMachine> {
    let srv = v.get("server").unwrap_or(v);
    let id = srv.get("id").and_then(|id| {
        id.as_u64()
            .map(|n| n.to_string())
            .or_else(|| id.as_str().map(str::to_string))
    })?;
    Some(ProviderMachine {
        provider_id: id,
        state: srv
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string(),
        name: srv
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        deletable_at: None,
    })
}

#[async_trait]
impl ManagedProvider for HetznerProvider {
    fn name(&self) -> &'static str {
        "hetzner"
    }

    fn sizes(&self) -> &[SizeSpec] {
        &HETZNER_SIZES
    }

    fn supports_free_stop(&self) -> bool {
        false
    }

    fn supports_snapshots(&self) -> bool {
        false
    }

    fn uses_cloud_init_bootstrap(&self) -> bool {
        true
    }

    fn is_ready_state(&self, state: &str) -> bool {
        state == "running"
    }

    fn is_stopped_state(&self, state: &str) -> bool {
        matches!(state, "off" | "deleting")
    }

    async fn spawn(&self, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        let server_type = map_size_alias(&spec.size, spec.arch.as_deref());
        let locations = candidate_locations(&self.default_location, &server_type);
        let mut last_err = String::new();
        for (idx, loc) in locations.iter().enumerate() {
            let body = spawn_body(spec, loc);
            match self
                .call(reqwest::Method::POST, "/servers", Some(body))
                .await
            {
                Ok(v) => {
                    return machine_from(&v)
                        .ok_or_else(|| "hetzner create: no server id in response".to_string());
                }
                Err(e) => {
                    let has_more = idx + 1 < locations.len();
                    if has_more && is_location_retryable_error(&e) {
                        tracing::info!(
                            failed_location = %loc,
                            server_type = %server_type,
                            error = %e,
                            "Hetzner location unavailable; trying next EU location"
                        );
                        last_err = e;
                        continue;
                    }
                    return Err(e);
                }
            }
        }
        Err(last_err)
    }

    async fn get(&self, provider_id: &str) -> Result<ProviderMachine, String> {
        let v = self
            .call(
                reqwest::Method::GET,
                &format!("/servers/{provider_id}"),
                None,
            )
            .await?;
        machine_from(&v).ok_or_else(|| "hetzner get: no server".to_string())
    }

    async fn list(&self) -> Result<Vec<ProviderMachine>, String> {
        let mut out = Vec::new();
        for page in 1..=10 {
            let v = self
                .call(
                    reqwest::Method::GET,
                    &format!("/servers?label_selector=orb-managed%3Dtrue&per_page=50&page={page}"),
                    None,
                )
                .await?;
            if let Some(items) = v.get("servers").and_then(Value::as_array) {
                if items.is_empty() {
                    break;
                }
                out.extend(items.iter().filter_map(machine_from));
            } else {
                break;
            }
            let next_page = v
                .pointer("/meta/pagination/next_page")
                .and_then(Value::as_u64);
            if next_page.is_none() {
                break;
            }
        }
        Ok(out)
    }

    async fn destroy(&self, provider_id: &str) -> Result<(), String> {
        match self
            .call(
                reqwest::Method::DELETE,
                &format!("/servers/{provider_id}"),
                None,
            )
            .await
        {
            Ok(_) => Ok(()),
            Err(e) if e.contains("HTTP 404") => Ok(()),
            Err(e) => Err(e),
        }
    }

    async fn extend(&self, _provider_id: &str, _ttl_seconds: u64) -> Result<(), String> {
        // Hetzner has no provider-side TTL countdown; Core's reaper enforces TTL.
        Ok(())
    }

    async fn write_file(
        &self,
        _provider_id: &str,
        _path: &str,
        _content: &str,
    ) -> Result<(), String> {
        Err("hetzner uses cloud-init bootstrap rather than provider file writes".into())
    }

    async fn exec(
        &self,
        _provider_id: &str,
        _command: &str,
        _timeout_secs: u64,
    ) -> Result<Value, String> {
        Err("hetzner uses cloud-init bootstrap rather than provider exec".into())
    }

    async fn usage(&self, provider_id: &str) -> Result<ProviderUsage, String> {
        let v = self
            .call(
                reqwest::Method::GET,
                &format!("/servers/{provider_id}"),
                None,
            )
            .await?;
        let srv = v.get("server").unwrap_or(&v);
        let status = srv.get("status").and_then(Value::as_str).unwrap_or("");
        let running = status == "running" || status == "starting" || status == "initializing";
        let created = srv
            .get("created")
            .and_then(Value::as_str)
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
            .map(|d| d.with_timezone(&Utc));
        let stype = srv
            .pointer("/server_type/name")
            .and_then(Value::as_str)
            .unwrap_or("cpx32");
        let rate = hetzner_size_spec(stype, None).map_or(0.062, |s| s.usd_per_hour);
        let secs = created
            .map(|c| (Utc::now() - c).num_seconds().max(0) as u64)
            .unwrap_or(0);
        // Hetzner bills in hourly increments or per-minute with hourly cap; estimate pro-rata.
        Ok(ProviderUsage {
            dollars: (secs as f64 / 3600.0) * rate,
            seconds: secs,
            running,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_spec(size: &str) -> SpawnSpec {
        SpawnSpec {
            machine_id: "mm12345678".into(),
            size: size.into(),
            cpu: 8,
            ram_gb: 16,
            ttl_seconds: 3600,
            image: Some("orb-node-base".into()),
            name: "orb-managed-mm12345678".into(),
            idempotency_key: "orb-managed-mm12345678".into(),
            bootstrap_script: Some("#!/usr/bin/env bash\necho ok\n".into()),
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
    fn spawn_body_tags_atomically_and_attaches_cloud_init() {
        let spec = sample_spec("large");
        let body = spawn_body(&spec, "fsn1");
        assert_eq!(body["name"], "orb-managed-mm12345678");
        assert_eq!(body["server_type"], "cpx42");
        assert_eq!(body["image"], "ubuntu-24.04");
        assert_eq!(body["labels"]["orb-managed"], "true");
        assert_eq!(body["labels"]["orb-id"], "mm12345678");
        assert!(body["user_data"].as_str().unwrap().contains("echo ok"));
    }

    #[test]
    fn legacy_eu_retired_sizes_and_arm64_aliases_map_to_active_types() {
        assert_eq!(map_size_alias("large", Some("arm64")), "cax31");
        assert_eq!(map_size_alias("cax21", None), "cax31");
        assert_eq!(map_size_alias("cpx21", None), "cpx22");
        assert_eq!(map_size_alias("cpx31", None), "cpx32");
        assert_eq!(map_size_alias("cpx41", None), "cpx42");
        assert_eq!(map_size_alias("cpx51", None), "cpx62");
        assert_eq!(map_size_alias("ccx43", None), "ccx43");
        assert_eq!(hetzner_size_spec("cpx41", None).unwrap().size, "cpx42");
    }

    #[test]
    fn error_formatter_surfaces_code_message_and_field_details() {
        let payload = r#"{
            "error": {
                "code": "invalid_input",
                "message": "invalid input in field 'server_type'",
                "details": {
                    "fields": [
                        {"name": "server_type", "messages": ["cpx51 is unavailable in fsn1"]}
                    ]
                }
            }
        }"#;
        assert_eq!(
            format_hetzner_error(payload),
            "invalid_input: invalid input in field 'server_type' (server_type: cpx51 is unavailable in fsn1)"
        );
    }

    #[tokio::test]
    async fn spawn_falls_back_to_next_eu_location_on_capacity_refusal() {
        use axum::{extract::State, http::StatusCode, routing::post, Json, Router};
        use std::sync::{Arc, Mutex};

        let seen: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let seen_clone = Arc::clone(&seen);
        let app = Router::new()
            .route(
                "/servers",
                post(
                    |State(seen): State<Arc<Mutex<Vec<String>>>>, Json(body): Json<Value>| async move {
                        let loc = body["location"].as_str().unwrap_or_default().to_string();
                        seen.lock().unwrap().push(loc.clone());
                        if loc == "fsn1" {
                            (
                                StatusCode::UNPROCESSABLE_ENTITY,
                                Json(json!({
                                    "error": {
                                        "code": "resource_unavailable",
                                        "message": "server location disabled"
                                    }
                                })),
                            )
                        } else {
                            (
                                StatusCode::CREATED,
                                Json(json!({
                                    "server": {"id": 99001, "name": body["name"], "status": "initializing"}
                                })),
                            )
                        }
                    },
                ),
            )
            .with_state(seen_clone);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let provider = HetznerProvider::with_location(
            format!("http://{addr}"),
            "test-token",
            Some("fsn1".into()),
        );
        let machine = provider.spawn(&sample_spec("cpx42")).await.unwrap();
        assert_eq!(machine.provider_id, "99001");
        assert_eq!(
            *seen.lock().unwrap(),
            vec!["fsn1".to_string(), "hel1".to_string()]
        );
    }
}
