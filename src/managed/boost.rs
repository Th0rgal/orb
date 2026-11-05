//! `boost.ci` Cloud Hypervisor microVM provider (`https://api.boost.ci/v1`).
//!
//! Boots isolated Ubuntu 26.04 microVMs with optional CoW `.olean` warm
//! overlays (`repo` / `base_key`), CoW disk snapshots (`snapshot_id`), and
//! live pool/quota preflight via `GET /v1/vms/capabilities`.

use std::collections::HashMap;
use std::sync::RwLock;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use base64::Engine as _;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

use super::{
    AvailabilityStatus, ManagedProvider, ProviderAvailability, ProviderMachine, ProviderSnapshot,
    ProviderUsage, SizeSpec, SpawnQuote, SpawnSpec,
};

pub const DEFAULT_API_BASE: &str = "https://api.boost.ci/v1";
const MAX_RAW_HTTP_BYTES: usize = 256 * 1024;
const CAPABILITIES_CACHE_TTL: Duration = Duration::from_secs(20);

/// `boost.ci` runner profiles priced on the `boat.dev` curve.
pub const BOOST_SIZES: [SizeSpec; 7] = [
    SizeSpec {
        size: "boost-2vcpu-ubuntu-2604",
        cpu: 2,
        ram_gb: 8,
        disk_gb: 50,
        usd_per_hour: 0.018,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "boost-4vcpu-ubuntu-2604",
        cpu: 4,
        ram_gb: 16,
        disk_gb: 75,
        usd_per_hour: 0.036,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "boost-8vcpu-ubuntu-2604",
        cpu: 8,
        ram_gb: 32,
        disk_gb: 100,
        usd_per_hour: 0.072,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "boost-16vcpu-ubuntu-2604",
        cpu: 16,
        ram_gb: 64,
        disk_gb: 150,
        usd_per_hour: 0.20,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "boost-24vcpu-ubuntu-2604",
        cpu: 24,
        ram_gb: 96,
        disk_gb: 175,
        usd_per_hour: 0.30,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "boost-32vcpu-96gb",
        cpu: 32,
        ram_gb: 96,
        disk_gb: 200,
        usd_per_hour: 0.40,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "boost-32vcpu-ubuntu-2604",
        cpu: 32,
        ram_gb: 128,
        disk_gb: 200,
        usd_per_hour: 0.45,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
];

pub fn boost_size_spec(name: &str) -> Option<SizeSpec> {
    let canonical = match name.trim().to_ascii_lowercase().as_str() {
        "small" | "boost-2vcpu" => "boost-2vcpu-ubuntu-2604",
        "default" | "medium" | "boost-4vcpu" => "boost-4vcpu-ubuntu-2604",
        "large" | "boost-8vcpu" => "boost-8vcpu-ubuntu-2604",
        "xlarge" | "boost-16vcpu" => "boost-16vcpu-ubuntu-2604",
        "boost-24vcpu" => "boost-24vcpu-ubuntu-2604",
        "2xlarge" => "boost-32vcpu-96gb",
        "3xlarge" | "boost-32vcpu" | "boost-32vcpu-vanilla" => "boost-32vcpu-ubuntu-2604",
        other => {
            return BOOST_SIZES.iter().copied().find(|s| s.size == other);
        }
    };
    BOOST_SIZES.iter().copied().find(|s| s.size == canonical)
}

pub fn normalize_api_base(raw: &str) -> String {
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.ends_with("/v1") || trimmed.ends_with("/api/v1") {
        trimmed.to_string()
    } else {
        format!("{trimmed}/v1")
    }
}

pub fn is_ready_state(state: &str) -> bool {
    state == "running"
}

pub fn is_stopped_state(state: &str) -> bool {
    matches!(state, "stopped" | "failed" | "reaped" | "deleted" | "error")
}

fn map_vm_state(raw_status: &str) -> String {
    match raw_status.trim().to_ascii_lowercase().as_str() {
        "queued" | "provisioning" | "booting" => "provisioning".into(),
        "running" => "running".into(),
        "stopping" | "deleting" => "destroying".into(),
        "stopped" | "deleted" | "reaped" => "stopped".into(),
        "failed" | "error" => "error".into(),
        other => other.to_string(),
    }
}

#[derive(Debug, Clone, Deserialize)]
struct CapabilitiesResponse {
    #[serde(default)]
    quota: Option<CapabilitiesQuota>,
    pool: CapabilitiesPool,
    effective: CapabilitiesEffective,
    #[serde(default)]
    profiles: Vec<CapabilitiesProfile>,
}

#[derive(Debug, Clone, Deserialize)]
struct CapabilitiesQuota {
    #[serde(default)]
    active_vms: Option<u32>,
}

#[derive(Debug, Clone, Deserialize)]
struct CapabilitiesPool {
    online_engines: u32,
}

#[derive(Debug, Clone, Deserialize)]
struct CapabilitiesEffective {
    schedulable_vcpus: u32,
    schedulable_memory_mib: u32,
    largest_bootable_vm: CapabilitiesVmSlot,
    #[serde(default)]
    queued_spawns: u32,
}

#[derive(Debug, Clone, Deserialize)]
struct CapabilitiesVmSlot {
    vcpus: u32,
    memory_mib: u32,
}

#[derive(Debug, Clone, Deserialize)]
struct CapabilitiesProfile {
    runner_label: String,
    vcpus: u32,
    default_memory_mib: u32,
    max_launchable_now: u32,
    #[serde(default)]
    blocking_reason: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct VmEnvelope {
    vm: VmRecord,
}

#[derive(Debug, Clone, Deserialize)]
struct VmListResponse {
    #[serde(default)]
    vms: Vec<VmRecord>,
}

#[derive(Debug, Clone, Deserialize)]
struct VmRecord {
    id: String,
    #[serde(default)]
    name: Option<String>,
    runner_label: String,
    #[serde(default)]
    vcpus: Option<u32>,
    #[serde(default)]
    memory_mib: Option<u32>,
    status: String,
    #[serde(default)]
    created_at: Option<DateTime<Utc>>,
    #[serde(default)]
    started_at: Option<DateTime<Utc>>,
    #[serde(default)]
    stopped_at: Option<DateTime<Utc>>,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct ExecResponse {
    #[serde(default)]
    ok: Option<bool>,
    #[serde(default)]
    exit_code: Option<i64>,
    #[serde(default)]
    stdout_b64: Option<String>,
    #[serde(default)]
    stderr_b64: Option<String>,
    #[serde(default)]
    timed_out: bool,
    #[serde(default)]
    stdout_truncated: bool,
    #[serde(default)]
    stderr_truncated: bool,
    #[serde(default)]
    elapsed_ms: Option<u64>,
    #[serde(default)]
    duration_ms: Option<u64>,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct SnapshotEnvelope {
    snapshot: SnapshotRecord,
}

#[derive(Debug, Clone, Deserialize)]
struct SnapshotListResponse {
    #[serde(default)]
    snapshots: Vec<SnapshotRecord>,
}

#[derive(Debug, Clone, Deserialize)]
struct SnapshotRecord {
    id: String,
    #[serde(default)]
    label: Option<String>,
    status: String,
    #[serde(default)]
    size_bytes: Option<u64>,
}

#[derive(Debug, Clone)]
struct CachedCapabilities {
    fetched_at: Instant,
    availability: ProviderAvailability,
}

#[derive(Debug, Serialize)]
struct CreateVmBody<'a> {
    name: &'a str,
    runner_label: &'a str,
    ttl_secs: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    memory_mib: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    lean_mode: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    repo: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    base_key: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    snapshot_id: Option<&'a str>,
}

pub struct BoostProvider {
    base_url: String,
    api_key: String,
    workspace_id: Option<String>,
    http: reqwest::Client,
    capabilities_cache: RwLock<Option<CachedCapabilities>>,
    snapshot_ids: RwLock<HashMap<String, String>>,
}

impl BoostProvider {
    pub fn new(base_url: impl Into<String>, api_key: impl Into<String>) -> Self {
        Self::with_workspace(base_url, api_key, None)
    }

    pub fn with_workspace(
        base_url: impl Into<String>,
        api_key: impl Into<String>,
        workspace_id: Option<String>,
    ) -> Self {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(90))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self {
            base_url: normalize_api_base(&base_url.into()),
            api_key: api_key.into().trim().to_string(),
            workspace_id: workspace_id
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
            http,
            capabilities_cache: RwLock::new(None),
            snapshot_ids: RwLock::new(HashMap::new()),
        }
    }

    pub fn configured_workspace_id(&self) -> Option<&str> {
        self.workspace_id.as_deref()
    }

    #[cfg(test)]
    pub(crate) fn seed_availability(&self, availability: ProviderAvailability) {
        if let Ok(mut slot) = self.capabilities_cache.write() {
            *slot = Some(CachedCapabilities {
                fetched_at: Instant::now(),
                availability,
            });
        }
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base_url, path)
    }

    fn req(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        let mut builder = self
            .http
            .request(method, self.url(path))
            .bearer_auth(&self.api_key);
        if let Some(ws) = &self.workspace_id {
            builder = builder.header("X-Boost-Workspace-Id", ws);
        }
        builder
    }

    fn invalidate_capabilities_cache(&self) {
        if let Ok(mut slot) = self.capabilities_cache.write() {
            *slot = None;
        }
    }

    async fn send_json<T: serde::de::DeserializeOwned>(
        &self,
        label: &str,
        req: reqwest::RequestBuilder,
    ) -> Result<T, String> {
        let resp = req.send().await.map_err(|e| format!("{label}: {e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("{label}: read body: {e}"))?;
        if !status.is_success() {
            return Err(format_error(label, status, &text));
        }
        serde_json::from_str::<T>(&text).map_err(|e| {
            format!(
                "{label}: invalid JSON ({e}): {}",
                truncate_chars(&text, 240)
            )
        })
    }

    async fn send_bounded_json(
        &self,
        label: &str,
        req: reqwest::RequestBuilder,
    ) -> Result<Value, String> {
        let mut resp = req.send().await.map_err(|e| format!("{label}: {e}"))?;
        let status = resp.status();
        let mut body = Vec::new();
        while let Some(chunk) = resp
            .chunk()
            .await
            .map_err(|e| format!("{label}: read chunk: {e}"))?
        {
            if body.len().saturating_add(chunk.len()) > MAX_RAW_HTTP_BYTES {
                return Err(format!("{label}: response exceeds {MAX_RAW_HTTP_BYTES}B"));
            }
            body.extend_from_slice(&chunk);
        }
        if !status.is_success() {
            let snippet = String::from_utf8_lossy(&body);
            return Err(format_error(label, status, &snippet));
        }
        if body.is_empty() {
            return Ok(json!({}));
        }
        serde_json::from_slice(&body).map_err(|e| format!("{label}: invalid JSON ({e})"))
    }

    async fn fetch_capabilities(
        &self,
        repo: Option<&str>,
        base_key: Option<&str>,
        snapshot_id: Option<&str>,
    ) -> Result<CapabilitiesResponse, String> {
        let mut query: Vec<(&str, &str)> = Vec::new();
        if let Some(s) = snapshot_id.filter(|s| !s.is_empty()) {
            query.push(("snapshot_id", s));
        } else if let Some(b) = base_key.filter(|s| !s.is_empty()) {
            query.push(("base_key", b));
        } else if let Some(r) = repo.filter(|s| !s.is_empty()) {
            query.push(("repo", r));
        }
        let mut req = self.req(reqwest::Method::GET, "/vms/capabilities");
        if !query.is_empty() {
            req = req.query(&query);
        }
        self.send_json("GET /vms/capabilities", req).await
    }

    fn derive_availability(caps: &CapabilitiesResponse) -> ProviderAvailability {
        let any_launchable = caps.profiles.iter().any(|p| p.max_launchable_now > 0);
        let all_launchable =
            !caps.profiles.is_empty() && caps.profiles.iter().all(|p| p.max_launchable_now > 0);
        let primary_blocker = || -> Option<String> {
            if caps.pool.online_engines == 0 {
                return Some("no_online_engines".into());
            }
            // Prefer quota/pool blockers reported on the flagship 32vcpu or largest blocked profile.
            caps.profiles
                .iter()
                .rev()
                .filter(|p| p.max_launchable_now == 0)
                .find_map(|p| p.blocking_reason.clone())
        };
        let (status, reason) = if caps.pool.online_engines == 0
            || caps.effective.largest_bootable_vm.vcpus < 2
            || (!caps.profiles.is_empty() && !any_launchable)
        {
            (
                AvailabilityStatus::Saturated,
                primary_blocker().or_else(|| Some("at_capacity".into())),
            )
        } else if !all_launchable {
            (AvailabilityStatus::Degraded, primary_blocker())
        } else {
            (AvailabilityStatus::Available, None)
        };
        ProviderAvailability {
            status,
            reason,
            schedulable_vcpus: Some(caps.effective.schedulable_vcpus),
            schedulable_memory_mib: Some(caps.effective.schedulable_memory_mib),
            largest_bootable_vcpus: Some(caps.effective.largest_bootable_vm.vcpus),
            largest_bootable_memory_mib: Some(caps.effective.largest_bootable_vm.memory_mib),
            online_engines: Some(caps.pool.online_engines),
            active_vms: caps.quota.as_ref().and_then(|q| q.active_vms),
            queued_spawns: Some(caps.effective.queued_spawns),
            checked_at: Utc::now(),
        }
    }

    async fn resolve_snapshot_id(&self, name_or_id: &str) -> Result<String, String> {
        let trimmed = name_or_id.trim();
        if Uuid::parse_str(trimmed).is_ok() {
            return Ok(trimmed.to_string());
        }
        if let Some(cached) = self
            .snapshot_ids
            .read()
            .ok()
            .and_then(|m| m.get(trimmed).cloned())
        {
            return Ok(cached);
        }
        let list: SnapshotListResponse = self
            .send_json(
                "GET /vms/snapshots",
                self.req(reqwest::Method::GET, "/vms/snapshots"),
            )
            .await?;
        let found = list
            .snapshots
            .into_iter()
            .find(|s| s.label.as_deref() == Some(trimmed) || s.id == trimmed)
            .ok_or_else(|| format!("snapshot '{trimmed}' not found on boost.ci"))?;
        if let Ok(mut cache) = self.snapshot_ids.write() {
            cache.insert(trimmed.to_string(), found.id.clone());
        }
        Ok(found.id)
    }

    fn snapshot_source_from_spec(spec: &SpawnSpec) -> Option<&str> {
        spec.image
            .as_deref()
            .map(str::trim)
            .filter(|img| img.starts_with("orb-snap-"))
    }

    fn decode_exec_value(resp: ExecResponse) -> Value {
        let stdout = resp
            .stdout_b64
            .as_deref()
            .and_then(|b64| {
                base64::engine::general_purpose::STANDARD
                    .decode(b64.trim())
                    .ok()
            })
            .map(|b| String::from_utf8_lossy(&b).into_owned())
            .unwrap_or_default();
        let mut stderr = resp
            .stderr_b64
            .as_deref()
            .and_then(|b64| {
                base64::engine::general_purpose::STANDARD
                    .decode(b64.trim())
                    .ok()
            })
            .map(|b| String::from_utf8_lossy(&b).into_owned())
            .unwrap_or_default();
        let timed_out = resp.timed_out
            || resp
                .error
                .as_deref()
                .is_some_and(|e| e.to_ascii_lowercase().contains("timed out"));
        let exit_code = match resp.exit_code {
            Some(0) if timed_out => 124,
            Some(0) if resp.ok == Some(false) => 1,
            Some(code) => code,
            None if timed_out => 124,
            None if resp.ok == Some(false) => 1,
            None => 0,
        };
        if stderr.is_empty() {
            if let Some(err) = resp.error.filter(|s| !s.trim().is_empty()) {
                stderr = err;
            }
        }
        json!({
            "exit_code": exit_code,
            "stdout": stdout,
            "stderr": stderr,
            "timed_out": timed_out,
            "truncated": resp.stdout_truncated || resp.stderr_truncated,
            "duration_ms": resp.elapsed_ms.or(resp.duration_ms).unwrap_or(0),
        })
    }

    fn file_mode_for_path(path: &str) -> u32 {
        if path.ends_with("enroll.env")
            || path.contains("/.boost-env")
            || path == "/etc/orb/boost-env"
        {
            0o600
        } else if path.ends_with(".sh") {
            0o755
        } else {
            0o644
        }
    }
}

fn truncate_chars(s: &str, max: usize) -> String {
    let mut out = String::new();
    for (i, ch) in s.chars().enumerate() {
        if i >= max {
            out.push('…');
            break;
        }
        out.push(ch);
    }
    out
}

fn format_error(label: &str, status: reqwest::StatusCode, body: &str) -> String {
    let detail = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| {
            if let Some(err_obj) = v.get("error").and_then(Value::as_object) {
                let code = err_obj.get("code").and_then(Value::as_str);
                let msg = err_obj.get("message").and_then(Value::as_str);
                match (code, msg) {
                    (Some(c), Some(m)) => return Some(format!("{c}: {m}")),
                    (None, Some(m)) => return Some(m.to_string()),
                    (Some(c), None) => return Some(c.to_string()),
                    (None, None) => {}
                }
            }
            let code = v.get("code").and_then(Value::as_str);
            let msg = v
                .get("error")
                .and_then(Value::as_str)
                .or_else(|| v.get("message").and_then(Value::as_str));
            match (code, msg) {
                (Some(c), Some(m)) => Some(format!("{c}: {m}")),
                (None, Some(m)) => Some(m.to_string()),
                (Some(c), None) => Some(c.to_string()),
                (None, None) => None,
            }
        })
        .unwrap_or_else(|| truncate_chars(body.trim(), 240));
    format!("{label} -> HTTP {}: {detail}", status.as_u16())
}

fn normalize_boost_lean_mode(raw: Option<&str>) -> Option<&'static str> {
    match raw.map(str::trim).filter(|s| !s.is_empty()) {
        None => None,
        Some(m) if m.eq_ignore_ascii_case("auto") => Some("auto"),
        Some(m) if m.eq_ignore_ascii_case("cache-only") || m.eq_ignore_ascii_case("cache_only") => {
            Some("cache-only")
        }
        Some(m) if m.eq_ignore_ascii_case("off") || m.eq_ignore_ascii_case("none") => Some("off"),
        Some(_) => None,
    }
}

/// Detect upstream `boost.ci` HTTP 403/404 rejections specific to an inaccessible
/// or unconnected `repo=` warm overlay (as opposed to workspace quota or auth errors).
pub(crate) fn is_repo_overlay_forbidden_or_unavailable(err: &str) -> bool {
    let lower = err.to_ascii_lowercase();
    if lower.contains("quota") && lower.contains("exceed") {
        return false;
    }
    let is_403 = lower.contains("http 403") || lower.contains("forbidden");
    if is_403 {
        return true;
    }
    let is_404 = lower.contains("http 404") || lower.contains("not_found");
    is_404
        && (lower.contains("repository")
            || lower.contains("overlay")
            || lower.contains("not connected")
            || lower.contains("repo"))
}

#[async_trait]
impl ManagedProvider for BoostProvider {
    fn name(&self) -> &'static str {
        "boost"
    }

    fn sizes(&self) -> &[SizeSpec] {
        &BOOST_SIZES
    }

    fn supports_free_stop(&self) -> bool {
        false
    }

    fn supports_snapshots(&self) -> bool {
        true
    }

    fn bootstraps_worker_via_exec(&self) -> bool {
        true
    }

    fn is_ready_state(&self, state: &str) -> bool {
        is_ready_state(state)
    }

    fn is_stopped_state(&self, state: &str) -> bool {
        is_stopped_state(state)
    }

    fn cached_availability(&self) -> Option<ProviderAvailability> {
        self.capabilities_cache
            .read()
            .ok()
            .and_then(|c| c.as_ref().map(|entry| entry.availability.clone()))
    }

    async fn refresh_availability(&self) -> Result<ProviderAvailability, String> {
        if let Some(fresh) = self.capabilities_cache.read().ok().and_then(|c| {
            c.as_ref()
                .filter(|entry| entry.fetched_at.elapsed() < CAPABILITIES_CACHE_TTL)
                .map(|entry| entry.availability.clone())
        }) {
            return Ok(fresh);
        }
        let caps = self.fetch_capabilities(None, None, None).await?;
        let availability = Self::derive_availability(&caps);
        if let Ok(mut slot) = self.capabilities_cache.write() {
            *slot = Some(CachedCapabilities {
                fetched_at: Instant::now(),
                availability: availability.clone(),
            });
        }
        Ok(availability)
    }

    async fn quote_spawn(&self, spec: &SpawnSpec) -> Result<Option<SpawnQuote>, String> {
        let size_spec = boost_size_spec(&spec.size)
            .ok_or_else(|| format!("unknown boost.ci runner_label '{}'", spec.size))?;
        let resolved_snap = match Self::snapshot_source_from_spec(spec) {
            Some(raw) => Some(self.resolve_snapshot_id(raw).await?),
            None => None,
        };
        let effective_mode = normalize_boost_lean_mode(spec.lean_mode.as_deref());
        let caps = match self
            .fetch_capabilities(
                spec.repo.as_deref(),
                spec.base_key.as_deref(),
                resolved_snap.as_deref(),
            )
            .await
        {
            Ok(caps) => caps,
            Err(err)
                if spec.repo.is_some()
                    && spec.base_key.is_none()
                    && effective_mode != Some("cache-only")
                    && is_repo_overlay_forbidden_or_unavailable(&err) =>
            {
                tracing::warn!(
                    repo = ?spec.repo,
                    error = %err,
                    "boost.ci capabilities rejected repo= overlay; retrying quote with lean_mode=off"
                );
                self.fetch_capabilities(None, None, resolved_snap.as_deref())
                    .await?
            }
            Err(err) => return Err(err),
        };
        if resolved_snap.is_none() && spec.repo.is_none() && spec.base_key.is_none() {
            let availability = Self::derive_availability(&caps);
            if let Ok(mut slot) = self.capabilities_cache.write() {
                *slot = Some(CachedCapabilities {
                    fetched_at: Instant::now(),
                    availability,
                });
            }
        }
        let profile = caps
            .profiles
            .iter()
            .find(|p| p.runner_label == size_spec.size);
        let requested_mib = spec
            .memory_mib
            .unwrap_or_else(|| profile.map_or(size_spec.ram_gb * 1024, |p| p.default_memory_mib));
        let requested_vcpus = profile.map_or(size_spec.cpu, |p| p.vcpus);

        let blocked_by_slot = caps.pool.online_engines == 0
            || requested_vcpus > caps.effective.schedulable_vcpus
            || requested_mib > caps.effective.schedulable_memory_mib
            || requested_vcpus > caps.effective.largest_bootable_vm.vcpus
            || requested_mib > caps.effective.largest_bootable_vm.memory_mib
            || (spec.memory_mib.is_none() && profile.is_some_and(|p| p.max_launchable_now == 0));

        if blocked_by_slot {
            let reason = if caps.pool.online_engines == 0 {
                "no_online_engines".to_string()
            } else if let Some(r) = profile.and_then(|p| p.blocking_reason.clone()) {
                r
            } else if requested_vcpus > caps.effective.schedulable_vcpus {
                "quota_or_pool_vcpus".into()
            } else {
                "pool_memory".into()
            };
            let max_vcpus = caps.effective.largest_bootable_vm.vcpus;
            let max_gib = caps.effective.largest_bootable_vm.memory_mib / 1024;
            return Err(format!(
                "provider_at_capacity ({reason}): boost.ci cannot launch {} ({} vCPU / {} GiB) right now; largest bootable VM is {} vCPU / {} GiB",
                size_spec.size,
                requested_vcpus,
                requested_mib / 1024,
                max_vcpus,
                max_gib,
            ));
        }

        if let Some(ceil) = spec.max_hourly_usd {
            if size_spec.usd_per_hour > ceil + 1e-9 {
                return Err(format!(
                    "boost.ci profile '{}' costs ${:.3}/h, above max_hourly_usd ${ceil:.3}/h",
                    size_spec.size, size_spec.usd_per_hour
                ));
            }
        }

        Ok(Some(SpawnQuote {
            offer_id: None,
            usd_per_hour: size_spec.usd_per_hour,
            cpu: requested_vcpus,
            ram_gb: requested_mib.div_ceil(1024),
        }))
    }

    async fn spawn(&self, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        let size_spec = boost_size_spec(&spec.size)
            .ok_or_else(|| format!("unknown boost.ci runner_label '{}'", spec.size))?;
        let snapshot_id = match Self::snapshot_source_from_spec(spec) {
            Some(raw) => Some(self.resolve_snapshot_id(raw).await?),
            None => None,
        };
        let requested_raw_vanilla = spec
            .size
            .trim()
            .eq_ignore_ascii_case("boost-32vcpu-vanilla");
        let lean_mode: Option<&str> = if requested_raw_vanilla {
            Some("off")
        } else {
            normalize_boost_lean_mode(spec.lean_mode.as_deref()).or(spec.lean_mode.as_deref())
        };
        let (repo, base_key) = if snapshot_id.is_some() {
            (None, None)
        } else if spec.base_key.is_some() {
            (None, spec.base_key.as_deref())
        } else {
            (spec.repo.as_deref(), None)
        };
        let body = CreateVmBody {
            name: &spec.name,
            runner_label: size_spec.size,
            ttl_secs: spec.ttl_seconds.clamp(60, 86_400),
            memory_mib: spec.memory_mib,
            lean_mode,
            repo,
            base_key,
            snapshot_id: snapshot_id.as_deref(),
        };
        let mut req = self.req(reqwest::Method::POST, "/vms").json(&body);
        if !spec.idempotency_key.is_empty() {
            req = req.header("Idempotency-Key", &spec.idempotency_key);
        }
        let created_res: Result<VmEnvelope, String> = self.send_json("POST /vms", req).await;
        self.invalidate_capabilities_cache();
        let mut warnings = Vec::new();
        let mut effective_lean_mode: Option<String> = None;
        let mut effective_repo: Option<Option<String>> = None;
        let vm = match created_res {
            Ok(env) => env.vm,
            Err(err)
                if repo.is_some()
                    && base_key.is_none()
                    && lean_mode != Some("cache-only")
                    && is_repo_overlay_forbidden_or_unavailable(&err) =>
            {
                let rejected_repo = repo.unwrap_or_default();
                let warning = format!(
                    "boost_repo_overlay_unavailable: upstream boost.ci rejected warm repo overlay '{rejected_repo}' ({err}); auto-fell back to lean_mode=\"off\" without prewarmed overlay"
                );
                tracing::warn!(repo = %rejected_repo, error = %err, "boost.ci POST /vms rejected repo= overlay; retrying with lean_mode=off");
                let fallback_body = CreateVmBody {
                    name: &spec.name,
                    runner_label: size_spec.size,
                    ttl_secs: spec.ttl_seconds.clamp(60, 86_400),
                    memory_mib: spec.memory_mib,
                    lean_mode: Some("off"),
                    repo: None,
                    base_key: None,
                    snapshot_id: snapshot_id.as_deref(),
                };
                let mut fallback_req = self.req(reqwest::Method::POST, "/vms").json(&fallback_body);
                if !spec.idempotency_key.is_empty() {
                    fallback_req = fallback_req.header(
                        "Idempotency-Key",
                        format!("{}-lean-off", spec.idempotency_key),
                    );
                }
                let fallback_res: Result<VmEnvelope, String> = self
                    .send_json("POST /vms (lean_mode=off fallback)", fallback_req)
                    .await;
                self.invalidate_capabilities_cache();
                match fallback_res {
                    Ok(env) => {
                        warnings.push(warning);
                        effective_lean_mode = Some("off".into());
                        effective_repo = Some(None);
                        env.vm
                    }
                    Err(fb_err) => {
                        if let Ok(existing) = self.list().await {
                            if let Some(mut found) = existing
                                .into_iter()
                                .find(|pm| pm.name == spec.name && !is_stopped_state(&pm.state))
                            {
                                found.warnings.push(warning);
                                found.effective_lean_mode = Some("off".into());
                                found.effective_repo = Some(None);
                                return Ok(found);
                            }
                        }
                        return Err(format!(
                            "{err}; fallback with lean_mode=off also failed: {fb_err}"
                        ));
                    }
                }
            }
            Err(err) => {
                // Reconcile by unique VM name if the response was lost mid-flight.
                if let Ok(existing) = self.list().await {
                    if let Some(found) = existing
                        .into_iter()
                        .find(|pm| pm.name == spec.name && !is_stopped_state(&pm.state))
                    {
                        return Ok(found);
                    }
                }
                return Err(err);
            }
        };
        Ok(ProviderMachine {
            provider_id: vm.id,
            state: map_vm_state(&vm.status),
            name: vm.name.unwrap_or_default(),
            deletable_at: None,
            warnings,
            effective_lean_mode,
            effective_repo,
        })
    }

    async fn get(&self, provider_id: &str) -> Result<ProviderMachine, String> {
        let env: VmEnvelope = self
            .send_json(
                "GET /vms/{id}",
                self.req(reqwest::Method::GET, &format!("/vms/{provider_id}")),
            )
            .await?;
        let state = map_vm_state(&env.vm.status);
        if state == "error" {
            if let Some(detail) = env.vm.error.as_deref().filter(|s| !s.is_empty()) {
                tracing::warn!(
                    provider_id = %provider_id,
                    detail = %truncate_chars(detail, 240),
                    "boost.ci VM entered error state"
                );
            }
        }
        Ok(ProviderMachine {
            provider_id: env.vm.id,
            state,
            name: env.vm.name.unwrap_or_default(),
            deletable_at: None,
            ..Default::default()
        })
    }

    async fn list(&self) -> Result<Vec<ProviderMachine>, String> {
        let resp: VmListResponse = self
            .send_json("GET /vms", self.req(reqwest::Method::GET, "/vms"))
            .await?;
        Ok(resp
            .vms
            .into_iter()
            .map(|vm| ProviderMachine {
                provider_id: vm.id,
                state: map_vm_state(&vm.status),
                name: vm.name.unwrap_or_default(),
                deletable_at: None,
                ..Default::default()
            })
            .collect())
    }

    async fn destroy(&self, provider_id: &str) -> Result<(), String> {
        let resp = self
            .req(reqwest::Method::DELETE, &format!("/vms/{provider_id}"))
            .send()
            .await
            .map_err(|e| format!("DELETE /vms/{provider_id}: {e}"))?;
        let status = resp.status();
        self.invalidate_capabilities_cache();
        if status.is_success() || status == reqwest::StatusCode::NOT_FOUND {
            return Ok(());
        }
        let body = resp.text().await.unwrap_or_default();
        Err(format_error("DELETE /vms/{id}", status, &body))
    }

    async fn extend(&self, _provider_id: &str, _ttl_seconds: u64) -> Result<(), String> {
        Err("boost.ci sets VM ttl_secs at boot (up to 86400s / 24h) and does not support live TTL extension".into())
    }

    async fn write_file(&self, provider_id: &str, path: &str, content: &str) -> Result<(), String> {
        let payload = json!({
            "path": path,
            "content_b64": base64::engine::general_purpose::STANDARD.encode(content.as_bytes()),
            "mode": Self::file_mode_for_path(path),
        });
        let resp: ExecResponse = self
            .send_json(
                "PUT /vms/{id}/files",
                self.req(reqwest::Method::PUT, &format!("/vms/{provider_id}/files"))
                    .timeout(Duration::from_secs(125))
                    .json(&payload),
            )
            .await?;
        if resp.ok == Some(false) {
            return Err(format!(
                "PUT /vms/{{id}}/files: {}",
                resp.error.as_deref().unwrap_or("guest file write failed")
            ));
        }
        Ok(())
    }

    async fn exec(
        &self,
        provider_id: &str,
        command: &str,
        timeout_secs: u64,
    ) -> Result<Value, String> {
        let clamped_timeout = timeout_secs.clamp(1, 600);
        let http_timeout_secs = (clamped_timeout + 35).max(125);
        let payload = json!({
            "command": ["bash", "-lc", command],
            "timeout_secs": clamped_timeout,
            "as_root": true,
        });
        let resp: ExecResponse = self
            .send_json(
                "POST /vms/{id}/exec",
                self.req(reqwest::Method::POST, &format!("/vms/{provider_id}/exec"))
                    .timeout(Duration::from_secs(http_timeout_secs))
                    .json(&payload),
            )
            .await?;
        Ok(Self::decode_exec_value(resp))
    }

    async fn raw_exec(
        &self,
        provider_id: &str,
        command: &str,
        timeout_secs: u64,
    ) -> Result<Value, String> {
        let clamped_timeout = timeout_secs.clamp(1, 120);
        let http_timeout_secs = (clamped_timeout + 35).max(125);
        let payload = json!({
            "command": ["bash", "-lc", command],
            "timeout_secs": clamped_timeout,
            "as_root": true,
        });
        let raw = self
            .send_bounded_json(
                "POST /vms/{id}/exec",
                self.req(reqwest::Method::POST, &format!("/vms/{provider_id}/exec"))
                    .timeout(Duration::from_secs(http_timeout_secs))
                    .json(&payload),
            )
            .await?;
        let parsed: ExecResponse = serde_json::from_value(raw)
            .map_err(|e| format!("POST /vms/{{id}}/exec: invalid exec payload ({e})"))?;
        Ok(Self::decode_exec_value(parsed))
    }

    async fn raw_write_file(
        &self,
        provider_id: &str,
        path: &str,
        content: &str,
    ) -> Result<(), String> {
        let payload = json!({
            "path": path,
            "content_b64": base64::engine::general_purpose::STANDARD.encode(content.as_bytes()),
            "mode": Self::file_mode_for_path(path),
        });
        let raw = self
            .send_bounded_json(
                "PUT /vms/{id}/files",
                self.req(reqwest::Method::PUT, &format!("/vms/{provider_id}/files"))
                    .timeout(Duration::from_secs(125))
                    .json(&payload),
            )
            .await?;
        if raw.get("ok").and_then(Value::as_bool) == Some(false) {
            let err = raw
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("guest file write failed");
            return Err(format!("PUT /vms/{{id}}/files: {err}"));
        }
        Ok(())
    }

    async fn usage(&self, provider_id: &str) -> Result<ProviderUsage, String> {
        let resp = self
            .req(reqwest::Method::GET, &format!("/vms/{provider_id}"))
            .send()
            .await
            .map_err(|e| format!("GET /vms/{provider_id}: {e}"))?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(ProviderUsage {
                dollars: 0.0,
                seconds: 0,
                running: false,
            });
        }
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("GET /vms/{provider_id}: read body: {e}"))?;
        if !status.is_success() {
            return Err(format_error("GET /vms/{id}", status, &text));
        }
        let env: VmEnvelope = serde_json::from_str(&text)
            .map_err(|e| format!("GET /vms/{{id}}: invalid JSON ({e})"))?;
        let vm = env.vm;
        let mapped = map_vm_state(&vm.status);
        let running = !is_stopped_state(&mapped);
        let rate = boost_size_spec(&vm.runner_label)
            .map(|s| s.usd_per_hour)
            .or_else(|| {
                let vcpus = vm.vcpus?;
                let ram_gb = vm.memory_mib.map(|m| m.div_ceil(1024)).unwrap_or(0);
                BOOST_SIZES
                    .iter()
                    .find(|s| s.cpu >= vcpus && s.ram_gb >= ram_gb)
                    .map(|s| s.usd_per_hour)
            })
            .unwrap_or(0.036);
        let Some(start) = vm.started_at.or(vm.created_at) else {
            return Ok(ProviderUsage {
                dollars: 0.0,
                seconds: 0,
                running,
            });
        };
        let end = vm.stopped_at.unwrap_or_else(Utc::now);
        let seconds = (end - start).num_seconds().max(0) as u64;
        let dollars = (seconds as f64 / 3600.0) * rate;
        Ok(ProviderUsage {
            dollars,
            seconds,
            running,
        })
    }

    async fn save_snapshot(&self, provider_id: &str, name: &str) -> Result<(), String> {
        let env: SnapshotEnvelope = self
            .send_json(
                "POST /vms/{id}/snapshots",
                self.req(
                    reqwest::Method::POST,
                    &format!("/vms/{provider_id}/snapshots"),
                )
                .json(&json!({ "label": name })),
            )
            .await?;
        if let Ok(mut cache) = self.snapshot_ids.write() {
            cache.insert(name.to_string(), env.snapshot.id);
        }
        Ok(())
    }

    async fn snapshot(&self, name: &str) -> Result<ProviderSnapshot, String> {
        let list: SnapshotListResponse = self
            .send_json(
                "GET /vms/snapshots",
                self.req(reqwest::Method::GET, "/vms/snapshots"),
            )
            .await?;
        let found = list
            .snapshots
            .into_iter()
            .find(|s| s.label.as_deref() == Some(name) || s.id == name)
            .ok_or_else(|| format!("snapshot '{name}' not found on boost.ci"))?;
        if let Ok(mut cache) = self.snapshot_ids.write() {
            cache.insert(name.to_string(), found.id);
        }
        let status = match found.status.trim().to_ascii_lowercase().as_str() {
            "ready" => "ready",
            "failed" | "error" | "deleted" => "failed",
            _ => "saving",
        };
        Ok(ProviderSnapshot {
            name: name.to_string(),
            status: status.into(),
            size_bytes: found.size_bytes,
        })
    }

    async fn delete_snapshot(&self, name: &str) -> Result<(), String> {
        let snap_id = match self.resolve_snapshot_id(name).await {
            Ok(id) => id,
            Err(e) if e.contains("not found") => return Ok(()),
            Err(e) => return Err(e),
        };
        let resp = self
            .req(
                reqwest::Method::DELETE,
                &format!("/vms/snapshots/{snap_id}"),
            )
            .send()
            .await
            .map_err(|e| format!("DELETE /vms/snapshots/{snap_id}: {e}"))?;
        if let Ok(mut cache) = self.snapshot_ids.write() {
            cache.remove(name);
        }
        let status = resp.status();
        if status.is_success() || status == reqwest::StatusCode::NOT_FOUND {
            return Ok(());
        }
        let body = resp.text().await.unwrap_or_default();
        Err(format_error("DELETE /vms/snapshots/{id}", status, &body))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::managed::ProvisioningMode;
    use axum::{
        extract::{Path, Query, State},
        http::{HeaderMap, StatusCode},
        routing::{delete, get, post, put},
        Json, Router,
    };
    use std::collections::HashMap;
    use std::sync::{Arc as StdArc, Mutex as StdMutex};

    fn test_spec(size: &str) -> SpawnSpec {
        SpawnSpec {
            machine_id: "mm123456".into(),
            size: size.into(),
            cpu: 4,
            ram_gb: 16,
            ttl_seconds: 3600,
            image: Some("ubuntu-26.04".into()),
            name: "orb-managed-mm123456".into(),
            idempotency_key: "orb-managed-mm123456".into(),
            bootstrap_script: None,
            gpu: None,
            arch: None,
            max_hourly_usd: None,
            preferred_offer_id: None,
            exclude_offer_ids: Vec::new(),
            allow_24h_commitment: false,
            provisioning_mode: ProvisioningMode::Worker,
            repo: None,
            base_key: None,
            lean_mode: None,
            memory_mib: None,
        }
    }

    fn sample_caps(
        online_engines: u32,
        sched_vcpus: u32,
        sched_mem_mib: u32,
        max_32: u32,
        blocker_32: Option<&str>,
    ) -> Value {
        json!({
            "principal": {
                "workspace_id": "5b9e0000-0000-0000-0000-000000000001",
                "principal_type": "api_token",
                "isolation_mode": "shared"
            },
            "quota": {
                "scope": "workspace",
                "max_vcpus": 64,
                "used_vcpus": 32,
                "available_vcpus": sched_vcpus,
                "active_vms": 1
            },
            "pool": {
                "online_engines": online_engines,
                "free_vcpus": sched_vcpus,
                "free_memory_mib": sched_mem_mib,
                "largest_single_vm": {
                    "vcpus": sched_vcpus.min(32),
                    "memory_mib": sched_mem_mib
                }
            },
            "effective": {
                "schedulable_vcpus": sched_vcpus,
                "schedulable_memory_mib": sched_mem_mib,
                "largest_bootable_vm": {
                    "vcpus": sched_vcpus.min(32),
                    "memory_mib": sched_mem_mib
                },
                "queued_spawns": 0
            },
            "profiles": [
                {
                    "runner_label": "boost-4vcpu-ubuntu-2604",
                    "vcpus": 4,
                    "default_memory_mib": 16384,
                    "max_launchable_now": if sched_vcpus >= 4 && sched_mem_mib >= 16384 && online_engines > 0 { 2 } else { 0 },
                    "blocking_reason": if online_engines == 0 { Some("no_online_engines") } else if sched_vcpus < 4 { Some("quota_vcpus") } else { None }
                },
                {
                    "runner_label": "boost-32vcpu-96gb",
                    "vcpus": 32,
                    "default_memory_mib": 98304,
                    "max_launchable_now": max_32,
                    "blocking_reason": blocker_32
                }
            ]
        })
    }

    #[test]
    fn normalizes_api_base_variants() {
        assert_eq!(
            normalize_api_base("https://api.boost.ci"),
            "https://api.boost.ci/v1"
        );
        assert_eq!(
            normalize_api_base("https://api.boost.ci/"),
            "https://api.boost.ci/v1"
        );
        assert_eq!(
            normalize_api_base("https://api.boost.ci/v1/"),
            "https://api.boost.ci/v1"
        );
        assert_eq!(
            normalize_api_base("https://api.boost.ci/api/v1"),
            "https://api.boost.ci/api/v1"
        );
    }

    #[test]
    fn size_aliases_follow_boat_pricing_curve() {
        let small = boost_size_spec("small").unwrap();
        assert_eq!(small.size, "boost-2vcpu-ubuntu-2604");
        assert_eq!(small.usd_per_hour, 0.018);

        let shared = boost_size_spec("boost-32vcpu-96gb").unwrap();
        assert_eq!(shared.cpu, 32);
        assert_eq!(shared.ram_gb, 96);
        assert_eq!(shared.usd_per_hour, 0.40);

        let largest = boost_size_spec("boost-32vcpu").unwrap();
        assert_eq!(largest.size, "boost-32vcpu-ubuntu-2604");
        assert_eq!(largest.ram_gb, 128);
        assert_eq!(largest.usd_per_hour, 0.45);
    }

    #[tokio::test]
    async fn capabilities_detect_degraded_and_saturated_and_reject_oversized_quote() {
        let caps_state = StdArc::new(StdMutex::new(sample_caps(
            1,
            32,
            91136,
            0,
            Some("pool_memory"),
        )));
        let app = Router::new()
            .route(
                "/v1/vms/capabilities",
                get(|State(st): State<StdArc<StdMutex<Value>>>| async move {
                    Json(st.lock().unwrap().clone())
                }),
            )
            .with_state(StdArc::clone(&caps_state));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let provider = BoostProvider::new(format!("http://{addr}"), "bst_test_secret");
        let avail = provider.refresh_availability().await.unwrap();
        assert_eq!(avail.status, AvailabilityStatus::Degraded);
        assert_eq!(avail.reason.as_deref(), Some("pool_memory"));
        assert_eq!(avail.largest_bootable_vcpus, Some(32));
        assert_eq!(avail.largest_bootable_memory_mib, Some(91136));

        // 4 vCPU / 16 GiB fits inside 91136 MiB.
        let ok_quote = provider
            .quote_spawn(&test_spec("boost-4vcpu-ubuntu-2604"))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(ok_quote.cpu, 4);
        assert_eq!(ok_quote.ram_gb, 16);
        assert_eq!(ok_quote.usd_per_hour, 0.036);

        // 32 vCPU / 96 GiB (98304 MiB) is blocked by `pool_memory`.
        let err = provider
            .quote_spawn(&test_spec("boost-32vcpu-96gb"))
            .await
            .unwrap_err();
        assert!(err.contains("provider_at_capacity (pool_memory)"), "{err}");

        // Saturated when quota/pool drops to 0 schedulable vCPUs.
        *caps_state.lock().unwrap() = sample_caps(1, 0, 91136, 0, Some("quota_vcpus"));
        provider.invalidate_capabilities_cache();
        let sat = provider.refresh_availability().await.unwrap();
        assert_eq!(sat.status, AvailabilityStatus::Saturated);
        assert_eq!(sat.reason.as_deref(), Some("quota_vcpus"));
    }

    #[derive(Debug, Deserialize)]
    #[serde(deny_unknown_fields)]
    struct MockExecReq {
        command: Vec<String>,
        timeout_secs: Option<u32>,
        as_root: bool,
    }

    #[derive(Debug, Deserialize)]
    #[serde(deny_unknown_fields)]
    struct MockWriteFileReq {
        path: String,
        content_b64: String,
        mode: Option<u32>,
    }

    #[tokio::test]
    async fn spawn_exec_files_and_snapshots_roundtrip() {
        let vm_id = "2f85a649-5040-49d0-9499-0b8d7e81b111";

        let app = Router::new()
            .route(
                "/v1/vms/capabilities",
                get(|Query(q): Query<HashMap<String, String>>| async move {
                    assert_eq!(
                        q.get("repo").map(String::as_str),
                        Some("Layr-Labs/evm.fast")
                    );
                    Json(sample_caps(1, 32, 131072, 1, None))
                }),
            )
            .route(
                "/v1/vms",
                post(|headers: HeaderMap, Json(_body): Json<Value>| async move {
                    assert_eq!(
                        headers.get("authorization").and_then(|v| v.to_str().ok()),
                        Some("Bearer bst_key")
                    );
                    assert_eq!(
                        headers
                            .get("x-boost-workspace-id")
                            .and_then(|v| v.to_str().ok()),
                        Some("ws-123")
                    );
                    assert_eq!(
                        headers.get("idempotency-key").and_then(|v| v.to_str().ok()),
                        Some("orb-managed-mm123456")
                    );
                    (
                        StatusCode::CREATED,
                        Json(json!({
                            "vm": {
                                "id": "2f85a649-5040-49d0-9499-0b8d7e81b111",
                                "name": "orb-managed-mm123456",
                                "runner_label": "boost-32vcpu-96gb",
                                "vcpus": 32,
                                "memory_mib": 98304,
                                "status": "queued"
                            }
                        })),
                    )
                }),
            )
            .route(
                "/v1/vms/:id/exec",
                post(|Path(id): Path<String>, Json(req): Json<MockExecReq>| async move {
                    assert_eq!(id, "2f85a649-5040-49d0-9499-0b8d7e81b111");
                    assert_eq!(req.command, vec!["bash", "-lc", "echo ready"]);
                    assert_eq!(req.timeout_secs, Some(30));
                    assert!(req.as_root);
                    Json(json!({
                        "op_id": "11111111-2222-3333-4444-555555555555",
                        "ok": true,
                        "exit_code": 0,
                        "stdout_b64": base64::engine::general_purpose::STANDARD.encode("ready\n"),
                        "elapsed_ms": 42
                    }))
                }),
            )
            .route(
                "/v1/vms/:id/files",
                put(|Path(id): Path<String>, Json(req): Json<MockWriteFileReq>| async move {
                    assert_eq!(id, "2f85a649-5040-49d0-9499-0b8d7e81b111");
                    assert!(!req.path.is_empty());
                    assert!(!req.content_b64.is_empty());
                    let mode = req.mode.expect("numeric octal mode expected");
                    assert!(mode <= 0o777, "mode {mode:#o} exceeds 0o777");
                    Json(json!({
                        "op_id": "11111111-2222-3333-4444-666666666666",
                        "ok": true,
                        "size_bytes": 5,
                        "mode": mode,
                        "elapsed_ms": 7
                    }))
                }),
            )
            .route(
                "/v1/vms/:id/snapshots",
                post(|Path(id): Path<String>| async move {
                    assert_eq!(id, "2f85a649-5040-49d0-9499-0b8d7e81b111");
                    (
                        StatusCode::CREATED,
                        Json(json!({
                            "snapshot": {
                                "id": "9a111111-2222-3333-4444-555555555555",
                                "label": "orb-snap-proj-warm-abcd",
                                "status": "saving"
                            }
                        })),
                    )
                }),
            )
            .route(
                "/v1/vms/snapshots",
                get(|| async {
                    Json(json!({
                        "snapshots": [{
                            "id": "9a111111-2222-3333-4444-555555555555",
                            "label": "orb-snap-proj-warm-abcd",
                            "status": "ready",
                            "size_bytes": 1048576
                        }]
                    }))
                }),
            )
            .route(
                "/v1/vms/snapshots/:snap_id",
                delete(|Path(sid): Path<String>| async move {
                    assert_eq!(sid, "9a111111-2222-3333-4444-555555555555");
                    StatusCode::NO_CONTENT
                }),
            )
            .route(
                "/v1/vms/:id",
                delete(|Path(id): Path<String>| async move {
                    assert_eq!(id, "2f85a649-5040-49d0-9499-0b8d7e81b111");
                    StatusCode::NO_CONTENT
                }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let provider = BoostProvider::with_workspace(
            format!("http://{addr}"),
            "bst_key",
            Some("ws-123".into()),
        );
        let mut spec = test_spec("boost-32vcpu-96gb");
        spec.repo = Some("Layr-Labs/evm.fast".into());
        spec.lean_mode = Some("auto".into());

        let quote = provider.quote_spawn(&spec).await.unwrap().unwrap();
        assert_eq!(quote.usd_per_hour, 0.40);

        let created = provider.spawn(&spec).await.unwrap();
        assert_eq!(created.provider_id, vm_id);
        assert_eq!(created.state, "provisioning");

        provider
            .write_file(vm_id, "/tmp/orb-bootstrap.sh", "#!/bin/sh\nexit 0\n")
            .await
            .unwrap();
        provider
            .raw_write_file(vm_id, "/tmp/hello.txt", "hello\n")
            .await
            .unwrap();
        let exec_out = provider.exec(vm_id, "echo ready", 30).await.unwrap();
        assert_eq!(exec_out["exit_code"], 0);
        assert_eq!(exec_out["stdout"], "ready\n");
        assert_eq!(exec_out["duration_ms"], 42);
        let raw_out = provider.raw_exec(vm_id, "echo ready", 30).await.unwrap();
        assert_eq!(raw_out["exit_code"], 0);
        assert_eq!(raw_out["stdout"], "ready\n");

        provider
            .save_snapshot(vm_id, "orb-snap-proj-warm-abcd")
            .await
            .unwrap();
        let snap = provider.snapshot("orb-snap-proj-warm-abcd").await.unwrap();
        assert_eq!(snap.status, "ready");
        assert_eq!(snap.size_bytes, Some(1048576));
        provider
            .delete_snapshot("orb-snap-proj-warm-abcd")
            .await
            .unwrap();
        provider.destroy(vm_id).await.unwrap();
    }

    #[test]
    fn formats_nested_boost_api_error_and_decodes_failed_operation_result() {
        let formatted = format_error(
            "POST /vms",
            reqwest::StatusCode::FORBIDDEN,
            r#"{"error":{"code":"forbidden","message":"repository `org/repo` is not connected to workspace"}}"#,
        );
        assert_eq!(
            formatted,
            "POST /vms -> HTTP 403: forbidden: repository `org/repo` is not connected to workspace"
        );

        let failed = BoostProvider::decode_exec_value(ExecResponse {
            ok: Some(false),
            exit_code: None,
            stdout_b64: None,
            stderr_b64: None,
            timed_out: false,
            stdout_truncated: false,
            stderr_truncated: false,
            elapsed_ms: Some(120_005),
            duration_ms: None,
            error: Some("guest command timed out after 120s".into()),
        });
        assert_eq!(failed["exit_code"], 124);
        assert_eq!(failed["timed_out"], true);
        assert_eq!(failed["stderr"], "guest command timed out after 120s");
        assert_eq!(failed["duration_ms"], 120_005);
    }
}
