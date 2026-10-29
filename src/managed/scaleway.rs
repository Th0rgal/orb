//! Scaleway implementation of [`super::ManagedProvider`] covering both:
//! 1. **Linux & GPU Cloud Instances** (`/instance/v1/zones/{zone}/servers`,
//!    `DEV1-M`, `DEV1-L`, `PRO2-S`, `PRO2-M`, `L4-1-24G`, `H100-1-80G`) —
//!    tagged atomically with `tags: ["orb-managed", spec.name]` and bootstrapped
//!    via cloud-init `user-data` over Core's reverse relay.
//! 2. **Apple Silicon Mac minis** (`/apple-silicon/v1alpha1/zones/fr-par-1/servers`,
//!    `M1-M`, `M2-M`, `M2-PRO`, `M4-M`) — subject to Scaleway's mandatory
//!    **24-hour minimum billing lease** (`deletable_at`). Spawning an Apple
//!    Silicon server requires `spec.allow_24h_commitment == true` and records
//!    `deletable_at` onto `ProviderMachine.deletable_at` so Core's reaper
//!    schedules deferred deletion at `deletable_at` instead of failing `403/409`
//!    during the first 24 hours.

use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde_json::{json, Value};

use super::{ManagedProvider, ProviderMachine, ProviderUsage, SizeSpec, SpawnSpec};

pub const DEFAULT_API_BASE: &str = "https://api.scaleway.com";
const INSTANCE_ZONES: [&str; 3] = ["fr-par-1", "fr-par-2", "nl-ams-1"];
const APPLE_SILICON_ZONES: [&str; 2] = ["fr-par-1", "fr-par-3"];

pub const SCALEWAY_SIZES: [SizeSpec; 8] = [
    SizeSpec {
        size: "DEV1-M",
        cpu: 3,
        ram_gb: 4,
        disk_gb: 40,
        usd_per_hour: 0.032,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "DEV1-L",
        cpu: 4,
        ram_gb: 8,
        disk_gb: 80,
        usd_per_hour: 0.064,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "PRO2-S",
        cpu: 4,
        ram_gb: 16,
        disk_gb: 80,
        usd_per_hour: 0.088,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "PRO2-M",
        cpu: 8,
        ram_gb: 32,
        disk_gb: 160,
        usd_per_hour: 0.175,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "L4-1-24G",
        cpu: 8,
        ram_gb: 45,
        disk_gb: 200,
        usd_per_hour: 0.85,
        gpu: Some("L4 24GB"),
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "H100-1-80G",
        cpu: 24,
        ram_gb: 240,
        disk_gb: 400,
        usd_per_hour: 3.15,
        gpu: Some("H100 80GB"),
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "M2-M",
        cpu: 8,
        ram_gb: 16,
        disk_gb: 256,
        usd_per_hour: 0.12,
        gpu: None,
        arch: "arm64",
        min_billing_hours: Some(24),
    },
    SizeSpec {
        size: "M2-PRO",
        cpu: 10,
        ram_gb: 32,
        disk_gb: 512,
        usd_per_hour: 0.24,
        gpu: None,
        arch: "arm64",
        min_billing_hours: Some(24),
    },
];

/// Linux/GPU sizes capable of running `sandboxed-node` in `worker` mode.
pub const SCALEWAY_WORKER_SIZES: &[SizeSpec] = SCALEWAY_SIZES.split_at(6).0;

pub fn is_apple_silicon_type(size: &str) -> bool {
    let up = size.trim().to_ascii_uppercase();
    up.starts_with("M1-") || up.starts_with("M2-") || up.starts_with("M4-")
}

pub fn normalize_scaleway_size(raw: &str) -> String {
    match raw.trim().to_ascii_lowercase().as_str() {
        "small" => "DEV1-M".into(),
        "default" | "medium" => "DEV1-L".into(),
        "large" => "PRO2-S".into(),
        "xlarge" => "PRO2-M".into(),
        "mac" | "macos" | "m2" => "M2-M".into(),
        "m2-pro" => "M2-PRO".into(),
        _ => raw.trim().to_ascii_uppercase(),
    }
}

