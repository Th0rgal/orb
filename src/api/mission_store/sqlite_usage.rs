//! Usage ledger reads and router attribution for the SQLite mission store.
//!
//! Kept apart from `sqlite.rs` so the usage analytics schema and queries can
//! evolve without touching the main store. `proxy_usage` gains attribution
//! columns here; `records` returns harness and router rows unaggregated so
//! `crate::api::usage_summary` can filter and group them in one place.
use super::SqliteMissionStore;
use crate::api::mission_store::{ProxyUsageRecord, UsageRecord, UsageSource};
use rusqlite::{params, Connection};

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// Columns added to `proxy_usage` for attribution. The cache columns are in
/// the base schema but are listed so databases created before them migrate.
const PROXY_USAGE_COLUMNS: &[(&str, &str)] = &[
    ("cache_creation_tokens", "INTEGER NOT NULL DEFAULT 0"),
    ("cache_read_tokens", "INTEGER NOT NULL DEFAULT 0"),
    ("provider", "TEXT"),
    ("account_id", "TEXT"),
    ("account_bound", "INTEGER NOT NULL DEFAULT 0"),
    ("api_key_id", "TEXT"),
    ("api_key_name", "TEXT"),
    ("mission_id", "TEXT"),
    ("caller_kind", "TEXT"),
    ("purpose", "TEXT"),
    ("reasoning_tokens", "INTEGER NOT NULL DEFAULT 0"),
];

/// Add the attribution columns and their indexes. Idempotent, and tolerant of
/// a concurrent store init running the same ALTER.
pub(super) fn migrate(conn: &Connection) -> Result<(), String> {
    for (column, ddl) in PROXY_USAGE_COLUMNS {
        let exists = conn
            .prepare("SELECT 1 FROM pragma_table_info('proxy_usage') WHERE name = ?1")
            .map_err(err)?
            .exists(params![column])
            .map_err(err)?;
        if exists {
            continue;
        }
        tracing::info!(column, "Running migration: adding proxy_usage column");
        match conn.execute(
            &format!("ALTER TABLE proxy_usage ADD COLUMN {column} {ddl}"),
            [],
        ) {
            Ok(_) => {}
            Err(e) if e.to_string().contains("duplicate column") => {}
            Err(e) => return Err(format!("Failed to add proxy_usage.{column}: {e}")),
        }
    }
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_proxy_usage_api_key ON proxy_usage(api_key_id, timestamp);
         CREATE INDEX IF NOT EXISTS idx_proxy_usage_mission ON proxy_usage(mission_id);",
    )
    .map_err(err)
}

pub(super) async fn record(
    store: &SqliteMissionStore,
    record: &ProxyUsageRecord,
) -> Result<(), String> {
    let conn = store.conn.lock().await;
    conn.execute(
        "INSERT INTO proxy_usage (timestamp, model, input_tokens, output_tokens,
            cache_creation_tokens, cache_read_tokens, cost_cents,
            provider, account_id, api_key_id, api_key_name, mission_id,
            caller_kind, purpose, reasoning_tokens, account_bound)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
        params![
            record
                .observed_at
                .clone()
                .unwrap_or_else(|| chrono::Utc::now().to_rfc3339()),
            record.model,
            record.input_tokens as i64,
            record.output_tokens as i64,
            record.cache_creation_tokens as i64,
            record.cache_read_tokens as i64,
            record.cost_cents as i64,
            record.provider,
            record.account_id.map(|id| id.to_string()),
            record.api_key_id.map(|id| id.to_string()),
            record.api_key_name,
            record.mission_id.map(|id| id.to_string()),
            record.caller_kind,
            record.purpose,
            record.reasoning_tokens as i64,
            record.account_bound,
        ],
    )
    .map_err(err)?;
    Ok(())
}

fn non_negative(value: i64) -> u64 {
    value.max(0) as u64
}

fn token_usage(input: u64, output: u64, creation: u64, read: u64) -> crate::cost::TokenUsage {
    crate::cost::TokenUsage {
        input_tokens: input,
        output_tokens: output,
        cache_creation_input_tokens: Some(creation),
        cache_read_input_tokens: Some(read),
    }
}

