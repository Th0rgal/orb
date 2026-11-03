//! Global and per-mission resource flow & subagent DAG endpoints.
//!
//! - `GET /api/resources/overview?range=30m|1h|6h|24h|7d`
//! - `GET /api/resources/missions/:id?horizon=6h|all`

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use axum::{
    extract::{Extension, Path, Query, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::auth::AuthUser;
use super::mission_store::sqlite_resources::{
    parse_rfc3339_unix_secs, pool_label_for_id, resolve_inference_pool, ComputeMinuteSample,
    ComputeRollupRow, ResourcesStoreOverview,
};
use super::routes::AppState;

/// Amortized reference hourly USD per vCPU when a host/static node has no provider bill.
const STATIC_VCPU_USD_PER_HOUR: f64 = 0.0045;
const LOCAL_HOST_VCPU_USD_PER_HOUR: f64 = 0.0035;
const SPARK_GPU_USD_PER_HOUR: f64 = 0.45;

pub fn protected_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/resources/overview", get(get_overview))
        .route("/api/resources/missions/:id", get(get_mission_resources))
}

/// Spawn the 60-second compute fleet sampler that records `compute_rollup_1m`
/// rows into each active user's SQLite mission store.
pub fn spawn_compute_sampler(state: Arc<AppState>) {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(60));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            if super::routes::is_shutdown_initiated() {
                break;
            }
            sample_all_loaded_stores(&state).await;
        }
    });
}

async fn sample_all_loaded_stores(state: &AppState) {
    let sessions = state.control.all_sessions_with_users().await;
    if sessions.is_empty() {
        return;
    }
    let now_min = Utc::now().timestamp().div_euclid(60);
    for (user_id, cs) in sessions {
        let Ok(overview) = cs.mission_store.query_resources_overview(now_min - 2).await else {
            continue;
        };
        let samples = build_live_compute_samples(state, &user_id, now_min, &overview).await;
        if !samples.is_empty() {
            let _ = cs.mission_store.record_compute_samples(&samples).await;
        }
    }
}

fn machine_class_for_managed(provider: &str, size: &str) -> (String, String) {
    let p = provider.trim().to_ascii_lowercase();
    let s = size.trim().to_ascii_lowercase();
    let prov_title = match p.as_str() {
        "boat" => "Boat",
        "hetzner" => "Hetzner",
        "vast" | "vastai" | "vast.ai" => "Vast.ai",
        "scaleway" => "Scaleway",
        other => {
            if other.is_empty() {
                "Cloud"
            } else {
                other
            }
        }
    };
    let clean_size = if s.is_empty() { "vm" } else { s.as_str() };
    (
        format!("{p}:{clean_size}"),
        format!("{prov_title} · {clean_size}"),
    )
}

pub fn machine_class_label(class_id: &str) -> String {
    match class_id {
        "static:fleet" => "Static fleet".to_string(),
        "core:host" => "Local host".to_string(),
        "spark:gpu" => "DGX Spark".to_string(),
        other => {
            if let Some((p, s)) = other.split_once(':') {
                let (_, lbl) = machine_class_for_managed(p, s);
                lbl
            } else {
                other.to_string()
            }
        }
    }
}

async fn build_live_compute_samples(
    state: &AppState,
    user_id: &str,
    bucket_unix_min: i64,
    store_snap: &ResourcesStoreOverview,
) -> Vec<ComputeMinuteSample> {
    let mut out = Vec::new();
    let mut managed_node_ids: HashSet<String> = HashSet::new();

    // Map node_id -> active mission_ids currently running on that node
    let mut runs_by_node: HashMap<String, Vec<(String, String)>> = HashMap::new();
    let mut local_runs: Vec<(String, String)> = Vec::new();
    for ar in &store_snap.active_runs {
        let node = ar
            .placement_node_id
            .as_deref()
            .or(ar.remote_node_id.as_deref())
            .or_else(|| {
                ar.scope_unit.as_deref().and_then(|s| {
                    s.strip_prefix("remote-node:")
                        .or_else(|| s.strip_prefix("remote:"))
                })
            })
            .map(str::trim)
            .filter(|s| !s.is_empty() && *s != "core" && *s != "local");
        if let Some(n) = node {
            runs_by_node
                .entry(n.to_string())
                .or_default()
                .push((ar.mission_id.clone(), ar.root_mission_id.clone()));
        } else {
            local_runs.push((ar.mission_id.clone(), ar.root_mission_id.clone()));
        }
    }

    // 1. Managed machines (Boat, Hetzner, Vast, Scaleway)
    if let Some(manager) = state.managed() {
        let view = manager.list(1).await;
        for m in view.machines {
            if !m.state.is_live() {
                continue;
            }
            if !m.provisioning_mode.is_worker() && m.owner_user_id.as_deref() != Some(user_id) {
                continue;
            }
            managed_node_ids.insert(m.node_id.clone());
            let (class_id, _) = machine_class_for_managed(&m.provider, &m.size);
            let total_vcpu = (m.cpu.max(1)) as f64;
            let total_ram = m.ram_gb as f64;
            // Millicents per minute from usd_per_hour (`1 USD = 100_000 millicents`)
            let mc_per_min = ((m.usd_per_hour * 100_000.0) / 60.0).round() as i64;

            if let Some(active_list) = runs_by_node.get(&m.node_id) {
                let n = active_list.len().max(1) as f64;
                for (mid, root_id) in active_list {
                    out.push(ComputeMinuteSample {
                        bucket_unix_min,
                        machine_class: class_id.clone(),
                        node_id: m.node_id.clone(),
                        root_mission_id: root_id.clone(),
                        mission_id: mid.clone(),
                        state: "active".to_string(),
                        vcpu_allocated: total_vcpu / n,
                        vcpu_busy: total_vcpu / n,
                        ram_gb_allocated: total_ram / n,
                        cost_millicents: (mc_per_min as f64 / n).round() as i64,
                    });
                }
            } else if let Some(owner_mid) = m
                .owner_mission_id
                .as_deref()
                .or(m.requested_by_mission_id.as_deref())
                .filter(|s| !s.is_empty())
            {
                let root_id = store_snap
                    .mission_roots
                    .get(owner_mid)
                    .cloned()
                    .unwrap_or_else(|| owner_mid.to_string());
                let sample_state = match m.state {
                    crate::managed::MachineState::Provisioning
                    | crate::managed::MachineState::Enrolling => "provisioning",
                    _ => "idle_leased",
                };
                out.push(ComputeMinuteSample {
                    bucket_unix_min,
                    machine_class: class_id,
                    node_id: m.node_id.clone(),
                    root_mission_id: root_id,
                    mission_id: owner_mid.to_string(),
                    state: sample_state.to_string(),
                    vcpu_allocated: total_vcpu,
                    vcpu_busy: 0.0,
                    ram_gb_allocated: total_ram,
                    cost_millicents: mc_per_min,
                });
            } else {
                out.push(ComputeMinuteSample {
                    bucket_unix_min,
                    machine_class: class_id,
                    node_id: m.node_id.clone(),
                    root_mission_id: String::new(),
                    mission_id: String::new(),
                    state: "idle_leased".to_string(),
                    vcpu_allocated: total_vcpu,
                    vcpu_busy: 0.0,
                    ram_gb_allocated: total_ram,
                    cost_millicents: mc_per_min,
                });
            }
        }
    }

    // 2. Static remote nodes
    for node_cfg in &state.config.remote_nodes.nodes {
        if managed_node_ids.contains(&node_cfg.id) {
            continue;
        }
        let cached = state.fleet.get(&node_cfg.id);
        let view = crate::remote_node::RemoteNodeView::from_cache(node_cfg, cached.as_ref());
        let cpu_total = view.cpu_total.unwrap_or(8).max(1) as f64;
        let cap_total = view.capacity_total.unwrap_or(4).max(1) as f64;
        let vcpu_per_slot = (cpu_total / cap_total).max(1.0);
        let class_id = if node_cfg.id.contains("spark") {
            "spark:gpu".to_string()
        } else {
            "static:fleet".to_string()
        };
        let rate_usd_h = if class_id == "spark:gpu" {
            SPARK_GPU_USD_PER_HOUR / cpu_total
        } else {
            STATIC_VCPU_USD_PER_HOUR
        };

        if let Some(active_list) = runs_by_node.get(&node_cfg.id) {
            let per_run_vcpu = (cpu_total / active_list.len() as f64).min(vcpu_per_slot.max(2.0));
            let mc_per_run = ((per_run_vcpu * rate_usd_h * 100_000.0) / 60.0).round() as i64;
            for (mid, root_id) in active_list {
                out.push(ComputeMinuteSample {
                    bucket_unix_min,
                    machine_class: class_id.clone(),
                    node_id: node_cfg.id.clone(),
                    root_mission_id: root_id.clone(),
                    mission_id: mid.clone(),
                    state: "active".to_string(),
                    vcpu_allocated: per_run_vcpu,
                    vcpu_busy: per_run_vcpu,
                    ram_gb_allocated: 0.0,
                    cost_millicents: mc_per_run,
                });
            }
        }
    }

    // 3. Local host (`core:host`) active mission runs
    if !local_runs.is_empty() {
        let host_metrics = super::monitoring::latest_system_metrics().await;
        let host_cores = host_metrics
            .as_ref()
            .map(|m| m.cpu_cores.len().max(1) as f64)
            .unwrap_or_else(|| {
                std::thread::available_parallelism()
                    .map(|n| n.get() as f64)
                    .unwrap_or(8.0)
            });
        let cpu_util = host_metrics
            .as_ref()
            .map(|m| (m.cpu_percent as f64 / 100.0).clamp(0.08, 1.0))
            .unwrap_or(0.25);
        let active_vcpu_total = (host_cores * cpu_util).max(local_runs.len() as f64);
        let per_run = (active_vcpu_total / local_runs.len() as f64).min(host_cores);
        let mc_per_run =
            ((per_run * LOCAL_HOST_VCPU_USD_PER_HOUR * 100_000.0) / 60.0).round() as i64;
        for (mid, root_id) in &local_runs {
            out.push(ComputeMinuteSample {
                bucket_unix_min,
                machine_class: "core:host".to_string(),
                node_id: "core".to_string(),
                root_mission_id: root_id.clone(),
                mission_id: mid.clone(),
                state: "active".to_string(),
                vcpu_allocated: per_run,
                vcpu_busy: per_run,
                ram_gb_allocated: 0.0,
                cost_millicents: mc_per_run,
            });
        }
    }

    out
}

