//! Resource flow rollups, subagent spans, and orchestration metadata for SQLite.
//!
//! Powers `GET /api/resources/overview` and `GET /api/resources/missions/:id`
//! from compact 1-minute `WITHOUT ROWID` rollups and side tables on read-only
//! WAL connections without touching `MISSION_LIST_COLUMNS`.

use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Weak;
use tokio::sync::Mutex;
use uuid::Uuid;

use super::SqliteMissionStore;
use crate::api::control::AgentEvent;
use crate::api::mission_store::{MissionRun, ProxyOutcomeRecord, ProxyUsageRecord};

const ROLLUP_RETENTION_DAYS: i64 = 8;
static ROLLUP_WRITE_SEQ: AtomicU64 = AtomicU64::new(0);

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ComputeMinuteSample {
    pub bucket_unix_min: i64,
    pub machine_class: String,
    pub node_id: String,
    pub root_mission_id: String,
    pub mission_id: String,
    pub state: String,
    pub vcpu_allocated: f64,
    pub vcpu_busy: f64,
    pub ram_gb_allocated: f64,
    pub cost_millicents: i64,
}

#[derive(Debug, Clone, Default)]
pub struct UsageRollupRow {
    pub bucket_unix_min: i64,
    pub pool_id: String,
    pub root_mission_id: String,
    pub total_tokens: u64,
    pub billable_tokens: u64,
    pub rate_limit_429_count: u64,
    pub est_cost_millicents: u64,
}

#[derive(Debug, Clone, Default)]
pub struct ComputeRollupRow {
    pub bucket_unix_min: i64,
    pub machine_class: String,
    pub node_id: String,
    pub root_mission_id: String,
    pub state: String,
    pub vcpu_allocated: f64,
    pub cost_millicents: u64,
}

#[derive(Debug, Clone, Default)]
pub struct RootMissionResourceRow {
    pub id: String,
    pub title: String,
    pub project: Option<String>,
    pub status: String,
    pub backend: String,
    pub remote_node_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub first_started_at: Option<String>,
    pub completed_at: Option<String>,
    pub stall_kind: Option<String>,
    pub subagent_running: u32,
    pub subagent_total: u32,
    pub eta_remaining_secs: Option<i64>,
}

#[derive(Debug, Clone, Default)]
pub struct ActiveRunAttributionRow {
    pub mission_id: String,
    pub root_mission_id: String,
    pub remote_node_id: Option<String>,
    pub placement_node_id: Option<String>,
    pub scope_unit: Option<String>,
    pub status: String,
}

#[derive(Debug, Clone, Default)]
pub struct ResourcesStoreOverview {
    pub usage_rows: Vec<UsageRollupRow>,
    pub compute_rows: Vec<ComputeRollupRow>,
    pub root_missions: Vec<RootMissionResourceRow>,
    pub active_runs: Vec<ActiveRunAttributionRow>,
    pub mission_roots: HashMap<String, String>,
}

#[derive(Debug, Clone, Default)]
pub struct MissionNodeRow {
    pub id: String,
    pub parent_mission_id: Option<String>,
    pub title: String,
    pub project: Option<String>,
    pub track: Option<String>,
    pub status: String,
    pub backend: String,
    pub model_override: Option<String>,
    pub remote_node_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub terminal_reason: Option<String>,
    pub role: Option<String>,
    pub depends_on: Vec<String>,
    pub first_started_at: Option<String>,
    pub completed_at: Option<String>,
    pub active_run_ms: i64,
    pub placement_node_id: Option<String>,
    pub stall_kind: Option<String>,
    pub eta_remaining_secs: Option<i64>,
    pub eta_basis: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct BoardTaskResourceRow {
    pub id: String,
    pub boss_mission_id: String,
    pub task_key: String,
    pub title: String,
    pub backend: Option<String>,
    pub model_override: Option<String>,
    pub role: String,
    pub depends_on: Vec<String>,
    pub status: String,
    pub worker_mission_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Default)]