/// Router cost: re-price from tokens when the model has a price (corrects
/// rows written before it had one), else keep the stored value and flag it.
fn router_cost(model: &str, stored: u64, usage: &crate::cost::TokenUsage) -> (u64, bool) {
    if crate::cost::has_pricing(model) {
        (crate::cost::cost_cents_from_usage(model, usage), true)
    } else {
        (stored, !usage.has_usage())
    }
}

pub(super) async fn records(
    store: &SqliteMissionStore,
    since: Option<&str>,
) -> Result<Vec<UsageRecord>, String> {
    let conn = store.reader();
    let since = since.map(str::to_string);
    tokio::task::spawn_blocking(move || {
        let conn = conn.blocking_lock();
        let mut out = harness_records(&conn, since.as_deref())?;
        out.extend(router_records(&conn, since.as_deref())?);
        let parents = mission_parents(&conn)?;
        for r in &mut out {
            r.root_mission_id = r.mission_id.as_deref().map(|m| root_of(&parents, m));
        }
        out.sort_by(|a, b| a.timestamp.cmp(&b.timestamp));
        Ok(out)
    })
    .await
    .map_err(err)?
}

/// `mission id -> parent id` for every mission that has a parent.
fn mission_parents(conn: &Connection) -> Result<std::collections::HashMap<String, String>, String> {
    let mut stmt = conn
        .prepare("SELECT id, parent_mission_id FROM missions WHERE parent_mission_id IS NOT NULL")
        .map_err(err)?;
    let rows = stmt
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(err)?;
    rows.collect::<Result<_, _>>().map_err(err)
}

/// Walk parents to the top-level mission (bounded, cycle-safe).
fn root_of(parents: &std::collections::HashMap<String, String>, mission: &str) -> String {
    let mut current = mission;
    for _ in 0..16 {
        match parents.get(current) {
            Some(parent) if parent != mission => current = parent,
            _ => break,
        }
    }
    current.to_string()
}

/// Caller kind of a legacy router row written before `caller_kind` existed,
/// derived from the stored key the same way the proxy derives it live.
fn legacy_caller_kind(api_key_name: Option<&str>, mission_id: Option<&str>) -> &'static str {
    use crate::api::usage_attribution::{principal_for, CallerKind};
    let internal = api_key_name.is_none();
    match principal_for(api_key_name, internal).kind {
        CallerKind::Core if mission_id.is_some() => CallerKind::Mission.as_str(),
        kind => kind.as_str(),
    }
}

