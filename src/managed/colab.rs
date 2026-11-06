//! Google Colab (`Th0rgal/colab-api`) implementation of [`super::ManagedProvider`].
//!
//! Talks to a `colab-api` server (`GET /v1/accounts`, `GET /v1/accelerators`,
//! `GET|POST /v1/notebooks`, `POST /v1/notebooks/{id}/delete`) and to each
//! runtime's per-instance `colab_worker.py` HTTP server (`GET /info`,
//! `POST /exec`, `PUT /files/<rel>`) over its `cloudflared` tunnel.
//!
//! Sizes carry a shadow hourly rate equal to **half of Vast.ai's equivalent
//! GPU/TPU hourly rate** so Colab runtimes participate naturally in mission
//! USD budget pools, daily spend caps, and the 7-day spend chart.

use std::collections::HashMap;
use std::sync::RwLock;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use base64::Engine as _;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::{
    AvailabilityStatus, ManagedProvider, ProviderAvailability, ProviderMachine, ProviderUsage,
    SizeSpec, SpawnQuote, SpawnSpec,
};

pub const DEFAULT_API_BASE: &str = "http://127.0.0.1:8790/v1";
const MAX_RAW_HTTP_BYTES: usize = 256 * 1024;
const CAPABILITIES_CACHE_TTL: Duration = Duration::from_secs(30);

/// Colab accelerator profiles shadow-priced at ½ of Vast.ai's equivalent rate:
/// - T4 (~$0.20/h on Vast.ai) -> $0.10/h
/// - L4 (~$0.45/h on Vast.ai) -> $0.225/h
/// - A100 ($1.35/h on Vast.ai) -> $0.675/h
/// - H100 ($2.40/h on Vast.ai) -> $1.20/h
/// - v5e-1 TPU (L40S-class $0.95/h ÷ 2) -> $0.475/h
/// - v6e-1 TPU (A100-class $1.35/h ÷ 2) -> $0.675/h
pub const COLAB_SIZES: [SizeSpec; 7] = [
    SizeSpec {
        size: "colab-auto",
        cpu: 8,
        ram_gb: 30,
        disk_gb: 100,
        usd_per_hour: 0.225,
        gpu: Some("Auto GPU"),
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "t4",
        cpu: 2,
        ram_gb: 12,
        disk_gb: 80,
        usd_per_hour: 0.10,
        gpu: Some("Tesla T4"),
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "l4",
        cpu: 8,
        ram_gb: 30,
        disk_gb: 100,
        usd_per_hour: 0.225,
        gpu: Some("NVIDIA L4"),
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "a100",
        cpu: 12,
        ram_gb: 80,
        disk_gb: 150,
        usd_per_hour: 0.675,
        gpu: Some("A100"),
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "h100",
        cpu: 12,
        ram_gb: 80,
        disk_gb: 150,
        usd_per_hour: 1.20,
        gpu: Some("H100"),
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "v5e1",
        cpu: 8,
        ram_gb: 32,
        disk_gb: 100,
        usd_per_hour: 0.475,
        gpu: Some("TPU v5e-1"),
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "v6e1",
        cpu: 8,
        ram_gb: 32,
        disk_gb: 100,
        usd_per_hour: 0.675,
        gpu: Some("TPU v6e-1"),
        arch: "x86_64",
        min_billing_hours: None,
    },
];

pub fn colab_size_spec(raw: &str) -> Option<SizeSpec> {
    let key = match raw.trim().to_ascii_lowercase().as_str() {
        "auto" | "default" | "colab-auto" => "colab-auto",
        "small" | "t4" => "t4",
        "medium" | "l4" => "l4",
        "large" | "a100" | "a100-80g" | "a100-40g" => "a100",
        "xlarge" | "h100" | "h100-80g" => "h100",
        "v5e" | "v5e1" | "v5e-1" | "tpu-v5e" => "v5e1",
        "v6e" | "v6e1" | "v6e-1" | "tpu-v6e" => "v6e1",
        other => return COLAB_SIZES.iter().copied().find(|s| s.size == other),
    };
    COLAB_SIZES.iter().copied().find(|s| s.size == key)
}

/// Shadow tier spec corresponding to a concrete Colab `accelerator` string
/// (`"T4"`, `"L4"`, `"A100"`, `"H100"`, `"V5E1"`, `"V6E1"`, `"NONE"`).
pub fn spec_for_accelerator(accel: &str) -> SizeSpec {
    let up = accel.trim().to_ascii_uppercase();
    if up == "H100" {
        COLAB_SIZES[4]
    } else if up.starts_with("A100") {
        COLAB_SIZES[3]
    } else if up.starts_with("V6E") {
        COLAB_SIZES[6]
    } else if up.starts_with("V5E") {
        COLAB_SIZES[5]
    } else if up == "L4" {
        COLAB_SIZES[2]
    } else if up == "T4" {
        COLAB_SIZES[1]
    } else {
        // Plain CPU / legacy TPU fallback: ½ of cheapest GPU rate ($0.05/h).
        SizeSpec {
            size: "t4",
            cpu: 2,
            ram_gb: 12,
            disk_gb: 80,
            usd_per_hour: 0.05,
            gpu: None,
            arch: "x86_64",
            min_billing_hours: None,
        }
    }
}