#[derive(Debug, Clone, Copy)]
struct RangeSpec {
    id: &'static str,
    minutes: i64,
    step_minutes: i64,
}

fn parse_range(raw: Option<&str>) -> Result<RangeSpec, String> {
    match raw.map(str::trim).filter(|s| !s.is_empty()).unwrap_or("6h") {
        "30m" => Ok(RangeSpec {
            id: "30m",
            minutes: 30,
            step_minutes: 1,
        }),
        "1h" => Ok(RangeSpec {
            id: "1h",
            minutes: 60,
            step_minutes: 1,
        }),
        "6h" => Ok(RangeSpec {
            id: "6h",
            minutes: 360,
            step_minutes: 5,
        }),
        "24h" => Ok(RangeSpec {
            id: "24h",
            minutes: 1_440,
            step_minutes: 20,
        }),
        "7d" => Ok(RangeSpec {
            id: "7d",
            minutes: 10_080,
            step_minutes: 120,
        }),
        other => Err(format!(
            "Invalid range {other:?}: expected 30m, 1h, 6h, 24h, or 7d"
        )),
    }
}

#[derive(Debug, Deserialize)]
pub struct OverviewQuery {
    pub range: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ResourcesOverviewResponse {
    pub as_of: String,
    pub range: String,
    pub bucket_seconds: i64,
    pub timestamps_ms: Vec<i64>,
    pub compute: ComputeOverview,
    pub inference: InferenceOverview,
    pub missions: Vec<MissionResourceSummary>,
    pub links: Vec<ResourceFlowLink>,
}

#[derive(Debug, Serialize)]
pub struct ComputeOverview {
    pub total_vcpu: f64,
    pub active_vcpu: f64,
    pub idle_leased_vcpu: f64,
    pub hourly_burn_usd: f64,
    pub sources: Vec<ComputeSourceSummary>,
}

#[derive(Debug, Serialize)]
pub struct ComputeSourceSummary {
    pub id: String,
    pub label: String,
    pub sublabel: String,
    pub total_vcpu: f64,
    pub active_vcpu: f64,
    pub idle_leased_vcpu: f64,
    pub est_usd_per_h: f64,
    pub health: String,
    pub series_vcpu: Vec<f64>,
    pub series_usd_per_h: Vec<f64>,
}

#[derive(Debug, Serialize)]
pub struct InferenceOverview {
    pub current_b_tok_per_h: f64,
    pub est_usd_per_h: f64,
    pub window_total_tokens: u64,
    pub window_est_usd: f64,
    pub throttled_429_count: u64,
    pub pools: Vec<InferencePoolSummary>,
}

#[derive(Debug, Serialize)]
pub struct InferencePoolSummary {
    pub id: String,
    pub label: String,
    pub sublabel: String,
    pub provider: String,
    pub quota_pct_remaining: Option<f64>,
    pub reset_at: Option<String>,
    pub current_b_tok_per_h: f64,
    pub est_usd_per_h: f64,
    pub health: String,
    pub series_b_tok_per_h: Vec<f64>,
    pub series_usd_per_h: Vec<f64>,
}

#[derive(Debug, Serialize)]
pub struct MissionResourceSummary {
    pub id: String,
    pub title: String,
    pub project: Option<String>,
    pub status: String,
    pub stall_kind: Option<String>,
    pub subagent_running: u32,
    pub subagent_total: u32,
    pub vcpu: f64,
    pub idle_vcpu: f64,
    pub compute_usd_per_h: f64,
    pub b_tok_per_h: f64,
    pub inference_usd_per_h: f64,
    pub eta_remaining_secs: Option<i64>,
    pub series_vcpu: Vec<f64>,
    pub series_compute_usd_per_h: Vec<f64>,
    pub series_b_tok_per_h: Vec<f64>,
    pub series_inference_usd_per_h: Vec<f64>,
}

#[derive(Debug, Serialize)]
pub struct ResourceFlowLink {
    pub kind: String,
    pub source_id: String,
    pub mission_id: String,
    pub value: f64,
    pub est_usd_per_h: f64,
    pub degraded: bool,
}

async fn extract_pool_quotas(state: &AppState) -> HashMap<String, (Option<f64>, Option<String>)> {
    let mut out: HashMap<String, (Option<f64>, Option<String>)> = HashMap::new();
    let providers = state.ai_providers.list().await;
    let cache = state.provider_usage_cache.snapshot().await;

    let mut update_min = |pool_id: &str, rem_pct: Option<f64>, reset: Option<String>| {
        let Some(pct) = rem_pct else { return };
        let clamped = pct.clamp(0.0, 100.0);
        match out.get(pool_id) {
            Some((Some(existing), _)) if *existing <= clamped => {}
            _ => {
                out.insert(pool_id.to_string(), (Some(clamped), reset));
            }
        }
    };

    for p in &providers {
        if !p.enabled {
            continue;
        }
        let key_uuid = p.id.to_string();
        let prov_str = p.provider_type.id();
        let Some(entry) = cache.get(&key_uuid).or_else(|| cache.get(prov_str)) else {
            continue;
        };
        let v = &entry.value;
        if prov_str == "antigravity" {
            if let Some(arr) = v.get("antigravity_windows").and_then(|w| w.as_array()) {
                for w in arr {
                    let lbl = w
                        .get("label")
                        .and_then(|l| l.as_str())
                        .unwrap_or("")
                        .to_ascii_lowercase();
                    let used = w
                        .get("used_percent")
                        .and_then(|u| u.as_f64())
                        .or_else(|| w.get("reset_at").map(|_| 100.0));
                    let reset = w
                        .get("reset_at")
                        .and_then(|r| r.as_i64())
                        .and_then(|ts| chrono::DateTime::<Utc>::from_timestamp(ts, 0))
                        .map(|dt| dt.to_rfc3339());
                    let pool = if lbl.contains("claude") {
                        "antigravity:claude"
                    } else {
                        "antigravity:gemini"
                    };
                    update_min(pool, used.map(|u| 100.0 - u), reset);
                }
            }
            continue;
        }

        let used_pct = v
            .get("unified_5h_utilization")
            .and_then(|x| x.as_f64())
            .map(|u| u * 100.0)
            .or_else(|| v.get("codex_primary_used_percent").and_then(|x| x.as_f64()))
            .or_else(|| v.get("xai_credit_used_percent").and_then(|x| x.as_f64()))
            .or_else(|| v.get("kimi_5h_used_percent").and_then(|x| x.as_f64()))
            .or_else(|| v.get("zai_5h_used_percent").and_then(|x| x.as_f64()))
            .or_else(|| v.get("muse_5h_used_percent").and_then(|x| x.as_f64()))
            .or_else(|| {
                v.get("mistral_monthly_used_percent")
                    .and_then(|x| x.as_f64())
            })
            .or_else(|| {
                v.get("minimax_interval_remaining_percent")
                    .and_then(|x| x.as_f64())
                    .map(|rem| 100.0 - rem)
            });
        let (pool_id, _) = resolve_inference_pool(Some(prov_str), None, "");
        update_min(&pool_id, used_pct.map(|u| 100.0 - u), None);
    }

    out
}

async fn get_overview(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Query(query): Query<OverviewQuery>,
) -> Result<Json<ResourcesOverviewResponse>, (StatusCode, String)> {
    let spec = parse_range(query.range.as_deref()).map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    let now = Utc::now();
    let now_min = now.timestamp().div_euclid(60);
    let num_buckets = (spec.minutes / spec.step_minutes).max(2) as usize;
    let first_bucket_min = now_min - (num_buckets as i64 - 1) * spec.step_minutes;
    let bucket_seconds = spec.step_minutes * 60;

    let control_state = state.control.get_or_spawn(&user).await;
    let mut snap = control_state
        .mission_store
        .query_resources_overview(first_bucket_min)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    // Synthesize and merge live current-minute compute attribution so freshly booted servers
    // and newly spawned VMs appear immediately without waiting for the 60s background tick.
    let live_samples = build_live_compute_samples(&state, &user.id, now_min, &snap).await;
    let has_current_min = snap
        .compute_rows
        .iter()
        .any(|r| r.bucket_unix_min == now_min);
    if !has_current_min && !live_samples.is_empty() {
        let _ = control_state
            .mission_store
            .record_compute_samples(&live_samples)
            .await;
        for s in &live_samples {
            snap.compute_rows.push(ComputeRollupRow {
                bucket_unix_min: s.bucket_unix_min,
                machine_class: s.machine_class.clone(),
                node_id: s.node_id.clone(),
                root_mission_id: s.root_mission_id.clone(),
                state: s.state.clone(),
                vcpu_allocated: s.vcpu_allocated,
                cost_millicents: s.cost_millicents.max(0) as u64,
            });
        }
    }

    let timestamps_ms: Vec<i64> = (0..num_buckets)
        .map(|i| (first_bucket_min + (i as i64) * spec.step_minutes) * 60_000)
        .collect();

    let bucket_idx_of = |bmin: i64| -> Option<usize> {
        if bmin < first_bucket_min {
            return None;
        }
        let idx = ((bmin - first_bucket_min) / spec.step_minutes) as usize;
        Some(idx.min(num_buckets - 1))
    };

    // Fleet capacity inventory (live right now) for ComputeSourceSummary totals & sublabels
    let mut live_class_capacity: BTreeMap<String, (f64, usize, f64)> = BTreeMap::new(); // class -> (total_vcpu, count, usd_h)
    {
        let mut managed_ids = HashSet::new();
        if let Some(mgr) = state.managed() {
            let mview = mgr.list(1).await;
            for m in mview.machines {
                if !m.state.is_live() {
                    continue;
                }
                if !m.provisioning_mode.is_worker()
                    && m.owner_user_id.as_deref() != Some(user.id.as_str())
                {
                    continue;
                }
                managed_ids.insert(m.node_id.clone());
                let (cid, _) = machine_class_for_managed(&m.provider, &m.size);
                let entry = live_class_capacity.entry(cid).or_insert((0.0, 0, 0.0));
                entry.0 += m.cpu.max(1) as f64;
                entry.1 += 1;
                entry.2 += m.usd_per_hour;
            }
        }
        for ncfg in &state.config.remote_nodes.nodes {
            if managed_ids.contains(&ncfg.id) {
                continue;
            }
            let cached = state.fleet.get(&ncfg.id);
            let rview = crate::remote_node::RemoteNodeView::from_cache(ncfg, cached.as_ref());
            let c = rview.cpu_total.unwrap_or(8).max(1) as f64;
            let cid = if ncfg.id.contains("spark") {
                "spark:gpu".to_string()
            } else {
                "static:fleet".to_string()
            };
            let usd = if cid == "spark:gpu" {
                SPARK_GPU_USD_PER_HOUR
            } else {
                c * STATIC_VCPU_USD_PER_HOUR
            };
            let entry = live_class_capacity.entry(cid).or_insert((0.0, 0, 0.0));
            entry.0 += c;
            entry.1 += 1;
            entry.2 += usd;
        }
        let host_cores = super::monitoring::latest_system_metrics()
            .await
            .map(|m| m.cpu_cores.len().max(1) as f64)
            .unwrap_or_else(|| {
                std::thread::available_parallelism()
                    .map(|n| n.get() as f64)
                    .unwrap_or(8.0)
            });
        live_class_capacity.insert(
            "core:host".to_string(),
            (host_cores, 1, host_cores * LOCAL_HOST_VCPU_USD_PER_HOUR),
        );
    }

    // Aggregate compute series per class, per mission, and per (class, mission)
    let step_f = spec.step_minutes as f64;
    let mut class_series_vcpu: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut class_series_usd: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut class_idle_vcpu_sum: HashMap<String, f64> = HashMap::new();

    let mut mission_series_vcpu: HashMap<String, Vec<f64>> = HashMap::new();
    let mut mission_series_comp_usd: HashMap<String, Vec<f64>> = HashMap::new();
    let mut mission_idle_vcpu_sum: HashMap<String, f64> = HashMap::new();

    // (class_id, root_mission_id) -> (sum_vcpu_min, sum_cost_millicents, any_idle)
    let mut comp_links_acc: BTreeMap<(String, String), (f64, u64, bool)> = BTreeMap::new();

    for row in &snap.compute_rows {
        let Some(bi) = bucket_idx_of(row.bucket_unix_min) else {
            continue;
        };
        let vcpu_step = row.vcpu_allocated / step_f;
        // millicents in bucket -> USD/h: (mc / 100_000) * (3600 / bucket_seconds)
        let usd_h_step =
            (row.cost_millicents as f64 / 100_000.0) * (3600.0 / bucket_seconds as f64);

        class_series_vcpu
            .entry(row.machine_class.clone())
            .or_insert_with(|| vec![0.0; num_buckets])[bi] += vcpu_step;
        class_series_usd
            .entry(row.machine_class.clone())
            .or_insert_with(|| vec![0.0; num_buckets])[bi] += usd_h_step;

        if row.state == "idle_leased" {
            *class_idle_vcpu_sum
                .entry(row.machine_class.clone())
                .or_insert(0.0) += row.vcpu_allocated;
        }

        if !row.root_mission_id.is_empty() {
            mission_series_vcpu
                .entry(row.root_mission_id.clone())
                .or_insert_with(|| vec![0.0; num_buckets])[bi] += vcpu_step;
            mission_series_comp_usd
                .entry(row.root_mission_id.clone())
                .or_insert_with(|| vec![0.0; num_buckets])[bi] += usd_h_step;
            if row.state == "idle_leased" {
                *mission_idle_vcpu_sum
                    .entry(row.root_mission_id.clone())
                    .or_insert(0.0) += row.vcpu_allocated;
            }
            let entry = comp_links_acc
                .entry((row.machine_class.clone(), row.root_mission_id.clone()))
                .or_insert((0.0, 0, false));
            entry.0 += row.vcpu_allocated;
            entry.1 += row.cost_millicents;
            if row.state == "idle_leased" {
                entry.2 = true;
            }
        }
    }

    // Observed minutes denominator for compute rates (so freshly sampled DBs don't divide 1 live minute by 360)
    let observed_comp_mins = snap
        .compute_rows
        .iter()
        .map(|r| r.bucket_unix_min)
        .collect::<HashSet<_>>()
        .len()
        .max(1) as f64;

    // Aggregate inference series per pool, per mission, and per (pool, mission)
    let mut pool_series_btok: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut pool_series_usd: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut pool_429: HashMap<String, u64> = HashMap::new();
    let mut window_total_tokens: u64 = 0;
    let mut window_est_mc: u64 = 0;
    let mut total_429: u64 = 0;

    let mut mission_series_btok: HashMap<String, Vec<f64>> = HashMap::new();
    let mut mission_series_inf_usd: HashMap<String, Vec<f64>> = HashMap::new();

    // (pool_id, target_mission_or_external) -> (sum_tokens, sum_est_mc, sum_429)
    let mut inf_links_acc: BTreeMap<(String, String), (u64, u64, u64)> = BTreeMap::new();
    const EXTERNAL_TRAFFIC_ID: &str = "__external__";

    for row in &snap.usage_rows {
        let Some(bi) = bucket_idx_of(row.bucket_unix_min) else {
            continue;
        };
        window_total_tokens += row.total_tokens;
        window_est_mc += row.est_cost_millicents;
        total_429 += row.rate_limit_429_count;
        *pool_429.entry(row.pool_id.clone()).or_insert(0) += row.rate_limit_429_count;

        let btok_h = (row.total_tokens as f64 / 1e9) * (3600.0 / bucket_seconds as f64);
        let usd_h = (row.est_cost_millicents as f64 / 100_000.0) * (3600.0 / bucket_seconds as f64);

        pool_series_btok
            .entry(row.pool_id.clone())
            .or_insert_with(|| vec![0.0; num_buckets])[bi] += btok_h;
        pool_series_usd
            .entry(row.pool_id.clone())
            .or_insert_with(|| vec![0.0; num_buckets])[bi] += usd_h;

        let target_id = if row.root_mission_id.is_empty() {
            EXTERNAL_TRAFFIC_ID.to_string()
        } else {
            row.root_mission_id.clone()
        };

        if row.total_tokens > 0 || row.est_cost_millicents > 0 {
            mission_series_btok
                .entry(target_id.clone())
                .or_insert_with(|| vec![0.0; num_buckets])[bi] += btok_h;
            mission_series_inf_usd
                .entry(target_id.clone())
                .or_insert_with(|| vec![0.0; num_buckets])[bi] += usd_h;

            let l = inf_links_acc
                .entry((row.pool_id.clone(), target_id))
                .or_insert((0, 0, 0));
            l.0 += row.total_tokens;
            l.1 += row.est_cost_millicents;
            l.2 += row.rate_limit_429_count;
        }
    }

    let window_hours = (spec.minutes as f64 / 60.0).max(0.5);

    // Build ComputeSourceSummary list
    let mut all_classes: BTreeMap<String, ()> = BTreeMap::new();
    for k in live_class_capacity.keys() {
        all_classes.insert(k.clone(), ());
    }
    for k in class_series_vcpu.keys() {
        all_classes.insert(k.clone(), ());
    }

    let mut compute_sources = Vec::new();
    let mut fleet_total_vcpu = 0.0;
    let mut fleet_active_vcpu = 0.0;
    let mut fleet_idle_vcpu = 0.0;
    let mut fleet_burn_usd = 0.0;

    for class_id in all_classes.keys() {
        let (cap_vcpu, node_count, live_usd_h) = live_class_capacity
            .get(class_id)
            .copied()
            .unwrap_or((0.0, 0, 0.0));
        let sv = class_series_vcpu
            .remove(class_id)
            .unwrap_or_else(|| vec![0.0; num_buckets]);
        let su = class_series_usd
            .remove(class_id)
            .unwrap_or_else(|| vec![0.0; num_buckets]);

        let attributed_vcpu: f64 = comp_links_acc
            .iter()
            .filter(|((cid, _), _)| cid == class_id)
            .map(|(_, (v, _, _))| *v / observed_comp_mins)
            .sum();
        let attributed_usd_h: f64 = comp_links_acc
            .iter()
            .filter(|((cid, _), _)| cid == class_id)
            .map(|(_, (_, mc, _))| (*mc as f64 / 100_000.0) * (60.0 / observed_comp_mins))
            .sum();
        let idle_vcpu =
            class_idle_vcpu_sum.get(class_id).copied().unwrap_or(0.0) / observed_comp_mins;

        let total_vcpu = cap_vcpu.max(attributed_vcpu);
        if total_vcpu <= 0.0 && attributed_vcpu <= 0.0 {
            continue;
        }
        let active_vcpu = (attributed_vcpu - idle_vcpu).max(0.0);
        let est_usd_h = if attributed_usd_h > 0.0 {
            attributed_usd_h
        } else {
            live_usd_h
        };

        fleet_total_vcpu += total_vcpu;
        fleet_active_vcpu += active_vcpu;
        fleet_idle_vcpu += idle_vcpu;
        fleet_burn_usd += est_usd_h;

        let unit_word = if class_id == "core:host" {
            "local".to_string()
        } else if class_id.starts_with("static:") {
            format!(
                "{node_count} host{}",
                if node_count == 1 { "" } else { "s" }
            )
        } else {
            format!("{node_count} VM{}", if node_count == 1 { "" } else { "s" })
        };
        let health = if idle_vcpu > active_vcpu && idle_vcpu >= 4.0 {
            "warn"
        } else {
            "ok"
        };

        compute_sources.push(ComputeSourceSummary {
            id: class_id.clone(),
            label: machine_class_label(class_id),
            sublabel: unit_word,
            total_vcpu,
            active_vcpu: attributed_vcpu,
            idle_leased_vcpu: idle_vcpu,
            est_usd_per_h: est_usd_h,
            health: health.to_string(),
            series_vcpu: sv,
            series_usd_per_h: su,
        });
    }
    compute_sources.sort_by(|a, b| {
        b.active_vcpu
            .partial_cmp(&a.active_vcpu)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                b.total_vcpu
                    .partial_cmp(&a.total_vcpu)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    });

    // Build InferencePoolSummary list (combining active pools + enabled configured providers)
    let quotas = extract_pool_quotas(&state).await;
    let mut all_pools: BTreeMap<String, ()> = BTreeMap::new();
    for k in pool_series_btok.keys() {
        all_pools.insert(k.clone(), ());
    }
    for p in state.ai_providers.list().await {
        if p.enabled {
            let (pid, _) = resolve_inference_pool(Some(p.provider_type.id()), None, "");
            all_pools.insert(pid, ());
        }
    }

    let mut pools = Vec::new();
    let mut total_btok_h = 0.0;
    let mut total_inf_usd_h = 0.0;

    for pool_id in all_pools.keys() {
        let sb = pool_series_btok
            .remove(pool_id)
            .unwrap_or_else(|| vec![0.0; num_buckets]);
        let su = pool_series_usd
            .remove(pool_id)
            .unwrap_or_else(|| vec![0.0; num_buckets]);

        let pool_tokens: u64 = inf_links_acc
            .iter()
            .filter(|((pid, _), _)| pid == pool_id)
            .map(|(_, (t, _, _))| *t)
            .sum();
        let pool_mc: u64 = inf_links_acc
            .iter()
            .filter(|((pid, _), _)| pid == pool_id)
            .map(|(_, (_, mc, _))| *mc)
            .sum();

        let btok_h = (pool_tokens as f64 / 1e9) / window_hours;
        let usd_h = (pool_mc as f64 / 100_000.0) / window_hours;
        let (quota_rem, reset_at) = quotas.get(pool_id).cloned().unwrap_or((None, None));
        let p429 = pool_429.get(pool_id).copied().unwrap_or(0);

        if pool_tokens == 0 && quota_rem.is_none() && p429 == 0 && all_pools.len() > 4 {
            continue;
        }

        total_btok_h += btok_h;
        total_inf_usd_h += usd_h;

        let sublabel = match quota_rem {
            Some(pct) => format!("{}% left", pct.round() as i64),
            None if p429 > 0 => format!("{p429}× 429"),
            None => "metered".to_string(),
        };
        let health = if quota_rem.is_some_and(|q| q <= 10.0) || p429 >= 5 {
            "bad"
        } else if quota_rem.is_some_and(|q| q <= 25.0) || p429 > 0 {
            "warn"
        } else {
            "ok"
        };

        pools.push(InferencePoolSummary {
            id: pool_id.clone(),
            label: pool_label_for_id(pool_id),
            sublabel,
            provider: pool_id.split(':').next().unwrap_or(pool_id).to_string(),
            quota_pct_remaining: quota_rem,
            reset_at,
            current_b_tok_per_h: btok_h,
            est_usd_per_h: usd_h,
            health: health.to_string(),
            series_b_tok_per_h: sb,
            series_usd_per_h: su,
        });
    }
    pools.sort_by(|a, b| {
        b.current_b_tok_per_h
            .partial_cmp(&a.current_b_tok_per_h)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                b.est_usd_per_h
                    .partial_cmp(&a.est_usd_per_h)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    });

    // Build links & MissionResourceSummary list
    let mut links = Vec::new();
    let mut mission_comp_totals: HashMap<String, (f64, f64)> = HashMap::new(); // mid -> (vcpu, usd_h)
    let mut mission_inf_totals: HashMap<String, (f64, f64)> = HashMap::new(); // mid -> (btok_h, usd_h)

    for ((class_id, mid), (sum_vcpu, sum_mc, any_idle)) in &comp_links_acc {
        let vcpu = *sum_vcpu / observed_comp_mins;
        let usd_h = (*sum_mc as f64 / 100_000.0) * (60.0 / observed_comp_mins);
        if vcpu <= 0.001 && usd_h <= 0.0001 {
            continue;
        }
        let m = mission_comp_totals.entry(mid.clone()).or_insert((0.0, 0.0));
        m.0 += vcpu;
        m.1 += usd_h;
        links.push(ResourceFlowLink {
            kind: "compute".to_string(),
            source_id: class_id.clone(),
            mission_id: mid.clone(),
            value: vcpu,
            est_usd_per_h: usd_h,
            degraded: *any_idle,
        });
    }

    for ((pool_id, mid), (sum_tok, sum_mc, sum_429)) in &inf_links_acc {
        let btok_h = (*sum_tok as f64 / 1e9) / window_hours;
        let usd_h = (*sum_mc as f64 / 100_000.0) / window_hours;
        if btok_h <= 0.0 && usd_h <= 0.0 {
            continue;
        }
        let m = mission_inf_totals.entry(mid.clone()).or_insert((0.0, 0.0));
        m.0 += btok_h;
        m.1 += usd_h;
        links.push(ResourceFlowLink {
            kind: "inference".to_string(),
            source_id: pool_id.clone(),
            mission_id: mid.clone(),
            value: btok_h,
            est_usd_per_h: usd_h,
            degraded: *sum_429 > 0,
        });
    }

    let mut missions = Vec::new();
    for rm in snap.root_missions {
        let (vcpu, comp_usd_h) = mission_comp_totals
            .get(&rm.id)
            .copied()
            .unwrap_or((0.0, 0.0));
        let (btok_h, inf_usd_h) = mission_inf_totals
            .get(&rm.id)
            .copied()
            .unwrap_or((0.0, 0.0));
        let is_live = matches!(
            rm.status.as_str(),
            "active" | "pending" | "waiting_background" | "blocked"
        );
        if vcpu <= 0.0 && btok_h <= 0.0 && inf_usd_h <= 0.0 && !is_live {
            continue;
        }
        let idle_vcpu =
            mission_idle_vcpu_sum.get(&rm.id).copied().unwrap_or(0.0) / observed_comp_mins;
        missions.push(MissionResourceSummary {
            vcpu,
            idle_vcpu,
            compute_usd_per_h: comp_usd_h,
            b_tok_per_h: btok_h,
            inference_usd_per_h: inf_usd_h,
            series_vcpu: mission_series_vcpu
                .remove(&rm.id)
                .unwrap_or_else(|| vec![0.0; num_buckets]),
            series_compute_usd_per_h: mission_series_comp_usd
                .remove(&rm.id)
                .unwrap_or_else(|| vec![0.0; num_buckets]),
            series_b_tok_per_h: mission_series_btok
                .remove(&rm.id)
                .unwrap_or_else(|| vec![0.0; num_buckets]),
            series_inference_usd_per_h: mission_series_inf_usd
                .remove(&rm.id)
                .unwrap_or_else(|| vec![0.0; num_buckets]),
            id: rm.id,
            title: rm.title,
            project: rm.project,
            status: rm.status,
            stall_kind: rm.stall_kind,
            subagent_running: rm.subagent_running,
            subagent_total: rm.subagent_total,
            eta_remaining_secs: rm.eta_remaining_secs,
        });
    }

    // Include external /v1 API traffic node if non-mission requests consumed tokens
    if let Some((btok_h, inf_usd_h)) = mission_inf_totals.get(EXTERNAL_TRAFFIC_ID).copied() {
        if btok_h > 0.0 || inf_usd_h > 0.0 {
            missions.push(MissionResourceSummary {
                id: EXTERNAL_TRAFFIC_ID.to_string(),
                title: "API & external tools".to_string(),
                project: None,
                status: "active".to_string(),
                stall_kind: None,
                subagent_running: 0,
                subagent_total: 0,
                vcpu: 0.0,
                idle_vcpu: 0.0,
                compute_usd_per_h: 0.0,
                b_tok_per_h: btok_h,
                inference_usd_per_h: inf_usd_h,
                eta_remaining_secs: None,
                series_vcpu: vec![0.0; num_buckets],
                series_compute_usd_per_h: vec![0.0; num_buckets],
                series_b_tok_per_h: mission_series_btok
                    .remove(EXTERNAL_TRAFFIC_ID)
                    .unwrap_or_else(|| vec![0.0; num_buckets]),
                series_inference_usd_per_h: mission_series_inf_usd
                    .remove(EXTERNAL_TRAFFIC_ID)
                    .unwrap_or_else(|| vec![0.0; num_buckets]),
            });
        }
    }

    missions.sort_by(|a, b| {
        let sa = a.vcpu + a.inference_usd_per_h * 4.0 + a.b_tok_per_h * 50.0;
        let sb = b.vcpu + b.inference_usd_per_h * 4.0 + b.b_tok_per_h * 50.0;
        sb.partial_cmp(&sa).unwrap_or(std::cmp::Ordering::Equal)
    });

    Ok(Json(ResourcesOverviewResponse {
        as_of: now.to_rfc3339(),
        range: spec.id.to_string(),
        bucket_seconds,
        timestamps_ms,
        compute: ComputeOverview {
            total_vcpu: fleet_total_vcpu,
            active_vcpu: fleet_active_vcpu,
            idle_leased_vcpu: fleet_idle_vcpu,
            hourly_burn_usd: fleet_burn_usd,
            sources: compute_sources,
        },
        inference: InferenceOverview {
            current_b_tok_per_h: total_btok_h,
            est_usd_per_h: total_inf_usd_h,
            window_total_tokens,
            window_est_usd: window_est_mc as f64 / 100_000.0,
            throttled_429_count: total_429,
            pools,
        },
        missions,
        links,
    }))
}

/* -------------------------------------------------------------------------- */
/* Per-Mission Subagent Flow & Fast-DAG Endpoint                              */
/* -------------------------------------------------------------------------- */

#[derive(Debug, Deserialize)]
pub struct MissionResourcesQuery {
    pub horizon: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct MissionResourcesResponse {
    pub as_of: String,
    pub mission: MissionDetailHeader,
    pub available_horizons: Vec<HorizonOption>,
    pub active_horizon: String,
    pub flow: MissionFlowPayload,
    pub dag: MissionDagPayload,
    pub timeline: MissionTimelineSeries,
}

#[derive(Debug, Serialize)]
pub struct HorizonOption {
    pub id: String,
    pub label: String,
    pub span_secs: i64,
}

#[derive(Debug, Serialize)]
pub struct MissionDetailHeader {
    pub id: String,
    pub title: String,
    pub project: Option<String>,
    pub status: String,
    pub started_at: String,
    pub completed_at: Option<String>,
    pub elapsed_secs: i64,
    pub eta_remaining_secs: Option<i64>,
    pub subagent_count: usize,
    pub track_count: usize,
}

#[derive(Debug, Serialize)]
pub struct MissionFlowPayload {
    pub inputs: Vec<MissionFlowInputNode>,
    pub tracks: Vec<MissionFlowTrackNode>,
    pub subagents: Vec<MissionFlowSubagentNode>,
    pub input_to_track: Vec<MissionFlowEdge>,
    pub track_to_subagent: Vec<MissionFlowEdge>,
}

#[derive(Debug, Serialize)]
pub struct MissionFlowInputNode {
    pub id: String,
    pub kind: String,
    pub label: String,
    pub sub: String,
    pub weight: f64,
    pub est_usd_per_h: f64,
}

#[derive(Debug, Serialize)]
pub struct MissionFlowTrackNode {
    pub id: String,
    pub label: String,
    pub sub: String,
    pub state: String,
}

#[derive(Debug, Serialize)]
pub struct MissionFlowSubagentNode {
    pub id: String,
    pub mission_id: Option<String>,
    pub native: bool,
    pub track_id: String,
    pub role: String,
    pub label: String,
    pub model: Option<String>,
    pub node_id: Option<String>,
    pub vcpu: f64,
    pub compute_usd_per_h: f64,
    pub b_tok_per_h: f64,
    pub inference_usd_per_h: f64,
    pub state: String,
}

#[derive(Debug, Serialize)]
pub struct MissionFlowEdge {
    pub kind: String,
    pub source_id: String,
    pub target_id: String,
    pub weight: f64,
    pub est_usd_per_h: f64,
    pub degraded: bool,
}

#[derive(Debug, Serialize)]
pub struct MissionDagPayload {
    pub origin_unix_secs: i64,
    pub horizon_secs: i64,
    pub now_offset_secs: i64,
    pub bars: Vec<MissionDagBar>,
}

#[derive(Debug, Serialize)]
pub struct MissionDagBar {
    pub id: String,
    pub mission_id: Option<String>,
    pub label: String,
    pub section: String,
    pub role: String,
    pub model: Option<String>,
    pub node_id: Option<String>,
    pub vcpu: f64,
    pub compute_usd_per_h: f64,
    pub b_tok_per_h: f64,
    pub inference_usd_per_h: f64,
    pub start_offset_secs: i64,
    pub duration_secs: i64,
    pub eta_remaining_secs: Option<i64>,
    pub eta_basis: Option<String>,
    pub state: String,
    pub after_ids: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct MissionTimelineSeries {
    pub offsets_secs: Vec<i64>,
    pub observed_vcpu: Vec<Option<f64>>,
    pub projected_vcpu: Vec<Option<f64>>,
    pub observed_compute_usd_per_h: Vec<Option<f64>>,
    pub projected_compute_usd_per_h: Vec<Option<f64>>,
    pub observed_b_tok_per_h: Vec<Option<f64>>,
    pub projected_b_tok_per_h: Vec<Option<f64>>,
    pub observed_inference_usd_per_h: Vec<Option<f64>>,
    pub projected_inference_usd_per_h: Vec<Option<f64>>,
}

fn normalize_bar_state(status: &str, stall_kind: Option<&str>) -> &'static str {
    if stall_kind.is_some() || status == "blocked" {
        return "capped";
    }
    match status {
        "completed" | "acknowledged" | "done" => "done",
        "active" | "waiting_background" | "running" => "active",
        "failed" | "cancelled" | "interrupted" => "capped",
        _ => "pending",
    }
}

async fn get_mission_resources(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Query(query): Query<MissionResourcesQuery>,
) -> Result<Json<MissionResourcesResponse>, (StatusCode, String)> {
    let now = Utc::now();
    let now_secs = now.timestamp();
    let since_8d_min = (now_secs - 8 * 86_400).div_euclid(60);

    let control_state = state.control.get_or_spawn(&user).await;
    let Some(snap) = control_state
        .mission_store
        .query_mission_resources(id, since_8d_min)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?
    else {
        return Err((StatusCode::NOT_FOUND, format!("Mission {id} not found")));
    };

    let root_start_secs = parse_rfc3339_unix_secs(
        snap.root
            .first_started_at
            .as_deref()
            .unwrap_or(&snap.root.created_at),
    )
    .unwrap_or(now_secs - 300);
    let root_end_secs = snap
        .root
        .completed_at
        .as_deref()
        .and_then(parse_rfc3339_unix_secs);
    let full_elapsed = (root_end_secs.unwrap_or(now_secs) - root_start_secs).max(60);

    // Horizon selection (`6h` wave vs `all` history when mission spans > 6h)
    let mut available_horizons = Vec::new();
    let wave_span_secs = if full_elapsed <= 3_600 { 3_600 } else { 21_600 };
    available_horizons.push(HorizonOption {
        id: "6h".to_string(),
        label: if full_elapsed <= 3_600 {
            "Active wave (1h)".to_string()
        } else {
            "Fast-DAG (6h)".to_string()
        },
        span_secs: wave_span_secs,
    });
    if full_elapsed > 21_600 {
        let days = full_elapsed as f64 / 86_400.0;
        let lbl = if days >= 1.0 {
            format!("{days:.1}d history")
        } else {
            format!("{}h history", (full_elapsed + 3599) / 3600)
        };
        available_horizons.push(HorizonOption {
            id: "all".to_string(),
            label: lbl,
            span_secs: (full_elapsed as f64 * 1.12) as i64,
        });
    }

    let active_horizon = query
        .horizon
        .as_deref()
        .filter(|h| available_horizons.iter().any(|opt| opt.id == *h))
        .unwrap_or("6h")
        .to_string();

    let (origin_secs, horizon_secs) = if active_horizon == "all" {
        (
            root_start_secs,
            (full_elapsed as f64 * 1.12).max(3600.0) as i64,
        )
    } else if full_elapsed > wave_span_secs {
        // Anchor the 6h window so `now` sits ~75% across (showing recent completions + forward ETA wave)
        let anchor_now = root_end_secs.unwrap_or(now_secs);
        let orig = (anchor_now - (wave_span_secs * 3) / 4).max(root_start_secs);
        (orig, wave_span_secs)
    } else {
        (root_start_secs, wave_span_secs)
    };
    let origin_min = origin_secs.div_euclid(60);
    let window_hours = (horizon_secs as f64 / 3600.0).max(0.5);

    // Map board task_key -> bar_id (either spawned worker_mission_id or `board:<id>`)
    let mut task_key_to_bar_id: HashMap<String, String> = HashMap::new();
    let mut board_by_worker: HashMap<
        String,
        &super::mission_store::sqlite_resources::BoardTaskResourceRow,
    > = HashMap::new();
    for bt in &snap.board_tasks {
        let bid = bt
            .worker_mission_id
            .clone()
            .unwrap_or_else(|| format!("board:{}", bt.id));
        task_key_to_bar_id.insert(bt.task_key.clone(), bid);
        if let Some(wid) = &bt.worker_mission_id {
            board_by_worker.insert(wid.clone(), bt);
        }
    }

    // Per-mission usage & compute totals within the selected horizon
    let mut m_tok: HashMap<String, (u64, u64, Option<String>)> = HashMap::new();
    let mut m_pool_tok: HashMap<(String, String), (u64, u64, u64)> = HashMap::new();
    for u in &snap.usage_by_mission {
        if u.bucket_unix_min < origin_min {
            continue;
        }
        let e = m_tok.entry(u.mission_id.clone()).or_insert((0, 0, None));
        e.0 += u.total_tokens;
        e.1 += u.est_cost_millicents;
        if e.2.is_none() && !u.model.is_empty() {
            e.2 = Some(u.model.clone());
        }
        let pe = m_pool_tok
            .entry((u.pool_id.clone(), u.mission_id.clone()))
            .or_insert((0, 0, 0));
        pe.0 += u.total_tokens;
        pe.1 += u.est_cost_millicents;
        pe.2 += u.rate_limit_429_count;
    }

    let obs_comp_mins = snap
        .compute_by_mission
        .iter()
        .filter(|c| c.bucket_unix_min >= origin_min)
        .map(|c| c.bucket_unix_min)
        .collect::<HashSet<_>>()
        .len()
        .max(1) as f64;
    let mut m_comp: HashMap<String, (f64, u64, bool)> = HashMap::new();
    let mut m_class_comp: HashMap<(String, String), (f64, u64, bool)> = HashMap::new();
    for c in &snap.compute_by_mission {
        if c.bucket_unix_min < origin_min {
            continue;
        }
        let e = m_comp
            .entry(c.mission_id.clone())
            .or_insert((0.0, 0, false));
        e.0 += c.vcpu_allocated;
        e.1 += c.cost_millicents;
        if c.state == "idle_leased" {
            e.2 = true;
        }
        let ce = m_class_comp
            .entry((c.machine_class.clone(), c.mission_id.clone()))
            .or_insert((0.0, 0, false));
        ce.0 += c.vcpu_allocated;
        ce.1 += c.cost_millicents;
        if c.state == "idle_leased" {
            ce.2 = true;
        }
    }

    // Build unified subagent bars + flow nodes
    let mut bars: Vec<MissionDagBar> = Vec::new();
    let mut subagents: Vec<MissionFlowSubagentNode> = Vec::new();

    // If the root mission has no child missions/board tasks/native spans yet, represent the root agent itself
    let has_sub_units =
        !snap.children.is_empty() || !snap.board_tasks.is_empty() || !snap.native_spans.is_empty();

    let nodes_to_render: Vec<&super::mission_store::sqlite_resources::MissionNodeRow> =
        if has_sub_units {
            snap.children.iter().collect()
        } else {
            vec![&snap.root]
        };

    for child in nodes_to_render {
        let bt = board_by_worker.get(&child.id).copied();
        let role = child
            .role
            .clone()
            .or_else(|| bt.map(|b| b.role.clone()))
            .unwrap_or_else(|| {
                if child.id == snap.root.id {
                    "coordinator".to_string()
                } else {
                    "worker".to_string()
                }
            });
        let section = child
            .track
            .clone()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| {
                let mut ch = role.chars();
                match ch.next() {
                    Some(f) => format!("{}{}", f.to_ascii_uppercase(), ch.as_str()),
                    None => "Workers".to_string(),
                }
            });

        let raw_deps = if !child.depends_on.is_empty() {
            &child.depends_on
        } else if let Some(b) = bt {
            &b.depends_on
        } else {
            &child.depends_on
        };
        let after_ids: Vec<String> = raw_deps
            .iter()
            .map(|d| {
                task_key_to_bar_id
                    .get(d)
                    .cloned()
                    .unwrap_or_else(|| d.clone())
            })
            .collect();

        let start_s = parse_rfc3339_unix_secs(
            child
                .first_started_at
                .as_deref()
                .unwrap_or(&child.created_at),
        )
        .unwrap_or(origin_secs);
        let end_s = child
            .completed_at
            .as_deref()
            .and_then(parse_rfc3339_unix_secs);
        let state_norm = normalize_bar_state(&child.status, child.stall_kind.as_deref());

        let (start_off, dur_secs) = if state_norm == "pending" {
            let off = (start_s - origin_secs).max(0);
            (off, snap.cohort_p50_secs)
        } else {
            let actual_end = end_s.unwrap_or(now_secs);
            let off = (start_s - origin_secs).max(0);
            let obs = (actual_end - start_s).max(45);
            let total_dur = obs + child.eta_remaining_secs.unwrap_or(0);
            (off, total_dur)
        };

        let (tok, inf_mc, inferred_model) = m_tok.get(&child.id).cloned().unwrap_or((0, 0, None));
        let (sum_vcpu, comp_mc, _) = m_comp.get(&child.id).copied().unwrap_or((0.0, 0, false));

        let vcpu = if sum_vcpu > 0.0 {
            sum_vcpu / obs_comp_mins
        } else if state_norm == "active" {
            2.0
        } else {
            0.0
        };
        let comp_usd_h = if comp_mc > 0 {
            (comp_mc as f64 / 100_000.0) * (60.0 / obs_comp_mins)
        } else {
            vcpu * LOCAL_HOST_VCPU_USD_PER_HOUR
        };
        let btok_h = (tok as f64 / 1e9) / window_hours;
        let inf_usd_h = (inf_mc as f64 / 100_000.0) / window_hours;
        let model = child
            .model_override
            .clone()
            .or(inferred_model)
            .or_else(|| Some(child.backend.clone()));
        let node_id = child
            .placement_node_id
            .clone()
            .or_else(|| child.remote_node_id.clone());

        bars.push(MissionDagBar {
            id: child.id.clone(),
            mission_id: Some(child.id.clone()),
            label: child.title.clone(),
            section: section.clone(),
            role: role.clone(),
            model: model.clone(),
            node_id: node_id.clone(),
            vcpu,
            compute_usd_per_h: comp_usd_h,
            b_tok_per_h: btok_h,
            inference_usd_per_h: inf_usd_h,
            start_offset_secs: start_off,
            duration_secs: dur_secs,
            eta_remaining_secs: child.eta_remaining_secs,
            eta_basis: child.eta_basis.clone(),
            state: state_norm.to_string(),
            after_ids,
        });

        subagents.push(MissionFlowSubagentNode {
            id: child.id.clone(),
            mission_id: Some(child.id.clone()),
            native: false,
            track_id: format!("track:{section}"),
            role,
            label: child.title.clone(),
            model,
            node_id,
            vcpu,
            compute_usd_per_h: comp_usd_h,
            b_tok_per_h: btok_h,
            inference_usd_per_h: inf_usd_h,
            state: state_norm.to_string(),
        });
    }

