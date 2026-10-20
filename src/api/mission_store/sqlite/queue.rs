//! Control queue persistence, scheduled deliveries, continuations and wakeup fences.

use super::*;

impl SqliteMissionStore {
    pub(super) async fn save_control_queue(
        &self,
        _user_id: &str,
        payload: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let payload = payload.to_string();
        let now = now_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO control_queue (id, payload, updated_at) VALUES (1, ?1, ?2)
                 ON CONFLICT(id) DO UPDATE SET payload = ?1, updated_at = ?2",
                params![payload, now],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn load_control_queue(&self, _user_id: &str) -> Result<String, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let payload: Option<String> = conn
                .query_row(
                    "SELECT payload FROM control_queue WHERE id = 1",
                    [],
                    |row| row.get(0),
                )
                .optional()
                .map_err(|e| e.to_string())?;
            Ok(payload.unwrap_or_default())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn stage_scheduled_delivery(
        &self,
        automation: &Automation,
        execution: AutomationExecution,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let automation = automation.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction().map_err(|e| e.to_string())?;
            let current: Option<(bool, Option<String>)> = tx.query_row(
                "SELECT active, last_triggered_at FROM automations WHERE id = ?",
                [automation.id.to_string()], |r| Ok((r.get(0)?, r.get(1)?))
            ).optional().map_err(|e| e.to_string())?;
            if current != Some((true, automation.last_triggered_at.clone())) { return Ok(false); }
            let pending: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM automation_executions WHERE automation_id = ? AND trigger_source = 'durable_schedule' AND status IN ('pending','running'))",
                [automation.id.to_string()], |r| r.get(0)
            ).map_err(|e| e.to_string())?;
            if pending { return Ok(false); }
            tx.execute("INSERT INTO automation_executions (id, automation_id, mission_id, triggered_at, trigger_source, status, variables_used, retry_count) VALUES (?, ?, ?, ?, 'durable_schedule', 'pending', ?, 0)",
                params![execution.id.to_string(), automation.id.to_string(), automation.mission_id.to_string(), execution.triggered_at,
                    serde_json::to_string(&execution.variables_used).map_err(|e| e.to_string())?]
            ).map_err(|e| e.to_string())?;
            tx.execute("UPDATE automations SET last_triggered_at = ?, active = ? WHERE id = ?", params![
                execution.triggered_at, !matches!(automation.stop_policy, StopPolicy::AfterFirstFire), automation.id.to_string()
            ]).map_err(|e| e.to_string())?;
            tx.commit().map_err(|e| e.to_string())?;
            Ok(true)
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn list_scheduled_deliveries(
        &self,
    ) -> Result<Vec<AutomationExecution>, String> {
        let conn = self.reader();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn.prepare("SELECT id, automation_id, mission_id, triggered_at, trigger_source, status, webhook_payload, variables_used, completed_at, error, retry_count FROM automation_executions WHERE trigger_source = 'durable_schedule' AND status NOT IN ('cancelled', 'skipped') AND (status IN ('pending','running') OR COALESCE(json_extract(variables_used, '$.__delivery_accepted'), '') != 'true') ORDER BY triggered_at, id").map_err(|e| e.to_string())?;
            let rows = stmt.query_map([], Self::parse_execution_row).map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?;
            Ok(rows)
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn can_admit_scheduled_delivery(
        &self,
        mission: Uuid,
        id: Uuid,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            conn.blocking_lock().query_row("SELECT EXISTS (SELECT 1 FROM automation_executions WHERE id = ?1 AND mission_id = ?2 AND trigger_source = 'durable_schedule' AND status NOT IN ('cancelled', 'skipped'))",
                params![id.to_string(), mission.to_string()], |row| row.get(0)).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn fence_mission_wakeups(&self, mission: Uuid) -> Result<(), String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            conn.blocking_lock().execute("INSERT INTO mission_wakeup_fences (mission_id, stopped_generation)
                VALUES (?1, COALESCE((SELECT MAX(generation) FROM mission_runs WHERE mission_id = ?1), 0))
                ON CONFLICT(mission_id) DO UPDATE SET stopped_generation = MAX(stopped_generation, excluded.stopped_generation)", [mission.to_string()])
                .map(|_| ()).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn wakeup_creation_allowed(
        &self,
        mission: Uuid,
        generation: u64,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            conn.blocking_lock().query_row("SELECT
                COALESCE((SELECT MAX(generation) FROM mission_runs WHERE mission_id = ?1), 0) = ?2
                AND NOT EXISTS (SELECT 1 FROM mission_wakeup_fences WHERE mission_id = ?1 AND stopped_generation >= ?2)",
                params![mission.to_string(), generation as i64], |row| row.get(0)).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn cancel_mission_continuations(&self, mission: Uuid) -> Result<(), String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock(); let tx = conn.transaction()?;
            tx.execute("UPDATE automations SET active = 0 WHERE mission_id = ? AND json_extract(variables, '$.__wakeup_source') IS NOT NULL", [mission.to_string()])?;
            tx.execute("UPDATE board_outbox SET state = 'acknowledged', acknowledged_at = ? WHERE id IN (SELECT id FROM automation_executions WHERE mission_id = ? AND trigger_source = 'durable_schedule') AND state = 'pending'", params![now_string(),mission.to_string()])?;
            tx.execute("UPDATE automation_executions SET status = 'cancelled', completed_at = ? WHERE mission_id = ? AND trigger_source = 'durable_schedule' AND (status IN ('pending','running') OR COALESCE(json_extract(variables_used, '$.__delivery_accepted'), '') != 'true')", params![now_string(),mission.to_string()])?;
            tx.commit()
        }).await.map_err(|e|e.to_string())?.map_err(|e|e.to_string())
    }

    pub(super) async fn cancel_mission_continuations_through(
        &self,
        mission: Uuid,
        generation: u64,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock(); let tx = conn.transaction()?;
            tx.execute("INSERT INTO mission_wakeup_fences (mission_id, stopped_generation) VALUES (?1, ?2) ON CONFLICT(mission_id) DO UPDATE SET stopped_generation = MAX(stopped_generation, excluded.stopped_generation)", params![mission.to_string(), generation as i64])?;
            tx.execute("UPDATE automations SET active = 0 WHERE mission_id = ? AND json_extract(variables, '$.__wakeup_source') IS NOT NULL AND CAST(COALESCE(json_extract(variables, '$.__wakeup_run_generation'), '0') AS INTEGER) <= ?", params![mission.to_string(),generation as i64])?;
            tx.execute("UPDATE board_outbox SET state = 'acknowledged', acknowledged_at = ? WHERE id IN (SELECT id FROM automation_executions WHERE mission_id = ? AND trigger_source = 'durable_schedule' AND CAST(COALESCE(json_extract(variables_used, '$.__wakeup_run_generation'), '0') AS INTEGER) <= ?) AND state = 'pending'", params![now_string(),mission.to_string(),generation as i64])?;
            tx.execute("UPDATE automation_executions SET status = 'cancelled', completed_at = ? WHERE mission_id = ? AND trigger_source = 'durable_schedule' AND CAST(COALESCE(json_extract(variables_used, '$.__wakeup_run_generation'), '0') AS INTEGER) <= ? AND (status IN ('pending','running') OR COALESCE(json_extract(variables_used, '$.__delivery_accepted'), '') != 'true')", params![now_string(),mission.to_string(),generation as i64])?;
            tx.commit()
        }).await.map_err(|e|e.to_string())?.map_err(|e|e.to_string())
    }

    pub(super) async fn cancel_scheduled_delivery(&self, id: Uuid) -> Result<(), String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction().map_err(|e| e.to_string())?;
            tx.execute("UPDATE automations SET active = 0 WHERE id = ?", [id.to_string()]).map_err(|e| e.to_string())?;
            tx.execute("UPDATE automation_executions SET status = 'cancelled', completed_at = ? WHERE automation_id = ? AND trigger_source = 'durable_schedule' AND (status = 'pending' OR (status IN ('success','failed') AND COALESCE(json_extract(variables_used, '$.__delivery_accepted'), '') != 'true'))", params![now_string(), id.to_string()]).map_err(|e| e.to_string())?;
            tx.commit().map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn complete_turn_executions_for_mission(
        &self,
        mission_id: Uuid,
        occurrence: Option<Uuid>,
        success: bool,
        error: Option<String>,
    ) -> Result<u32, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute("UPDATE automation_executions SET status = ?, completed_at = ?, error = ?
                WHERE mission_id = ? AND ((trigger_source != 'durable_schedule' AND status IN ('pending','running'))
                  OR (trigger_source = 'durable_schedule' AND status = 'running' AND COALESCE(json_extract(variables_used, '$.__continuation_message_id'), id) = ?))",
                params![if success { "success" } else { "failed" }, now_string(), error, mission_id.to_string(), occurrence.map(|id| id.to_string())])
                .map(|n| n as u32).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn bind_scheduled_remote_job(
        &self,
        mission: Uuid,
        message: Option<Uuid>,
        previous_job: Uuid,
        job: Uuid,
    ) -> Result<u32, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            conn.blocking_lock().execute("UPDATE automation_executions SET variables_used = json_set(variables_used, '$.__remote_job_id', ?1)
                WHERE mission_id = ?2 AND trigger_source = 'durable_schedule' AND status = 'running'
                AND (COALESCE(json_extract(variables_used, '$.__continuation_message_id'), id) = ?3 OR json_extract(variables_used, '$.__remote_job_id') = ?4)",
                params![job.to_string(), mission.to_string(), message.map(|id| id.to_string()), previous_job.to_string()])
                .map(|n| n as u32).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn scheduled_remote_delivery(
        &self,
        mission: Uuid,
        message: Uuid,
    ) -> Result<Option<(Uuid, bool)>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let row = conn.blocking_lock().query_row("SELECT json_extract(variables_used, '$.__remote_job_id'), COALESCE(json_extract(variables_used, '$.__delivery_accepted'), '') = 'true'
                FROM automation_executions WHERE mission_id = ?1 AND COALESCE(json_extract(variables_used, '$.__continuation_message_id'), id) = ?2
                AND trigger_source = 'durable_schedule' AND status NOT IN ('cancelled', 'skipped') AND json_type(variables_used, '$.__remote_job_id') = 'text' LIMIT 1",
                params![mission.to_string(), message.to_string()], |row| Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?))).optional().map_err(|e| e.to_string())?;
            row.map(|(id, accepted)| Uuid::parse_str(&id).map(|id| (id, accepted)).map_err(|e| e.to_string())).transpose()
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn complete_scheduled_remote_job(
        &self,
        mission: Uuid,
        job: Uuid,
        success: Option<bool>,
        error: Option<String>,
    ) -> Result<u32, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            conn.blocking_lock().execute("UPDATE automation_executions SET status = COALESCE(?1, 'running'), completed_at = CASE WHEN ?1 IS NULL THEN completed_at ELSE ?2 END, error = ?3, variables_used = json_set(variables_used, '$.__delivery_accepted', 'true')
                WHERE mission_id = ?4 AND trigger_source = 'durable_schedule' AND status IN ('pending', 'running') AND json_extract(variables_used, '$.__remote_job_id') = ?5",
                params![success.map(|success| if success {"success"} else {"failed"}), now_string(), error, mission.to_string(), job.to_string()])
                .map(|n| n as u32).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }

    pub(super) async fn handoff_scheduled_executions(
        &self,
        mission: Uuid,
        from: Vec<Uuid>,
        to: Uuid,
    ) -> Result<u32, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            conn.blocking_lock().execute("UPDATE automation_executions SET variables_used = json_set(variables_used, '$.__continuation_message_id', ?)
                WHERE mission_id = ? AND trigger_source = 'durable_schedule' AND status = 'running'
                AND COALESCE(json_extract(variables_used, '$.__continuation_message_id'), id) IN (SELECT value FROM json_each(?))",
                params![to.to_string(), mission.to_string(), serde_json::to_string(&from).map_err(|e| e.to_string())?])
                .map(|n| n as u32).map_err(|e| e.to_string())
        }).await.map_err(|e| e.to_string())?
    }
}
