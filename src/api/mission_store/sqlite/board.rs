//! Board tasks, task attempts and the board outbox.

use super::*;

/// Byte-exact family match: `?1` itself or `?1-` as a literal prefix.
/// Deliberately NOT `LIKE` — its `_` wildcard would make `foo_bar` match
/// `fooXbar-*`, and its ASCII case-folding would merge differently-cased
/// slugs; `substr`/`||` compare bytes, matching `project_prefix` semantics.
pub(super) const BOARD_TASK_PROJECT_FAMILY_PREDICATE: &str =
    "(m.project = ?1 OR substr(m.project, 1, length(?1) + 1) = ?1 || '-')";

/// Column list shared by every board task SELECT so `parse_board_task_row`
/// indices stay in sync.
pub(super) const BOARD_TASK_COLUMNS: &str = "id, boss_mission_id, task_key, title, prompt, backend, \
    model_override, model_effort, working_directory, repository, branch, role, acceptance_criteria, \
    verification_command, design_domain, declared_write_set, risk_class, token_budget, cost_budget_cents, \
    depends_on, status, outcome, worker_mission_id, prior_worker_mission_id, prior_outcome, \
    prior_result_digest, attempts, result_digest, notes, created_at, updated_at";

pub(super) fn parse_board_task_row(row: &rusqlite::Row<'_>) -> Result<BoardTask, rusqlite::Error> {
    let id: String = row.get(0)?;
    let boss_mission_id: String = row.get(1)?;
    let acceptance_criteria: String = row.get(12)?;
    let declared_write_set: String = row.get(15)?;
    let token_budget: Option<i64> = row.get(17)?;
    let depends_on_json: String = row.get(19)?;
    let status_str: String = row.get(20)?;
    let outcome_str: Option<String> = row.get(21)?;
    let worker_mission_id: Option<String> = row.get(22)?;
    let prior_worker_mission_id: Option<String> = row.get(23)?;
    let prior_outcome: Option<String> = row.get(24)?;
    let attempts: i64 = row.get(26)?;
    Ok(BoardTask {
        id: Uuid::parse_str(&id)
            .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
        boss_mission_id: Uuid::parse_str(&boss_mission_id)
            .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?,
        task_key: row.get(2)?,
        title: row.get(3)?,
        prompt: row.get(4)?,
        backend: row.get(5)?,
        model_override: row.get(6)?,
        model_effort: row.get(7)?,
        working_directory: row.get(8)?,
        repository: row.get(9)?,
        branch: row.get(10)?,
        role: BoardTaskRole::parse(&row.get::<_, String>(11)?),
        acceptance_criteria: serde_json::from_str(&acceptance_criteria).unwrap_or_default(),
        verification_command: row.get(13)?,
        design_domain: row.get(14)?,
        declared_write_set: serde_json::from_str(&declared_write_set).unwrap_or_default(),
        risk_class: row.get(16)?,
        token_budget: token_budget.map(|value| value.max(0) as u64),
        cost_budget_cents: row.get(18)?,
        depends_on: serde_json::from_str(&depends_on_json).unwrap_or_default(),
        status: BoardTaskStatus::parse(&status_str).unwrap_or(BoardTaskStatus::Pending),
        outcome: outcome_str.as_deref().and_then(BoardTaskOutcome::parse),
        worker_mission_id: worker_mission_id.and_then(|s| Uuid::parse_str(&s).ok()),
        prior_worker_mission_id: prior_worker_mission_id.and_then(|s| Uuid::parse_str(&s).ok()),
        prior_outcome: prior_outcome.as_deref().and_then(BoardTaskOutcome::parse),
        prior_result_digest: row.get(25)?,
        attempts: attempts as u32,
        result_digest: row.get(27)?,
        notes: row.get(28)?,
        created_at: row.get(29)?,
        updated_at: row.get(30)?,
    })
}

pub(super) fn parse_task_attempt_row(
    row: &rusqlite::Row<'_>,
) -> Result<TaskAttempt, rusqlite::Error> {
    let id: String = row.get(0)?;
    let task_id: String = row.get(1)?;
    let attempt_number: i64 = row.get(2)?;
    let mission_id: String = row.get(3)?;
    let role: String = row.get(6)?;
    let run_id: Option<String> = row.get(7)?;
    let changed_files: String = row.get(9)?;
    let evidence: String = row.get(10)?;
    Ok(TaskAttempt {
        id: Uuid::parse_str(&id).unwrap_or_default(),
        task_id: Uuid::parse_str(&task_id).unwrap_or_default(),
        attempt_number: attempt_number.max(0) as u32,
        mission_id: Uuid::parse_str(&mission_id).unwrap_or_default(),
        backend: row.get(4)?,
        model: row.get(5)?,
        role: BoardTaskRole::parse(&role),
        run_id: run_id.and_then(|value| Uuid::parse_str(&value).ok()),
        commit_sha: row.get(8)?,
        changed_files: serde_json::from_str(&changed_files).unwrap_or_default(),
        verification_evidence: serde_json::from_str(&evidence).unwrap_or_default(),
        cost_cents: row.get(11)?,
        terminal_class: row.get(12)?,
        started_at: row.get(13)?,
        finished_at: row.get(14)?,
    })
}