pub fn scaleway_size_spec(raw: &str) -> Option<SizeSpec> {
    let norm = normalize_scaleway_size(raw);
    SCALEWAY_SIZES.iter().copied().find(|s| s.size == norm)
}

#[derive(Clone)]
pub struct ScalewayProvider {
    http: reqwest::Client,
    base: String,
    secret_key: String,
    project_id: tokio::sync::OnceCell<String>,
    configured_project_id: Option<String>,
    default_zone: String,
}

impl std::fmt::Debug for ScalewayProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ScalewayProvider")
            .field("base", &self.base)
            .field("default_zone", &self.default_zone)
            .finish()
    }
}

impl ScalewayProvider {
    pub fn new(
        base: impl Into<String>,
        secret_key: impl Into<String>,
        project_id: Option<String>,
    ) -> Self {
        let default_zone = std::env::var("SCALEWAY_DEFAULT_ZONE")
            .ok()
            .filter(|z| !z.trim().is_empty())
            .unwrap_or_else(|| "fr-par-1".into());
        Self {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(60))
                .connect_timeout(Duration::from_secs(10))
                .build()
                .unwrap_or_default(),
            base: base.into().trim_end_matches('/').to_string(),
            secret_key: secret_key.into(),
            project_id: tokio::sync::OnceCell::new(),
            configured_project_id: project_id.filter(|p| !p.trim().is_empty()),
            default_zone,
        }
    }

    pub fn from_env() -> Option<Self> {
        let key = std::env::var("SCALEWAY_SECRET_KEY")
            .or_else(|_| std::env::var("SCW_SECRET_KEY"))
            .ok()
            .filter(|k| !k.trim().is_empty())?;
        std::env::remove_var("SCALEWAY_SECRET_KEY");
        std::env::remove_var("SCW_SECRET_KEY");
        std::env::remove_var("SCALEWAY_KEY_ID");
        std::env::remove_var("SCW_ACCESS_KEY");
        let project_id = std::env::var("SCALEWAY_PROJECT_ID")
            .or_else(|_| std::env::var("SCW_DEFAULT_PROJECT_ID"))
            .ok();
        let base =
            std::env::var("SCALEWAY_API_BASE").unwrap_or_else(|_| DEFAULT_API_BASE.to_string());
        Some(Self::new(base, key.trim(), project_id))
    }

    async fn resolve_project_id(&self) -> Result<String, String> {
        if let Some(pid) = &self.configured_project_id {
            return Ok(pid.clone());
        }
        self.project_id
            .get_or_try_init(|| async {
                let orgs = self
                    .call(reqwest::Method::GET, "/account/v3/organizations", None)
                    .await?;
                let org_id = orgs
                    .get("organizations")
                    .and_then(Value::as_array)
                    .and_then(|arr| arr.first())
                    .and_then(|o| o.get("id"))
                    .and_then(Value::as_str)
                    .ok_or_else(|| "scaleway: no organization found for key".to_string())?;
                let projs = self
                    .call(
                        reqwest::Method::GET,
                        &format!("/account/v3/projects?organization_id={org_id}"),
                        None,
                    )
                    .await?;
                projs
                    .get("projects")
                    .and_then(Value::as_array)
                    .and_then(|arr| {
                        arr.iter()
                            .find(|p| p.get("name").and_then(Value::as_str) == Some("default"))
                            .or_else(|| arr.first())
                    })
                    .and_then(|p| p.get("id"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .ok_or_else(|| "scaleway: no project found for organization".to_string())
            })
            .await
            .cloned()
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
            .header("X-Auth-Token", &self.secret_key);
        if let Some(b) = body {
            req = req.json(&b);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| format!("scaleway {method} {path}: {}", e.without_url()))?;
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(format!(
                "scaleway {method} {path} -> HTTP {} {}",
                status.as_u16(),
                text.chars().take(160).collect::<String>()
            ));
        }
        if text.trim().is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_str(&text).map_err(|e| format!("scaleway {path}: bad JSON: {e}"))
    }

    async fn call_raw_text(&self, path: &str, content: &str) -> Result<(), String> {
        let resp = self
            .http
            .patch(format!("{}{}", self.base, path))
            .header("X-Auth-Token", &self.secret_key)
            .header("Content-Type", "text/plain")
            .body(content.to_string())
            .send()
            .await
            .map_err(|e| format!("scaleway PATCH {path}: {}", e.without_url()))?;
        if !resp.status().is_success() {
            return Err(format!(
                "scaleway PATCH {path} -> HTTP {}",
                resp.status().as_u16()
            ));
        }
        Ok(())
    }
}