/// Harness rows are the `harness_direct` route: usage a harness reported
/// for traffic that did not go through Core's proxy. A mission with any
/// legacy unbound proxied traffic retains its existing proxy-only aggregation.
/// New bound traffic takes over from its first server observation, before the
/// response is forwarded: migrating an old native mission must not hide its
/// earlier direct usage, and asynchronous storage must not double-count its
/// later harness completion. Returning to direct routing within that same
/// mission still requires explicit per-turn provenance (not inferred here).
fn harness_records(conn: &Connection, since: Option<&str>) -> Result<Vec<UsageRecord>, String> {
    let sql = r#"
        SELECT
            e.timestamp,
            e.mission_id,
            e.id AS event_row,
            m.backend,
            m.title,
            COALESCE(json_extract(e.metadata, '$.model'), '') AS raw_model,
            COALESCE(json_extract(e.metadata, '$.model_normalized'), '') AS stored_model,
            COALESCE(CAST(json_extract(e.metadata, '$.usage.input_tokens') AS INTEGER), 0),
            COALESCE(CAST(json_extract(e.metadata, '$.usage.output_tokens') AS INTEGER), 0),
            COALESCE(CAST(json_extract(e.metadata, '$.usage.cache_creation_input_tokens') AS INTEGER), 0),
            COALESCE(CAST(json_extract(e.metadata, '$.usage.cache_read_input_tokens') AS INTEGER), 0),
            COALESCE(json_extract(e.metadata, '$.cost.source'), ''),
            CAST(COALESCE(
                json_extract(e.metadata, '$.cost.amount_cents'),
                json_extract(e.metadata, '$.cost_cents'),
                0
            ) AS INTEGER)
            , m.parent_mission_id
        FROM mission_events e
        LEFT JOIN missions m ON m.id = e.mission_id
        WHERE e.event_type = 'assistant_message' AND (?1 IS NULL OR e.timestamp >= ?1)
          AND NOT EXISTS (SELECT 1 FROM proxy_usage p WHERE p.mission_id = e.mission_id
              AND (p.account_bound = 0 OR p.timestamp <= e.timestamp))
    "#;
    let mut stmt = conn.prepare(sql).map_err(err)?;
    let rows = stmt
        .query_map(params![since], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
                [
                    row.get::<_, i64>(7)?,
                    row.get::<_, i64>(8)?,
                    row.get::<_, i64>(9)?,
                    row.get::<_, i64>(10)?,
                ],
                row.get::<_, String>(11)?,
                row.get::<_, i64>(12)?,
                row.get::<_, Option<String>>(13)?,
                row.get::<_, i64>(2)?,
            ))
        })
        .map_err(err)?;
    let mut out = Vec::new();
    for row in rows {
        let (
            timestamp,
            mission_id,
            backend,
            title,
            raw,
            stored,
            tokens,
            source,
            cost,
            parent,
            row_id,
        ) = row.map_err(err)?;
        let model = super::usage_model_key(&raw, &stored);
        let [input, output, creation, read] = tokens.map(non_negative);
        let stored_cost = non_negative(cost);
        let usage = token_usage(input, output, creation, read);
        if model.is_empty() && !usage.has_usage() && stored_cost == 0 {
            continue;
        }
        let cost_cents = super::usage_cost_with_read_side_estimate(
            &model,
            stored_cost,
            &source,
            input,
            output,
            creation,
            read,
        );
        let cost_known = (source == "actual" && stored_cost > 0)
            || crate::cost::has_pricing(&model)
            || !usage.has_usage();
        out.push(UsageRecord {
            request_id: Some(format!("event:{row_id}")),
            timestamp,
            source: UsageSource::Harness,
            model,
            provider: None,
            backend,
            mission_id: Some(mission_id),
            mission_title: title,
            root_mission_id: None,
            caller_kind: if parent.is_some() {
                "subagent"
            } else {
                "mission"
            }
            .to_string(),
            purpose: None,
            api_key_id: None,
            api_key_name: None,
            account_id: None,
            account_bound: false,
            input_tokens: input,
            output_tokens: output,
            cache_creation_tokens: creation,
            cache_read_tokens: read,
            reasoning_tokens: 0,
            cost_cents,
            cost_known,
        });
    }
    Ok(out)
}