    // Add unspawned queued `board_tasks` so future DAG waves render with their `depends_on` edges!
    let mut bar_end_by_id: HashMap<String, i64> = bars
        .iter()
        .map(|b| (b.id.clone(), b.start_offset_secs + b.duration_secs))
        .collect();

    for bt in &snap.board_tasks {
        if bt.worker_mission_id.is_some() {
            continue;
        }
        let bar_id = format!("board:{}", bt.id);
        let after_ids: Vec<String> = bt
            .depends_on
            .iter()
            .map(|d| {
                task_key_to_bar_id
                    .get(d)
                    .cloned()
                    .unwrap_or_else(|| d.clone())
            })
            .collect();
        let dep_end = after_ids
            .iter()
            .filter_map(|aid| bar_end_by_id.get(aid).copied())
            .max()
            .unwrap_or((now_secs - origin_secs).max(0));
        let start_off = dep_end.max((now_secs - origin_secs).max(0));
        let dur_secs = snap.cohort_p50_secs;
        bar_end_by_id.insert(bar_id.clone(), start_off + dur_secs);

        let mut role_ch = bt.role.chars();
        let section = match role_ch.next() {
            Some(f) => format!("{}{}", f.to_ascii_uppercase(), role_ch.as_str()),
            None => "Queued".to_string(),
        };

        bars.push(MissionDagBar {
            id: bar_id.clone(),
            mission_id: None,
            label: bt.title.clone(),
            section: section.clone(),
            role: bt.role.clone(),
            model: bt.model_override.clone().or_else(|| bt.backend.clone()),
            node_id: None,
            vcpu: 2.0,
            compute_usd_per_h: 2.0 * STATIC_VCPU_USD_PER_HOUR,
            b_tok_per_h: 0.02,
            inference_usd_per_h: 0.18,
            start_offset_secs: start_off,
            duration_secs: dur_secs,
            eta_remaining_secs: Some(dur_secs),
            eta_basis: Some("cohort_p50".to_string()),
            state: "pending".to_string(),
            after_ids,
        });
    }

