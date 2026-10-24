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
//! `SANDBOXED_MANAGED_DAILY_CAP_USD` (20; `none` = unlimited),
//! `SANDBOXED_MANAGED_MAX_CONCURRENT` (6; `none` = unlimited), `SANDBOXED_MANAGED_DEFAULT_TTL_MINUTES` (60),
//! `SANDBOXED_MANAGED_AUTO_EXTEND_MINUTES` (30; 0 = off),
//! `SANDBOXED_MANAGED_MAX_TTL_MINUTES` (720), `SANDBOXED_MANAGED_DEFAULT_SIZE`
//! (small), `SANDBOXED_MANAGED_MAX_SIZE` (xlarge), `SANDBOXED_MANAGED_IMAGE`
//! (orb-node-base), `SANDBOXED_MANAGED_CORE_URL` (defaults to
//! `SANDBOXED_PUBLIC_URL`), `SANDBOXED_MANAGED_IDLE_MINUTES` (30),
//! `SANDBOXED_MANAGED_OWNER_GRACE_MINUTES` (5),
//! `SANDBOXED_MANAGED_WAITING_GRACE_MINUTES` (15),
//! `SANDBOXED_MANAGED_STOPPED_RETENTION_HOURS` (24), `SANDBOXED_MANAGED_SNAPSHOT_KEEP` (2),
//! `SANDBOXED_MANAGED_SNAPSHOT_UNUSED_DAYS` (14),
//! `SANDBOXED_MANAGED_ORPHAN_GRACE_MINUTES` (10),
//! `SANDBOXED_MANAGED_RECONCILE_SECS` (120).
//!
//! Lifecycle (ownership, reaping, reconciliation): `docs/specs/managed-vm-lifecycle.md`.

pub mod boat;
pub mod budget;
pub mod lifecycle;
pub mod relay;
pub mod snapshots;

