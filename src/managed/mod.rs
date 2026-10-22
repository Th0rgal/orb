//! Managed machines: short-lived compute that Core rents from a provider
//! (boat.dev today) and enrolls as a dial-out `sandboxed-node`.
//!
//! - [`ManagedProvider`] abstracts the provider; [`boat::BoatProvider`] is the
//!   first implementation.
//! - [`ManagedManager`] owns the persisted registry (which doubles as the cost
//!   ledger), the caps (concurrency, daily dollars, TTL), the one-time
//!   enrollment tokens and the reverse relay that carries the ordinary node
//!   API over the node's outbound long-poll.
//! - Managed nodes are a separate trust class: they are never part of the
//!   static `SANDBOXED_REMOTE_NODES` list, so automatic placement never picks
//!   them. Work reaches them only when a caller names the node explicitly
//!   (`remote_node_id: "managed-<id>"` or `"auto-managed"`).
//!
//! Configuration (all optional, env):
//! `BOAT_API_KEY` (enables the feature), `SANDBOXED_MANAGED_ENABLED`,
//! `SANDBOXED_MANAGED_DAILY_CAP_USD` (20), `SANDBOXED_MANAGED_MAX_CONCURRENT`
//! (6), `SANDBOXED_MANAGED_DEFAULT_TTL_MINUTES` (120),
//! `SANDBOXED_MANAGED_MAX_TTL_MINUTES` (720), `SANDBOXED_MANAGED_DEFAULT_SIZE`
//! (small), `SANDBOXED_MANAGED_MAX_SIZE` (xlarge), `SANDBOXED_MANAGED_IMAGE`
//! (orb-node-base), `SANDBOXED_MANAGED_CORE_URL` (defaults to
//! `SANDBOXED_PUBLIC_URL`), `SANDBOXED_MANAGED_IDLE_MINUTES` (15),
//! `SANDBOXED_MANAGED_RECONCILE_SECS` (300).

pub mod boat;
pub mod relay;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, LazyLock, OnceLock, RwLock};
use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;

use crate::remote_node::RemoteNodeConfig;

/// Prefix of every managed node id and of the boat sandbox names we create.
pub const NODE_PREFIX: &str = "managed-";
pub const SANDBOX_NAME_PREFIX: &str = "orb-managed-";
const TOKEN_ENV_PREFIX: &str = "SANDBOXED_MANAGED_TOKEN_";
const ENROLL_ENV_PATH: &str = "/home/user/.orb/enroll.env";

// ---------------------------------------------------------------- provider

#[derive(Debug, Clone)]
pub struct SpawnSpec {
    pub size: String,
    pub ttl_seconds: u64,
    pub image: Option<String>,
    pub name: String,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProviderMachine {
    pub provider_id: String,
    pub state: String,
    pub name: String,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ProviderUsage {
    pub dollars: f64,
    pub seconds: u64,
    pub running: bool,
}

#[async_trait]
pub trait ManagedProvider: Send + Sync {
    fn name(&self) -> &'static str;
    async fn spawn(&self, spec: &SpawnSpec) -> Result<ProviderMachine, String>;
    async fn get(&self, provider_id: &str) -> Result<ProviderMachine, String>;
    async fn list(&self) -> Result<Vec<ProviderMachine>, String>;
    async fn destroy(&self, provider_id: &str) -> Result<(), String>;
    async fn extend(&self, provider_id: &str, ttl_seconds: u64) -> Result<(), String>;
    async fn write_file(&self, provider_id: &str, path: &str, content: &str) -> Result<(), String>;
    async fn exec(
        &self,
        provider_id: &str,
        command: &str,
        timeout_secs: u64,
    ) -> Result<Value, String>;
    async fn usage(&self, provider_id: &str) -> Result<ProviderUsage, String>;
}

// ------------------------------------------------------------------- sizes

#[derive(Debug, Clone, Copy, Serialize)]
pub struct SizeSpec {
    pub size: &'static str,
    pub cpu: u32,
    pub ram_gb: u32,
    pub disk_gb: u32,
    pub usd_per_hour: f64,
}

pub const SIZES: [SizeSpec; 4] = [
    SizeSpec {
        size: "small",
        cpu: 2,
        ram_gb: 4,
        disk_gb: 12,
        usd_per_hour: 0.018,
    },
    SizeSpec {
        size: "default",
        cpu: 4,
        ram_gb: 8,
        disk_gb: 50,
        usd_per_hour: 0.036,
    },
    SizeSpec {
        size: "large",
        cpu: 8,
        ram_gb: 16,
        disk_gb: 125,
        usd_per_hour: 0.072,
    },
    SizeSpec {
        size: "xlarge",
        cpu: 16,
        ram_gb: 32,
        disk_gb: 251,
        usd_per_hour: 0.20,
    },
];

pub fn size_spec(name: &str) -> Option<SizeSpec> {
    let name = match name.trim().to_ascii_lowercase().as_str() {
        "medium" => "default".to_string(),
        other => other.to_string(),
    };
    SIZES.iter().copied().find(|s| s.size == name)
}

fn size_rank(name: &str) -> usize {
    SIZES.iter().position(|s| s.size == name).unwrap_or(0)
}

/// Smallest size that satisfies an explicit CPU / RAM request.
pub fn size_for(cpu: Option<u32>, ram_gb: Option<u32>) -> Option<SizeSpec> {
    SIZES
        .iter()
        .copied()
        .find(|s| cpu.is_none_or(|c| s.cpu >= c) && ram_gb.is_none_or(|r| s.ram_gb >= r))
}

// ---------------------------------------------------------------- settings

#[derive(Debug, Clone, Serialize)]
pub struct ManagedSettings {
    pub enabled: bool,
    pub provider: String,
    pub daily_cap_usd: f64,
    pub max_concurrent: usize,
    pub default_ttl_minutes: u64,
    pub max_ttl_minutes: u64,
    pub default_size: String,
    pub max_size: String,
    pub image: String,
    /// Images (named snapshots) callers may request
    /// (`SANDBOXED_MANAGED_IMAGES`, comma list; default just `image`).
    pub allowed_images: Vec<String>,
    #[serde(skip)]
    pub core_url: Option<String>,
    pub idle_minutes: u64,
    pub reconcile_secs: u64,
}

fn env_parse<T: std::str::FromStr>(key: &str) -> Option<T> {
    std::env::var(key).ok().and_then(|v| v.trim().parse().ok())
}

impl ManagedSettings {
    pub fn from_env(provider_configured: bool) -> Self {
        let enabled = match std::env::var("SANDBOXED_MANAGED_ENABLED").ok().as_deref() {
            Some("0") | Some("false") | Some("no") | Some("off") => false,
            _ => provider_configured,
        };
        let default_size = std::env::var("SANDBOXED_MANAGED_DEFAULT_SIZE")
            .ok()
            .and_then(|s| size_spec(&s))
            .map_or("small", |s| s.size)
            .to_string();
        let max_size = std::env::var("SANDBOXED_MANAGED_MAX_SIZE")
            .ok()
            .and_then(|s| size_spec(&s))
            .map_or("xlarge", |s| s.size)
            .to_string();
        let max_ttl = env_parse("SANDBOXED_MANAGED_MAX_TTL_MINUTES").unwrap_or(720u64);
        let image = std::env::var("SANDBOXED_MANAGED_IMAGE")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| "orb-node-base".into());
        let mut allowed_images: Vec<String> = std::env::var("SANDBOXED_MANAGED_IMAGES")
            .unwrap_or_default()
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if !allowed_images.contains(&image) {
            allowed_images.push(image.clone());
        }
        Self {
            enabled,
            provider: "boat".into(),
            daily_cap_usd: env_parse("SANDBOXED_MANAGED_DAILY_CAP_USD").unwrap_or(20.0),
            max_concurrent: env_parse("SANDBOXED_MANAGED_MAX_CONCURRENT").unwrap_or(6),
            default_ttl_minutes: env_parse::<u64>("SANDBOXED_MANAGED_DEFAULT_TTL_MINUTES")
                .unwrap_or(120)
                .min(max_ttl),
            max_ttl_minutes: max_ttl,
            default_size,
            max_size,
            image,
            allowed_images,
            core_url: std::env::var("SANDBOXED_MANAGED_CORE_URL")
                .ok()
                .or_else(|| std::env::var("SANDBOXED_PUBLIC_URL").ok())
                .map(|u| u.trim().trim_end_matches('/').to_string())
                .filter(|u| !u.is_empty()),
            idle_minutes: env_parse("SANDBOXED_MANAGED_IDLE_MINUTES").unwrap_or(15),
            reconcile_secs: env_parse("SANDBOXED_MANAGED_RECONCILE_SECS").unwrap_or(300),
        }
    }
}

// ----------------------------------------------------------------- records

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MachineState {
    Provisioning,
    Enrolling,
    Online,
    Destroying,
    Destroyed,
    Failed,
}

impl MachineState {
    pub fn is_live(self) -> bool {
        !matches!(self, Self::Destroyed | Self::Failed)
    }
}

/// One managed machine. The persisted list of these is the cost ledger:
/// `cost_usd` is the provider's metered cost and `ledger_closed` is true once
/// the provider confirms nothing is billing any more.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManagedMachine {
    pub id: String,
    /// Short human name, unique among live machines ("small-a", "large-b").
    /// Display/targeting alias only: `node_id` stays immutable.
    #[serde(default)]
    pub name: String,
    /// Owner's Antigravity sign-in was pushed to this VM (wiped on destroy).
    #[serde(default)]
    pub antigravity_projected: bool,
    pub provider: String,
    pub provider_id: Option<String>,
    pub node_id: String,
    pub image: String,
    pub size: String,
    pub cpu: u32,
    pub ram_gb: u32,
    pub disk_gb: u32,
    pub usd_per_hour: f64,
    pub state: MachineState,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    #[serde(default)]
    pub online_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub destroyed_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub destroy_reason: Option<String>,
    pub cost_usd: f64,
    #[serde(default)]
    pub cost_is_metered: bool,
    #[serde(default)]
    pub owner_mission_id: Option<String>,
    /// Tenant (user id) whose mission store holds `owner_mission_id`.
    #[serde(default)]
    pub owner_user_id: Option<String>,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    pub ledger_closed: bool,
    #[serde(default)]
    pub last_busy_at: Option<DateTime<Utc>>,
}

