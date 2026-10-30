//! Automations and automation executions.

use super::*;

impl SqliteMissionStore {
    pub(super) async fn create_automation(
        &self,
        automation: Automation,
    ) -> Result<Automation, String> {
        let conn = self.conn.clone();

        // Serialize command source
        let (command_source_type, command_source_data) = match &automation.command_source {
            CommandSource::Library { name } => {
                ("library", serde_json::json!({ "name": name }).to_string())
            }
            CommandSource::LocalFile { path } => (
                "local_file",
                serde_json::json!({ "path": path }).to_string(),
            ),
            CommandSource::Inline { content } => (
                "inline",
                serde_json::json!({ "content": content }).to_string(),
            ),
            CommandSource::NativeLoop {
                harness,
                command,
                args,
            } => (
                "native_loop",
                serde_json::json!({
                    "harness": harness,
                    "command": command,
                    "args": args,
                })
                .to_string(),
            ),
        };

        // Serialize trigger
        let (trigger_type, trigger_data) = match &automation.trigger {
            TriggerType::Interval { seconds } => (
                "interval",
                serde_json::json!({ "seconds": seconds }).to_string(),
            ),
            TriggerType::Cron {
                expression,
                timezone,
            } => (
                "cron",
                serde_json::json!({ "expression": expression, "timezone": timezone }).to_string(),
            ),
            TriggerType::Webhook { config } => (
                "webhook",
                serde_json::to_string(config).map_err(|e| e.to_string())?,
            ),
            TriggerType::AgentFinished => ("agent_finished", "{}".to_string()),
            TriggerType::DurableJobTerminal { job_id } => (
                "durable_job_terminal",
                serde_json::json!({ "job_id": job_id }).to_string(),
            ),
            TriggerType::Telegram { config } => (
                "telegram",
                serde_json::to_string(config).map_err(|e| e.to_string())?,
            ),
        };

        // Serialize variables
        let variables_json =
            serde_json::to_string(&automation.variables).map_err(|e| e.to_string())?;

        let a = automation.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.blocking_lock();
            let tx = conn.transaction()?;
            let stop_policy_str = match &a.stop_policy {
                StopPolicy::Never => "never".to_string(),
                StopPolicy::WhenMissionTerminal => "when_mission_terminal".to_string(),
                StopPolicy::WhenFailingConsecutively { count } => format!("consecutive_failures:{}", count),
                StopPolicy::WhenAllIssuesClosedAndPRsMerged { repo } => format!("all_issues_closed_and_prs_merged:{}", repo),
                StopPolicy::AfterFirstFire => "after_first_fire".to_string(),
            };
            let fresh_session_str = match a.fresh_session {
                FreshSession::Always => "always",
                FreshSession::Switch => "switch",
                FreshSession::Keep => "keep",
            };
            let driver_str = match a.driver {
                super::super::AutomationDriver::Scheduler => "scheduler",
                super::super::AutomationDriver::HarnessLoop => "harness_loop",
            };
            tx.execute(
                "INSERT INTO automations (id, mission_id, command_source_type, command_source_data,
                                         trigger_type, trigger_data, variables, active, stop_policy,
                                         fresh_session, driver, created_at, last_triggered_at, retry_max_retries,
                                         retry_delay_seconds, retry_backoff_multiplier)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                params![
                    a.id.to_string(),
                    a.mission_id.to_string(),
                    command_source_type,
                    command_source_data,
                    trigger_type,
                    trigger_data,
                    variables_json,
                    if a.active { 1 } else { 0 },
                    stop_policy_str,
                    fresh_session_str,
                    driver_str,
                    a.created_at,
                    a.last_triggered_at,
                    a.retry_config.max_retries as i64,
                    a.retry_config.retry_delay_seconds as i64,
                    a.retry_config.backoff_multiplier,
                ],
            )
            ?;
            if let Some(key) = a.active.then(|| crate::api::control::wakeup_supersession_key(a.variables.get("__wakeup_source").map(String::as_str), &a.trigger)).flatten() {
                let priors: Vec<(String, String, String, String, bool)> = {
                    let mut stmt = tx.prepare("SELECT id, variables, trigger_type, trigger_data, active FROM automations WHERE mission_id = ? AND id != ? ORDER BY created_at DESC, id DESC")?;
                    let rows = stmt.query_map(params![a.mission_id.to_string(), a.id.to_string()], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?.collect::<Result<Vec<_>, _>>()?;
                    rows
                };
                // Keep the key's quota of newest active rows (counting this one).
                let mut keep = crate::api::control::wakeup_supersession_keep(&key).saturating_sub(1);
                for (id, vars, kind, data, active) in priors {
                    let vars: std::collections::HashMap<String, String> = serde_json::from_str(&vars).unwrap_or_default();
                    let mut trigger: serde_json::Value = serde_json::from_str(&data).unwrap_or_default();
                    trigger["type"] = serde_json::Value::String(kind);
                    let Ok(trigger) = serde_json::from_value::<TriggerType>(trigger) else { continue };
                    if crate::api::control::wakeup_supersession_key(vars.get("__wakeup_source").map(String::as_str), &trigger).as_ref() == Some(&key) {
                        if active && keep > 0 {
                            keep -= 1;
                            continue;
                        }
                        tx.execute("UPDATE automations SET active = 0 WHERE id = ?", [&id])?;
                        tx.execute("UPDATE automation_executions SET status = 'cancelled', completed_at = ? WHERE automation_id = ? AND trigger_source = 'durable_schedule' AND status NOT IN ('cancelled','skipped') AND COALESCE(json_extract(variables_used, '$.__delivery_accepted'), '') != 'true'", params![now_string(), id])?;
                    }
                }
            }
            tx.commit()
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
        .map_err(|e| e.to_string())?;

        Ok(automation)
    }