    // Add native in-harness subagent spans (`Task` / `Agent` / `invoke_subagent`)
    for sp in &snap.native_spans {
        let start_s = parse_rfc3339_unix_secs(&sp.started_at).unwrap_or(origin_secs);
        let end_s = sp.completed_at.as_deref().and_then(parse_rfc3339_unix_secs);
        if end_s.is_some_and(|e| e < origin_secs) {
            continue;
        }
        let start_off = (start_s - origin_secs).max(0);
        let dur_secs = (end_s.unwrap_or(now_secs) - start_s).max(30);
        let st = normalize_bar_state(&sp.state, None);
        let sid = format!("span:{}", sp.tool_call_id);
        let section = "In-harness subagents".to_string();

        bars.push(MissionDagBar {
            id: sid.clone(),
            mission_id: Some(sp.mission_id.clone()),
            label: sp.name.clone(),
            section: section.clone(),
            role: sp.role.clone(),
            model: sp.model.clone(),
            node_id: None,
            vcpu: 1.0,
            compute_usd_per_h: LOCAL_HOST_VCPU_USD_PER_HOUR,
            b_tok_per_h: 0.01,
            inference_usd_per_h: 0.08,
            start_offset_secs: start_off,
            duration_secs: dur_secs,
            eta_remaining_secs: None,
            eta_basis: None,
            state: st.to_string(),
            after_ids: Vec::new(),
        });

        subagents.push(MissionFlowSubagentNode {
            id: sid,
            mission_id: Some(sp.mission_id.clone()),
            native: true,
            track_id: format!("track:{section}"),
            role: sp.role.clone(),
            label: sp.name.clone(),
            model: sp.model.clone(),
            node_id: None,
            vcpu: 1.0,
            compute_usd_per_h: LOCAL_HOST_VCPU_USD_PER_HOUR,
            b_tok_per_h: 0.01,
            inference_usd_per_h: 0.08,
            state: st.to_string(),
        });
    }

