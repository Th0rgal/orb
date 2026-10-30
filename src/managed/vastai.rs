//! Vast.ai GPU marketplace implementation of [`super::ManagedProvider`].
//!
//! Vast.ai currently splits its REST surface across two API versions:
//! - `/api/v1/instances/` for listing instances (`GET /api/v0/instances/` is `HTTP 410`).
//! - `/api/v0/` for offer search (`POST /bundles/`), rental (`PUT /asks/{id}/`),
//!   and per-instance inspection/teardown (`GET|DELETE /instances/{id}/`).
//!
//! Searches verified on-demand CUDA offers matching the requested GPU class
//! (`rtx4090`, `a100`, `h100`, `l40s`, or explicit `spec.gpu`) under
//! `max_hourly_usd`, rents with `label: spec.name` (`orb-managed-<id>`) and
//! `onstart` script enrolling `orb-node` over Core's reverse HTTP relay, and
//! destroys via `DELETE /api/v0/instances/{id}/`.

use std::time::Duration;

use async_trait::async_trait;
use serde_json::{json, Value};

use super::{ManagedProvider, ProviderMachine, ProviderUsage, SizeSpec, SpawnSpec};

pub const DEFAULT_API_BASE: &str = "https://cloud.vast.ai/api/v0";

pub const VASTAI_SIZES: [SizeSpec; 4] = [
    SizeSpec {
        size: "rtx4090",
        cpu: 16,
        ram_gb: 64,
        disk_gb: 120,
        usd_per_hour: 0.45,
        gpu: Some("RTX 4090"),
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "l40s",
        cpu: 16,
        ram_gb: 64,
        disk_gb: 160,
        usd_per_hour: 0.95,
        gpu: Some("L40S"),
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "a100",
        cpu: 24,
        ram_gb: 96,
        disk_gb: 200,
        usd_per_hour: 1.35,
        gpu: Some("A100 SXM4"),
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "h100",
        cpu: 24,
        ram_gb: 128,
        disk_gb: 250,
        usd_per_hour: 2.40,
        gpu: Some("H100 SXM"),
        arch: "x86_64",
        min_billing_hours: None,
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
    v0_base: String,
    v1_base: String,
    key: String,
}

impl std::fmt::Debug for VastAiProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VastAiProvider")
            .field("v0_base", &self.v0_base)
            .field("v1_base", &self.v1_base)
            .finish()
    }
}