/// Candidate Colab accelerator list (ordered best-first when auto) for a request.
pub fn requested_accelerators(size: &str, explicit_gpu: Option<&str>) -> Vec<String> {
    if let Some(g) = explicit_gpu.map(str::trim).filter(|s| !s.is_empty()) {
        let low = g.to_ascii_lowercase();
        let mapped = if low.contains("h100") {
            vec!["H100"]
        } else if low.contains("a100") {
            vec!["A100"]
        } else if low.contains("v6e") {
            vec!["V6E1"]
        } else if low.contains("v5e") {
            vec!["V5E1"]
        } else if low == "tpu" {
            vec!["V6E1", "V5E1"]
        } else if low.contains("l4") {
            vec!["L4"]
        } else if low.contains("t4") {
            vec!["T4"]
        } else {
            return vec![g.to_ascii_uppercase()];
        };
        return mapped.into_iter().map(str::to_string).collect();
    }
    let canonical = colab_size_spec(size).map_or(size.trim(), |s| s.size);
    match canonical {
        "colab-auto" => vec!["H100", "A100", "L4", "T4"],
        "t4" => vec!["T4"],
        "l4" => vec!["L4"],
        "a100" => vec!["A100"],
        "h100" => vec!["H100"],
        "v5e1" => vec!["V5E1"],
        "v6e1" => vec!["V6E1"],
        other => return vec![other.to_ascii_uppercase()],
    }
    .into_iter()
    .map(str::to_string)
    .collect()
}

pub fn normalize_api_base(raw: &str) -> String {
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return DEFAULT_API_BASE.to_string();
    }
    if trimmed.ends_with("/v1") || trimmed.ends_with("/api/v1") {
        trimmed.to_string()
    } else {
        format!("{trimmed}/v1")
    }
}

pub fn is_ready_state(state: &str) -> bool {
    matches!(state, "running" | "ready")
}

pub fn is_stopped_state(state: &str) -> bool {
    matches!(
        state,
        "stopped" | "deleted" | "error" | "failed" | "offline"
    )
}

#[derive(Debug, Clone, Deserialize)]
struct AccountsResponse {
    #[serde(default)]
    accounts: Vec<ColabAccountStatus>,
}

#[derive(Debug, Clone, Deserialize)]
struct ColabAccountStatus {
    #[allow(dead_code)]
    email: String,
    #[serde(default)]
    usable: bool,
    #[serde(default)]
    needs_login: bool,
    #[serde(default)]
    cooldown_secs: u64,
    #[serde(default)]
    last_error: String,
}

#[derive(Debug, Clone, Deserialize)]
struct AcceleratorsResponse {
    #[serde(default)]
    accounts: Vec<AccountAccelerators>,
}

#[derive(Debug, Clone, Deserialize)]
struct AccountAccelerators {
    #[allow(dead_code)]
    account: String,
    #[serde(default)]
    #[allow(dead_code)]
    tier: String,
    #[serde(default)]
    #[allow(dead_code)]
    best: Option<String>,
    #[serde(default)]
    available: Vec<AcceleratorSpec>,
}

#[derive(Debug, Clone, Deserialize)]
struct AcceleratorSpec {
    #[serde(default)]
    #[allow(dead_code)]
    variant: String,
    accelerator: String,
    #[serde(default)]
    shape: String,
    #[serde(default)]
    eligible: bool,
}

#[derive(Debug, Clone, Deserialize)]
struct NotebooksListResponse {
    #[serde(default)]
    notebooks: Vec<NotebookRecord>,
}

#[derive(Debug, Clone, Deserialize)]
struct NotebookRecord {
    id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    accelerator: String,
    #[serde(default)]
    connected: Option<bool>,
    #[serde(default)]
    worker_url: Option<String>,
    #[serde(default)]
    worker_token: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct WorkerInfoResponse {
    #[serde(default)]
    #[allow(dead_code)]
    cpus: Option<u32>,
    #[serde(default)]
    #[allow(dead_code)]
    memory_mib: Option<u32>,
}

#[derive(Debug, Clone, Deserialize)]
struct WorkerExecResponse {
    #[serde(default)]
    exit_code: Option<i64>,
    #[serde(default)]
    timed_out: bool,
    #[serde(default)]
    output: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Debug, Clone)]
struct WorkerEndpoint {
    url: String,
    token: String,
}

#[derive(Debug, Clone)]
struct RuntimeTracking {
    started_at: DateTime<Utc>,
    usd_per_hour: f64,
}

#[derive(Debug, Clone)]
struct CachedAvailability {
    fetched_at: Instant,
    availability: ProviderAvailability,
    eligible_accelerators: Vec<String>,
}

#[derive(Debug, Serialize)]
struct CreateNotebookBody<'a> {
    name: &'a str,
    accelerator: &'a [String],
    assign_timeout_secs: u64,
    worker: bool,
}

pub struct ColabProvider {
    base_url: String,
    api_token: String,
    http: reqwest::Client,
    availability_cache: RwLock<Option<CachedAvailability>>,
    workers: RwLock<HashMap<String, WorkerEndpoint>>,
    runtimes: RwLock<HashMap<String, RuntimeTracking>>,
}

impl std::fmt::Debug for ColabProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ColabProvider")
            .field("base_url", &self.base_url)
            .finish()
    }
}

