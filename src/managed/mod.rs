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
pub mod hetzner;
pub mod lifecycle;
pub mod raw_operations;
pub mod relay;
pub mod scaleway;
pub mod snapshots;
pub mod vastai;

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

static RESOURCE_LEDGER_SHADOW_COUNTER: OnceLock<crate::orb_spec::ShadowCounter> = OnceLock::new();

pub fn resource_ledger_shadow_counter() -> &'static crate::orb_spec::ShadowCounter {
    RESOURCE_LEDGER_SHADOW_COUNTER.get_or_init(crate::orb_spec::ShadowCounter::new)
}

#[allow(clippy::too_many_arguments)]
pub fn evaluate_resource_ledger_gate(
    op_kind: crate::orb_spec::ResourceLedgerOp,
    reserved_slots: u32,
    active_slots: u32,
    max_slots: u32,
    spent_cents: u64,
    cost_delta_cents: u64,
    budget_cents: u64,
    now_tick: u64,
    ttl_expiry_tick: u64,
) -> crate::orb_spec::ResourceLedgerStepVerdict {
    let input = crate::orb_spec::ResourceLedgerStepInput {
        op_kind,
        reserved_slots,
        active_slots,
        max_slots,
        spent_cents,
        cost_delta_cents,
        budget_cents,
        now_tick,
        ttl_expiry_tick,
    };
    let verdict = crate::orb_spec::resource_ledger_step(input);
    let active_fits = active_slots <= max_slots;
    let rem_slots = if active_fits {
        max_slots - active_slots
    } else {
        0
    };
    let reserved_fits = reserved_slots <= rem_slots;
    let budget_valid = spent_cents <= budget_cents;
    let state_valid = active_fits && reserved_fits && budget_valid;
    let rem_budget = if budget_valid {
        budget_cents - spent_cents
    } else {
        0
    };
    let spend_fits = state_valid && cost_delta_cents <= rem_budget;
    let can_reserve = matches!(op_kind, crate::orb_spec::ResourceLedgerOp::Reserve)
        && spend_fits
        && reserved_slots < rem_slots
        && now_tick < ttl_expiry_tick;
    let can_activate = matches!(op_kind, crate::orb_spec::ResourceLedgerOp::ActivateReserved)
        && state_valid
        && reserved_slots > 0
        && now_tick < ttl_expiry_tick;
    let can_release = matches!(op_kind, crate::orb_spec::ResourceLedgerOp::ReleaseActive)
        && state_valid
        && active_slots > 0;
    let can_reap = matches!(op_kind, crate::orb_spec::ResourceLedgerOp::ReapExpired)
        && state_valid
        && reserved_slots > 0
        && now_tick >= ttl_expiry_tick;
    let host_admitted = can_reserve || can_activate || can_release || can_reap;
    let host_next_reserved = if can_reserve {
        reserved_slots + 1
    } else if can_activate || can_reap {
        reserved_slots - 1
    } else {
        reserved_slots
    } as u16;
    let host_next_active = if can_activate {
        active_slots + 1
    } else if can_release {
        active_slots - 1
    } else {
        active_slots
    } as u16;
    let sim = crate::orb_spec::shadow::RefinementSimulation::<
        (bool, u16, u16),
        (bool, u16, u16),
        crate::orb_spec::ResourceLedgerStepInput,
        u8,
        u8,
    > {
        subsystem: "orb_resource_ledger_step",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = crate::orb_spec::resource_ledger_step(*ev);
            (
                (v.admitted, v.next_reserved_slots, v.next_active_slots),
                vec![u8::from(v.state_valid)],
            )
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let ctx = crate::orb_spec::shadow::EventContext {
        now_ms: now_tick,
        fresh_nonce: ttl_expiry_tick,
        idempotency_key: cost_delta_cents,
        boot_id_matches: true,
        schema_id: 2,
    };
    resource_ledger_shadow_counter().with_ring(|ring| {
        let _ = sim.observe_step(
            &(false, reserved_slots as u16, active_slots as u16),
            &(host_admitted, host_next_reserved, host_next_active),
            &input,
            &[u8::from(state_valid)],
            ctx,
            ring,
        );
    });
    verdict
}
const TOKEN_ENV_PREFIX: &str = "SANDBOXED_MANAGED_TOKEN_";
const ENROLL_ENV_PATH: &str = "/home/user/.orb/enroll.env";
const PROVISION_PATH: &str = "/home/user/.orb/provision.sh";
/// Per-VM fixups run as root before orb-node starts (writable
/// `/tmp/opencode`, GitHub credential helper, user rustup env).
pub const PROVISION_SCRIPT: &str = include_str!("orb-node-provision.sh");
pub const UPDATE_NODE_CODEX_SCRIPT: &str = include_str!("../../scripts/update-node-codex.py");
pub const UPDATE_NODE_HARNESSES_SCRIPT: &str =
    include_str!("../../scripts/update-node-harnesses.py");

// ---------------------------------------------------------------- provider

#[derive(Debug, Clone)]
pub struct SpawnSpec {
    pub machine_id: String,
    pub size: String,
    pub cpu: u32,
    pub ram_gb: u32,
    pub ttl_seconds: u64,
    pub image: Option<String>,
    pub name: String,
    pub idempotency_key: String,
    pub bootstrap_script: Option<String>,
    pub gpu: Option<String>,
    pub arch: Option<String>,
    pub max_hourly_usd: Option<f64>,
    pub preferred_offer_id: Option<String>,
    pub exclude_offer_ids: Vec<String>,
    pub allow_24h_commitment: bool,
    pub provisioning_mode: ProvisioningMode,
}

#[derive(Debug, Clone)]
pub struct SpawnQuote {
    pub offer_id: Option<String>,
    pub usd_per_hour: f64,
    pub cpu: u32,
    pub ram_gb: u32,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProviderMachine {
    pub provider_id: String,
    pub state: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deletable_at: Option<DateTime<Utc>>,
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
    fn sizes(&self) -> &[SizeSpec] {
        &SIZES
    }
    fn supports_free_stop(&self) -> bool {
        false
    }
    fn supports_snapshots(&self) -> bool {
        false
    }
    fn uses_cloud_init_bootstrap(&self) -> bool {
        false
    }
    fn is_ready_state(&self, state: &str) -> bool {
        boat::is_ready_state(state)
    }
    fn is_stopped_state(&self, state: &str) -> bool {
        boat::is_stopped_state(state)
    }
    async fn quote_spawn(&self, _spec: &SpawnSpec) -> Result<Option<SpawnQuote>, String> {
        Ok(None)
    }
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
    /// Raw operation calls must cap HTTP response bodies before JSON allocation.
    async fn raw_exec(
        &self,
        _provider_id: &str,
        _command: &str,
        _timeout_secs: u64,
    ) -> Result<Value, String> {
        Err("bounded raw execution is unsupported".into())
    }
    async fn raw_write_file(
        &self,
        _provider_id: &str,
        _path: &str,
        _content: &str,
    ) -> Result<(), String> {
        Err("bounded raw file writes are unsupported".into())
    }
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

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct SizeSpec {
    pub size: &'static str,
    pub cpu: u32,
    pub ram_gb: u32,
    pub disk_gb: u32,
    pub usd_per_hour: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gpu: Option<&'static str>,
    pub arch: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_billing_hours: Option<u32>,
}

pub const SIZES: [SizeSpec; 4] = [
    SizeSpec {
        size: "small",
        cpu: 2,
        ram_gb: 4,
        disk_gb: 12,
        usd_per_hour: 0.018,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "default",
        cpu: 4,
        ram_gb: 8,
        disk_gb: 50,
        usd_per_hour: 0.036,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "large",
        cpu: 8,
        ram_gb: 16,
        disk_gb: 125,
        usd_per_hour: 0.072,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
    },
    SizeSpec {
        size: "xlarge",
        cpu: 16,
        ram_gb: 32,
        disk_gb: 251,
        usd_per_hour: 0.20,
        gpu: None,
        arch: "x86_64",
        min_billing_hours: None,
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
    /// Operator-approved clean images for raw VMs; empty disables fresh raw spawn.
    pub raw_allowed_images: Vec<String>,
    #[serde(skip)]
    pub core_url: Option<String>,
    pub idle_minutes: u64,
    /// Idle minutes before an unused worker VM owned by a `Working` parent is
    /// reaped (`0` disables `Working`-owner idle reaping).
    pub working_idle_minutes: u64,
    /// Idle minutes after a worker VM has completed at least one job while its
    /// `Working` parent continues elsewhere.
    pub post_job_idle_minutes: u64,
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
            working_idle_minutes: self.working_idle_minutes as i64,
            post_job_working_idle_minutes: self.post_job_idle_minutes as i64,
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
            raw_allowed_images: std::env::var("SANDBOXED_MANAGED_RAW_IMAGES")
                .unwrap_or_default()
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect(),
            core_url: std::env::var("SANDBOXED_MANAGED_CORE_URL")
                .ok()
                .or_else(|| std::env::var("SANDBOXED_PUBLIC_URL").ok())
                .map(|u| u.trim().trim_end_matches('/').to_string())
                .filter(|u| !u.is_empty()),
            idle_minutes: env_parse("SANDBOXED_MANAGED_IDLE_MINUTES").unwrap_or(15),
            working_idle_minutes: env_parse("SANDBOXED_MANAGED_WORKING_IDLE_MINUTES").unwrap_or(15),
            post_job_idle_minutes: env_parse("SANDBOXED_MANAGED_POST_JOB_IDLE_MINUTES")
                .unwrap_or(5),
            owner_grace_minutes: env_parse("SANDBOXED_MANAGED_OWNER_GRACE_MINUTES").unwrap_or(2),
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

/// Guest provisioning policy, persisted through forks and snapshots.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProvisioningMode {
    #[default]
    Worker,
    Raw,
}

impl ProvisioningMode {
    pub fn is_worker(self) -> bool {
        self == Self::Worker
    }

    fn inherit(requested: Option<Self>, source: Self) -> Result<Self, ManagedError> {
        if requested.is_some_and(|mode| mode != source) {
            return Err(ManagedError::new(
                "mode_mismatch",
                400,
                "Provisioning mode must match the source machine or snapshot",
            ));
        }
        Ok(source)
    }
}

/// One managed machine. The persisted list of these is the cost ledger:
/// `cost_usd` is the provider's metered cost and `ledger_closed` is true once
/// the provider confirms nothing is billing any more.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManagedMachine {
    #[serde(default)]
    pub provisioning_mode: ProvisioningMode,
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
    /// Mission concurrency-override pool this machine occupies a slot in;
    /// `None` when counted against the shared global concurrency pool.
    #[serde(default)]
    pub cap_pool_id: Option<String>,
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
    /// Delivered secrets were verified deleted when it stopped.
    #[serde(default)]
    pub secrets_wiped: bool,
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
    /// Project slug of the owning mission (set server-side at spawn/claim).
    #[serde(default)]
    pub project: Option<String>,
    /// Root ancestor mission ID of the owning lineage.
    #[serde(default)]
    pub root_mission_id: Option<String>,
    /// Live worker mission IDs currently executing remote jobs/leases on `node_id`.
    #[serde(default)]
    pub active_mission_ids: Vec<String>,
    /// Provider minimum-lease timestamp (e.g. Scaleway Apple Silicon 24h
    /// `deletable_at`) before which provider deletion is forbidden.
    #[serde(default)]
    pub deletable_at: Option<DateTime<Utc>>,
    /// Monotone sticky flag set once the node has executed at least one job.
    #[serde(default)]
    pub has_executed_job: bool,
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
        let min_end = self.deletable_at.unwrap_or(self.created_at);
        let end = self
            .destroyed_at
            .or(self.stopped_at)
            .unwrap_or(now)
            .min(self.expires_at)
            .max(min_end.min(now));
        let start = self.run_started_at.unwrap_or(self.created_at);
        let secs = (end - start).num_seconds().max(0) as f64;
        self.cost_before_resume + secs / 3600.0 * self.usd_per_hour
    }

    fn remaining_commitment(&self, now: DateTime<Utc>) -> f64 {
        if !self.state.is_live() {
            return 0.0;
        }
        let committed_end = match self.deletable_at {
            Some(del_at) if del_at > self.expires_at => del_at,
            _ => self.expires_at,
        };
        let secs = (committed_end - now).num_seconds().max(0) as f64;
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
    #[serde(default)]
    pub provisioning_mode: Option<ProvisioningMode>,
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
    /// Mission lineage (target mission first, then ancestors) used to resolve
    /// per-mission `vm_limits` concurrency overrides; never from the body.
    #[serde(skip)]
    pub cap_lineage: Vec<String>,
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
    /// Project snapshots are looked up in (the charged mission's); set by
    /// the API, never from a body.
    #[serde(skip)]
    pub snapshot_project: Option<String>,
    /// Prefer an idle machine of the same size whose owner (a child of the
    /// requester) has ended, inside its grace window, over a fresh rent.
    #[serde(default)]
    pub reuse_idle: Option<bool>,
    /// Cloud provider (`"boat"`, `"hetzner"`, `"vastai"`, `"scaleway"`).
    /// Defaults to `"boat"` (or the first configured provider).
    #[serde(default)]
    pub provider: Option<String>,
    /// Optional GPU model filter (e.g. `"RTX 4090"`, `"A100 SXM4"`, `"H100"`).
    #[serde(default)]
    pub gpu: Option<String>,
    /// Optional CPU architecture (`"x86_64"` or `"arm64"`).
    #[serde(default)]
    pub arch: Option<String>,
    /// Optional hourly USD ceiling for marketplace offers (e.g. Vast.ai).
    #[serde(default)]
    pub max_hourly_usd: Option<f64>,
    /// Explicit confirmation required for 24h minimum-lease hardware (Scaleway Apple Silicon).
    #[serde(default)]
    pub allow_24h_commitment: Option<bool>,
    /// Root ancestor mission ID resolved server-side from mission lineage.
    #[serde(skip)]
    pub root_mission_id: Option<String>,
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

pub type ActiveMissionsProbe = Arc<
    dyn Fn() -> std::pin::Pin<
            Box<dyn std::future::Future<Output = HashMap<String, Vec<String>>> + Send>,
        > + Send
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
    if !machine.provisioning_mode.is_worker() {
        return;
    }
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

/// Pure verdict behind [`ManagedManager::node_provably_gone`].
pub fn node_gone_verdict(record: Option<MachineState>, registry_authoritative: bool) -> bool {
    match record {
        Some(state) => matches!(state, MachineState::Destroyed | MachineState::Failed),
        None => registry_authoritative,
    }
}

#[cfg(test)]
static TEST_MANAGER: std::sync::Mutex<Option<Arc<ManagedManager>>> = std::sync::Mutex::new(None);

/// Install a registry for [`node_provably_gone`] in tests.
#[cfg(test)]
pub fn set_test_manager(manager: Option<Arc<ManagedManager>>) {
    *TEST_MANAGER.lock().unwrap_or_else(|e| e.into_inner()) = manager;
}

/// Whether `node_id` names a managed VM whose registry record proves no node
/// process can still run there. Static nodes and an unavailable registry are
/// never proof.
pub async fn node_provably_gone(node_id: &str) -> bool {
    if !is_managed_node(node_id) {
        return false;
    }
    #[cfg(test)]
    let manager = TEST_MANAGER
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .or_else(global);
    #[cfg(not(test))]
    let manager = global();
    match manager {
        Some(manager) => manager.node_provably_gone(node_id).await,
        None => false,
    }
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
    if !machine.provisioning_mode.is_worker() {
        return;
    }
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
            format!("provider={}", machine.provider),
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

pub const CANONICAL_PROVIDERS: [&str; 4] = ["boat", "hetzner", "vastai", "scaleway"];

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProviderMeta {
    pub credential_source: Option<String>,
    pub key_hint: Option<String>,
    pub region: Option<String>,
    pub project_id: Option<String>,
}

#[derive(Clone)]
struct BaseProviderCredential {
    source: String,
    api_key: String,
    region: Option<String>,
    project_id: Option<String>,
}

impl std::fmt::Debug for BaseProviderCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BaseProviderCredential")
            .field("source", &self.source)
            .field("region", &self.region)
            .field("project_id", &self.project_id)
            .finish()
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct StoredProviderEntry {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    encrypted_api_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    key_hint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    region: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    project_id: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ProviderUpdateRequest {
    #[serde(default)]
    pub enabled: Option<bool>,
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default)]
    pub region: Option<String>,
    #[serde(default)]
    pub project_id: Option<String>,
}

pub fn mask_key_hint(secret: &str) -> String {
    let chars: Vec<char> = secret.trim().chars().collect();
    if chars.len() <= 6 {
        "••••••••".to_string()
    } else {
        let tail: String = chars[chars.len() - 4..].iter().collect();
        format!("••••{tail}")
    }
}

pub struct ManagedManager {
    pub settings: ManagedSettings,
    providers: std::sync::RwLock<HashMap<String, Arc<dyn ManagedProvider>>>,
    provider_meta: std::sync::RwLock<HashMap<String, ProviderMeta>>,
    base_credentials: std::sync::RwLock<HashMap<String, BaseProviderCredential>>,
    stored_providers: std::sync::RwLock<HashMap<String, StoredProviderEntry>>,
    default_provider_name: std::sync::RwLock<String>,
    enabled_runtime: std::sync::atomic::AtomicBool,
    loops_started: std::sync::atomic::AtomicBool,
    activity_notify: tokio::sync::Notify,
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
    active_missions_probe: std::sync::RwLock<Option<ActiveMissionsProbe>>,
    runtime: std::sync::RwLock<RuntimeSettings>,
    /// Reconciler memory (not persisted; a restart restarts the graces).
    reconcile_state: Mutex<ReconcileState>,
    /// The persisted registry was read and parsed, so a node id missing
    /// from it was never (or is no longer) a machine of this Core.
    registry_authoritative: std::sync::atomic::AtomicBool,
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
    /// destroyed. TTL expiry always destroys. Defaults to `false` (active
    /// reaping enforced unless `SANDBOXED_MANAGED_REAPER_DRY_RUN=1`).
    #[serde(default)]
    pub reaper_dry_run: bool,
    /// Cloud providers explicitly disabled by the operator (e.g. `"hetzner"`).
    /// Disabled providers refuse new spawns/resumes/forks while still reaping
    /// and reconciling any already-live machines.
    #[serde(default, skip_serializing_if = "std::collections::BTreeSet::is_empty")]
    pub disabled_providers: std::collections::BTreeSet<String>,
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
            reaper_dry_run: matches!(
                std::env::var("SANDBOXED_MANAGED_REAPER_DRY_RUN")
                    .ok()
                    .as_deref(),
                Some("1" | "true" | "yes" | "on")
            ),
            disabled_providers: std::collections::BTreeSet::new(),
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

pub(crate) fn sha256_hex(value: &str) -> String {
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
    /// Live machines counted against the shared global concurrency pool
    /// (`cap_pool_id == None`).
    pub shared_active: usize,
    /// `null` = unlimited.
    pub max_concurrent: Option<usize>,
    pub default_ttl_minutes: u64,
    pub max_ttl_minutes: u64,
    pub default_size: String,
    pub max_size: String,
    pub image: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ProviderCatalogEntry {
    pub provider: String,
    pub display_name: String,
    pub configured: bool,
    pub enabled: bool,
    pub supports_free_stop: bool,
    pub supports_snapshots: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credential_source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key_hint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub region: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    pub sizes: Vec<SizeSpec>,
}

pub fn provider_display_name(provider: &str) -> &'static str {
    match provider {
        "boat" => "boat.dev",
        "hetzner" => "Hetzner Cloud",
        "vastai" => "Vast.ai",
        "scaleway" => "Scaleway",
        "fake" => "Fake",
        _ => "Custom",
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ListView {
    pub enabled: bool,
    pub provider: String,
    pub providers: Vec<ProviderCatalogEntry>,
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

type BuiltCloudProvider = (Arc<dyn ManagedProvider>, Option<String>, Option<String>);

impl ManagedManager {
    pub fn new(
        settings: ManagedSettings,
        provider: Option<Arc<dyn ManagedProvider>>,
        working_dir: &std::path::Path,
        core_port: u16,
    ) -> Self {
        let dir = working_dir.join(".sandboxed-sh");
        let mut providers = HashMap::new();
        let mut default_name = settings.provider.clone();
        if let Some(p) = provider {
            default_name = p.name().to_string();
            providers.insert(default_name.clone(), p);
        }
        let enabled_runtime = settings.enabled && !providers.is_empty();
        Self {
            settings,
            providers: std::sync::RwLock::new(providers),
            provider_meta: std::sync::RwLock::new(HashMap::new()),
            base_credentials: std::sync::RwLock::new(HashMap::new()),
            stored_providers: std::sync::RwLock::new(HashMap::new()),
            default_provider_name: std::sync::RwLock::new(default_name),
            enabled_runtime: std::sync::atomic::AtomicBool::new(enabled_runtime),
            loops_started: std::sync::atomic::AtomicBool::new(false),
            activity_notify: tokio::sync::Notify::new(),
            core_port,
            dir,
            machines: Mutex::new(Vec::new()),
            budgets: Mutex::new(HashMap::new()),
            snapshots: Mutex::new(Vec::new()),
            secrets: Mutex::new(HashMap::new()),
            admission: Mutex::new(()),
            relay: relay::RelayHub::default(),
            owner_probe: std::sync::RwLock::new(None),
            active_missions_probe: std::sync::RwLock::new(None),
            runtime: std::sync::RwLock::new(RuntimeSettings::default()),
            reconcile_state: Mutex::new(ReconcileState::default()),
            registry_authoritative: std::sync::atomic::AtomicBool::new(false),
        }
    }

    pub fn is_enabled(&self) -> bool {
        let explicitly_off = matches!(
            std::env::var("SANDBOXED_MANAGED_ENABLED").ok().as_deref(),
            Some("0" | "false" | "no" | "off")
        );
        if explicitly_off {
            return false;
        }
        (self.settings.enabled
            || self
                .enabled_runtime
                .load(std::sync::atomic::Ordering::SeqCst))
            && self.providers.read().is_ok_and(|p| !p.is_empty())
    }

    pub fn is_provider_enabled(&self, name: &str) -> bool {
        let key = name.trim().to_ascii_lowercase();
        !self.runtime_settings().disabled_providers.contains(&key)
    }

    pub fn provider_for(&self, name: &str) -> Option<Arc<dyn ManagedProvider>> {
        let key = name.trim().to_ascii_lowercase();
        let map = self.providers.read().ok()?;
        if let Some(p) = map.get(&key) {
            return Some(Arc::clone(p));
        }
        // In unit tests ONLY, a single `FakeProvider` ("fake") backs rows whose
        // default provider string was "boat". Never alias real cloud providers.
        if map.len() == 1 && (key.is_empty() || key == "boat") {
            return map.get("fake").cloned();
        }
        None
    }

    pub fn default_provider(&self) -> Option<Arc<dyn ManagedProvider>> {
        let name = self
            .default_provider_name
            .read()
            .ok()
            .map(|s| s.clone())
            .unwrap_or_else(|| "boat".into());
        if self.is_provider_enabled(&name) {
            if let Some(p) = self
                .provider_for(&name)
                .filter(|p| self.is_provider_enabled(p.name()))
            {
                return Some(p);
            }
        }
        let map = self.providers.read().ok()?;
        for id in CANONICAL_PROVIDERS {
            if self.is_provider_enabled(id) {
                if let Some(p) = map.get(id) {
                    return Some(Arc::clone(p));
                }
            }
        }
        map.values()
            .find(|p| self.is_provider_enabled(p.name()))
            .cloned()
    }

    pub fn provider_catalog(&self) -> Vec<ProviderCatalogEntry> {
        let Ok(map) = self.providers.read() else {
            return Vec::new();
        };
        let metas = self
            .provider_meta
            .read()
            .map(|m| m.clone())
            .unwrap_or_default();
        let stored = self
            .stored_providers
            .read()
            .map(|m| m.clone())
            .unwrap_or_default();
        let disabled = self.runtime_settings().disabled_providers;
        let canonical: [(&str, bool, bool, &[SizeSpec]); 4] = [
            ("boat", true, true, &SIZES),
            ("hetzner", false, false, &hetzner::HETZNER_SIZES),
            ("vastai", false, false, &vastai::VASTAI_SIZES),
            ("scaleway", false, false, scaleway::SCALEWAY_WORKER_SIZES),
        ];
        let mut out = Vec::with_capacity(canonical.len() + 1);
        for (id, free_stop, snapshots, fallback_sizes) in canonical {
            let enabled = !disabled.contains(id);
            let meta = metas.get(id);
            let st = stored.get(id);
            if let Some(p) = map.get(id) {
                out.push(ProviderCatalogEntry {
                    provider: id.to_string(),
                    display_name: provider_display_name(id).to_string(),
                    configured: true,
                    enabled,
                    supports_free_stop: p.supports_free_stop(),
                    supports_snapshots: p.supports_snapshots(),
                    credential_source: meta.and_then(|m| m.credential_source.clone()),
                    key_hint: meta.and_then(|m| m.key_hint.clone()),
                    region: meta.and_then(|m| m.region.clone()),
                    project_id: meta.and_then(|m| m.project_id.clone()),
                    sizes: p.sizes().to_vec(),
                });
            } else {
                out.push(ProviderCatalogEntry {
                    provider: id.to_string(),
                    display_name: provider_display_name(id).to_string(),
                    configured: false,
                    enabled,
                    supports_free_stop: free_stop,
                    supports_snapshots: snapshots,
                    credential_source: None,
                    key_hint: None,
                    region: st.and_then(|s| s.region.clone()),
                    project_id: st.and_then(|s| s.project_id.clone()),
                    sizes: fallback_sizes.to_vec(),
                });
            }
        }
        let mut extras: Vec<&String> = map
            .keys()
            .filter(|k| !canonical.iter().any(|(c, ..)| c == &k.as_str()))
            .collect();
        extras.sort();
        for key in extras {
            if let Some(p) = map.get(key) {
                let id = p.name();
                let meta = metas.get(id);
                out.push(ProviderCatalogEntry {
                    provider: id.to_string(),
                    display_name: provider_display_name(id).to_string(),
                    configured: true,
                    enabled: !disabled.contains(id),
                    supports_free_stop: p.supports_free_stop(),
                    supports_snapshots: p.supports_snapshots(),
                    credential_source: meta.and_then(|m| m.credential_source.clone()),
                    key_hint: meta.and_then(|m| m.key_hint.clone()),
                    region: meta.and_then(|m| m.region.clone()),
                    project_id: meta.and_then(|m| m.project_id.clone()),
                    sizes: p.sizes().to_vec(),
                });
            }
        }
        out
    }

    /// Register a cloud provider (from env, Bitwarden vault, or unit test) in
    /// memory and ensure the reaper/reconciler loops are active.
    pub fn register_provider(self: &Arc<Self>, provider: Arc<dyn ManagedProvider>) {
        self.register_provider_with_meta(provider, None);
    }

    fn insert_provider_and_meta(
        &self,
        provider: Arc<dyn ManagedProvider>,
        meta: Option<ProviderMeta>,
    ) {
        let name = provider.name().to_string();
        if let Some(m) = meta {
            if let Ok(mut metas) = self.provider_meta.write() {
                metas.insert(name.clone(), m);
            }
        }
        if let Ok(mut map) = self.providers.write() {
            let prefer_default = name == "boat" || map.is_empty();
            map.insert(name.clone(), provider);
            if prefer_default {
                if let Ok(mut def) = self.default_provider_name.write() {
                    if def.is_empty() || name == "boat" || !map.contains_key(def.as_str()) {
                        *def = name.clone();
                    }
                }
            }
        }
        let explicitly_off = matches!(
            std::env::var("SANDBOXED_MANAGED_ENABLED").ok().as_deref(),
            Some("0" | "false" | "no" | "off")
        );
        if !explicitly_off {
            self.enabled_runtime
                .store(true, std::sync::atomic::Ordering::SeqCst);
        }
    }

    pub fn register_provider_with_meta(
        self: &Arc<Self>,
        provider: Arc<dyn ManagedProvider>,
        meta: Option<ProviderMeta>,
    ) {
        self.insert_provider_and_meta(provider, meta);
        self.ensure_background_loops();
    }

    pub fn has_base_credential(&self, provider: &str) -> bool {
        let id = provider.trim().to_ascii_lowercase();
        self.base_credentials
            .read()
            .is_ok_and(|m| m.contains_key(&id))
    }

    /// Register a startup credential (`"environment"` or `"bitwarden"`) and
    /// reconcile it with any operator-saved `"settings"` override.
    pub fn register_base_credential(
        self: &Arc<Self>,
        provider: &str,
        source: &str,
        api_key: impl Into<String>,
        region: Option<String>,
        project_id: Option<String>,
    ) {
        let id = provider.trim().to_ascii_lowercase();
        let api_key = api_key.into().trim().to_string();
        if api_key.is_empty() {
            return;
        }
        if let Ok(mut base) = self.base_credentials.write() {
            base.insert(
                id.clone(),
                BaseProviderCredential {
                    source: source.to_string(),
                    api_key,
                    region: region
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty()),
                    project_id: project_id
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty()),
                },
            );
        }
        self.sync_provider_from_sources(&id);
        self.ensure_background_loops();
    }

    fn providers_config_path(&self) -> PathBuf {
        self.dir.join("managed_providers.json")
    }

    fn encryption_key(&self) -> Result<[u8; 32], String> {
        if let Ok(Some(key)) = crate::library::env_crypto::load_private_key_from_env() {
            return Ok(key);
        }
        let key_path = self.dir.join("private_key");
        if let Ok(contents) = std::fs::read_to_string(&key_path) {
            let trimmed = contents.trim();
            if !trimmed.is_empty() {
                if let Ok(key) = crate::library::env_crypto::parse_key_hex(trimmed) {
                    return Ok(key);
                }
            }
        }
        let key = crate::library::env_crypto::generate_private_key();
        let hex_key = hex::encode(key);
        let _ = std::fs::create_dir_all(&self.dir);
        write_atomic(&key_path, hex_key.as_bytes(), true);
        Ok(key)
    }

    fn build_cloud_provider(
        id: &str,
        api_key: &str,
        region: Option<&str>,
        project_id: Option<&str>,
    ) -> Option<BuiltCloudProvider> {
        match id {
            "boat" => {
                let base = std::env::var("BOAT_API_BASE")
                    .unwrap_or_else(|_| boat::DEFAULT_API_BASE.to_string());
                Some((Arc::new(boat::BoatProvider::new(base, api_key)), None, None))
            }
            "hetzner" => {
                let base = std::env::var("HETZNER_API_BASE")
                    .unwrap_or_else(|_| hetzner::DEFAULT_API_BASE.to_string());
                let p = hetzner::HetznerProvider::with_location(
                    base,
                    api_key,
                    region.map(str::to_string),
                );
                let loc = Some(p.default_location().to_string());
                Some((Arc::new(p), loc, None))
            }
            "vastai" => {
                let base = std::env::var("VASTAI_API_BASE")
                    .unwrap_or_else(|_| vastai::DEFAULT_API_BASE.to_string());
                Some((
                    Arc::new(vastai::VastAiProvider::new(base, api_key)),
                    None,
                    None,
                ))
            }
            "scaleway" => {
                let base = std::env::var("SCALEWAY_API_BASE")
                    .unwrap_or_else(|_| scaleway::DEFAULT_API_BASE.to_string());
                let p = scaleway::ScalewayProvider::with_config(
                    base,
                    api_key,
                    project_id.map(str::to_string),
                    region.map(str::to_string),
                );
                let zone = Some(p.default_zone().to_string());
                let proj = p.configured_project_id().map(str::to_string);
                Some((Arc::new(p), zone, proj))
            }
            _ => None,
        }
    }

    fn sync_provider_from_sources(&self, id: &str) {
        let stored = self
            .stored_providers
            .read()
            .ok()
            .and_then(|m| m.get(id).cloned());
        let base = self
            .base_credentials
            .read()
            .ok()
            .and_then(|m| m.get(id).cloned());

        let settings_key = stored
            .as_ref()
            .and_then(|s| s.encrypted_api_key.as_deref())
            .and_then(|enc| {
                let key = self.encryption_key().ok()?;
                crate::library::env_crypto::decrypt_value(&key, enc)
                    .ok()
                    .map(|v| v.trim().to_string())
                    .filter(|v| !v.is_empty())
            });

        let (effective_key, cred_source, key_hint) = if let Some(k) = settings_key {
            let hint = stored
                .as_ref()
                .and_then(|s| s.key_hint.clone())
                .unwrap_or_else(|| mask_key_hint(&k));
            (Some(k), Some("settings".to_string()), Some(hint))
        } else if let Some(b) = &base {
            (
                Some(b.api_key.clone()),
                Some(b.source.clone()),
                Some(mask_key_hint(&b.api_key)),
            )
        } else {
            (None, None, None)
        };

        let region = stored
            .as_ref()
            .and_then(|s| s.region.clone())
            .or_else(|| base.as_ref().and_then(|b| b.region.clone()));
        let project_id = stored
            .as_ref()
            .and_then(|s| s.project_id.clone())
            .or_else(|| base.as_ref().and_then(|b| b.project_id.clone()));

        if let Some(api_key) = effective_key {
            if let Some((provider, resolved_region, resolved_project)) =
                Self::build_cloud_provider(id, &api_key, region.as_deref(), project_id.as_deref())
            {
                self.insert_provider_and_meta(
                    provider,
                    Some(ProviderMeta {
                        credential_source: cred_source,
                        key_hint,
                        region: resolved_region,
                        project_id: resolved_project,
                    }),
                );
            }
        } else {
            if let Ok(mut map) = self.providers.write() {
                map.remove(id);
                if let Ok(mut def) = self.default_provider_name.write() {
                    if def.as_str() == id {
                        *def = map
                            .get("boat")
                            .map(|p| p.name().to_string())
                            .or_else(|| map.keys().next().cloned())
                            .unwrap_or_else(|| "boat".into());
                    }
                }
            }
            if let Ok(mut metas) = self.provider_meta.write() {
                metas.remove(id);
            }
        }
    }

    pub fn load_stored_providers(&self) {
        if let Some(parsed) = std::fs::read(self.providers_config_path())
            .ok()
            .and_then(|b| serde_json::from_slice::<HashMap<String, StoredProviderEntry>>(&b).ok())
        {
            if let Ok(mut slot) = self.stored_providers.write() {
                *slot = parsed;
            }
        }
        for id in CANONICAL_PROVIDERS {
            let should_sync = self
                .stored_providers
                .read()
                .is_ok_and(|m| m.contains_key(id))
                || self.has_base_credential(id);
            if should_sync {
                self.sync_provider_from_sources(id);
            }
        }
    }

    fn persist_stored_providers(&self) {
        let Ok(map) = self.stored_providers.read() else {
            return;
        };
        let _ = std::fs::create_dir_all(&self.dir);
        write_atomic(
            &self.providers_config_path(),
            &serde_json::to_vec_pretty(&*map).unwrap_or_default(),
            true,
        );
    }

    /// Update a provider's enable/disable state and/or encrypted credentials &
    /// regional settings at runtime without restarting Core.
    pub fn update_provider_config(
        self: &Arc<Self>,
        provider: &str,
        patch: ProviderUpdateRequest,
    ) -> Result<ProviderCatalogEntry, ManagedError> {
        let id = provider.trim().to_ascii_lowercase();
        if !CANONICAL_PROVIDERS.contains(&id.as_str()) {
            return Err(ManagedError::new(
                "unknown_provider",
                400,
                format!(
                    "Unknown provider '{provider}'; supported: {}",
                    CANONICAL_PROVIDERS.join(", ")
                ),
            ));
        }

        if let Some(enabled) = patch.enabled {
            let mut rt = self.runtime_settings();
            if enabled {
                rt.disabled_providers.remove(&id);
            } else {
                rt.disabled_providers.insert(id.clone());
            }
            self.set_runtime_settings(rt);
        }

        let mut changed_stored = false;
        let mut entry = self
            .stored_providers
            .read()
            .ok()
            .and_then(|m| m.get(&id).cloned())
            .unwrap_or_default();

        if let Some(raw_key) = patch.api_key {
            let trimmed = raw_key.trim();
            if trimmed.is_empty() {
                entry.encrypted_api_key = None;
                entry.key_hint = None;
            } else {
                let enc_key = self
                    .encryption_key()
                    .map_err(|e| ManagedError::new("crypto_error", 500, e))?;
                let encrypted = crate::library::env_crypto::encrypt_value(&enc_key, trimmed)
                    .map_err(|e| ManagedError::new("crypto_error", 500, e.to_string()))?;
                entry.encrypted_api_key = Some(encrypted);
                entry.key_hint = Some(mask_key_hint(trimmed));
            }
            changed_stored = true;
        }
        if let Some(raw_region) = patch.region {
            let trimmed = raw_region.trim();
            entry.region = if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            };
            changed_stored = true;
        }
        if let Some(raw_proj) = patch.project_id {
            let trimmed = raw_proj.trim();
            entry.project_id = if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            };
            changed_stored = true;
        }

        if changed_stored {
            if let Ok(mut slot) = self.stored_providers.write() {
                let is_empty = entry.encrypted_api_key.is_none()
                    && entry.region.is_none()
                    && entry.project_id.is_none();
                if is_empty {
                    slot.remove(&id);
                } else {
                    slot.insert(id.clone(), entry);
                }
            }
            self.persist_stored_providers();
            self.sync_provider_from_sources(&id);
            self.ensure_background_loops();
        }

        self.provider_catalog()
            .into_iter()
            .find(|p| p.provider == id)
            .ok_or_else(|| ManagedError::new("unknown_provider", 404, "Provider not found"))
    }

    pub(crate) fn ensure_background_loops(self: &Arc<Self>) {
        if !self.is_enabled() {
            return;
        }
        if self
            .loops_started
            .swap(true, std::sync::atomic::Ordering::SeqCst)
        {
            return;
        }
        let providers: Vec<String> = self
            .providers
            .read()
            .map(|m| m.keys().cloned().collect())
            .unwrap_or_default();
        tracing::info!(
            daily_cap = ?self.settings.daily_cap_usd,
            max_concurrent = ?self.settings.max_concurrent,
            ?providers,
            "Managed machines reaper & reconciler active"
        );
        let reaper = Arc::clone(self);
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(30)) => {}
                    _ = reaper.activity_notify.notified() => {
                        // Coalesce burst job/mission completions.
                        tokio::time::sleep(Duration::from_secs(1)).await;
                    }
                }
                reaper.reap_once().await;
            }
        });
        let rec = Arc::clone(self);
        tokio::spawn(async move {
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

    /// Wake the reaper promptly after a mission ends or a remote job completes.
    pub fn notify_activity_change(&self) {
        self.activity_notify.notify_one();
    }

    /// Install the mission-status lookup used to destroy machines whose
    /// owning mission has ended.
    pub fn set_owner_probe(&self, probe: OwnerProbe) {
        if let Ok(mut slot) = self.owner_probe.write() {
            *slot = Some(probe);
        }
    }

    /// Install the live active-missions lookup (`node_id -> Vec<mission_id>`).
    pub fn set_active_missions_probe(&self, probe: ActiveMissionsProbe) {
        if let Ok(mut slot) = self.active_missions_probe.write() {
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
        let is_live = m.state.is_live();
        let same_tenant = match (m.owner_user_id.as_deref(), tenant) {
            (Some(owner), Some(caller)) => owner == caller,
            (Some(_), None) => false,
            (None, _) => true,
        };
        if is_live && same_tenant && m.owner_mission_id.as_deref() == Some(mission_id) {
            return Ok(m);
        }
        let owner_none = m.owner_mission_id.is_none();
        let requester_is_current_owner = m
            .owner_mission_id
            .as_deref()
            .is_some_and(|current| requested_by == Some(current));
        let admitted = crate::orb_spec::vm_claim_admit(crate::orb_spec::VmClaimInput {
            is_live,
            same_tenant,
            owner_none,
            owner_in_lineage: requester_is_current_owner,
        });
        if !admitted {
            if !is_live {
                return Err(ManagedError::new("not_live", 409, "Machine is not running"));
            }
            if !same_tenant {
                return Err(ManagedError::new(
                    "forbidden",
                    403,
                    "Managed machine belongs to another user",
                ));
            }
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
        m.provisioning_mode.is_worker()
            && m.state.is_live()
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
            if m.provisioning_mode.is_worker() && !m.antigravity_projected {
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
        let parsed: Option<Persisted> = std::fs::read(self.machines_path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok());
        self.registry_authoritative
            .store(parsed.is_some(), std::sync::atomic::Ordering::SeqCst);
        let machines = parsed.unwrap_or_default();
        let secrets: HashMap<String, MachineSecrets> = std::fs::read(self.secrets_path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let mut machines = machines;
        let now = Utc::now();
        let mut recovered_dirty = false;
        // Crash recovery: any `Provisioning` or `Enrolling` row from a prior
        // Core process has no running provisioning task in this process.
        // Without `provider_id` it is closed immediately as `Failed`; with a
        // `provider_id` it moves to `Destroying` so `reap_once` cleans up the
        // half-enrolled VM instead of leaking until TTL.
        for m in machines.machines.iter_mut() {
            if matches!(
                m.state,
                MachineState::Provisioning | MachineState::Enrolling
            ) {
                recovered_dirty = true;
                if m.provider_id.is_none() {
                    m.state = MachineState::Failed;
                    m.destroyed_at = Some(now);
                    m.destroy_reason = Some("core_restarted_during_provision".into());
                    m.error =
                        Some("Core restarted before provider machine creation completed".into());
                    m.ledger_closed = true;
                } else {
                    m.state = MachineState::Destroying;
                    m.destroy_reason = Some("core_restarted_during_provision".into());
                    m.error = Some("Core restarted while machine was enrolling".into());
                }
            }
        }
        // Rows from before names existed: give live ones a name now.
        let mut live_names: Vec<String> = machines
            .machines
            .iter()
            .filter(|m| {
                (m.state.is_live() || m.state == MachineState::Stopped) && !m.name.is_empty()
            })
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
        if recovered_dirty {
            self.persist().await;
        }
        if let Some(rt) = std::fs::read(self.runtime_path())
            .ok()
            .and_then(|b| serde_json::from_slice::<RuntimeSettings>(&b).ok())
        {
            if let Ok(mut r) = self.runtime.write() {
                *r = rt;
            }
        }
        self.load_stored_providers();
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
            "cap_pool_id": machine.cap_pool_id,
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

    /// Whether the managed VM behind `node_id` provably cannot run a process
    /// any more: its record is `Destroyed`/`Failed` (set only after the
    /// provider confirmed the destroy, or it vanished from the provider), or
    /// the successfully loaded registry has no record of it at all. A
    /// `Stopped` VM keeps its disk and can resume, so it is not proof.
    pub async fn node_provably_gone(&self, node_id: &str) -> bool {
        let Some(id) = node_id.strip_prefix(NODE_PREFIX) else {
            return false;
        };
        let machines = self.machines.lock().await;
        node_gone_verdict(
            machines.iter().find(|m| m.id == id).map(|m| m.state),
            self.registry_authoritative
                .load(std::sync::atomic::Ordering::SeqCst),
        )
    }

    pub async fn budget(&self) -> BudgetView {
        self.budget_view(&self.machines.lock().await)
    }

    /// Display scope only; admission always uses the full global budget.
    pub async fn visible_budget(&self, tenant: &str) -> BudgetView {
        let machines: Vec<_> = self
            .machines
            .lock()
            .await
            .iter()
            .filter(|m| {
                m.provisioning_mode.is_worker() || m.owner_user_id.as_deref() == Some(tenant)
            })
            .cloned()
            .collect();
        self.budget_view(&machines)
    }

    fn budget_view(&self, machines: &[ManagedMachine]) -> BudgetView {
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
            shared_active: machines
                .iter()
                .filter(|m| m.state.is_live() && m.cap_pool_id.is_none())
                .count(),
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
        let active_by_node = match self
            .active_missions_probe
            .read()
            .ok()
            .and_then(|p| p.clone())
        {
            Some(probe) => probe().await,
            None => HashMap::new(),
        };
        let mut machines: Vec<_> = self
            .machines
            .lock()
            .await
            .iter()
            .filter(|m| {
                m.state.is_live() || m.state == MachineState::Stopped || m.created_at >= cutoff
            })
            .cloned()
            .map(|mut m| {
                if let Some(ids) = active_by_node.get(&m.node_id) {
                    m.active_mission_ids = ids.clone();
                }
                m
            })
            .collect();
        machines.sort_by_key(|m| std::cmp::Reverse(m.created_at));
        let daily_spend = self.daily_spend(SPEND_DAYS).await;
        let default_prov = self.default_provider();
        let provider_name = default_prov
            .as_ref()
            .map(|p| p.name().to_string())
            .unwrap_or_else(|| self.settings.provider.clone());
        let sizes = default_prov
            .as_ref()
            .map(|p| p.sizes().to_vec())
            .unwrap_or_else(|| SIZES.to_vec());
        ListView {
            enabled: self.is_enabled(),
            provider: provider_name,
            providers: self.provider_catalog(),
            machines,
            budget: self.budget().await,
            sizes,
            daily_spend,
        }
    }

    /// Every machine row (stats: VM cost per owner mission).
    pub async fn machines_snapshot(&self) -> Vec<ManagedMachine> {
        self.machines.lock().await.clone()
    }

    pub async fn daily_spend(&self, days: u32) -> Vec<DailySpend> {
        daily_spend(&self.machines.lock().await, days, Utc::now())
    }

    /// Only operator-allowlisted images may be started on snapshot-backed providers.
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

    fn resolve_cloud_image(
        provider_name: &str,
        size: &str,
        requested: Option<&str>,
    ) -> Result<String, ManagedError> {
        if let Some(raw) = requested.map(str::trim).filter(|s| !s.is_empty()) {
            if !raw
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '/' | '-'))
            {
                return Err(ManagedError::new(
                    "image_invalid",
                    400,
                    "Image identifier contains invalid characters",
                ));
            }
            return Ok(raw.to_string());
        }
        Ok(match provider_name {
            "hetzner" => "ubuntu-24.04".into(),
            "vastai" => "pytorch/pytorch:2.4.1-cuda12.4-cudnn9-devel".into(),
            "scaleway" if scaleway::is_apple_silicon_type(size) => "macos-15".into(),
            "scaleway" => "ubuntu_noble".into(),
            _ => "ubuntu-24.04".into(),
        })
    }

    /// Validate a request against size / arch / mode / TTL policy for a specific provider.
    pub fn plan_for_provider(
        settings: &ManagedSettings,
        provider_name: &str,
        req: &SpawnRequest,
    ) -> Result<(SizeSpec, u64), ManagedError> {
        let prov = provider_name.trim().to_ascii_lowercase();
        let requested_size = req.size.as_deref().map(str::trim).filter(|s| !s.is_empty());
        let requested_arch = match req.arch.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            None => None,
            Some(a)
                if a.eq_ignore_ascii_case("x86_64")
                    || a.eq_ignore_ascii_case("amd64")
                    || a.eq_ignore_ascii_case("x64") =>
            {
                Some("x86_64")
            }
            Some(a) if a.eq_ignore_ascii_case("arm64") || a.eq_ignore_ascii_case("aarch64") => {
                Some("arm64")
            }
            Some(other) => {
                return Err(ManagedError::new(
                    "invalid_arch",
                    400,
                    format!("Unsupported architecture '{other}'; use x86_64 or arm64"),
                ));
            }
        };
        let check_spec = |spec: SizeSpec| -> Result<SizeSpec, ManagedError> {
            if let Some(arch) = requested_arch {
                if spec.arch != arch {
                    return Err(ManagedError::new(
                        "invalid_size",
                        400,
                        format!(
                            "Size '{}' is {}, not requested architecture '{arch}'",
                            spec.size, spec.arch
                        ),
                    ));
                }
            }
            if req.cpu.is_some_and(|c| c > spec.cpu) || req.ram_gb.is_some_and(|r| r > spec.ram_gb)
            {
                return Err(ManagedError::new(
                    "invalid_size",
                    400,
                    format!(
                        "Size '{}' has {} vCPU / {} GB RAM, less than requested",
                        spec.size, spec.cpu, spec.ram_gb
                    ),
                ));
            }
            Ok(spec)
        };
        let find_smallest = |catalog: &[SizeSpec]| -> Option<SizeSpec> {
            catalog.iter().copied().find(|s| {
                requested_arch.is_none_or(|a| s.arch == a)
                    && req.cpu.is_none_or(|c| s.cpu >= c)
                    && req.ram_gb.is_none_or(|r| s.ram_gb >= r)
            })
        };

        let (spec, boat_rank_pair) = match prov.as_str() {
            "hetzner" => {
                let s = match (requested_size, req.cpu, req.ram_gb) {
                    (Some(name), _, _) => hetzner::hetzner_size_spec(name, requested_arch)
                        .ok_or_else(|| {
                            ManagedError::new(
                                "invalid_size",
                                400,
                                format!(
                                    "Unknown Hetzner size '{name}'; use cpx22, cpx32, cpx42, cax31, cpx52, cpx62, ccx33 or ccx43"
                                ),
                            )
                        })
                        .and_then(check_spec)?,
                    (None, None, None) => hetzner::hetzner_size_spec("default", requested_arch)
                        .unwrap_or(hetzner::HETZNER_SIZES[1]),
                    (None, _, _) => find_smallest(&hetzner::HETZNER_SIZES).ok_or_else(|| {
                        ManagedError::new(
                            "invalid_size",
                            400,
                            "No Hetzner machine size satisfies the requested CPU/RAM/arch",
                        )
                    })?,
                };
                (check_spec(s)?, (0u8, 0u8))
            }
            "vastai" => {
                let s = match (requested_size, req.cpu, req.ram_gb) {
                    (Some(name), _, _) => vastai::vastai_size_spec(name)
                        .ok_or_else(|| {
                            ManagedError::new(
                                "invalid_size",
                                400,
                                format!(
                                    "Unknown Vast.ai GPU size '{name}'; use rtx4090, l40s, a100 or h100"
                                ),
                            )
                        })
                        .and_then(check_spec)?,
                    (None, None, None) => check_spec(vastai::VASTAI_SIZES[0])?,
                    (None, _, _) => find_smallest(&vastai::VASTAI_SIZES).ok_or_else(|| {
                        ManagedError::new(
                            "invalid_size",
                            400,
                            "No Vast.ai GPU tier satisfies the requested CPU/RAM/arch",
                        )
                    })?,
                };
                (s, (0u8, 0u8))
            }
            "scaleway" => {
                let mode = req.provisioning_mode.unwrap_or_default();
                let s = match (requested_size, req.cpu, req.ram_gb) {
                    (Some(name), _, _) => scaleway::scaleway_size_spec(name)
                        .ok_or_else(|| {
                            ManagedError::new(
                                "invalid_size",
                                400,
                                format!(
                                    "Unknown Scaleway size '{name}'; use DEV1-M, DEV1-L, PRO2-S, PRO2-M, L4-1-24G, H100-1-80G, M2-M or M2-PRO"
                                ),
                            )
                        })
                        .and_then(check_spec)?,
                    (None, None, None) if requested_arch == Some("arm64") => {
                        find_smallest(&scaleway::SCALEWAY_SIZES).ok_or_else(|| {
                            ManagedError::new(
                                "invalid_size",
                                400,
                                "No Scaleway arm64 size available",
                            )
                        })?
                    }
                    (None, None, None) => check_spec(scaleway::SCALEWAY_SIZES[1])?,
                    (None, _, _) => {
                        let pool: &[SizeSpec] = if mode.is_worker() && requested_arch.is_none() {
                            scaleway::SCALEWAY_WORKER_SIZES
                        } else {
                            &scaleway::SCALEWAY_SIZES
                        };
                        find_smallest(pool).ok_or_else(|| {
                            ManagedError::new(
                                "invalid_size",
                                400,
                                "No Scaleway instance size satisfies the requested CPU/RAM/arch",
                            )
                        })?
                    }
                };
                if scaleway::is_apple_silicon_type(s.size) {
                    if mode.is_worker() {
                        return Err(ManagedError::new(
                            "unsupported_provisioning_mode",
                            400,
                            format!(
                                "Scaleway Apple Silicon '{}' runs macOS without cloud-init/Linux worker containment and cannot enroll as an orb-node worker. Pass provisioning_mode: \"raw\" with allow_24h_commitment: true.",
                                s.size
                            ),
                        ));
                    }
                    if req.allow_24h_commitment != Some(true) {
                        return Err(ManagedError::new(
                            "commitment_confirmation_required",
                            400,
                            format!(
                                "Scaleway Apple Silicon '{}' carries a mandatory 24-hour minimum billing lease (deletable_at, ~${:.2} committed). Pass allow_24h_commitment: true to confirm.",
                                s.size,
                                s.usd_per_hour * 24.0
                            ),
                        ));
                    }
                }
                (s, (0u8, 0u8))
            }
            _ => {
                let spec = match (requested_size, req.cpu, req.ram_gb) {
                    (Some(name), _, _) => size_spec(name)
                        .ok_or_else(|| {
                            ManagedError::new(
                                "invalid_size",
                                400,
                                format!(
                                    "Unknown size '{name}'; use small, default, large or xlarge"
                                ),
                            )
                        })
                        .and_then(check_spec)?,
                    (None, None, None) => {
                        check_spec(size_spec(&settings.default_size).unwrap_or(SIZES[0]))?
                    }
                    (None, _, _) => find_smallest(&SIZES).ok_or_else(|| {
                        ManagedError::new(
                            "invalid_size",
                            400,
                            "No machine size satisfies the requested CPU/RAM/arch (max 16 vCPU / 32 GB x86_64)",
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
                (
                    spec,
                    (
                        size_rank(spec.size) as u8,
                        size_rank(&settings.max_size) as u8,
                    ),
                )
            }
        };

        let ttl = req
            .ttl_minutes
            .unwrap_or(settings.default_ttl_minutes)
            .clamp(5, settings.max_ttl_minutes.max(5));
        if !crate::orb_spec::vm_spawn_admit(crate::orb_spec::VmSpawnInput {
            size_rank: boat_rank_pair.0,
            max_size_rank: boat_rank_pair.1,
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

    /// Validate a request against size / TTL policy. Pure, so it is unit-tested.
    pub fn plan(
        settings: &ManagedSettings,
        req: &SpawnRequest,
    ) -> Result<(SizeSpec, u64), ManagedError> {
        let provider_name = req
            .provider
            .as_deref()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(&settings.provider);
        Self::plan_for_provider(settings, provider_name, req)
    }

    fn core_url_for(&self, mode: ProvisioningMode) -> Result<String, ManagedError> {
        if !mode.is_worker() {
            return Ok(String::new());
        }
        self.settings.core_url.clone().ok_or_else(|| {
            ManagedError::new(
                "disabled",
                503,
                "SANDBOXED_PUBLIC_URL / SANDBOXED_MANAGED_CORE_URL is not set",
            )
        })
    }

    pub async fn spawn(
        self: &Arc<Self>,
        req: SpawnRequest,
    ) -> Result<ManagedMachine, ManagedError> {
        if !self.is_enabled() {
            return Err(ManagedError::new(
                "disabled",
                503,
                "Managed machines are disabled or no provider is configured",
            ));
        }
        let requested_provider = req
            .provider
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let any_configured = self.providers.read().is_ok_and(|p| !p.is_empty());
        let provider = if let Some(name) = requested_provider {
            let p = self.provider_for(name).ok_or_else(|| {
                let configured: Vec<String> = self
                    .provider_catalog()
                    .into_iter()
                    .filter(|p| p.configured)
                    .map(|p| p.provider)
                    .collect();
                ManagedError::new(
                    "unknown_provider",
                    400,
                    format!(
                        "Provider '{name}' is not configured; available: {}",
                        if configured.is_empty() {
                            "none".to_string()
                        } else {
                            configured.join(", ")
                        }
                    ),
                )
            })?;
            if !self.is_provider_enabled(p.name()) {
                return Err(ManagedError::new(
                    "provider_disabled",
                    409,
                    format!(
                        "Provider '{}' is disabled in Settings",
                        provider_display_name(p.name())
                    ),
                ));
            }
            p
        } else if let Some(of) = req.fork_of.as_deref() {
            if let Some(src) = self.get(of).await {
                let p = self
                    .provider_for(&src.provider)
                    .or_else(|| self.default_provider())
                    .ok_or_else(|| {
                        ManagedError::new(
                            "disabled",
                            503,
                            "No managed-machine provider is configured",
                        )
                    })?;
                if !self.is_provider_enabled(p.name()) {
                    return Err(ManagedError::new(
                        "provider_disabled",
                        409,
                        format!(
                            "Provider '{}' is disabled in Settings",
                            provider_display_name(p.name())
                        ),
                    ));
                }
                p
            } else {
                self.default_provider().ok_or_else(|| {
                    if any_configured {
                        ManagedError::new(
                            "provider_disabled",
                            409,
                            "All configured machine providers are disabled in Settings",
                        )
                    } else {
                        ManagedError::new(
                            "disabled",
                            503,
                            "No managed-machine provider is configured",
                        )
                    }
                })?
            }
        } else {
            self.default_provider().ok_or_else(|| {
                if any_configured {
                    ManagedError::new(
                        "provider_disabled",
                        409,
                        "All configured machine providers are disabled in Settings",
                    )
                } else {
                    ManagedError::new("disabled", 503, "No managed-machine provider is configured")
                }
            })?
        };
        if (req.fork_of.is_some() || req.from_snapshot.is_some()) && !provider.supports_snapshots()
        {
            return Err(ManagedError::new(
                "snapshots_unsupported",
                400,
                format!(
                    "Provider '{}' does not support warm snapshots or forks; use boat or spawn fresh",
                    provider.name()
                ),
            ));
        }
        let (spec, ttl_minutes) = Self::plan_for_provider(&self.settings, provider.name(), &req)?;
        let (image, source_snapshot, fork_source, provisioning_mode) = if provider
            .uses_cloud_init_bootstrap()
            && req.fork_of.is_none()
            && req.from_snapshot.is_none()
        {
            let mode = req.provisioning_mode.unwrap_or_default();
            let img = Self::resolve_cloud_image(provider.name(), spec.size, req.image.as_deref())?;
            (img, None, None, mode)
        } else {
            self.resolve_source(&req).await?
        };
        let core_url = self.core_url_for(provisioning_mode)?;
        let is_apple_silicon =
            provider.name() == "scaleway" && scaleway::is_apple_silicon_type(spec.size);
        let committed_minutes = if is_apple_silicon {
            ttl_minutes.max(24 * 60)
        } else {
            ttl_minutes
        };
        let min_cpu = req.cpu.map_or(spec.cpu, |c| c.max(spec.cpu));
        let min_ram_gb = req.ram_gb.map_or(spec.ram_gb, |r| r.max(spec.ram_gb));
        let quote = if fork_source.is_none() {
            let quote_spec = SpawnSpec {
                machine_id: String::new(),
                size: spec.size.into(),
                cpu: min_cpu,
                ram_gb: min_ram_gb,
                ttl_seconds: ttl_minutes * 60 + 300,
                image: Some(image.clone()),
                name: String::new(),
                idempotency_key: String::new(),
                bootstrap_script: None,
                gpu: req.gpu.clone(),
                arch: req.arch.clone(),
                max_hourly_usd: req.max_hourly_usd,
                preferred_offer_id: None,
                exclude_offer_ids: Vec::new(),
                allow_24h_commitment: req.allow_24h_commitment.unwrap_or(false),
                provisioning_mode,
            };
            provider
                .quote_spawn(&quote_spec)
                .await
                .map_err(|e| ManagedError::new("provider_quote_failed", 502, e))?
        } else {
            None
        };
        let effective_usd_per_hour = quote.as_ref().map_or(spec.usd_per_hour, |q| q.usd_per_hour);
        let effective_cpu = quote.as_ref().map_or(spec.cpu, |q| q.cpu);
        let effective_ram_gb = quote.as_ref().map_or(spec.ram_gb, |q| q.ram_gb);
        let quoted_offer_id = quote.and_then(|q| q.offer_id);

        let machine = {
            let _guard = self.admission.lock().await;
            let live_snapshot = self.machines.lock().await.clone();
            let cap_pool_id = self
                .check_concurrency_quota(
                    &live_snapshot,
                    provider.name(),
                    &req.cap_lineage,
                    None,
                    req.owner_mission_id
                        .as_deref()
                        .or(req.requested_by_mission_id.as_deref()),
                    req.owner_user_id.as_deref(),
                )
                .await?;
            let budget = self.budget_view(&live_snapshot);
            let new_cost = committed_minutes as f64 / 60.0 * effective_usd_per_hour;
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
            let spent_plus_new_cents =
                ((budget.spent_today_usd + budget.committed_usd + new_cost) * 100.0).ceil() as u64;
            let daily_cap_cents = self
                .settings
                .daily_cap_usd
                .map(|c| (c * 100.0).floor() as u64)
                .unwrap_or(spent_plus_new_cents.saturating_add(1));
            // Concurrency admission was already checked via `orb_vm_cap_admit`
            // in `check_concurrency_quota`, so pass `(0, 1)` slots here to keep
            // daily dollar budget and TTL gates independent of overridden pools.
            if !crate::orb_spec::vm_spawn_admit(crate::orb_spec::VmSpawnInput {
                size_rank: 0,
                max_size_rank: 0,
                secret_projected: false,
                active_count: 0,
                max_concurrent: 1,
                ttl_minutes: ttl_minutes as u32,
                max_ttl_minutes: self.settings.max_ttl_minutes.max(5) as u32,
                job_mem_pct: 90,
                spent_plus_new_cents,
                daily_cap_cents,
            }) {
                return Err(ManagedError::new(
                    "budget_exceeded",
                    402,
                    "Managed machine spawn rejected by kernel admission policy",
                ));
            }
            let spent_before_cents =
                ((budget.spent_today_usd + budget.committed_usd) * 100.0).ceil() as u64;
            let cost_delta_cents = spent_plus_new_cents.saturating_sub(spent_before_cents);
            let ledger_cap_cents = daily_cap_cents.max(spent_plus_new_cents);
            let now_tick = Utc::now().timestamp().max(0) as u64;
            let ttl_expiry_tick = now_tick.saturating_add(ttl_minutes.saturating_mul(60));
            let ledger_verdict = evaluate_resource_ledger_gate(
                crate::orb_spec::ResourceLedgerOp::Reserve,
                0,
                0,
                1,
                spent_before_cents,
                cost_delta_cents,
                ledger_cap_cents,
                now_tick,
                ttl_expiry_tick,
            );
            if !ledger_verdict.admitted {
                return Err(ManagedError::new(
                    "budget_exceeded",
                    402,
                    "Managed machine reservation rejected by orb_resource_ledger_step",
                ));
            }
            let reserve = if committed_minutes > ttl_minutes {
                new_cost
            } else {
                budget::reservation_for(ttl_minutes, effective_usd_per_hour)
            };
            if let Some(sub) = req.sub_budget_usd {
                if reserve > sub {
                    return Err(ManagedError::new(
                        "budget_exceeded",
                        402,
                        format!(
                            "The child's sub-budget ${sub:.2} cannot cover this machine's reservation ${reserve:.4} ({} for {} min); use a smaller size or a larger sub-budget",
                            spec.size,
                            committed_minutes.min(budget::RESERVE_MINUTES as u64).max(if is_apple_silicon { 24 * 60 } else { 0 })
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
            let live_names: Vec<String> = live_snapshot
                .iter()
                .filter(|m| m.state.is_live() || m.state == MachineState::Stopped)
                .map(|m| m.name.clone())
                .collect();
            let name_prefix = spec.size.to_ascii_lowercase();
            let name = allocate_name(&name_prefix, &live_names);
            let machine = ManagedMachine {
                provisioning_mode,
                name,
                antigravity_projected: false,
                node_id: format!("{NODE_PREFIX}{id}"),
                id,
                provider: provider.name().into(),
                provider_id: None,
                image: image.clone(),
                size: spec.size.into(),
                cpu: effective_cpu,
                ram_gb: effective_ram_gb,
                disk_gb: spec.disk_gb,
                usd_per_hour: effective_usd_per_hour,
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
                cap_pool_id,
                auto_extensions: 0,
                stopped_at: None,
                stopped_by_reaper: false,
                source_snapshot: source_snapshot.clone(),
                forked_from: fork_source.as_ref().map(|(id, _)| id.clone()),
                fork_source_provider_id: fork_source.as_ref().map(|(_, pid)| pid.clone()),
                resumes: 0,
                secrets_wiped: false,
                run_started_at: None,
                cost_before_resume: 0.0,
                prior_pool_charges: Vec::new(),
                pool_spent_offset: 0.0,
                project: req.snapshot_project.clone(),
                root_mission_id: req
                    .root_mission_id
                    .clone()
                    .or_else(|| req.owner_mission_id.clone()),
                active_mission_ids: Vec::new(),
                deletable_at: is_apple_silicon.then(|| now + chrono::Duration::hours(24)),
                has_executed_job: false,
            };
            self.machines.lock().await.push(machine.clone());
            self.persist().await;
            register_alias(&machine);
            machine
        };
        self.ledger("spawn_requested", &machine);

        let admitted_ceiling = if quoted_offer_id.is_some() {
            Some(
                req.max_hourly_usd
                    .map_or(effective_usd_per_hour, |m| m.min(effective_usd_per_hour)),
            )
        } else {
            req.max_hourly_usd
        };
        let extras = SpawnExtras {
            gpu: req.gpu.clone(),
            arch: req.arch.clone(),
            max_hourly_usd: admitted_ceiling,
            preferred_offer_id: quoted_offer_id,
            min_cpu: Some(min_cpu),
            min_ram_gb: Some(min_ram_gb),
            allow_24h_commitment: req.allow_24h_commitment.unwrap_or(false),
        };
        let this = Arc::clone(self);
        let id = machine.id.clone();
        let task = tokio::spawn(async move {
            let result = this
                .provision_with_extras(&id, provider, &core_url, ttl_minutes, extras)
                .await;
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

    pub(super) async fn provision(
        self: &Arc<Self>,
        id: &str,
        provider: Arc<dyn ManagedProvider>,
        core_url: &str,
        ttl_minutes: u64,
    ) -> Result<ManagedMachine, String> {
        self.provision_with_extras(id, provider, core_url, ttl_minutes, SpawnExtras::default())
            .await
    }

    async fn provision_with_extras(
        self: &Arc<Self>,
        id: &str,
        provider: Arc<dyn ManagedProvider>,
        core_url: &str,
        ttl_minutes: u64,
        extras: SpawnExtras,
    ) -> Result<ManagedMachine, String> {
        let mut m = self.get(id).await.ok_or("machine vanished")?;
        let started = tokio::time::Instant::now();
        // Mint the one-time enrollment token upfront so cloud-init / onstart
        // providers can embed it in the root-only bootstrap payload without SSH.
        let enroll_token = if m.provisioning_mode.is_worker() {
            let tok = random_token();
            let mut secrets = self.secrets.lock().await;
            let entry = secrets.entry(id.to_string()).or_default();
            entry.enroll_token_sha256 = Some(sha256_hex(&tok));
            entry.enroll_expires_at = Some(Utc::now() + chrono::Duration::minutes(15));
            entry.enroll_used = false;
            Some(tok)
        } else {
            None
        };
        let build_spec = |m: &ManagedMachine,
                          preferred_offer_id: Option<String>,
                          exclude_offer_ids: Vec<String>| {
            let capacity = (m.cpu / 2).max(1);
            let job_memory = managed_job_memory_bytes(m.ram_gb);
            let bootstrap_script = match (&enroll_token, provider.uses_cloud_init_bootstrap()) {
                (Some(tok), true) => Some(cloud_bootstrap_script(
                    core_url,
                    id,
                    &m.node_id,
                    tok,
                    capacity,
                    job_memory,
                    &m.provider,
                    &m.size,
                    &m.image,
                )),
                _ => None,
            };
            // boat stops the sandbox itself at TTL + a small grace, even if Core
            // is down: the hard backstop against runaway cost.
            SpawnSpec {
                machine_id: m.id.clone(),
                size: m.size.clone(),
                cpu: m.cpu,
                ram_gb: m.ram_gb,
                ttl_seconds: ttl_minutes * 60 + 300,
                image: Some(m.image.clone()),
                name: format!("{SANDBOX_NAME_PREFIX}{}", m.id),
                // A resume provisions the same machine id again.
                idempotency_key: if m.resumes == 0 {
                    format!("orb-managed-{}", m.id)
                } else {
                    format!("orb-managed-{}-r{}", m.id, m.resumes)
                },
                bootstrap_script,
                gpu: extras.gpu.clone(),
                arch: extras.arch.clone(),
                max_hourly_usd: extras.max_hourly_usd,
                preferred_offer_id,
                exclude_offer_ids,
                allow_24h_commitment: extras.allow_24h_commitment,
                provisioning_mode: m.provisioning_mode,
            }
        };
        let created = match m.fork_source_provider_id.clone() {
            Some(source) => {
                let spec = build_spec(&m, extras.preferred_offer_id.clone(), Vec::new());
                provider.fork(&source, &spec).await?
            }
            None => {
                let mut current_offer = extras.preferred_offer_id.clone();
                let mut excluded = Vec::new();
                let admitted_rate = m.usd_per_hour;
                loop {
                    let spec = build_spec(&m, current_offer.clone(), excluded.clone());
                    match provider.spawn(&spec).await {
                        Ok(created) => break created,
                        Err(first_err) => {
                            let Some(failed_offer) = current_offer.take() else {
                                return Err(first_err);
                            };
                            if excluded.len() >= 2 {
                                return Err(first_err);
                            }
                            excluded.push(failed_offer);
                            if !self.get(id).await.is_some_and(|cur| cur.state.is_live()) {
                                return Err("machine destroyed while provisioning".into());
                            }
                            let requote_spec = SpawnSpec {
                                cpu: extras.min_cpu.unwrap_or(m.cpu),
                                ram_gb: extras.min_ram_gb.unwrap_or(m.ram_gb),
                                bootstrap_script: None,
                                preferred_offer_id: None,
                                exclude_offer_ids: excluded.clone(),
                                max_hourly_usd: Some(
                                    extras
                                        .max_hourly_usd
                                        .map_or(admitted_rate, |cap| cap.min(admitted_rate)),
                                ),
                                ..spec
                            };
                            let Some(next_quote) = provider
                                .quote_spawn(&requote_spec)
                                .await
                                .map_err(|re_err| {
                                    format!("{first_err}; replacement quote failed: {re_err}")
                                })?
                            else {
                                return Err(first_err);
                            };
                            let Some(next_offer) = next_quote
                                .offer_id
                                .clone()
                                .filter(|o| !excluded.contains(o))
                            else {
                                return Err(first_err);
                            };
                            if next_quote.usd_per_hour > admitted_rate + 1e-9 {
                                return Err(first_err);
                            }
                            m = self
                                .update(id, |row| {
                                    row.cpu = next_quote.cpu;
                                    row.ram_gb = next_quote.ram_gb;
                                    row.usd_per_hour = next_quote.usd_per_hour;
                                })
                                .await
                                .ok_or("machine vanished")?;
                            current_offer = Some(next_offer);
                        }
                    }
                }
            }
        };
        let provider_id = created.provider_id.clone();
        let created_deletable_at = created.deletable_at;
        self.update(id, |m| {
            m.provider_id = Some(provider_id.clone());
            m.fork_source_provider_id = None;
            if created_deletable_at.is_some() {
                m.deletable_at = created_deletable_at;
            }
        })
        .await;
        let m = self.get(id).await.ok_or("machine vanished")?;
        self.ledger("provider_created", &m);

        // Wait for ready.
        let ready_timeout = if provider.uses_cloud_init_bootstrap() {
            300
        } else {
            240
        };
        let deadline = tokio::time::Instant::now() + Duration::from_secs(ready_timeout);
        loop {
            if !self.get(id).await.is_some_and(|m| m.state.is_live()) {
                return Err("machine destroyed while provisioning".into());
            }
            if let Ok(pm) = provider.get(&provider_id).await {
                if pm.deletable_at.is_some() {
                    let del = pm.deletable_at;
                    self.update(id, |m| m.deletable_at = del).await;
                }
                if provider.is_ready_state(&pm.state) {
                    break;
                }
                if pm.state == "error" {
                    return Err("provider reported error state".into());
                }
            }
            if tokio::time::Instant::now() > deadline {
                return Err(format!(
                    "provider machine not ready within {ready_timeout}s"
                ));
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
        let ready_ms = started.elapsed().as_millis() as u64;

        if !m.provisioning_mode.is_worker() {
            let machine = self
                .update(id, |m| {
                    if m.state == MachineState::Provisioning {
                        m.state = MachineState::Online;
                        m.online_at = Some(Utc::now());
                        m.last_busy_at = Some(Utc::now());
                    }
                })
                .await
                .ok_or("machine vanished")?;
            if machine.state != MachineState::Online {
                return Err("machine destroyed while provisioning".into());
            }
            self.ledger("raw_ready", &machine);
            return Ok(machine);
        }

        let enroll_token = enroll_token.ok_or("missing enrollment token")?;
        self.update(id, |m| m.state = MachineState::Enrolling).await;
        let (provision_ms, provisioned) = if provider.uses_cloud_init_bootstrap() {
            // Cloud-init / onstart script already writes enroll.env, runs
            // PROVISION_SCRIPT and starts sandboxed-node inside the guest.
            (0u64, Ok(()))
        } else {
            let capacity = (m.cpu / 2).max(1);
            let job_memory = managed_job_memory_bytes(m.ram_gb);
            let env = format!(
                "SANDBOXED_NODE_DIAL_CORE_URL={core_url}\nSANDBOXED_NODE_MANAGED_ID={id}\nSANDBOXED_NODE_ENROLL_TOKEN={enroll_token}\nSANDBOXED_NODE_ID={node}\nSANDBOXED_NODE_CAPACITY={capacity}\nSANDBOXED_NODE_JOB_MEMORY_BYTES={job_memory}\nSANDBOXED_NODE_LABELS=managed,trust=managed,provider={prov},size={size},image={image},lean\n",
                node = m.node_id,
                prov = m.provider,
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
            // Boat's sandbox exec proxy can transiently return HTTP 502
            // (`sandbox_direct_failed`) right after ready; retry transient errors.
            let mut provisioned = Err(String::new());
            for attempt in 0..4 {
                provisioned = match provider
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
                if provisioned.is_ok()
                    || provisioned
                        .as_ref()
                        .err()
                        .is_none_or(|e| !is_retryable_exec_error(e))
                {
                    break;
                }
                if attempt + 1 < 4 {
                    tokio::time::sleep(Duration::from_secs(3)).await;
                }
            }
            let provision_ms = provision_started.elapsed().as_millis() as u64;
            if let Err(error) = &provisioned {
                tracing::warn!(machine = %id, %error, "managed VM provisioning script failed");
            }
            // A fork or snapshot carries the source node's credential, projected
            // sign-in and delivered secrets: drop them once while orb-node is
            // stopped, BEFORE starting the daemon. Keeping credential deletion
            // separate from `systemctl restart` ensures a retry after a lost
            // exec response cannot erase a newly enrolled `node.cred`.
            let wipe_cmd = format!(
                "(sudo systemctl stop orb-node.service 2>/dev/null || true) && sudo rm -rf /var/lib/orb-node/node.cred /var/lib/orb-node/work/managed-auth && {} && chmod 600 /home/user/.orb/enroll.env",
                snapshots::SECRETS_WIPE
            );
            let mut wipe_res = Err(String::new());
            for attempt in 0..5 {
                wipe_res = provider
                    .exec(&provider_id, &wipe_cmd, 60)
                    .await
                    .and_then(|res| {
                        if let Some(code) = exec_exit_code(&res).filter(|c| *c != 0) {
                            Err(format!("exit code {code}"))
                        } else {
                            Ok(())
                        }
                    });
                if wipe_res.is_ok()
                    || wipe_res
                        .as_ref()
                        .err()
                        .is_none_or(|e| !is_retryable_exec_error(e))
                {
                    break;
                }
                if attempt + 1 < 5 {
                    tokio::time::sleep(Duration::from_secs(3)).await;
                }
            }
            wipe_res.map_err(|e| format!("prepare orb-node state: {e}"))?;

            let mut start_res = Err(String::new());
            for attempt in 0..5 {
                start_res = provider
                    .exec(&provider_id, "sudo systemctl restart orb-node.service", 120)
                    .await
                    .and_then(|node_started| {
                        if let Some(code) = exec_exit_code(&node_started).filter(|c| *c != 0) {
                            Err(format!("exit code {code}"))
                        } else {
                            Ok(())
                        }
                    });
                if start_res.is_ok()
                    || start_res
                        .as_ref()
                        .err()
                        .is_none_or(|e| !is_retryable_exec_error(e))
                {
                    break;
                }
                if attempt + 1 < 5 {
                    tracing::warn!(
                        machine = %id,
                        attempt = attempt + 1,
                        error = %start_res.as_ref().err().unwrap_or(&String::new()),
                        "transient error starting orb-node on managed VM; retrying"
                    );
                    tokio::time::sleep(Duration::from_secs(3)).await;
                }
            }
            start_res.map_err(|e| format!("start orb-node: {e}"))?;
            (provision_ms, provisioned)
        };
        let enroll_started = tokio::time::Instant::now();

        // Wait for the node to enroll and answer a heartbeat over the relay.
        let enroll_timeout = if provider.uses_cloud_init_bootstrap() {
            420
        } else {
            240
        };
        let deadline = tokio::time::Instant::now() + Duration::from_secs(enroll_timeout);
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
                            provider = %m.provider,
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
                return Err(format!(
                    "node did not enroll and answer a heartbeat within {enroll_timeout}s"
                ));
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }

    /// Verify an active, unused enrollment token for `/bootstrap-binary/:id`
    /// without consuming `enroll_used` (the guest still calls `/enroll` next).
    pub async fn verify_bootstrap_token(
        &self,
        machine_id: &str,
        enroll_token: &str,
    ) -> Option<ManagedMachine> {
        let machine = self.get(machine_id).await?;
        if !machine.provisioning_mode.is_worker() || !machine.state.is_live() {
            return None;
        }
        let secrets = self.secrets.lock().await;
        let entry = secrets.get(&machine.id)?;
        let valid = !entry.enroll_used
            && entry.enroll_expires_at.is_some_and(|exp| exp > Utc::now())
            && entry
                .enroll_token_sha256
                .as_deref()
                .is_some_and(|h| constant_time_eq(h, &sha256_hex(enroll_token)));
        valid.then_some(machine)
    }

    /// Exchange a one-time enrollment token for the node credential.
    pub async fn enroll(
        &self,
        machine_id: &str,
        enroll_token: &str,
    ) -> Result<(String, String), ManagedError> {
        let denied = || ManagedError::new("enrollment_denied", 401, "Enrollment denied");
        let machine = self.get(machine_id).await.ok_or_else(denied)?;
        if !machine.provisioning_mode.is_worker() || !machine.state.is_live() {
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
        if !machine.provisioning_mode.is_worker() || !machine.state.is_live() {
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
        if let (Some(p), Some(pid)) = (self.provider_for(&m.provider), &m.provider_id) {
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
        let current = self
            .get(id)
            .await
            .ok_or_else(|| ManagedError::new("not_found", 404, "Unknown managed machine"))?;
        // Scaleway Apple Silicon 24h minimum lease (`deletable_at`): never
        // call provider DELETE before `deletable_at`. Unregister the node &
        // close the relay so no new work lands on it, and schedule exact
        // deletion at `deletable_at`.
        if !failed
            && current.provider_id.is_some()
            && current
                .deletable_at
                .is_some_and(|del_at| Utc::now() < del_at)
        {
            let del_at = current.deletable_at.unwrap();
            let defer_reason = format!(
                "awaiting_deletable_at:{}",
                reason.as_deref().unwrap_or("requested")
            );
            unregister_node(&current);
            self.relay.close(&current.id).await;
            let m = self
                .update(id, |m| {
                    m.reap_at = Some(del_at);
                    m.reap_reason = Some(defer_reason.clone());
                    if m.destroy_reason.is_none() {
                        m.destroy_reason = reason.clone();
                    }
                })
                .await
                .unwrap_or(current);
            self.ledger("deferred_destroy", &m);
            return Ok(m);
        }
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
        if let (Some(provider), Some(pid)) = (self.provider_for(&m.provider), &m.provider_id) {
            // Wipe a projected sign-in before the disk is retained by the
            // provider (boat keeps stopped disks for 14 days).
            if m.provisioning_mode.is_worker() && m.antigravity_projected {
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
        let (Some(provider), Some(pid)) = (self.provider_for(&m.provider), &m.provider_id) else {
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
        let supports_free_stop = self
            .provider_for(&m.provider)
            .is_some_and(|p| p.supports_free_stop());
        let facts = lifecycle::ReapFacts {
            now,
            expires_at: m.expires_at,
            deletable_at: m.deletable_at,
            busy,
            has_executed_job: m.has_executed_job,
            supports_free_stop,
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
        for mut m in machines {
            match m.state {
                MachineState::Online | MachineState::Enrolling | MachineState::Provisioning => {
                    if m.state != MachineState::Online {
                        // Not yet serving: only the TTL applies.
                        if now >= m.expires_at {
                            let now_tick = now.timestamp().max(0) as u64;
                            let exp_tick = m.expires_at.timestamp().max(0) as u64;
                            let reap_ledger = evaluate_resource_ledger_gate(
                                crate::orb_spec::ResourceLedgerOp::ReapExpired,
                                1,
                                0,
                                1,
                                0,
                                0,
                                1,
                                now_tick,
                                exp_tick,
                            );
                            if reap_ledger.admitted {
                                let _ = self
                                    .destroy_inner(&m.id, Some("ttl_expired".into()), false)
                                    .await;
                                continue;
                            }
                        }
                    } else {
                        let busy = Self::node_busy(&m.node_id);
                        if busy {
                            if let Some(updated) = self
                                .update(&m.id, |m| {
                                    m.last_busy_at = Some(now);
                                    m.has_executed_job = true;
                                })
                                .await
                            {
                                m = updated;
                            }
                            if self.auto_extend(&m, now).await {
                                continue;
                            }
                        }
                        let (decision, _) = self.decide_for(&m, now).await;
                        match &decision {
                            ReapDecision::Stop { reason } => {
                                let admitted =
                                    crate::orb_spec::vm_should_reap(crate::orb_spec::VmReapInput {
                                        ttl_expired: false,
                                        busy,
                                        owner_ended: decision.is_owner_rule(),
                                        idle_expired: !decision.is_owner_rule(),
                                    });
                                if admitted && !dry_run {
                                    let _ = self.stop_inner(&m.id, reason, true).await;
                                    continue;
                                }
                                if admitted {
                                    self.note_would_reap(&m, reason, now).await;
                                }
                            }
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
                                    let release_ledger = evaluate_resource_ledger_gate(
                                        crate::orb_spec::ResourceLedgerOp::ReleaseActive,
                                        0,
                                        1,
                                        1,
                                        0,
                                        0,
                                        1,
                                        now.timestamp().max(0) as u64,
                                        m.expires_at.timestamp().max(0) as u64,
                                    );
                                    debug_assert!(release_ledger.admitted);
                                    let supports_free_stop = self
                                        .provider_for(&m.provider)
                                        .is_some_and(|p| p.supports_free_stop());
                                    if supports_free_stop
                                        && snapshots::stops_instead_of_destroy(reason)
                                    {
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
                                if reason.starts_with("awaiting_deletable_at:ttl_expired") {
                                    unregister_node(&m);
                                    self.relay.close(&m.id).await;
                                }
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

    /// Compare provider state with the registry across all configured providers.
    /// Provider VMs carrying our name prefix with no live registry row are
    /// stopped after `orphan_grace_minutes` (dry-run: reported only). Live rows
    /// whose VM the provider stopped, or no longer lists for two passes, are closed.
    pub async fn reconcile_once(&self) -> Result<Value, String> {
        let providers: Vec<Arc<dyn ManagedProvider>> = self
            .providers
            .read()
            .map(|m| m.values().cloned().collect())
            .unwrap_or_default();
        if providers.is_empty() {
            return Ok(serde_json::json!({"skipped": "no provider"}));
        }
        let machines = self.machines.lock().await.clone();
        let now = Utc::now();
        let dry_run = self.dry_run();
        let grace = chrono::Duration::minutes(self.settings.orphan_grace_minutes as i64);
        let mut total_remote = 0usize;
        let mut orphans_stopped = Vec::new();
        let mut orphans_pending = Vec::new();
        let mut orphan_ids = std::collections::HashSet::new();
        let mut closed = Vec::new();
        let mut vanished = Vec::new();
        let mut first_err: Option<String> = None;

        for provider in &providers {
            let prov_name = provider.name();
            let remote = match provider.list().await {
                Ok(r) => r,
                Err(e) => {
                    if first_err.is_none() {
                        first_err = Some(e);
                    }
                    continue;
                }
            };
            total_remote += remote.len();
            for pm in &remote {
                if !pm.name.starts_with(SANDBOX_NAME_PREFIX) || provider.is_stopped_state(&pm.state)
                {
                    continue;
                }
                let matches_provider = |m: &ManagedMachine| {
                    m.provider == prov_name || (providers.len() == 1 && m.provider == "boat")
                };
                let live = machines.iter().any(|m| {
                    matches_provider(m)
                        && m.provider_id.as_deref() == Some(&pm.provider_id)
                        && m.state.is_live()
                })
                // A spawn in flight has a row but no provider id yet.
                || machines.iter().any(|m| {
                    matches_provider(m)
                        && m.provider_id.is_none()
                        && m.state.is_live()
                        && pm.name == format!("{SANDBOX_NAME_PREFIX}{}", m.id)
                });
                if live {
                    continue;
                }
                if pm.deletable_at.is_some_and(|del_at| now < del_at) {
                    continue;
                }
                let orphan_key = format!("{prov_name}:{}", pm.provider_id);
                orphan_ids.insert(orphan_key.clone());
                let first = *self
                    .reconcile_state
                    .lock()
                    .await
                    .orphans_seen
                    .entry(orphan_key)
                    .or_insert(now);
                if now - first < grace || dry_run {
                    if now - first >= grace {
                        tracing::warn!(provider = %prov_name, sandbox = %pm.provider_id, "managed reconcile (dry-run) would stop orphan sandbox");
                    }
                    orphans_pending.push(serde_json::json!({
                        "provider": prov_name,
                        "provider_id": pm.provider_id,
                        "name": pm.name,
                        "first_seen": first,
                        "stop_at": first + grace,
                    }));
                    continue;
                }
                tracing::warn!(provider = %prov_name, sandbox = %pm.provider_id, "stopping orphan managed sandbox");
                if provider.destroy(&pm.provider_id).await.is_ok() {
                    orphans_stopped.push(pm.provider_id.clone());
                }
            }

            for m in machines.iter().filter(|m| {
                m.state.is_live()
                    && (m.provider == prov_name || (providers.len() == 1 && m.provider == "boat"))
            }) {
                let Some(pid) = &m.provider_id else { continue };
                match remote.iter().find(|p| &p.provider_id == pid) {
                    Some(pm) => {
                        self.reconcile_state
                            .lock()
                            .await
                            .vanished_passes
                            .remove(&m.id);
                        if pm.deletable_at.is_some() && m.deletable_at != pm.deletable_at {
                            let del = pm.deletable_at;
                            self.update(&m.id, |row| row.deletable_at = del).await;
                        }
                        if provider.is_stopped_state(&pm.state) {
                            if m.state == MachineState::Online {
                                let _ = self
                                    .destroy_inner(&m.id, Some("stopped_by_provider".into()), false)
                                    .await;
                                closed.push(m.id.clone());
                            } else if m.state == MachineState::Destroying {
                                self.mark_vanished(&m.id).await;
                                vanished.push(m.id.clone());
                            }
                        }
                    }
                    // An empty list while we know live Online VMs is more likely a
                    // provider glitch than every VM vanishing: wait for proof.
                    // A Destroying row whose provider no longer lists it for two
                    // passes (e.g. rotated API key or already reaped) is safe to close.
                    None if (!remote.is_empty() && m.state == MachineState::Online)
                        || m.state == MachineState::Destroying =>
                    {
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
        }
        if total_remote == 0 {
            if let Some(err) = first_err {
                return Err(err);
            }
        }
        self.reconcile_state
            .lock()
            .await
            .orphans_seen
            .retain(|id, _| orphan_ids.contains(id));

        Ok(serde_json::json!({
            "provider_machines": total_remote,
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

/// Per-provider live usage against an active mission concurrency override.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ProviderCapUsageView {
    pub provider: String,
    pub active: usize,
    pub max_concurrent: usize,
}

/// Resolved concurrency limits governing a mission (either its own/ancestor
/// override pool or the global default).
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct EffectiveVmLimitsView {
    /// `"mission"` when an override pool governs this mission, else `"global"`.
    pub source: &'static str,
    pub pool_id: Option<String>,
    pub active: usize,
    pub max_concurrent: Option<usize>,
    pub global_active: usize,
    pub global_max_concurrent: Option<usize>,
    pub ancestor_max_concurrent: Option<usize>,
    pub provider_limits: Vec<ProviderCapUsageView>,
}

/// A mission's budget and VM concurrency limits as the API returns them.
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
    /// Operator-configured concurrency override on this mission itself.
    pub own_vm_limits: Option<budget::VmConcurrencyLimits>,
    /// `"own"`, `"pooled"` (from an ancestor), or `"global"` (no override).
    pub vm_limits_mode: &'static str,
    /// Nearest pool in lineage with `vm_limits` (self, ancestor, or none).
    pub vm_limits_pool_id: Option<String>,
    pub effective_vm_limits: EffectiveVmLimitsView,
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
    pub has_vm_limits: bool,
    pub vm_max_concurrent: Option<usize>,
    pub live_machines: usize,
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
    /// Resolve the cap lineage when the caller did not supply an explicit
    /// `MissionStore` chain (e.g. background auto-resume or direct manager tests).
    fn fallback_cap_lineage(
        pools: &HashMap<String, budget::BudgetPool>,
        existing_cap_pool_id: Option<&str>,
        owner_mission_id: Option<&str>,
    ) -> Vec<String> {
        let mut chain = Vec::new();
        if let Some(m) = owner_mission_id {
            chain.push(m.to_string());
        }
        let mut cur = existing_cap_pool_id.or(owner_mission_id);
        for _ in 0..32 {
            let Some(id) = cur else { break };
            if !chain.iter().any(|x| x == id) {
                chain.push(id.to_string());
            }
            cur = pools.get(id).and_then(|p| p.parent_cap_pool_id.as_deref());
        }
        chain
    }

    fn resolve_covering_cap_pool(
        pools: &HashMap<String, budget::BudgetPool>,
        chain: &[String],
        provider: &str,
        user_id: Option<&str>,
    ) -> Option<String> {
        if let Some(u) = user_id {
            budget::nearest_cap_pool_for_provider(
                chain.iter().map(String::as_str),
                pools,
                u,
                provider,
            )
        } else {
            chain
                .iter()
                .find(|id| {
                    pools.get(id.as_str()).is_some_and(|p| {
                        p.owner_user_id.is_none()
                            && p.vm_limits.as_ref().is_some_and(|l| l.covers(provider))
                    })
                })
                .cloned()
        }
    }

    /// Unified concurrency quota gate across `spawn`, `resume`, and sibling
    /// pool transfers. Must be called under `self.admission` lock.
    ///
    /// Returns `Ok(Some(pool_id))` when an override pool covers `provider`,
    /// `Ok(None)` when the shared global pool admitted the machine, or `Err`
    /// (`429 quota_exceeded`) when blocked.
    pub(crate) async fn check_concurrency_quota(
        &self,
        machines: &[ManagedMachine],
        provider: &str,
        cap_lineage: &[String],
        existing_cap_pool_id: Option<&str>,
        owner_mission_id: Option<&str>,
        user_id: Option<&str>,
    ) -> Result<Option<String>, ManagedError> {
        let pools = self.budgets.lock().await.clone();
        let chain = if !cap_lineage.is_empty() {
            cap_lineage.to_vec()
        } else {
            Self::fallback_cap_lineage(&pools, existing_cap_pool_id, owner_mission_id)
        };
        let covering = Self::resolve_covering_cap_pool(&pools, &chain, provider, user_id);
        let shared_active = machines
            .iter()
            .filter(|m| m.state.is_live() && m.cap_pool_id.is_none())
            .count();
        let shared_active_u32 = shared_active.min(u32::MAX as usize) as u32;
        let has_global_max = self.settings.max_concurrent.is_some();
        let global_max = self
            .settings
            .max_concurrent
            .unwrap_or(0)
            .min(u32::MAX as usize) as u32;

        if let Some(pool_id) = covering {
            let lim = pools
                .get(&pool_id)
                .and_then(|p| p.vm_limits.as_ref())
                .cloned()
                .unwrap_or_default();
            let (pool_active_usize, prov_active_usize) =
                budget::cap_pool_counts(&pool_id, provider, &pools, machines);
            let prov_cap = lim.provider_max_concurrent.get(provider).copied();

            let mut blocked_ancestor_msg: Option<String> = None;
            for anc_id in budget::ancestor_cap_chain(&pool_id, &chain, &pools, user_id) {
                if blocked_ancestor_msg.is_some() {
                    break;
                }
                let Some(anc_lim) = pools.get(&anc_id).and_then(|p| p.vm_limits.as_ref()) else {
                    continue;
                };
                let (anc_total, anc_prov) =
                    budget::cap_pool_counts(&anc_id, provider, &pools, machines);
                if let Some(&anc_p_max) = anc_lim.provider_max_concurrent.get(provider) {
                    if anc_prov >= anc_p_max {
                        blocked_ancestor_msg = Some(if anc_p_max == 0 {
                            format!(
                                "Provider '{provider}' is disabled by ancestor mission concurrency limit on pool {anc_id}"
                            )
                        } else {
                            format!(
                                "{anc_prov} '{provider}' managed machines are running in ancestor pool {anc_id} (provider max {anc_p_max}); destroy one first"
                            )
                        });
                        break;
                    }
                }
                if let Some(anc_max) = anc_lim.max_concurrent {
                    if anc_total >= anc_max {
                        blocked_ancestor_msg = Some(format!(
                            "{anc_total} managed machines are running in ancestor pool {anc_id} (mission max {anc_max}); destroy one first"
                        ));
                        break;
                    }
                }
            }

            let admitted = crate::orb_spec::vm_cap_admit(crate::orb_spec::VmCapInput {
                has_pool_override: true,
                has_pool_max: lim.max_concurrent.is_some(),
                has_provider_max: prov_cap.is_some(),
                has_global_max,
                ancestor_blocked: blocked_ancestor_msg.is_some(),
                shared_active: shared_active_u32,
                global_max,
                pool_active: pool_active_usize.min(u32::MAX as usize) as u32,
                pool_max: lim.max_concurrent.unwrap_or(0).min(u32::MAX as usize) as u32,
                provider_active: prov_active_usize.min(u32::MAX as usize) as u32,
                provider_max: prov_cap.unwrap_or(0).min(u32::MAX as usize) as u32,
            });
            if !admitted {
                let msg = if prov_cap == Some(0) {
                    format!(
                        "Provider '{provider}' is disabled by mission concurrency limit on pool {pool_id} (0 allowed)"
                    )
                } else if let Some(p_max) = prov_cap.filter(|&m| prov_active_usize >= m) {
                    format!(
                        "{prov_active_usize} '{provider}' managed machines are running in mission pool {pool_id} (provider max {p_max}); destroy one first"
                    )
                } else if let Some(t_max) = lim.max_concurrent.filter(|&m| pool_active_usize >= m) {
                    format!(
                        "{pool_active_usize} managed machines are running in mission pool {pool_id} (mission max {t_max}); destroy one first"
                    )
                } else {
                    blocked_ancestor_msg.unwrap_or_else(|| {
                        "Managed machine spawn rejected by mission concurrency cap".to_string()
                    })
                };
                return Err(ManagedError::new("quota_exceeded", 429, msg));
            }
            Ok(Some(pool_id))
        } else {
            let admitted = crate::orb_spec::vm_cap_admit(crate::orb_spec::VmCapInput {
                has_pool_override: false,
                has_pool_max: false,
                has_provider_max: false,
                has_global_max,
                ancestor_blocked: false,
                shared_active: shared_active_u32,
                global_max,
                pool_active: 0,
                pool_max: 0,
                provider_active: 0,
                provider_max: 0,
            });
            if !admitted {
                let max = self.settings.max_concurrent.unwrap_or(0);
                return Err(ManagedError::new(
                    "quota_exceeded",
                    429,
                    format!(
                        "{shared_active} managed machines are running (max {max}); destroy one first"
                    ),
                ));
            }
            Ok(None)
        }
    }

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
        pools.get(pool_id).and_then(|p| p.budget_usd)?;
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
                {
                    let mut pools = self.budgets.lock().await;
                    let remove_entry = match pools.get_mut(mission_id) {
                        Some(entry) if entry.vm_limits.is_some() => {
                            entry.budget_usd = None;
                            entry.parent_pool_id = None;
                            entry.updated_at = Utc::now();
                            false
                        }
                        Some(_) => true,
                        None => false,
                    };
                    if remove_entry {
                        pools.remove(mission_id);
                    }
                    // Child pools re-attach to the parent pool.
                    for p in pools.values_mut() {
                        if p.parent_pool_id.as_deref() == Some(mission_id) {
                            p.parent_pool_id =
                                parent_pool.clone().filter(|anc| anc != &p.mission_id);
                        }
                    }
                }
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
                let existing = pools.get(mission_id).cloned();
                let had_budget = existing.as_ref().is_some_and(|p| p.budget_usd.is_some());
                pools.insert(
                    mission_id.to_string(),
                    budget::BudgetPool {
                        mission_id: mission_id.to_string(),
                        budget_usd: Some(amount),
                        parent_pool_id: parent_pool.clone().filter(|p| p != mission_id),
                        vm_limits: existing.as_ref().and_then(|p| p.vm_limits.clone()),
                        parent_cap_pool_id: existing
                            .as_ref()
                            .and_then(|p| p.parent_cap_pool_id.clone()),
                        owner_user_id: owner_user_id
                            .or_else(|| existing.and_then(|p| p.owner_user_id)),
                        updated_at: Utc::now(),
                    },
                );
                drop(pools);
                if !had_budget {
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

    /// Set (`Some`) or clear (`None`) a mission's VM concurrency override.
    pub async fn set_mission_vm_limits(
        &self,
        mission_id: &str,
        limits: Option<budget::VmConcurrencyLimits>,
        lineage: &[String],
        parent_cap_pool: Option<String>,
        owner_user_id: Option<String>,
    ) -> Result<(), ManagedError> {
        let _guard = self.admission.lock().await;
        match limits {
            None => {
                let pools_snapshot = {
                    let mut pools = self.budgets.lock().await;
                    let remove_entry = match pools.get_mut(mission_id) {
                        Some(entry) if entry.budget_usd.is_some() => {
                            entry.vm_limits = None;
                            entry.parent_cap_pool_id = None;
                            entry.updated_at = Utc::now();
                            false
                        }
                        Some(_) => true,
                        None => false,
                    };
                    if remove_entry {
                        pools.remove(mission_id);
                    }
                    for p in pools.values_mut() {
                        if p.parent_cap_pool_id.as_deref() == Some(mission_id) {
                            p.parent_cap_pool_id =
                                parent_cap_pool.clone().filter(|anc| anc != &p.mission_id);
                        }
                    }
                    pools.clone()
                };
                let mut machines = self.machines.lock().await;
                for m in machines.iter_mut() {
                    if m.cap_pool_id.as_deref() == Some(mission_id) {
                        let fallback_chain = Self::fallback_cap_lineage(
                            &pools_snapshot,
                            parent_cap_pool.as_deref(),
                            None,
                        );
                        m.cap_pool_id = Self::resolve_covering_cap_pool(
                            &pools_snapshot,
                            &fallback_chain,
                            &m.provider,
                            m.owner_user_id.as_deref(),
                        );
                    }
                }
            }
            Some(raw) => {
                let validated = budget::validate_vm_limits(raw)
                    .map_err(|e| ManagedError::new("invalid_vm_limits", 400, e))?;
                let pools_before = self.budgets.lock().await.clone();
                let anc_chain = if !lineage.is_empty() {
                    lineage.iter().skip(1).cloned().collect::<Vec<_>>()
                } else {
                    Self::fallback_cap_lineage(&pools_before, parent_cap_pool.as_deref(), None)
                };
                for anc_id in &anc_chain {
                    let Some(anc_pool) = pools_before.get(anc_id.as_str()) else {
                        continue;
                    };
                    if owner_user_id.is_some() && anc_pool.owner_user_id != owner_user_id {
                        continue;
                    }
                    let Some(anc_lim) = anc_pool.vm_limits.as_ref() else {
                        continue;
                    };
                    if let (Some(c_max), Some(a_max)) =
                        (validated.max_concurrent, anc_lim.max_concurrent)
                    {
                        if c_max > a_max {
                            return Err(ManagedError::new(
                                "sub_limit_exceeds_pool",
                                400,
                                format!(
                                    "max_concurrent ({c_max}) exceeds ancestor pool {anc_id}'s max_concurrent ({a_max})"
                                ),
                            ));
                        }
                    }
                    for (prov, &c_p) in &validated.provider_max_concurrent {
                        if let Some(&a_p) = anc_lim.provider_max_concurrent.get(prov) {
                            if c_p > a_p {
                                return Err(ManagedError::new(
                                    "sub_limit_exceeds_pool",
                                    400,
                                    format!(
                                        "Limit for '{prov}' ({c_p}) exceeds ancestor pool {anc_id}'s '{prov}' limit ({a_p})"
                                    ),
                                ));
                            }
                        }
                        if let Some(a_max) = anc_lim.max_concurrent {
                            if c_p > a_max {
                                return Err(ManagedError::new(
                                    "sub_limit_exceeds_pool",
                                    400,
                                    format!(
                                        "Limit for '{prov}' ({c_p}) exceeds ancestor pool {anc_id}'s max_concurrent ({a_max})"
                                    ),
                                ));
                            }
                        }
                    }
                }
                let pools_snapshot = {
                    let mut pools = self.budgets.lock().await;
                    let existing = pools.get(mission_id).cloned();
                    pools.insert(
                        mission_id.to_string(),
                        budget::BudgetPool {
                            mission_id: mission_id.to_string(),
                            budget_usd: existing.as_ref().and_then(|p| p.budget_usd),
                            parent_pool_id: existing
                                .as_ref()
                                .and_then(|p| p.parent_pool_id.clone()),
                            vm_limits: Some(validated),
                            parent_cap_pool_id: parent_cap_pool.clone().filter(|p| p != mission_id),
                            owner_user_id: owner_user_id
                                .or_else(|| existing.and_then(|p| p.owner_user_id)),
                            updated_at: Utc::now(),
                        },
                    );
                    pools.clone()
                };
                // Re-evaluate live or stopped machines directly owned by `mission_id`
                // (or already pointing at `mission_id`), so e.g. removing a provider
                // limit releases machines on that provider back to the ancestor/global pool.
                let mut machines = self.machines.lock().await;
                for m in machines.iter_mut().filter(|m| {
                    (m.state.is_live() || m.state == MachineState::Stopped)
                        && (m.owner_mission_id.as_deref() == Some(mission_id)
                            || m.cap_pool_id.as_deref() == Some(mission_id))
                }) {
                    let chain = Self::fallback_cap_lineage(
                        &pools_snapshot,
                        Some(mission_id),
                        m.owner_mission_id.as_deref(),
                    );
                    m.cap_pool_id = Self::resolve_covering_cap_pool(
                        &pools_snapshot,
                        &chain,
                        &m.provider,
                        m.owner_user_id.as_deref(),
                    );
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
                Some(p) if p.budget_usd.is_some() && p.parent_pool_id != parent_pool => {
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

    /// Re-attach a concurrency override pool to its current nearest ancestor cap pool.
    pub async fn reparent_cap_pool(&self, mission_id: &str, parent_cap_pool: Option<String>) {
        let changed = {
            let mut pools = self.budgets.lock().await;
            match pools.get_mut(mission_id) {
                Some(p) if p.vm_limits.is_some() && p.parent_cap_pool_id != parent_cap_pool => {
                    p.parent_cap_pool_id = parent_cap_pool.filter(|p| p != mission_id);
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

    /// Attribute a machine's concurrency slot to `cap_pool` (or `None` for global).
    pub async fn set_machine_cap_pool(&self, id: &str, cap_pool: Option<String>) {
        if let Some(m) = self.get(id).await {
            if m.cap_pool_id != cap_pool {
                if let Some(m) = self
                    .update(&m.id, |m| {
                        m.cap_pool_id = cap_pool;
                    })
                    .await
                {
                    self.ledger("cap_pool_set", &m);
                }
            }
        }
    }

    /// Budget and concurrency-override view for one mission. `lineage` is the
    /// mission then its ancestors; `children` its direct children.
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
        let cap_pool_id =
            budget::nearest_cap_pool(lineage.iter().map(String::as_str), &pools, user_id);
        let open = self.open_pools(&pools).await;
        let machines = self.machines.lock().await.clone();
        let now = Utc::now();
        let is_open = |id: &str| open.get(id).copied().unwrap_or(true);
        let pool = pool_id
            .as_deref()
            .and_then(|p| budget::pool_usage(p, &pools, &machines, now, &is_open));
        let own = pools.get(mission_id).and_then(|p| p.budget_usd);
        let own_vm_limits = pools.get(mission_id).and_then(|p| p.vm_limits.clone());

        let global_active = machines
            .iter()
            .filter(|m| m.state.is_live() && m.cap_pool_id.is_none())
            .count();
        let global_max_concurrent = self.settings.max_concurrent;

        // Strict ancestor total ceiling (analogous to `max_grant_usd`).
        let ancestor_max_concurrent = lineage
            .iter()
            .skip(1)
            .filter_map(|anc| {
                pools
                    .get(anc.as_str())
                    .filter(|p| p.owner_user_id.as_deref() == Some(user_id))
                    .and_then(|p| p.vm_limits.as_ref())
                    .and_then(|l| l.max_concurrent)
            })
            .min();

        let effective_vm_limits = if let Some(ref cp_id) = cap_pool_id {
            let mut chain_pools = vec![cp_id.clone()];
            chain_pools.extend(budget::ancestor_cap_chain(
                cp_id,
                lineage,
                &pools,
                Some(user_id),
            ));
            let eff_max = chain_pools
                .iter()
                .filter_map(|id| {
                    pools
                        .get(id.as_str())
                        .and_then(|p| p.vm_limits.as_ref())
                        .and_then(|l| l.max_concurrent)
                })
                .min();
            let (pool_active, _) = budget::cap_pool_counts(cp_id, "", &pools, &machines);
            let mut provider_limits = Vec::new();
            for prov in CANONICAL_PROVIDERS {
                let prov_cap = chain_pools
                    .iter()
                    .filter_map(|id| {
                        pools
                            .get(id.as_str())
                            .and_then(|p| p.vm_limits.as_ref())
                            .and_then(|l| l.provider_max_concurrent.get(prov).copied())
                    })
                    .min();
                if let Some(max_c) = prov_cap {
                    let (_, prov_active) = budget::cap_pool_counts(cp_id, prov, &pools, &machines);
                    provider_limits.push(ProviderCapUsageView {
                        provider: prov.to_string(),
                        active: prov_active,
                        max_concurrent: max_c,
                    });
                }
            }
            EffectiveVmLimitsView {
                source: "mission",
                pool_id: Some(cp_id.clone()),
                active: pool_active,
                max_concurrent: eff_max,
                global_active,
                global_max_concurrent,
                ancestor_max_concurrent,
                provider_limits,
            }
        } else {
            EffectiveVmLimitsView {
                source: "global",
                pool_id: None,
                active: global_active,
                max_concurrent: global_max_concurrent,
                global_active,
                global_max_concurrent,
                ancestor_max_concurrent,
                provider_limits: Vec::new(),
            }
        };

        let children = children
            .iter()
            .map(|c| {
                let child_pool = pools.get(c);
                let has_vm_limits = child_pool.is_some_and(|p| p.vm_limits.is_some());
                let vm_max_concurrent = child_pool
                    .and_then(|p| p.vm_limits.as_ref())
                    .and_then(|l| l.max_concurrent);
                let live_machines = if has_vm_limits {
                    budget::cap_pool_counts(c, "", &pools, &machines).0
                } else {
                    machines
                        .iter()
                        .filter(|m| {
                            m.state.is_live() && m.owner_mission_id.as_deref() == Some(c.as_str())
                        })
                        .count()
                };
                match child_pool.and_then(|p| p.budget_usd) {
                    Some(b_usd) => {
                        let u = budget::pool_usage(c, &pools, &machines, now, &is_open);
                        ChildBudgetView {
                            mission_id: c.clone(),
                            mode: "sub_budget",
                            budget_usd: Some(b_usd),
                            spent_usd: u.as_ref().map_or(0.0, |u| u.spent_usd),
                            reserved_usd: u.as_ref().map_or(0.0, |u| u.reserved_usd + u.carved_usd),
                            has_vm_limits,
                            vm_max_concurrent,
                            live_machines,
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
                            has_vm_limits,
                            vm_max_concurrent,
                            live_machines,
                        }
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
            vm_limits_mode: if own_vm_limits.is_some() {
                "own"
            } else if cap_pool_id.is_some() {
                "pooled"
            } else {
                "global"
            },
            own_vm_limits,
            vm_limits_pool_id: cap_pool_id,
            effective_vm_limits,
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
        self.take_idle_sibling_for_lineage(None, &[], want, candidates_ok)
            .await
    }

    pub async fn take_idle_sibling_for_provider(
        &self,
        want_provider: Option<&str>,
        want: &SiblingReuse<'_>,
        candidates_ok: &(dyn Fn(&str) -> bool + Sync),
    ) -> Option<ManagedMachine> {
        self.take_idle_sibling_for_lineage(want_provider, &[], want, candidates_ok)
            .await
    }

    pub async fn take_idle_sibling_for_lineage(
        &self,
        want_provider: Option<&str>,
        cap_lineage: &[String],
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
        let all_machines = self.machines.lock().await.clone();
        let pick = all_machines
            .iter()
            .filter(|m| {
                m.provisioning_mode.is_worker()
                    && m.state == MachineState::Online
                    && want_provider.is_none_or(|p| m.provider == p)
                    && m.size == size
                    && m.image == image
                    && Utc::now() + chrono::Duration::minutes(10) < m.expires_at
                    && (m.owner_user_id.as_deref() == tenant || m.owner_user_id.is_none())
                    && m.owner_mission_id.as_deref().is_some_and(candidates_ok)
                    && !Self::node_busy(&m.node_id)
            })
            .min_by_key(|m| m.created_at)
            .cloned()?;
        // A handover re-charges the VM: it must pass the same budget and
        // concurrency checks as a fresh rent, or the caller falls back to
        // normal admission.
        let pools = self.budgets.lock().await.clone();
        let eff_chain = if !cap_lineage.is_empty() {
            cap_lineage.to_vec()
        } else {
            Self::fallback_cap_lineage(&pools, None, Some(requested_by))
        };
        let target_cap_pool =
            Self::resolve_covering_cap_pool(&pools, &eff_chain, &pick.provider, tenant);
        drop(pools);
        if pick.cap_pool_id != target_cap_pool {
            let others: Vec<ManagedMachine> = all_machines
                .into_iter()
                .filter(|x| x.id != pick.id)
                .collect();
            if self
                .check_concurrency_quota(
                    &others,
                    &pick.provider,
                    cap_lineage,
                    None,
                    Some(requested_by),
                    tenant,
                )
                .await
                .is_err()
            {
                return None;
            }
        }
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
                m.cap_pool_id = target_cap_pool;
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

#[derive(Debug, Clone, Default)]
struct SpawnExtras {
    gpu: Option<String>,
    arch: Option<String>,
    max_hourly_usd: Option<f64>,
    preferred_offer_id: Option<String>,
    min_cpu: Option<u32>,
    min_ram_gb: Option<u32>,
    allow_24h_commitment: bool,
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn cloud_bootstrap_script(
    core_url: &str,
    machine_id: &str,
    node_id: &str,
    enroll_token: &str,
    capacity: u32,
    job_memory: u64,
    provider: &str,
    size: &str,
    image: &str,
) -> String {
    let core_url = core_url.trim_end_matches('/');
    format!(
        r#"#!/usr/bin/env bash
set -euo pipefail
H=/var/lib/orb-node; B=/usr/local/bin; S=/usr/local/sbin; O=/home/user/.orb
P=$B:/usr/sbin:/usr/bin:/sbin:/bin
E="OPENCODE_TMPDIR=/tmp/opencode GIT_TERMINAL_PROMPT=0 DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_AUTOUPDATE=1 CODEX_DISABLE_UPDATE_CHECK=1 NO_UPDATE_NOTIFIER=1"
q() {{ "$@" >/dev/null 2>&1; }}
if q command -v apt-get; then
  n=0; for c in curl git python3 jq xz zstd runuser; do q command -v "$c" || n=1; done
  [ -d /run/systemd/system ] && [ ! -e /usr/lib/systemd/user/dbus.socket ] && [ ! -e /lib/systemd/user/dbus.socket ] && n=1 || true
  [ "$n" = 1 ] && export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -yqq curl ca-certificates git sudo python3 dbus-user-session jq xz-utils zstd util-linux
fi
q id -u user || useradd -m -s /bin/bash user || true
q id -u orbnode || useradd -r -m -d "$H" -s /bin/bash orbnode || true
for g in sudo adm admin wheel docker lxd; do q gpasswd -d orbnode "$g" || true; done
rm -f /etc/sudoers.d/orbnode
install -d -m 0755 "$B" "$S" /opt/sandboxed-tools
install -d -m 0750 -o orbnode -g orbnode "$H" "$H/work" "$H/work/caches"
install -d -m 0700 -o user -g user "$O" || mkdir -p -m 0700 "$O"
chmod 0750 /home/user 2>/dev/null || true
A=$O/auth; printf 'header = "Authorization: Bearer %s"\n' '{enroll_token}' >"$A"; chmod 0600 "$A"
trap 'rm -f "$A"' EXIT
U="{core_url}/api/managed-machines/bootstrap-binary/{machine_id}?binary="
orb_fetch() {{ curl -fsSL --retry 6 --retry-delay 3 -K "$A" "$U$1" -o "$2.t" && chmod "$3" "$2.t" && mv "$2.t" "$2"; }}
[ -x "$B/sandboxed-node" ] || orb_fetch sandboxed-node "$B/sandboxed-node" 0755
[ -x "$B/sandboxed-mcp" ] || orb_fetch sandboxed-mcp "$B/sandboxed-mcp" 0755
orb_fetch provision-script "$O/provision.sh" 0700
orb_fetch update-node-codex "$S/update-node-codex" 0755
orb_fetch update-node-harnesses "$S/update-node-harnesses" 0755
rm -f "$A"
for h in opencode claude codex; do [ -x "$B/$h" ] || python3 "$S/update-node-harnesses" --only "$h" --probe-user orbnode; done
[ -x "$B/grok" ] || python3 "$S/update-node-harnesses" --only grok --probe-user orbnode || true
cat >"$O/enroll.env" <<'EOF'
SANDBOXED_NODE_DIAL_CORE_URL={core_url}
SANDBOXED_NODE_MANAGED_ID={machine_id}
SANDBOXED_NODE_ENROLL_TOKEN={enroll_token}
SANDBOXED_NODE_ID={node_id}
SANDBOXED_NODE_CAPACITY={capacity}
SANDBOXED_NODE_JOB_MEMORY_BYTES={job_memory}
SANDBOXED_NODE_WORK_DIR=/var/lib/orb-node/work
SANDBOXED_NODE_LABELS=managed,trust=managed,provider={provider},size={size},image={image},lean
EOF
chmod 0600 "$O/enroll.env"
bash "$O/provision.sh" || true
rm -rf "$H/node.cred" "$H/work/managed-auth"
if q command -v systemctl && [ -d /run/systemd/system ]; then
  UID_N=$(id -u orbnode)
  cat >/etc/systemd/system/orb-node.service <<EOF
[Unit]
After=network-online.target systemd-logind.service
Wants=network-online.target
[Service]
User=orbnode
Group=orbnode
WorkingDirectory=$H
EnvironmentFile=$O/enroll.env
Environment=HOME=$H PATH=$P XDG_RUNTIME_DIR=/run/user/${{UID_N}} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${{UID_N}}/bus $E
NoNewPrivileges=true
ExecStartPre=+/bin/sh -c 'loginctl enable-linger orbnode; systemctl start user@${{UID_N}}.service || true; for _ in \$\$(seq 100); do [ -S /run/user/${{UID_N}}/bus ] && exit 0; sleep 0.2; done; echo user bus missing >&2; exit 1'
ExecStart=$B/sandboxed-node
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable orb-node.service && systemctl restart orb-node.service
else
  nohup bash -c "set -a; . $O/enroll.env; set +a; cd $H; while true; do runuser -u orbnode -- env HOME=$H PATH=$P $E $B/sandboxed-node || true; sleep 2; done" >"$H/orb-node.log" 2>&1 &
fi
"#
    )
}

/// Exit code of a provider exec result, when it reports one.
pub fn exec_exit_code(v: &Value) -> Option<i64> {
    ["exitCode", "exit_code", "code"]
        .iter()
        .find_map(|k| v.get(*k).and_then(Value::as_i64))
}

fn is_retryable_exec_error(err: &str) -> bool {
    let lower = err.to_ascii_lowercase();
    err.contains("HTTP 502")
        || err.contains("HTTP 503")
        || err.contains("HTTP 504")
        || lower.contains("sandbox_direct_failed")
        || lower.contains("sandbox_starting")
        || lower.contains("timed out")
        || lower.contains("timeout")
        || lower.contains("connection")
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
    let take_env = |keys: &[&str]| -> Option<String> {
        let val = keys.iter().find_map(|k| {
            std::env::var(k)
                .ok()
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
        });
        for k in keys {
            std::env::remove_var(k);
        }
        val
    };
    let boat_key = take_env(&["BOAT_API_KEY"]);
    let hetzner_key = take_env(&["HETZNER_CLOUD_APIKEY", "HCLOUD_TOKEN"]);
    let vastai_key = take_env(&["VASTAI_API_KEY", "VAST_API_KEY"]);
    let scaleway_key = take_env(&["SCALEWAY_SECRET_KEY", "SCW_SECRET_KEY"]);
    std::env::remove_var("SCALEWAY_KEY_ID");
    std::env::remove_var("SCW_ACCESS_KEY");

    let hetzner_loc = std::env::var("HETZNER_DEFAULT_LOCATION")
        .ok()
        .filter(|s| !s.trim().is_empty());
    let scaleway_zone = std::env::var("SCALEWAY_DEFAULT_ZONE")
        .ok()
        .filter(|s| !s.trim().is_empty());
    let scaleway_proj = std::env::var("SCALEWAY_PROJECT_ID")
        .or_else(|_| std::env::var("SCW_DEFAULT_PROJECT_ID"))
        .ok()
        .filter(|s| !s.trim().is_empty());

    let any_provider = boat_key.is_some()
        || hetzner_key.is_some()
        || vastai_key.is_some()
        || scaleway_key.is_some();
    let settings = ManagedSettings::from_env(any_provider);
    let manager = Arc::new(ManagedManager::new(settings, None, working_dir, core_port));
    if let Some(key) = boat_key {
        manager.register_base_credential("boat", "environment", key, None, None);
    }
    if let Some(key) = hetzner_key {
        manager.register_base_credential("hetzner", "environment", key, hetzner_loc, None);
    }
    if let Some(key) = vastai_key {
        manager.register_base_credential("vastai", "environment", key, None, None);
    }
    if let Some(key) = scaleway_key {
        manager.register_base_credential(
            "scaleway",
            "environment",
            key,
            scaleway_zone,
            scaleway_proj,
        );
    }
    manager.load().await;
    let _ = MANAGER.set(Arc::clone(&manager));
    manager.ensure_background_loops();
    manager
}

#[cfg(test)]
mod tests;