pub struct NativeSubagentSpanRow {
    pub mission_id: String,
    pub tool_call_id: String,
    pub name: String,
    pub role: String,
    pub model: Option<String>,
    pub state: String,
    pub started_at: String,
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct MissionRunIntervalRow {
    pub mission_id: String,
    pub started_at: String,
    pub ended_at: Option<String>,
    pub scope_unit: Option<String>,
    pub terminal_reason: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct MissionUsageBucketRow {
    pub bucket_unix_min: i64,
    pub pool_id: String,
    pub mission_id: String,
    pub model: String,
    pub total_tokens: u64,
    pub est_cost_millicents: u64,
    pub rate_limit_429_count: u64,
}

#[derive(Debug, Clone, Default)]
pub struct MissionComputeBucketRow {
    pub bucket_unix_min: i64,
    pub machine_class: String,
    pub node_id: String,
    pub mission_id: String,
    pub state: String,
    pub vcpu_allocated: f64,
    pub cost_millicents: u64,
}

#[derive(Debug, Clone, Default)]
pub struct MissionResourcesStoreSnapshot {
    pub root: MissionNodeRow,
    pub children: Vec<MissionNodeRow>,
    pub board_tasks: Vec<BoardTaskResourceRow>,
    pub native_spans: Vec<NativeSubagentSpanRow>,
    pub run_intervals: Vec<MissionRunIntervalRow>,
    pub usage_by_mission: Vec<MissionUsageBucketRow>,
    pub compute_by_mission: Vec<MissionComputeBucketRow>,
    pub cohort_p50_secs: i64,
}

pub const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS mission_orchestration_meta (
    mission_id            TEXT PRIMARY KEY REFERENCES missions(id) ON DELETE CASCADE,
    root_mission_id       TEXT NOT NULL,
    role                  TEXT,
    wave_label            TEXT,
    depends_on_json       TEXT NOT NULL DEFAULT '[]',
    queued_at             TEXT NOT NULL,
    first_started_at      TEXT,
    completed_at          TEXT,
    active_run_ms         INTEGER NOT NULL DEFAULT 0,
    estimated_duration_ms INTEGER,
    placement_node_id     TEXT,
    allocated_vcpu        REAL,
    stall_kind            TEXT
);

CREATE INDEX IF NOT EXISTS idx_orch_meta_root
    ON mission_orchestration_meta(root_mission_id, first_started_at);

CREATE TABLE IF NOT EXISTS mission_subagent_spans (
    mission_id       TEXT NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    tool_call_id     TEXT NOT NULL,
    root_mission_id  TEXT NOT NULL,
    name             TEXT NOT NULL,
    role             TEXT NOT NULL DEFAULT 'subagent',
    model            TEXT,
    state            TEXT NOT NULL,
    started_at       TEXT NOT NULL,
    completed_at     TEXT,
    PRIMARY KEY (mission_id, tool_call_id)
);

CREATE INDEX IF NOT EXISTS idx_subagent_spans_root
    ON mission_subagent_spans(root_mission_id, started_at);

CREATE TABLE IF NOT EXISTS usage_rollup_1m (
    bucket_unix_min       INTEGER NOT NULL,
    pool_id               TEXT NOT NULL,
    root_mission_id       TEXT NOT NULL,
    mission_id            TEXT NOT NULL,
    model                 TEXT NOT NULL,
    total_tokens          INTEGER NOT NULL DEFAULT 0,
    billable_tokens       INTEGER NOT NULL DEFAULT 0,
    output_tokens         INTEGER NOT NULL DEFAULT 0,
    request_count         INTEGER NOT NULL DEFAULT 0,
    rate_limit_429_count  INTEGER NOT NULL DEFAULT 0,
    est_cost_millicents   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (bucket_unix_min, pool_id, root_mission_id, mission_id, model)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_usage_rollup_root_min
    ON usage_rollup_1m(root_mission_id, bucket_unix_min)
    WHERE root_mission_id <> '';

CREATE TABLE IF NOT EXISTS compute_rollup_1m (
    bucket_unix_min   INTEGER NOT NULL,
    machine_class     TEXT NOT NULL,
    node_id           TEXT NOT NULL,
    root_mission_id   TEXT NOT NULL,
    mission_id        TEXT NOT NULL,
    state             TEXT NOT NULL,
    vcpu_allocated    REAL NOT NULL DEFAULT 0,
    vcpu_busy         REAL NOT NULL DEFAULT 0,
    ram_gb_allocated  REAL NOT NULL DEFAULT 0,
    cost_millicents   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (bucket_unix_min, node_id, mission_id, state)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_compute_rollup_root_min
    ON compute_rollup_1m(root_mission_id, bucket_unix_min)
    WHERE root_mission_id <> '';
"#;

/// Canonical inference pool ID & display label for an observed request or turn.
pub fn resolve_inference_pool(
    provider: Option<&str>,
    backend: Option<&str>,
    model: &str,
) -> (String, String) {
    let prov = provider.map(str::trim).unwrap_or("").to_ascii_lowercase();
    let back = backend.map(str::trim).unwrap_or("").to_ascii_lowercase();
    let m = model.trim().to_ascii_lowercase();

    if prov == "antigravity" || back == "antigravity" || m.starts_with("agy-") {
        if m.contains("claude") {
            return ("antigravity:claude".to_string(), "AGY · Claude".to_string());
        }
        return ("antigravity:gemini".to_string(), "AGY · Gemini".to_string());
    }

    let inferred = if !prov.is_empty() {
        prov
    } else {
        crate::api::usage_summary::infer_provider_for_model(model).unwrap_or_else(|| {
            if !back.is_empty() {
                back
            } else {
                "other".to_string()
            }
        })
    };

    match inferred.as_str() {
        "anthropic" | "claudecode" | "claude" => (
            "anthropic:claude".to_string(),
            "Anthropic · Claude".to_string(),
        ),
        "openai" | "codex" => ("openai:codex".to_string(), "OpenAI · Codex".to_string()),
        "google" | "gemini" => ("google:gemini".to_string(), "Google · Gemini".to_string()),
        "xai" | "grok" => ("xai:grok".to_string(), "xAI · Grok".to_string()),
        "kimi" => ("kimi:moonshot".to_string(), "Kimi · Moonshot".to_string()),
        "zai" | "z-ai" => ("zai:glm".to_string(), "Z.AI · GLM".to_string()),
        "minimax" => ("minimax:coding".to_string(), "MiniMax".to_string()),
        "mistral" => ("mistral:codestral".to_string(), "Mistral".to_string()),
        "muse-code" | "muse" => ("muse:spark".to_string(), "Muse Code".to_string()),
        "spark" | "local" => ("spark:local".to_string(), "Local GPU".to_string()),
        other => {
            let label = if other.is_empty() || other == "other" {
                "Other LLM".to_string()
            } else {
                let mut chars = other.chars();
                match chars.next() {
                    Some(first) => format!("{}{}", first.to_ascii_uppercase(), chars.as_str()),
                    None => "Other LLM".to_string(),
                }
            };
            (format!("{other}:pool"), label)
        }
    }
}

pub fn pool_label_for_id(pool_id: &str) -> String {
    match pool_id {
        "antigravity:claude" => "AGY · Claude".to_string(),
        "antigravity:gemini" => "AGY · Gemini".to_string(),
        "anthropic:claude" => "Anthropic · Claude".to_string(),
        "openai:codex" => "OpenAI · Codex".to_string(),
        "google:gemini" => "Google · Gemini".to_string(),
        "xai:grok" => "xAI · Grok".to_string(),
        "kimi:moonshot" => "Kimi · Moonshot".to_string(),
        "zai:glm" => "Z.AI · GLM".to_string(),
        "minimax:coding" => "MiniMax".to_string(),
        "mistral:codestral" => "Mistral".to_string(),
        "muse:spark" => "Muse Code".to_string(),
        "spark:local" => "Local GPU".to_string(),
        other => {
            let head = other.split(':').next().unwrap_or(other);
            let mut chars = head.chars();
            match chars.next() {
                Some(c) => format!("{}{}", c.to_ascii_uppercase(), chars.as_str()),
                None => "Inference".to_string(),
            }
        }
    }
}

/// Sub-cent API-equivalent cost in millicents (`1 USD = 100_000 millicents`).
/// Uses `crate::cost::pricing_for_model` nanodollars so even flat-rate OAuth
/// and small turns accumulate exact estimated dollar rates.
pub fn estimate_cost_millicents(
    model: &str,
    stored_cost_cents: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
) -> u64 {
    let norm = crate::cost::normalized_model(model);
    if let Some(p) =
        crate::cost::pricing_for_model(&norm).or_else(|| crate::cost::pricing_for_model(model))
    {
        let create_rate = p
            .cache_create_nano_per_token
            .unwrap_or(p.input_nano_per_token);
        let read_rate = p
            .cache_read_nano_per_token
            .unwrap_or(p.input_nano_per_token / 10);
        let nanodollars = (input_tokens as u128) * (p.input_nano_per_token as u128)
            + (output_tokens as u128) * (p.output_nano_per_token as u128)
            + (cache_creation_tokens as u128) * (create_rate as u128)
            + (cache_read_tokens as u128) * (read_rate as u128);
        // 1 millicent = 10_000 nanodollars
        let mc = ((nanodollars + 5_000) / 10_000) as u64;
        if mc > 0 {
            return mc;
        }
    }
    if stored_cost_cents > 0 {
        return stored_cost_cents.saturating_mul(1_000);
    }
    // Fallback blended heuristic ($3 / 1M billable, $0.30 / 1M cache read) for uncatalogued models
    let fallback_nano = ((input_tokens + output_tokens + cache_creation_tokens) as u128) * 3_000
        + (cache_read_tokens as u128) * 300;
    ((fallback_nano + 5_000) / 10_000) as u64
}

pub fn parse_rfc3339_unix_secs(ts: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(ts)
        .ok()
        .map(|dt| dt.timestamp())
}

pub fn unix_minute_for_ts(ts: &str) -> i64 {
    parse_rfc3339_unix_secs(ts)
        .unwrap_or_else(|| Utc::now().timestamp())
        .div_euclid(60)
}

fn resolve_root_mission_id_sync(conn: &Connection, mission_id: &str) -> String {
    let mut current = mission_id.to_string();
    for _ in 0..16 {
        let next: Option<Option<String>> = conn
            .query_row(
                "SELECT parent_mission_id FROM missions WHERE id = ?1",
                params![&current],
                |row| row.get(0),
            )
            .optional()
            .ok()
            .flatten();
        match next.flatten() {
            Some(parent) if !parent.is_empty() && parent != current && parent != mission_id => {
                current = parent;
            }
            _ => break,
        }
    }
    current
}

fn maybe_prune_old_rollups(conn: &Connection) {
    if !ROLLUP_WRITE_SEQ
        .fetch_add(1, Ordering::Relaxed)
        .is_multiple_of(256)
    {
        return;
    }
    let cutoff_min = (Utc::now().timestamp() - ROLLUP_RETENTION_DAYS * 86_400).div_euclid(60);
    let _ = conn.execute(
        "DELETE FROM usage_rollup_1m WHERE bucket_unix_min < ?1",
        params![cutoff_min],
    );
    let _ = conn.execute(
        "DELETE FROM compute_rollup_1m WHERE bucket_unix_min < ?1",
        params![cutoff_min],
    );
}

/// Ensure resource rollup tables exist; returns `true` when background 8-day
/// backfill should be scheduled.
pub(super) fn ensure_schema(conn: &Connection) -> Result<bool, String> {
    conn.execute_batch(SCHEMA)
        .map_err(|e| format!("Failed to create resource rollup schema: {e}"))?;

    let rollup_empty: bool = conn
        .query_row(
            "SELECT NOT EXISTS(SELECT 1 FROM usage_rollup_1m LIMIT 1)",
            [],
            |r| r.get(0),
        )
        .unwrap_or(false);
    let meta_empty: bool = conn
        .query_row(
            "SELECT NOT EXISTS(SELECT 1 FROM mission_orchestration_meta LIMIT 1)",
            [],
            |r| r.get(0),
        )
        .unwrap_or(false);

    if !rollup_empty && !meta_empty {
        return Ok(false);
    }

    let has_source_data: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM missions LIMIT 1) OR EXISTS(SELECT 1 FROM proxy_usage LIMIT 1)",
            [],
            |r| r.get(0),
        )
        .unwrap_or(false);
    Ok(has_source_data)
}

pub(super) fn spawn_background_backfill(conn_weak: Weak<Mutex<Connection>>) {
    let Ok(handle) = tokio::runtime::Handle::try_current() else {
        return;
    };
    handle.spawn(async move {
        let Some(conn_arc) = conn_weak.upgrade() else {
            return;
        };
        let _ = tokio::task::spawn_blocking(move || {
            let conn = conn_arc.blocking_lock();
            if let Err(e) = backfill_recent_sync(&conn) {
                tracing::warn!(error = %e, "Resources rollup backfill skipped");
            }
        })
        .await;
    });
}

/// Idempotent backfill of the last 8 days of missions, runs, board tasks,
/// native subagent spans, and proxy/harness token usage.
pub(super) fn backfill_recent_sync(conn: &Connection) -> Result<(), String> {
    let cutoff_iso = (Utc::now() - chrono::Duration::days(ROLLUP_RETENTION_DAYS)).to_rfc3339();

    // 1. Parent lookup map for root_mission_id resolution
    let mut parents: HashMap<String, String> = HashMap::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT id, parent_mission_id FROM missions WHERE parent_mission_id IS NOT NULL",
            )
            .map_err(err)?;
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
            .map_err(err)?;
        for row in rows.flatten() {
            parents.insert(row.0, row.1);
        }
    }
    let root_of = |mid: &str| -> String {
        let mut cur = mid;
        for _ in 0..16 {
            match parents.get(cur) {
                Some(p) if !p.is_empty() && p != mid && p != cur => cur = p.as_str(),
                _ => break,
            }
        }
        cur.to_string()
    };