pub use lifecycle::{owner_state_for_status, LifecyclePolicy, Owner, OwnerState, ReapDecision};

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
const PROVISION_PATH: &str = "/home/user/.orb/provision.sh";
/// Per-VM fixups run as root before orb-node starts (writable
/// `/tmp/opencode`, GitHub credential helper, user rustup env).
pub const PROVISION_SCRIPT: &str = include_str!("orb-node-provision.sh");

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
    /// Stop (keep the disk for resume/fork). Nothing is billed afterwards.
    async fn stop(&self, provider_id: &str) -> Result<(), String> {
        self.destroy(provider_id).await
    }
    /// New sandbox from the latest snapshot of `provider_id` (running or
    /// stopped). The copy can be up to about a minute stale.
    async fn fork(&self, _provider_id: &str, _spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        Err("fork is not supported by this provider".into())
    }
    /// Save a named snapshot of a sandbox (async: poll `snapshot`).
    async fn save_snapshot(&self, _provider_id: &str, _name: &str) -> Result<(), String> {
        Err("snapshots are not supported by this provider".into())
    }
    async fn snapshot(&self, _name: &str) -> Result<ProviderSnapshot, String> {
        Err("snapshots are not supported by this provider".into())
    }
    async fn delete_snapshot(&self, _name: &str) -> Result<(), String> {
        Err("snapshots are not supported by this provider".into())
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ProviderSnapshot {
    pub name: String,
    /// `saving`, `ready` or `failed`.
    pub status: String,
    pub size_bytes: Option<u64>,
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
    /// `None` = no daily dollar cap (explicit `none` only; default $20).
    pub daily_cap_usd: Option<f64>,
    /// `None` = no concurrency cap (explicit `none` only; default 6).
    pub max_concurrent: Option<usize>,
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
    /// Grace after the owner mission ended or vanished.
    pub owner_grace_minutes: u64,
    /// How long an owner may be interrupted/awaiting before its idle VM goes.
    pub waiting_grace_minutes: u64,
    /// Grace before a provider VM unknown to the registry is stopped.
    pub orphan_grace_minutes: u64,
    pub reconcile_secs: u64,
    /// Minutes added to a busy machine's TTL when it is about to expire
    /// (0 disables auto-extend). Each chunk is checked against budgets.
    pub auto_extend_minutes: u64,
    /// How long a stopped machine may be resumed before it is closed
    /// (boat keeps the disk 14 days).
    pub stopped_retention_hours: u64,
    /// Warm snapshots kept per project by the cleanup.
    pub snapshot_keep: usize,
    /// Snapshots unused this long are deleted by the cleanup.
    pub snapshot_unused_days: i64,
}

impl ManagedSettings {
    pub fn policy(&self) -> LifecyclePolicy {
        LifecyclePolicy {
            idle_minutes: self.idle_minutes as i64,
            ended_grace_minutes: self.owner_grace_minutes as i64,
            waiting_grace_minutes: self.waiting_grace_minutes as i64,
        }
    }
}

fn env_parse<T: std::str::FromStr>(key: &str) -> Option<T> {
    std::env::var(key).ok().and_then(|v| v.trim().parse().ok())
}

/// Parse an operator limit. Only an explicit `none`, `unlimited` or `off`
/// removes it. Unset, empty, zero, negative or malformed values keep the
/// built-in safe default, so a typo can never lift a cost guard.
pub fn optional_limit<T: std::str::FromStr + PartialOrd + Default>(
    raw: Option<&str>,
    default: T,
) -> Option<T> {
    let Some(raw) = raw.map(str::trim).filter(|r| !r.is_empty()) else {
        return Some(default);
    };
    if ["none", "unlimited", "off"].contains(&raw.to_ascii_lowercase().as_str()) {
        return None;
    }
    Some(
        raw.parse::<T>()
            .ok()
            .filter(|v| *v > T::default())
            .unwrap_or(default),
    )
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
            daily_cap_usd: optional_limit(
                std::env::var("SANDBOXED_MANAGED_DAILY_CAP_USD")
                    .ok()
                    .as_deref(),
                20.0,
            ),
            max_concurrent: optional_limit(
                std::env::var("SANDBOXED_MANAGED_MAX_CONCURRENT")
                    .ok()
                    .as_deref(),
                6,
            ),
            default_ttl_minutes: env_parse::<u64>("SANDBOXED_MANAGED_DEFAULT_TTL_MINUTES")
                .unwrap_or(60)
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
            idle_minutes: env_parse("SANDBOXED_MANAGED_IDLE_MINUTES").unwrap_or(30),
            owner_grace_minutes: env_parse("SANDBOXED_MANAGED_OWNER_GRACE_MINUTES").unwrap_or(5),
            waiting_grace_minutes: env_parse("SANDBOXED_MANAGED_WAITING_GRACE_MINUTES")
                .unwrap_or(15),
            orphan_grace_minutes: env_parse("SANDBOXED_MANAGED_ORPHAN_GRACE_MINUTES").unwrap_or(10),
            reconcile_secs: env_parse("SANDBOXED_MANAGED_RECONCILE_SECS").unwrap_or(120),
            auto_extend_minutes: env_parse("SANDBOXED_MANAGED_AUTO_EXTEND_MINUTES").unwrap_or(30),
            stopped_retention_hours: env_parse("SANDBOXED_MANAGED_STOPPED_RETENTION_HOURS")
                .unwrap_or(24),
            snapshot_keep: env_parse("SANDBOXED_MANAGED_SNAPSHOT_KEEP").unwrap_or(2),
            snapshot_unused_days: env_parse("SANDBOXED_MANAGED_SNAPSHOT_UNUSED_DAYS").unwrap_or(14),
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
    /// Stopped with its disk kept (boat keeps it 14 days): costs nothing,
    /// can be resumed (as a fork of the stopped sandbox, same node id).
    Stopped,
}

impl MachineState {
    pub fn is_live(self) -> bool {
        !matches!(self, Self::Destroyed | Self::Failed | Self::Stopped)
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
    /// The mission this machine serves: its lifetime governs the machine.
    #[serde(default)]
    pub owner_mission_id: Option<String>,
    /// The mission that asked for it (e.g. the caller of `start_mission`
    /// with `auto-managed`), when different from the owner. Informational:
    /// it does not keep the machine alive.
    #[serde(default)]
    pub requested_by_mission_id: Option<String>,
    /// `mission` or `user` (created from Orb/API without a mission). Absent on
    /// legacy rows: shown as "No owner".
    #[serde(default)]
    pub owner_kind: Option<String>,
    /// Tenant (user id) whose mission store holds `owner_mission_id`.
    #[serde(default)]
    pub owner_user_id: Option<String>,
    #[serde(default)]
    pub reason: Option<String>,
    /// When the reaper will destroy this machine, if a rule applies.
    #[serde(default)]
    pub reap_at: Option<DateTime<Utc>>,
    /// The `destroy_reason` the scheduled reap will record.
    #[serde(default)]
    pub reap_reason: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    pub ledger_closed: bool,
    #[serde(default)]
    pub last_busy_at: Option<DateTime<Utc>>,
    /// Mission budget pool this machine is charged to (`budget.rs`); `None`
    /// when no pool applies (only the daily cap).
    #[serde(default)]
    pub budget_pool_id: Option<String>,
    /// Automatic TTL extensions granted while the node was busy.
    #[serde(default)]
    pub auto_extensions: u32,
    /// When it was stopped (state `Stopped`).
    #[serde(default)]
    pub stopped_at: Option<DateTime<Utc>>,
    /// Stopped by the reaper while its owner waited: resumed automatically
    /// when the owner works again.
    #[serde(default)]
    pub stopped_by_reaper: bool,
    /// Named snapshot this machine was created from (registry name).
    #[serde(default)]
    pub source_snapshot: Option<String>,
    /// Machine this one was forked from (fork_managed_machine).
    #[serde(default)]
    pub forked_from: Option<String>,
    /// Provider sandbox the next provisioning forks from (fork or resume);
    /// cleared once provisioning starts.
    #[serde(default)]
    pub fork_source_provider_id: Option<String>,
    /// Start of the current run (after a resume); `created_at` otherwise.
    #[serde(default)]
    pub run_started_at: Option<DateTime<Utc>>,
    /// Cost of the runs before the last resume (their sandboxes are
    /// metered separately by the provider).
    #[serde(default)]
    pub cost_before_resume: f64,
    /// Times this machine was resumed from `Stopped`.
    #[serde(default)]
    pub resumes: u32,
    /// Cost already charged to earlier pools when the VM changed pool
    /// (reuse, claim): `(pool id, usd)`. The current pool is charged only
    /// `spent - pool_spent_offset`.
    #[serde(default)]
    pub prior_pool_charges: Vec<(String, f64)>,
    #[serde(default)]
    pub pool_spent_offset: f64,
}

impl ManagedMachine {
    /// Move the VM to `pool`: what it cost so far stays with the old pool,
    /// only future cost is charged to the new one.
    pub fn change_pool(&mut self, pool: Option<String>, now: DateTime<Utc>) {
        if self.budget_pool_id == pool {
            return;
        }
        let spent = budget::machine_spent(self, now);
        if let Some(old) = self.budget_pool_id.take() {
            let share = (spent - self.pool_spent_offset).max(0.0);
            if share > 0.0 {
                self.prior_pool_charges.push((old, share));
            }
        }
        self.pool_spent_offset = spent;
        self.budget_pool_id = pool;
    }

    fn estimated_cost(&self, now: DateTime<Utc>) -> f64 {
        let end = self
            .destroyed_at
            .or(self.stopped_at)
            .unwrap_or(now)
            .min(self.expires_at);
        let start = self.run_started_at.unwrap_or(self.created_at);
        let secs = (end - start).num_seconds().max(0) as f64;
        self.cost_before_resume + secs / 3600.0 * self.usd_per_hour
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
    #[serde(default)]
    pub requested_by_mission_id: Option<String>,
    /// Set by the API from the authenticated caller; never from the body.
    #[serde(skip)]
    pub owner_user_id: Option<String>,
    /// Wait until the node is online (default true).
    pub wait: Option<bool>,
    /// Budget pool the machine is charged to. Resolved by the API from the
    /// caller's mission lineage; never from the body.
    #[serde(skip)]
    pub budget_pool_id: Option<String>,
    /// The machine is for a child that will get this sub-budget: the
    /// reservation must fit it (and the pool it is carved from).
    #[serde(default)]
    pub sub_budget_usd: Option<f64>,
    /// Create from this named snapshot (registry name from
    /// `list_managed_snapshots`) instead of the default image.
    #[serde(default)]
    pub from_snapshot: Option<String>,
    /// Fork this machine (id/name): set by the API from the path, never
    /// from a body.
    #[serde(skip)]
    pub fork_of: Option<String>,
    /// Prefer an idle machine of the same size whose owner (a child of the
    /// requester) has ended, inside its grace window, over a fresh rent.
    #[serde(default)]
    pub reuse_idle: Option<bool>,
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

pub type OwnerProbe = Arc<
    dyn Fn(
            String,
            String,
        )
            -> std::pin::Pin<Box<dyn std::future::Future<Output = Option<OwnerState>> + Send>>
        + Send
        + Sync,
>;

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
    budgets: Mutex<HashMap<String, budget::BudgetPool>>,
    snapshots: Mutex<Vec<snapshots::ManagedSnapshot>>,
    secrets: Mutex<HashMap<String, MachineSecrets>>,
    /// Serialises spawn admission so two callers cannot both pass the caps.
    admission: Mutex<()>,
    pub relay: relay::RelayHub,
    owner_probe: std::sync::RwLock<Option<OwnerProbe>>,
    runtime: std::sync::RwLock<RuntimeSettings>,
    /// Reconciler memory (not persisted; a restart restarts the graces).
    reconcile_state: Mutex<ReconcileState>,
}

#[derive(Default)]
struct ReconcileState {
    /// Provider VM id -> first pass that saw it unknown to the registry.
    orphans_seen: HashMap<String, DateTime<Utc>>,
    /// Registry id -> consecutive passes whose provider list lacked its VM.
    vanished_passes: HashMap<String, u32>,
    /// "machine:reason" already reported as `would_reap` (dry-run).
    would_reap_logged: std::collections::HashSet<String>,
}

/// One row of the reap plan (`GET /api/managed-machines/reap-plan`).
#[derive(Debug, Clone, Serialize)]
pub struct ReapPlanEntry {
    pub machine_id: String,
    pub name: String,
    pub owner_mission_id: Option<String>,
    pub owner_kind: Option<String>,
    pub busy: bool,
    pub owner_state: Option<String>,
    #[serde(flatten)]
    pub decision: ReapDecision,
}

/// Operator toggles persisted in `managed_settings.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeSettings {
    /// Project the owner's Antigravity (Google) sign-in onto managed VMs the
    /// owner rented. Default on (`SANDBOXED_MANAGED_ANTIGRAVITY=0` disables).
    #[serde(default = "default_true")]
    pub antigravity_on_managed: bool,
    /// Lifecycle reaper in dry-run: owner/idle/orphan decisions are recorded
    /// (`would_reap` in the ledger, `reap_at` on the row) but nothing is
    /// destroyed. TTL expiry always destroys. Default on until an operator
    /// has reviewed `GET /api/managed-machines/reap-plan`.
    #[serde(default = "default_true")]
    pub reaper_dry_run: bool,
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
            reaper_dry_run: !matches!(
                std::env::var("SANDBOXED_MANAGED_REAPER_DRY_RUN")
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
    /// `null` = unlimited.
    pub daily_cap_usd: Option<f64>,
    pub active: usize,
    /// `null` = unlimited.
    pub max_concurrent: Option<usize>,
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
    /// Last `SPEND_DAYS` UTC days, oldest first.
    pub daily_spend: Vec<DailySpend>,
}

/// Days of history `list` returns in `daily_spend`.
pub const SPEND_DAYS: u32 = 7;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct SpendPart {
    /// Owner mission id, or `null` for machines without one.
    pub mission_id: Option<String>,
    pub usd: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct SizeSpend {
    pub size: String,
    pub usd: f64,
}

/// One UTC day of managed-machine spend.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct DailySpend {
    /// `YYYY-MM-DD` (UTC).
    pub day: String,
    pub usd: f64,
    /// Highest spend first.
    pub missions: Vec<SpendPart>,
    /// Highest spend first.
    pub sizes: Vec<SizeSpend>,
}

fn round4(v: f64) -> f64 {
    (v * 10000.0).round() / 10000.0
}

/// Spend per UTC day over the last `days` days (oldest first, today last).
/// Each machine's cost (metered, or estimated so far while live and
/// unmetered) is spread evenly over the time it ran, so a machine that runs
/// past midnight counts on both days. One pass over the registry.
pub fn daily_spend(machines: &[ManagedMachine], days: u32, now: DateTime<Utc>) -> Vec<DailySpend> {
    let days = days.clamp(1, 90) as i64;
    let today = now.date_naive();
    let first = today - chrono::Duration::days(days - 1);
    let mut totals = vec![0.0f64; days as usize];
    let mut missions: Vec<HashMap<Option<String>, f64>> = vec![HashMap::new(); days as usize];
    let mut sizes: Vec<HashMap<String, f64>> = vec![HashMap::new(); days as usize];
    for m in machines {
        let cost = if m.state.is_live() && !m.cost_is_metered {
            m.cost_usd.max(m.estimated_cost(now))
        } else {
            m.cost_usd
        };
        if cost <= 0.0 {
            continue;
        }
        let start = m.created_at;
        let end = m.destroyed_at.unwrap_or(now).max(start);
        if end.date_naive() < first {
            continue;
        }
        let span = (end - start).num_milliseconds() as f64;
        let mut day = start.date_naive().max(first);
        while day <= end.date_naive() && day <= today {
            let d0 = day.and_hms_opt(0, 0, 0).unwrap().and_utc();
            let d1 = d0 + chrono::Duration::days(1);
            let share = if span <= 0.0 {
                1.0
            } else {
                ((end.min(d1) - start.max(d0)).num_milliseconds().max(0) as f64) / span
            };
            let usd = cost * share;
            if usd > 0.0 {
                let i = (day - first).num_days() as usize;
                totals[i] += usd;
                *missions[i].entry(m.owner_mission_id.clone()).or_default() += usd;
                *sizes[i].entry(m.size.clone()).or_default() += usd;
            }
            day += chrono::Duration::days(1);
        }
    }
    let by_usd = |a: &f64, b: &f64| b.partial_cmp(a).unwrap_or(std::cmp::Ordering::Equal);
    (0..days as usize)
        .map(|i| {
            let mut ms: Vec<SpendPart> = missions[i]
                .drain()
                .map(|(mission_id, usd)| SpendPart {
                    mission_id,
                    usd: round4(usd),
                })
                .collect();
            ms.sort_by(|a, b| by_usd(&a.usd, &b.usd).then_with(|| a.mission_id.cmp(&b.mission_id)));
            let mut ss: Vec<SizeSpend> = sizes[i]
                .drain()
                .map(|(size, usd)| SizeSpend {
                    size,
                    usd: round4(usd),
                })
                .collect();
            ss.sort_by(|a, b| by_usd(&a.usd, &b.usd).then_with(|| a.size.cmp(&b.size)));
            DailySpend {
                day: (first + chrono::Duration::days(i as i64)).to_string(),
                usd: round4(totals[i]),
                missions: ms,
                sizes: ss,
            }
        })
        .collect()
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
            budgets: Mutex::new(HashMap::new()),
            snapshots: Mutex::new(Vec::new()),
            secrets: Mutex::new(HashMap::new()),
            admission: Mutex::new(()),
            relay: relay::RelayHub::default(),
            owner_probe: std::sync::RwLock::new(None),
            runtime: std::sync::RwLock::new(RuntimeSettings::default()),
            reconcile_state: Mutex::new(ReconcileState::default()),
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
            .update(&m.id, |m| {
                m.owner_mission_id = Some(mission_id.to_string());
                m.owner_kind = Some("mission".into());
            })
            .await?;
        self.ledger("adopted", &m);
        Some(m)
    }

    /// Give a machine to the mission it was rented for. Only an unowned
    /// machine, or one owned by `requested_by` (the caller that rented it
    /// for this mission), can be claimed: a mission never takes over another
    /// tree's machine this way.
    pub async fn claim_for_mission(
        &self,
        id: &str,
        mission_id: &str,
        requested_by: Option<&str>,
        tenant: Option<&str>,
    ) -> Result<ManagedMachine, ManagedError> {
        let m = self
            .get(id)
            .await
            .ok_or_else(|| ManagedError::new("not_found", 404, "Unknown managed machine"))?;
        if !m.state.is_live() {
            return Err(ManagedError::new("not_live", 409, "Machine is not running"));
        }
        // Tenant boundary: only the machine's own user may claim it. A row
        // without a recorded tenant (legacy) belongs to the single owner.
        if let (Some(owner), Some(caller)) = (m.owner_user_id.as_deref(), tenant) {
            if owner != caller {
                return Err(ManagedError::new(
                    "forbidden",
                    403,
                    "Managed machine belongs to another user",
                ));
            }
        } else if m.owner_user_id.is_some() && tenant.is_none() {
            return Err(ManagedError::new(
                "forbidden",
                403,
                "Managed machine belongs to another user",
            ));
        }
        if m.owner_mission_id.as_deref() == Some(mission_id) {
            return Ok(m);
        }
        let claimable = match m.owner_mission_id.as_deref() {
            None => true,
            Some(current) => requested_by == Some(current),
        };
        if !claimable {
            return Err(ManagedError::new(
                "owned",
                409,
                "Managed machine already belongs to another mission",
            ));
        }
        let m = self
            .update(&m.id, |m| {
                let previous = m.owner_mission_id.take();
                m.requested_by_mission_id = requested_by
                    .map(str::to_string)
                    .or(previous)
                    .or(m.requested_by_mission_id.take())
                    .filter(|r| r != mission_id);
                m.owner_mission_id = Some(mission_id.to_string());
                m.owner_kind = Some("mission".into());
                if m.owner_user_id.is_none() {
                    m.owner_user_id = tenant.map(str::to_string);
                }
                m.reap_at = None;
                m.reap_reason = None;
            })
            .await
            .ok_or_else(|| ManagedError::new("not_found", 404, "Unknown managed machine"))?;
        self.ledger("owner_set", &m);
        Ok(m)
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
    fn budgets_path(&self) -> PathBuf {
        self.dir.join("mission_budgets.json")
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
        self.load_snapshots().await;
        if let Some(b) = std::fs::read(self.budgets_path())
            .ok()
            .and_then(|b| serde_json::from_slice::<HashMap<String, budget::BudgetPool>>(&b).ok())
        {
            *self.budgets.lock().await = b;
        }
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
        self.ledger_with(event, machine, Value::Null);
    }

    fn ledger_with(&self, event: &str, machine: &ManagedMachine, extra: Value) {
        use std::io::Write;
        let mut line = serde_json::json!({
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
            "budget_pool_id": machine.budget_pool_id,
        });
        if let (Some(line), Some(extra)) = (line.as_object_mut(), extra.as_object()) {
            for (k, v) in extra {
                line.insert(k.clone(), v.clone());
            }
        }
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
            .filter(|m| {
                m.state.is_live() || m.state == MachineState::Stopped || m.created_at >= cutoff
            })
            .cloned()
            .collect();
        machines.sort_by_key(|m| std::cmp::Reverse(m.created_at));
        let daily_spend = self.daily_spend(SPEND_DAYS).await;
        ListView {
            enabled: self.settings.enabled && self.provider.is_some(),
            provider: self.settings.provider.clone(),
            machines,
            budget: self.budget().await,
            sizes: SIZES.to_vec(),
            daily_spend,
        }
    }

    pub async fn daily_spend(&self, days: u32) -> Vec<DailySpend> {
        daily_spend(&self.machines.lock().await, days, Utc::now())
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
        if !crate::orb_spec::vm_spawn_admit(crate::orb_spec::VmSpawnInput {
            size_rank: size_rank(spec.size) as u8,
            max_size_rank: size_rank(&settings.max_size) as u8,
            secret_projected: false,
            active_count: 0,
            max_concurrent: 1,
            ttl_minutes: ttl as u32,
            max_ttl_minutes: settings.max_ttl_minutes.max(5) as u32,
            job_mem_pct: 90,
            spent_plus_new_cents: 0,
            daily_cap_cents: 1,
        }) {
            return Err(ManagedError::new(
                "size_not_allowed",
                403,
                format!(
                    "Size '{}' exceeds the allowed maximum '{}'",
                    spec.size, settings.max_size
                ),
            ));
        }
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
        let (image, source_snapshot, fork_source) = self.resolve_source(&req).await?;

        let machine = {
            let _guard = self.admission.lock().await;
            let budget = self.budget().await;
            if let Some(max) = self.settings.max_concurrent {
                if budget.active >= max {
                    return Err(ManagedError::new(
                        "quota_exceeded",
                        429,
                        format!(
                            "{} managed machines are running (max {max}); destroy one first",
                            budget.active
                        ),
                    ));
                }
            }
            let new_cost = ttl_minutes as f64 / 60.0 * spec.usd_per_hour;
            if let Some(cap) = self
                .settings
                .daily_cap_usd
                .filter(|cap| budget.spent_today_usd + budget.committed_usd + new_cost > *cap)
            {
                return Err(ManagedError::new(
                    "budget_exceeded",
                    402,
                    format!(
                        "Daily managed-machine budget ${:.2} would be exceeded (spent ${:.2}, committed ${:.2}, this machine up to ${:.2}); pick a smaller size or shorter TTL",
                        cap,
                        budget.spent_today_usd,
                        budget.committed_usd,
                        new_cost
                    ),
                ));
            }
            let reserve = budget::reservation_for(ttl_minutes, spec.usd_per_hour);
            if let Some(sub) = req.sub_budget_usd {
                if reserve > sub {
                    return Err(ManagedError::new(
                        "budget_exceeded",
                        402,
                        format!(
                            "The child's sub-budget ${sub:.2} cannot cover this machine's reservation ${reserve:.4} ({} for {} min); use a smaller size or a larger sub-budget",
                            spec.size,
                            ttl_minutes.min(budget::RESERVE_MINUTES as u64)
                        ),
                    ));
                }
            }
            if let Some(pool) = req.budget_pool_id.as_deref() {
                // A sub-budget child carves its whole budget from the pool.
                let needed = req.sub_budget_usd.unwrap_or(0.0).max(reserve);
                self.check_pool(pool, needed, "this machine").await?;
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
                owner_kind: Some(
                    if req.owner_mission_id.is_some() {
                        "mission"
                    } else {
                        "user"
                    }
                    .into(),
                ),
                requested_by_mission_id: req
                    .requested_by_mission_id
                    .clone()
                    .filter(|r| req.owner_mission_id.as_ref() != Some(r)),
                owner_mission_id: req.owner_mission_id.clone(),
                owner_user_id: req.owner_user_id.clone(),
                reason: req.reason.clone(),
                reap_at: None,
                reap_reason: None,
                error: None,
                ledger_closed: false,
                last_busy_at: None,
                budget_pool_id: req.budget_pool_id.clone(),
                auto_extensions: 0,
                stopped_at: None,
                stopped_by_reaper: false,
                source_snapshot: source_snapshot.clone(),
                forked_from: fork_source.as_ref().map(|(id, _)| id.clone()),
                fork_source_provider_id: fork_source.as_ref().map(|(_, pid)| pid.clone()),
                resumes: 0,
                run_started_at: None,
                cost_before_resume: 0.0,
                prior_pool_charges: Vec::new(),
                pool_spent_offset: 0.0,
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
        let started = tokio::time::Instant::now();
        // boat stops the sandbox itself at TTL + a small grace, even if Core
        // is down: the hard backstop against runaway cost.
        let spec = SpawnSpec {
            size: m.size.clone(),
            ttl_seconds: ttl_minutes * 60 + 300,
            image: Some(m.image.clone()),
            name: format!("{SANDBOX_NAME_PREFIX}{}", m.id),
            // A resume provisions the same machine id again.
            idempotency_key: if m.resumes == 0 {
                format!("orb-managed-{}", m.id)
            } else {
                format!("orb-managed-{}-r{}", m.id, m.resumes)
            },
        };
        let created = match m.fork_source_provider_id.clone() {
            Some(source) => provider.fork(&source, &spec).await?,
            None => provider.spawn(&spec).await?,
        };
        let provider_id = created.provider_id.clone();
        self.update(id, |m| {
            m.provider_id = Some(provider_id.clone());
            m.fork_source_provider_id = None;
        })
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
        let ready_ms = started.elapsed().as_millis() as u64;

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
        let provision_started = tokio::time::Instant::now();
        // Image fixups are best effort: a failure is logged, never fatal.
        let provisioned = match provider
            .write_file(&provider_id, PROVISION_PATH, PROVISION_SCRIPT)
            .await
        {
            Ok(()) => provider
                .exec(&provider_id, &format!("sudo bash {PROVISION_PATH}"), 60)
                .await
                .and_then(|v| match exec_exit_code(&v) {
                    Some(code) if code != 0 => Err(format!("exit code {code}")),
                    _ => Ok(()),
                }),
            Err(e) => Err(e),
        };
        let provision_ms = provision_started.elapsed().as_millis() as u64;
        if let Err(error) = &provisioned {
            tracing::warn!(machine = %id, %error, "managed VM provisioning script failed");
        }
        provider
            .exec(
                &provider_id,
                // A fork or snapshot carries the source node's credential and
                // projected sign-in: drop them so this VM enrolls fresh.
                "chmod 600 /home/user/.orb/enroll.env && sudo rm -rf /var/lib/orb-node/node.cred /var/lib/orb-node/work/managed-auth && sudo systemctl restart orb-node.service",
                60,
            )
            .await
            .map_err(|e| format!("start orb-node: {e}"))?;
        let enroll_started = tokio::time::Instant::now();

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
                        let enroll_ms = enroll_started.elapsed().as_millis() as u64;
                        let total_ms = started.elapsed().as_millis() as u64;
                        tracing::info!(
                            machine = %id,
                            size = %m.size,
                            ready_ms,
                            provision_ms,
                            provision_ok = provisioned.is_ok(),
                            enroll_ms,
                            total_ms,
                            "managed machine online"
                        );
                        self.ledger_with(
                            "online",
                            &m,
                            serde_json::json!({
                                "ready_ms": ready_ms,
                                "provision_ms": provision_ms,
                                "provision_ok": provisioned.is_ok(),
                                "enroll_ms": enroll_ms,
                                "total_ms": total_ms,
                            }),
                        );
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
        if let Some(pool) = m.budget_pool_id.as_deref() {
            let _guard = self.admission.lock().await;
            self.check_pool(
                pool,
                budget::reservation_for(ttl, m.usd_per_hour),
                "this extension",
            )
            .await?;
        }
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
                if m.state.is_live() || m.state == MachineState::Stopped {
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
                    m.cost_usd = m.cost_before_resume + usage.dollars;
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

    fn dry_run(&self) -> bool {
        self.runtime_settings().reaper_dry_run
    }

    fn node_busy(node_id: &str) -> bool {
        crate::remote_node::global_fleet()
            .as_ref()
            .and_then(|f| f.get(node_id))
            .and_then(|c| c.last_heartbeat)
            .is_some_and(|hb| hb.active_jobs > 0 || hb.active_leases > 0 || hb.queued_jobs > 0)
    }

    async fn owner_of(&self, m: &ManagedMachine) -> Owner {
        let Some(owner) = m.owner_mission_id.clone() else {
            return if m.owner_kind.as_deref() == Some("user") {
                Owner::User
            } else {
                Owner::None
            };
        };
        // Without a recorded tenant the owner's store is unknown: never
        // destroy on the owner rule.
        let Some(tenant) = m.owner_user_id.clone() else {
            return Owner::Mission(None);
        };
        let probe = self.owner_probe.read().ok().and_then(|p| p.clone());
        match probe {
            Some(probe) => Owner::Mission(probe(tenant, owner).await),
            None => Owner::Mission(None),
        }
    }

    /// The decision for one live, online machine this pass.
    async fn decide_for(&self, m: &ManagedMachine, now: DateTime<Utc>) -> (ReapDecision, Owner) {
        let busy = Self::node_busy(&m.node_id);
        let owner = self.owner_of(m).await;
        let facts = lifecycle::ReapFacts {
            now,
            expires_at: m.expires_at,
            busy,
            idle_since: if busy {
                now
            } else {
                m.last_busy_at.unwrap_or(m.created_at)
            },
            owner,
            scheduled: m.reap_reason.clone().zip(m.reap_at),
        };
        (lifecycle::decide(&facts, &self.settings.policy()), owner)
    }

    /// What the reaper would do for every live machine, without acting.
    pub async fn reap_plan(&self) -> Vec<ReapPlanEntry> {
        let now = Utc::now();
        let machines = self.machines.lock().await.clone();
        let mut out = Vec::new();
        for m in machines.iter().filter(|m| m.state == MachineState::Online) {
            let (decision, owner) = self.decide_for(m, now).await;
            out.push(ReapPlanEntry {
                machine_id: m.id.clone(),
                name: m.name.clone(),
                owner_mission_id: m.owner_mission_id.clone(),
                owner_kind: m.owner_kind.clone(),
                busy: Self::node_busy(&m.node_id),
                owner_state: Some(format!("{owner:?}")),
                decision,
            });
        }
        out
    }

    /// One reaper pass: lifecycle rules (spec), TTL and cost refresh.
    /// Reconcile runs separately.
    pub async fn reap_once(self: &Arc<Self>) {
        let now = Utc::now();
        let machines = self.machines.lock().await.clone();
        let dry_run = self.dry_run();
        for m in machines {
            match m.state {
                MachineState::Online | MachineState::Enrolling | MachineState::Provisioning => {
                    if m.state != MachineState::Online {
                        // Not yet serving: only the TTL applies.
                        if now >= m.expires_at {
                            let _ = self
                                .destroy_inner(&m.id, Some("ttl_expired".into()), false)
                                .await;
                            continue;
                        }
                    } else {
                        let busy = Self::node_busy(&m.node_id);
                        if busy {
                            self.update(&m.id, |m| m.last_busy_at = Some(now)).await;
                            if self.auto_extend(&m, now).await {
                                continue;
                            }
                        }
                        let (decision, _) = self.decide_for(&m, now).await;
                        match &decision {
                            ReapDecision::Destroy { reason } => {
                                let ttl = reason == "ttl_expired";
                                // Lean gate (`orb_vm_step`, reap_check).
                                let admitted =
                                    crate::orb_spec::vm_should_reap(crate::orb_spec::VmReapInput {
                                        ttl_expired: ttl,
                                        busy,
                                        owner_ended: !ttl && decision.is_owner_rule(),
                                        idle_expired: !ttl && !decision.is_owner_rule(),
                                    });
                                if admitted && (ttl || !dry_run) {
                                    // A waiting owner may resume: stop (disk
                                    // kept, nothing billed) instead of destroy.
                                    if snapshots::stops_instead_of_destroy(reason) {
                                        let _ = self.stop_inner(&m.id, reason, true).await;
                                    } else {
                                        let _ = self
                                            .destroy_inner(&m.id, Some(reason.clone()), false)
                                            .await;
                                    }
                                    continue;
                                }
                                if admitted {
                                    self.note_would_reap(&m, reason, now).await;
                                }
                            }
                            ReapDecision::Schedule { reason, at } => {
                                if m.reap_reason.as_deref() != Some(reason)
                                    || m.reap_at != Some(*at)
                                {
                                    let (reason, at) = (reason.clone(), *at);
                                    self.update(&m.id, |m| {
                                        m.reap_reason = Some(reason);
                                        m.reap_at = Some(at);
                                    })
                                    .await;
                                }
                            }
                            ReapDecision::Keep => {
                                if m.reap_at.is_some() || m.reap_reason.is_some() {
                                    self.update(&m.id, |m| {
                                        m.reap_at = None;
                                        m.reap_reason = None;
                                    })
                                    .await;
                                }
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
                MachineState::Stopped => {
                    self.reap_stopped(&m, now).await;
                }
            }
        }
    }

    /// Dry-run: keep the due reap visible on the row and log it once.
    async fn note_would_reap(&self, m: &ManagedMachine, reason: &str, now: DateTime<Utc>) {
        if m.reap_reason.as_deref() != Some(reason) || m.reap_at.is_none() {
            let r = reason.to_string();
            self.update(&m.id, |m| {
                m.reap_reason = Some(r);
                m.reap_at = Some(now);
            })
            .await;
        }
        let key = format!("{}:{reason}", m.id);
        if self
            .reconcile_state
            .lock()
            .await
            .would_reap_logged
            .insert(key)
        {
            tracing::warn!(machine = %m.id, name = %m.name, %reason, "managed reaper (dry-run) would destroy");
            let mut row = m.clone();
            row.destroy_reason = Some(reason.to_string());
            self.ledger("would_reap", &row);
        }
    }

    /// Compare provider state with the registry. Provider VMs carrying our
    /// name prefix with no live registry row are stopped after
    /// `orphan_grace_minutes` (dry-run: reported only). Live rows whose VM
    /// the provider stopped, or no longer lists for two passes, are closed.
    pub async fn reconcile_once(&self) -> Result<Value, String> {
        let Some(provider) = &self.provider else {
            return Ok(serde_json::json!({"skipped": "no provider"}));
        };
        let remote = provider.list().await?;
        let machines = self.machines.lock().await.clone();
        let now = Utc::now();
        let dry_run = self.dry_run();
        let grace = chrono::Duration::minutes(self.settings.orphan_grace_minutes as i64);
        let mut orphans_stopped = Vec::new();
        let mut orphans_pending = Vec::new();
        let mut orphan_ids = std::collections::HashSet::new();
        for pm in &remote {
            if !pm.name.starts_with(SANDBOX_NAME_PREFIX) || boat::is_stopped_state(&pm.state) {
                continue;
            }
            let live = machines
                .iter()
                .any(|m| m.provider_id.as_deref() == Some(&pm.provider_id) && m.state.is_live())
                // A spawn in flight has a row but no provider id yet.
                || machines.iter().any(|m| {
                    m.provider_id.is_none()
                        && m.state.is_live()
                        && pm.name == format!("{SANDBOX_NAME_PREFIX}{}", m.id)
                });
            if live {
                continue;
            }
            orphan_ids.insert(pm.provider_id.clone());
            let first = *self
                .reconcile_state
                .lock()
                .await
                .orphans_seen
                .entry(pm.provider_id.clone())
                .or_insert(now);
            if now - first < grace || dry_run {
                if now - first >= grace {
                    tracing::warn!(sandbox = %pm.provider_id, "managed reconcile (dry-run) would stop orphan sandbox");
                }
                orphans_pending.push(serde_json::json!({
                    "provider_id": pm.provider_id,
                    "name": pm.name,
                    "first_seen": first,
                    "stop_at": first + grace,
                }));
                continue;
            }
            tracing::warn!(sandbox = %pm.provider_id, "stopping orphan managed sandbox");
            if provider.destroy(&pm.provider_id).await.is_ok() {
                orphans_stopped.push(pm.provider_id.clone());
            }
        }
        self.reconcile_state
            .lock()
            .await
            .orphans_seen
            .retain(|id, _| orphan_ids.contains(id));

        let mut closed = Vec::new();
        let mut vanished = Vec::new();
        for m in machines.iter().filter(|m| m.state.is_live()) {
            let Some(pid) = &m.provider_id else { continue };
            match remote.iter().find(|p| &p.provider_id == pid) {
                Some(pm) => {
                    self.reconcile_state
                        .lock()
                        .await
                        .vanished_passes
                        .remove(&m.id);
                    if boat::is_stopped_state(&pm.state) && m.state == MachineState::Online {
                        let _ = self
                            .destroy_inner(&m.id, Some("stopped_by_provider".into()), false)
                            .await;
                        closed.push(m.id.clone());
                    }
                }
                // An empty list while we know live VMs is more likely a
                // provider glitch than every VM vanishing: wait for proof.
                None if !remote.is_empty() && m.state == MachineState::Online => {
                    let passes = {
                        let mut st = self.reconcile_state.lock().await;
                        let n = st.vanished_passes.entry(m.id.clone()).or_insert(0);
                        *n += 1;
                        *n
                    };
                    if passes >= 2 {
                        self.mark_vanished(&m.id).await;
                        self.reconcile_state
                            .lock()
                            .await
                            .vanished_passes
                            .remove(&m.id);
                        vanished.push(m.id.clone());
                    }
                }
                None => {}
            }
        }
        Ok(serde_json::json!({
            "provider_machines": remote.len(),
            "dry_run": dry_run,
            "orphans_stopped": orphans_stopped,
            "orphans_pending": orphans_pending,
            "closed_rows": closed,
            "vanished_rows": vanished,
        }))
    }

    /// The provider no longer has this VM: close the row without a provider
    /// call (nothing is left to stop) and settle the ledger.
    async fn mark_vanished(&self, id: &str) {
        let Some(m) = self
            .update(id, |m| {
                m.state = MachineState::Destroyed;
                m.destroyed_at = Some(Utc::now());
                if m.destroy_reason.is_none() {
                    m.destroy_reason = Some("provider_vanished".into());
                }
                if !m.cost_is_metered {
                    m.cost_usd = m.estimated_cost(Utc::now());
                }
            })
            .await
        else {
            return;
        };
        unregister_node(&m);
        self.relay.close(&m.id).await;
        self.ledger("destroyed", &m);
        self.refresh_usage(id).await;
        // The provider may not meter a VM it no longer knows: close anyway.
        if let Some(m) = self.get(id).await {
            if !m.ledger_closed {
                if let Some(m) = self.update(id, |m| m.ledger_closed = true).await {
                    self.ledger("ledger_closed", &m);
                }
            }
        }
    }
}

// ------------------------------------------------------------------ budgets

/// A mission's budget as the API returns it.
#[derive(Debug, Clone, Serialize)]
pub struct MissionBudgetView {
    pub mission_id: String,
    /// The mission has its own budget (a pool root).
    pub own_budget_usd: Option<f64>,
    /// The pool the mission draws from (itself, an ancestor, or none).
    pub pool_id: Option<String>,
    /// `pooled` (draws from an ancestor), `own` (its own budget) or `none`.
    pub mode: &'static str,
    pub pool: Option<budget::PoolUsage>,
    /// Most this mission's own budget may be set to (the parent pool's
    /// remaining plus what this mission already holds); `None` = no limit.
    pub max_grant_usd: Option<f64>,
    pub children: Vec<ChildBudgetView>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChildBudgetView {
    pub mission_id: String,
    /// `pooled` or `sub_budget`.
    pub mode: &'static str,
    pub budget_usd: Option<f64>,
    pub spent_usd: f64,
    pub reserved_usd: f64,
}

/// What a new child asks for when an ended sibling's idle VM may serve it.
#[derive(Debug, Clone, Copy)]
pub struct SiblingReuse<'a> {
    pub size: &'a str,
    pub image: &'a str,
    /// The parent of both siblings.
    pub requested_by: &'a str,
    pub tenant: Option<&'a str>,
    /// Pool the VM will be charged to.
    pub budget_pool_id: Option<&'a str>,
    pub sub_budget_usd: Option<f64>,
}

impl ManagedManager {
    async fn persist_budgets(&self) {
        let budgets = self.budgets.lock().await.clone();
        let _ = std::fs::create_dir_all(&self.dir);
        write_atomic(
            &self.budgets_path(),
            &serde_json::to_vec_pretty(&budgets).unwrap_or_default(),
            false,
        );
    }

    pub async fn budget_pools(&self) -> HashMap<String, budget::BudgetPool> {
        self.budgets.lock().await.clone()
    }

    /// Which pools' owners still run (their sub-budget stays carved).
    async fn open_pools(
        &self,
        pools: &HashMap<String, budget::BudgetPool>,
    ) -> HashMap<String, bool> {
        let probe = self.owner_probe.read().ok().and_then(|p| p.clone());
        let mut out = HashMap::new();
        for p in pools.values() {
            let open = match (&probe, &p.owner_user_id) {
                (Some(probe), Some(tenant)) => !matches!(
                    probe(tenant.clone(), p.mission_id.clone()).await,
                    Some(OwnerState::Terminal { .. }) | Some(OwnerState::Missing)
                ),
                _ => true,
            };
            out.insert(p.mission_id.clone(), open);
        }
        out
    }

    pub async fn pool_usage(&self, pool_id: &str) -> Option<budget::PoolUsage> {
        let pools = self.budget_pools().await;
        if !pools.contains_key(pool_id) {
            return None;
        }
        let open = self.open_pools(&pools).await;
        let machines = self.machines.lock().await.clone();
        budget::pool_usage(pool_id, &pools, &machines, Utc::now(), &|id| {
            open.get(id).copied().unwrap_or(true)
        })
    }

    /// Reject a spend of `needed` that does not fit `pool_id`. A pool that
    /// no longer exists (budget removed) imposes no limit.
    async fn check_pool(&self, pool_id: &str, needed: f64, what: &str) -> Result<(), ManagedError> {
        let Some(u) = self.pool_usage(pool_id).await else {
            return Ok(());
        };
        if needed > u.available_usd + 1e-9 {
            return Err(ManagedError::new(
                "budget_exceeded",
                402,
                budget::exceeded_message(&u, needed, what),
            ));
        }
        Ok(())
    }

    /// Most `mission_id`'s own budget may be: the parent pool's remaining
    /// plus what this mission's pool already holds there.
    pub async fn max_grant(&self, mission_id: &str, parent_pool: Option<&str>) -> Option<f64> {
        let parent = self.pool_usage(parent_pool?).await?;
        let held = match self.pool_usage(mission_id).await {
            Some(own) => (own.spent_usd + own.reserved_usd + own.carved_usd).max(own.budget_usd),
            None => 0.0,
        };
        Some((parent.available_usd + held).max(0.0))
    }

    /// Set (`Some`) or remove (`None`) a mission's own budget. A budget
    /// under an ancestor pool is a sub-budget and must fit that pool.
    pub async fn set_mission_budget(
        &self,
        mission_id: &str,
        amount: Option<f64>,
        parent_pool: Option<String>,
        owner_user_id: Option<String>,
    ) -> Result<(), ManagedError> {
        let _guard = self.admission.lock().await;
        match amount {
            None => {
                self.budgets.lock().await.remove(mission_id);
                // Everything charged to the removed pool (current machines
                // and cost recorded when machines left it) moves to the
                // parent pool. Without a parent nothing is limited any more;
                // the records stay as they are.
                let now = Utc::now();
                let mut machines = self.machines.lock().await;
                for m in machines.iter_mut() {
                    if m.budget_pool_id.as_deref() == Some(mission_id) {
                        m.change_pool(parent_pool.clone(), now);
                    }
                    if let Some(parent) = &parent_pool {
                        for (pool, _) in m.prior_pool_charges.iter_mut() {
                            if pool == mission_id {
                                *pool = parent.clone();
                            }
                        }
                    }
                }
                drop(machines);
                // Child pools re-attach to the parent pool.
                for p in self.budgets.lock().await.values_mut() {
                    if p.parent_pool_id.as_deref() == Some(mission_id) {
                        p.parent_pool_id = parent_pool.clone();
                    }
                }
            }
            Some(raw) => {
                let amount = budget::validate_amount(raw)
                    .map_err(|e| ManagedError::new("invalid_budget", 400, e))?;
                if let Some(max) = self.max_grant(mission_id, parent_pool.as_deref()).await {
                    if amount > max + 1e-9 {
                        return Err(ManagedError::new(
                            "sub_budget_exceeds_pool",
                            402,
                            format!(
                                "Sub-budget ${amount:.2} exceeds what the parent pool {} can grant (${max:.4} remaining)",
                                parent_pool.as_deref().unwrap_or_default()
                            ),
                        ));
                    }
                }
                let mut pools = self.budgets.lock().await;
                let existed = pools.contains_key(mission_id);
                pools.insert(
                    mission_id.to_string(),
                    budget::BudgetPool {
                        mission_id: mission_id.to_string(),
                        budget_usd: amount,
                        parent_pool_id: parent_pool.clone().filter(|p| p != mission_id),
                        owner_user_id,
                        updated_at: Utc::now(),
                    },
                );
                drop(pools);
                if !existed {
                    // Live machines this mission owns now charge to its pool.
                    let mut machines = self.machines.lock().await;
                    for m in machines.iter_mut().filter(|m| {
                        m.state.is_live()
                            && m.owner_mission_id.as_deref() == Some(mission_id)
                            && m.budget_pool_id == parent_pool
                    }) {
                        m.change_pool(Some(mission_id.to_string()), Utc::now());
                    }
                }
            }
        }
        self.persist_budgets().await;
        self.persist().await;
        Ok(())
    }

    /// Re-attach a pool to its current nearest ancestor pool.
    pub async fn reparent_pool(&self, mission_id: &str, parent_pool: Option<String>) {
        let changed = {
            let mut pools = self.budgets.lock().await;
            match pools.get_mut(mission_id) {
                Some(p) if p.parent_pool_id != parent_pool => {
                    p.parent_pool_id = parent_pool.filter(|p| p != mission_id);
                    true
                }
                _ => false,
            }
        };
        if changed {
            self.persist_budgets().await;
        }
    }

    /// Charge a machine to a pool (the child that claimed it).
    pub async fn set_machine_pool(&self, id: &str, pool: Option<String>) {
        if let Some(m) = self.get(id).await {
            if m.budget_pool_id != pool {
                if let Some(m) = self
                    .update(&m.id, |m| m.change_pool(pool, Utc::now()))
                    .await
                {
                    self.ledger("budget_pool_set", &m);
                }
            }
        }
    }

    /// Budget view for one mission. `lineage` is the mission then its
    /// ancestors; `children` its direct children.
    pub async fn mission_budget(
        &self,
        mission_id: &str,
        lineage: &[String],
        children: &[String],
        user_id: &str,
    ) -> MissionBudgetView {
        let pools = self.budget_pools().await;
        let pool_id = budget::nearest_pool(lineage.iter().map(String::as_str), &pools, user_id);
        let parent_pool =
            budget::nearest_pool(lineage.iter().skip(1).map(String::as_str), &pools, user_id);
        let open = self.open_pools(&pools).await;
        let machines = self.machines.lock().await.clone();
        let now = Utc::now();
        let is_open = |id: &str| open.get(id).copied().unwrap_or(true);
        let pool = pool_id
            .as_deref()
            .and_then(|p| budget::pool_usage(p, &pools, &machines, now, &is_open));
        let own = pools.get(mission_id).map(|p| p.budget_usd);
        let children = children
            .iter()
            .map(|c| match pools.get(c) {
                Some(p) => {
                    let u = budget::pool_usage(c, &pools, &machines, now, &is_open);
                    ChildBudgetView {
                        mission_id: c.clone(),
                        mode: "sub_budget",
                        budget_usd: Some(p.budget_usd),
                        spent_usd: u.as_ref().map_or(0.0, |u| u.spent_usd),
                        reserved_usd: u.as_ref().map_or(0.0, |u| u.reserved_usd + u.carved_usd),
                    }
                }
                None => {
                    let mine = machines.iter().filter(|m| {
                        m.owner_mission_id.as_deref() == Some(c.as_str())
                            && m.budget_pool_id.is_some()
                            && m.budget_pool_id == pool_id
                    });
                    let (spent, reserved) = mine.fold((0.0, 0.0), |(s, r), m| {
                        (
                            s + budget::machine_spent(m, now),
                            r + budget::machine_reserved(m, now),
                        )
                    });
                    ChildBudgetView {
                        mission_id: c.clone(),
                        mode: "pooled",
                        budget_usd: None,
                        spent_usd: (spent * 10000.0).round() / 10000.0,
                        reserved_usd: (reserved * 10000.0).round() / 10000.0,
                    }
                }
            })
            .collect();
        drop(machines);
        let max_grant_usd = self.max_grant(mission_id, parent_pool.as_deref()).await;
        MissionBudgetView {
            mission_id: mission_id.to_string(),
            own_budget_usd: own,
            mode: if own.is_some() {
                "own"
            } else if pool_id.is_some() {
                "pooled"
            } else {
                "none"
            },
            pool_id,
            pool,
            max_grant_usd,
            children,
        }
    }

    /// Hand an idle machine whose owner (a sibling of the new child, i.e. a
    /// child of `requested_by`) has ended to a new child of `requested_by`,
    /// instead of renting a fresh one. `ended(owner)` says whether the owner
    /// mission is terminal and a child of `requested_by` (checked by the
    /// caller against the mission store). Returns the released machine,
    /// unowned and requested by `requested_by`, ready to be claimed.
    pub async fn take_idle_sibling(
        &self,
        want: &SiblingReuse<'_>,
        candidates_ok: &(dyn Fn(&str) -> bool + Sync),
    ) -> Option<ManagedMachine> {
        let SiblingReuse {
            size,
            image,
            requested_by,
            tenant,
            budget_pool_id,
            sub_budget_usd,
        } = *want;
        let _guard = self.admission.lock().await;
        let pick = self
            .machines
            .lock()
            .await
            .iter()
            .filter(|m| {
                m.state == MachineState::Online
                    && m.size == size
                    && m.image == image
                    && Utc::now() + chrono::Duration::minutes(10) < m.expires_at
                    && (m.owner_user_id.as_deref() == tenant || m.owner_user_id.is_none())
                    && m.owner_mission_id.as_deref().is_some_and(candidates_ok)
                    && !Self::node_busy(&m.node_id)
            })
            .min_by_key(|m| m.created_at)
            .cloned()?;
        // A handover re-charges the VM: it must pass the same budget checks
        // as a fresh rent, or the caller falls back to normal admission.
        let reserve = budget::machine_reserved(&pick, Utc::now());
        if sub_budget_usd.is_some_and(|sub| reserve > sub) {
            return None;
        }
        if let Some(pool) = budget_pool_id {
            let needed = sub_budget_usd.unwrap_or(0.0).max(reserve);
            if self.check_pool(pool, needed, "this machine").await.is_err() {
                return None;
            }
        }
        let pool = budget_pool_id.map(str::to_string);
        let m = self
            .update(&pick.id, |m| {
                m.change_pool(pool, Utc::now());
                m.owner_mission_id = None;
                m.requested_by_mission_id = Some(requested_by.to_string());
                m.reap_at = None;
                m.reap_reason = None;
                m.last_busy_at = Some(Utc::now());
            })
            .await?;
        self.ledger("reused_idle", &m);
        Some(m)
    }

    /// While busy and close to its TTL, extend by `auto_extend_minutes` if
    /// the pool (and the daily cap) allow. Returns true when extended.
    async fn auto_extend(&self, m: &ManagedMachine, now: DateTime<Utc>) -> bool {
        let chunk = self.settings.auto_extend_minutes;
        if chunk == 0 || m.expires_at - now > chrono::Duration::minutes(10) {
            return false;
        }
        let max_end =
            m.created_at + chrono::Duration::minutes(self.settings.max_ttl_minutes as i64);
        if m.expires_at >= max_end {
            return false;
        }
        if let Some(cap) = self.settings.daily_cap_usd {
            let b = self.budget().await;
            if b.spent_today_usd + b.committed_usd + chunk as f64 / 60.0 * m.usd_per_hour > cap {
                return false;
            }
        }
        match self.extend(&m.id, chunk).await {
            Ok(m) => {
                if let Some(m) = self.update(&m.id, |m| m.auto_extensions += 1).await {
                    self.ledger("auto_extended", &m);
                }
                true
            }
            Err(e) => {
                tracing::info!(machine = %m.id, error = %e, "managed auto-extend refused");
                false
            }
        }
    }
}

/// Exit code of a provider exec result, when it reports one.
pub fn exec_exit_code(v: &Value) -> Option<i64> {
    ["exitCode", "exit_code", "code"]
        .iter()
        .find_map(|k| v.get(*k).and_then(Value::as_i64))
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
            daily_cap = ?manager.settings.daily_cap_usd,
            max_concurrent = ?manager.settings.max_concurrent,
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
                rec.cleanup_snapshots().await;
                tokio::time::sleep(Duration::from_secs(rec.settings.reconcile_secs.max(30))).await;
            }
        });
    }
    manager
}

#[cfg(test)]
mod tests;