impl ManagedMachine {
    fn estimated_cost(&self, now: DateTime<Utc>) -> f64 {
        let end = self.destroyed_at.unwrap_or(now).min(self.expires_at);
        let secs = (end - self.created_at).num_seconds().max(0) as f64;
        secs / 3600.0 * self.usd_per_hour
    }

    fn remaining_commitment(&self, now: DateTime<Utc>) -> f64 {
        if !self.state.is_live() {
            return 0.0;
        }
        let secs = (self.expires_at - now).num_seconds().max(0) as f64;
        secs / 3600.0 * self.usd_per_hour
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct MachineSecrets {
    enroll_token_sha256: Option<String>,
    enroll_expires_at: Option<DateTime<Utc>>,
    enroll_used: bool,
    node_token: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct SpawnRequest {
    pub size: Option<String>,
    pub cpu: Option<u32>,
    pub ram_gb: Option<u32>,
    pub ttl_minutes: Option<u64>,
    pub image: Option<String>,
    pub reason: Option<String>,
    pub owner_mission_id: Option<String>,
    /// Set by the API from the authenticated caller; never from the body.
    #[serde(skip)]
    pub owner_user_id: Option<String>,
    /// Wait until the node is online (default true).
    pub wait: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ManagedError {
    pub error: &'static str,
    pub message: String,
    #[serde(skip)]
    pub status: u16,
}

impl ManagedError {
    fn new(error: &'static str, status: u16, message: impl Into<String>) -> Self {
        Self {
            error,
            status,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for ManagedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.error, self.message)
    }
}

// ------------------------------------------------- dynamic node registry
//
// `RemoteNodeSettings::node()` hands out `&RemoteNodeConfig`. Managed node
// configs are leaked once per machine (a few hundred bytes, bounded by the
// daily machine count) so the borrow is `'static`.

static NODES: LazyLock<RwLock<HashMap<String, &'static RemoteNodeConfig>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));
static TOKENS: LazyLock<RwLock<HashMap<String, String>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));
static MANAGER: OnceLock<Arc<ManagedManager>> = OnceLock::new();

/// Lifecycle of a machine's owning mission, as seen by the reaper.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OwnerState {
    /// Running, queued, awaiting the user, interrupted (resumable), paused...
    Live,
    /// Completed, failed, not feasible or acknowledged: it will not run again.
    Terminal,
    /// The mission no longer exists (deleted).
    Missing,
}

pub type OwnerProbe = Arc<
    dyn Fn(
            String,
            String,
        )
            -> std::pin::Pin<Box<dyn std::future::Future<Output = Option<OwnerState>> + Send>>
        + Send
        + Sync,
>;

/// Map a mission status (its Display string) to an [`OwnerState`].
/// `interrupted` and `blocked` stay live: deploy restarts interrupt missions
/// that are then resumed, and blocked missions await resolution.
pub fn owner_state_for_status(status: &str) -> OwnerState {
    match status {
        "completed" | "failed" | "not_feasible" | "acknowledged" | "cancelled" => {
            OwnerState::Terminal
        }
        _ => OwnerState::Live,
    }
}

static ALIASES: LazyLock<RwLock<HashMap<String, String>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));