    // Extend horizon if projected queued waves reach past `horizon_secs`
    let max_bar_end = bars
        .iter()
        .map(|b| b.start_offset_secs + b.duration_secs)
        .max()
        .unwrap_or(horizon_secs);
    let effective_horizon_secs = horizon_secs.max(((max_bar_end as f64) * 1.05) as i64);
    let now_offset_secs = (now_secs - origin_secs).clamp(0, effective_horizon_secs);

    // Build conserved 3-column Flow (`Inputs -> Tracks -> Subagents`)
    let mut track_map: BTreeMap<String, (String, usize, usize)> = BTreeMap::new(); // track_id -> (label, running, total)
    let mut mission_to_track: HashMap<String, String> = HashMap::new();
    for s in &subagents {
        let lbl = s.track_id.strip_prefix("track:").unwrap_or(&s.track_id);
        let entry = track_map
            .entry(s.track_id.clone())
            .or_insert_with(|| (lbl.to_string(), 0, 0));
        entry.2 += 1;
        if s.state == "active" {
            entry.1 += 1;
        }
        if let Some(mid) = &s.mission_id {
            mission_to_track.insert(mid.clone(), s.track_id.clone());
        }
    }
    let default_track_id = track_map
        .keys()
        .next()
        .cloned()
        .unwrap_or_else(|| "track:Main".to_string());