fn router_records(conn: &Connection, since: Option<&str>) -> Result<Vec<UsageRecord>, String> {
    let sql = r#"
        SELECT
            p.timestamp, p.model, p.provider, p.account_id, p.api_key_id, p.api_key_name,
            p.mission_id, m.backend, m.title,
            p.input_tokens, p.output_tokens, p.cache_creation_tokens, p.cache_read_tokens,
            p.cost_cents, p.caller_kind, p.purpose, p.reasoning_tokens, p.id, p.account_bound
        FROM proxy_usage p
        LEFT JOIN missions m ON m.id = p.mission_id
        WHERE (?1 IS NULL OR p.timestamp >= ?1)
    "#;
    let mut stmt = conn.prepare(sql).map_err(err)?;
    let rows = stmt
        .query_map(params![since], |row| {
            Ok((
                [row.get::<_, String>(0)?, row.get::<_, String>(1)?],
                [
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, Option<String>>(8)?,
                ],
                [
                    row.get::<_, i64>(9)?,
                    row.get::<_, i64>(10)?,
                    row.get::<_, i64>(11)?,
                    row.get::<_, i64>(12)?,
                    row.get::<_, i64>(13)?,
                    row.get::<_, i64>(16)?,
                ],
                [
                    row.get::<_, Option<String>>(14)?,
                    row.get::<_, Option<String>>(15)?,
                ],
                row.get::<_, i64>(17)?,
                row.get::<_, bool>(18)?,
            ))
        })
        .map_err(err)?;
    let mut out = Vec::new();
    for row in rows {
        let (
            [timestamp, model],
            attribution,
            numbers,
            [caller_kind, purpose],
            row_id,
            account_bound,
        ) = row.map_err(err)?;
        let [provider, account_id, api_key_id, api_key_name, mission_id, backend, title] =
            attribution;
        let [input, output, creation, read, stored_cost, reasoning] = numbers.map(non_negative);
        let caller_kind = caller_kind.filter(|k| !k.is_empty()).unwrap_or_else(|| {
            legacy_caller_kind(api_key_name.as_deref(), mission_id.as_deref()).to_string()
        });
        let (cost_cents, cost_known) = router_cost(
            &model,
            stored_cost,
            &token_usage(input, output, creation, read),
        );
        out.push(UsageRecord {
            request_id: Some(format!("proxy:{row_id}")),
            timestamp,
            source: UsageSource::Router,
            model,
            provider,
            backend,
            mission_id,
            mission_title: title,
            root_mission_id: None,
            caller_kind,
            purpose,
            api_key_id,
            api_key_name,
            account_id,
            account_bound,
            input_tokens: input,
            output_tokens: output,
            cache_creation_tokens: creation,
            cache_read_tokens: read,
            reasoning_tokens: reasoning,
            cost_cents,
            cost_known,
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn store() -> (tempfile::TempDir, SqliteMissionStore) {
        let dir = tempfile::tempdir().expect("tempdir");
        let store = SqliteMissionStore::new(dir.path().to_path_buf(), "test-user")
            .await
            .expect("store");
        (dir, store)
    }

    #[test]
    fn migration_adds_attribution_columns_to_a_legacy_table() {
        let conn = Connection::open_in_memory().expect("db");
        conn.execute_batch(
            "CREATE TABLE missions (id TEXT PRIMARY KEY, backend TEXT, title TEXT);
             CREATE TABLE proxy_usage (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL,
                model TEXT NOT NULL, input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0, cost_cents INTEGER NOT NULL DEFAULT 0);
             INSERT INTO proxy_usage (timestamp, model, input_tokens) VALUES ('2026-10-01T00:00:00+00:00', 'gpt-5.4', 10);",
        )
        .expect("legacy schema");
        migrate(&conn).expect("migrate");
        migrate(&conn).expect("migration is idempotent");
        let columns: Vec<String> = conn
            .prepare("SELECT name FROM pragma_table_info('proxy_usage')")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for (column, _) in PROXY_USAGE_COLUMNS {
            assert!(columns.iter().any(|c| c == column), "{column}");
        }
        let records = router_records(&conn, None).expect("legacy rows read");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].api_key_id, None);
        assert!(!records[0].account_bound);
        assert_eq!(records[0].cache_read_tokens, 0);
    }

    #[tokio::test]
    async fn attributed_router_usage_round_trips_with_source_and_reprices() {
        let (_dir, store) = store().await;
        let key = uuid::Uuid::new_v4();
        let account = uuid::Uuid::new_v4();
        store
            .record_proxy_usage_attributed(&ProxyUsageRecord {
                observed_at: None,
                model: "gemini-4-argon".into(),
                provider: Some("google".into()),
                account_id: Some(account),
                account_bound: true,
                api_key_id: Some(key),
                api_key_name: Some("Cursor".into()),
                mission_id: None,
                caller_kind: Some("script".into()),
                purpose: None,
                reasoning_tokens: 0,
                input_tokens: 1_000_000,
                output_tokens: 0,
                cache_creation_tokens: 0,
                cache_read_tokens: 500_000,
                // Written before the model had a price.
                cost_cents: 0,
            })
            .await
            .expect("record");
        store
            .record_proxy_usage_attributed(&ProxyUsageRecord {
                model: "mystery-model".into(),
                input_tokens: 10,
                ..Default::default()
            })
            .await
            .expect("record unknown");
        let records = store.get_usage_records(None).await.expect("records");
        assert_eq!(records.len(), 2);
        let argon = records
            .iter()
            .find(|r| r.model == "gemini-4-argon")
            .unwrap();
        assert_eq!(argon.source, UsageSource::Router);
        assert!(argon.account_bound);
        assert_eq!(argon.api_key_id.as_deref(), Some(key.to_string().as_str()));
        assert_eq!(argon.api_key_name.as_deref(), Some("Cursor"));
        assert_eq!(
            argon.account_id.as_deref(),
            Some(account.to_string().as_str())
        );
        assert_eq!(argon.provider.as_deref(), Some("google"));
        assert_eq!(argon.cache_read_tokens, 500_000);
        // $2 input + 500k cached at $0.20.
        assert_eq!(argon.cost_cents, 210);
        assert!(argon.cost_known);
        let unknown = records.iter().find(|r| r.model == "mystery-model").unwrap();
        assert!(!unknown.cost_known);

        let future = (chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339();
        assert!(store
            .get_usage_records(Some(&future))
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn binding_a_native_mission_preserves_earlier_harness_usage() {
        let (_dir, store) = store().await;
        let mission = uuid::Uuid::new_v4();
        {
            let conn = store.conn.lock().await;
            conn.execute("INSERT INTO missions (id,status,title,created_at,updated_at,backend,workspace_id) VALUES (?1,'active','t',?2,?2,'codex','w')", params![mission.to_string(), "2026-10-29T00:00:00+00:00"]).unwrap();
            for (seq, timestamp) in [
                (1, "2026-10-29T00:00:01+00:00"),
                (2, "2026-10-29T00:00:03+00:00"),
            ] {
                conn.execute("INSERT INTO mission_events (mission_id,sequence,event_type,timestamp,content,metadata) VALUES (?1,?2,'assistant_message',?3,'',?4)",params![mission.to_string(),seq,timestamp,r#"{"model":"gpt-6-astra","usage":{"input_tokens":10,"output_tokens":5}}"#]).unwrap();
            }
        }
        // Persist after both harness events, as an asynchronous stream sink may,
        // but retain the server observation made before forwarding the new turn.
        store
            .record_proxy_usage_attributed(&ProxyUsageRecord {
                observed_at: Some("2026-10-29T00:00:02+00:00".into()),
                model: "gpt-6-astra".into(),
                mission_id: Some(mission),
                account_bound: true,
                input_tokens: 10,
                output_tokens: 5,
                ..Default::default()
            })
            .await
            .unwrap();
        let records = store.get_usage_records(None).await.unwrap();
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].source, UsageSource::Harness);
        assert_eq!(records[0].timestamp, "2026-10-29T00:00:01+00:00");
        assert_eq!(records[1].source, UsageSource::Router);
        assert_eq!(records.iter().map(|r| r.input_tokens).sum::<u64>(), 20);
    }

    #[tokio::test]
    async fn proxied_missions_are_not_double_counted_from_harness_events() {
        let (_dir, store) = store().await;
        let proxied = uuid::Uuid::new_v4().to_string();
        let direct = uuid::Uuid::new_v4().to_string();
        let child = uuid::Uuid::new_v4().to_string();
        {
            let conn = store.conn.lock().await;
            let now = chrono::Utc::now().to_rfc3339();
            for (id, parent) in [(&proxied, None), (&direct, None), (&child, Some(&direct))] {
                conn.execute(
                    "INSERT INTO missions (id, status, title, created_at, updated_at, parent_mission_id, backend, workspace_id)
                     VALUES (?1, 'active', 't', ?2, ?2, ?3, 'antigravity', 'w')",
                    params![id, now, parent],
                )
                .unwrap();
            }
            for id in [&proxied, &direct, &child] {
                conn.execute(
                    "INSERT INTO mission_events (mission_id, sequence, event_type, timestamp, content, metadata)
                     VALUES (?1, 1, 'assistant_message', ?2, '', ?3)",
                    params![
                        id,
                        now,
                        r#"{"model":"gemini-4-argon","usage":{"input_tokens":10,"output_tokens":5}}"#
                    ],
                )
                .unwrap();
            }
        }
        store
            .record_proxy_usage_attributed(&ProxyUsageRecord {
                model: "gemini-4-argon".into(),
                mission_id: Some(uuid::Uuid::parse_str(&proxied).unwrap()),
                caller_kind: Some("mission".into()),
                input_tokens: 10,
                output_tokens: 5,
                ..Default::default()
            })
            .await
            .unwrap();
        let records = store.get_usage_records(None).await.unwrap();
        let for_mission = |id: &str| -> Vec<&UsageRecord> {
            records
                .iter()
                .filter(|r| r.mission_id.as_deref() == Some(id))
                .collect()
        };
        // Proxy wins: one row for the proxied mission, from the router.
        assert_eq!(for_mission(&proxied).len(), 1);
        assert_eq!(for_mission(&proxied)[0].source, UsageSource::Router);
        // A native harness (agy) is billed from its own usage report.
        assert_eq!(for_mission(&direct)[0].source, UsageSource::Harness);
        assert_eq!(for_mission(&direct)[0].caller_kind, "mission");
        let sub = for_mission(&child)[0];
        assert_eq!(sub.caller_kind, "subagent");
        assert_eq!(sub.root_mission_id.as_deref(), Some(direct.as_str()));
    }
}
