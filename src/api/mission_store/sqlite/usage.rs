//! Cost and usage aggregate, including proxy usage.

use super::*;
use crate::api::mission_store::{ProxyOutcomeRecord, ProxyUsageRecord, UsageRecord};

#[path = "../sqlite_usage.rs"]
mod usage_records;

pub(super) fn migrate(conn: &Connection) -> Result<(), String> {
    usage_records::migrate(conn)?;
    migrate_proxy_outcomes(conn)
}

/// Per-request router outcomes (reliability monitoring). A table of its own
/// rather than more `proxy_usage` columns: `proxy_usage` only gets a row when
/// tokens were reported, while failed requests are exactly what this tracks.
fn migrate_proxy_outcomes(conn: &Connection) -> Result<(), String> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS proxy_outcomes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            chain_id TEXT NOT NULL,
            provider TEXT,
            account_id TEXT,
            model TEXT,
            status TEXT NOT NULL,
            http_status INTEGER,
            retries INTEGER NOT NULL DEFAULT 0,
            ttft_ms INTEGER,
            total_ms INTEGER NOT NULL DEFAULT 0,
            fallback_depth INTEGER NOT NULL DEFAULT 0,
            stream INTEGER NOT NULL DEFAULT 0,
            superseded INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_proxy_outcomes_timestamp ON proxy_outcomes(timestamp);",
    )
    .map_err(|e| format!("Failed to create proxy_outcomes: {e}"))
}

/// Outcome rows older than this are pruned on write.
const PROXY_OUTCOME_RETENTION_DAYS: i64 = 30;

pub(super) fn usage_cost_with_read_side_estimate(
    model: &str,
    stored_cost_cents: u64,
    cost_source: &str,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
) -> u64 {
    if stored_cost_cents > 0 && cost_source == "actual" {
        return stored_cost_cents;
    }
    let estimated = crate::cost::cost_cents_from_usage(
        model,
        &crate::cost::TokenUsage {
            input_tokens,
            output_tokens,
            cache_creation_input_tokens: Some(cache_creation_tokens),
            cache_read_input_tokens: Some(cache_read_tokens),
        },
    );
    if estimated > 0 {
        return estimated;
    }
    stored_cost_cents
}

pub(super) fn usage_model_key(raw_model: &str, stored_normalized_model: &str) -> String {
    let raw_model = raw_model.trim();
    if !raw_model.is_empty() {
        return crate::cost::normalized_model(raw_model);
    }
    stored_normalized_model.trim().to_string()
}
impl SqliteMissionStore {
    pub(super) async fn get_total_cost_cents(&self) -> Result<u64, String> {
        let conn = self.conn.lock().await;

        // Prefer normalized cost.amount_cents while remaining backward-compatible
        // with legacy flat cost_cents metadata. Clamp malformed negative values
        // to zero so aggregate cost invariants remain non-negative.
        let query = r#"
            WITH assistant_costs AS (
                SELECT CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) AS raw_cost
                FROM mission_events
                WHERE event_type = 'assistant_message'
            )
            SELECT COALESCE(
                SUM(CASE WHEN raw_cost > 0 THEN raw_cost ELSE 0 END),
                0
            ) as total_cost
            FROM assistant_costs
        "#;

        let total: i64 = conn
            .query_row(query, [], |row| row.get(0))
            .map_err(|e| e.to_string())?;

