//! Vast.ai GPU marketplace implementation of [`super::ManagedProvider`].
//!
//! Uses Vast.ai's v1 API (`https://cloud.vast.ai/api/v1/`) — `/api/v0/` is
//! deprecated (`HTTP 410`). Searches verified on-demand CUDA offers matching
//! the requested GPU class (`rtx4090`, `a100`, `h100`, `l40s`, or explicit
//! `spec.gpu`) under `max_hourly_usd`, rents with `label: spec.name`
//! (`orb-managed-<id>`) and `onstart` script enrolling `orb-node` over Core's
//! reverse HTTP relay, and destroys via `DELETE /instances/{id}/`.

use std::time::Duration;

use async_trait::async_trait;
use serde_json::{json, Value};

use super::{ManagedProvider, ProviderMachine, ProviderUsage, SizeSpec, SpawnSpec};

pub const DEFAULT_API_BASE: &str = "https://cloud.vast.ai/api/v1";

pub const VASTAI_SIZES: [SizeSpec; 4] = [
    SizeSpec {
        size: "rtx4090",
        cpu: 16,
        ram_gb: 64,
        disk_gb: 120,
        usd_per_hour: 0.45,
    },
    SizeSpec {
        size: "l40s",
        cpu: 16,
        ram_gb: 64,
        disk_gb: 160,
        usd_per_hour: 0.95,
    },
    SizeSpec {
        size: "a100",
        cpu: 24,
        ram_gb: 96,
        disk_gb: 200,
        usd_per_hour: 1.35,
    },
    SizeSpec {
        size: "h100",
        cpu: 24,
        ram_gb: 128,
        disk_gb: 250,
        usd_per_hour: 2.40,
    },
];

pub fn gpu_model_for_size<'a>(size: &'a str, explicit_gpu: Option<&'a str>) -> &'a str {
    if let Some(gpu) = explicit_gpu.map(str::trim).filter(|g| !g.is_empty()) {
        return gpu;
    }
    match size.trim().to_ascii_lowercase().as_str() {
        "small" | "default" | "medium" | "rtx4090" | "4090" => "RTX 4090",
        "l40s" | "l40" => "L40S",
        "large" | "a100" => "A100 SXM4",
        "xlarge" | "h100" => "H100 SXM",
        other => {
            let _ = other;
            size.trim()
        }
    }
}

pub fn vastai_size_spec(raw: &str) -> Option<SizeSpec> {
    let key = match raw.trim().to_ascii_lowercase().as_str() {
        "small" | "default" | "medium" | "4090" => "rtx4090",
        "l40" => "l40s",
        "large" => "a100",
        "xlarge" => "h100",
        other => return VASTAI_SIZES.iter().copied().find(|s| s.size == other),
    };
    VASTAI_SIZES.iter().copied().find(|s| s.size == key)
}

#[derive(Clone)]
pub struct VastAiProvider {
    http: reqwest::Client,
    base: String,
    key: String,
}

impl std::fmt::Debug for VastAiProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VastAiProvider")
            .field("base", &self.base)
            .finish()
    }
}

impl VastAiProvider {
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
        let key = std::env::var("VASTAI_API_KEY")
            .or_else(|_| std::env::var("VAST_API_KEY"))
            .ok()
            .filter(|k| !k.trim().is_empty())?;
        std::env::remove_var("VASTAI_API_KEY");
        std::env::remove_var("VAST_API_KEY");
        let base =
            std::env::var("VASTAI_API_BASE").unwrap_or_else(|_| DEFAULT_API_BASE.to_string());
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
            .map_err(|e| format!("vastai {method} {path}: {}", e.without_url()))?;
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(format!(
                "vastai {method} {path} -> HTTP {} {}",
                status.as_u16(),
                text.chars().take(160).collect::<String>()
            ));
        }
        if text.trim().is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_str(&text).map_err(|e| format!("vastai {path}: bad JSON: {e}"))
    }
}

pub(crate) fn search_bundles_body(spec: &SpawnSpec) -> Value {
    let gpu_name = gpu_model_for_size(&spec.size, spec.gpu.as_deref());
    let default_ceiling = vastai_size_spec(&spec.size).map_or(2.50, |s| s.usd_per_hour * 1.6);
    let max_dph = spec.max_hourly_usd.unwrap_or(default_ceiling);
    json!({
        "verified": {"eq": true},
        "external": {"eq": false},
        "rentable": {"eq": true},
        "rented": {"eq": false},
        "gpu_name": {"eq": gpu_name},
        "dph_total": {"lte": max_dph},
        "reliability2": {"gte": 0.98},
        "order": [["dph_total", "asc"]],
        "type": "on-demand",
        "limit": 10
    })
}

pub(crate) fn create_instance_body(spec: &SpawnSpec, disk_gb: u32) -> Value {
    let image = match spec.image.as_deref() {
        Some(img) if !img.is_empty() && img != "orb-node-base" && img != "provider-default" => img,
        _ => "pytorch/pytorch:2.4.1-cuda12.4-cudnn9-devel",
    };
    let mut body = json!({
        "client_id": "me",
        "image": image,
        "disk": disk_gb.max(40),
        "label": spec.name,
        "runtype": "ssh_direc ssh_proxy",
    });
    if let Some(script) = spec.bootstrap_script.as_deref().filter(|s| !s.is_empty()) {
        body["onstart"] = json!(script);
    }
    body
}

