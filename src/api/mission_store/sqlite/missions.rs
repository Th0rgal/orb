//! Mission aggregate: rows, listing, status, metadata and tree persistence.

use super::*;

/// Map one row of [`MISSION_LIST_COLUMNS`] onto a `Mission`.
/// Positional getters — only valid for that exact column list.
pub(super) fn row_to_mission(row: &rusqlite::Row<'_>) -> rusqlite::Result<Mission> {
    let id_str: String = row.get(0)?;
    let status_str: String = row.get(1)?;
    let workspace_id_str: String = row.get(8)?;
    let desktop_sessions_json: Option<String> = row.get(17)?;
    let backend: String = row.get(18)?;
    let session_id: Option<String> = row.get(19)?;
    let terminal_reason: Option<String> = row.get(20)?;
    let config_profile: Option<String> = row.get(21)?;
    let (project, awaiting_kind, last_status_change_at) = read_project_columns(row, 32)?;

    Ok(Mission {
        id: parse_uuid_or_nil(&id_str),
        status: parse_status(&status_str),
        title: row.get(2)?,
        short_description: row.get(3)?,
        metadata_updated_at: row.get(4)?,
        metadata_source: row.get(5)?,
        metadata_model: row.get(6)?,
        metadata_version: row.get(7)?,
        workspace_id: Uuid::parse_str(&workspace_id_str)
            .unwrap_or(crate::workspace::DEFAULT_WORKSPACE_ID),
        workspace_name: row.get(9)?,
        agent: row.get(10)?,
        model_override: row.get(11)?,
        model_effort: row.get(12)?,
        fast_mode: row.get::<_, i32>(41)? != 0,
        service_tier: read_service_tier(row)?,
        backend,
        config_profile,
        history: vec![], // Loaded separately if needed
        created_at: row.get(13)?,
        updated_at: row.get(14)?,
        interrupted_at: row.get(15)?,
        paused_at: row.get(31).ok().flatten(),
        resumable: row.get::<_, i32>(16)? != 0,
        desktop_sessions: desktop_sessions_json
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default(),
        session_id,
        terminal_reason,
        terminal_evidence: None,
        parent_mission_id: row
            .get::<_, Option<String>>(22)?
            .and_then(|s| Uuid::parse_str(&s).ok()),
        working_directory: row.get(23)?,
        mission_mode: row
            .get::<_, Option<String>>(24)?
            .and_then(|s| serde_json::from_value(serde_json::Value::String(s)).ok())
            .unwrap_or_default(),
        goal_mode: row.get::<_, i32>(25).unwrap_or(0) != 0,
        goal_objective: row.get(26).ok().flatten(),
        first_viewed_at: row.get(27).ok().flatten(),
        scheduling: MissionScheduling {
            priority: row.get::<_, i32>(28).unwrap_or(0),
            not_before: row.get(29).ok().flatten(),
            deadline: row.get(30).ok().flatten(),
        },
        project,
        activity: MissionActivity {
            last_status_change_at,
            ..Default::default()
        },
        awaiting_kind,
        origin: row.get(42).ok().flatten(),
        origin_session_id: row.get(43).ok().flatten(),
        requires_local_disk: row.get::<_, i32>(44).unwrap_or(1) != 0,
    })
}

/// Column list shared by every query that maps rows through the same
/// `Mission` projection. The row getters below are positional, so the two
/// listings MUST select the same columns in the same order — keeping one
/// const is what stops them drifting.
pub(super) const MISSION_LIST_COLUMNS: &str = "id, status, title, short_description, metadata_updated_at, metadata_source, metadata_model, metadata_version, workspace_id, workspace_name, agent, model_override, \
     model_effort, \
     created_at, updated_at, interrupted_at, resumable, desktop_sessions, \
     COALESCE(backend, 'opencode') as backend, session_id, terminal_reason, \
     config_profile, parent_mission_id, working_directory, \
     COALESCE(mission_mode, 'task') as mission_mode, \
     COALESCE(goal_mode, 0) as goal_mode, goal_objective, first_viewed_at, \
     COALESCE(priority, 0) as priority, not_before, deadline, paused_at, \
     project, track, intent, github_pr, tags, desired_state, next_check_at, awaiting_kind, last_status_change_at, \
     COALESCE(fast_mode, 0) as fast_mode, origin, origin_session_id, COALESCE(requires_local_disk, 1) as requires_local_disk, service_tier";

pub(super) fn read_service_tier(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<Option<crate::codex_speed::Tier>> {
    row.get::<_, Option<String>>("service_tier")?
        .map(|tier| {
            serde_json::from_value(serde_json::Value::String(tier)).map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })
        })
        .transpose()
}

pub(super) fn parse_status(s: &str) -> MissionStatus {
    match s {
        "pending" => MissionStatus::Pending,
        "active" => MissionStatus::Active,
        "awaiting_user" => MissionStatus::AwaitingUser,
        "acknowledged" => MissionStatus::Acknowledged,
        "waiting_background" => MissionStatus::WaitingBackground,
        "completed" => MissionStatus::Completed,
        "failed" => MissionStatus::Failed,
        "interrupted" => MissionStatus::Interrupted,
        "blocked" => MissionStatus::Blocked,
        "not_feasible" => MissionStatus::NotFeasible,
        "paused" => MissionStatus::Paused,
        _ => MissionStatus::Pending,
    }
}

pub(super) fn status_to_string(status: MissionStatus) -> &'static str {
    match status {
        MissionStatus::Pending => "pending",
        MissionStatus::Active => "active",
        MissionStatus::AwaitingUser => "awaiting_user",
        MissionStatus::Acknowledged => "acknowledged",
        MissionStatus::WaitingBackground => "waiting_background",
        MissionStatus::Completed => "completed",
        MissionStatus::Failed => "failed",
        MissionStatus::Interrupted => "interrupted",
        MissionStatus::Blocked => "blocked",
        MissionStatus::NotFeasible => "not_feasible",
        MissionStatus::Paused => "paused",
    }
}

pub(super) fn parse_mission_run_row(
    row: &rusqlite::Row<'_>,
) -> Result<MissionRun, rusqlite::Error> {
    let run_id: String = row.get(0)?;
    let mission_id: String = row.get(1)?;
    let state: String = row.get(3)?;
    Ok(MissionRun {
        run_id: parse_uuid_or_nil(&run_id),
        mission_id: parse_uuid_or_nil(&mission_id),
        generation: row.get::<_, i64>(2)?.max(0) as u64,
        execution_state: MissionExecutionState::parse(&state)
            .unwrap_or(MissionExecutionState::Terminal),
        owner_actor_id: row.get(4)?,
        scope_unit: row.get(5)?,
        started_at: row.get(6)?,
        heartbeat_at: row.get(7)?,
        stopping_at: row.get(8)?,
        ended_at: row.get(9)?,
        terminal_reason: row.get(10)?,
    })
}

pub(super) fn parse_tool_execution_row(
    row: &rusqlite::Row<'_>,
) -> Result<MissionToolExecution, rusqlite::Error> {
    let run_id: String = row.get(1)?;
    let state: String = row.get(3)?;
    let durable_job_id: Option<String> = row.get(8)?;
    Ok(MissionToolExecution {
        tool_call_id: row.get(0)?,
        run_id: parse_uuid_or_nil(&run_id),
        tool_kind: row.get(2)?,
        state: MissionToolExecutionState::parse(&state).unwrap_or(MissionToolExecutionState::Stale),
        started_at: row.get(4)?,
        heartbeat_at: row.get(5)?,
        deadline_at: row.get(6)?,
        process_pid: row.get::<_, Option<i64>>(7)?.map(|pid| pid.max(0) as u32),
        durable_job_id: durable_job_id.and_then(|id| Uuid::parse_str(&id).ok()),
        completed_at: row.get(9)?,
        exit_status: row.get(10)?,
        failure_class: row.get(11)?,
    })
}

/// Serialize mission tags to a JSON array string for storage. `None` when empty
/// (keeps the column NULL rather than `"[]"`).
pub(super) fn tags_to_json(tags: &[String]) -> Option<String> {
    if tags.is_empty() {
        None
    } else {
        serde_json::to_string(tags).ok()
    }
}

/// Parse a stored JSON array of tags. Tolerates NULL / malformed values.
pub(super) fn tags_from_json(raw: Option<String>) -> Vec<String> {
    raw.as_deref()
        .and_then(|s| serde_json::from_str::<Vec<String>>(s).ok())
        .unwrap_or_default()
}