    let tracks: Vec<MissionFlowTrackNode> = track_map
        .iter()
        .map(|(tid, (lbl, running, total))| MissionFlowTrackNode {
            id: tid.clone(),
            label: lbl.clone(),
            sub: format!("{running}/{total} active"),
            state: if *running > 0 {
                "active".to_string()
            } else {
                "done".to_string()
            },
        })
        .collect();

    let mut inputs: Vec<MissionFlowInputNode> = Vec::new();
    let mut input_to_track: Vec<MissionFlowEdge> = Vec::new();
    let mut track_to_subagent: Vec<MissionFlowEdge> = Vec::new();

    // Compute Flow edges
    let mut comp_in_by_class: BTreeMap<String, (f64, f64)> = BTreeMap::new();
    let mut comp_in_to_track: BTreeMap<(String, String), (f64, f64, bool)> = BTreeMap::new();
    for ((cid, mid), (sum_v, sum_mc, idle)) in &m_class_comp {
        let tid = mission_to_track
            .get(mid)
            .cloned()
            .unwrap_or_else(|| default_track_id.clone());
        let v = *sum_v / obs_comp_mins;
        let u = (*sum_mc as f64 / 100_000.0) * (60.0 / obs_comp_mins);
        let ci = comp_in_by_class.entry(cid.clone()).or_insert((0.0, 0.0));
        ci.0 += v;
        ci.1 += u;
        let ct = comp_in_to_track
            .entry((cid.clone(), tid))
            .or_insert((0.0, 0.0, false));
        ct.0 += v;
        ct.1 += u;
        ct.2 |= *idle;
    }
    for (cid, (v, u)) in &comp_in_by_class {
        if *v > 0.001 {
            inputs.push(MissionFlowInputNode {
                id: format!("in:comp:{cid}"),
                kind: "compute".to_string(),
                label: machine_class_label(cid),
                sub: "compute".to_string(),
                weight: *v,
                est_usd_per_h: *u,
            });
        }
    }
    for ((cid, tid), (v, u, deg)) in &comp_in_to_track {
        if *v > 0.001 {
            input_to_track.push(MissionFlowEdge {
                kind: "compute".to_string(),
                source_id: format!("in:comp:{cid}"),
                target_id: tid.clone(),
                weight: *v,
                est_usd_per_h: *u,
                degraded: *deg,
            });
        }
    }