impl ColabProvider {
    pub fn new(base_url: impl Into<String>, api_token: impl Into<String>) -> Self {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(120))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self {
            base_url: normalize_api_base(&base_url.into()),
            api_token: api_token.into().trim().to_string(),
            http,
            availability_cache: RwLock::new(None),
            workers: RwLock::new(HashMap::new()),
            runtimes: RwLock::new(HashMap::new()),
        }
    }

    pub fn from_env() -> Option<Self> {
        let token = std::env::var("COLAB_API_TOKEN")
            .ok()
            .filter(|k| !k.trim().is_empty())?;
        std::env::remove_var("COLAB_API_TOKEN");
        let base = std::env::var("COLAB_API_URL")
            .or_else(|_| std::env::var("COLAB_API_BASE"))
            .unwrap_or_else(|_| DEFAULT_API_BASE.to_string());
        Some(Self::new(base, token))
    }

    pub fn configured_api_base(&self) -> &str {
        &self.base_url
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base_url, path)
    }

    fn req(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        self.http
            .request(method, self.url(path))
            .bearer_auth(&self.api_token)
    }

    pub(crate) fn invalidate_cache(&self) {
        if let Ok(mut slot) = self.availability_cache.write() {
            *slot = None;
        }
    }

    async fn send_json<T: serde::de::DeserializeOwned>(
        &self,
        label: &str,
        req: reqwest::RequestBuilder,
    ) -> Result<T, String> {
        let resp = req
            .send()
            .await
            .map_err(|e| format!("colab {label}: {}", e.without_url()))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("colab {label}: read body: {}", e.without_url()))?;
        if !status.is_success() {
            return Err(format_error(label, status, &text));
        }
        serde_json::from_str::<T>(&text).map_err(|e| {
            format!(
                "colab {label}: invalid JSON ({e}): {}",
                truncate_chars(&text, 200)
            )
        })
    }

    async fn send_bounded_json(label: &str, req: reqwest::RequestBuilder) -> Result<Value, String> {
        let mut resp = req
            .send()
            .await
            .map_err(|e| format!("colab {label}: {}", e.without_url()))?;
        let status = resp.status();
        let mut body = Vec::new();
        while let Some(chunk) = resp
            .chunk()
            .await
            .map_err(|e| format!("colab {label}: read chunk: {}", e.without_url()))?
        {
            if body.len().saturating_add(chunk.len()) > MAX_RAW_HTTP_BYTES {
                return Err(format!(
                    "colab {label}: response exceeds {MAX_RAW_HTTP_BYTES}B"
                ));
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
        serde_json::from_slice(&body).map_err(|e| format!("colab {label}: invalid JSON ({e})"))
    }

    fn derive_snapshot(
        accts: &AccountsResponse,
        accels: Option<&AcceleratorsResponse>,
        notebooks: Option<&NotebooksListResponse>,
    ) -> (ProviderAvailability, Vec<String>) {
        let total_accounts = accts.accounts.len() as u32;
        let usable_accounts = accts.accounts.iter().filter(|a| a.usable).count() as u32;
        let active_notebooks = notebooks.map(|n| n.notebooks.len() as u32);

        let mut eligible_set: Vec<String> = Vec::new();
        let mut max_cpu = 0u32;
        let mut max_ram_mib = 0u32;
        if let Some(acc) = accels {
            for entry in &acc.accounts {
                for sp in &entry.available {
                    if !sp.eligible {
                        continue;
                    }
                    let up = sp.accelerator.trim().to_ascii_uppercase();
                    if !up.is_empty() && !eligible_set.iter().any(|x| x == &up) {
                        eligible_set.push(up.clone());
                    }
                    let tier = spec_for_accelerator(&up);
                    let ram_mib = if sp.shape == "SHAPE_HIGHMEM" {
                        (tier.ram_gb * 1024).max(52 * 1024)
                    } else {
                        tier.ram_gb * 1024
                    };
                    max_cpu = max_cpu.max(tier.cpu);
                    max_ram_mib = max_ram_mib.max(ram_mib);
                }
            }
        } else if usable_accounts > 0 {
            max_cpu = 8;
            max_ram_mib = 30 * 1024;
        }

        let free_slots = match active_notebooks {
            Some(active) => usable_accounts.saturating_sub(active),
            None => usable_accounts,
        };

        let primary_blocker = || -> String {
            if total_accounts == 0 {
                return "no_accounts_configured".into();
            }
            if accts.accounts.iter().all(|a| a.needs_login) {
                return "accounts_need_login".into();
            }
            if accts.accounts.iter().any(|a| a.cooldown_secs > 0) {
                if accts
                    .accounts
                    .iter()
                    .any(|a| a.last_error.contains("QUOTA_EXCEEDED"))
                {
                    return "quota_exceeded_cooldown".into();
                }
                return "accounts_in_cooldown".into();
            }
            if usable_accounts > 0 && free_slots == 0 {
                return "all_accounts_have_active_runtimes".into();
            }
            "at_capacity".into()
        };

        let has_pro_tier = eligible_set
            .iter()
            .any(|a| matches!(a.as_str(), "H100" | "A100" | "L4" | "V6E1" | "V5E1"));

        let (status, reason) = if usable_accounts == 0
            || free_slots == 0
            || (accels.is_some() && eligible_set.is_empty())
        {
            (AvailabilityStatus::Saturated, Some(primary_blocker()))
        } else if usable_accounts < total_accounts || (accels.is_some() && !has_pro_tier) {
            let why = if usable_accounts < total_accounts {
                Some("some_accounts_cooling_down".into())
            } else {
                Some("free_tier_only".into())
            };
            (AvailabilityStatus::Degraded, why)
        } else {
            (AvailabilityStatus::Available, None)
        };

        let avail = ProviderAvailability {
            status,
            reason,
            schedulable_vcpus: Some(free_slots.saturating_mul(max_cpu)),
            schedulable_memory_mib: Some(free_slots.saturating_mul(max_ram_mib)),
            largest_bootable_vcpus: (free_slots > 0).then_some(max_cpu),
            largest_bootable_memory_mib: (free_slots > 0).then_some(max_ram_mib),
            online_engines: Some(usable_accounts),
            active_vms: active_notebooks,
            queued_spawns: Some(0),
            checked_at: Utc::now(),
        };
        (avail, eligible_set)
    }

    async fn probe_snapshot(&self, force: bool) -> Result<CachedAvailability, String> {
        if !force {
            if let Some(fresh) = self.availability_cache.read().ok().and_then(|c| {
                c.as_ref()
                    .filter(|entry| entry.fetched_at.elapsed() < CAPABILITIES_CACHE_TTL)
                    .cloned()
            }) {
                return Ok(fresh);
            }
        }
        let accts: AccountsResponse = self
            .send_json(
                "GET /accounts",
                self.req(reqwest::Method::GET, "/accounts")
                    .timeout(Duration::from_secs(20)),
            )
            .await?;
        let usable_any = accts.accounts.iter().any(|a| a.usable);
        let accels = if usable_any {
            self.send_json::<AcceleratorsResponse>(
                "GET /accelerators",
                self.req(reqwest::Method::GET, "/accelerators")
                    .timeout(Duration::from_secs(30)),
            )
            .await
            .ok()
        } else {
            None
        };
        let notebooks = self
            .send_json::<NotebooksListResponse>(
                "GET /notebooks",
                self.req(reqwest::Method::GET, "/notebooks")
                    .timeout(Duration::from_secs(25)),
            )
            .await
            .ok();

        let (availability, eligible_accelerators) =
            Self::derive_snapshot(&accts, accels.as_ref(), notebooks.as_ref());
        let entry = CachedAvailability {
            fetched_at: Instant::now(),
            availability,
            eligible_accelerators,
        };
        if let Ok(mut slot) = self.availability_cache.write() {
            *slot = Some(entry.clone());
        }
        Ok(entry)
    }

    fn cache_worker_from_record(&self, rec: &NotebookRecord) {
        if let (Some(url), Some(tok)) = (
            rec.worker_url
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty()),
            rec.worker_token
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty()),
        ) {
            if let Ok(mut map) = self.workers.write() {
                map.insert(
                    rec.id.clone(),
                    WorkerEndpoint {
                        url: url.trim_end_matches('/').to_string(),
                        token: tok.to_string(),
                    },
                );
            }
        }
    }

    async fn resolve_worker(
        &self,
        provider_id: &str,
        force_refresh: bool,
    ) -> Result<WorkerEndpoint, String> {
        if !force_refresh {
            if let Some(ep) = self
                .workers
                .read()
                .ok()
                .and_then(|m| m.get(provider_id).cloned())
            {
                return Ok(ep);
            }
        }
        let encoded = urlencoding::encode(provider_id);
        let rec: NotebookRecord = self
            .send_json(
                "GET /notebooks/{id}",
                self.req(reqwest::Method::GET, &format!("/notebooks/{encoded}")),
            )
            .await?;
        self.cache_worker_from_record(&rec);
        self.workers
            .read()
            .ok()
            .and_then(|m| m.get(provider_id).cloned())
            .ok_or_else(|| {
                format!(
                    "colab runtime '{provider_id}' worker tunnel is not ready yet (sandbox_starting)"
                )
            })
    }

    async fn fetch_worker_info(&self, ep: &WorkerEndpoint) -> Option<WorkerInfoResponse> {
        let resp = self
            .http
            .get(format!("{}/info", ep.url))
            .bearer_auth(&ep.token)
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        resp.json::<WorkerInfoResponse>().await.ok()
    }

    fn notebook_state(rec: &NotebookRecord) -> String {
        if rec.connected == Some(false) {
            return "provisioning".into();
        }
        if rec
            .worker_url
            .as_deref()
            .is_some_and(|u| !u.trim().is_empty())
        {
            "running".into()
        } else {
            // `GET /v1/notebooks` omits `worker_url` for speed; `connected: true` means assigned.
            if rec.connected == Some(true) {
                "running".into()
            } else {
                "provisioning".into()
            }
        }
    }

    fn decode_worker_exec(resp: WorkerExecResponse) -> Value {
        let timed_out = resp.timed_out;
        let stdout = resp.output.unwrap_or_default();
        let stderr = resp.error.unwrap_or_default();
        let exit_code = match resp.exit_code {
            Some(0) if timed_out => 124,
            Some(code) => code,
            None if timed_out => 124,
            None if !stderr.is_empty() => 1,
            None => 0,
        };
        json!({
            "exit_code": exit_code,
            "stdout": stdout,
            "stderr": stderr,
            "timed_out": timed_out,
        })
    }

    fn file_mode_for_path(path: &str) -> u32 {
        if path.ends_with("enroll.env") {
            0o600
        } else if path.ends_with(".sh") {
            0o755
        } else {
            0o644
        }
    }

    async fn worker_exec_inner(
        &self,
        provider_id: &str,
        command: &str,
        timeout_secs: u64,
        bounded: bool,
    ) -> Result<Value, String> {
        let clamped_timeout = timeout_secs.clamp(1, if bounded { 120 } else { 600 });
        let http_timeout = Duration::from_secs((clamped_timeout + 35).max(90));
        let payload = json!({
            "cmd": command,
            "timeout": clamped_timeout,
        });
        let mut ep = self.resolve_worker(provider_id, false).await?;
        for attempt in 0..2 {
            let req = self
                .http
                .post(format!("{}/exec", ep.url))
                .bearer_auth(&ep.token)
                .timeout(http_timeout)
                .json(&payload);
            let res = if bounded {
                Self::send_bounded_json("worker POST /exec", req)
                    .await
                    .and_then(|v| {
                        serde_json::from_value::<WorkerExecResponse>(v)
                            .map_err(|e| format!("colab worker POST /exec: bad JSON ({e})"))
                    })
            } else {
                self.send_json::<WorkerExecResponse>("worker POST /exec", req)
                    .await
            };
            match res {
                Ok(parsed) => return Ok(Self::decode_worker_exec(parsed)),
                Err(err)
                    if attempt == 0
                        && (err.contains("HTTP 502")
                            || err.contains("HTTP 503")
                            || err.contains("HTTP 404")
                            || err.contains("HTTP 530")
                            || err.contains("connection")) =>
                {
                    ep = self.resolve_worker(provider_id, true).await?;
                }
                Err(err) => return Err(err),
            }
        }
        Err("colab worker POST /exec failed after tunnel refresh".into())
    }

    async fn worker_write_file_inner(
        &self,
        provider_id: &str,
        path: &str,
        content: &str,
        bounded: bool,
    ) -> Result<(), String> {
        if !path.starts_with('/') || path.contains('\0') {
            return Err("colab write_file: path must be absolute".into());
        }
        let mode = Self::file_mode_for_path(path);
        // Fast path when writing under `/content/...`: direct `PUT /files/<rel>` + chmod if executable/secret.
        if let Some(rel) = path
            .strip_prefix("/content/")
            .filter(|r| !r.is_empty() && !r.split('/').any(|p| p == ".."))
        {
            let ep = self.resolve_worker(provider_id, false).await?;
            let req = self
                .http
                .put(format!("{}/files/{rel}", ep.url))
                .bearer_auth(&ep.token)
                .timeout(Duration::from_secs(90))
                .body(content.as_bytes().to_vec());
            let _ = if bounded {
                Self::send_bounded_json("worker PUT /files", req).await?
            } else {
                self.send_json::<Value>("worker PUT /files", req).await?
            };
            if mode != 0o644 {
                let quoted = format!("'{}'", path.replace('\'', "'\\''"));
                let _ = self
                    .worker_exec_inner(
                        provider_id,
                        &format!("chmod {:o} {quoted}", mode),
                        15,
                        bounded,
                    )
                    .await?;
            }
            return Ok(());
        }

        // Generic absolute path (e.g. `/tmp/orb-bootstrap.sh` or `/home/user/.orb/enroll.env`):
        // write atomically via base64 over `POST /exec`.
        let b64 = base64::engine::general_purpose::STANDARD.encode(content.as_bytes());
        let quoted = format!("'{}'", path.replace('\'', "'\\''"));
        let cmd = format!(
            "set -eu; p={quoted}; mkdir -p \"$(dirname \"$p\")\"; printf '%s' '{b64}' | base64 -d >\"$p.tmp\" && chmod {:o} \"$p.tmp\" && mv \"$p.tmp\" \"$p\"",
            mode
        );
        let res = self
            .worker_exec_inner(provider_id, &cmd, 30, bounded)
            .await?;
        let code = res.get("exit_code").and_then(Value::as_i64).unwrap_or(1);
        if code != 0 {
            let out = res
                .get("stdout")
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
                .or_else(|| res.get("stderr").and_then(Value::as_str))
                .unwrap_or("write failed");
            return Err(format!("colab write_file {path}: exit {code}: {out}"));
        }
        Ok(())
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
            v.get("error")
                .and_then(Value::as_str)
                .or_else(|| v.get("message").and_then(Value::as_str))
                .map(str::to_string)
        })
        .unwrap_or_else(|| truncate_chars(body.trim(), 220));
    format!("colab {label} -> HTTP {}: {detail}", status.as_u16())
}

