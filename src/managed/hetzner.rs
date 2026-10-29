//! Hetzner Cloud implementation of [`super::ManagedProvider`].
//!
//! Spawns x86_64 and ARM64 Ubuntu servers (`cpx21`..`ccx33`, `cax31`) tagged
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

pub const HETZNER_SIZES: [SizeSpec; 6] = [
    SizeSpec {
        size: "cpx21",
        cpu: 3,
        ram_gb: 4,
        disk_gb: 80,
        usd_per_hour: 0.015,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "cpx31",
        cpu: 4,
        ram_gb: 8,
        disk_gb: 160,
        usd_per_hour: 0.027,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "cpx41",
        cpu: 8,
        ram_gb: 16,
        disk_gb: 240,
        usd_per_hour: 0.050,
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
        size: "cpx51",
        cpu: 16,
        ram_gb: 32,
        disk_gb: 360,
        usd_per_hour: 0.102,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "ccx33",
        cpu: 8,
        ram_gb: 32,
        disk_gb: 240,
        usd_per_hour: 0.105,
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
        "small" => "cpx21".into(),
        "default" | "medium" => "cpx31".into(),
        "large" => "cpx41".into(),
        "xlarge" => "cpx51".into(),
        other => other.into(),
    }
}

pub fn hetzner_size_spec(raw: &str, arch: Option<&str>) -> Option<SizeSpec> {
    let mapped = map_size_alias(raw, arch);
    HETZNER_SIZES.iter().copied().find(|s| s.size == mapped)
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
        let default_location = std::env::var("HETZNER_DEFAULT_LOCATION")
            .ok()
            .filter(|s| !s.trim().is_empty())
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
            let msg = serde_json::from_str::<Value>(&text)
                .ok()
                .and_then(|v| {
                    v.get("error")
                        .and_then(|e| e.get("code").or_else(|| e.get("message")))
                        .and_then(Value::as_str)
                        .map(str::to_string)
                })
                .unwrap_or_default();
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
        let body = spawn_body(spec, &self.default_location);
        let v = self
            .call(reqwest::Method::POST, "/servers", Some(body))
            .await?;
        machine_from(&v).ok_or_else(|| "hetzner create: no server id in response".to_string())
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
            .unwrap_or("cpx31");
        let rate = hetzner_size_spec(stype, None).map_or(0.03, |s| s.usd_per_hour);
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

    #[test]
    fn spawn_body_tags_atomically_and_attaches_cloud_init() {
        let spec = SpawnSpec {
            machine_id: "mm12345678".into(),
            size: "large".into(),
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
            allow_24h_commitment: false,
            provisioning_mode: crate::managed::ProvisioningMode::Worker,
        };
        let body = spawn_body(&spec, "fsn1");
        assert_eq!(body["name"], "orb-managed-mm12345678");
        assert_eq!(body["server_type"], "cpx41");
        assert_eq!(body["image"], "ubuntu-24.04");
        assert_eq!(body["labels"]["orb-managed"], "true");
        assert_eq!(body["labels"]["orb-id"], "mm12345678");
        assert!(body["user_data"].as_str().unwrap().contains("echo ok"));
    }

    #[test]
    fn arm64_alias_maps_to_cax31() {
        assert_eq!(map_size_alias("large", Some("arm64")), "cax31");
        assert_eq!(map_size_alias("cpx51", None), "cpx51");
    }
}