    // 2. Backfill mission_orchestration_meta for recent/live missions
    {
        let mut stmt = conn
            .prepare(
                "SELECT m.id, m.created_at, m.updated_at, m.status,
                        (SELECT MAX(CASE
                            WHEN r.scope_unit LIKE 'remote-node:%' THEN substr(r.scope_unit, 13)
                            WHEN r.scope_unit LIKE 'remote:%' THEN substr(r.scope_unit, 8)
                            ELSE NULL END)
                         FROM mission_runs r WHERE r.mission_id = m.id),
                        (SELECT MIN(r.started_at) FROM mission_runs r WHERE r.mission_id = m.id),
                        (SELECT MAX(r.ended_at) FROM mission_runs r WHERE r.mission_id = m.id AND r.ended_at IS NOT NULL),
                        b.role, b.depends_on
                 FROM missions m
                 LEFT JOIN board_tasks b ON b.worker_mission_id = m.id
                 WHERE m.updated_at >= ?1 OR m.status IN ('pending', 'active', 'waiting_background', 'blocked')",
            )
            .map_err(err)?;
        let rows = stmt
            .query_map(params![&cutoff_iso], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, Option<String>>(4)?,
                    r.get::<_, Option<String>>(5)?,
                    r.get::<_, Option<String>>(6)?,
                    r.get::<_, Option<String>>(7)?,
                    r.get::<_, Option<String>>(8)?,
                ))
            })
            .map_err(err)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(err)?;

        for (
            id,
            created_at,
            updated_at,
            status,
            remote_node_id,
            first_start,
            last_end,
            role,
            deps,
        ) in rows
        {
            let root_id = root_of(&id);
            let is_terminal = matches!(
                status.as_str(),
                "completed" | "acknowledged" | "failed" | "cancelled" | "interrupted"
            );
            let completed_at = if is_terminal {
                last_end.or(Some(updated_at))
            } else {
                None
            };
            let _ = conn.execute(
                "INSERT OR IGNORE INTO mission_orchestration_meta
                 (mission_id, root_mission_id, role, depends_on_json, queued_at, first_started_at, completed_at, placement_node_id)
                 VALUES (?1, ?2, ?3, COALESCE(?4, '[]'), ?5, ?6, ?7, ?8)",
                params![
                    id,
                    root_id,
                    role,
                    deps,
                    created_at,
                    first_start,
                    completed_at,
                    remote_node_id,
                ],
            );
        }
    }

    // 3. Backfill usage_rollup_1m only if currently empty (avoid double-counting)
    let rollup_empty: bool = conn
        .query_row(
            "SELECT NOT EXISTS(SELECT 1 FROM usage_rollup_1m LIMIT 1)",
            [],
            |r| r.get(0),
        )
        .unwrap_or(false);
    if rollup_empty {
        // 3a. Router rows (`proxy_usage`)
        let mut stmt = conn
            .prepare(
                "SELECT p.timestamp, p.model, p.provider, p.mission_id, m.backend,
                        p.input_tokens, p.output_tokens, p.cache_creation_tokens, p.cache_read_tokens, p.cost_cents
                 FROM proxy_usage p
                 LEFT JOIN missions m ON m.id = p.mission_id
                 WHERE p.timestamp >= ?1",
            )
            .map_err(err)?;
        let rows = stmt
            .query_map(params![&cutoff_iso], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, Option<String>>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, i64>(7)?,
                    r.get::<_, i64>(8)?,
                    r.get::<_, i64>(9)?,
                ))
            })
            .map_err(err)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(err)?;

        for (ts, model, provider, mission_id, backend, inp, out, cc, cr, cost_cents) in rows {
            let bucket = unix_minute_for_ts(&ts);
            let (pool_id, _) =
                resolve_inference_pool(provider.as_deref(), backend.as_deref(), &model);
            let mid = mission_id.unwrap_or_default();
            let root_id = if mid.is_empty() {
                String::new()
            } else {
                root_of(&mid)
            };
            let u_in = inp.max(0) as u64;
            let u_out = out.max(0) as u64;
            let u_cc = cc.max(0) as u64;
            let u_cr = cr.max(0) as u64;
            let est_mc =
                estimate_cost_millicents(&model, cost_cents.max(0) as u64, u_in, u_out, u_cc, u_cr);
            upsert_usage_rollup_row(
                conn,
                bucket,
                &pool_id,
                &root_id,
                &mid,
                &model,
                u_in + u_out + u_cc + u_cr,
                u_in + u_out + u_cc,
                u_out,
                1,
                0,
                est_mc,
            );
        }

        // 3b. Direct harness rows (`mission_events` not covered by `proxy_usage`)
        let mut hstmt = conn
            .prepare(
                "SELECT e.timestamp, e.mission_id, m.backend,
                        COALESCE(json_extract(e.metadata, '$.model'), ''),
                        COALESCE(json_extract(e.metadata, '$.model_normalized'), ''),
                        COALESCE(CAST(json_extract(e.metadata, '$.usage.input_tokens') AS INTEGER), 0),
                        COALESCE(CAST(json_extract(e.metadata, '$.usage.output_tokens') AS INTEGER), 0),
                        COALESCE(CAST(json_extract(e.metadata, '$.usage.cache_creation_input_tokens') AS INTEGER), 0),
                        COALESCE(CAST(json_extract(e.metadata, '$.usage.cache_read_input_tokens') AS INTEGER), 0),
                        COALESCE(CAST(json_extract(e.metadata, '$.cost_cents') AS INTEGER), 0)
                 FROM mission_events e
                 LEFT JOIN missions m ON m.id = e.mission_id
                 WHERE e.event_type = 'assistant_message'
                   AND e.timestamp >= ?1
                   AND NOT EXISTS (
                       SELECT 1 FROM proxy_usage p
                       WHERE p.mission_id = e.mission_id
                         AND (p.account_bound = 0 OR p.timestamp <= e.timestamp)
                   )",
            )
            .map_err(err)?;
        let hrows = hstmt
            .query_map(params![&cutoff_iso], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, i64>(7)?,
                    r.get::<_, i64>(8)?,
                    r.get::<_, i64>(9)?,
                ))
            })
            .map_err(err)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(err)?;

        for (ts, mid, backend, raw_model, norm_model, inp, out, cc, cr, cost_cents) in hrows {
            let model = if !raw_model.trim().is_empty() {
                crate::cost::normalized_model(raw_model.trim())
            } else {
                norm_model.trim().to_string()
            };
            let u_in = inp.max(0) as u64;
            let u_out = out.max(0) as u64;
            let u_cc = cc.max(0) as u64;
            let u_cr = cr.max(0) as u64;
            let total = u_in + u_out + u_cc + u_cr;
            if total == 0 && cost_cents <= 0 {
                continue;
            }
            let bucket = unix_minute_for_ts(&ts);
            let (pool_id, _) = resolve_inference_pool(None, backend.as_deref(), &model);
            let root_id = root_of(&mid);
            let est_mc =
                estimate_cost_millicents(&model, cost_cents.max(0) as u64, u_in, u_out, u_cc, u_cr);
            upsert_usage_rollup_row(
                conn,
                bucket,
                &pool_id,
                &root_id,
                &mid,
                &model,
                total,
                u_in + u_out + u_cc,
                u_out,
                1,
                0,
                est_mc,
            );
        }

        // 3c. Backfill 429 counts from proxy_outcomes
        if let Ok(mut ostmt) = conn.prepare(
            "SELECT timestamp, provider, COALESCE(model, '')
             FROM proxy_outcomes
             WHERE http_status = 429 AND timestamp >= ?1",
        ) {
            if let Ok(orows) = ostmt.query_map(params![&cutoff_iso], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, String>(2)?,
                ))
            }) {
                for row in orows.flatten() {
                    let bucket = unix_minute_for_ts(&row.0);
                    let (pool_id, _) = resolve_inference_pool(row.1.as_deref(), None, &row.2);
                    upsert_usage_rollup_row(
                        conn, bucket, &pool_id, "", "", &row.2, 0, 0, 0, 0, 1, 0,
                    );
                }
            }
        }
    }

    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn upsert_usage_rollup_row(
    conn: &Connection,
    bucket_unix_min: i64,
    pool_id: &str,
    root_mission_id: &str,
    mission_id: &str,
    model: &str,
    total_tokens: u64,
    billable_tokens: u64,
    output_tokens: u64,
    request_count: u64,
    rate_limit_429_count: u64,
    est_cost_millicents: u64,
) {
    let _ = conn.execute(
        "INSERT INTO usage_rollup_1m
            (bucket_unix_min, pool_id, root_mission_id, mission_id, model,
             total_tokens, billable_tokens, output_tokens, request_count,
             rate_limit_429_count, est_cost_millicents)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
         ON CONFLICT(bucket_unix_min, pool_id, root_mission_id, mission_id, model) DO UPDATE SET
            total_tokens = total_tokens + excluded.total_tokens,
            billable_tokens = billable_tokens + excluded.billable_tokens,
            output_tokens = output_tokens + excluded.output_tokens,
            request_count = request_count + excluded.request_count,
            rate_limit_429_count = rate_limit_429_count + excluded.rate_limit_429_count,
            est_cost_millicents = est_cost_millicents + excluded.est_cost_millicents",
        params![
            bucket_unix_min,
            pool_id,
            root_mission_id,
            mission_id,
            model,
            total_tokens as i64,
            billable_tokens as i64,
            output_tokens as i64,
            request_count as i64,
            rate_limit_429_count as i64,
            est_cost_millicents as i64,
        ],
    );
    maybe_prune_old_rollups(conn);
}