        u64::try_from(total).map_err(|_| format!("negative aggregate cost is invalid: {total}"))
    }

    pub(super) async fn get_cost_by_source(&self) -> Result<(u64, u64, u64), String> {
        let conn = self.conn.lock().await;

        // Group costs by source provenance. Events may store cost in the
        // normalized shape (cost.amount_cents + cost.source) or in the legacy
        // flat shape (cost_cents, with no source — treated as unknown).
        let query = r#"
            WITH source_costs AS (
                SELECT
                    CAST(
                        COALESCE(
                            json_extract(metadata, '$.cost.amount_cents'),
                            json_extract(metadata, '$.cost_cents'),
                            0
                        ) AS INTEGER
                    ) AS raw_cost,
                    COALESCE(
                        json_extract(metadata, '$.cost.source'),
                        'unknown'
                    ) AS source
                FROM mission_events
                WHERE event_type = 'assistant_message'
            )
            SELECT
                source,
                COALESCE(SUM(CASE WHEN raw_cost > 0 THEN raw_cost ELSE 0 END), 0) AS total
            FROM source_costs
            GROUP BY source
        "#;

        let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                let source: String = row.get(0)?;
                let total: i64 = row.get(1)?;
                Ok((source, total.max(0) as u64))
            })
            .map_err(|e| e.to_string())?;

        let mut actual: u64 = 0;
        let mut estimated: u64 = 0;
        let mut unknown: u64 = 0;

        for row in rows {
            let (source, total) = row.map_err(|e| e.to_string())?;
            match source.as_str() {
                "actual" => actual = total,
                "estimated" => estimated = total,
                _ => unknown = unknown.saturating_add(total),
            }
        }

        Ok((actual, estimated, unknown))
    }

    pub(super) async fn get_total_cost_cents_since(&self, since: &str) -> Result<u64, String> {
        let conn = self.conn.lock().await;
        let query = r#"
            WITH assistant_costs AS (
                SELECT CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) AS raw_cost
                FROM mission_events
                WHERE event_type = 'assistant_message'
                  AND timestamp >= ?1
            )
            SELECT COALESCE(
                SUM(CASE WHEN raw_cost > 0 THEN raw_cost ELSE 0 END),
                0
            ) as total_cost
            FROM assistant_costs
        "#;
        let total: i64 = conn
            .query_row(query, [since], |row| row.get(0))
            .map_err(|e| e.to_string())?;
        u64::try_from(total).map_err(|_| format!("negative aggregate cost is invalid: {total}"))
    }

    pub(super) async fn get_cost_by_source_since(
        &self,
        since: &str,
    ) -> Result<(u64, u64, u64), String> {
        let conn = self.conn.lock().await;
        let query = r#"
            WITH source_costs AS (
                SELECT
                    CAST(
                        COALESCE(
                            json_extract(metadata, '$.cost.amount_cents'),
                            json_extract(metadata, '$.cost_cents'),
                            0
                        ) AS INTEGER
                    ) AS raw_cost,
                    COALESCE(
                        json_extract(metadata, '$.cost.source'),
                        'unknown'
                    ) AS source
                FROM mission_events
                WHERE event_type = 'assistant_message'
                  AND timestamp >= ?1
            )
            SELECT
                source,
                COALESCE(SUM(CASE WHEN raw_cost > 0 THEN raw_cost ELSE 0 END), 0) AS total
            FROM source_costs
            GROUP BY source
        "#;
        let mut stmt = conn.prepare(query).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([since], |row| {
                let source: String = row.get(0)?;
                let total: i64 = row.get(1)?;
                Ok((source, total.max(0) as u64))
            })
            .map_err(|e| e.to_string())?;

        let mut actual: u64 = 0;
        let mut estimated: u64 = 0;
        let mut unknown: u64 = 0;
        for row in rows {
            let (source, total) = row.map_err(|e| e.to_string())?;
            match source.as_str() {
                "actual" => actual = total,
                "estimated" => estimated = total,
                _ => unknown = unknown.saturating_add(total),
            }
        }
        Ok((actual, estimated, unknown))
    }

    pub(super) async fn get_usage_by_model(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<ModelUsageStats>, String> {
        let conn = self.conn.lock().await;

        // Read individual rows so stale stored `model_normalized` values can be
        // corrected with the current normalizer and estimated costs can be
        // recalculated under the corrected model.
        let base_query = r#"
            SELECT
                COALESCE(json_extract(metadata, '$.model'), '') AS raw_model,
                COALESCE(json_extract(metadata, '$.model_normalized'), '') AS stored_model,
                COALESCE(CAST(json_extract(metadata, '$.usage.input_tokens') AS INTEGER), 0) AS input_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.output_tokens') AS INTEGER), 0) AS output_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.cache_creation_input_tokens') AS INTEGER), 0) AS cache_creation_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.cache_read_input_tokens') AS INTEGER), 0) AS cache_read_tokens,
                COALESCE(
                    json_extract(metadata, '$.cost.source'),
                    ''
                ) AS cost_source,
                CASE WHEN CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) > 0
                THEN CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) ELSE 0 END AS cost_cents
            FROM mission_events
            WHERE event_type = 'assistant_message'
        "#;

        let sql = match since {
            Some(_) => format!("{base_query} AND timestamp >= ?1"),
            None => base_query.to_string(),
        };

        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let since_owned = since.map(|s| s.to_string());
        let params: Vec<&dyn rusqlite::ToSql> = match since_owned.as_ref() {
            Some(s) => vec![s],
            None => vec![],
        };
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                let raw_model: String = row.get(0)?;
                let stored_model: String = row.get(1)?;
                let input_tokens: i64 = row.get(2)?;
                let output_tokens: i64 = row.get(3)?;
                let cache_creation_tokens: i64 = row.get(4)?;
                let cache_read_tokens: i64 = row.get(5)?;
                let cost_source: String = row.get(6)?;
                let cost_cents: i64 = row.get(7)?;
                let model = usage_model_key(&raw_model, &stored_model);
                let input_tokens = input_tokens.max(0) as u64;
                let output_tokens = output_tokens.max(0) as u64;
                let cache_creation_tokens = cache_creation_tokens.max(0) as u64;
                let cache_read_tokens = cache_read_tokens.max(0) as u64;
                let stored_cost_cents = cost_cents.max(0) as u64;
                let cost_cents = usage_cost_with_read_side_estimate(
                    &model,
                    stored_cost_cents,
                    &cost_source,
                    input_tokens,
                    output_tokens,
                    cache_creation_tokens,
                    cache_read_tokens,
                );
                Ok(ModelUsageStats {
                    model,
                    requests: 1,
                    input_tokens,
                    output_tokens,
                    cache_creation_tokens,
                    cache_read_tokens,
                    cost_cents,
                })
            })
            .map_err(|e| e.to_string())?;

        let mut by_model: BTreeMap<String, ModelUsageStats> = BTreeMap::new();
        for r in rows {
            let row = r.map_err(|e| e.to_string())?;
            // Skip empty-model rows that carry no usage signal at all
            if row.model.is_empty()
                && row.input_tokens == 0
                && row.output_tokens == 0
                && row.cache_creation_tokens == 0
                && row.cache_read_tokens == 0
                && row.cost_cents == 0
            {
                continue;
            }
            let entry = by_model
                .entry(row.model.clone())
                .or_insert_with(|| ModelUsageStats {
                    model: row.model.clone(),
                    requests: 0,
                    input_tokens: 0,
                    output_tokens: 0,
                    cache_creation_tokens: 0,
                    cache_read_tokens: 0,
                    cost_cents: 0,
                });
            entry.requests = entry.requests.saturating_add(row.requests);
            entry.input_tokens = entry.input_tokens.saturating_add(row.input_tokens);
            entry.output_tokens = entry.output_tokens.saturating_add(row.output_tokens);
            entry.cache_creation_tokens = entry
                .cache_creation_tokens
                .saturating_add(row.cache_creation_tokens);
            entry.cache_read_tokens = entry
                .cache_read_tokens
                .saturating_add(row.cache_read_tokens);
            entry.cost_cents = entry.cost_cents.saturating_add(row.cost_cents);
        }
        let mut out: Vec<ModelUsageStats> = by_model.into_values().collect();
        out.sort_by(|a, b| {
            b.cost_cents
                .cmp(&a.cost_cents)
                .then_with(|| b.requests.cmp(&a.requests))
                .then_with(|| a.model.cmp(&b.model))
        });
        Ok(out)
    }

    pub(super) async fn get_usage_by_day(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<DailyUsageStats>, String> {
        let conn = self.conn.lock().await;

        // Group by the UTC date prefix of the ISO-8601 timestamp.
        // We rely on timestamps being stored in RFC3339 / ISO-8601 form, which
        // is what `now_string()` and SQLite's CURRENT_TIMESTAMP produce.
        let base_query = r#"
            SELECT
                substr(timestamp, 1, 10) AS day,
                COALESCE(json_extract(metadata, '$.model'), '') AS raw_model,
                COALESCE(json_extract(metadata, '$.model_normalized'), '') AS stored_model,
                COALESCE(CAST(json_extract(metadata, '$.usage.input_tokens') AS INTEGER), 0) AS input_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.output_tokens') AS INTEGER), 0) AS output_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.cache_creation_input_tokens') AS INTEGER), 0) AS cache_creation_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.cache_read_input_tokens') AS INTEGER), 0) AS cache_read_tokens,
                COALESCE(json_extract(metadata, '$.cost.source'), '') AS cost_source,
                CASE WHEN CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) > 0
                THEN CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) ELSE 0 END AS cost_cents
            FROM mission_events
            WHERE event_type = 'assistant_message'
        "#;

        let sql = match since {
            Some(_) => format!("{base_query} AND timestamp >= ?1 ORDER BY day ASC"),
            None => format!("{base_query} ORDER BY day ASC"),
        };

        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let since_owned = since.map(|s| s.to_string());
        let params: Vec<&dyn rusqlite::ToSql> = match since_owned.as_ref() {
            Some(s) => vec![s],
            None => vec![],
        };
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                let day: String = row.get(0)?;
                let raw_model: String = row.get(1)?;
                let stored_model: String = row.get(2)?;
                let input_tokens: i64 = row.get(3)?;
                let output_tokens: i64 = row.get(4)?;
                let cache_creation_tokens: i64 = row.get(5)?;
                let cache_read_tokens: i64 = row.get(6)?;
                let cost_source: String = row.get(7)?;
                let cost_cents: i64 = row.get(8)?;
                let model = usage_model_key(&raw_model, &stored_model);
                let input_tokens = input_tokens.max(0) as u64;
                let output_tokens = output_tokens.max(0) as u64;
                let cache_creation_tokens = cache_creation_tokens.max(0) as u64;
                let cache_read_tokens = cache_read_tokens.max(0) as u64;
                let cost_cents = usage_cost_with_read_side_estimate(
                    &model,
                    cost_cents.max(0) as u64,
                    &cost_source,
                    input_tokens,
                    output_tokens,
                    cache_creation_tokens,
                    cache_read_tokens,
                );
                Ok((
                    day,
                    1,
                    input_tokens,
                    output_tokens,
                    cache_read_tokens,
                    cost_cents,
                ))
            })
            .map_err(|e| e.to_string())?;

        let mut by_day: BTreeMap<String, DailyUsageStats> = BTreeMap::new();
        for r in rows {
            let (day, requests, input_tokens, output_tokens, cache_read_tokens, cost_cents) =
                r.map_err(|e| e.to_string())?;
            if day.is_empty() {
                continue;
            }
            let entry = by_day.entry(day.clone()).or_insert(DailyUsageStats {
                day,
                requests: 0,
                input_tokens: 0,
                output_tokens: 0,
                cache_read_tokens: 0,
                cost_cents: 0,
            });
            entry.requests = entry.requests.saturating_add(requests);
            entry.input_tokens = entry.input_tokens.saturating_add(input_tokens);
            entry.output_tokens = entry.output_tokens.saturating_add(output_tokens);
            entry.cache_read_tokens = entry.cache_read_tokens.saturating_add(cache_read_tokens);
            entry.cost_cents = entry.cost_cents.saturating_add(cost_cents);
        }
        Ok(by_day.into_values().collect())
    }

    pub(super) async fn get_usage_by_hour(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<HourlyUsageStats>, String> {
        let conn = self.conn.lock().await;

        // Bucket by `YYYY-MM-DDTHH` (the first 13 chars of an RFC3339 stamp).
        // Same cost-source fallback as get_usage_by_day.
        let base_query = r#"
            SELECT
                substr(timestamp, 1, 13) AS hour,
                COALESCE(json_extract(metadata, '$.model'), '') AS raw_model,
                COALESCE(json_extract(metadata, '$.model_normalized'), '') AS stored_model,
                COALESCE(CAST(json_extract(metadata, '$.usage.input_tokens') AS INTEGER), 0) AS input_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.output_tokens') AS INTEGER), 0) AS output_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.cache_creation_input_tokens') AS INTEGER), 0) AS cache_creation_tokens,
                COALESCE(CAST(json_extract(metadata, '$.usage.cache_read_input_tokens') AS INTEGER), 0) AS cache_read_tokens,
                COALESCE(json_extract(metadata, '$.cost.source'), '') AS cost_source,
                CASE WHEN CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) > 0
                THEN CAST(
                    COALESCE(
                        json_extract(metadata, '$.cost.amount_cents'),
                        json_extract(metadata, '$.cost_cents'),
                        0
                    ) AS INTEGER
                ) ELSE 0 END AS cost_cents
            FROM mission_events
            WHERE event_type = 'assistant_message'
        "#;
        let sql = match since {
            Some(_) => format!("{base_query} AND timestamp >= ?1 ORDER BY hour ASC"),
            None => format!("{base_query} ORDER BY hour ASC"),
        };
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let since_owned = since.map(|s| s.to_string());
        let params: Vec<&dyn rusqlite::ToSql> = match since_owned.as_ref() {
            Some(s) => vec![s],
            None => vec![],
        };
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                let hour: String = row.get(0)?;
                let raw_model: String = row.get(1)?;
                let stored_model: String = row.get(2)?;
                let input_tokens: i64 = row.get(3)?;
                let output_tokens: i64 = row.get(4)?;
                let cache_creation_tokens: i64 = row.get(5)?;
                let cache_read_tokens: i64 = row.get(6)?;
                let cost_source: String = row.get(7)?;
                let cost_cents: i64 = row.get(8)?;
                let model = usage_model_key(&raw_model, &stored_model);
                let input_tokens = input_tokens.max(0) as u64;
                let output_tokens = output_tokens.max(0) as u64;
                let cache_creation_tokens = cache_creation_tokens.max(0) as u64;
                let cache_read_tokens = cache_read_tokens.max(0) as u64;
                let cost_cents = usage_cost_with_read_side_estimate(
                    &model,
                    cost_cents.max(0) as u64,
                    &cost_source,
                    input_tokens,
                    output_tokens,
                    cache_creation_tokens,
                    cache_read_tokens,
                );
                Ok((
                    hour,
                    1,
                    input_tokens,
                    output_tokens,
                    cache_read_tokens,
                    cost_cents,
                ))
            })
            .map_err(|e| e.to_string())?;
        let mut by_hour: BTreeMap<String, HourlyUsageStats> = BTreeMap::new();
        for r in rows {
            let (hour, requests, input_tokens, output_tokens, cache_read_tokens, cost_cents) =
                r.map_err(|e| e.to_string())?;
            if hour.is_empty() {
                continue;
            }
            let entry = by_hour.entry(hour.clone()).or_insert(HourlyUsageStats {
                hour,
                requests: 0,
                input_tokens: 0,
                output_tokens: 0,
                cache_read_tokens: 0,
                cost_cents: 0,
            });
            entry.requests = entry.requests.saturating_add(requests);
            entry.input_tokens = entry.input_tokens.saturating_add(input_tokens);
            entry.output_tokens = entry.output_tokens.saturating_add(output_tokens);
            entry.cache_read_tokens = entry.cache_read_tokens.saturating_add(cache_read_tokens);
            entry.cost_cents = entry.cost_cents.saturating_add(cost_cents);
        }
        Ok(by_hour.into_values().collect())
    }

    pub(super) async fn record_proxy_usage(
        &self,
        model: &str,
        input_tokens: u64,
        output_tokens: u64,
        cost_cents: u64,
    ) -> Result<(), String> {
        let conn = self.conn.lock().await;
        conn.execute(
            "INSERT INTO proxy_usage (timestamp, model, input_tokens, output_tokens, cost_cents)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![
                chrono::Utc::now().to_rfc3339(),
                model,
                input_tokens as i64,
                output_tokens as i64,
                cost_cents as i64,
            ],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub(super) async fn record_proxy_outcome(
        &self,
        record: &ProxyOutcomeRecord,
    ) -> Result<(), String> {
        let conn = self.conn.lock().await;
        conn.execute(
            "INSERT INTO proxy_outcomes (timestamp, chain_id, provider, account_id, model,
                status, http_status, retries, ttft_ms, total_ms, fallback_depth, stream, superseded)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            rusqlite::params![
                record.timestamp,
                record.chain_id,
                record.provider,
                record.account_id.map(|id| id.to_string()),
                record.model,
                record.status,
                record.http_status.map(i64::from),
                i64::from(record.retries),
                record.ttft_ms.map(|v| v as i64),
                record.total_ms as i64,
                i64::from(record.fallback_depth),
                record.stream as i64,
                record.superseded as i64,
            ],
        )
        .map_err(|e| e.to_string())?;
        // Cheap bounded retention: prune roughly once per 512 inserts.
        if conn.last_insert_rowid() % 512 == 0 {
            let cutoff = (chrono::Utc::now()
                - chrono::Duration::days(PROXY_OUTCOME_RETENTION_DAYS))
            .to_rfc3339();
            conn.execute(
                "DELETE FROM proxy_outcomes WHERE timestamp < ?1",
                rusqlite::params![cutoff],
            )
            .map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    pub(super) async fn get_proxy_outcomes(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<ProxyOutcomeRecord>, String> {
        let conn = self.conn.lock().await;
        let mut stmt = conn
            .prepare(
                "SELECT timestamp, chain_id, provider, account_id, model, status, http_status,
                        retries, ttft_ms, total_ms, fallback_depth, stream, superseded
                 FROM proxy_outcomes
                 WHERE ?1 IS NULL OR timestamp >= ?1
                 ORDER BY timestamp ASC",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(rusqlite::params![since], |row| {
                let account: Option<String> = row.get(3)?;
                Ok(ProxyOutcomeRecord {
                    timestamp: row.get(0)?,
                    chain_id: row.get(1)?,
                    provider: row.get(2)?,
                    account_id: account.and_then(|a| Uuid::parse_str(&a).ok()),
                    model: row.get(4)?,
                    status: row.get(5)?,
                    http_status: row
                        .get::<_, Option<i64>>(6)?
                        .and_then(|v| u16::try_from(v).ok()),
                    retries: row.get::<_, i64>(7)?.max(0) as u32,
                    ttft_ms: row.get::<_, Option<i64>>(8)?.map(|v| v.max(0) as u64),
                    total_ms: row.get::<_, i64>(9)?.max(0) as u64,
                    fallback_depth: row.get::<_, i64>(10)?.max(0) as u32,
                    stream: row.get::<_, i64>(11)? != 0,
                    superseded: row.get::<_, i64>(12)? != 0,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())
    }

    pub(super) async fn record_proxy_usage_attributed(
        &self,
        record: &ProxyUsageRecord,
    ) -> Result<(), String> {
        usage_records::record(self, record).await
    }

    pub(super) async fn get_usage_records(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<UsageRecord>, String> {
        usage_records::records(self, since).await
    }

    pub(super) async fn get_proxy_usage_by_model(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<ModelUsageStats>, String> {
        let conn = self.conn.lock().await;
        // Models are normalized and costs finalized at write time, so plain
        // SQL aggregation is enough (unlike mission_events, which re-derives
        // both from stored metadata on read).
        let base_query = r#"
            SELECT
                model,
                COUNT(*) AS requests,
                SUM(input_tokens) AS input_tokens,
                SUM(output_tokens) AS output_tokens,
                SUM(cache_creation_tokens) AS cache_creation_tokens,
                SUM(cache_read_tokens) AS cache_read_tokens,
                SUM(cost_cents) AS cost_cents
            FROM proxy_usage
        "#;
        let sql = match since {
            Some(_) => format!("{base_query} WHERE timestamp >= ?1 GROUP BY model"),
            None => format!("{base_query} GROUP BY model"),
        };
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let since_owned = since.map(|s| s.to_string());
        let params: Vec<&dyn rusqlite::ToSql> = match since_owned.as_ref() {
            Some(s) => vec![s],
            None => vec![],
        };
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                Ok(ModelUsageStats {
                    model: row.get(0)?,
                    requests: row.get::<_, i64>(1)?.max(0) as u64,
                    input_tokens: row.get::<_, i64>(2)?.max(0) as u64,
                    output_tokens: row.get::<_, i64>(3)?.max(0) as u64,
                    cache_creation_tokens: row.get::<_, i64>(4)?.max(0) as u64,
                    cache_read_tokens: row.get::<_, i64>(5)?.max(0) as u64,
                    cost_cents: row.get::<_, i64>(6)?.max(0) as u64,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())
    }

    pub(super) async fn get_proxy_usage_by_day(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<DailyUsageStats>, String> {
        let conn = self.conn.lock().await;
        let base_query = r#"
            SELECT
                substr(timestamp, 1, 10) AS day,
                COUNT(*) AS requests,
                SUM(input_tokens) AS input_tokens,
                SUM(output_tokens) AS output_tokens,
                SUM(cache_read_tokens) AS cache_read_tokens,
                SUM(cost_cents) AS cost_cents
            FROM proxy_usage
        "#;
        let sql = match since {
            Some(_) => format!("{base_query} WHERE timestamp >= ?1 GROUP BY day ORDER BY day ASC"),
            None => format!("{base_query} GROUP BY day ORDER BY day ASC"),
        };
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let since_owned = since.map(|s| s.to_string());
        let params: Vec<&dyn rusqlite::ToSql> = match since_owned.as_ref() {
            Some(s) => vec![s],
            None => vec![],
        };
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                Ok(DailyUsageStats {
                    day: row.get(0)?,
                    requests: row.get::<_, i64>(1)?.max(0) as u64,
                    input_tokens: row.get::<_, i64>(2)?.max(0) as u64,
                    output_tokens: row.get::<_, i64>(3)?.max(0) as u64,
                    cache_read_tokens: row.get::<_, i64>(4)?.max(0) as u64,
                    cost_cents: row.get::<_, i64>(5)?.max(0) as u64,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())
    }

    pub(super) async fn get_proxy_usage_by_hour(
        &self,
        since: Option<&str>,
    ) -> Result<Vec<HourlyUsageStats>, String> {
        let conn = self.conn.lock().await;
        let base_query = r#"
            SELECT
                substr(timestamp, 1, 13) AS hour,
                COUNT(*) AS requests,
                SUM(input_tokens) AS input_tokens,
                SUM(output_tokens) AS output_tokens,
                SUM(cache_read_tokens) AS cache_read_tokens,
                SUM(cost_cents) AS cost_cents
            FROM proxy_usage
        "#;
        let sql = match since {
            Some(_) => {
                format!("{base_query} WHERE timestamp >= ?1 GROUP BY hour ORDER BY hour ASC")
            }
            None => format!("{base_query} GROUP BY hour ORDER BY hour ASC"),
        };
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let since_owned = since.map(|s| s.to_string());
        let params: Vec<&dyn rusqlite::ToSql> = match since_owned.as_ref() {
            Some(s) => vec![s],
            None => vec![],
        };
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                Ok(HourlyUsageStats {
                    hour: row.get(0)?,
                    requests: row.get::<_, i64>(1)?.max(0) as u64,
                    input_tokens: row.get::<_, i64>(2)?.max(0) as u64,
                    output_tokens: row.get::<_, i64>(3)?.max(0) as u64,
                    cache_read_tokens: row.get::<_, i64>(4)?.max(0) as u64,
                    cost_cents: row.get::<_, i64>(5)?.max(0) as u64,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())
    }
}