/// Provider IDs carry `<kind>:<zone>:<uuid>` so `get`/`destroy`/`usage` target
/// the exact Scaleway regional endpoint without guessing.
fn encode_provider_id(kind: &str, zone: &str, raw_id: &str) -> String {
    format!("{kind}:{zone}:{raw_id}")
}

fn decode_provider_id<'a>(pid: &'a str, fallback_zone: &'a str) -> (&'a str, &'a str, &'a str) {
    let parts: Vec<&str> = pid.splitn(3, ':').collect();
    if parts.len() == 3 {
        (parts[0], parts[1], parts[2])
    } else {
        ("instance", fallback_zone, pid)
    }
}

pub(crate) fn parse_apple_silicon_machine(v: &Value, zone: &str) -> Option<ProviderMachine> {
    let srv = v.get("server").unwrap_or(v);
    let raw_id = srv.get("id")?.as_str()?;
    let deletable_at = srv
        .get("deletable_at")
        .and_then(Value::as_str)
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.with_timezone(&Utc));
    Some(ProviderMachine {
        provider_id: encode_provider_id("mac", zone, raw_id),
        state: srv
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("starting")
            .to_string(),
        name: srv
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        deletable_at,
    })
}

fn parse_instance_machine(v: &Value, zone: &str) -> Option<ProviderMachine> {
    let srv = v.get("server").unwrap_or(v);
    let raw_id = srv.get("id")?.as_str()?;
    Some(ProviderMachine {
        provider_id: encode_provider_id("instance", zone, raw_id),
        state: srv
            .get("state")
            .and_then(Value::as_str)
            .unwrap_or("starting")
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
impl ManagedProvider for ScalewayProvider {
    fn name(&self) -> &'static str {
        "scaleway"
    }

    fn sizes(&self) -> &[SizeSpec] {
        SCALEWAY_WORKER_SIZES
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
        matches!(state, "running" | "ready")
    }

    fn is_stopped_state(&self, state: &str) -> bool {
        matches!(state, "stopped" | "stopped in place" | "stopping")
    }

    async fn spawn(&self, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        let commercial_type = normalize_scaleway_size(&spec.size);
        let zone = &self.default_zone;
        if is_apple_silicon_type(&commercial_type) {
            if spec.provisioning_mode.is_worker() {
                return Err(
                    "Scaleway Apple Silicon Mac minis do not support Linux worker bootstrap (`orb-node`). Pass `provisioning_mode: \"raw\"` alongside `allow_24h_commitment: true`."
                        .into(),
                );
            }
            if !spec.allow_24h_commitment {
                return Err(
                    "Scaleway Apple Silicon Mac minis carry a mandatory 24-hour minimum billing commitment (`deletable_at`). Pass `allow_24h_commitment: true` explicitly to confirm."
                        .into(),
                );
            }
            let project_id = self.resolve_project_id().await?;
            let body = json!({
                "name": spec.name,
                "project_id": project_id,
                "type": commercial_type,
            });
            let v = self
                .call(
                    reqwest::Method::POST,
                    &format!("/apple-silicon/v1alpha1/zones/{zone}/servers"),
                    Some(body),
                )
                .await?;
            return parse_apple_silicon_machine(&v, zone)
                .ok_or_else(|| "scaleway apple-silicon create: missing server id".to_string());
        }
        let project_id = self.resolve_project_id().await?;

        let image = match spec.image.as_deref() {
            Some(img) if !img.is_empty() && img != "orb-node-base" && img != "provider-default" => {
                img
            }
            _ => "ubuntu_noble",
        };
        let create_body = json!({
            "name": spec.name,
            "commercial_type": commercial_type,
            "project": project_id,
            "image": image,
            "routed_ip_enabled": true,
            "tags": ["orb-managed", spec.name.clone(), spec.machine_id.clone()],
        });
        let created = self
            .call(
                reqwest::Method::POST,
                &format!("/instance/v1/zones/{zone}/servers"),
                Some(create_body),
            )
            .await?;
        let machine = parse_instance_machine(&created, zone)
            .ok_or_else(|| "scaleway instance create: missing server id".to_string())?;
        let (_, _, raw_id) = decode_provider_id(&machine.provider_id, zone);
        if let Some(script) = spec.bootstrap_script.as_deref().filter(|s| !s.is_empty()) {
            self.call_raw_text(
                &format!("/instance/v1/zones/{zone}/servers/{raw_id}/user_data/cloud-init"),
                script,
            )
            .await?;
        }
        self.call(
            reqwest::Method::POST,
            &format!("/instance/v1/zones/{zone}/servers/{raw_id}/action"),
            Some(json!({"action": "poweron"})),
        )
        .await?;
        Ok(machine)
    }

    async fn get(&self, provider_id: &str) -> Result<ProviderMachine, String> {
        let (kind, zone, raw_id) = decode_provider_id(provider_id, &self.default_zone);
        if kind == "mac" {
            let v = self
                .call(
                    reqwest::Method::GET,
                    &format!("/apple-silicon/v1alpha1/zones/{zone}/servers/{raw_id}"),
                    None,
                )
                .await?;
            return parse_apple_silicon_machine(&v, zone)
                .ok_or_else(|| "scaleway apple-silicon get: missing server".to_string());
        }
        let v = self
            .call(
                reqwest::Method::GET,
                &format!("/instance/v1/zones/{zone}/servers/{raw_id}"),
                None,
            )
            .await?;
        parse_instance_machine(&v, zone)
            .ok_or_else(|| "scaleway instance get: missing server".to_string())
    }

    async fn list(&self) -> Result<Vec<ProviderMachine>, String> {
        let mut out = Vec::new();
        for zone in INSTANCE_ZONES {
            let v = self
                .call(
                    reqwest::Method::GET,
                    &format!("/instance/v1/zones/{zone}/servers?tags=orb-managed&per_page=100"),
                    None,
                )
                .await?;
            if let Some(items) = v.get("servers").and_then(Value::as_array) {
                out.extend(items.iter().filter_map(|s| parse_instance_machine(s, zone)));
            }
        }
        for zone in APPLE_SILICON_ZONES {
            if let Ok(v) = self
                .call(
                    reqwest::Method::GET,
                    &format!("/apple-silicon/v1alpha1/zones/{zone}/servers?per_page=100"),
                    None,
                )
                .await
            {
                if let Some(items) = v.get("servers").and_then(Value::as_array) {
                    out.extend(
                        items
                            .iter()
                            .filter_map(|s| parse_apple_silicon_machine(s, zone))
                            .filter(|pm| pm.name.starts_with(super::SANDBOX_NAME_PREFIX)),
                    );
                }
            }
        }
        Ok(out)
    }

    async fn destroy(&self, provider_id: &str) -> Result<(), String> {
        let (kind, zone, raw_id) = decode_provider_id(provider_id, &self.default_zone);
        if kind == "mac" {
            return match self
                .call(
                    reqwest::Method::DELETE,
                    &format!("/apple-silicon/v1alpha1/zones/{zone}/servers/{raw_id}"),
                    None,
                )
                .await
            {
                Ok(_) => Ok(()),
                Err(e) if e.contains("HTTP 404") => Ok(()),
                Err(e) => Err(e),
            };
        }
        // For running Scaleway Instances, `terminate` powers off and deletes attached volumes.
        match self
            .call(
                reqwest::Method::POST,
                &format!("/instance/v1/zones/{zone}/servers/{raw_id}/action"),
                Some(json!({"action": "terminate"})),
            )
            .await
        {
            Ok(_) => return Ok(()),
            Err(e) if e.contains("HTTP 404") => return Ok(()),
            Err(_) => {}
        }
        match self
            .call(
                reqwest::Method::DELETE,
                &format!("/instance/v1/zones/{zone}/servers/{raw_id}"),
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
        Err("scaleway uses cloud-init bootstrap rather than provider file writes".into())
    }

    async fn exec(
        &self,
        _provider_id: &str,
        _command: &str,
        _timeout_secs: u64,
    ) -> Result<Value, String> {
        Err("scaleway uses cloud-init bootstrap rather than provider exec".into())
    }

    async fn usage(&self, provider_id: &str) -> Result<ProviderUsage, String> {
        let (kind, zone, raw_id) = decode_provider_id(provider_id, &self.default_zone);
        if kind == "mac" {
            let v = self
                .call(
                    reqwest::Method::GET,
                    &format!("/apple-silicon/v1alpha1/zones/{zone}/servers/{raw_id}"),
                    None,
                )
                .await?;
            let srv = v.get("server").unwrap_or(&v);
            let status = srv.get("status").and_then(Value::as_str).unwrap_or("");
            let stype = srv.get("type").and_then(Value::as_str).unwrap_or("M2-M");
            let rate = scaleway_size_spec(stype).map_or(0.12, |s| s.usd_per_hour);
            let created = srv
                .get("created_at")
                .and_then(Value::as_str)
                .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .map(|d| d.with_timezone(&Utc));
            // Apple Silicon bills minimum 24h upon creation.
            let secs = created
                .map(|c| (Utc::now() - c).num_seconds().max(86_400) as u64)
                .unwrap_or(86_400);
            return Ok(ProviderUsage {
                dollars: (secs as f64 / 3600.0) * rate,
                seconds: secs,
                running: matches!(status, "running" | "starting" | "rebooting"),
            });
        }
        let v = self
            .call(
                reqwest::Method::GET,
                &format!("/instance/v1/zones/{zone}/servers/{raw_id}"),
                None,
            )
            .await?;
        let srv = v.get("server").unwrap_or(&v);
        let state = srv.get("state").and_then(Value::as_str).unwrap_or("");
        let stype = srv
            .get("commercial_type")
            .and_then(Value::as_str)
            .unwrap_or("DEV1-L");
        let rate = scaleway_size_spec(stype).map_or(0.064, |s| s.usd_per_hour);
        let created = srv
            .get("creation_date")
            .and_then(Value::as_str)
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
            .map(|d| d.with_timezone(&Utc));
        let secs = created
            .map(|c| (Utc::now() - c).num_seconds().max(0) as u64)
            .unwrap_or(0);
        Ok(ProviderUsage {
            dollars: (secs as f64 / 3600.0) * rate,
            seconds: secs,
            running: matches!(state, "running" | "starting"),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_apple_silicon_deletable_at_and_encodes_zone() {
        let sample = json!({
            "id": "abc-123",
            "name": "orb-managed-mmmac001",
            "status": "running",
            "deletable_at": "2026-10-30T12:00:00Z"
        });
        let pm = parse_apple_silicon_machine(&sample, "fr-par-1").unwrap();
        assert_eq!(pm.provider_id, "mac:fr-par-1:abc-123");
        assert_eq!(pm.state, "running");
        assert!(pm.deletable_at.is_some());
        assert_eq!(
            decode_provider_id(&pm.provider_id, "fr-par-1"),
            ("mac", "fr-par-1", "abc-123")
        );
    }

    #[test]
    fn recognizes_apple_silicon_commercial_types() {
        assert!(is_apple_silicon_type("M2-M"));
        assert!(is_apple_silicon_type("m2-pro"));
        assert!(!is_apple_silicon_type("PRO2-S"));
        assert!(!is_apple_silicon_type("H100-1-80G"));
    }
}