/// Live hook called from `sqlite_usage::record` inside the writer lock.
pub(crate) fn on_router_usage_sync(conn: &Connection, record: &ProxyUsageRecord) {
    let ts = record
        .observed_at
        .clone()
        .unwrap_or_else(|| Utc::now().to_rfc3339());
    let bucket = unix_minute_for_ts(&ts);
    let mid = record.mission_id.map(|u| u.to_string()).unwrap_or_default();
    let (root_id, backend) = if mid.is_empty() {
        (String::new(), None)
    } else {
        let b: Option<String> = conn
            .query_row(
                "SELECT backend FROM missions WHERE id = ?1",
                params![&mid],
                |r| r.get(0),
            )
            .optional()
            .ok()
            .flatten();
        (resolve_root_mission_id_sync(conn, &mid), b)
    };
    let (pool_id, _) = resolve_inference_pool(
        record.provider.as_deref(),
        backend.as_deref(),
        &record.model,
    );
    let total = record.input_tokens
        + record.output_tokens
        + record.cache_creation_tokens
        + record.cache_read_tokens;
    let billable = record.input_tokens + record.output_tokens + record.cache_creation_tokens;
    let est_mc = estimate_cost_millicents(
        &record.model,
        record.cost_cents,
        record.input_tokens,
        record.output_tokens,
        record.cache_creation_tokens,
        record.cache_read_tokens,
    );
    upsert_usage_rollup_row(
        conn,
        bucket,
        &pool_id,
        &root_id,
        &mid,
        &record.model,
        total,
        billable,
        record.output_tokens,
        1,
        0,
        est_mc,
    );
}

/// Live hook called from `sqlite/usage.rs` `record_proxy_outcome`.
pub(crate) fn on_proxy_outcome_sync(conn: &Connection, record: &ProxyOutcomeRecord) {
    if record.http_status != Some(429) {
        return;
    }
    let bucket = unix_minute_for_ts(&record.timestamp);
    let model = record.model.as_deref().unwrap_or("");
    let (pool_id, _) = resolve_inference_pool(record.provider.as_deref(), None, model);
    upsert_usage_rollup_row(conn, bucket, &pool_id, "", "", model, 0, 0, 0, 0, 1, 0);
}

fn is_native_subagent_tool_name(name: &str) -> bool {
    let bare = name
        .rsplit(['.', ':', '/'])
        .next()
        .unwrap_or(name)
        .trim()
        .to_ascii_lowercase();
    matches!(
        bare.as_str(),
        "task" | "agent" | "delegate_task" | "subagent" | "spawn_subagent" | "invoke_subagent"
    )
}

fn truncate_clean_label(raw: &str, max_chars: usize) -> String {
    let line = raw.lines().next().unwrap_or(raw).trim();
    if line.chars().count() <= max_chars {
        return line.to_string();
    }
    let mut out: String = line.chars().take(max_chars.saturating_sub(1)).collect();
    out.push('…');
    out
}

/// Live hook called from `sqlite/events.rs` `log_event_sync`.
pub(crate) fn on_event_logged_sync(
    conn: &Connection,
    mission_id: Uuid,
    timestamp: &str,
    event: &AgentEvent,
) {
    let mid = mission_id.to_string();
    match event {
        AgentEvent::ToolCall {
            tool_call_id,
            name,
            args,
            ..
        } if is_native_subagent_tool_name(name) => {
            let root_id = resolve_root_mission_id_sync(conn, &mid);
            let label = args
                .get("Role")
                .or_else(|| args.get("description"))
                .or_else(|| args.get("name"))
                .or_else(|| args.get("subagent_type"))
                .or_else(|| args.get("TypeName"))
                .and_then(|v| v.as_str())
                .map(|s| truncate_clean_label(s, 64))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| name.clone());
            let role = args
                .get("subagent_type")
                .or_else(|| args.get("TypeName"))
                .or_else(|| args.get("role"))
                .and_then(|v| v.as_str())
                .map(|s| truncate_clean_label(s, 32))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "subagent".to_string());
            let model = args
                .get("model")
                .or_else(|| args.get("Model"))
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty() && *s != "inherit")
                .map(str::to_string);
            let _ = conn.execute(
                "INSERT INTO mission_subagent_spans
                    (mission_id, tool_call_id, root_mission_id, name, role, model, state, started_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'running', ?7)
                 ON CONFLICT(mission_id, tool_call_id) DO UPDATE SET
                    name = excluded.name,
                    role = excluded.role,
                    model = COALESCE(excluded.model, mission_subagent_spans.model)",
                params![mid, tool_call_id, root_id, label, role, model, timestamp],
            );
        }
        AgentEvent::ToolResult {
            tool_call_id,
            name,
            result,
            ..
        } if is_native_subagent_tool_name(name) => {
            let failed = result
                .get("is_error")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
                || result.get("error").is_some();
            let next_state = if failed { "failed" } else { "done" };
            let _ = conn.execute(
                "UPDATE mission_subagent_spans
                 SET state = ?1, completed_at = COALESCE(completed_at, ?2)
                 WHERE mission_id = ?3 AND tool_call_id = ?4",
                params![next_state, timestamp, mid, tool_call_id],
            );
        }
        AgentEvent::AssistantMessage {
            cost_cents,
            usage: Some(usage),
            model,
            model_normalized,
            ..
        } => {
            // Mirror `sqlite_usage::harness_records` deduplication: skip when router already attributed
            let has_proxy: bool = conn
                .query_row(
                    "SELECT EXISTS(
                        SELECT 1 FROM proxy_usage p
                        WHERE p.mission_id = ?1
                          AND (p.account_bound = 0 OR p.timestamp <= ?2)
                    )",
                    params![&mid, timestamp],
                    |r| r.get(0),
                )
                .unwrap_or(false);
            if has_proxy {
                return;
            }
            let input = usage.input_tokens;
            let output = usage.output_tokens;
            let cc = usage.cache_creation_input_tokens.unwrap_or(0);
            let cr = usage.cache_read_input_tokens.unwrap_or(0);
            let total = input + output + cc + cr;
            if total == 0 && *cost_cents == 0 {
                return;
            }
            let model_key = model
                .as_deref()
                .filter(|s| !s.trim().is_empty())
                .map(crate::cost::normalized_model)
                .or_else(|| model_normalized.clone())
                .unwrap_or_default();
            let backend: Option<String> = conn
                .query_row(
                    "SELECT backend FROM missions WHERE id = ?1",
                    params![&mid],
                    |r| r.get(0),
                )
                .optional()
                .ok()
                .flatten();
            let root_id = resolve_root_mission_id_sync(conn, &mid);
            let (pool_id, _) = resolve_inference_pool(None, backend.as_deref(), &model_key);
            let bucket = unix_minute_for_ts(timestamp);
            let est_mc = estimate_cost_millicents(&model_key, *cost_cents, input, output, cc, cr);
            upsert_usage_rollup_row(
                conn,
                bucket,
                &pool_id,
                &root_id,
                &mid,
                &model_key,
                total,
                input + output + cc,
                output,
                1,
                0,
                est_mc,
            );
        }
        AgentEvent::MissionStatusChanged { status, .. } => {
            let status_s = status.to_string();
            let is_terminal = matches!(
                status_s.as_str(),
                "completed" | "acknowledged" | "failed" | "cancelled" | "interrupted"
            );
            if is_terminal {
                let root_id = resolve_root_mission_id_sync(conn, &mid);
                let _ = conn.execute(
                    "INSERT INTO mission_orchestration_meta
                        (mission_id, root_mission_id, queued_at, completed_at)
                     VALUES (?1, ?2, ?3, ?3)
                     ON CONFLICT(mission_id) DO UPDATE SET
                        completed_at = COALESCE(mission_orchestration_meta.completed_at, excluded.completed_at)",
                    params![mid, root_id, timestamp],
                );
            }
        }
        _ => {}
    }
}