pub(super) fn parse_board_outbox_row(
    row: &rusqlite::Row<'_>,
) -> Result<BoardOutboxItem, rusqlite::Error> {
    let id: String = row.get(0)?;
    let boss_mission_id: String = row.get(1)?;
    let task_id: Option<String> = row.get(2)?;
    let payload: String = row.get(5)?;
    let attempts: i64 = row.get(7)?;
    Ok(BoardOutboxItem {
        id: Uuid::parse_str(&id).unwrap_or_default(),
        boss_mission_id: Uuid::parse_str(&boss_mission_id).unwrap_or_default(),
        task_id: task_id.and_then(|value| Uuid::parse_str(&value).ok()),
        delivery_kind: row.get(3)?,
        idempotency_key: row.get(4)?,
        payload: serde_json::from_str(&payload).unwrap_or_default(),
        state: row.get(6)?,
        attempts: attempts.max(0) as u32,
        created_at: row.get(8)?,
        acknowledged_at: row.get(9)?,
    })
}
impl SqliteMissionStore {
    // ---- Task board ------------------------------------------------------

    pub(super) async fn upsert_board_tasks(
        &self,
        boss_mission_id: Uuid,
        tasks: Vec<NewBoardTask>,
    ) -> Result<Vec<BoardTask>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let now = now_string();
            let mut out = Vec::with_capacity(tasks.len());
            for t in tasks {
                let existing: Option<(String, String)> = conn
                    .query_row(
                        "SELECT id, status FROM board_tasks WHERE boss_mission_id = ?1 AND task_key = ?2",
                        params![boss_mission_id.to_string(), t.task_key],
                        |row| Ok((row.get(0)?, row.get(1)?)),
                    )
                    .optional()
                    .map_err(|e| format!("Failed to look up board task: {e}"))?;

                let depends_on_json = serde_json::to_string(&t.depends_on)
                    .map_err(|e| format!("Failed to serialize depends_on: {e}"))?;

                let row_id = match existing {
                    Some((id, status)) if status == "pending" => {
                        conn.execute(
                            "UPDATE board_tasks SET title = ?1, prompt = ?2, backend = ?3, \
                             model_override = ?4, model_effort = ?5, working_directory = ?6, \
                             repository = ?7, branch = ?8, role = ?9, acceptance_criteria = ?10, \
                             verification_command = ?11, design_domain = ?12, declared_write_set = ?13, \
                             risk_class = ?14, token_budget = ?15, cost_budget_cents = ?16, \
                             depends_on = ?17, updated_at = ?18 WHERE id = ?19",
                            params![
                                t.title,
                                t.prompt,
                                t.backend,
                                t.model_override,
                                t.model_effort,
                                t.working_directory,
                                t.repository,
                                t.branch,
                                t.role.to_string(),
                                serde_json::to_string(&t.acceptance_criteria).unwrap_or_else(|_| "[]".into()),
                                t.verification_command,
                                t.design_domain,
                                serde_json::to_string(&t.declared_write_set).unwrap_or_else(|_| "[]".into()),
                                t.risk_class,
                                t.token_budget.map(|value| value as i64),
                                t.cost_budget_cents,
                                depends_on_json,
                                now,
                                id,
                            ],
                        )
                        .map_err(|e| format!("Failed to update board task: {e}"))?;
                        id
                    }
                    Some((id, status)) if status == "running" => {
                        // A worker is already executing this task, so its
                        // prompt/backend/deps are frozen — but the OUTCOME
                        // CONTRACT may still be corrected. `plan_tasks` warns
                        // about missing acceptance criteria only after
                        // registration, and the scheduler can spawn the task
                        // within one pass (~3s), before the boss reads the
                        // warning. Letting the contract fields through means
                        // that correction still lands: verdict guidance and
                        // the retry prompt read them live, and a retry's
                        // worker contract delivers them.
                        conn.execute(
                            "UPDATE board_tasks SET acceptance_criteria = ?1, \
                             verification_command = ?2, risk_class = ?3, updated_at = ?4 \
                             WHERE id = ?5",
                            params![
                                serde_json::to_string(&t.acceptance_criteria)
                                    .unwrap_or_else(|_| "[]".into()),
                                t.verification_command,
                                t.risk_class,
                                now,
                                id,
                            ],
                        )
                        .map_err(|e| format!("Failed to update running task contract: {e}"))?;
                        id
                    }
                    Some((id, _)) => id, // settled/terminal: leave untouched
                    None => {
                        let id = Uuid::new_v4().to_string();
                        conn.execute(
                            "INSERT INTO board_tasks (id, boss_mission_id, task_key, title, prompt, \
                             backend, model_override, model_effort, working_directory, repository, branch, \
                             role, acceptance_criteria, verification_command, design_domain, declared_write_set, \
                             risk_class, token_budget, cost_budget_cents, depends_on, status, attempts, created_at, updated_at) \
                             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, \
                             ?15, ?16, ?17, ?18, ?19, ?20, 'pending', 0, ?21, ?21)",
                            params![
                                id,
                                boss_mission_id.to_string(),
                                t.task_key,
                                t.title,
                                t.prompt,
                                t.backend,
                                t.model_override,
                                t.model_effort,
                                t.working_directory,
                                t.repository,
                                t.branch,
                                t.role.to_string(),
                                serde_json::to_string(&t.acceptance_criteria).unwrap_or_else(|_| "[]".into()),
                                t.verification_command,
                                t.design_domain,
                                serde_json::to_string(&t.declared_write_set).unwrap_or_else(|_| "[]".into()),
                                t.risk_class,
                                t.token_budget.map(|value| value as i64),
                                t.cost_budget_cents,
                                depends_on_json,
                                now,
                            ],
                        )
                        .map_err(|e| format!("Failed to insert board task: {e}"))?;
                        id
                    }
                };

                let task = conn
                    .query_row(
                        &format!("SELECT {BOARD_TASK_COLUMNS} FROM board_tasks WHERE id = ?1"),
                        params![row_id],
                        parse_board_task_row,
                    )
                    .map_err(|e| format!("Failed to re-read board task: {e}"))?;
                out.push(task);
            }
            Ok(out)
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    pub(super) async fn list_board_tasks(
        &self,
        boss_mission_id: Uuid,
    ) -> Result<Vec<BoardTask>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(&format!(
                    "SELECT {BOARD_TASK_COLUMNS} FROM board_tasks \
                     WHERE boss_mission_id = ?1 ORDER BY created_at ASC, task_key ASC"
                ))
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![boss_mission_id.to_string()], parse_board_task_row)
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    pub(super) async fn list_board_tasks_for_project(
        &self,
        project: &str,
    ) -> Result<Vec<BoardTask>, String> {
        let conn = self.reader();
        let project = project.to_string();
        // Qualify every column so the missions join can't shadow board task
        // columns (both tables have id/status/created_at/...).
        let columns = BOARD_TASK_COLUMNS
            .split(',')
            .map(|column| format!("bt.{}", column.trim()))
            .collect::<Vec<_>>()
            .join(", ");
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(&format!(
                    "SELECT {columns} FROM board_tasks bt \
                     JOIN missions m ON m.id = bt.boss_mission_id \
                     WHERE {BOARD_TASK_PROJECT_FAMILY_PREDICATE} \
                     ORDER BY bt.created_at ASC, bt.task_key ASC"
                ))
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![project], parse_board_task_row)
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    pub(super) async fn list_active_board_missions(&self) -> Result<Vec<Uuid>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT DISTINCT boss_mission_id FROM board_tasks \
                     WHERE status IN ('pending', 'running', 'settled')",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(|e| e.to_string())?;
            let mut out = Vec::new();
            for r in rows {
                let s = r.map_err(|e| e.to_string())?;
                if let Ok(id) = Uuid::parse_str(&s) {
                    out.push(id);
                }
            }
            Ok(out)
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    pub(super) async fn get_board_task(&self, task_id: Uuid) -> Result<Option<BoardTask>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                &format!("SELECT {BOARD_TASK_COLUMNS} FROM board_tasks WHERE id = ?1"),
                params![task_id.to_string()],
                parse_board_task_row,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    pub(super) async fn get_board_task_by_worker(
        &self,
        worker_mission_id: Uuid,
    ) -> Result<Option<BoardTask>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                &format!(
                    "SELECT {BOARD_TASK_COLUMNS} FROM board_tasks \
                     WHERE worker_mission_id = ?1 ORDER BY updated_at DESC LIMIT 1"
                ),
                params![worker_mission_id.to_string()],
                parse_board_task_row,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    pub(super) async fn save_board_task(&self, task: &BoardTask) -> Result<(), String> {
        let conn = self.conn.clone();
        let t = task.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let depends_on_json = serde_json::to_string(&t.depends_on)
                .map_err(|e| format!("Failed to serialize depends_on: {e}"))?;
            let updated = conn
                .execute(
                    "UPDATE board_tasks SET task_key = ?1, title = ?2, prompt = ?3, backend = ?4, \
                     model_override = ?5, model_effort = ?6, working_directory = ?7, repository = ?8, \
                     branch = ?9, role = ?10, acceptance_criteria = ?11, verification_command = ?12, \
                     design_domain = ?13, declared_write_set = ?14, risk_class = ?15, token_budget = ?16, \
                     cost_budget_cents = ?17, depends_on = ?18, status = ?19, outcome = ?20, \
                     worker_mission_id = ?21, prior_worker_mission_id = ?22, prior_outcome = ?23, \
                     prior_result_digest = ?24, attempts = ?25, result_digest = ?26, notes = ?27, \
                     updated_at = ?28 WHERE id = ?29",
                    params![
                        t.task_key,
                        t.title,
                        t.prompt,
                        t.backend,
                        t.model_override,
                        t.model_effort,
                        t.working_directory,
                        t.repository,
                        t.branch,
                        t.role.to_string(),
                        serde_json::to_string(&t.acceptance_criteria).unwrap_or_else(|_| "[]".into()),
                        t.verification_command,
                        t.design_domain,
                        serde_json::to_string(&t.declared_write_set).unwrap_or_else(|_| "[]".into()),
                        t.risk_class,
                        t.token_budget.map(|value| value as i64),
                        t.cost_budget_cents,
                        depends_on_json,
                        t.status.to_string(),
                        t.outcome.map(|o| o.to_string()),
                        t.worker_mission_id.map(|id| id.to_string()),
                        t.prior_worker_mission_id.map(|id| id.to_string()),
                        t.prior_outcome.map(|o| o.to_string()),
                        t.prior_result_digest,
                        t.attempts as i64,
                        t.result_digest,
                        t.notes,
                        now_string(),
                        t.id.to_string(),
                    ],
                )
                .map_err(|e| format!("Failed to save board task: {e}"))?;
            if updated == 0 {
                return Err(format!("Board task {} not found", t.id));
            }
            Ok(())
        })
        .await
        .map_err(|e| format!("Task join error: {e}"))?
    }

    pub(super) async fn create_task_attempt(
        &self,
        attempt: TaskAttempt,
    ) -> Result<TaskAttempt, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO task_attempts (id, task_id, attempt_number, mission_id, backend, model, role, \
                 run_id, commit_sha, changed_files, verification_evidence, cost_cents, terminal_class, started_at, finished_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15) \
                 ON CONFLICT(task_id, attempt_number) DO NOTHING",
                params![
                    attempt.id.to_string(), attempt.task_id.to_string(), attempt.attempt_number as i64,
                    attempt.mission_id.to_string(), attempt.backend, attempt.model,
                    attempt.role.to_string(), attempt.run_id.map(|id| id.to_string()), attempt.commit_sha,
                    serde_json::to_string(&attempt.changed_files).unwrap_or_else(|_| "[]".into()),
                    attempt.verification_evidence.to_string(), attempt.cost_cents,
                    attempt.terminal_class, attempt.started_at, attempt.finished_at,
                ],
            ).map_err(|error| format!("Failed to create task attempt: {error}"))?;
            conn.query_row(
                "SELECT id, task_id, attempt_number, mission_id, backend, model, role, run_id, commit_sha, \
                 changed_files, verification_evidence, cost_cents, terminal_class, started_at, finished_at \
                 FROM task_attempts WHERE task_id = ?1 AND attempt_number = ?2",
                params![attempt.task_id.to_string(), attempt.attempt_number as i64],
                parse_task_attempt_row,
            ).map_err(|error| format!("Failed to read task attempt: {error}"))
        }).await.map_err(|error| format!("Task join error: {error}"))?
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) async fn finish_task_attempt(
        &self,
        task_id: Uuid,
        attempt_number: u32,
        terminal_class: &str,
        commit_sha: Option<&str>,
        changed_files: &[String],
        verification_evidence: &serde_json::Value,
        cost_cents: Option<i64>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let terminal_class = terminal_class.to_string();
        let commit_sha = commit_sha.map(str::to_string);
        let changed_files = serde_json::to_string(changed_files).map_err(|e| e.to_string())?;
        let verification_evidence = verification_evidence.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let updated = conn.execute(
                "UPDATE task_attempts SET terminal_class = ?1, commit_sha = ?2, changed_files = ?3, \
                 verification_evidence = ?4, cost_cents = ?5, finished_at = ?6 \
                 WHERE task_id = ?7 AND attempt_number = ?8",
                params![terminal_class, commit_sha, changed_files, verification_evidence, cost_cents,
                    now_string(), task_id.to_string(), attempt_number as i64],
            ).map_err(|error| format!("Failed to finish task attempt: {error}"))?;
            (updated > 0).then_some(()).ok_or_else(|| "Task attempt not found".to_string())
        }).await.map_err(|error| format!("Task join error: {error}"))?
    }

    pub(super) async fn list_task_attempts(
        &self,
        task_id: Uuid,
    ) -> Result<Vec<TaskAttempt>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut statement = conn.prepare(
                "SELECT id, task_id, attempt_number, mission_id, backend, model, role, run_id, commit_sha, \
                 changed_files, verification_evidence, cost_cents, terminal_class, started_at, finished_at \
                 FROM task_attempts WHERE task_id = ?1 ORDER BY attempt_number"
            ).map_err(|error| error.to_string())?;
            let rows = statement.query_map(params![task_id.to_string()], parse_task_attempt_row)
                .map_err(|error| error.to_string())?
                .collect::<Result<Vec<_>, _>>().map_err(|error| error.to_string())?;
            Ok(rows)
        }).await.map_err(|error| format!("Task join error: {error}"))?
    }

    pub(super) async fn enqueue_board_outbox(
        &self,
        item: BoardOutboxItem,
    ) -> Result<BoardOutboxItem, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO board_outbox (id, boss_mission_id, task_id, delivery_kind, idempotency_key, \
                 payload, state, attempts, created_at, acknowledged_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) ON CONFLICT(idempotency_key) DO NOTHING",
                params![item.id.to_string(), item.boss_mission_id.to_string(), item.task_id.map(|id| id.to_string()),
                    item.delivery_kind, item.idempotency_key, item.payload.to_string(), item.state,
                    item.attempts as i64, item.created_at, item.acknowledged_at],
            ).map_err(|error| format!("Failed to enqueue board delivery: {error}"))?;
            conn.query_row(
                "SELECT id, boss_mission_id, task_id, delivery_kind, idempotency_key, payload, state, attempts, \
                 created_at, acknowledged_at FROM board_outbox WHERE idempotency_key = ?1",
                params![item.idempotency_key], parse_board_outbox_row,
            ).map_err(|error| format!("Failed to read board delivery: {error}"))
        }).await.map_err(|error| format!("Task join error: {error}"))?
    }

    pub(super) async fn acknowledge_board_outbox(
        &self,
        idempotency_key: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let key = idempotency_key.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE board_outbox SET state = 'acknowledged', acknowledged_at = ?1 WHERE idempotency_key = ?2",
                params![now_string(), key],
            ).map(|_| ()).map_err(|error| error.to_string())
        }).await.map_err(|error| format!("Task join error: {error}"))?
    }

    pub(super) async fn pending_client_delivery_ids(&self) -> Result<Vec<Uuid>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut statement = conn.prepare("SELECT id FROM board_outbox WHERE state != 'acknowledged' AND delivery_kind = 'client_message'").map_err(|e| e.to_string())?;
            let ids = statement.query_map([], |row| row.get::<_, String>(0)).map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?;
            ids.into_iter().map(|id| Uuid::parse_str(&id).map_err(|e| e.to_string())).collect()
        }).await.map_err(|e| format!("Task join error: {e}"))?
    }

    pub(super) async fn list_pending_board_outbox_filtered(
        &self,
        limit: usize,
        client: Option<bool>,
    ) -> Result<Vec<BoardOutboxItem>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut statement = conn.prepare(
                "SELECT id, boss_mission_id, task_id, delivery_kind, idempotency_key, payload, state, attempts, \
                 created_at, acknowledged_at FROM board_outbox WHERE state != 'acknowledged' AND (?2 IS NULL OR (delivery_kind = 'client_message') = ?2) ORDER BY created_at LIMIT ?1"
            ).map_err(|error| error.to_string())?;
            let rows = statement.query_map(params![limit.min(1000) as i64, client], parse_board_outbox_row)
                .map_err(|error| error.to_string())?
                .collect::<Result<Vec<_>, _>>().map_err(|error| error.to_string())?;
            Ok(rows)
        }).await.map_err(|error| format!("Task join error: {error}"))?
    }
}