/// Map a live machine name ("small-a") to its immutable node id; anything
/// else is returned unchanged. Resolve at intake so a persisted mission never
/// refers to a reusable name.
pub fn resolve_node_alias(id: &str) -> String {
    ALIASES
        .read()
        .ok()
        .and_then(|m| m.get(id).cloned())
        .unwrap_or_else(|| id.to_string())
}

/// Display name for a managed node id, if live.
pub fn display_name(node_id: &str) -> Option<String> {
    ALIASES
        .read()
        .ok()?
        .iter()
        .find(|(_, v)| v.as_str() == node_id)
        .map(|(k, _)| k.clone())
}

/// Name prefix for a size: boat's "default" reads as "medium".
pub fn name_prefix(size: &str) -> &str {
    if size == "default" {
        "medium"
    } else {
        size
    }
}

/// Lowest free `<size>-<letter>` name: a..z, then a1..z1, a2..
pub fn allocate_name(size: &str, live: &[String]) -> String {
    let size = name_prefix(size);
    for round in 0u32.. {
        for letter in b'a'..=b'z' {
            let suffix = if round == 0 {
                (letter as char).to_string()
            } else {
                format!("{}{}", letter as char, round)
            };
            let name = format!("{size}-{suffix}");
            if !live.iter().any(|n| n == &name) {
                return name;
            }
        }
    }
    unreachable!()
}

fn register_alias(machine: &ManagedMachine) {
    if !machine.name.is_empty() {
        if let Ok(mut map) = ALIASES.write() {
            map.insert(machine.name.clone(), machine.node_id.clone());
        }
    }
}

fn unregister_alias(machine: &ManagedMachine) {
    if let Ok(mut map) = ALIASES.write() {
        if map.get(&machine.name) == Some(&machine.node_id) {
            map.remove(&machine.name);
        }
    }
}

pub fn node_config(node_id: &str) -> Option<&'static RemoteNodeConfig> {
    NODES.read().ok()?.get(node_id).copied()
}

pub fn node_configs() -> Vec<&'static RemoteNodeConfig> {
    let mut nodes: Vec<_> = NODES
        .read()
        .map(|m| m.values().copied().collect())
        .unwrap_or_default();
    nodes.sort_by(|a: &&RemoteNodeConfig, b| a.id.cmp(&b.id));
    nodes
}

/// Token lookup for a managed node's `token_env`; `None` for any other name.
pub fn node_token(token_env: &str) -> Option<String> {
    if !token_env.starts_with(TOKEN_ENV_PREFIX) {
        return None;
    }
    TOKENS.read().ok()?.get(token_env).cloned()
}

pub fn is_managed_node(node_id: &str) -> bool {
    node_id.starts_with(NODE_PREFIX)
}

pub fn global() -> Option<Arc<ManagedManager>> {
    MANAGER.get().cloned()
}

fn token_env_for(machine_id: &str) -> String {
    format!("{TOKEN_ENV_PREFIX}{}", machine_id.to_ascii_uppercase())
}

fn register_node(machine: &ManagedMachine, core_port: u16, token: &str) {
    let config: &'static RemoteNodeConfig = Box::leak(Box::new(RemoteNodeConfig {
        id: machine.node_id.clone(),
        base_url: format!(
            "http://127.0.0.1:{core_port}/api/managed-machines/relay/tunnel/{}",
            machine.id
        ),
        token_env: token_env_for(&machine.id),
        labels: Some(vec![
            "managed".into(),
            "trust=managed".into(),
            format!("size={}", machine.size),
            format!("image={}", machine.image),
        ]),
    }));
    if let Ok(mut map) = TOKENS.write() {
        map.insert(config.token_env.clone(), token.to_string());
    }
    if let Ok(mut map) = NODES.write() {
        map.insert(config.id.clone(), config);
    }
}

fn unregister_node(machine: &ManagedMachine) {
    unregister_alias(machine);
    if let Ok(mut map) = NODES.write() {
        map.remove(&machine.node_id);
    }
    if let Ok(mut map) = TOKENS.write() {
        map.remove(&token_env_for(&machine.id));
    }
}

// ----------------------------------------------------------------- manager

#[derive(Default, Serialize, Deserialize)]
struct Persisted {
    machines: Vec<ManagedMachine>,
}

pub struct ManagedManager {
    pub settings: ManagedSettings,
    provider: Option<Arc<dyn ManagedProvider>>,
    core_port: u16,
    dir: PathBuf,
    machines: Mutex<Vec<ManagedMachine>>,
    secrets: Mutex<HashMap<String, MachineSecrets>>,
    /// Serialises spawn admission so two callers cannot both pass the caps.
    admission: Mutex<()>,
    pub relay: relay::RelayHub,
    owner_probe: std::sync::RwLock<Option<OwnerProbe>>,
    runtime: std::sync::RwLock<RuntimeSettings>,
}

/// Operator toggles persisted in `managed_settings.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeSettings {
    /// Project the owner's Antigravity (Google) sign-in onto managed VMs the
    /// owner rented. Default on (`SANDBOXED_MANAGED_ANTIGRAVITY=0` disables).
    #[serde(default = "default_true")]
    pub antigravity_on_managed: bool,
}

fn default_true() -> bool {
    true
}

impl Default for RuntimeSettings {
    fn default() -> Self {
        Self {
            antigravity_on_managed: !matches!(
                std::env::var("SANDBOXED_MANAGED_ANTIGRAVITY")
                    .ok()
                    .as_deref(),
                Some("0" | "false" | "no" | "off")
            ),
        }
    }
}

/// Is `owner_user_id` allowed to receive the Antigravity projection?
/// `SANDBOXED_MANAGED_ANTIGRAVITY_USERS` (comma list) restricts it; unset
/// means any authenticated owner (single-tenant Core: every user is Thomas).
/// A machine without a recorded owner never qualifies.
pub fn antigravity_owner_allowed(owner_user_id: Option<&str>, allowlist: Option<&str>) -> bool {
    let Some(owner) = owner_user_id.filter(|o| !o.is_empty()) else {
        return false;
    };
    match allowlist.map(str::trim).filter(|l| !l.is_empty()) {
        None => true,
        Some(list) => list.split(',').map(str::trim).any(|u| u == owner),
    }
}

fn random_id() -> String {
    const ALPHABET: &[u8] = b"23456789abcdefghjkmnpqrstuvwxyz";
    let mut rng = rand::thread_rng();
    (0..8)
        .map(|_| ALPHABET[rng.gen_range(0..ALPHABET.len())] as char)
        .collect()
}