/// Live hook called from `sqlite/runs.rs` when a mission run begins.
pub(crate) fn on_run_started_sync(conn: &Connection, run: &MissionRun) {
    let mid = run.mission_id.to_string();
    let root_id = resolve_root_mission_id_sync(conn, &mid);
    let placement = run
        .scope_unit
        .as_deref()
        .and_then(|s| {
            s.strip_prefix("remote-node:")
                .or_else(|| s.strip_prefix("remote:"))
        })
        .map(str::to_string);
    let _ = conn.execute(
        "INSERT INTO mission_orchestration_meta
            (mission_id, root_mission_id, queued_at, first_started_at, placement_node_id)
         VALUES (?1, ?2, ?3, ?3, ?4)
         ON CONFLICT(mission_id) DO UPDATE SET
            first_started_at = COALESCE(mission_orchestration_meta.first_started_at, excluded.first_started_at),
            placement_node_id = COALESCE(excluded.placement_node_id, mission_orchestration_meta.placement_node_id)",
        params![mid, root_id, run.started_at, placement],
    );
}

/// Live hook called from `sqlite/runs.rs` when a mission run finishes.
pub(crate) fn on_run_finished_sync(
    conn: &Connection,
    run_id: Uuid,
    ended_at: &str,
    terminal_reason: Option<&str>,
) {
    let row: Option<(String, String)> = conn
        .query_row(
            "SELECT mission_id, started_at FROM mission_runs WHERE run_id = ?1",
            params![run_id.to_string()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .ok()
        .flatten();
    let Some((mid, started_at)) = row else {
        return;
    };
    let delta_ms = match (
        parse_rfc3339_unix_secs(&started_at),
        parse_rfc3339_unix_secs(ended_at),
    ) {
        (Some(s), Some(e)) if e > s => (e - s) * 1_000,
        _ => 0,
    };
    let stall_kind = terminal_reason.and_then(|r| {
        if r.contains("rate_limit") || r.contains("429") || r.contains("quota") {
            Some("rate_limited")
        } else if r.contains("safety") || r.contains("content_filter") {
            Some("safety_filter")
        } else {
            None
        }
    });
    let root_id = resolve_root_mission_id_sync(conn, &mid);
    let _ = conn.execute(
        "INSERT INTO mission_orchestration_meta
            (mission_id, root_mission_id, queued_at, active_run_ms, stall_kind)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(mission_id) DO UPDATE SET
            active_run_ms = mission_orchestration_meta.active_run_ms + excluded.active_run_ms,
            stall_kind = COALESCE(excluded.stall_kind, mission_orchestration_meta.stall_kind)",
        params![mid, root_id, ended_at, delta_ms, stall_kind],
    );
}

impl SqliteMissionStore {
    pub(crate) async fn record_compute_samples_sqlite(
        &self,
        samples: &[ComputeMinuteSample],
    ) -> Result<(), String> {
        if samples.is_empty() {
            return Ok(());
        }
        let conn = self.conn.clone();
        let samples = samples.to_vec();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction().map_err(err)?;
            for s in &samples {
                tx.execute(
                    "INSERT INTO compute_rollup_1m
                        (bucket_unix_min, machine_class, node_id, root_mission_id, mission_id, state,
                         vcpu_allocated, vcpu_busy, ram_gb_allocated, cost_millicents)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                     ON CONFLICT(bucket_unix_min, node_id, mission_id, state) DO UPDATE SET
                        machine_class = excluded.machine_class,
                        root_mission_id = excluded.root_mission_id,
                        vcpu_allocated = excluded.vcpu_allocated,
                        vcpu_busy = excluded.vcpu_busy,
                        ram_gb_allocated = excluded.ram_gb_allocated,
                        cost_millicents = excluded.cost_millicents",
                    params![
                        s.bucket_unix_min,
                        s.machine_class,
                        s.node_id,
                        s.root_mission_id,
                        s.mission_id,
                        s.state,
                        s.vcpu_allocated,
                        s.vcpu_busy,
                        s.ram_gb_allocated,
                        s.cost_millicents,
                    ],
                )
                .map_err(err)?;
            }
            tx.commit().map_err(err)?;
            maybe_prune_old_rollups(&conn);
            Ok(())
        })
        .await
        .map_err(err)?
    }

    pub(crate) async fn query_resources_overview_sqlite(
        &self,
        since_unix_min: i64,
    ) -> Result<ResourcesStoreOverview, String> {
        let reader = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = reader.blocking_lock();
            let since_iso = DateTime::<Utc>::from_timestamp(since_unix_min * 60, 0)
                .unwrap_or_else(Utc::now)
                .to_rfc3339();

            // 1. Usage rollups in window
            let mut ustmt = conn
                .prepare(
                    "SELECT bucket_unix_min, pool_id, root_mission_id,
                            SUM(total_tokens), SUM(billable_tokens),
                            SUM(rate_limit_429_count), SUM(est_cost_millicents)
                     FROM usage_rollup_1m
                     WHERE bucket_unix_min >= ?1
                     GROUP BY bucket_unix_min, pool_id, root_mission_id",
                )
                .map_err(err)?;
            let usage_rows = ustmt
                .query_map(params![since_unix_min], |r| {
                    Ok(UsageRollupRow {
                        bucket_unix_min: r.get(0)?,
                        pool_id: r.get(1)?,
                        root_mission_id: r.get(2)?,
                        total_tokens: r.get::<_, i64>(3)?.max(0) as u64,
                        billable_tokens: r.get::<_, i64>(4)?.max(0) as u64,
                        rate_limit_429_count: r.get::<_, i64>(5)?.max(0) as u64,
                        est_cost_millicents: r.get::<_, i64>(6)?.max(0) as u64,
                    })
                })
                .map_err(err)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(err)?;

            // 2. Compute rollups in window
            let mut cstmt = conn
                .prepare(
                    "SELECT bucket_unix_min, machine_class, node_id, root_mission_id, state,
                            SUM(vcpu_allocated), SUM(cost_millicents)
                     FROM compute_rollup_1m
                     WHERE bucket_unix_min >= ?1
                     GROUP BY bucket_unix_min, machine_class, node_id, root_mission_id, state",
                )
                .map_err(err)?;
            let compute_rows = cstmt
                .query_map(params![since_unix_min], |r| {
                    Ok(ComputeRollupRow {
                        bucket_unix_min: r.get(0)?,
                        machine_class: r.get(1)?,
                        node_id: r.get(2)?,
                        root_mission_id: r.get(3)?,
                        state: r.get(4)?,
                        vcpu_allocated: r.get(5)?,
                        cost_millicents: r.get::<_, i64>(6)?.max(0) as u64,
                    })
                })
                .map_err(err)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(err)?;

            // 3. Parent map for root attribution
            let mut parents: HashMap<String, String> = HashMap::new();
            {
                let mut pstmt = conn
                    .prepare(
                        "SELECT id, parent_mission_id FROM missions WHERE parent_mission_id IS NOT NULL",
                    )
                    .map_err(err)?;
                let prows = pstmt
                    .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
                    .map_err(err)?;
                for row in prows.flatten() {
                    parents.insert(row.0, row.1);
                }
            }
            let root_of = |mid: &str| -> String {
                let mut cur = mid;
                for _ in 0..16 {
                    match parents.get(cur) {
                        Some(p) if !p.is_empty() && p != mid && p != cur => cur = p.as_str(),
                        _ => break,
                    }
                }
                cur.to_string()
            };

            let mut mission_roots: HashMap<String, String> = HashMap::new();
            for child in parents.keys() {
                mission_roots.insert(child.clone(), root_of(child));
            }

            // 4. Active runs right now (for live current-minute compute attribution)
            let mut rstmt = conn
                .prepare(
                    "SELECT r.mission_id, om.placement_node_id, om.placement_node_id, r.scope_unit, m.status
                     FROM mission_runs r
                     JOIN missions m ON m.id = r.mission_id
                     LEFT JOIN mission_orchestration_meta om ON om.mission_id = r.mission_id
                     WHERE r.execution_state <> 'terminal'",
                )
                .map_err(err)?;
            let active_runs = rstmt
                .query_map([], |r| {
                    let mid: String = r.get(0)?;
                    let root = root_of(&mid);
                    Ok(ActiveRunAttributionRow {
                        mission_id: mid,
                        root_mission_id: root,
                        remote_node_id: r.get(1)?,
                        placement_node_id: r.get(2)?,
                        scope_unit: r.get(3)?,
                        status: r.get(4)?,
                    })
                })
                .map_err(err)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(err)?;

            // 5. Subagent counts per root mission (both child missions + native spans)
            let mut sub_counts: HashMap<String, (u32, u32)> = HashMap::new();
            {
                let mut ch_stmt = conn
                    .prepare(
                        "SELECT id, status FROM missions WHERE parent_mission_id IS NOT NULL",
                    )
                    .map_err(err)?;
                let ch_rows = ch_stmt
                    .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
                    .map_err(err)?;
                for row in ch_rows.flatten() {
                    let root = root_of(&row.0);
                    let entry = sub_counts.entry(root).or_insert((0, 0));
                    entry.1 += 1;
                    if matches!(
                        row.1.as_str(),
                        "active" | "pending" | "waiting_background"
                    ) {
                        entry.0 += 1;
                    }
                }
            }
            {
                let mut sp_stmt = conn
                    .prepare(
                        "SELECT root_mission_id, state FROM mission_subagent_spans",
                    )
                    .map_err(err)?;
                let sp_rows = sp_stmt
                    .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
                    .map_err(err)?;
                for row in sp_rows.flatten() {
                    let entry = sub_counts.entry(row.0).or_insert((0, 0));
                    entry.1 += 1;
                    if row.1 == "running" {
                        entry.0 += 1;
                    }
                }
            }

            // 6. Candidate root IDs from rollups, active runs, and live/recent root missions
            let mut referenced_roots: HashSet<String> = HashSet::new();
            for u in &usage_rows {
                if !u.root_mission_id.is_empty() {
                    referenced_roots.insert(u.root_mission_id.clone());
                }
            }
            for c in &compute_rows {
                if !c.root_mission_id.is_empty() {
                    referenced_roots.insert(c.root_mission_id.clone());
                }
            }
            for ar in &active_runs {
                referenced_roots.insert(ar.root_mission_id.clone());
            }

            let mut mstmt = conn
                .prepare(
                    "SELECT m.id, COALESCE(NULLIF(TRIM(m.title), ''), 'Untitled mission'),
                            m.project, m.status, m.backend, om.placement_node_id,
                            m.created_at, m.updated_at,
                            om.first_started_at, om.completed_at, om.stall_kind
                     FROM missions m
                     LEFT JOIN mission_orchestration_meta om ON om.mission_id = m.id
                     WHERE m.parent_mission_id IS NULL
                       AND (m.updated_at >= ?1 OR m.status IN ('pending', 'active', 'waiting_background', 'blocked'))
                     ORDER BY m.updated_at DESC
                     LIMIT 250",
                )
                .map_err(err)?;
            let mut root_map: HashMap<String, RootMissionResourceRow> = HashMap::new();
            let mrows = mstmt
                .query_map(params![&since_iso], |r| {
                    let id: String = r.get(0)?;
                    let (running, total) = sub_counts.get(&id).copied().unwrap_or((0, 0));
                    Ok(RootMissionResourceRow {
                        id,
                        title: r.get(1)?,
                        project: r.get(2)?,
                        status: r.get(3)?,
                        backend: r.get(4)?,
                        remote_node_id: r.get(5)?,
                        created_at: r.get(6)?,
                        updated_at: r.get(7)?,
                        first_started_at: r.get(8)?,
                        completed_at: r.get(9)?,
                        stall_kind: r.get(10)?,
                        subagent_running: running,
                        subagent_total: total,
                        eta_remaining_secs: None,
                    })
                })
                .map_err(err)?;
            for row in mrows.flatten() {
                mission_roots.entry(row.id.clone()).or_insert_with(|| row.id.clone());
                root_map.insert(row.id.clone(), row);
            }

            // Ensure any root referenced in usage/compute rollups whose updated_at was older is still fetched
            for missing_id in referenced_roots {
                if root_map.contains_key(&missing_id) {
                    continue;
                }
                if let Some(row) = conn
                    .query_row(
                        "SELECT m.id, COALESCE(NULLIF(TRIM(m.title), ''), 'Untitled mission'),
                                m.project, m.status, m.backend, om.placement_node_id,
                                m.created_at, m.updated_at,
                                om.first_started_at, om.completed_at, om.stall_kind
                         FROM missions m
                         LEFT JOIN mission_orchestration_meta om ON om.mission_id = m.id
                         WHERE m.id = ?1",
                        params![&missing_id],
                        |r| {
                            let id: String = r.get(0)?;
                            let (running, total) = sub_counts.get(&id).copied().unwrap_or((0, 0));
                            Ok(RootMissionResourceRow {
                                id,
                                title: r.get(1)?,
                                project: r.get(2)?,
                                status: r.get(3)?,
                                backend: r.get(4)?,
                                remote_node_id: r.get(5)?,
                                created_at: r.get(6)?,
                                updated_at: r.get(7)?,
                                first_started_at: r.get(8)?,
                                completed_at: r.get(9)?,
                                stall_kind: r.get(10)?,
                                subagent_running: running,
                                subagent_total: total,
                                eta_remaining_secs: None,
                            })
                        },
                    )
                    .optional()
                    .map_err(err)?
                {
                    root_map.insert(row.id.clone(), row);
                }
            }

            Ok(ResourcesStoreOverview {
                usage_rows,
                compute_rows,
                root_missions: root_map.into_values().collect(),
                active_runs,
                mission_roots,
            })
        })
        .await
        .map_err(err)?
    }

    pub(crate) async fn query_mission_resources_sqlite(
        &self,
        mission_id: Uuid,
        since_unix_min: i64,
    ) -> Result<Option<MissionResourcesStoreSnapshot>, String> {
        let reader = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = reader.blocking_lock();
            let target_id = mission_id.to_string();
            let root_id = resolve_root_mission_id_sync(&conn, &target_id);

            let parse_node = |r: &rusqlite::Row<'_>| -> Result<MissionNodeRow, rusqlite::Error> {
                let deps_raw: Option<String> = r.get(12)?;
                let depends_on: Vec<String> = deps_raw
                    .as_deref()
                    .and_then(|s| serde_json::from_str(s).ok())
                    .unwrap_or_default();
                Ok(MissionNodeRow {
                    id: r.get(0)?,
                    parent_mission_id: r.get(1)?,
                    title: r.get(2)?,
                    project: r.get(3)?,
                    track: r.get(4)?,
                    status: r.get(5)?,
                    backend: r.get(6)?,
                    model_override: r.get(7)?,
                    remote_node_id: r.get(8)?,
                    created_at: r.get(9)?,
                    updated_at: r.get(10)?,
                    terminal_reason: r.get(11)?,
                    depends_on,
                    role: r.get(13)?,
                    first_started_at: r.get(14)?,
                    completed_at: r.get(15)?,
                    active_run_ms: r.get::<_, Option<i64>>(16)?.unwrap_or(0),
                    placement_node_id: r.get(17)?,
                    stall_kind: r.get(18)?,
                    eta_remaining_secs: None,
                    eta_basis: None,
                })
            };

            let Some(root) = conn
                .query_row(
                    "SELECT m.id, m.parent_mission_id,
                            COALESCE(NULLIF(TRIM(m.title), ''), 'Untitled mission'),
                            m.project, m.track, m.status, m.backend, m.model_override,
                            om.placement_node_id, m.created_at, m.updated_at, m.terminal_reason,
                            om.depends_on_json, om.role, om.first_started_at, om.completed_at,
                            om.active_run_ms, om.placement_node_id, om.stall_kind
                     FROM missions m
                     LEFT JOIN mission_orchestration_meta om ON om.mission_id = m.id
                     WHERE m.id = ?1",
                    params![&root_id],
                    parse_node,
                )
                .optional()
                .map_err(err)?
            else {
                return Ok(None);
            };

            // Recursive CTE to gather all descendant missions under `root_id`
            let mut dstmt = conn
                .prepare(
                    "WITH RECURSIVE tree(id, depth) AS (
                        SELECT id, 1 FROM missions WHERE parent_mission_id = ?1
                        UNION ALL
                        SELECT m.id, tree.depth + 1
                        FROM missions m
                        JOIN tree ON m.parent_mission_id = tree.id
                        WHERE tree.depth < 8
                     )
                     SELECT m.id, m.parent_mission_id,
                            COALESCE(NULLIF(TRIM(m.title), ''), 'Subagent'),
                            m.project, m.track, m.status, m.backend, m.model_override,
                            om.placement_node_id, m.created_at, m.updated_at, m.terminal_reason,
                            om.depends_on_json, om.role, om.first_started_at, om.completed_at,
                            om.active_run_ms, om.placement_node_id, om.stall_kind
                     FROM tree
                     JOIN missions m ON m.id = tree.id
                     LEFT JOIN mission_orchestration_meta om ON om.mission_id = m.id
                     ORDER BY m.created_at ASC",
                )
                .map_err(err)?;
            let mut children = dstmt
                .query_map(params![&root_id], parse_node)
                .map_err(err)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(err)?;

            let mut all_ids: Vec<String> = Vec::with_capacity(children.len() + 1);
            all_ids.push(root.id.clone());
            for c in &children {
                all_ids.push(c.id.clone());
            }

            // Cohort P50 duration (in seconds) from settled sibling/project runs for ETA estimation
            let mut settled_secs: Vec<i64> = children
                .iter()
                .filter_map(|c| {
                    let s = parse_rfc3339_unix_secs(c.first_started_at.as_deref().unwrap_or(&c.created_at))?;
                    let e = parse_rfc3339_unix_secs(c.completed_at.as_deref()?)?;
                    (e > s).then_some(e - s)
                })
                .collect();
            settled_secs.sort_unstable();
            let cohort_p50_secs = if settled_secs.len() >= 2 {
                settled_secs[settled_secs.len() / 2].clamp(60, 14_400)
            } else {
                900 // 15m default wave task estimate when fewer than 2 siblings have settled
            };

            let now_secs = Utc::now().timestamp();
            for c in &mut children {
                if matches!(c.status.as_str(), "active" | "waiting_background") {
                    let start_s = parse_rfc3339_unix_secs(
                        c.first_started_at.as_deref().unwrap_or(&c.created_at),
                    )
                    .unwrap_or(now_secs);
                    let elapsed = (now_secs - start_s).max(0);
                    let rem = if elapsed < cohort_p50_secs {
                        (cohort_p50_secs - elapsed).max(60)
                    } else {
                        (elapsed / 3).clamp(90, 1_800)
                    };
                    c.eta_remaining_secs = Some(rem);
                    c.eta_basis = Some(if settled_secs.len() >= 2 {
                        "cohort_p50".to_string()
                    } else {
                        "hint".to_string()
                    });
                }
            }

            // Board tasks for the root (and any coordinator child)
            let mut bstmt = conn
                .prepare(
                    "SELECT id, boss_mission_id, task_key, title, backend, model_override,
                            role, depends_on, status, worker_mission_id, created_at, updated_at
                     FROM board_tasks
                     WHERE boss_mission_id = ?1
                     ORDER BY created_at ASC",
                )
                .map_err(err)?;
            let board_tasks = bstmt
                .query_map(params![&root_id], |r| {
                    let deps_raw: String = r.get(7)?;
                    let depends_on: Vec<String> =
                        serde_json::from_str(&deps_raw).unwrap_or_default();
                    Ok(BoardTaskResourceRow {
                        id: r.get(0)?,
                        boss_mission_id: r.get(1)?,
                        task_key: r.get(2)?,
                        title: r.get(3)?,
                        backend: r.get(4)?,
                        model_override: r.get(5)?,
                        role: r.get(6)?,
                        depends_on,
                        status: r.get(8)?,
                        worker_mission_id: r.get(9)?,
                        created_at: r.get(10)?,
                        updated_at: r.get(11)?,
                    })
                })
                .map_err(err)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(err)?;

            // Native subagent spans under this root
            let mut sstmt = conn
                .prepare(
                    "SELECT mission_id, tool_call_id, name, role, model, state, started_at, completed_at
                     FROM mission_subagent_spans
                     WHERE root_mission_id = ?1
                     ORDER BY started_at ASC",
                )
                .map_err(err)?;
            let native_spans = sstmt
                .query_map(params![&root_id], |r| {
                    Ok(NativeSubagentSpanRow {
                        mission_id: r.get(0)?,
                        tool_call_id: r.get(1)?,
                        name: r.get(2)?,
                        role: r.get(3)?,
                        model: r.get(4)?,
                        state: r.get(5)?,
                        started_at: r.get(6)?,
                        completed_at: r.get(7)?,
                    })
                })
                .map_err(err)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(err)?;

            // Run intervals for root + children
            let id_set: HashSet<&str> = all_ids.iter().map(String::as_str).collect();
            let mut run_intervals = Vec::new();
            {
                let mut rstmt = conn
                    .prepare(
                        "SELECT r.mission_id, r.started_at, r.ended_at, r.scope_unit, r.terminal_reason
                         FROM mission_runs r
                         JOIN missions m ON m.id = r.mission_id
                         WHERE m.id = ?1 OR m.parent_mission_id = ?1
                            OR EXISTS (
                                SELECT 1 FROM mission_orchestration_meta om
                                WHERE om.mission_id = r.mission_id AND om.root_mission_id = ?1
                            )
                         ORDER BY r.started_at ASC",
                    )
                    .map_err(err)?;
                let rrows = rstmt
                    .query_map(params![&root_id], |r| {
                        Ok(MissionRunIntervalRow {
                            mission_id: r.get(0)?,
                            started_at: r.get(1)?,
                            ended_at: r.get(2)?,
                            scope_unit: r.get(3)?,
                            terminal_reason: r.get(4)?,
                        })
                    })
                    .map_err(err)?;
                for row in rrows.flatten() {
                    if id_set.contains(row.mission_id.as_str()) {
                        run_intervals.push(row);
                    }
                }
            }

            // Per-mission usage rollup buckets
            let mut ustmt = conn
                .prepare(
                    "SELECT bucket_unix_min, pool_id, mission_id, model,
                            SUM(total_tokens), SUM(est_cost_millicents), SUM(rate_limit_429_count)
                     FROM usage_rollup_1m
                     WHERE root_mission_id = ?1 AND bucket_unix_min >= ?2
                     GROUP BY bucket_unix_min, pool_id, mission_id, model",
                )
                .map_err(err)?;
            let usage_by_mission = ustmt
                .query_map(params![&root_id, since_unix_min], |r| {
                    Ok(MissionUsageBucketRow {
                        bucket_unix_min: r.get(0)?,
                        pool_id: r.get(1)?,
                        mission_id: r.get(2)?,
                        model: r.get(3)?,
                        total_tokens: r.get::<_, i64>(4)?.max(0) as u64,
                        est_cost_millicents: r.get::<_, i64>(5)?.max(0) as u64,
                        rate_limit_429_count: r.get::<_, i64>(6)?.max(0) as u64,
                    })
                })
                .map_err(err)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(err)?;

            // Per-mission compute rollup buckets
            let mut cstmt = conn
                .prepare(
                    "SELECT bucket_unix_min, machine_class, node_id, mission_id, state,
                            SUM(vcpu_allocated), SUM(cost_millicents)
                     FROM compute_rollup_1m
                     WHERE root_mission_id = ?1 AND bucket_unix_min >= ?2
                     GROUP BY bucket_unix_min, machine_class, node_id, mission_id, state",
                )
                .map_err(err)?;
            let compute_by_mission = cstmt
                .query_map(params![&root_id, since_unix_min], |r| {
                    Ok(MissionComputeBucketRow {
                        bucket_unix_min: r.get(0)?,
                        machine_class: r.get(1)?,
                        node_id: r.get(2)?,
                        mission_id: r.get(3)?,
                        state: r.get(4)?,
                        vcpu_allocated: r.get(5)?,
                        cost_millicents: r.get::<_, i64>(6)?.max(0) as u64,
                    })
                })
                .map_err(err)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(err)?;

            Ok(Some(MissionResourcesStoreSnapshot {
                root,
                children,
                board_tasks,
                native_spans,
                run_intervals,
                usage_by_mission,
                compute_by_mission,
                cohort_p50_secs,
            }))
        })
        .await
        .map_err(err)?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::control::AgentEvent;
    use crate::api::mission_store::{
        BoardTaskRole, MissionStore, NewBoardTask, ProxyOutcomeRecord, ProxyUsageRecord,
    };
    use serde_json::json;

    #[tokio::test]
    async fn live_hooks_and_backfill_populate_rollups_and_mission_dag() {
        let dir = tempfile::tempdir().unwrap();
        let store = SqliteMissionStore::new(dir.path().into(), "resources-test")
            .await
            .unwrap();

        let root = store
            .create_mission(
                Some("Maxwell Kernel Campaign"),
                None,
                None,
                None,
                None,
                Some("claudecode"),
                None,
            )
            .await
            .unwrap();

        let child = store
            .create_mission_with_parent(
                Some("Proof Shard 01"),
                None,
                None,
                None,
                None,
                false,
                Some("opencode"),
                None,
                Some(root.id),
                None,
            )
            .await
            .unwrap();

        // Start a run on child so first_started_at is tracked
        let run = store
            .begin_mission_run(child.id, "actor-1", None)
            .await
            .unwrap();
        store
            .finish_mission_run(run.run_id, run.generation, Some("completed"))
            .await
            .unwrap();

        // Board tasks on boss mission with depends_on
        let tasks = store
            .upsert_board_tasks(
                root.id,
                vec![
                    NewBoardTask {
                        task_key: "t1".to_string(),
                        title: "Spec review".to_string(),
                        prompt: "Review spec".to_string(),
                        backend: "claudecode".to_string(),
                        role: BoardTaskRole::Reviewer,
                        ..Default::default()
                    },
                    NewBoardTask {
                        task_key: "t2".to_string(),
                        title: "Verify proof".to_string(),
                        prompt: "Verify".to_string(),
                        backend: "opencode".to_string(),
                        role: BoardTaskRole::Reconciler,
                        depends_on: vec!["t1".to_string()],
                        ..Default::default()
                    },
                ],
            )
            .await
            .unwrap();
        assert_eq!(tasks.len(), 2);

        let now_iso = Utc::now().to_rfc3339();
        let now_min = unix_minute_for_ts(&now_iso);

        // Router proxy usage attributed to child (should roll up under root.id)
        store
            .record_proxy_usage_attributed(&ProxyUsageRecord {
                observed_at: Some(now_iso.clone()),
                model: "claude-sonnet-4-5".to_string(),
                provider: Some("anthropic".to_string()),
                mission_id: Some(child.id),
                input_tokens: 50_000,
                output_tokens: 10_000,
                cache_creation_tokens: 5_000,
                cache_read_tokens: 20_000,
                cost_cents: 42,
                ..Default::default()
            })
            .await
            .unwrap();

        // 429 rate-limit outcome on anthropic pool
        store
            .record_proxy_outcome(&ProxyOutcomeRecord {
                timestamp: now_iso.clone(),
                chain_id: "anthropic/claude-sonnet-4-5".to_string(),
                provider: Some("anthropic".to_string()),
                model: Some("claude-sonnet-4-5".to_string()),
                status: "client_error".to_string(),
                http_status: Some(429),
                ..Default::default()
            })
            .await
            .unwrap();

        // Native subagent tool call + result on root
        store
            .log_event(
                root.id,
                &AgentEvent::ToolCall {
                    tool_call_id: "tc-sub-1".to_string(),
                    name: "invoke_subagent".to_string(),
                    args: json!({
                        "Role": "Lemma Explorer",
                        "TypeName": "research",
                        "Model": "gemini-2.5-pro"
                    }),
                    mission_id: Some(root.id),
                },
            )
            .await
            .unwrap();
        store
            .log_event(
                root.id,
                &AgentEvent::ToolResult {
                    tool_call_id: "tc-sub-1".to_string(),
                    name: "invoke_subagent".to_string(),
                    result: json!({ "output": "done" }),
                    mission_id: Some(root.id),
                },
            )
            .await
            .unwrap();

        // Compute sample attributed to child under root
        store
            .record_compute_samples(&[ComputeMinuteSample {
                bucket_unix_min: now_min,
                machine_class: "ephemeral_hetzner".to_string(),
                node_id: "hz-cpx51-1".to_string(),
                root_mission_id: root.id.to_string(),
                mission_id: child.id.to_string(),
                state: "busy".to_string(),
                vcpu_allocated: 16.0,
                vcpu_busy: 14.5,
                ram_gb_allocated: 32.0,
                cost_millicents: 1_200,
            }])
            .await
            .unwrap();

        // Query overview
        let ov = store.query_resources_overview(now_min - 60).await.unwrap();
        let total_tok: u64 = ov
            .usage_rows
            .iter()
            .filter(|r| r.root_mission_id == root.id.to_string())
            .map(|r| r.total_tokens)
            .sum();
        assert_eq!(total_tok, 85_000);
        let rl_429: u64 = ov
            .usage_rows
            .iter()
            .filter(|r| r.pool_id == "anthropic:claude")
            .map(|r| r.rate_limit_429_count)
            .sum();
        assert_eq!(rl_429, 1);
        assert_eq!(ov.compute_rows.len(), 1);
        assert_eq!(ov.compute_rows[0].vcpu_allocated, 16.0);

        // Query mission resources snapshot
        let msnap = store
            .query_mission_resources(root.id, now_min - 60)
            .await
            .unwrap()
            .expect("mission snapshot exists");
        assert_eq!(msnap.root.id, root.id.to_string());
        assert_eq!(msnap.children.len(), 1);
        assert_eq!(msnap.children[0].id, child.id.to_string());
        assert_eq!(msnap.board_tasks.len(), 2);
        assert_eq!(msnap.native_spans.len(), 1);
        assert_eq!(msnap.native_spans[0].name, "Lemma Explorer");
        assert_eq!(msnap.native_spans[0].state, "done");

        // Verify startup backfill restores usage_rollup_1m if cleared
        {
            let conn = store.conn.lock().await;
            conn.execute_batch("DELETE FROM usage_rollup_1m;").unwrap();
            backfill_recent_sync(&conn).unwrap();
        }
        let ov_after = store.query_resources_overview(now_min - 60).await.unwrap();
        let backfilled_tok: u64 = ov_after
            .usage_rows
            .iter()
            .filter(|r| r.root_mission_id == root.id.to_string())
            .map(|r| r.total_tokens)
            .sum();
        assert_eq!(backfilled_tok, 85_000);
    }
}