impl VastAiProvider {
    pub fn new(base: impl Into<String>, key: impl Into<String>) -> Self {
        let trimmed = base.into().trim_end_matches('/').to_string();
        let (v0_base, v1_base) = if let Some(root) = trimmed
            .strip_suffix("/api/v0")
            .or_else(|| trimmed.strip_suffix("/api/v1"))
        {
            (format!("{root}/api/v0"), format!("{root}/api/v1"))
        } else {
            (trimmed.clone(), trimmed)
        };
        Self {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(60))
                .connect_timeout(Duration::from_secs(10))
                .build()
                .unwrap_or_default(),
            v0_base,
            v1_base,
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

    async fn call_base(
        &self,
        base: &str,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, String> {
        let mut req = self
            .http
            .request(method.clone(), format!("{base}{path}"))
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

    async fn call_v0(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, String> {
        self.call_base(&self.v0_base, method, path, body).await
    }

    async fn call_v1(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, String> {
        self.call_base(&self.v1_base, method, path, body).await
    }
}

pub(crate) fn default_max_dph(size: &str) -> f64 {
    vastai_size_spec(size).map_or(2.50, |s| (s.usd_per_hour * 1.6 * 10000.0).round() / 10000.0)
}

pub(crate) fn min_ram_mb_for_gb(ram_gb: u32) -> u32 {
    // Physical Linux hosts report MemTotal ~95-99% of nominal DIMM capacity in MB.
    ram_gb.saturating_mul(960)
}

fn spec_floors(spec: &SpawnSpec) -> (u32, u32, f64) {
    let tier = vastai_size_spec(&spec.size);
    let min_cpu = if spec.cpu > 0 {
        spec.cpu
    } else {
        tier.map_or(1, |s| s.cpu)
    };
    let min_ram_gb = if spec.ram_gb > 0 {
        spec.ram_gb
    } else {
        tier.map_or(1, |s| s.ram_gb)
    };
    let max_dph = spec
        .max_hourly_usd
        .unwrap_or_else(|| default_max_dph(&spec.size));
    (min_cpu, min_ram_gb, max_dph)
}

pub(crate) fn search_bundles_body(spec: &SpawnSpec) -> Value {
    let gpu_name = gpu_model_for_size(&spec.size, spec.gpu.as_deref());
    let (min_cpu, min_ram_gb, max_dph) = spec_floors(spec);
    let min_disk_gb = vastai_size_spec(&spec.size)
        .map_or(120, |s| s.disk_gb)
        .max(40);
    json!({
        "verified": {"eq": true},
        "external": {"eq": false},
        "rentable": {"eq": true},
        "rented": {"eq": false},
        "gpu_name": {"eq": gpu_name},
        "dph_total": {"lte": max_dph},
        "cpu_cores_effective": {"gte": min_cpu},
        "cpu_ram": {"gte": min_ram_mb_for_gb(min_ram_gb)},
        "disk_space": {"gte": min_disk_gb},
        "reliability2": {"gte": 0.98},
        "order": [["dph_total", "asc"]],
        "type": "on-demand",
        "limit": 10
    })
}

pub(crate) fn select_verified_offer(
    offers: &[Value],
    min_cpu: u32,
    min_ram_gb: u32,
    max_dph: f64,
    preferred_offer_id: Option<&str>,
    exclude_offer_ids: &[String],
) -> Option<super::SpawnQuote> {
    let min_ram_mb = f64::from(min_ram_mb_for_gb(min_ram_gb));
    let parse_one = |o: &Value| -> Option<super::SpawnQuote> {
        let offer_id = o.get("id").and_then(|x| {
            x.as_u64()
                .map(|n| n.to_string())
                .or_else(|| x.as_str().map(str::to_string))
        })?;
        if exclude_offer_ids.iter().any(|ex| ex == &offer_id) {
            return None;
        }
        let dph = o.get("dph_total").and_then(Value::as_f64)?;
        if !dph.is_finite() || dph <= 0.0 || dph > max_dph + 1e-9 {
            return None;
        }
        let cpu = o
            .get("cpu_cores_effective")
            .or_else(|| o.get("cpu_cores"))
            .and_then(Value::as_f64)
            .map(|c| c.floor() as u32)?;
        if cpu < min_cpu {
            return None;
        }
        let ram_mb = o.get("cpu_ram").and_then(Value::as_f64)?;
        if !ram_mb.is_finite() || ram_mb < min_ram_mb {
            return None;
        }
        let ram_gb = ((ram_mb / 1024.0).round() as u32).max(1);
        Some(super::SpawnQuote {
            offer_id: Some(offer_id),
            usd_per_hour: ((dph * 10000.0 - 1e-9).ceil()).max(0.0) / 10000.0,
            cpu,
            ram_gb,
        })
    };
    if let Some(pref) = preferred_offer_id {
        if let Some(q) = offers
            .iter()
            .filter_map(parse_one)
            .find(|q| q.offer_id.as_deref() == Some(pref))
        {
            return Some(q);
        }
    }
    offers.iter().find_map(parse_one)
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
    let actual = inst
        .get("actual_status")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let cur = inst
        .get("cur_state")
        .or_else(|| inst.get("intended_status"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let state = match (actual, cur) {
        (Some(a), _) => a,
        // Right after `PUT /asks/{id}/`, Vast.ai sets `cur_state: "running"`
        // while `actual_status` is still `null` and layers are downloading.
        // Never treat desired `"running"` as ready until `actual_status` says so.
        (None, Some(c)) if matches!(c, "stopped" | "exited" | "destroyed" | "offline") => c,
        _ => "loading",
    }
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

    async fn quote_spawn(&self, spec: &SpawnSpec) -> Result<Option<super::SpawnQuote>, String> {
        let (min_cpu, min_ram_gb, max_dph) = spec_floors(spec);
        let query = search_bundles_body(spec);
        let offers_resp = self
            .call_v0(reqwest::Method::POST, "/bundles/", Some(query))
            .await?;
        let offers = offers_resp
            .get("offers")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        select_verified_offer(
            offers,
            min_cpu,
            min_ram_gb,
            max_dph,
            spec.preferred_offer_id.as_deref(),
            &spec.exclude_offer_ids,
        )
        .map(Some)
        .ok_or_else(|| {
            format!(
                "vastai quote: no verified GPU offers matched size '{}' (>={min_cpu} vCPU, >={min_ram_gb} GB RAM, <=${max_dph:.2}/h)",
                spec.size
            )
        })
    }

    async fn spawn(&self, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        let disk_gb = vastai_size_spec(&spec.size).map_or(120, |s| s.disk_gb);
        let create_body = create_instance_body(spec, disk_gb);
        // When `ManagedManager` has already quoted a specific offer and embedded
        // its exact CPU/RAM into `bootstrap_script`, rent ONLY that offer here;
        // if it was sniped, return an error so `ManagedManager` reconciles the
        // replacement offer's CPU/RAM/price and regenerates `bootstrap_script`.
        let created = if let Some(pref_id) =
            spec.preferred_offer_id.as_deref().filter(|s| !s.is_empty())
        {
            self.call_v0(
                reqwest::Method::PUT,
                &format!("/asks/{pref_id}/"),
                Some(create_body),
            )
            .await?
        } else {
            let (min_cpu, min_ram_gb, max_dph) = spec_floors(spec);
            let query = search_bundles_body(spec);
            let offers_resp = self
                .call_v0(reqwest::Method::POST, "/bundles/", Some(query))
                .await?;
            let offers = offers_resp
                .get("offers")
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or(&[]);
            let quote = select_verified_offer(
                offers,
                min_cpu,
                min_ram_gb,
                max_dph,
                None,
                &spec.exclude_offer_ids,
            )
            .ok_or_else(|| {
                format!(
                    "vastai spawn: no verified GPU offers matched size '{}' (>={min_cpu} vCPU, >={min_ram_gb} GB RAM, <=${max_dph:.2}/h)",
                    spec.size
                )
            })?;
            let offer_id = quote.offer_id.unwrap_or_default();
            self.call_v0(
                reqwest::Method::PUT,
                &format!("/asks/{offer_id}/"),
                Some(create_body),
            )
            .await?
        };
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
            .call_v0(
                reqwest::Method::GET,
                &format!("/instances/{provider_id}/"),
                None,
            )
            .await?;
        let inner = v.get("instances").unwrap_or(&v);
        instance_from(inner).ok_or_else(|| "vastai get: no instance".to_string())
    }

    async fn list(&self) -> Result<Vec<ProviderMachine>, String> {
        let mut out = Vec::new();
        let mut seen_tokens = std::collections::HashSet::new();
        let mut next_token: Option<String> = None;
        for _ in 0..10 {
            let path = match &next_token {
                Some(tok) => {
                    let enc: String =
                        url::form_urlencoded::byte_serialize(tok.as_bytes()).collect();
                    format!("/instances/?next_token={enc}")
                }
                None => "/instances/".to_string(),
            };
            let v = self.call_v1(reqwest::Method::GET, &path, None).await?;
            if let Some(items) = v.get("instances").and_then(Value::as_array) {
                out.extend(items.iter().filter_map(instance_from));
            }
            match v
                .get("next_token")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                Some(tok) if seen_tokens.insert(tok.to_string()) => {
                    next_token = Some(tok.to_string());
                }
                _ => break,
            }
        }
        Ok(out)
    }

    async fn destroy(&self, provider_id: &str) -> Result<(), String> {
        match self
            .call_v0(
                reqwest::Method::DELETE,
                &format!("/instances/{provider_id}/"),
                None,
            )
            .await
        {
            Ok(_) => Ok(()),
            // Treat 404 as idempotent ONLY when Vast.ai confirms `no_such_instance`,
            // never on a generic route `"Not found"` 404 (which would leak billing).
            Err(e) if e.contains("HTTP 404") && e.contains("no_such_instance") => Ok(()),
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
            .call_v0(
                reqwest::Method::GET,
                &format!("/instances/{provider_id}/"),
                None,
            )
            .await?;
        let inst = match v.get("instances") {
            Some(Value::Null) => return Err("vastai usage: instance deleted".into()),
            Some(inner) => inner,
            None => &v,
        };
        if !inst.is_object() {
            return Err("vastai usage: no instance".into());
        }
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
            cpu: 16,
            ram_gb: 64,
            ttl_seconds: 3600,
            image: None,
            name: "orb-managed-mmgpu1234".into(),
            idempotency_key: "orb-managed-mmgpu1234".into(),
            bootstrap_script: Some("#!/usr/bin/env bash\n".into()),
            gpu: None,
            arch: None,
            max_hourly_usd: Some(0.60),
            preferred_offer_id: None,
            exclude_offer_ids: Vec::new(),
            allow_24h_commitment: false,
            provisioning_mode: crate::managed::ProvisioningMode::Worker,
        };
        let q = search_bundles_body(&spec);
        assert_eq!(q["gpu_name"]["eq"], "RTX 4090");
        assert_eq!(q["dph_total"]["lte"], 0.60);
        assert_eq!(q["cpu_cores_effective"]["gte"], 16);
        assert_eq!(q["cpu_ram"]["gte"], min_ram_mb_for_gb(64));
        let create = create_instance_body(&spec, 120);
        assert_eq!(create["label"], "orb-managed-mmgpu1234");
        assert!(create["onstart"].as_str().is_some());
    }
}