fn random_token() -> String {
    let bytes: [u8; 32] = rand::thread_rng().gen();
    hex::encode(bytes)
}

fn sha256_hex(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}

fn constant_time_eq(a: &str, b: &str) -> bool {
    a.len() == b.len()
        && a.bytes()
            .zip(b.bytes())
            .fold(0u8, |acc, (x, y)| acc | (x ^ y))
            == 0
}

fn start_of_today() -> DateTime<Utc> {
    Utc::now()
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_utc()
}

#[derive(Debug, Clone, Serialize)]
pub struct BudgetView {
    pub spent_today_usd: f64,
    pub committed_usd: f64,
    pub daily_cap_usd: f64,
    pub active: usize,
    pub max_concurrent: usize,
    pub default_ttl_minutes: u64,
    pub max_ttl_minutes: u64,
    pub default_size: String,
    pub max_size: String,
    pub image: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ListView {
    pub enabled: bool,
    pub provider: String,
    pub machines: Vec<ManagedMachine>,
    pub budget: BudgetView,
    pub sizes: Vec<SizeSpec>,
}

impl ManagedManager {
    pub fn new(
        settings: ManagedSettings,
        provider: Option<Arc<dyn ManagedProvider>>,
        working_dir: &std::path::Path,
        core_port: u16,
    ) -> Self {
        let dir = working_dir.join(".sandboxed-sh");
        Self {
            settings,
            provider,
            core_port,
            dir,
            machines: Mutex::new(Vec::new()),
            secrets: Mutex::new(HashMap::new()),
            admission: Mutex::new(()),
            relay: relay::RelayHub::default(),
            owner_probe: std::sync::RwLock::new(None),
            runtime: std::sync::RwLock::new(RuntimeSettings::default()),
        }
    }

    /// Install the mission-status lookup used to destroy machines whose
    /// owning mission has ended.
    pub fn set_owner_probe(&self, probe: OwnerProbe) {
        if let Ok(mut slot) = self.owner_probe.write() {
            *slot = Some(probe);
        }
    }

    /// Hand a live machine to another mission of the owner's tree (the
    /// gateway has already checked lineage). The new owner's lifetime then
    /// governs the machine.
    pub async fn adopt(&self, id: &str, mission_id: &str) -> Option<ManagedMachine> {
        let m = self.get(id).await?;
        if !m.state.is_live() || m.owner_mission_id.as_deref() == Some(mission_id) {
            return Some(m);
        }
        let m = self
            .update(&m.id, |m| m.owner_mission_id = Some(mission_id.to_string()))
            .await?;
        self.ledger("adopted", &m);
        Some(m)
    }

    fn runtime_path(&self) -> PathBuf {
        self.dir.join("managed_settings.json")
    }

    pub fn runtime_settings(&self) -> RuntimeSettings {
        self.runtime.read().map(|r| r.clone()).unwrap_or_default()
    }

    pub fn set_runtime_settings(&self, settings: RuntimeSettings) {
        let _ = std::fs::create_dir_all(&self.dir);
        write_atomic(
            &self.runtime_path(),
            &serde_json::to_vec_pretty(&settings).unwrap_or_default(),
            false,
        );
        if let Ok(mut r) = self.runtime.write() {
            *r = settings;
        }
    }

    /// May the owner's Antigravity sign-in be projected onto this node?
    pub async fn antigravity_allowed(&self, node_id: &str) -> bool {
        if !self.runtime_settings().antigravity_on_managed {
            return false;
        }
        let Some(m) = self.get(node_id).await else {
            return false;
        };
        m.state.is_live()
            && m.node_id == node_id
            && antigravity_owner_allowed(
                m.owner_user_id.as_deref(),
                std::env::var("SANDBOXED_MANAGED_ANTIGRAVITY_USERS")
                    .ok()
                    .as_deref(),
            )
    }

    pub async fn mark_antigravity_projected(&self, node_id: &str) {
        if let Some(m) = self.get(node_id).await {
            if !m.antigravity_projected {
                if let Some(m) = self.update(&m.id, |m| m.antigravity_projected = true).await {
                    self.ledger("antigravity_projected", &m);
                }
            }
        }
    }

    fn machines_path(&self) -> PathBuf {
        self.dir.join("managed_machines.json")
    }
    fn secrets_path(&self) -> PathBuf {
        self.dir.join("managed_machine_secrets.json")
    }
    fn ledger_path(&self) -> PathBuf {
        self.dir.join("managed_ledger.jsonl")
    }