    // Inference Flow edges
    let mut inf_in_by_pool: BTreeMap<String, (f64, f64)> = BTreeMap::new();
    let mut inf_in_to_track: BTreeMap<(String, String), (f64, f64, bool)> = BTreeMap::new();
    for ((pid, mid), (sum_t, sum_mc, sum_429)) in &m_pool_tok {
        let tid = mission_to_track
            .get(mid)
            .cloned()
            .unwrap_or_else(|| default_track_id.clone());
        let btok = (*sum_t as f64 / 1e9) / window_hours;
        let u = (*sum_mc as f64 / 100_000.0) / window_hours;
        let pi = inf_in_by_pool.entry(pid.clone()).or_insert((0.0, 0.0));
        pi.0 += btok;
        pi.1 += u;
        let pt = inf_in_to_track
            .entry((pid.clone(), tid))
            .or_insert((0.0, 0.0, false));
        pt.0 += btok;
        pt.1 += u;
        pt.2 |= *sum_429 > 0;
    }
    for (pid, (b, u)) in &inf_in_by_pool {
        if *b > 0.0 || *u > 0.0 {
            inputs.push(MissionFlowInputNode {
                id: format!("in:inf:{pid}"),
                kind: "inference".to_string(),
                label: pool_label_for_id(pid),
                sub: "inference".to_string(),
                weight: *b,
                est_usd_per_h: *u,
            });
        }
    }
    for ((pid, tid), (b, u, deg)) in &inf_in_to_track {
        if *b > 0.0 || *u > 0.0 {
            input_to_track.push(MissionFlowEdge {
                kind: "inference".to_string(),
                source_id: format!("in:inf:{pid}"),
                target_id: tid.clone(),
                weight: *b,
                est_usd_per_h: *u,
                degraded: *deg,
            });
        }
    }