#[async_trait]
impl ManagedProvider for ColabProvider {
    fn name(&self) -> &'static str {
        "colab"
    }

    fn sizes(&self) -> &[SizeSpec] {
        &COLAB_SIZES
    }

    fn supports_free_stop(&self) -> bool {
        false
    }

    fn supports_snapshots(&self) -> bool {
        false
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
        self.availability_cache
            .read()
            .ok()
            .and_then(|c| c.as_ref().map(|e| e.availability.clone()))
    }

    async fn refresh_availability(&self) -> Result<ProviderAvailability, String> {
        Ok(self.probe_snapshot(false).await?.availability)
    }

    async fn quote_spawn(&self, spec: &SpawnSpec) -> Result<Option<SpawnQuote>, String> {
        let size_spec = colab_size_spec(&spec.size)
            .ok_or_else(|| format!("unknown colab size '{}'", spec.size))?;
        let wanted = requested_accelerators(&spec.size, spec.gpu.as_deref());
        let snap = self.probe_snapshot(false).await?;
        if snap.availability.status == AvailabilityStatus::Saturated {
            let reason = snap
                .availability
                .reason
                .unwrap_or_else(|| "at_capacity".into());
            return Err(format!(
                "provider_at_capacity ({reason}): Google Colab has no free usable account right now"
            ));
        }

        // When accelerator eligibility was fetched, pick the highest-priority
        // wanted accelerator that at least one usable account can actually serve.
        let chosen_tier = if !snap.eligible_accelerators.is_empty() {
            let Some(matched) = wanted.iter().find(|w| {
                snap.eligible_accelerators
                    .iter()
                    .any(|elig| elig.eq_ignore_ascii_case(w))
            }) else {
                return Err(format!(
                    "provider_at_capacity (accelerator_ineligible): none of {:?} are eligible on usable Colab accounts (eligible: {:?})",
                    wanted, snap.eligible_accelerators
                ));
            };
            spec_for_accelerator(matched)
        } else {
            size_spec
        };

        if let Some(ceil) = spec.max_hourly_usd {
            if chosen_tier.usd_per_hour > ceil + 1e-9 {
                return Err(format!(
                    "colab tier '{}' shadow rate ${:.3}/h exceeds max_hourly_usd ${ceil:.3}/h",
                    chosen_tier.size, chosen_tier.usd_per_hour
                ));
            }
        }

        Ok(Some(SpawnQuote {
            offer_id: None,
            usd_per_hour: chosen_tier.usd_per_hour,
            cpu: chosen_tier.cpu.max(spec.cpu),
            ram_gb: chosen_tier.ram_gb.max(spec.ram_gb),
        }))
    }

    async fn spawn(&self, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        let wanted = requested_accelerators(&spec.size, spec.gpu.as_deref());
        let body = CreateNotebookBody {
            name: &spec.name,
            accelerator: &wanted,
            assign_timeout_secs: 180,
            worker: true,
        };
        let req = self
            .req(reqwest::Method::POST, "/notebooks")
            .timeout(Duration::from_secs(300))
            .json(&body);
        let created_res: Result<NotebookRecord, String> =
            self.send_json("POST /notebooks", req).await;
        self.invalidate_cache();
        let rec = match created_res {
            Ok(r) => r,
            Err(err) => {
                // Reconcile by caller `name` (`orb-managed-<id>`) if the HTTP response dropped.
                if let Ok(existing) = self.list().await {
                    if let Some(found) = existing
                        .into_iter()
                        .find(|pm| pm.name == spec.name && !is_stopped_state(&pm.state))
                    {
                        return Ok(found);
                    }
                }
                if err.contains("no usable Colab account")
                    || err.contains("QUOTA_EXCEEDED")
                    || err.contains("TOO_MANY_ACTIVE_RUNTIMES")
                    || err.contains("HTTP 503")
                {
                    return Err(format!("provider_at_capacity: {err}"));
                }
                return Err(err);
            }
        };
        self.cache_worker_from_record(&rec);
        let assigned_rate = if !rec.accelerator.trim().is_empty() {
            spec_for_accelerator(&rec.accelerator).usd_per_hour
        } else {
            colab_size_spec(&spec.size).map_or(0.225, |s| s.usd_per_hour)
        };
        if let Ok(mut rt) = self.runtimes.write() {
            rt.insert(
                rec.id.clone(),
                RuntimeTracking {
                    started_at: Utc::now(),
                    usd_per_hour: assigned_rate,
                },
            );
        }
        // Best-effort warmup check on the worker info endpoint.
        if let Some(ep) = self
            .workers
            .read()
            .ok()
            .and_then(|m| m.get(&rec.id).cloned())
        {
            let _ = self.fetch_worker_info(&ep).await;
        }
        let state = if rec
            .worker_url
            .as_deref()
            .is_some_and(|u| !u.trim().is_empty())
        {
            "running".to_string()
        } else {
            "provisioning".to_string()
        };
        Ok(ProviderMachine {
            provider_id: rec.id,
            state,
            name: rec.name.unwrap_or_else(|| spec.name.clone()),
            deletable_at: None,
            warnings: Vec::new(),
            effective_lean_mode: None,
            effective_repo: None,
        })
    }

    async fn get(&self, provider_id: &str) -> Result<ProviderMachine, String> {
        let encoded = urlencoding::encode(provider_id);
        let rec: NotebookRecord = self
            .send_json(
                "GET /notebooks/{id}",
                self.req(reqwest::Method::GET, &format!("/notebooks/{encoded}")),
            )
            .await?;
        self.cache_worker_from_record(&rec);
        let state = if rec
            .worker_url
            .as_deref()
            .is_some_and(|u| !u.trim().is_empty())
        {
            "running".into()
        } else {
            "provisioning".into()
        };
        Ok(ProviderMachine {
            provider_id: rec.id,
            state,
            name: rec.name.unwrap_or_default(),
            deletable_at: None,
            warnings: Vec::new(),
            effective_lean_mode: None,
            effective_repo: None,
        })
    }

    async fn list(&self) -> Result<Vec<ProviderMachine>, String> {
        let resp: NotebooksListResponse = self
            .send_json(
                "GET /notebooks",
                self.req(reqwest::Method::GET, "/notebooks"),
            )
            .await?;
        Ok(resp
            .notebooks
            .into_iter()
            .map(|rec| {
                let state = Self::notebook_state(&rec);
                ProviderMachine {
                    provider_id: rec.id,
                    state,
                    name: rec.name.unwrap_or_default(),
                    deletable_at: None,
                    warnings: Vec::new(),
                    effective_lean_mode: None,
                    effective_repo: None,
                }
            })
            .collect())
    }

    async fn destroy(&self, provider_id: &str) -> Result<(), String> {
        let encoded = urlencoding::encode(provider_id);
        // `colab-api` uses `lean-sys` HTTP parser (GET + POST only), so deletion is `POST .../delete`.
        let resp = self
            .req(
                reqwest::Method::POST,
                &format!("/notebooks/{encoded}/delete"),
            )
            .json(&json!({}))
            .send()
            .await
            .map_err(|e| format!("colab POST /notebooks/{{id}}/delete: {}", e.without_url()))?;
        let status = resp.status();
        self.invalidate_cache();
        if let Ok(mut w) = self.workers.write() {
            w.remove(provider_id);
        }
        if let Ok(mut rt) = self.runtimes.write() {
            rt.remove(provider_id);
        }
        if status.is_success() || status == reqwest::StatusCode::NOT_FOUND {
            return Ok(());
        }
        let body = resp.text().await.unwrap_or_default();
        Err(format_error("POST /notebooks/{id}/delete", status, &body))
    }

    async fn extend(&self, _provider_id: &str, _ttl_seconds: u64) -> Result<(), String> {
        // Colab runtimes have no server-side TTL parameter on `v1beta/runtimes`;
        // Core's `expires_at` governs reaping, so extending in Core succeeds as a no-op here.
        Ok(())
    }

    async fn write_file(&self, provider_id: &str, path: &str, content: &str) -> Result<(), String> {
        self.worker_write_file_inner(provider_id, path, content, false)
            .await
    }

    async fn exec(
        &self,
        provider_id: &str,
        command: &str,
        timeout_secs: u64,
    ) -> Result<Value, String> {
        self.worker_exec_inner(provider_id, command, timeout_secs, false)
            .await
    }

    async fn raw_exec(
        &self,
        provider_id: &str,
        command: &str,
        timeout_secs: u64,
    ) -> Result<Value, String> {
        self.worker_exec_inner(provider_id, command, timeout_secs, true)
            .await
    }

    async fn raw_write_file(
        &self,
        provider_id: &str,
        path: &str,
        content: &str,
    ) -> Result<(), String> {
        self.worker_write_file_inner(provider_id, path, content, true)
            .await
    }

    async fn usage(&self, provider_id: &str) -> Result<ProviderUsage, String> {
        let encoded = urlencoding::encode(provider_id);
        let resp = self
            .req(reqwest::Method::GET, &format!("/notebooks/{encoded}"))
            .send()
            .await
            .map_err(|e| format!("colab GET /notebooks/{{id}}: {}", e.without_url()))?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(ProviderUsage {
                dollars: 0.0,
                seconds: 0,
                running: false,
            });
        }
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(format_error("GET /notebooks/{id}", status, &text));
        }
        let rec: NotebookRecord = serde_json::from_str(&text)
            .map_err(|e| format!("colab GET /notebooks/{{id}}: bad JSON ({e})"))?;
        let tracked = self
            .runtimes
            .read()
            .ok()
            .and_then(|m| m.get(provider_id).cloned());
        let rate = if !rec.accelerator.trim().is_empty() {
            spec_for_accelerator(&rec.accelerator).usd_per_hour
        } else {
            tracked.as_ref().map_or(0.225, |t| t.usd_per_hour)
        };
        let Some(t) = tracked else {
            return Ok(ProviderUsage {
                dollars: 0.0,
                seconds: 0,
                running: true,
            });
        };
        let seconds = (Utc::now() - t.started_at).num_seconds().max(0) as u64;
        let dollars = (seconds as f64 / 3600.0) * rate;
        Ok(ProviderUsage {
            dollars,
            seconds,
            running: true,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::managed::ProvisioningMode;
    use axum::{
        extract::{Path, State},
        http::{HeaderMap, StatusCode},
        routing::{get, post, put},
        Json, Router,
    };
    use std::sync::{Arc as StdArc, Mutex as StdMutex};

    fn test_spec(size: &str) -> SpawnSpec {
        SpawnSpec {
            machine_id: "mmcolab1".into(),
            size: size.into(),
            cpu: 2,
            ram_gb: 12,
            ttl_seconds: 3600,
            image: Some("colab-default".into()),
            name: "orb-managed-mmcolab1".into(),
            idempotency_key: "orb-managed-mmcolab1".into(),
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

    #[test]
    fn colab_shadow_pricing_is_half_of_vastai() {
        // Vast.ai: a100 = $1.35/h -> $0.675/h; h100 = $2.40/h -> $1.20/h;
        // rtx4090/L4 = $0.45/h -> $0.225/h; T4 = $0.20/h -> $0.10/h.
        assert!((colab_size_spec("t4").unwrap().usd_per_hour - 0.10).abs() < 1e-9);
        assert!((colab_size_spec("l4").unwrap().usd_per_hour - 0.225).abs() < 1e-9);
        assert!((colab_size_spec("a100").unwrap().usd_per_hour - 0.675).abs() < 1e-9);
        assert!((colab_size_spec("h100").unwrap().usd_per_hour - 1.20).abs() < 1e-9);
        assert!((colab_size_spec("v5e1").unwrap().usd_per_hour - 0.475).abs() < 1e-9);
        assert!((colab_size_spec("v6e1").unwrap().usd_per_hour - 0.675).abs() < 1e-9);
    }

    #[test]
    fn normalizes_colab_api_base() {
        assert_eq!(
            normalize_api_base("http://127.0.0.1:8790"),
            "http://127.0.0.1:8790/v1"
        );
        assert_eq!(
            normalize_api_base("https://colab.example.com/v1/"),
            "https://colab.example.com/v1"
        );
    }

    #[derive(Default)]
    struct MockColabState {
        accounts: Value,
        accelerators: Value,
        deleted_ids: Vec<String>,
        files: HashMap<String, String>,
        commands: Vec<String>,
        worker_url: String,
    }

    async fn spawn_mock_colab(state: StdArc<StdMutex<MockColabState>>) -> String {
        let app = Router::new()
            .route(
                "/v1/accounts",
                get(|State(st): State<StdArc<StdMutex<MockColabState>>>| async move {
                    Json(st.lock().unwrap().accounts.clone())
                }),
            )
            .route(
                "/v1/accelerators",
                get(|State(st): State<StdArc<StdMutex<MockColabState>>>| async move {
                    Json(st.lock().unwrap().accelerators.clone())
                }),
            )
            .route(
                "/v1/notebooks",
                get(|State(_st): State<StdArc<StdMutex<MockColabState>>>| async move {
                    Json(json!({
                        "notebooks": [
                            {"id": "rt-user~me@gmail.com", "name": null, "accelerator": "T4", "connected": true}
                        ]
                    }))
                })
                .post(
                    |headers: HeaderMap,
                     State(st): State<StdArc<StdMutex<MockColabState>>>,
                     Json(body): Json<Value>| async move {
                        let auth = headers
                            .get("authorization")
                            .and_then(|v| v.to_str().ok())
                            .unwrap_or_default();
                        if auth != "Bearer colab-secret" {
                            return (
                                StatusCode::UNAUTHORIZED,
                                Json(json!({"error": "bad token"})),
                            );
                        }
                        let worker_url = st.lock().unwrap().worker_url.clone();
                        let name = body.get("name").cloned().unwrap_or(Value::Null);
                        (
                            StatusCode::CREATED,
                            Json(json!({
                                "id": "rt-123~pro@gmail.com",
                                "name": name,
                                "accelerator": "A100",
                                "connected": true,
                                "worker_url": worker_url,
                                "worker_token": "wtok-1"
                            })),
                        )
                    },
                ),
            )
            .route(
                "/v1/notebooks/:id",
                get(
                    |Path(id): Path<String>,
                     State(st): State<StdArc<StdMutex<MockColabState>>>| async move {
                        let worker_url = st.lock().unwrap().worker_url.clone();
                        Json(json!({
                            "id": id,
                            "name": "orb-managed-mmcolab1",
                            "accelerator": "A100",
                            "connected": true,
                            "worker_url": worker_url,
                            "worker_token": "wtok-1"
                        }))
                    },
                ),
            )
            .route(
                "/v1/notebooks/:id/delete",
                post(
                    |Path(id): Path<String>,
                     State(st): State<StdArc<StdMutex<MockColabState>>>| async move {
                        st.lock().unwrap().deleted_ids.push(id.clone());
                        Json(json!({"deleted": id}))
                    },
                ),
            )
            // Mock worker endpoints on the same server (`/worker/...`)
            .route(
                "/worker/info",
                get(|| async move {
                    Json(json!({"cpus": 12, "memory_mib": 85196, "gpus": [{"name": "NVIDIA A100-SXM4-80GB"}]}))
                }),
            )
            .route(
                "/worker/files/*path",
                put(
                    |Path(path): Path<String>,
                     headers: HeaderMap,
                     State(st): State<StdArc<StdMutex<MockColabState>>>,
                     body: String| async move {
                        let auth = headers
                            .get("authorization")
                            .and_then(|v| v.to_str().ok())
                            .unwrap_or_default();
                        if auth != "Bearer wtok-1" {
                            return (StatusCode::UNAUTHORIZED, Json(json!({"error": "unauth"})));
                        }
                        st.lock().unwrap().files.insert(path.clone(), body);
                        (StatusCode::OK, Json(json!({"path": path})))
                    },
                ),
            )
            .route(
                "/worker/exec",
                post(
                    |headers: HeaderMap,
                     State(st): State<StdArc<StdMutex<MockColabState>>>,
                     Json(body): Json<Value>| async move {
                        let auth = headers
                            .get("authorization")
                            .and_then(|v| v.to_str().ok())
                            .unwrap_or_default();
                        if auth != "Bearer wtok-1" {
                            return (StatusCode::UNAUTHORIZED, Json(json!({"error": "unauth"})));
                        }
                        let cmd = body
                            .get("cmd")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string();
                        st.lock().unwrap().commands.push(cmd);
                        (
                            StatusCode::OK,
                            Json(json!({"exit_code": 0, "timed_out": false, "output": "ok\n"})),
                        )
                    },
                ),
            )
            .with_state(state.clone());

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base = format!("http://{addr}");
        state.lock().unwrap().worker_url = format!("{base}/worker");
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        base
    }

    #[tokio::test]
    async fn availability_and_quote_reflect_account_pool_and_eligible_specs() {
        let state = StdArc::new(StdMutex::new(MockColabState {
            accounts: json!({
                "accounts": [
                    {"email": "pro@gmail.com", "usable": true, "needs_login": false, "cooldown_secs": 0, "last_error": ""},
                    {"email": "free@gmail.com", "usable": true, "needs_login": false, "cooldown_secs": 0, "last_error": ""}
                ]
            }),
            accelerators: json!({
                "accounts": [
                    {
                        "account": "pro@gmail.com",
                        "tier": "TIER_PRO_PLUS",
                        "best": "A100",
                        "available": [
                            {"variant": "VARIANT_GPU", "accelerator": "A100", "shape": "SHAPE_HIGHMEM", "eligible": true},
                            {"variant": "VARIANT_GPU", "accelerator": "L4", "shape": "SHAPE_STANDARD", "eligible": true}
                        ]
                    }
                ]
            }),
            ..Default::default()
        }));
        let base = spawn_mock_colab(state.clone()).await;
        let p = ColabProvider::new(&base, "colab-secret");

        let avail = p.refresh_availability().await.unwrap();
        // 2 usable accounts, 1 active notebook -> 1 free slot -> Available.
        assert_eq!(avail.status, AvailabilityStatus::Available);
        assert_eq!(avail.online_engines, Some(2));
        assert_eq!(avail.active_vms, Some(1));

        // `colab-auto` resolves to highest eligible wanted tier (`A100` -> $0.675/h).
        let auto_quote = p
            .quote_spawn(&test_spec("colab-auto"))
            .await
            .unwrap()
            .unwrap();
        assert!((auto_quote.usd_per_hour - 0.675).abs() < 1e-9);
        assert_eq!(auto_quote.cpu, 12);
        assert_eq!(auto_quote.ram_gb, 80);

        // Requesting `h100` when only `A100`/`L4` are eligible fails fast with `provider_at_capacity`.
        let err = p.quote_spawn(&test_spec("h100")).await.unwrap_err();
        assert!(err.contains("provider_at_capacity"), "got: {err}");
    }

    #[tokio::test]
    async fn saturated_when_all_accounts_in_quota_cooldown() {
        let state = StdArc::new(StdMutex::new(MockColabState {
            accounts: json!({
                "accounts": [
                    {"email": "pro@gmail.com", "usable": false, "needs_login": false, "cooldown_secs": 3600, "last_error": "QUOTA_EXCEEDED_USAGE_TIME"}
                ]
            }),
            accelerators: json!({"accounts": []}),
            ..Default::default()
        }));
        let base = spawn_mock_colab(state).await;
        let p = ColabProvider::new(&base, "colab-secret");

        let avail = p.refresh_availability().await.unwrap();
        assert_eq!(avail.status, AvailabilityStatus::Saturated);
        assert_eq!(avail.reason.as_deref(), Some("quota_exceeded_cooldown"));
    }

    #[tokio::test]
    async fn spawn_exec_write_and_urlencoded_delete_round_trip() {
        let state = StdArc::new(StdMutex::new(MockColabState {
            accounts: json!({"accounts": [{"email": "pro@gmail.com", "usable": true}]}),
            accelerators: json!({"accounts": []}),
            ..Default::default()
        }));
        let base = spawn_mock_colab(state.clone()).await;
        let p = ColabProvider::new(&base, "colab-secret");

        let pm = p.spawn(&test_spec("a100")).await.unwrap();
        assert_eq!(pm.provider_id, "rt-123~pro@gmail.com");
        assert_eq!(pm.name, "orb-managed-mmcolab1");
        assert!(p.is_ready_state(&pm.state));

        // Direct `/content/` file upload hits `PUT /worker/files/hello.txt`.
        p.write_file(&pm.provider_id, "/content/hello.txt", "world")
            .await
            .unwrap();
        assert_eq!(
            state
                .lock()
                .unwrap()
                .files
                .get("hello.txt")
                .map(String::as_str),
            Some("world")
        );

        // System path (`/tmp/orb-bootstrap.sh`) stages atomically over `/worker/exec`.
        p.write_file(
            &pm.provider_id,
            "/tmp/orb-bootstrap.sh",
            "#!/bin/sh\necho hi\n",
        )
        .await
        .unwrap();

        let out = p.exec(&pm.provider_id, "nvidia-smi", 30).await.unwrap();
        assert_eq!(out.get("exit_code").and_then(Value::as_i64), Some(0));
        assert_eq!(out.get("stdout").and_then(Value::as_str), Some("ok\n"));

        p.destroy(&pm.provider_id).await.unwrap();
        assert_eq!(
            state.lock().unwrap().deleted_ids,
            vec!["rt-123~pro@gmail.com".to_string()]
        );
    }
}