    /// Load the registry and re-register the nodes of live machines.
    pub async fn load(&self) {
        let machines: Persisted = std::fs::read(self.machines_path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let secrets: HashMap<String, MachineSecrets> = std::fs::read(self.secrets_path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let mut machines = machines;
        // Rows from before names existed: give live ones a name now.
        let mut live_names: Vec<String> = machines
            .machines
            .iter()
            .filter(|m| m.state.is_live() && !m.name.is_empty())
            .map(|m| m.name.clone())
            .collect();
        for m in machines.machines.iter_mut() {
            if m.state.is_live() && m.name.is_empty() {
                m.name = allocate_name(&m.size, &live_names);
                live_names.push(m.name.clone());
            }
        }
        for m in &machines.machines {
            if m.state.is_live() {
                register_alias(m);
                if let Some(token) = secrets.get(&m.id).and_then(|s| s.node_token.as_deref()) {
                    register_node(m, self.core_port, token);
                }
            }
        }
        *self.machines.lock().await = machines.machines;
        *self.secrets.lock().await = secrets;
        if let Some(rt) = std::fs::read(self.runtime_path())
            .ok()
            .and_then(|b| serde_json::from_slice::<RuntimeSettings>(&b).ok())
        {
            if let Ok(mut r) = self.runtime.write() {
                *r = rt;
            }
        }
    }

    async fn persist(&self) {
        let machines = self.machines.lock().await.clone();
        let secrets = self.secrets.lock().await.clone();
        let _ = std::fs::create_dir_all(&self.dir);
        write_atomic(
            &self.machines_path(),
            &serde_json::to_vec_pretty(&Persisted { machines }).unwrap_or_default(),
            false,
        );
        write_atomic(
            &self.secrets_path(),
            &serde_json::to_vec(&secrets).unwrap_or_default(),
            true,
        );
    }

    fn ledger(&self, event: &str, machine: &ManagedMachine) {
        use std::io::Write;
        let line = serde_json::json!({
            "at": Utc::now(),
            "event": event,
            "machine_id": machine.id,
            "name": machine.name,
            "provider_id": machine.provider_id,
            "size": machine.size,
            "state": machine.state,
            "cost_usd": machine.cost_usd,
            "cost_is_metered": machine.cost_is_metered,
            "ledger_closed": machine.ledger_closed,
            "owner_mission_id": machine.owner_mission_id,
            "reason": machine.destroy_reason.as_ref().or(machine.reason.as_ref()),
        });
        let _ = std::fs::create_dir_all(&self.dir);
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.ledger_path())
        {
            let _ = writeln!(f, "{line}");
        }
    }

    async fn update<F: FnOnce(&mut ManagedMachine)>(
        &self,
        id: &str,
        f: F,
    ) -> Option<ManagedMachine> {
        let out = {
            let mut machines = self.machines.lock().await;
            let m = machines.iter_mut().find(|m| m.id == id)?;
            f(m);
            m.clone()
        };
        self.persist().await;
        Some(out)
    }

    pub async fn get(&self, id: &str) -> Option<ManagedMachine> {
        let id = id.strip_prefix(NODE_PREFIX).unwrap_or(id);
        self.machines
            .lock()
            .await
            .iter()
            .find(|m| {
                m.id == id
                    || m.provider_id.as_deref() == Some(id)
                    || (m.state.is_live() && !m.name.is_empty() && m.name == id)
            })
            .cloned()
    }

    pub async fn budget(&self) -> BudgetView {
        let machines = self.machines.lock().await;
        let now = Utc::now();
        let today = start_of_today();
        let spent = machines
            .iter()
            .filter(|m| m.created_at >= today || m.state.is_live())
            .map(|m| m.cost_usd)
            .sum::<f64>();
        BudgetView {
            spent_today_usd: (spent * 10000.0).round() / 10000.0,
            committed_usd: machines
                .iter()
                .map(|m| m.remaining_commitment(now))
                .sum::<f64>(),
            daily_cap_usd: self.settings.daily_cap_usd,
            active: machines.iter().filter(|m| m.state.is_live()).count(),
            max_concurrent: self.settings.max_concurrent,
            default_ttl_minutes: self.settings.default_ttl_minutes,
            max_ttl_minutes: self.settings.max_ttl_minutes,
            default_size: self.settings.default_size.clone(),
            max_size: self.settings.max_size.clone(),
            image: self.settings.image.clone(),
        }
    }

    pub async fn list(&self, include_history_hours: i64) -> ListView {
        let cutoff = Utc::now() - chrono::Duration::hours(include_history_hours);
        let mut machines: Vec<_> = self
            .machines
            .lock()
            .await
            .iter()
            .filter(|m| m.state.is_live() || m.created_at >= cutoff)
            .cloned()
            .collect();
        machines.sort_by_key(|m| std::cmp::Reverse(m.created_at));
        ListView {
            enabled: self.settings.enabled && self.provider.is_some(),
            provider: self.settings.provider.clone(),
            machines,
            budget: self.budget().await,
            sizes: SIZES.to_vec(),
        }
    }

    /// Only operator-allowlisted images may be started.
    pub fn resolve_image(
        settings: &ManagedSettings,
        requested: Option<&str>,
    ) -> Result<String, ManagedError> {
        match requested.map(str::trim).filter(|i| !i.is_empty()) {
            None => Ok(settings.image.clone()),
            Some(image) if settings.allowed_images.iter().any(|a| a == image) => {
                Ok(image.to_string())
            }
            Some(image) => Err(ManagedError::new(
                "image_unknown",
                400,
                format!(
                    "Image '{image}' is not allowed; allowed: {}",
                    settings.allowed_images.join(", ")
                ),
            )),
        }
    }

    /// Validate a request against size / TTL policy. Pure, so it is unit-tested.
    pub fn plan(
        settings: &ManagedSettings,
        req: &SpawnRequest,
    ) -> Result<(SizeSpec, u64), ManagedError> {
        let spec = match (
            req.size.as_deref().filter(|s| !s.trim().is_empty()),
            req.cpu,
            req.ram_gb,
        ) {
            (Some(name), cpu, ram) => {
                let spec = size_spec(name).ok_or_else(|| {
                    ManagedError::new(
                        "invalid_size",
                        400,
                        format!("Unknown size '{name}'; use small, default, large or xlarge"),
                    )
                })?;
                if cpu.is_some_and(|c| c > spec.cpu) || ram.is_some_and(|r| r > spec.ram_gb) {
                    return Err(ManagedError::new(
                        "invalid_size",
                        400,
                        format!(
                            "Size '{}' has {} vCPU / {} GB RAM, less than requested",
                            spec.size, spec.cpu, spec.ram_gb
                        ),
                    ));
                }
                spec
            }
            (None, None, None) => size_spec(&settings.default_size).unwrap_or(SIZES[0]),
            (None, cpu, ram) => size_for(cpu, ram).ok_or_else(|| {
                ManagedError::new(
                    "invalid_size",
                    400,
                    "No machine size has that much CPU/RAM (max 16 vCPU / 32 GB)",
                )
            })?,
        };
        if size_rank(spec.size) > size_rank(&settings.max_size) {
            return Err(ManagedError::new(
                "size_not_allowed",
                403,
                format!(
                    "Size '{}' exceeds the allowed maximum '{}'",
                    spec.size, settings.max_size
                ),
            ));
        }
        let ttl = req
            .ttl_minutes
            .unwrap_or(settings.default_ttl_minutes)
            .clamp(5, settings.max_ttl_minutes.max(5));
        Ok((spec, ttl))
    }

    pub async fn spawn(
        self: &Arc<Self>,
        req: SpawnRequest,
    ) -> Result<ManagedMachine, ManagedError> {
        if !self.settings.enabled {
            return Err(ManagedError::new(
                "disabled",
                503,
                "Managed machines are disabled on this backend",
            ));
        }
        let provider = self.provider.clone().ok_or_else(|| {
            ManagedError::new("disabled", 503, "No managed-machine provider is configured")
        })?;
        let core_url = self.settings.core_url.clone().ok_or_else(|| {
            ManagedError::new(
                "disabled",
                503,
                "SANDBOXED_PUBLIC_URL / SANDBOXED_MANAGED_CORE_URL is not set",
            )
        })?;
        let (spec, ttl_minutes) = Self::plan(&self.settings, &req)?;
        let image = Self::resolve_image(&self.settings, req.image.as_deref())?;

        let machine = {
            let _guard = self.admission.lock().await;
            let budget = self.budget().await;
            if budget.active >= self.settings.max_concurrent {
                return Err(ManagedError::new(
                    "quota_exceeded",
                    429,
                    format!(
                        "{} managed machines are running (max {}); destroy one first",
                        budget.active, self.settings.max_concurrent
                    ),
                ));
            }
            let new_cost = ttl_minutes as f64 / 60.0 * spec.usd_per_hour;
            if budget.spent_today_usd + budget.committed_usd + new_cost
                > self.settings.daily_cap_usd
            {
                return Err(ManagedError::new(
                    "budget_exceeded",
                    402,
                    format!(
                        "Daily managed-machine budget ${:.2} would be exceeded (spent ${:.2}, committed ${:.2}, this machine up to ${:.2}); pick a smaller size or shorter TTL",
                        self.settings.daily_cap_usd,
                        budget.spent_today_usd,
                        budget.committed_usd,
                        new_cost
                    ),
                ));
            }
            let id = format!("mm{}", random_id());
            let now = Utc::now();
            let live_names: Vec<String> = self
                .machines
                .lock()
                .await
                .iter()
                .filter(|m| m.state.is_live())
                .map(|m| m.name.clone())
                .collect();
            let name = allocate_name(spec.size, &live_names);
            let machine = ManagedMachine {
                name,
                antigravity_projected: false,
                node_id: format!("{NODE_PREFIX}{id}"),
                id,
                provider: provider.name().into(),
                provider_id: None,
                image: image.clone(),
                size: spec.size.into(),
                cpu: spec.cpu,
                ram_gb: spec.ram_gb,
                disk_gb: spec.disk_gb,
                usd_per_hour: spec.usd_per_hour,
                state: MachineState::Provisioning,
                created_at: now,
                expires_at: now + chrono::Duration::minutes(ttl_minutes as i64),
                online_at: None,
                destroyed_at: None,
                destroy_reason: None,
                cost_usd: 0.0,
                cost_is_metered: false,
                owner_mission_id: req.owner_mission_id.clone(),
                owner_user_id: req.owner_user_id.clone(),
                reason: req.reason.clone(),
                error: None,
                ledger_closed: false,
                last_busy_at: None,
            };
            self.machines.lock().await.push(machine.clone());
            self.persist().await;
            register_alias(&machine);
            machine
        };
        self.ledger("spawn_requested", &machine);

        let this = Arc::clone(self);
        let id = machine.id.clone();
        let task = tokio::spawn(async move {
            let result = this.provision(&id, provider, &core_url, ttl_minutes).await;
            if let Err(error) = &result {
                tracing::warn!(machine = %id, %error, "managed machine failed to come online");
                let _ = this
                    .destroy_inner(&id, Some(format!("provisioning failed: {error}")), true)
                    .await;
            }
            result
        });
        if req.wait.unwrap_or(true) {
            match task.await {
                Ok(Ok(m)) => Ok(m),
                Ok(Err(e)) => Err(ManagedError::new("provision_failed", 502, e)),
                Err(e) => Err(ManagedError::new("provision_failed", 500, e.to_string())),
            }
        } else {
            Ok(self.get(&machine.id).await.unwrap_or(machine))
        }
    }

    async fn provision(
        self: &Arc<Self>,
        id: &str,
        provider: Arc<dyn ManagedProvider>,
        core_url: &str,
        ttl_minutes: u64,
    ) -> Result<ManagedMachine, String> {
        let m = self.get(id).await.ok_or("machine vanished")?;
        // boat stops the sandbox itself at TTL + a small grace, even if Core
        // is down: the hard backstop against runaway cost.
        let spec = SpawnSpec {
            size: m.size.clone(),
            ttl_seconds: ttl_minutes * 60 + 300,
            image: Some(m.image.clone()),
            name: format!("{SANDBOX_NAME_PREFIX}{}", m.id),
            idempotency_key: format!("orb-managed-{}", m.id),
        };
        let created = provider.spawn(&spec).await?;
        let provider_id = created.provider_id.clone();
        self.update(id, |m| m.provider_id = Some(provider_id.clone()))
            .await;
        let m = self.get(id).await.ok_or("machine vanished")?;
        self.ledger("provider_created", &m);

        // Wait for ready.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(240);
        loop {
            if !self.get(id).await.is_some_and(|m| m.state.is_live()) {
                return Err("machine destroyed while provisioning".into());
            }
            match provider.get(&provider_id).await {
                Ok(pm) if boat::is_ready_state(&pm.state) => break,
                Ok(pm) if pm.state == "error" => return Err("provider reported error state".into()),
                _ => {}
            }
            if tokio::time::Instant::now() > deadline {
                return Err("provider machine not ready within 240s".into());
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }

        // One-time enrollment token, delivered as a file (never in a command
        // line: boat keeps command history).
        let enroll_token = random_token();
        {
            let mut secrets = self.secrets.lock().await;
            let entry = secrets.entry(id.to_string()).or_default();
            entry.enroll_token_sha256 = Some(sha256_hex(&enroll_token));
            entry.enroll_expires_at = Some(Utc::now() + chrono::Duration::minutes(10));
            entry.enroll_used = false;
        }
        self.update(id, |m| m.state = MachineState::Enrolling).await;
        let capacity = (m.cpu / 2).max(1);
        // The VM is rented for its memory: let any one job use ~90% of it
        // instead of the static-node default (RAM split across every slot).
        let job_memory = managed_job_memory_bytes(m.ram_gb);
        let env = format!(
            "SANDBOXED_NODE_DIAL_CORE_URL={core_url}\nSANDBOXED_NODE_MANAGED_ID={id}\nSANDBOXED_NODE_ENROLL_TOKEN={enroll_token}\nSANDBOXED_NODE_ID={node}\nSANDBOXED_NODE_CAPACITY={capacity}\nSANDBOXED_NODE_JOB_MEMORY_BYTES={job_memory}\nSANDBOXED_NODE_LABELS=managed,trust=managed,size={size},image={image},lean\n",
            node = m.node_id,
            size = m.size,
            image = m.image,
        );
        let mut wrote = Err(String::new());
        for _ in 0..5 {
            wrote = provider
                .write_file(&provider_id, ENROLL_ENV_PATH, &env)
                .await;
            if wrote.is_ok() {
                break;
            }
            tokio::time::sleep(Duration::from_secs(3)).await;
        }
        wrote.map_err(|e| format!("write enrollment file: {e}"))?;
        provider
            .exec(
                &provider_id,
                "chmod 600 /home/user/.orb/enroll.env && sudo systemctl restart orb-node.service",
                60,
            )
            .await
            .map_err(|e| format!("start orb-node: {e}"))?;

        // Wait for the node to enroll and answer a heartbeat over the relay.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(240);
        let client = crate::remote_node::RemoteNodeClient::default();
        loop {
            if !self.get(id).await.is_some_and(|m| m.state.is_live()) {
                return Err("machine destroyed while enrolling".into());
            }
            if let Some(config) = node_config(&m.node_id) {
                if let Some(token) = node_token(&config.token_env) {
                    if let Ok(hb) = client.heartbeat(config, &token).await {
                        if let Some(fleet) = crate::remote_node::global_fleet() {
                            fleet.record_heartbeat(&config.id, hb);
                        }
                        let m = self
                            .update(id, |m| {
                                m.state = MachineState::Online;
                                m.online_at = Some(Utc::now());
                                m.last_busy_at = Some(Utc::now());
                            })
                            .await
                            .ok_or("machine vanished")?;
                        self.ledger("online", &m);
                        return Ok(m);
                    }
                }
            }
            if tokio::time::Instant::now() > deadline {
                return Err("node did not enroll and answer a heartbeat within 240s".into());
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }

    /// Exchange a one-time enrollment token for the node credential.
    pub async fn enroll(
        &self,
        machine_id: &str,
        enroll_token: &str,
    ) -> Result<(String, String), ManagedError> {
        let denied = || ManagedError::new("enrollment_denied", 401, "Enrollment denied");
        let machine = self.get(machine_id).await.ok_or_else(denied)?;
        if !machine.state.is_live() {
            return Err(denied());
        }
        let token = {
            let mut secrets = self.secrets.lock().await;
            let entry = secrets.get_mut(&machine.id).ok_or_else(denied)?;
            let valid = !entry.enroll_used
                && entry.enroll_expires_at.is_some_and(|exp| exp > Utc::now())
                && entry
                    .enroll_token_sha256
                    .as_deref()
                    .is_some_and(|h| constant_time_eq(h, &sha256_hex(enroll_token)));
            if !valid {
                return Err(denied());
            }
            entry.enroll_used = true;
            entry.enroll_token_sha256 = None;
            let token = random_token();
            entry.node_token = Some(token.clone());
            token
        };
        register_node(&machine, self.core_port, &token);
        self.persist().await;
        self.ledger("enrolled", &machine);
        Ok((machine.node_id.clone(), token))
    }

    /// Machine owning a presented node credential, if live.
    pub async fn machine_for_token(&self, machine_id: &str, token: &str) -> Option<ManagedMachine> {
        let machine = self.get(machine_id).await?;
        if !machine.state.is_live() {
            return None;
        }
        let secrets = self.secrets.lock().await;
        let expected = secrets.get(&machine.id)?.node_token.as_deref()?;
        constant_time_eq(expected, token).then_some(machine)
    }

    pub async fn extend(&self, id: &str, ttl_minutes: u64) -> Result<ManagedMachine, ManagedError> {
        let m = self
            .get(id)
            .await
            .ok_or_else(|| ManagedError::new("not_found", 404, "Unknown managed machine"))?;
        if !m.state.is_live() {
            return Err(ManagedError::new("not_live", 409, "Machine is not running"));
        }
        let ttl = ttl_minutes.clamp(5, self.settings.max_ttl_minutes);
        let max_end =
            m.created_at + chrono::Duration::minutes(self.settings.max_ttl_minutes as i64);
        // Adds to the current deadline (never shortens it).
        let new_end =
            (m.expires_at.max(Utc::now()) + chrono::Duration::minutes(ttl as i64)).min(max_end);
        if let (Some(p), Some(pid)) = (&self.provider, &m.provider_id) {
            let secs = (new_end - Utc::now()).num_seconds().max(60) as u64 + 300;
            p.extend(pid, secs)
                .await
                .map_err(|e| ManagedError::new("provider_error", 502, e))?;
        }
        Ok(self
            .update(&m.id, |m| m.expires_at = new_end)
            .await
            .unwrap_or(m))
    }

    pub async fn destroy(&self, id: &str, reason: &str) -> Result<ManagedMachine, ManagedError> {
        let m = self
            .get(id)
            .await
            .ok_or_else(|| ManagedError::new("not_found", 404, "Unknown managed machine"))?;
        self.destroy_inner(&m.id, Some(reason.to_string()), false)
            .await
    }

    async fn destroy_inner(
        &self,
        id: &str,
        reason: Option<String>,
        failed: bool,
    ) -> Result<ManagedMachine, ManagedError> {
        let Some(m) = self
            .update(id, |m| {
                if m.state.is_live() {
                    m.state = MachineState::Destroying;
                    if m.destroy_reason.is_none() {
                        m.destroy_reason = reason.clone();
                    }
                    if failed {
                        m.error = reason.clone();
                    }
                }
            })
            .await
        else {
            return Err(ManagedError::new(
                "not_found",
                404,
                "Unknown managed machine",
            ));
        };
        unregister_node(&m);
        self.relay.close(&m.id).await;
        if let (Some(provider), Some(pid)) = (&self.provider, &m.provider_id) {
            // Wipe a projected sign-in before the disk is retained by the
            // provider (boat keeps stopped disks for 14 days).
            if m.antigravity_projected {
                let wiped = provider
                    .exec(
                        pid,
                        "sudo rm -rf /var/lib/orb-node/work/managed-auth /var/lib/orb-node/node.cred && sync",
                        60,
                    )
                    .await;
                if let Err(e) = &wiped {
                    tracing::warn!(machine = %m.id, error = %e, "could not wipe projected sign-in before destroy");
                }
                self.ledger(
                    if wiped.is_ok() {
                        "antigravity_wiped"
                    } else {
                        "antigravity_wipe_failed"
                    },
                    &m,
                );
            }
            let mut last = Ok(());
            for _ in 0..3 {
                last = provider.destroy(pid).await;
                if last.is_ok() {
                    break;
                }
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
            if let Err(e) = last {
                // Leave it Destroying; the reconciler retries.
                self.update(id, |m| m.error = Some(format!("destroy failed: {e}")))
                    .await;
                return Err(ManagedError::new("provider_error", 502, e));
            }
        }
        let m = self
            .update(id, |m| {
                m.state = if failed {
                    MachineState::Failed
                } else {
                    MachineState::Destroyed
                };
                m.destroyed_at = Some(Utc::now());
                if m.provider_id.is_none() {
                    m.ledger_closed = true;
                }
                if !m.cost_is_metered {
                    m.cost_usd = m.estimated_cost(Utc::now());
                }
            })
            .await
            .unwrap_or(m);
        self.ledger("destroyed", &m);
        // Close the ledger with the metered cost once the provider confirms.
        self.refresh_usage(id).await;
        Ok(self.get(id).await.unwrap_or(m))
    }

    async fn refresh_usage(&self, id: &str) {
        let Some(m) = self.get(id).await else { return };
        let (Some(provider), Some(pid)) = (&self.provider, &m.provider_id) else {
            return;
        };
        if m.ledger_closed {
            return;
        }
        if let Ok(usage) = provider.usage(pid).await {
            let closed = !usage.running && !m.state.is_live();
            if let Some(m) = self
                .update(id, |m| {
                    m.cost_usd = usage.dollars;
                    m.cost_is_metered = true;
                    if closed {
                        m.ledger_closed = true;
                    }
                })
                .await
            {
                if closed {
                    self.ledger("ledger_closed", &m);
                }
            }
        }
    }

    /// One reaper pass: TTL, idle and cost refresh. Reconcile runs separately.
    pub async fn reap_once(&self) {
        let now = Utc::now();
        let machines = self.machines.lock().await.clone();
        let fleet = crate::remote_node::global_fleet();
        for m in machines {
            match m.state {
                MachineState::Online | MachineState::Enrolling | MachineState::Provisioning => {
                    if now >= m.expires_at {
                        let _ = self
                            .destroy_inner(&m.id, Some("ttl_expired".into()), false)
                            .await;
                        continue;
                    }
                    if m.state == MachineState::Online {
                        let busy = fleet
                            .as_ref()
                            .and_then(|f| f.get(&m.node_id))
                            .and_then(|c| c.last_heartbeat)
                            .is_some_and(|hb| {
                                hb.active_jobs > 0 || hb.active_leases > 0 || hb.queued_jobs > 0
                            });
                        // The owning mission ended: destroy now unless a job
                        // (e.g. a child still running there) keeps it busy.
                        if !busy {
                            if let (Some(owner), Some(tenant)) =
                                (m.owner_mission_id.clone(), m.owner_user_id.clone())
                            {
                                let probe = self.owner_probe.read().ok().and_then(|p| p.clone());
                                if let Some(probe) = probe {
                                    if matches!(
                                        probe(tenant, owner).await,
                                        Some(OwnerState::Terminal | OwnerState::Missing)
                                    ) {
                                        let _ = self
                                            .destroy_inner(&m.id, Some("owner_ended".into()), false)
                                            .await;
                                        continue;
                                    }
                                }
                            }
                        }
                        if busy {
                            self.update(&m.id, |m| m.last_busy_at = Some(now)).await;
                        } else if self.settings.idle_minutes > 0 {
                            let since = m.last_busy_at.unwrap_or(m.created_at);
                            if (now - since).num_minutes() >= self.settings.idle_minutes as i64 {
                                let _ = self.destroy_inner(&m.id, Some("idle".into()), false).await;
                                continue;
                            }
                        }
                    }
                    if !m.cost_is_metered || now.timestamp() % 300 < 31 {
                        let est = m.estimated_cost(now);
                        self.update(&m.id, |m| {
                            if !m.cost_is_metered || est > m.cost_usd {
                                m.cost_usd = est;
                            }
                        })
                        .await;
                    }
                }
                MachineState::Destroying => {
                    let _ = self.destroy_inner(&m.id, None, false).await;
                }
                MachineState::Destroyed | MachineState::Failed => {
                    if !m.ledger_closed {
                        self.refresh_usage(&m.id).await;
                    }
                }
            }
        }
    }

    /// Compare provider state with the registry: stop orphans (our tagged
    /// sandboxes with no live registry row) and close rows whose machine
    /// the provider already stopped.
    pub async fn reconcile_once(&self) -> Result<Value, String> {
        let Some(provider) = &self.provider else {
            return Ok(serde_json::json!({"skipped": "no provider"}));
        };
        let remote = provider.list().await?;
        let machines = self.machines.lock().await.clone();
        let mut orphans_stopped = Vec::new();
        for pm in &remote {
            if !pm.name.starts_with(SANDBOX_NAME_PREFIX) || boat::is_stopped_state(&pm.state) {
                continue;
            }
            let live = machines
                .iter()
                .any(|m| m.provider_id.as_deref() == Some(&pm.provider_id) && m.state.is_live());
            if !live {
                tracing::warn!(sandbox = %pm.provider_id, "stopping orphan managed sandbox");
                if provider.destroy(&pm.provider_id).await.is_ok() {
                    orphans_stopped.push(pm.provider_id.clone());
                }
            }
        }
        let mut closed = Vec::new();
        for m in machines.iter().filter(|m| m.state.is_live()) {
            let Some(pid) = &m.provider_id else { continue };
            if let Some(pm) = remote.iter().find(|p| &p.provider_id == pid) {
                if boat::is_stopped_state(&pm.state) && m.state == MachineState::Online {
                    let _ = self
                        .destroy_inner(&m.id, Some("stopped_by_provider".into()), false)
                        .await;
                    closed.push(m.id.clone());
                }
            }
        }
        Ok(serde_json::json!({
            "provider_machines": remote.len(),
            "orphans_stopped": orphans_stopped,
            "closed_rows": closed,
        }))
    }
}

/// Per-job memory ceiling on a managed VM: 90% of its RAM (GiB).
pub fn managed_job_memory_bytes(ram_gb: u32) -> u64 {
    u64::from(ram_gb) * 1024 * 1024 * 1024 * 9 / 10
}

fn write_atomic(path: &std::path::Path, bytes: &[u8], private: bool) {
    let tmp = path.with_extension("tmp");
    if std::fs::write(&tmp, bytes).is_ok() {
        #[cfg(unix)]
        if private {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
        }
        let _ = std::fs::rename(&tmp, path);
    }
}

/// Build the global manager, load the registry and start the reaper and
/// reconciler loops. Safe to call once at startup.
pub async fn start(working_dir: &std::path::Path, core_port: u16) -> Arc<ManagedManager> {
    let provider = boat::BoatProvider::from_env().map(|p| Arc::new(p) as Arc<dyn ManagedProvider>);
    let settings = ManagedSettings::from_env(provider.is_some());
    let manager = Arc::new(ManagedManager::new(
        settings,
        provider,
        working_dir,
        core_port,
    ));
    manager.load().await;
    let _ = MANAGER.set(Arc::clone(&manager));
    if manager.settings.enabled && manager.provider.is_some() {
        tracing::info!(
            daily_cap = manager.settings.daily_cap_usd,
            max_concurrent = manager.settings.max_concurrent,
            "Managed machines enabled (boat)"
        );
        let reaper = Arc::clone(&manager);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(30)).await;
                reaper.reap_once().await;
            }
        });
        let rec = Arc::clone(&manager);
        tokio::spawn(async move {
            // First pass soon after start (catches machines orphaned by a crash).
            tokio::time::sleep(Duration::from_secs(20)).await;
            loop {
                match rec.reconcile_once().await {
                    Ok(report) => tracing::debug!(%report, "managed reconcile"),
                    Err(e) => tracing::warn!(error = %e, "managed reconcile failed"),
                }
                tokio::time::sleep(Duration::from_secs(rec.settings.reconcile_secs.max(30))).await;
            }
        });
    }
    manager
}

#[cfg(test)]
mod tests;