    // Track -> Subagent conserved edges (split track inflow proportionally across subagents in that track)
    for kind in ["compute", "inference"] {
        let mut track_in: HashMap<String, (f64, f64)> = HashMap::new();
        for e in input_to_track.iter().filter(|e| e.kind == kind) {
            let t = track_in.entry(e.target_id.clone()).or_insert((0.0, 0.0));
            t.0 += e.weight;
            t.1 += e.est_usd_per_h;
        }
        for (tid, (in_w, in_u)) in track_in {
            let members: Vec<&MissionFlowSubagentNode> =
                subagents.iter().filter(|s| s.track_id == tid).collect();
            if members.is_empty() {
                continue;
            }
            let raw_sum: f64 = members
                .iter()
                .map(|m| {
                    if kind == "compute" {
                        m.vcpu.max(0.05)
                    } else {
                        m.b_tok_per_h.max(0.0001)
                    }
                })
                .sum();
            for m in members {
                let frac = if raw_sum > 0.0 {
                    let mw = if kind == "compute" {
                        m.vcpu.max(0.05)
                    } else {
                        m.b_tok_per_h.max(0.0001)
                    };
                    mw / raw_sum
                } else {
                    1.0 / (subagents.len().max(1) as f64)
                };
                track_to_subagent.push(MissionFlowEdge {
                    kind: kind.to_string(),
                    source_id: tid.clone(),
                    target_id: m.id.clone(),
                    weight: in_w * frac,
                    est_usd_per_h: in_u * frac,
                    degraded: m.state == "capped",
                });
            }
        }
    }

    // Synchronized 72-step consumption curve aligned with `0 .. effective_horizon_secs`
    let steps = 72usize;
    let offsets_secs: Vec<i64> = (0..steps)
        .map(|i| ((i as i64) * effective_horizon_secs) / (steps as i64 - 1))
        .collect();

    let mut obs_vcpu = vec![None; steps];
    let mut proj_vcpu = vec![None; steps];
    let mut obs_cu = vec![None; steps];
    let mut proj_cu = vec![None; steps];
    let mut obs_btok = vec![None; steps];
    let mut proj_btok = vec![None; steps];
    let mut obs_iu = vec![None; steps];
    let mut proj_iu = vec![None; steps];

    let pivot_idx = offsets_secs
        .iter()
        .position(|&off| off > now_offset_secs)
        .unwrap_or(steps)
        .saturating_sub(1);

    for (i, &off) in offsets_secs.iter().enumerate() {
        let mut v_sum = 0.0;
        let mut cu_sum = 0.0;
        let mut b_sum = 0.0;
        let mut iu_sum = 0.0;
        for b in &bars {
            if off >= b.start_offset_secs && off <= b.start_offset_secs + b.duration_secs {
                v_sum += b.vcpu;
                cu_sum += b.compute_usd_per_h;
                b_sum += b.b_tok_per_h;
                iu_sum += b.inference_usd_per_h;
            }
        }
        if i <= pivot_idx {
            obs_vcpu[i] = Some(v_sum);
            obs_cu[i] = Some(cu_sum);
            obs_btok[i] = Some(b_sum);
            obs_iu[i] = Some(iu_sum);
        }
        if i >= pivot_idx && now_offset_secs < effective_horizon_secs {
            proj_vcpu[i] = Some(v_sum);
            proj_cu[i] = Some(cu_sum);
            proj_btok[i] = Some(b_sum);
            proj_iu[i] = Some(iu_sum);
        }
    }

    let subagent_count = subagents.len();
    let track_count = tracks.len();

    Ok(Json(MissionResourcesResponse {
        as_of: now.to_rfc3339(),
        mission: MissionDetailHeader {
            id: snap.root.id,
            title: snap.root.title,
            project: snap.root.project,
            status: snap.root.status,
            started_at: snap.root.first_started_at.unwrap_or(snap.root.created_at),
            completed_at: snap.root.completed_at,
            elapsed_secs: full_elapsed,
            eta_remaining_secs: bars.iter().filter_map(|b| b.eta_remaining_secs).max(),
            subagent_count,
            track_count,
        },
        available_horizons,
        active_horizon,
        flow: MissionFlowPayload {
            inputs,
            tracks,
            subagents,
            input_to_track,
            track_to_subagent,
        },
        dag: MissionDagPayload {
            origin_unix_secs: origin_secs,
            horizon_secs: effective_horizon_secs,
            now_offset_secs,
            bars,
        },
        timeline: MissionTimelineSeries {
            offsets_secs,
            observed_vcpu: obs_vcpu,
            projected_vcpu: proj_vcpu,
            observed_compute_usd_per_h: obs_cu,
            projected_compute_usd_per_h: proj_cu,
            observed_b_tok_per_h: obs_btok,
            projected_b_tok_per_h: proj_btok,
            observed_inference_usd_per_h: obs_iu,
            projected_inference_usd_per_h: proj_iu,
        },
    }))
}