    pub(super) async fn get_mission_automations(
        &self,
        mission_id: Uuid,
    ) -> Result<Vec<Automation>, String> {
        let conn = self.reader();
        let mission_id_str = mission_id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare("SELECT id, mission_id, command_source_type, command_source_data,
                                trigger_type, trigger_data, variables, active, stop_policy, fresh_session, created_at, last_triggered_at,
                                retry_max_retries, retry_delay_seconds, retry_backoff_multiplier, driver
                         FROM automations WHERE mission_id = ? ORDER BY created_at DESC")
                .map_err(|e| e.to_string())?;

            let automations = stmt
                .query_map([mission_id_str], |row| {
                    Self::parse_automation_row(row)
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(automations)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    pub(super) async fn list_active_automations(&self) -> Result<Vec<Automation>, String> {
        let conn = self.reader();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, mission_id, command_source_type, command_source_data,
                            trigger_type, trigger_data, variables, active, stop_policy, fresh_session, created_at, last_triggered_at,
                            retry_max_retries, retry_delay_seconds, retry_backoff_multiplier, driver
                     FROM automations WHERE active = 1 ORDER BY created_at DESC",
                )
                .map_err(|e| e.to_string())?;

            let automations = stmt
                .query_map([], |row| {
                    Self::parse_automation_row(row)
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(automations)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    pub(super) async fn get_automation(&self, id: Uuid) -> Result<Option<Automation>, String> {
        let conn = self.reader();
        let id_str = id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let result = conn
                .query_row(
                    "SELECT id, mission_id, command_source_type, command_source_data,
                            trigger_type, trigger_data, variables, active, stop_policy, fresh_session, created_at, last_triggered_at,
                            retry_max_retries, retry_delay_seconds, retry_backoff_multiplier, driver
                     FROM automations WHERE id = ?",
                    [id_str],
                    Self::parse_automation_row,
                )
                .optional()
                .map_err(|e| e.to_string())?;

            Ok(result)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    pub(super) async fn update_automation_active(
        &self,
        id: Uuid,
        active: bool,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE automations SET active = ? WHERE id = ?",
                params![if active { 1 } else { 0 }, id_str],
            )
            .map(|_| ())
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
        .map_err(|e| e.to_string())
    }

    pub(super) async fn update_automation_last_triggered(&self, id: Uuid) -> Result<(), String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let now = now_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE automations SET last_triggered_at = ? WHERE id = ?",
                params![now, id_str],
            )
            .map(|_| ())
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
        .map_err(|e| e.to_string())
    }

    pub(super) async fn delete_automation(&self, id: Uuid) -> Result<bool, String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let rows = conn
                .execute("DELETE FROM automations WHERE id = ?", params![id_str])
                .map_err(|e| e.to_string())?;
            Ok(rows > 0)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    pub(super) async fn update_automation(&self, automation: Automation) -> Result<(), String> {
        let conn = self.conn.clone();

        // Serialize command source
        let (command_source_type, command_source_data) = match &automation.command_source {
            CommandSource::Library { name } => {
                ("library", serde_json::json!({ "name": name }).to_string())
            }
            CommandSource::LocalFile { path } => (
                "local_file",
                serde_json::json!({ "path": path }).to_string(),
            ),
            CommandSource::Inline { content } => (
                "inline",
                serde_json::json!({ "content": content }).to_string(),
            ),
            CommandSource::NativeLoop {
                harness,
                command,
                args,
            } => (
                "native_loop",
                serde_json::json!({
                    "harness": harness,
                    "command": command,
                    "args": args,
                })
                .to_string(),
            ),
        };

        // Serialize trigger
        let (trigger_type, trigger_data) = match &automation.trigger {
            TriggerType::Interval { seconds } => (
                "interval",
                serde_json::json!({ "seconds": seconds }).to_string(),
            ),
            TriggerType::Cron {
                expression,
                timezone,
            } => (
                "cron",
                serde_json::json!({ "expression": expression, "timezone": timezone }).to_string(),
            ),
            TriggerType::Webhook { config } => (
                "webhook",
                serde_json::to_string(config).map_err(|e| e.to_string())?,
            ),
            TriggerType::AgentFinished => ("agent_finished", "{}".to_string()),
            TriggerType::DurableJobTerminal { job_id } => (
                "durable_job_terminal",
                serde_json::json!({ "job_id": job_id }).to_string(),
            ),
            TriggerType::Telegram { config } => (
                "telegram",
                serde_json::to_string(config).map_err(|e| e.to_string())?,
            ),
        };

        // Serialize variables
        let variables_json =
            serde_json::to_string(&automation.variables).map_err(|e| e.to_string())?;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let stop_policy_str = match &automation.stop_policy {
                StopPolicy::Never => "never".to_string(),
                StopPolicy::WhenMissionTerminal => "when_mission_terminal".to_string(),
                StopPolicy::WhenFailingConsecutively { count } => format!("consecutive_failures:{}", count),
                StopPolicy::WhenAllIssuesClosedAndPRsMerged { repo } => format!("all_issues_closed_and_prs_merged:{}", repo),
                StopPolicy::AfterFirstFire => "after_first_fire".to_string(),
            };
            let fresh_session_str = match automation.fresh_session {
                FreshSession::Always => "always",
                FreshSession::Switch => "switch",
                FreshSession::Keep => "keep",
            };
            conn.execute(
                "UPDATE automations SET command_source_type = ?, command_source_data = ?,
                                       trigger_type = ?, trigger_data = ?, variables = ?, active = ?,
                                       stop_policy = ?, fresh_session = ?, last_triggered_at = ?, retry_max_retries = ?, retry_delay_seconds = ?,
                                       retry_backoff_multiplier = ?
                  WHERE id = ?",
                params![
                    command_source_type,
                    command_source_data,
                    trigger_type,
                    trigger_data,
                    variables_json,
                    if automation.active { 1 } else { 0 },
                    stop_policy_str,
                    fresh_session_str,
                    automation.last_triggered_at,
                    automation.retry_config.max_retries as i64,
                    automation.retry_config.retry_delay_seconds as i64,
                    automation.retry_config.backoff_multiplier,
                    automation.id.to_string(),
                ],
            )
            .map(|_| ())
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
        .map_err(|e| e.to_string())
    }

    pub(super) async fn get_automation_by_webhook_id(
        &self,
        webhook_id: &str,
    ) -> Result<Option<Automation>, String> {
        let conn = self.conn.clone();
        let webhook_id = webhook_id.to_string();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let result = conn
                .query_row(
                    "SELECT id, mission_id, command_source_type, command_source_data,
                            trigger_type, trigger_data, variables, active, stop_policy, fresh_session, created_at, last_triggered_at,
                            retry_max_retries, retry_delay_seconds, retry_backoff_multiplier, driver
                     FROM automations
                     WHERE trigger_type = 'webhook' AND json_extract(trigger_data, '$.webhook_id') = ?",
                    [webhook_id],
                    Self::parse_automation_row,
                )
                .optional()
                .map_err(|e| e.to_string())?;

            Ok(result)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    pub(super) async fn create_automation_execution(
        &self,
        execution: AutomationExecution,
    ) -> Result<AutomationExecution, String> {
        let conn = self.conn.clone();

        let webhook_payload_json = execution
            .webhook_payload
            .as_ref()
            .map(|v| serde_json::to_string(v).unwrap_or_else(|_| "null".to_string()));

        let variables_used_json =
            serde_json::to_string(&execution.variables_used).unwrap_or_else(|_| "{}".to_string());

        let status_str = match execution.status {
            ExecutionStatus::Pending => "pending",
            ExecutionStatus::Running => "running",
            ExecutionStatus::Success => "success",
            ExecutionStatus::Failed => "failed",
            ExecutionStatus::Cancelled => "cancelled",
            ExecutionStatus::Skipped => "skipped",
        };

        let exec = execution.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO automation_executions (id, automation_id, mission_id, triggered_at,
                                                    trigger_source, status, webhook_payload, variables_used,
                                                    completed_at, error, retry_count)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                params![
                    exec.id.to_string(),
                    exec.automation_id.to_string(),
                    exec.mission_id.to_string(),
                    exec.triggered_at,
                    exec.trigger_source,
                    status_str,
                    webhook_payload_json,
                    variables_used_json,
                    exec.completed_at,
                    exec.error,
                    exec.retry_count as i64,
                ],
            )
            .map(|_| ())
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
        .map_err(|e| e.to_string())?;

        Ok(execution)
    }

    pub(super) async fn update_automation_execution(
        &self,
        execution: AutomationExecution,
    ) -> Result<(), String> {
        let conn = self.conn.clone();

        let webhook_payload_json = execution
            .webhook_payload
            .as_ref()
            .map(|v| serde_json::to_string(v).unwrap_or_else(|_| "null".to_string()));

        let variables_used_json =
            serde_json::to_string(&execution.variables_used).unwrap_or_else(|_| "{}".to_string());

        let status_str = match execution.status {
            ExecutionStatus::Pending => "pending",
            ExecutionStatus::Running => "running",
            ExecutionStatus::Success => "success",
            ExecutionStatus::Failed => "failed",
            ExecutionStatus::Cancelled => "cancelled",
            ExecutionStatus::Skipped => "skipped",
        };

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE automation_executions SET status = CASE WHEN trigger_source = 'durable_schedule' AND (status IN ('success', 'failed') OR (json_extract(variables_used, '$.__delivery_accepted') = 'true' AND ?1 = 'pending')) THEN status ELSE ?1 END, webhook_payload = ?, variables_used = json_patch(json_patch(json_patch(?3, CASE WHEN json_type(variables_used, '$.__continuation_message_id') = 'text' THEN json_object('__continuation_message_id', json_extract(variables_used, '$.__continuation_message_id')) ELSE '{}' END), CASE WHEN json_type(variables_used, '$.__remote_job_id') = 'text' THEN json_object('__remote_job_id', json_extract(variables_used, '$.__remote_job_id')) ELSE '{}' END), CASE WHEN json_extract(variables_used, '$.__delivery_accepted') = 'true' THEN json_object('__delivery_accepted', 'true') ELSE '{}' END),
                                                 completed_at = CASE WHEN trigger_source = 'durable_schedule' AND status IN ('success','failed') THEN completed_at ELSE ? END, error = CASE WHEN trigger_source = 'durable_schedule' AND (status IN ('success','failed') OR (json_extract(variables_used, '$.__delivery_accepted') = 'true' AND ?1 IN ('pending','running'))) THEN error ELSE ? END, retry_count = ?
                 WHERE id = ? AND (trigger_source != 'durable_schedule' OR status NOT IN ('cancelled', 'skipped'))",
                params![
                    status_str,
                    webhook_payload_json,
                    variables_used_json,
                    execution.completed_at,
                    execution.error,
                    execution.retry_count as i64,
                    execution.id.to_string(),
                ],
            )
            .map(|_| ())
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
        .map_err(|e| e.to_string())
    }

    pub(super) async fn get_automation_executions(
        &self,
        automation_id: Uuid,
        limit: Option<usize>,
    ) -> Result<Vec<AutomationExecution>, String> {
        let conn = self.conn.clone();
        let automation_id_str = automation_id.to_string();
        let limit = limit.unwrap_or(100) as i64;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, automation_id, mission_id, triggered_at, trigger_source, status,
                            webhook_payload, variables_used, completed_at, error, retry_count
                     FROM automation_executions
                     WHERE automation_id = ?
                     ORDER BY triggered_at DESC
                     LIMIT ?",
                )
                .map_err(|e| e.to_string())?;

            let executions = stmt
                .query_map(params![automation_id_str, limit], |row| {
                    Self::parse_execution_row(row)
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(executions)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    pub(super) async fn get_mission_automation_executions(
        &self,
        mission_id: Uuid,
        limit: Option<usize>,
    ) -> Result<Vec<AutomationExecution>, String> {
        let conn = self.conn.clone();
        let mission_id_str = mission_id.to_string();
        let limit = limit.unwrap_or(100) as i64;

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, automation_id, mission_id, triggered_at, trigger_source, status,
                            webhook_payload, variables_used, completed_at, error, retry_count
                     FROM automation_executions
                     WHERE mission_id = ?
                     ORDER BY triggered_at DESC
                     LIMIT ?",
                )
                .map_err(|e| e.to_string())?;

            let executions = stmt
                .query_map(params![mission_id_str, limit], |row| {
                    Self::parse_execution_row(row)
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            Ok(executions)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }
}