fn instance_from(v: &Value) -> Option<ProviderMachine> {
    let inst = v.get("instances").filter(|i| i.is_object()).unwrap_or(v);
    let id = inst
        .get("id")
        .or_else(|| inst.get("new_contract"))
        .and_then(|x| {
            x.as_u64()
                .map(|n| n.to_string())
                .or_else(|| x.as_str().map(str::to_string))
        })?;
    let state = inst
        .get("actual_status")
        .or_else(|| inst.get("cur_state"))
        .or_else(|| inst.get("intended_status"))
        .and_then(Value::as_str)
        .unwrap_or("loading")
        .to_string();
    let name = inst
        .get("label")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    Some(ProviderMachine {
        provider_id: id,
        state,
        name,
        deletable_at: None,
    })
}

#[async_trait]
impl ManagedProvider for VastAiProvider {
    fn name(&self) -> &'static str {
        "vastai"
    }

    fn sizes(&self) -> &[SizeSpec] {
        &VASTAI_SIZES
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
        matches!(state, "stopped" | "exited" | "destroyed" | "offline")
    }

    async fn spawn(&self, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        let query = search_bundles_body(spec);
        let offers_resp = self
            .call(reqwest::Method::POST, "/bundles/", Some(query))
            .await?;
        let offer_id = offers_resp
            .get("offers")
            .and_then(Value::as_array)
            .and_then(|arr| arr.first())
            .and_then(|o| {
                o.get("id").and_then(|x| {
                    x.as_u64()
                        .map(|n| n.to_string())
                        .or_else(|| x.as_str().map(str::to_string))
                })
            })
            .ok_or_else(|| {
                "vastai spawn: no verified GPU offers matched size/price ceiling".to_string()
            })?;
        let disk_gb = vastai_size_spec(&spec.size).map_or(120, |s| s.disk_gb);
        let create_body = create_instance_body(spec, disk_gb);
        let created = self
            .call(
                reqwest::Method::PUT,
                &format!("/asks/{offer_id}/"),
                Some(create_body),
            )
            .await?;
        let id = created
            .get("new_contract")
            .and_then(|x| {
                x.as_u64()
                    .map(|n| n.to_string())
                    .or_else(|| x.as_str().map(str::to_string))
            })
            .ok_or_else(|| "vastai create: missing new_contract id".to_string())?;
        Ok(ProviderMachine {
            provider_id: id,
            state: "loading".into(),
            name: spec.name.clone(),
            deletable_at: None,
        })
    }

    async fn get(&self, provider_id: &str) -> Result<ProviderMachine, String> {
        let v = self
            .call(
                reqwest::Method::GET,
                &format!("/instances/{provider_id}/"),
                None,
            )
            .await?;
        let inner = v.get("instances").unwrap_or(&v);
        instance_from(inner).ok_or_else(|| "vastai get: no instance".to_string())
    }

    async fn list(&self) -> Result<Vec<ProviderMachine>, String> {
        let v = self.call(reqwest::Method::GET, "/instances/", None).await?;
        let mut out = Vec::new();
        if let Some(items) = v.get("instances").and_then(Value::as_array) {
            out.extend(items.iter().filter_map(instance_from));
        }
        Ok(out)
    }

    async fn destroy(&self, provider_id: &str) -> Result<(), String> {
        match self
            .call(
                reqwest::Method::DELETE,
                &format!("/instances/{provider_id}/"),
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
        Ok(())
    }

    async fn write_file(
        &self,
        _provider_id: &str,
        _path: &str,
        _content: &str,
    ) -> Result<(), String> {
        Err("vastai uses onstart bootstrap rather than provider file writes".into())
    }

    async fn exec(
        &self,
        _provider_id: &str,
        _command: &str,
        _timeout_secs: u64,
    ) -> Result<Value, String> {
        Err("vastai uses onstart bootstrap rather than provider exec".into())
    }

    async fn usage(&self, provider_id: &str) -> Result<ProviderUsage, String> {
        let v = self
            .call(
                reqwest::Method::GET,
                &format!("/instances/{provider_id}/"),
                None,
            )
            .await?;
        let inst = v.get("instances").unwrap_or(&v);
        let dph = inst.get("dph_total").and_then(Value::as_f64).unwrap_or(0.0);
        let start = inst.get("start_date").and_then(Value::as_f64);
        let now_s = chrono::Utc::now().timestamp() as f64;
        let secs = start.map(|s| (now_s - s).max(0.0) as u64).unwrap_or(0);
        let status = inst
            .get("actual_status")
            .and_then(Value::as_str)
            .unwrap_or("");
        Ok(ProviderUsage {
            dollars: (secs as f64 / 3600.0) * dph,
            seconds: secs,
            running: status == "running" || status == "loading",
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundle_search_and_instance_create_include_atomic_label_and_ceiling() {
        let spec = SpawnSpec {
            machine_id: "mmgpu1234".into(),
            size: "rtx4090".into(),
            ttl_seconds: 3600,
            image: None,
            name: "orb-managed-mmgpu1234".into(),
            idempotency_key: "orb-managed-mmgpu1234".into(),
            bootstrap_script: Some("#!/usr/bin/env bash\n".into()),
            gpu: None,
            arch: None,
            max_hourly_usd: Some(0.60),
            allow_24h_commitment: false,
        };
        let q = search_bundles_body(&spec);
        assert_eq!(q["gpu_name"]["eq"], "RTX 4090");
        assert_eq!(q["dph_total"]["lte"], 0.60);
        let create = create_instance_body(&spec, 120);
        assert_eq!(create["label"], "orb-managed-mmgpu1234");
        assert!(create["onstart"].as_str().is_some());
    }
}