/// Read the trailing project/activity columns from a mission row in the
/// canonical order `project, track, intent, github_pr, tags, desired_state,
/// next_check_at, awaiting_kind, last_status_change_at` starting at `base`.
/// Shared by the full SELECTs so the index math lives in one place. Returns the
/// project metadata, the awaiting classification, and `last_status_change_at`.
pub(super) fn read_project_columns(
    row: &rusqlite::Row,
    base: usize,
) -> rusqlite::Result<(MissionProject, Option<AwaitingKind>, Option<String>)> {
    let project = MissionProject {
        project: row.get(base)?,
        track: row.get(base + 1)?,
        intent: row.get(base + 2)?,
        github_pr: row.get(base + 3)?,
        tags: tags_from_json(row.get(base + 4)?),
        desired_state: row.get(base + 5)?,
        next_check_at: row.get(base + 6)?,
    };
    let awaiting_kind = row
        .get::<_, Option<String>>(base + 7)?
        .as_deref()
        .and_then(AwaitingKind::from_str_opt);
    let last_status_change_at: Option<String> = row.get(base + 8)?;
    Ok((project, awaiting_kind, last_status_change_at))
}
impl SqliteMissionStore {
    pub(super) async fn list_missions(
        &self,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<Mission>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(&format!(
                    "SELECT {MISSION_LIST_COLUMNS}
                     FROM missions
                     ORDER BY updated_at DESC
                     LIMIT ?1 OFFSET ?2"
                ))
                .map_err(|e| e.to_string())?;

            let missions = stmt
                .query_map(params![limit as i64, offset as i64], row_to_mission)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(missions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    /// Exact filtered listing: the predicate runs in SQL, so a match is found
    /// however deep it sits in the fleet (the generic scan gives up after
    /// 5 000 rows, which is why old conversations showed zero workers).
    ///
    /// `tag` is the one field SQL only narrows: `tags` is a JSON TEXT column
    /// and some rows hold malformed blobs, so `json_each` would fail the whole
    /// query. A `LIKE` prefilter selects candidates and
    /// [`MissionFilter::matches`] makes the final call — which means the
    /// prefilter can over-select, hence the accumulate-until-satisfied loop.
    pub(super) async fn list_missions_filtered(
        &self,
        filter: &MissionFilter,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<Mission>, String> {
        if filter.is_empty() {
            return self.list_missions(limit, offset).await;
        }
        let conn = self.reader();
        let filter = filter.clone();
        tokio::task::spawn_blocking(move || {
            const PAGE: i64 = 200;
            let conn = conn.blocking_lock();

            let mut clauses: Vec<String> = Vec::new();
            let mut binds: Vec<String> = Vec::new();
            let bind =
                |clause: &str, value: &str, clauses: &mut Vec<String>, binds: &mut Vec<String>| {
                    binds.push(value.to_string());
                    clauses.push(clause.replace("?n", &format!("?{}", binds.len())));
                };
            if let Some(v) = filter.status.as_deref() {
                bind("status = ?n", v, &mut clauses, &mut binds);
            }
            if let Some(v) = filter.project.as_deref() {
                bind("project = ?n", v, &mut clauses, &mut binds);
            }
            if let Some(v) = filter.project_prefix.as_deref() {
                // Range bounds, not `LIKE ?n || '-%'`: a LIKE whose pattern is
                // a concatenation expression is never index-optimised, so the
                // family lookup degraded into a full `SCAN missions` — on the
                // fleets this feature exists for, while holding the connection
                // mutex. `'-'` is 0x2D and `'.'` is 0x2E, so [`family-`,
                // `family.`) is exactly the set of `family-*` values under
                // BINARY collation, and both branches can use
                // idx_missions_project_track.
                binds.push(v.to_string());
                let exact = binds.len();
                binds.push(format!("{v}-"));
                let lower = binds.len();
                binds.push(format!("{v}."));
                let upper = binds.len();
                clauses.push(format!(
                    "(project = ?{exact} OR (project >= ?{lower} AND project < ?{upper}))"
                ));
            }
            if let Some(v) = filter.track.as_deref() {
                bind("track = ?n", v, &mut clauses, &mut binds);
            }
            if let Some(v) = filter.origin_session_id.as_deref() {
                bind("origin_session_id = ?n", v, &mut clauses, &mut binds);
            }
            if let Some(v) = filter.tag.as_deref() {
                // Match the tag's JSON *serialization*, quotes included: a tag
                // holding a quote/backslash/newline is escaped inside the
                // column, so a raw-text LIKE would exclude it in SQL and the
                // Rust re-check below would never get to see it.
                //
                // Then neutralise LIKE's own wildcards. Tags are free-form, so
                // `?tag=%` would otherwise select nearly every row and make the
                // loop page through them holding the connection lock — a
                // selective prefilter is what keeps this off the critical path.
                // Escape the escape character first, or `\` would be doubled.
                let encoded = serde_json::to_string(v).unwrap_or_else(|_| format!("\"{v}\""));
                let pattern = encoded
                    .replace('\\', "\\\\")
                    .replace('%', "\\%")
                    .replace('_', "\\_");
                bind(
                    r"tags LIKE '%' || ?n || '%' ESCAPE '\'",
                    &pattern,
                    &mut clauses,
                    &mut binds,
                );
            }
            if filter.attention_only {
                clauses.push(
                    "status NOT IN ('acknowledged', 'completed')".to_string(),
                );
                // Tags are a JSON array. The superseded token is stored as
                // the JSON string `"superseded"`; this is a prefilter — the
                // Rust `matches` call below is the authority.
                let encoded = serde_json::to_string(SUPERSEDED_TAG)
                    .unwrap_or_else(|_| format!("\"{SUPERSEDED_TAG}\""));
                let pattern = encoded
                    .replace('\\', "\\\\")
                    .replace('%', "\\%")
                    .replace('_', "\\_");
                bind(
                    r"(tags IS NULL OR tags = '' OR tags = '[]' OR tags NOT LIKE '%' || ?n || '%' ESCAPE '\')",
                    &pattern,
                    &mut clauses,
                    &mut binds,
                );
            }
            let where_sql = if clauses.is_empty() {
                String::new()
            } else {
                format!("WHERE {}", clauses.join(" AND "))
            };

            let sql = format!(
                "SELECT {MISSION_LIST_COLUMNS} FROM missions {where_sql} \
                 ORDER BY updated_at DESC LIMIT ?{} OFFSET ?{}",
                binds.len() + 1,
                binds.len() + 2
            );
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;

            let want = offset.saturating_add(limit);
            let mut matched: Vec<Mission> = Vec::new();
            let mut sql_offset: i64 = 0;
            loop {
                let mut args: Vec<&dyn rusqlite::ToSql> =
                    binds.iter().map(|v| v as &dyn rusqlite::ToSql).collect();
                args.push(&PAGE);
                args.push(&sql_offset);

                let page = stmt
                    .query_map(args.as_slice(), row_to_mission)
                    .map_err(|e| e.to_string())?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| e.to_string())?;
                let page_len = page.len();
                if filter.attention_only {
                    let mut candidates = Vec::new();
                    for mission in page {
                        let mut non_attn = filter.clone();
                        non_attn.attention_only = false;
                        if non_attn.matches(&mission) {
                            candidates.push(mission);
                        }
                    }
                    matched = crate::api::mission_store::reconcile_sidebar_missions_page(
                        &matched,
                        &candidates,
                        true,
                    );
                } else {
                    for mission in page {
                        // The tag prefilter can over-select; this is the authority.
                        if filter.matches(&mission) {
                            matched.push(mission);
                            if matched.len() >= want {
                                break;
                            }
                        }
                    }
                }
                if matched.len() >= want || (page_len as i64) < PAGE {
                    break;
                }
                sql_offset += PAGE;
            }
            Ok(matched.into_iter().skip(offset).take(limit).collect())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    /// Indexed prefix seek on the primary key: `id` is TEXT PRIMARY KEY, so
    /// the range bounds below use its implicit index instead of scanning.
    pub(super) async fn find_missions_by_id_prefix(
        &self,
        prefix: &str,
        limit: usize,
    ) -> Result<Vec<Mission>, String> {
        let prefix = prefix.to_ascii_lowercase();
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // Half-open range over the PK. Incrementing the last byte gives the
            // exclusive upper bound for "everything starting with prefix";
            // mission ids are lowercase hex + hyphens, so the successor is
            // always representable.
            let mut upper = prefix.clone().into_bytes();
            match upper.last_mut() {
                Some(byte) if *byte < 0xFF => *byte += 1,
                _ => upper.push(0),
            }
            let upper = String::from_utf8_lossy(&upper).to_string();
            let mut stmt = conn
                .prepare(&format!(
                    "SELECT {MISSION_LIST_COLUMNS} FROM missions \
                     WHERE id >= ?1 AND id < ?2 \
                     ORDER BY updated_at DESC LIMIT ?3"
                ))
                .map_err(|e| e.to_string())?;
            let missions = stmt
                .query_map(params![prefix, upper, limit as i64], row_to_mission)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(missions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn count_missions_by_status(&self) -> Result<MissionStatusCounts, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare("SELECT status, COUNT(*) FROM missions GROUP BY status")
                .map_err(|e| e.to_string())?;

            let rows = stmt
                .query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                })
                .map_err(|e| e.to_string())?;

            let mut counts = MissionStatusCounts::default();
            for row in rows {
                let (status, count) = row.map_err(|e| e.to_string())?;
                let count = usize::try_from(count).unwrap_or(0);
                counts.add(parse_status(&status), count);
            }
            Ok(counts)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn count_missions_updated_since(
        &self,
        since: &str,
    ) -> Result<MissionStatusCounts, String> {
        let conn = self.reader();
        let since = since.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT status, COUNT(*) FROM missions WHERE updated_at >= ?1 GROUP BY status",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![since], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                })
                .map_err(|e| e.to_string())?;
            let mut counts = MissionStatusCounts::default();
            for row in rows {
                let (status, count) = row.map_err(|e| e.to_string())?;
                let count = usize::try_from(count).unwrap_or(0);
                counts.add(parse_status(&status), count);
            }
            Ok(counts)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn restore_mission_status(
        &self,
        id: Uuid,
        snapshot: &super::super::MissionStatusSnapshot,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let snapshot = snapshot.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(|e| e.to_string())?;
            let changed = tx
                .execute(
                    "UPDATE missions SET status=?2, interrupted_at=?3, paused_at=?4, resumable=?5,
                 terminal_reason=?6, first_viewed_at=?7, awaiting_kind=?8,
                 last_status_change_at=?9 WHERE id=?1 AND (status='active' OR status=?2)",
                    params![
                        id.to_string(),
                        status_to_string(snapshot.status),
                        snapshot.interrupted_at,
                        snapshot.paused_at,
                        snapshot.resumable,
                        snapshot.terminal_reason,
                        snapshot.first_viewed_at,
                        snapshot.awaiting_kind.map(|kind| kind.as_str().to_string()),
                        snapshot.last_status_change_at
                    ],
                )
                .map_err(|e| e.to_string())?;
            if changed != 1 {
                return Err("mission status changed during rejected activation".into());
            }
            // Evidence uses a side table, not a positional missions column.
            if let Some(evidence) = snapshot.terminal_evidence {
                tx.execute("INSERT INTO mission_terminal_evidence(mission_id, evidence, recorded_at) VALUES (?1, ?2, ?3)
                    ON CONFLICT(mission_id) DO UPDATE SET evidence=excluded.evidence", params![id.to_string(), evidence, now_string()]).map_err(|e| e.to_string())?;
            } else {
                tx.execute("DELETE FROM mission_terminal_evidence WHERE mission_id=?1", params![id.to_string()]).map_err(|e| e.to_string())?;
            }
            tx.commit().map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn set_terminal_evidence(
        &self,
        id: Uuid,
        evidence: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let evidence = evidence.chars().take(2000).collect::<String>();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO mission_terminal_evidence (mission_id, evidence, recorded_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(mission_id) DO UPDATE SET evidence = ?2, recorded_at = ?3",
                params![id_str, evidence, now_string()],
            )
            .map(|_| ())
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_mission(&self, id: Uuid) -> Result<Option<Mission>, String> {
        let conn = self.reader();
        let id_str = id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();

            // Get mission
            let mut stmt = conn
                .prepare(
                    "SELECT id, status, title, short_description, metadata_updated_at, metadata_source, metadata_model, metadata_version, workspace_id, workspace_name, agent, model_override,
                            model_effort,
                            created_at, updated_at, interrupted_at, resumable, desktop_sessions,
                            COALESCE(backend, 'opencode') as backend, session_id, terminal_reason,
                            config_profile, parent_mission_id, working_directory,
                            COALESCE(mission_mode, 'task') as mission_mode, COALESCE(goal_mode, 0) as goal_mode, goal_objective, first_viewed_at,
                            COALESCE(priority, 0) as priority, not_before, deadline, paused_at,
                            project, track, intent, github_pr, tags, desired_state, next_check_at, awaiting_kind, last_status_change_at,
                            COALESCE(fast_mode, 0) as fast_mode, origin, origin_session_id, COALESCE(requires_local_disk, 1) as requires_local_disk, service_tier FROM missions WHERE id = ?1",
                )
                .map_err(|e| e.to_string())?;

            let mission: Option<Mission> = stmt
                .query_row(params![&id_str], |row| {
                    let id_str: String = row.get(0)?;
                    let status_str: String = row.get(1)?;
                    let workspace_id_str: String = row.get(8)?;
                    let desktop_sessions_json: Option<String> = row.get(17)?;
                    let backend: String = row.get(18)?;
                    let session_id: Option<String> = row.get(19)?;
                    let terminal_reason: Option<String> = row.get(20)?;
                    let config_profile: Option<String> = row.get(21)?;
                    let (project, awaiting_kind, last_status_change_at) =
                        read_project_columns(row, 32)?;

                    Ok(Mission {
                        id: parse_uuid_or_nil(&id_str),
                        status: parse_status(&status_str),
                        title: row.get(2)?,
                        short_description: row.get(3)?,
                        metadata_updated_at: row.get(4)?,
                        metadata_source: row.get(5)?,
                        metadata_model: row.get(6)?,
                        metadata_version: row.get(7)?,
                        workspace_id: Uuid::parse_str(&workspace_id_str)
                            .unwrap_or(crate::workspace::DEFAULT_WORKSPACE_ID),
                        workspace_name: row.get(9)?,
                        agent: row.get(10)?,
                        model_override: row.get(11)?,
                        model_effort: row.get(12)?,
                        fast_mode: row.get::<_, i32>(41)? != 0,
                        service_tier: read_service_tier(row)?,
                        backend,
                        config_profile,
                        history: vec![],
                        created_at: row.get(13)?,
                        updated_at: row.get(14)?,
                        interrupted_at: row.get(15)?,
                        paused_at: row.get(31).ok().flatten(),
                        resumable: row.get::<_, i32>(16)? != 0,
                        desktop_sessions: desktop_sessions_json
                            .and_then(|s| serde_json::from_str(&s).ok())
                            .unwrap_or_default(),
                        session_id,
                        terminal_reason,
                        terminal_evidence: None,
                        parent_mission_id: row.get::<_, Option<String>>(22)?.and_then(|s| Uuid::parse_str(&s).ok()),
                        working_directory: row.get(23)?,
                        mission_mode: row.get::<_, Option<String>>(24)?
                            .and_then(|s| serde_json::from_value(serde_json::Value::String(s)).ok())
                            .unwrap_or_default(),
                            goal_mode: row.get::<_, i32>(25).unwrap_or(0) != 0,
                            goal_objective: row.get(26).ok().flatten(),
                            first_viewed_at: row.get(27).ok().flatten(),
                            scheduling: MissionScheduling {
                                priority: row.get::<_, i32>(28).unwrap_or(0),
                                not_before: row.get(29).ok().flatten(),
                                deadline: row.get(30).ok().flatten(),
                            },
                            project,
                            activity: MissionActivity {
                                last_status_change_at,
                                ..Default::default()
                            },
                            awaiting_kind,
                            origin: row.get(42).ok().flatten(),
                            origin_session_id: row.get(43).ok().flatten(),
                            requires_local_disk: row.get::<_, i32>(44).unwrap_or(1) != 0,
                    })
                })
                .optional()
                .map_err(|e| e.to_string())?;

            // Load history from events (limited to last 200 messages for performance).
            // Two single-type DESC branches let SQLite seek `idx_events_mission_type_sequence`
            // directly instead of walking all tool/delta events via `idx_events_mission`.
            if let Some(mut m) = mission {
                let mut history_stmt = conn
                    .prepare(
                        "SELECT event_type, content, content_file FROM (
                             SELECT * FROM (
                                 SELECT event_type, content, content_file, sequence
                                 FROM mission_events
                                 WHERE mission_id = ?1 AND event_type = 'user_message'
                                 ORDER BY sequence DESC
                                 LIMIT 200
                             )
                             UNION ALL
                             SELECT * FROM (
                                 SELECT event_type, content, content_file, sequence
                                 FROM mission_events
                                 WHERE mission_id = ?1 AND event_type = 'assistant_message'
                                 ORDER BY sequence DESC
                                 LIMIT 200
                             )
                             ORDER BY sequence DESC
                             LIMIT 200
                         ) ORDER BY sequence ASC",
                    )
                    .map_err(|e| e.to_string())?;

                let history: Vec<MissionHistoryEntry> = history_stmt
                    .query_map(params![&id_str], |row| {
                        let event_type: String = row.get(0)?;
                        let content: Option<String> = row.get(1)?;
                        let content_file: Option<String> = row.get(2)?;
                        let full_content =
                            SqliteMissionStore::load_content(content.as_deref(), content_file.as_deref());
                        Ok(MissionHistoryEntry {
                            role: if event_type == "user_message" {
                                "user".to_string()
                            } else {
                                "assistant".to_string()
                            },
                            content: full_content,
                        })
                    })
                    .map_err(|e| e.to_string())?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| e.to_string())?;

                m.history = history;
                if m.backend.starts_with("cloud_") {
                    let data: Option<String> = conn.query_row("SELECT data FROM cloud_executions WHERE mission_id=?1", [&id_str], |row| row.get(0)).optional().map_err(|e| e.to_string())?;
                    if let Some(data) = data {
                        let execution: crate::api::cloud_agents::Execution = serde_json::from_str(&data).map_err(|e| e.to_string())?;
                        m.history.clear();
                        for turn in execution.turns.iter().rev().take(100).collect::<Vec<_>>().into_iter().rev() {
                            m.history.push(MissionHistoryEntry {role:"user".into(),content:turn.prompt.clone()});
                            if let Some(result) = &turn.result { m.history.push(MissionHistoryEntry{role:"assistant".into(),content:result.clone()}); }
                        }
                    }
                }

                // Guard evidence lives in its own side table (see
                // run_migrations); the single-mission read is the one path
                // that carries it — list projections stay lean.
                m.terminal_evidence = conn
                    .query_row(
                        "SELECT evidence FROM mission_terminal_evidence WHERE mission_id = ?1",
                        params![&id_str],
                        |row| row.get::<_, String>(0),
                    )
                    .ok();
                Ok(Some(m))
            } else {
                Ok(None)
            }
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_mission_metadata(&self, id: Uuid) -> Result<Option<Mission>, String> {
        let conn = self.reader();
        let id_str = id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                &format!("SELECT {MISSION_LIST_COLUMNS} FROM missions WHERE id = ?1"),
                params![id_str],
                row_to_mission,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn existing_mission_ids(
        &self,
        ids: &[Uuid],
    ) -> Result<std::collections::HashSet<Uuid>, String> {
        if ids.is_empty() {
            return Ok(std::collections::HashSet::new());
        }
        let conn = self.reader();
        let unique_ids: Vec<Uuid> = {
            let mut seen = std::collections::HashSet::with_capacity(ids.len());
            ids.iter().copied().filter(|id| seen.insert(*id)).collect()
        };
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare("SELECT 1 FROM missions WHERE id = ?1 LIMIT 1")
                .map_err(|e| e.to_string())?;
            let mut found = std::collections::HashSet::with_capacity(unique_ids.len());
            for id in unique_ids {
                let exists = stmt
                    .query_row(params![id.to_string()], |_| Ok(()))
                    .optional()
                    .map_err(|e| e.to_string())?
                    .is_some();
                if exists {
                    found.insert(id);
                }
            }
            Ok(found)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_hermes_root_missions(&self) -> Result<Vec<Mission>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(&format!(
                    "SELECT {MISSION_LIST_COLUMNS}
                     FROM missions
                     WHERE parent_mission_id IS NULL
                       AND origin = 'hermes'
                       AND origin_session_id IS NOT NULL"
                ))
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map([], row_to_mission)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_initial_user_message(
        &self,
        id: Uuid,
    ) -> Result<Option<String>, String> {
        let conn = self.reader();
        let id_str = id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let row = conn
                .query_row(
                    "SELECT content, content_file FROM mission_events
                     WHERE mission_id = ?1 AND event_type = 'user_message'
                     ORDER BY sequence ASC LIMIT 1",
                    params![id_str],
                    |row| {
                        Ok((
                            row.get::<_, Option<String>>(0)?,
                            row.get::<_, Option<String>>(1)?,
                        ))
                    },
                )
                .optional()
                .map_err(|error| error.to_string())?;
            match row {
                Some((Some(content), _)) => Ok(Some(content)),
                Some((None, Some(path))) => std::fs::read_to_string(&path)
                    .map(Some)
                    .map_err(|error| format!("read initial mission prompt {path}: {error}")),
                _ => Ok(None),
            }
        })
        .await
        .map_err(|error| error.to_string())?
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) async fn create_mission_with_parent_and_placement(
        &self,
        title: Option<&str>,
        workspace_id: Option<Uuid>,
        agent: Option<&str>,
        model_override: Option<&str>,
        model_effort: Option<&str>,
        fast_mode: bool,
        backend: Option<&str>,
        config_profile: Option<&str>,
        parent_mission_id: Option<Uuid>,
        working_directory: Option<&str>,
        requires_local_disk: bool,
        assigned_id: Option<Uuid>,
    ) -> Result<Mission, String> {
        let conn = self.conn.clone();
        let now = now_string();
        let id = assigned_id.unwrap_or_else(Uuid::new_v4);
        // Inherit workspace from parent mission when not explicitly provided.
        let workspace_id = if let Some(ws) = workspace_id {
            ws
        } else if let Some(parent_id) = parent_mission_id {
            match self.get_mission(parent_id).await {
                Ok(Some(parent)) => parent.workspace_id,
                _ => crate::workspace::DEFAULT_WORKSPACE_ID,
            }
        } else {
            crate::workspace::DEFAULT_WORKSPACE_ID
        };
        let backend = backend.unwrap_or("claudecode").to_string();
        let metadata_source = title.and_then(|value| {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(METADATA_SOURCE_USER.to_string())
            }
        });
        let metadata_updated_at = metadata_source.as_ref().map(|_| now.clone());
        // Generate session_id for conversation persistence (used by Claude Code --session-id)
        let session_id = Uuid::new_v4().to_string();

        let mission = Mission {
            id,
            status: MissionStatus::Pending,
            title: title.map(|s| s.to_string()),
            short_description: None,
            metadata_updated_at,
            metadata_source,
            metadata_model: None,
            metadata_version: None,
            workspace_id,
            workspace_name: None,
            agent: agent.map(|s| s.to_string()),
            model_override: model_override.map(|s| s.to_string()),
            model_effort: model_effort.map(|s| s.to_string()),
            fast_mode,
            service_tier: None,
            backend: backend.clone(),
            config_profile: config_profile.map(|s| s.to_string()),
            history: vec![],
            created_at: now.clone(),
            updated_at: now.clone(),
            interrupted_at: None,
            paused_at: None,
            resumable: false,
            desktop_sessions: Vec::new(),
            session_id: (!matches!(backend.as_str(), "grok" | "antigravity" | "vibe"))
                .then(|| session_id.clone()),
            terminal_reason: None,
            terminal_evidence: None,
            parent_mission_id,
            working_directory: working_directory.map(|s| s.to_string()),
            requires_local_disk,
            mission_mode: MissionMode::default(),
            goal_mode: false,
            goal_objective: None,
            first_viewed_at: None,
            scheduling: Default::default(),
            project: MissionProject::default(),
            activity: MissionActivity::default(),
            awaiting_kind: None,
            origin: None,
            origin_session_id: None,
        };

        let m = mission.clone();
        let mission_mode_str = serde_json::to_value(&m.mission_mode)
            .ok()
            .and_then(|v| v.as_str().map(|s| s.to_string()))
            .unwrap_or_else(|| "task".to_string());
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO missions (id, status, title, short_description, metadata_updated_at, metadata_source, metadata_model, metadata_version, workspace_id, agent, model_override, model_effort, backend, config_profile, created_at, updated_at, resumable, session_id, parent_mission_id, working_directory, mission_mode, goal_mode, goal_objective, last_status_change_at, fast_mode, requires_local_disk)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26)",
                params![
                    m.id.to_string(),
                    status_to_string(m.status),
                    m.title,
                    m.short_description,
                    m.metadata_updated_at,
                    m.metadata_source,
                    m.metadata_model,
                    m.metadata_version,
                    m.workspace_id.to_string(),
                    m.agent,
                    m.model_override,
                    m.model_effort,
                    m.backend,
                    m.config_profile,
                    m.created_at,
                    m.updated_at,
                    0,
                    m.session_id,
                    m.parent_mission_id.map(|id| id.to_string()),
                    m.working_directory,
                    mission_mode_str,
                    if m.goal_mode { 1i64 } else { 0i64 },
                    m.goal_objective,
                    m.created_at,
                    if m.fast_mode { 1i64 } else { 0i64 },
                    if m.requires_local_disk { 1i64 } else { 0i64 },
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;

        Ok(mission)
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) async fn create_mission_with_parent(
        &self,
        title: Option<&str>,
        workspace_id: Option<Uuid>,
        agent: Option<&str>,
        model_override: Option<&str>,
        model_effort: Option<&str>,
        fast_mode: bool,
        backend: Option<&str>,
        config_profile: Option<&str>,
        parent_mission_id: Option<Uuid>,
        working_directory: Option<&str>,
    ) -> Result<Mission, String> {
        self.create_mission_with_parent_and_placement(
            title,
            workspace_id,
            agent,
            model_override,
            model_effort,
            fast_mode,
            backend,
            config_profile,
            parent_mission_id,
            working_directory,
            true,
            None,
        )
        .await
    }

    pub(super) async fn reparent_child_missions(
        &self,
        from: Uuid,
        to: Uuid,
    ) -> Result<Vec<Uuid>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare("UPDATE missions SET parent_mission_id = ?2 WHERE parent_mission_id = ?1 RETURNING id")
                .map_err(|e| e.to_string())?;
            let moved = stmt
                .query_map(params![from.to_string(), to.to_string()], |row| row.get::<_, String>(0))
                .map_err(|e| e.to_string())?
                .filter_map(|id| id.ok().and_then(|id| Uuid::parse_str(&id).ok()))
                .collect();
            Ok(moved)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_child_missions(&self, parent_id: Uuid) -> Result<Vec<Mission>, String> {
        let conn = self.reader();
        let parent_id_str = parent_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(&format!(
                    "SELECT {MISSION_LIST_COLUMNS} FROM missions WHERE parent_mission_id = ?1"
                ))
                .map_err(|e| e.to_string())?;
            let missions = stmt
                .query_map(params![parent_id_str], row_to_mission)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(missions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn set_mission_requires_local_disk(
        &self,
        id: Uuid,
        requires_local_disk: bool,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET requires_local_disk = ?1, updated_at = ?2 WHERE id = ?3",
                params![
                    if requires_local_disk { 1i64 } else { 0i64 },
                    now_string(),
                    id.to_string()
                ],
            )
            .map_err(|error| error.to_string())
            .and_then(|updated| {
                (updated == 1)
                    .then_some(())
                    .ok_or_else(|| format!("mission {id} not found while persisting placement"))
            })
        })
        .await
        .map_err(|error| error.to_string())?
    }

    pub(super) async fn update_mission_status(
        &self,
        id: Uuid,
        status: MissionStatus,
    ) -> Result<(), String> {
        self.update_mission_status_with_reason(id, status, None)
            .await
    }

    pub(super) async fn set_mission_scheduling(
        &self,
        id: Uuid,
        scheduling: &MissionScheduling,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let priority = scheduling.priority;
        let not_before = scheduling.not_before.clone();
        let deadline = scheduling.deadline.clone();
        let now = now_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET priority = ?1, not_before = ?2, deadline = ?3, updated_at = ?4 WHERE id = ?5",
                params![priority, not_before, deadline, now, id.to_string()],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn update_mission_status_with_reason(
        &self,
        id: Uuid,
        status: MissionStatus,
        terminal_reason: Option<&str>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let now = now_string();
        let interrupted_at =
            if matches!(status, MissionStatus::Interrupted | MissionStatus::Blocked) {
                Some(now.clone())
            } else {
                None
            };
        // Failed missions with LlmError are also resumable (transient API errors).
        // AwaitingUser missions are also resumable (the user can send another
        // message at any time to wake the agent back up).
        let resumable = matches!(
            status,
            MissionStatus::Interrupted
                | MissionStatus::Blocked
                | MissionStatus::Failed
                | MissionStatus::AwaitingUser
                | MissionStatus::Acknowledged
                | MissionStatus::WaitingBackground
        );
        let terminal_reason = terminal_reason.map(|s| s.to_string());
        // Transitioning back to Active means the user just sent a new message —
        // clear `first_viewed_at` so the next AwaitingUser round starts fresh
        // (and so the "opened" dot disappears once the agent picks up again).
        let clear_first_viewed_at = matches!(status, MissionStatus::Active);
        // `awaiting_kind` only describes an `AwaitingUser` mission. Any status
        // change away from AwaitingUser must clear it so a stale classification
        // can't leak to consumers once the mission is running/terminal again.
        let clear_awaiting_kind = !matches!(status, MissionStatus::AwaitingUser);

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            if status == MissionStatus::Acknowledged {
                let active_run = conn
                    .query_row(
                        "SELECT run_id FROM mission_runs WHERE mission_id = ?1 AND execution_state <> 'terminal' LIMIT 1",
                        params![id.to_string()],
                        |row| row.get::<_, String>(0),
                    )
                    .optional()
                    .map_err(|error| error.to_string())?;
                if let Some(run_id) = active_run {
                    return Err(format!(
                        "mission {id} cannot be acknowledged while run {run_id} is non-terminal"
                    ));
                }
            }
            // Read the old status before the UPDATE so we can decide whether
            // to invalidate the Paloma cooldown. Wiping cooldown on a
            // no-op status write (e.g. heartbeat that re-sets Active=Active)
            // would let "still running" alerts skip past the user's
            // exponential backoff and arrive too soon.
            let previous_status: Option<String> = conn
                .query_row(
                    "SELECT status FROM missions WHERE id = ?1",
                    params![id.to_string()],
                    |row| row.get(0),
                )
                .ok();
            let updated = if clear_first_viewed_at {
                conn.execute(
                    "UPDATE missions SET status = ?1, updated_at = ?2, interrupted_at = ?3, resumable = ?4, terminal_reason = ?5, first_viewed_at = NULL, awaiting_kind = CASE WHEN ?7 THEN NULL ELSE awaiting_kind END, last_status_change_at = CASE WHEN status <> ?1 THEN ?2 ELSE last_status_change_at END WHERE id = ?6",
                    params![
                        status_to_string(status),
                        now,
                        interrupted_at,
                        if resumable { 1 } else { 0 },
                        terminal_reason,
                        id.to_string(),
                        clear_awaiting_kind,
                    ],
                )
                .map_err(|e| e.to_string())?
            } else {
                conn.execute(
                    "UPDATE missions SET status = ?1, updated_at = ?2, interrupted_at = ?3, resumable = ?4, terminal_reason = ?5, awaiting_kind = CASE WHEN ?7 THEN NULL ELSE awaiting_kind END, last_status_change_at = CASE WHEN status <> ?1 THEN ?2 ELSE last_status_change_at END WHERE id = ?6",
                    params![
                        status_to_string(status),
                        now,
                        interrupted_at,
                        if resumable { 1 } else { 0 },
                        terminal_reason,
                        id.to_string(),
                        clear_awaiting_kind,
                    ],
                )
                .map_err(|e| e.to_string())?
            };
            if updated != 1 {
                return Err(format!(
                    "mission {id} not found while updating status to {}",
                    status_to_string(status)
                ));
            }
            // Only reset cooldown on a *genuine* status transition. Best
            // effort — if the table is missing or the row is gone, nothing
            // to do.
            let status_changed = previous_status.as_deref() != Some(status_to_string(status));
            if status_changed {
                let _ = conn.execute(
                    "DELETE FROM paloma_cooldown_state WHERE mission_id = ?1",
                    params![id.to_string()],
                );
            }
            Ok::<(), String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(())
    }

    pub(super) async fn update_mission_history(
        &self,
        id: Uuid,
        _history: &[MissionHistoryEntry],
    ) -> Result<(), String> {
        // For SQLite store, history is derived from events logged via log_event().
        // This method only updates the mission's updated_at timestamp.
        // Events are NOT inserted here to avoid race condition duplicates with the
        // event logger task that also inserts via log_event().
        let conn = self.conn.clone();
        let now = now_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();

            conn.execute(
                "UPDATE missions SET updated_at = ?1 WHERE id = ?2",
                params![&now, id.to_string()],
            )
            .map_err(|e| e.to_string())?;

            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn set_mission_first_viewed_at_if_unset(
        &self,
        id: Uuid,
        timestamp: &str,
    ) -> Result<Option<String>, String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let ts = timestamp.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let updated = conn
                .execute(
                    "UPDATE missions SET first_viewed_at = ?1 WHERE id = ?2 AND (first_viewed_at IS NULL OR first_viewed_at < ?1)",
                    params![&ts, &id_str],
                )
                .map_err(|e| e.to_string())?;
            Ok(if updated > 0 { Some(ts) } else { None })
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn acknowledge_stale_awaiting_user_missions(
        &self,
        grace_seconds: u64,
    ) -> Result<Vec<Uuid>, String> {
        let conn = self.conn.clone();
        let cutoff = (Utc::now() - chrono::Duration::seconds(grace_seconds as i64)).to_rfc3339();
        let now = now_string();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction().map_err(|e| e.to_string())?;
            let ids: Vec<Uuid> = {
                let mut stmt = tx
                    .prepare(
                        "SELECT id FROM missions
                         WHERE status = 'awaiting_user'
                           AND first_viewed_at IS NOT NULL
                           AND first_viewed_at <= ?1
                           AND NOT EXISTS (
                               SELECT 1 FROM mission_runs r
                               WHERE r.mission_id = missions.id AND r.execution_state <> 'terminal'
                           )",
                    )
                    .map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![&cutoff], |row| {
                        let id_str: String = row.get(0)?;
                        Ok(parse_uuid_or_nil(&id_str))
                    })
                    .map_err(|e| e.to_string())?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| e.to_string())?;
                rows
            };
            if !ids.is_empty() {
                tx.execute(
                    "UPDATE missions SET status = 'acknowledged', updated_at = ?1
                     WHERE status = 'awaiting_user'
                       AND first_viewed_at IS NOT NULL
                       AND first_viewed_at <= ?2
                       AND NOT EXISTS (
                           SELECT 1 FROM mission_runs r
                           WHERE r.mission_id = missions.id AND r.execution_state <> 'terminal'
                       )",
                    params![&now, &cutoff],
                )
                .map_err(|e| e.to_string())?;
            }
            tx.commit().map_err(|e| e.to_string())?;
            Ok(ids)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_waiting_background_mission_ids(&self) -> Result<Vec<Uuid>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare("SELECT id FROM missions WHERE status = 'waiting_background'")
                .map_err(|e| e.to_string())?;
            let ids = stmt
                .query_map([], |row| {
                    let id_str: String = row.get(0)?;
                    Ok(parse_uuid_or_nil(&id_str))
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(ids)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn update_mission_desktop_sessions(
        &self,
        id: Uuid,
        sessions: &[DesktopSessionInfo],
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let now = now_string();
        let sessions_json = serde_json::to_string(sessions).unwrap_or_else(|_| "[]".to_string());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET desktop_sessions = ?1, updated_at = ?2 WHERE id = ?3",
                params![sessions_json, now, id.to_string()],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn update_mission_title(&self, id: Uuid, title: &str) -> Result<(), String> {
        let conn = self.conn.clone();
        let now = now_string();
        let title = title.to_string();
        let source = "user".to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions
                 SET title = ?1,
                     metadata_source = ?2,
                     metadata_model = NULL,
                     metadata_version = NULL,
                     metadata_updated_at = ?3,
                     updated_at = ?4
                 WHERE id = ?5",
                params![title, source, now.clone(), now, id.to_string()],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) async fn update_mission_run_settings(
        &self,
        id: Uuid,
        backend: Option<&str>,
        agent: Option<Option<&str>>,
        model_override: Option<Option<&str>>,
        model_effort: Option<Option<&str>>,
        fast_mode: Option<bool>,
        service_tier: Option<crate::codex_speed::Tier>,
        config_profile: Option<Option<&str>>,
        session_id: &str,
    ) -> Result<Mission, String> {
        let fast_mode = service_tier
            .map(|tier| tier == crate::codex_speed::Tier::Fast)
            .or(fast_mode);
        let conn = self.conn.clone();
        let now = now_string();
        let backend_set = backend.is_some();
        let agent_set = agent.is_some();
        let model_override_set = model_override.is_some();
        let model_effort_set = model_effort.is_some();
        let tier = service_tier
            .or(fast_mode.map(|fast| crate::codex_speed::Tier::from_legacy(None, fast)));
        let tier_set = tier.is_some();
        let tier = tier.map(|value| value.id().to_string());
        let fast_mode_set = fast_mode.is_some();
        let config_profile_set = config_profile.is_some();
        let backend = backend.map(ToString::to_string);
        let agent = agent.flatten().map(ToString::to_string);
        let model_override = model_override.flatten().map(ToString::to_string);
        let model_effort = model_effort.flatten().map(ToString::to_string);
        let config_profile = config_profile.flatten().map(ToString::to_string);
        let session_id = session_id.to_string();
        let id_str = id.to_string();

        tokio::task::spawn_blocking(move || {
            let mut connection = conn.blocking_lock();
            let conn = connection.transaction().map_err(|e| e.to_string())?;
            let (old_backend, old_session): (String, Option<String>) = conn.query_row(
                "SELECT COALESCE(backend, 'opencode'), session_id FROM missions WHERE id = ?1",
                params![id_str], |row| Ok((row.get(0)?, row.get(1)?)),
            ).map_err(|e| e.to_string())?;
            let target = backend.as_deref().unwrap_or(&old_backend);
            let selected_session = if target == old_backend {
                old_session
            } else {
                if let Some(previous) = old_session {
                    conn.execute(
                        "INSERT INTO mission_harness_sessions (mission_id, backend, session_id) VALUES (?1, ?2, ?3)
                         ON CONFLICT(mission_id, backend) DO UPDATE SET session_id = excluded.session_id",
                        params![id_str, old_backend, previous],
                    ).map_err(|e| e.to_string())?;
                }
                conn.query_row(
                    "SELECT session_id FROM mission_harness_sessions WHERE mission_id = ?1 AND backend = ?2",
                    params![id_str, target], |row| row.get::<_, String>(0),
                ).optional().map_err(|e| e.to_string())?
                    .or_else(|| (!matches!(target, "grok" | "antigravity" | "vibe")).then(|| session_id.clone()))
            };
            let changed = conn
                .execute(
                    "UPDATE missions
                     SET backend = CASE WHEN ?1 THEN ?2 ELSE backend END,
                         agent = CASE WHEN ?3 THEN ?4 ELSE agent END,
                         model_override = CASE WHEN ?5 THEN ?6 ELSE model_override END,
                         model_effort = CASE WHEN ?7 THEN ?8 ELSE model_effort END,
                         fast_mode = CASE WHEN ?9 THEN ?10 ELSE fast_mode END,
                         config_profile = CASE WHEN ?11 THEN ?12 ELSE config_profile END,
                         session_id = ?13,
                         service_tier = CASE WHEN ?16 THEN ?17 ELSE service_tier END,
                         updated_at = ?14
                     WHERE id = ?15",
                    params![
                        backend_set,
                        backend,
                        agent_set,
                        agent,
                        model_override_set,
                        model_override,
                        model_effort_set,
                        model_effort,
                        fast_mode_set,
                        fast_mode,
                        config_profile_set,
                        config_profile,
                        selected_session,
                        now,
                        id_str,
                        tier_set,
                        tier,
                    ],
                )
                .map_err(|e| e.to_string())?;
            if changed == 0 {
                return Err(format!("Mission {} not found", id_str));
            }
            conn.commit().map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())??;

        self.get_mission(id)
            .await?
            .ok_or_else(|| format!("Mission {} not found", id))
    }

    pub(super) async fn update_mission_metadata(
        &self,
        id: Uuid,
        title: Option<Option<&str>>,
        short_description: Option<Option<&str>>,
        metadata_source: Option<Option<&str>>,
        metadata_model: Option<Option<&str>>,
        metadata_version: Option<Option<&str>>,
    ) -> Result<(), String> {
        if title.is_none()
            && short_description.is_none()
            && metadata_source.is_none()
            && metadata_model.is_none()
            && metadata_version.is_none()
        {
            return Ok(());
        }

        let conn = self.conn.clone();
        let now = now_string();
        let title_set = title.is_some();
        let short_description_set = short_description.is_some();
        let metadata_source_set = metadata_source.is_some();
        let metadata_model_set = metadata_model.is_some();
        let metadata_version_set = metadata_version.is_some();
        let title = title.flatten().map(|s| s.to_string());
        let short_description = short_description.flatten().map(|s| s.to_string());
        let metadata_source = metadata_source.flatten().map(|s| s.to_string());
        let metadata_model = metadata_model.flatten().map(|s| s.to_string());
        let metadata_version = metadata_version.flatten().map(|s| s.to_string());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions
                 SET title = CASE WHEN ?1 THEN ?2 ELSE title END,
                     short_description = CASE WHEN ?3 THEN ?4 ELSE short_description END,
                     metadata_source = CASE WHEN ?5 THEN ?6 ELSE metadata_source END,
                     metadata_model = CASE WHEN ?7 THEN ?8 ELSE metadata_model END,
                     metadata_version = CASE WHEN ?9 THEN ?10 ELSE metadata_version END,
                     metadata_updated_at = ?11,
                     updated_at = ?11
                 WHERE id = ?12",
                params![
                    title_set,
                    title,
                    short_description_set,
                    short_description,
                    metadata_source_set,
                    metadata_source,
                    metadata_model_set,
                    metadata_model,
                    metadata_version_set,
                    metadata_version,
                    now,
                    id.to_string()
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn update_mission_project(
        &self,
        id: Uuid,
        patch: MissionProjectPatch,
    ) -> Result<(), String> {
        if patch.is_empty() {
            return Ok(());
        }

        let conn = self.conn.clone();
        let now = now_string();
        let title_set = patch.title.is_some();
        let title = patch.title.flatten();
        let project_set = patch.project.is_some();
        let track_set = patch.track.is_some();
        let intent_set = patch.intent.is_some();
        let github_pr_set = patch.github_pr.is_some();
        let tags_set = patch.tags.is_some() || patch.tag_patch.is_some();
        let desired_state_set = patch.desired_state.is_some();
        let next_check_at_set = patch.next_check_at.is_some();
        let project = patch.project.flatten();
        let track = patch.track.flatten();
        let intent = patch.intent.flatten();
        let github_pr = patch.github_pr.flatten();
        let mut tags_json = patch.tags.as_deref().and_then(tags_to_json);
        let desired_state = patch.desired_state.flatten();
        let next_check_at = patch.next_check_at.flatten();

        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(|e| e.to_string())?;
            if let Some(delta) = patch.tag_patch {
                let raw: Option<String> = tx
                    .query_row(
                        "SELECT tags FROM missions WHERE id=?1",
                        params![id.to_string()],
                        |row| row.get(0),
                    )
                    .map_err(|e| e.to_string())?;
                let mut tags: Vec<String> = match tags_json.as_ref().or(raw.as_ref()) {
                    Some(raw) => serde_json::from_str(raw).map_err(|e| e.to_string())?,
                    None => Vec::new(),
                };
                delta.apply(&mut tags);
                tags_json = tags_to_json(&tags);
            }
            tx.execute(
                "UPDATE missions
                 SET project = CASE WHEN ?1 THEN ?2 ELSE project END,
                     track = CASE WHEN ?3 THEN ?4 ELSE track END,
                     intent = CASE WHEN ?5 THEN ?6 ELSE intent END,
                     github_pr = CASE WHEN ?7 THEN ?8 ELSE github_pr END,
                     tags = CASE WHEN ?9 THEN ?10 ELSE tags END,
                     desired_state = CASE WHEN ?11 THEN ?12 ELSE desired_state END,
                     next_check_at = CASE WHEN ?13 THEN ?14 ELSE next_check_at END,
                     updated_at = CASE WHEN ?19 THEN updated_at ELSE ?15 END,
                     title = CASE WHEN ?17 THEN ?18 ELSE title END
                 WHERE id = ?16",
                params![
                    project_set,
                    project,
                    track_set,
                    track,
                    intent_set,
                    intent,
                    github_pr_set,
                    github_pr,
                    tags_set,
                    tags_json,
                    desired_state_set,
                    desired_state,
                    next_check_at_set,
                    next_check_at,
                    now,
                    id.to_string(),
                    title_set,
                    title,
                    patch.preserve_updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            tx.commit().map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn set_mission_origin(
        &self,
        id: Uuid,
        origin: &str,
        origin_session_id: Option<&str>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let origin = origin.to_string();
        let origin_session_id = origin_session_id.map(|s| s.to_string());
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET origin = ?1, origin_session_id = ?2 WHERE id = ?3",
                params![origin, origin_session_id, id.to_string()],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_mission_activity(
        &self,
        ids: &[Uuid],
    ) -> Result<std::collections::HashMap<Uuid, (Option<String>, Option<String>)>, String> {
        if ids.is_empty() {
            return Ok(std::collections::HashMap::new());
        }
        let conn = self.reader();
        let id_strings: Vec<String> = ids.iter().map(|id| id.to_string()).collect();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let placeholders = vec!["?"; id_strings.len()].join(",");
            // last_agent_event_at = newest event of any kind; last_output_at =
            // newest assistant message (assistant text is logged as either
            // `assistant_message` or `assistant_message_canonical`). Backed by
            // idx_events_mission_timestamp.
            let sql = format!(
                "SELECT mission_id, MAX(timestamp) AS last_event, \
                 MAX(CASE WHEN event_type IN ('assistant_message', 'assistant_message_canonical') THEN timestamp END) AS last_output \
                 FROM mission_events WHERE mission_id IN ({placeholders}) GROUP BY mission_id"
            );
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(rusqlite::params_from_iter(id_strings.iter()), |row| {
                    let mid: String = row.get(0)?;
                    let last_event: Option<String> = row.get(1)?;
                    let last_output: Option<String> = row.get(2)?;
                    Ok((mid, last_event, last_output))
                })
                .map_err(|e| e.to_string())?;
            let mut out = std::collections::HashMap::new();
            for row in rows {
                let (mid, last_event, last_output) = row.map_err(|e| e.to_string())?;
                if let Ok(uuid) = Uuid::parse_str(&mid) {
                    out.insert(uuid, (last_event, last_output));
                }
            }
            Ok(out)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_mission_summaries(
        &self,
        ids: &[Uuid],
    ) -> Result<std::collections::HashMap<Uuid, MissionSummary>, String> {
        if ids.is_empty() {
            return Ok(std::collections::HashMap::new());
        }
        let conn = self.reader();
        let id_strings: Vec<String> = ids.iter().map(|id| id.to_string()).collect();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let placeholders = vec!["?"; id_strings.len()].join(",");
            let sql = format!(
                "SELECT id, title, status, workspace_name, awaiting_kind, \
                 origin_session_id, updated_at, last_status_change_at \
                 FROM missions WHERE id IN ({placeholders})"
            );
            let now = chrono::Utc::now();
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(rusqlite::params_from_iter(id_strings.iter()), |row| {
                    let mid: String = row.get(0)?;
                    let status: String = row.get(2)?;
                    let awaiting_kind: Option<String> = row.get(4)?;
                    let origin_session_id: Option<String> = row.get(5)?;
                    let updated_at: String = row.get(6)?;
                    let last_status_change_at: Option<String> = row.get(7)?;
                    let persisted_clock = last_status_change_at
                        .as_deref()
                        .unwrap_or(updated_at.as_str());
                    let parsed_status =
                        serde_json::from_value::<crate::api::control::events::MissionStatus>(
                            serde_json::Value::String(status.clone()),
                        )
                        .unwrap_or(crate::api::control::events::MissionStatus::Active);
                    let needs_operator = crate::api::operator_attention::needs_operator(
                        &crate::api::operator_attention::OperatorAttentionInput {
                            status: parsed_status,
                            awaiting_kind: awaiting_kind.as_deref(),
                            has_origin_session: origin_session_id
                                .as_deref()
                                .is_some_and(|id| !id.is_empty()),
                            updated_at: persisted_clock,
                            waiting_for_user_tool: false,
                            wait_started_at: None,
                        },
                        now,
                    );
                    Ok((
                        mid,
                        MissionSummary {
                            title: row.get(1)?,
                            status,
                            workspace_name: row.get(3)?,
                            awaiting_kind,
                            needs_operator,
                            origin_session_id,
                            updated_at,
                        },
                    ))
                })
                .map_err(|e| e.to_string())?;
            let mut out = std::collections::HashMap::new();
            for row in rows {
                let (mid, summary) = row.map_err(|e| e.to_string())?;
                if let Ok(uuid) = Uuid::parse_str(&mid) {
                    out.insert(uuid, summary);
                }
            }
            Ok(out)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn set_mission_awaiting_kind(
        &self,
        id: Uuid,
        kind: Option<AwaitingKind>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let kind_str = kind.map(|k| k.as_str().to_string());
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET awaiting_kind = ?1 WHERE id = ?2",
                params![kind_str, id.to_string()],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn update_mission_goal(
        &self,
        id: Uuid,
        goal_mode: bool,
        goal_objective: Option<&str>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let now = now_string();
        let goal_objective = goal_objective.map(|s| s.to_string());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET goal_mode = ?1, goal_objective = ?2, updated_at = ?3 WHERE id = ?4",
                params![
                    if goal_mode { 1i64 } else { 0i64 },
                    goal_objective,
                    now,
                    id.to_string()
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn update_mission_tree(
        &self,
        id: Uuid,
        tree: &AgentTreeNode,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let now = now_string();
        let tree_json = serde_json::to_string(tree).map_err(|e| e.to_string())?;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT OR REPLACE INTO mission_trees (mission_id, tree_json, updated_at)
                 VALUES (?1, ?2, ?3)",
                params![id.to_string(), tree_json, now],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_mission_tree(&self, id: Uuid) -> Result<Option<AgentTreeNode>, String> {
        let conn = self.reader();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let tree_json: Option<String> = conn
                .query_row(
                    "SELECT tree_json FROM mission_trees WHERE mission_id = ?1",
                    params![id.to_string()],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|e| e.to_string())?;

            if let Some(json) = tree_json {
                let tree: AgentTreeNode = serde_json::from_str(&json).map_err(|e| e.to_string())?;
                Ok(Some(tree))
            } else {
                Ok(None)
            }
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn delete_mission(&self, id: Uuid) -> Result<bool, String> {
        let conn = self.conn.clone();

        let removed = tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let rows = conn
                .execute(
                    "DELETE FROM missions WHERE id = ?1",
                    params![id.to_string()],
                )
                .map_err(|e| e.to_string())?;
            Ok::<bool, String>(rows > 0)
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(removed)
    }

    pub(super) async fn delete_empty_untitled_missions_excluding(
        &self,
        exclude: &[Uuid],
    ) -> Result<usize, String> {
        let conn = self.conn.clone();
        let exclude_strs: Vec<String> = exclude.iter().map(|id| id.to_string()).collect();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();

            // Find missions to delete
            let mut stmt = conn
                .prepare(
                    "SELECT m.id, COALESCE(goal_mode, 0) as goal_mode, goal_objective FROM missions m
                     LEFT JOIN mission_events e ON m.id = e.mission_id AND e.event_type IN ('user_message', 'assistant_message')
                     WHERE m.status = 'active'
                       AND (m.title IS NULL OR m.title = '' OR m.title = 'Untitled Mission')
                     GROUP BY m.id
                     HAVING COUNT(e.id) = 0",
                )
                .map_err(|e| e.to_string())?;

            let to_delete: Vec<String> = stmt
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(|e| e.to_string())?
                .filter_map(|r| r.ok())
                .filter(|id| !exclude_strs.contains(id))
                .collect();

            let count = to_delete.len();
            for id in to_delete {
                conn.execute("DELETE FROM missions WHERE id = ?1", params![id])
                    .ok();
            }

            Ok(count)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_stale_active_missions(
        &self,
        stale_hours: u64,
    ) -> Result<Vec<Mission>, String> {
        if stale_hours == 0 {
            return Ok(Vec::new());
        }

        let conn = self.reader();
        let cutoff = Utc::now() - chrono::Duration::hours(stale_hours as i64);
        let cutoff_str = cutoff.to_rfc3339();

        // A mission is stale only when *both* its metadata `updated_at` and
        // its newest event are older than the cutoff. Previously the query
        // looked at `updated_at` alone, but `updated_at` is bumped by
        // `update_mission_history` (assistant-turn boundary) and metadata
        // writes — not by individual `tool_call` / `tool_result` events. A
        // long agent run that's actively producing tool calls but no
        // assistant turns for >2h (e.g. waiting on a CI build via repeated
        // `gh run watch` invocations) would falsely trip this scan. Joining
        // against `mission_events.timestamp` ties the stale signal to real
        // activity.
        //
        // We compute `MAX(timestamp)` rather than the timestamp of the row
        // with the highest `sequence`: `log_event` updates an existing row
        // in-place when it sees a duplicate `event_id` (e.g. the
        // `text_delta_latest` row gets its `timestamp` rewritten on every
        // streamed delta), so a higher-sequence row can carry an *older*
        // timestamp than a refreshed lower-sequence row. The query is backed
        // by `idx_events_mission_timestamp(mission_id, timestamp DESC)` so
        // the per-mission MAX is an O(log n) seek; missions with no events
        // fall back to `updated_at` via COALESCE.
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // Must use MISSION_LIST_COLUMNS / row_to_mission so origin +
            // project.tags survive. A stub projection left those empty and
            // the 2h cleanup treated Hermes writers as untagged (#842 skip
            // never fired on 08306fdb / 203a49d5).
            let sql = format!(
                "SELECT {MISSION_LIST_COLUMNS} FROM missions
                 WHERE status = 'active'
                   AND max(
                         updated_at,
                         COALESCE(
                           (SELECT MAX(timestamp) FROM mission_events
                            WHERE mission_id = missions.id),
                           updated_at
                         )
                       ) < ?1"
            );
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;

            let missions = stmt
                .query_map(params![cutoff_str], row_to_mission)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(missions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_all_active_missions(&self) -> Result<Vec<Mission>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // Recovery decisions require placement tags, origin and project
            // metadata. A reduced projection silently classified native Orb
            // processes as orphaned Core runs after a service restart.
            let sql =
                format!("SELECT {MISSION_LIST_COLUMNS} FROM missions WHERE status = 'active'");
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
            let missions = stmt
                .query_map(params![], row_to_mission)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(missions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn set_deferred_goal(
        &self,
        mission_id: Uuid,
        goal: Option<String>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let id = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET deferred_goal = ?1 WHERE id = ?2",
                params![goal, id],
            )
            .map_err(|e| e.to_string())?;
            Ok::<(), String>(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_deferred_goal(
        &self,
        mission_id: Uuid,
    ) -> Result<Option<String>, String> {
        let conn = self.reader();
        let id = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT deferred_goal FROM missions WHERE id = ?1",
                params![id],
                |row| row.get::<_, Option<String>>(0),
            )
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn set_mission_paused_at(
        &self,
        mission_id: Uuid,
        paused_at: Option<String>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let id = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET paused_at = ?1 WHERE id = ?2",
                params![paused_at, id],
            )
            .map_err(|e| e.to_string())?;
            Ok::<(), String>(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_scheduled_pending_missions(&self) -> Result<Vec<Mission>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let sql = format!(
                "SELECT id, status, title, workspace_id, workspace_name, agent, model_override,
                            created_at, updated_at, interrupted_at, resumable, desktop_sessions,
                            COALESCE(backend, 'opencode') as backend,
                            COALESCE(mission_mode, 'task') as mission_mode,
                            COALESCE(goal_mode, 0) as goal_mode,
                            goal_objective,
                            COALESCE(priority, 0) as priority, not_before, deadline
                     FROM missions
                     WHERE status = 'pending' AND deferred_goal IS NOT NULL{}
                     ORDER BY created_at ASC",
                crate::api::control::client_placement::SQL_EXCLUDE
            );
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;

            let missions = stmt
                .query_map(params![], |row| {
                    let id_str: String = row.get(0)?;
                    let status_str: String = row.get(1)?;
                    let workspace_id_str: String = row.get(3)?;
                    let desktop_sessions_json: Option<String> = row.get(11)?;
                    let backend: String = row.get(12)?;

                    Ok(Mission {
                        id: parse_uuid_or_nil(&id_str),
                        status: parse_status(&status_str),
                        title: row.get(2)?,
                        short_description: None,
                        metadata_updated_at: None,
                        metadata_source: None,
                        metadata_model: None,
                        metadata_version: None,
                        workspace_id: Uuid::parse_str(&workspace_id_str)
                            .unwrap_or(crate::workspace::DEFAULT_WORKSPACE_ID),
                        workspace_name: row.get(4)?,
                        agent: row.get(5)?,
                        model_override: row.get(6)?,
                        model_effort: None,
                        fast_mode: false,
                        service_tier: None,
                        backend,
                        config_profile: None,
                        history: vec![],
                        created_at: row.get(7)?,
                        updated_at: row.get(8)?,
                        interrupted_at: row.get(9)?,
                        paused_at: None,
                        resumable: row.get::<_, i32>(10)? != 0,
                        desktop_sessions: desktop_sessions_json
                            .and_then(|s| serde_json::from_str(&s).ok())
                            .unwrap_or_default(),
                        session_id: None,
                        terminal_reason: None,
                        terminal_evidence: None,
                        parent_mission_id: None,
                        working_directory: None,
                        requires_local_disk: true,
                        mission_mode: row
                            .get::<_, Option<String>>(13)?
                            .and_then(|s| serde_json::from_value(serde_json::Value::String(s)).ok())
                            .unwrap_or_default(),
                        goal_mode: row.get::<_, i32>(14).unwrap_or(0) != 0,
                        goal_objective: row.get(15).ok().flatten(),
                        first_viewed_at: None,
                        scheduling: MissionScheduling {
                            priority: row.get::<_, i32>(16).unwrap_or(0),
                            not_before: row.get(17).ok().flatten(),
                            deadline: row.get(18).ok().flatten(),
                        },
                        project: MissionProject::default(),
                        activity: MissionActivity::default(),
                        awaiting_kind: None,
                        origin: None,
                        origin_session_id: None,
                    })
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(missions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_recent_server_shutdown_mission_ids(
        &self,
        max_age_hours: u64,
    ) -> Result<Vec<Uuid>, String> {
        let conn = self.conn.clone();
        let cutoff = Utc::now() - chrono::Duration::hours(max_age_hours as i64);
        let cutoff_str = cutoff.to_rfc3339();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id
                     FROM missions
                     WHERE status = 'interrupted'
                       AND resumable = 1
                       AND terminal_reason IN ('server_shutdown', 'service_restart')
                       AND COALESCE(mission_mode, 'task') != 'assistant'
                       AND interrupted_at IS NOT NULL
                       AND interrupted_at >= ?1
                     ORDER BY interrupted_at ASC",
                )
                .map_err(|e| e.to_string())?;

            let mission_ids = stmt
                .query_map(params![cutoff_str], |row| {
                    let id_str: String = row.get(0)?;
                    Ok(parse_uuid_or_nil(&id_str))
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(mission_ids)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn insert_mission_summary(
        &self,
        mission_id: Uuid,
        summary: &str,
        key_files: &[String],
        success: bool,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let now = now_string();
        let summary = summary.to_string();
        let key_files_json = serde_json::to_string(key_files).unwrap_or_else(|_| "[]".to_string());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO mission_summaries (mission_id, summary, key_files, success, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    mission_id.to_string(),
                    summary,
                    key_files_json,
                    if success { 1 } else { 0 },
                    now,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn latest_assistant_text(
        &self,
        mission_id: Uuid,
    ) -> Result<Option<String>, String> {
        let conn = self.reader();
        let id_str = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let row = conn
                .query_row(
                    "SELECT content, content_file FROM (
                         SELECT * FROM (
                             SELECT content, content_file, sequence FROM mission_events
                             WHERE mission_id = ?1 AND event_type = 'assistant_message'
                             ORDER BY sequence DESC LIMIT 1
                         )
                         UNION ALL
                         SELECT * FROM (
                             SELECT content, content_file, sequence FROM mission_events
                             WHERE mission_id = ?1 AND event_type = 'assistant_message_canonical'
                             ORDER BY sequence DESC LIMIT 1
                         )
                         ORDER BY sequence DESC LIMIT 1
                     )",
                    params![id_str],
                    |row| {
                        let content: Option<String> = row.get(0)?;
                        let content_file: Option<String> = row.get(1)?;
                        Ok((content, content_file))
                    },
                )
                .optional()
                .map_err(|e| e.to_string())?;
            Ok(match row {
                Some((content, content_file)) => {
                    let text = Self::load_content(content.as_deref(), content_file.as_deref());
                    let trimmed = text.trim();
                    if trimmed.is_empty() {
                        None
                    } else {
                        Some(trimmed.to_string())
                    }
                }
                None => None,
            })
        })
        .await
        .map_err(|e| e.to_string())?
    }

    // === Event logging methods ===

    pub(super) async fn get_remote_log_offset(&self, job_id: Uuid) -> Option<u64> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT published_offset FROM remote_log_offsets WHERE job_id = ?1",
                params![job_id.to_string()],
                |row| row.get::<_, i64>(0),
            )
            .ok()
            .and_then(|v| u64::try_from(v).ok())
        })
        .await
        .ok()
        .flatten()
    }

    pub(super) async fn set_remote_log_offset(&self, job_id: Uuid, offset: u64) {
        let conn = self.conn.clone();
        let _ = tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let _ = conn.execute(
                "INSERT INTO remote_log_offsets (job_id, published_offset, updated_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(job_id) DO UPDATE SET
                    published_offset = MAX(published_offset, excluded.published_offset),
                    updated_at = excluded.updated_at",
                params![job_id.to_string(), offset as i64, now_string()],
            );
            // Rows of long-finished jobs are useless; keep the table small.
            let _ = conn.execute(
                "DELETE FROM remote_log_offsets WHERE updated_at < ?1",
                params![(chrono::Utc::now() - chrono::Duration::days(14)).to_rfc3339()],
            );
        })
        .await;
    }

    pub(super) async fn update_mission_mode(
        &self,
        id: Uuid,
        mode: MissionMode,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let mode_str = serde_json::to_value(&mode)
            .ok()
            .and_then(|v| v.as_str().map(|s| s.to_string()))
            .unwrap_or_else(|| "task".to_string());
        let now = now_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE missions SET mission_mode = ?1, updated_at = ?2 WHERE id = ?3",
                params![mode_str, now, id_str],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    pub(super) async fn list_assistant_missions(&self) -> Result<Vec<Mission>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, status, title, workspace_id, agent, backend, created_at, updated_at, mission_mode, short_description, COALESCE(goal_mode, 0) as goal_mode, goal_objective FROM missions WHERE mission_mode = 'assistant' ORDER BY updated_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let missions = stmt
                .query_map([], |row| {
                    let id_str: String = row.get(0).unwrap_or_default();
                    let status_str: String = row.get(1).unwrap_or_else(|_| "pending".to_string());
                    let workspace_id_str: String = row.get(3).unwrap_or_default();
                    let mode_str: String = row.get(8).unwrap_or_else(|_| "task".to_string());
                    Ok(Mission {
                        id: Uuid::parse_str(&id_str).unwrap_or_default(),
                        status: serde_json::from_value(serde_json::Value::String(status_str))
                            .unwrap_or(MissionStatus::Pending),
                        title: row.get(2).unwrap_or_default(),
                        short_description: row.get(9).unwrap_or_default(),
                        metadata_updated_at: None,
                        metadata_source: None,
                        metadata_model: None,
                        metadata_version: None,
                        workspace_id: Uuid::parse_str(&workspace_id_str).unwrap_or_default(),
                        workspace_name: None,
                        agent: row.get(4).unwrap_or_default(),
                        model_override: None,
                        model_effort: None,
                        fast_mode: false,
                        service_tier: None,
                        backend: row.get(5).unwrap_or_else(|_| "claudecode".to_string()),
                        config_profile: None,
                        history: vec![],
                        created_at: row.get(6).unwrap_or_default(),
                        updated_at: row.get(7).unwrap_or_default(),
                        interrupted_at: None,
                        paused_at: None,
                        resumable: false,
                        desktop_sessions: vec![],
                        session_id: None,
                        terminal_reason: None,
                        terminal_evidence: None,
                        parent_mission_id: None,
                        working_directory: None,
                        requires_local_disk: true,
                        mission_mode: serde_json::from_value(serde_json::Value::String(mode_str))
                            .unwrap_or_default(),
                        goal_mode: false,
                        goal_objective: None,
                        first_viewed_at: None,
                        scheduling: Default::default(),
                        project: MissionProject::default(),
                        activity: MissionActivity::default(),
                        awaiting_kind: None,
                        origin: None,
                        origin_session_id: None,
                    })
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(missions)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }
}
