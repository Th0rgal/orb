//! Mission runs, tool executions and native-prompt/session leases.

use super::*;

impl SqliteMissionStore {
    pub(super) async fn begin_mission_run(
        &self,
        mission_id: Uuid,
        owner_actor_id: &str,
        scope_unit: Option<&str>,
    ) -> Result<MissionRun, String> {
        let conn = self.conn.clone();
        let owner_actor_id = owner_actor_id.to_string();
        let scope_unit = scope_unit.map(str::to_string);
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(|error| error.to_string())?;
            machine_transfer::guard_start(&tx, mission_id)?;
            machine_transfer::guard_placement(&tx,mission_id,&owner_actor_id,scope_unit.as_deref())?;
            let cwd=scope_unit.as_deref().and_then(|s|s.strip_prefix("orb-cwd:"));
            machine_transfer::guard_workspace(&tx,mission_id,cwd)?;
            let mission_status = tx
                .query_row(
                    "SELECT status FROM missions WHERE id = ?1",
                    params![mission_id.to_string()],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(|error| error.to_string())?;
            let Some(mission_status) = mission_status else {
                return Err(format!("mission not found: {mission_id}"));
            };
            if mission_status == "acknowledged" {
                return Err(format!(
                    "acknowledged mission {mission_id} cannot acquire a non-terminal run"
                ));
            }
            if !owner_actor_id.starts_with("orb-client:") && !matches!(mission_status.as_str(), "pending" | "active") {
                return Err(format!(
                    "mission {mission_id} has status {mission_status}; activate it before acquiring a non-terminal run"
                ));
            }
            if let Some(existing) = tx
                .query_row(
                    "SELECT run_id, mission_id, generation, execution_state, owner_actor_id, scope_unit, started_at, heartbeat_at, stopping_at, ended_at, terminal_reason
                     FROM mission_runs WHERE mission_id = ?1 AND execution_state <> 'terminal'",
                    params![mission_id.to_string()],
                    parse_mission_run_row,
                )
                .optional()
                .map_err(|error| error.to_string())?
            {
                return Err(format!(
                    "mission {mission_id} already has non-terminal run {} generation {}",
                    existing.run_id, existing.generation
                ));
            }
            if owner_actor_id.starts_with("orb-client:") {
                tx.execute("UPDATE missions SET status='active',updated_at=?2,working_directory=COALESCE(?3,working_directory) WHERE id=?1",params![mission_id.to_string(),now_string(),cwd]).map_err(|e|e.to_string())?;
            }
            let generation = tx
                .query_row(
                    "SELECT COALESCE(MAX(generation), 0) + 1 FROM mission_runs WHERE mission_id = ?1",
                    params![mission_id.to_string()],
                    |row| row.get::<_, i64>(0),
                )
                .map_err(|error| error.to_string())?
                .max(1) as u64;
            let now = now_string();
            let run = MissionRun {
                run_id: Uuid::new_v4(),
                mission_id,
                generation,
                execution_state: MissionExecutionState::Starting,
                owner_actor_id,
                scope_unit,
                started_at: now.clone(),
                heartbeat_at: now,
                stopping_at: None,
                ended_at: None,
                terminal_reason: None,
            };
            tx.execute(
                "INSERT INTO mission_runs (run_id, mission_id, generation, execution_state, owner_actor_id, scope_unit, started_at, heartbeat_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    run.run_id.to_string(),
                    run.mission_id.to_string(),
                    run.generation as i64,
                    run.execution_state.as_str(),
                    run.owner_actor_id,
                    run.scope_unit,
                    run.started_at,
                    run.heartbeat_at,
                ],
            )
            .map_err(|error| error.to_string())?;
            tx.commit().map_err(|error| error.to_string())?;
            Ok(run)
        })
        .await
        .map_err(|error| error.to_string())?
    }

    pub(super) async fn get_active_mission_run(
        &self,
        mission_id: Uuid,
    ) -> Result<Option<MissionRun>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT run_id, mission_id, generation, execution_state, owner_actor_id, scope_unit, started_at, heartbeat_at, stopping_at, ended_at, terminal_reason
                 FROM mission_runs WHERE mission_id = ?1 AND execution_state <> 'terminal'",
                params![mission_id.to_string()],
                parse_mission_run_row,
            )
            .optional()
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    pub(super) async fn get_latest_mission_run(
        &self,
        mission_id: Uuid,
    ) -> Result<Option<MissionRun>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT run_id, mission_id, generation, execution_state, owner_actor_id, scope_unit, started_at, heartbeat_at, stopping_at, ended_at, terminal_reason
                 FROM mission_runs WHERE mission_id = ?1 ORDER BY generation DESC LIMIT 1",
                params![mission_id.to_string()],
                parse_mission_run_row,
            )
            .optional()
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    pub(super) async fn list_active_mission_runs(&self) -> Result<Vec<MissionRun>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT run_id, mission_id, generation, execution_state, owner_actor_id, scope_unit, started_at, heartbeat_at, stopping_at, ended_at, terminal_reason
                     FROM mission_runs WHERE execution_state <> 'terminal' ORDER BY started_at ASC",
                )
                .map_err(|error| error.to_string())?;
            let rows = stmt
                .query_map([], parse_mission_run_row)
                .map_err(|error| error.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|error| error.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|error| error.to_string())?
    }

    pub(super) async fn heartbeat_mission_run(
        &self,
        run_id: Uuid,
        generation: u64,
        state: MissionExecutionState,
        scope_unit: Option<&str>,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let now = now_string();
        let scope_unit = scope_unit.map(str::to_string);
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE mission_runs SET execution_state = ?1, heartbeat_at = ?2,
                    scope_unit = COALESCE(?3, scope_unit),
                    stopping_at = CASE WHEN ?1 = 'stopping' THEN COALESCE(stopping_at, ?2) ELSE stopping_at END
                 WHERE run_id = ?4 AND generation = ?5 AND execution_state <> 'terminal'",
                params![state.as_str(), now, scope_unit, run_id.to_string(), generation as i64],
            )
            .map(|changed| changed == 1)
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    pub(super) async fn finish_mission_run(
        &self,
        run_id: Uuid,
        generation: u64,
        terminal_reason: Option<&str>,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let now = now_string();
        let terminal_reason = terminal_reason.map(str::to_string);
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE mission_runs SET execution_state = 'terminal', heartbeat_at = ?1,
                    ended_at = ?1, terminal_reason = ?2
                 WHERE run_id = ?3 AND generation = ?4 AND execution_state <> 'terminal'",
                params![now, terminal_reason, run_id.to_string(), generation as i64],
            )
            .map(|changed| changed == 1)
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    pub(super) async fn register_tool_execution(
        &self,
        execution: &MissionToolExecution,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let execution = execution.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO mission_tool_executions (tool_call_id, run_id, tool_kind, state, started_at, heartbeat_at, deadline_at, process_pid, durable_job_id, completed_at, exit_status, failure_class)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                 ON CONFLICT(run_id, tool_call_id) DO UPDATE SET
                    tool_kind = excluded.tool_kind, state = excluded.state,
                    heartbeat_at = excluded.heartbeat_at, deadline_at = excluded.deadline_at,
                    process_pid = COALESCE(excluded.process_pid, process_pid),
                    durable_job_id = COALESCE(excluded.durable_job_id, durable_job_id)",
                params![
                    execution.tool_call_id,
                    execution.run_id.to_string(),
                    execution.tool_kind,
                    execution.state.as_str(),
                    execution.started_at,
                    execution.heartbeat_at,
                    execution.deadline_at,
                    execution.process_pid.map(i64::from),
                    execution.durable_job_id.map(|id| id.to_string()),
                    execution.completed_at,
                    execution.exit_status,
                    execution.failure_class,
                ],
            )
            .map(|_| ())
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    pub(super) async fn finish_tool_execution(
        &self,
        run_id: Uuid,
        tool_call_id: &str,
        state: MissionToolExecutionState,
        exit_status: Option<i32>,
        failure_class: Option<&str>,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let tool_call_id = tool_call_id.to_string();
        let failure_class = failure_class.map(str::to_string);
        let now = now_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE mission_tool_executions SET state = ?1, heartbeat_at = ?2,
                    completed_at = ?2, exit_status = ?3, failure_class = ?4
                 WHERE run_id = ?5 AND tool_call_id = ?6",
                params![
                    state.as_str(),
                    now,
                    exit_status,
                    failure_class,
                    run_id.to_string(),
                    tool_call_id
                ],
            )
            .map(|changed| changed == 1)
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    pub(super) async fn list_active_tool_executions(
        &self,
        run_id: Uuid,
    ) -> Result<Vec<MissionToolExecution>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT tool_call_id, run_id, tool_kind, state, started_at, heartbeat_at, deadline_at, process_pid, durable_job_id, completed_at, exit_status, failure_class
                     FROM mission_tool_executions WHERE run_id = ?1 AND state IN ('provisional', 'running') ORDER BY started_at ASC",
                )
                .map_err(|error| error.to_string())?;
            let rows = stmt
                .query_map(params![run_id.to_string()], parse_tool_execution_row)
                .map_err(|error| error.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|error| error.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|error| error.to_string())?
    }

    pub(super) async fn native_prompt_attempted(
        &self,
        id: Uuid,
        backend: &str,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let backend = backend.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row("SELECT EXISTS(SELECT 1 FROM mission_native_prompt_attempts WHERE mission_id = ?1 AND backend = ?2)", params![id.to_string(), backend], |r| r.get(0)).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn claim_native_prompt(
        &self,
        id: Uuid,
        backend: &str,
        session_id: Option<&str>,
        run: Option<&super::super::SessionUpdateRun>,
        claim_id: Uuid,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let backend = backend.to_string();
        let session_id = session_id.map(str::to_string);
        let run_stamp = serde_json::to_string(&run).map_err(|e| e.to_string())?;
        let run = run.map(|r| (r.run_id.to_string(), r.generation));
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(|e| e.to_string())?;
            let (current_backend, current_session): (String, Option<String>) = tx.query_row("SELECT COALESCE(backend, 'opencode'), session_id FROM missions WHERE id = ?1", [id.to_string()], |r| Ok((r.get(0)?, r.get(1)?))).map_err(|e| e.to_string())?;
            let latest: Option<(String, u64)> = tx.query_row("SELECT run_id, generation FROM mission_runs WHERE mission_id = ?1 ORDER BY generation DESC LIMIT 1", [id.to_string()], |r| Ok((r.get(0)?, r.get(1)?))).optional().map_err(|e| e.to_string())?;
            if backend.is_empty() || current_backend != backend || current_session != session_id || latest != run { return Ok(false); }
            let prior: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM mission_native_prompt_attempts WHERE mission_id = ?1 AND backend = ?2)", params![id.to_string(), backend], |r| r.get(0)).map_err(|e| e.to_string())?;
            if prior && session_id.is_none() { return Ok(false); }
            tx.execute("INSERT OR IGNORE INTO mission_native_prompt_attempts (mission_id, backend) VALUES (?1, ?2)", params![id.to_string(), backend]).map_err(|e| e.to_string())?;
            if !prior {
                tx.execute("INSERT INTO mission_native_prompt_claims (mission_id, backend, claim_id, run_stamp) VALUES (?1, ?2, ?3, ?4)", params![id.to_string(), backend, claim_id.to_string(), run_stamp]).map_err(|e| e.to_string())?;
            }
            tx.commit().map_err(|e| e.to_string())?;
            Ok(true)
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn release_native_prompt_no_launch(
        &self,
        id: Uuid,
        backend: &str,
        run: Option<&super::super::SessionUpdateRun>,
        claim_id: Uuid,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let backend = backend.to_string();
        let run_stamp = serde_json::to_string(&run).map_err(|e| e.to_string())?;
        let run = run.map(|r| (r.run_id.to_string(), r.generation));
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(|e| e.to_string())?;
            let (current_backend, session): (String, Option<String>) = tx.query_row("SELECT COALESCE(backend, 'opencode'), session_id FROM missions WHERE id = ?1", [id.to_string()], |r| Ok((r.get(0)?, r.get(1)?))).map_err(|e| e.to_string())?;
            let latest: Option<(String, u64)> = tx.query_row("SELECT run_id, generation FROM mission_runs WHERE mission_id = ?1 ORDER BY generation DESC LIMIT 1", [id.to_string()], |r| Ok((r.get(0)?, r.get(1)?))).optional().map_err(|e| e.to_string())?;
            if backend.is_empty() || current_backend != backend || session.is_some() || latest != run { return Ok(false); }
            let deleted = tx.execute("DELETE FROM mission_native_prompt_claims WHERE mission_id = ?1 AND backend = ?2 AND claim_id = ?3 AND run_stamp = ?4", params![id.to_string(), backend, claim_id.to_string(), run_stamp]).map_err(|e| e.to_string())?;
            if deleted != 1 { return Ok(false); }
            tx.execute("DELETE FROM mission_native_prompt_attempts WHERE mission_id = ?1 AND backend = ?2", params![id.to_string(), backend]).map_err(|e| e.to_string())?;
            tx.commit().map_err(|e| e.to_string())?;
            Ok(true)
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn update_mission_session_id(
        &self,
        id: Uuid,
        session_id: &str,
        backend: &str,
        run: Option<&super::super::SessionUpdateRun>,
    ) -> Result<bool, String> {
        if backend.is_empty() {
            return Err("native session update requires harness provenance".into());
        }
        let conn = self.conn.clone();
        let now = now_string();
        let run = run.map(|r| (r.run_id.to_string(), r.generation));
        let session_id = session_id.to_string();
        let backend = backend.to_string();
        tokio::task::spawn_blocking(move || {
            let mut connection = conn.blocking_lock();
            let tx = connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(|e| e.to_string())?;
            let current_backend: String = tx.query_row(
                "SELECT COALESCE(backend, 'opencode') FROM missions WHERE id = ?1",
                params![id.to_string()], |row| row.get(0),
            ).map_err(|e| e.to_string())?;
            let latest: Option<(String, u64)> = tx.query_row(
                "SELECT run_id, generation FROM mission_runs WHERE mission_id = ?1 ORDER BY generation DESC LIMIT 1",
                params![id.to_string()], |row| Ok((row.get(0)?, row.get(1)?)),
            ).optional().map_err(|e| e.to_string())?;
            if latest != run {
                return Ok(false);
            }
            tx.execute(
                "INSERT INTO mission_harness_sessions (mission_id, backend, session_id) VALUES (?1, ?2, ?3)
                 ON CONFLICT(mission_id, backend) DO UPDATE SET session_id = excluded.session_id",
                params![id.to_string(), backend, session_id],
            ).map_err(|e| e.to_string())?;
            if current_backend == backend {
                tx.execute(
                    "UPDATE missions SET session_id = ?1, updated_at = ?2 WHERE id = ?3",
                    params![session_id, now, id.to_string()],
                ).map_err(|e| e.to_string())?;
            }
            tx.commit().map_err(|e| e.to_string())?;
            Ok(true)
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn clear_unsubmitted_session_id(
        &self,
        id: Uuid,
        session_id: &str,
        backend: &str,
        run: &super::super::SessionUpdateRun,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let session_id = session_id.to_string();
        let backend = backend.to_string();
        let run = (run.run_id.to_string(), run.generation);
        tokio::task::spawn_blocking(move || {
            let mut c = conn.blocking_lock();
            let tx = c.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(|e| e.to_string())?;
            let latest: Option<(String,u64)> = tx.query_row(
                "SELECT run_id,generation FROM mission_runs WHERE mission_id=?1 ORDER BY generation DESC LIMIT 1",
                [id.to_string()], |row| Ok((row.get(0)?,row.get(1)?)),
            ).optional().map_err(|e| e.to_string())?;
            if latest != Some(run) { return Ok(false); }
            let removed = tx.execute("DELETE FROM mission_harness_sessions WHERE mission_id=?1 AND backend=?2 AND session_id=?3", params![id.to_string(),backend,session_id]).map_err(|e| e.to_string())?;
            if removed == 0 {
                // Without a recorded native session, only the mission's own
                // never-submitted placeholder identity may be cleared.
                let recorded: i64 = tx.query_row("SELECT COUNT(*) FROM mission_harness_sessions WHERE mission_id=?1 AND backend=?2", params![id.to_string(),backend], |row| row.get(0)).map_err(|e| e.to_string())?;
                if recorded > 0 { return Ok(false); }
            }
            let cleared = tx.execute("UPDATE missions SET session_id=NULL,updated_at=?4 WHERE id=?1 AND backend=?2 AND session_id=?3",params![id.to_string(),backend,session_id,now_string()]).map_err(|e| e.to_string())?;
            if removed == 0 && cleared == 0 { return Ok(false); }
            tx.commit().map_err(|e| e.to_string())?;
            Ok(true)
        }).await.map_err(|e| e.to_string())?
    }
}
