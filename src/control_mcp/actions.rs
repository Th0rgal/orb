//! Action queue and receipts in the existing projects database. The queue stores
//! intent, not a second copy of mission/job state. An ambiguous dispatch is held.
use super::gateway::{Call, Principal};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use uuid::Uuid;

pub fn init(conn: &Connection) -> Result<(), String> {
    conn.execute_batch("CREATE TABLE IF NOT EXISTS mcp_actions_v1 (
        id TEXT PRIMARY KEY, owner TEXT NOT NULL, scope TEXT NOT NULL,
        retry_key TEXT NOT NULL, fingerprint TEXT NOT NULL, principal TEXT NOT NULL,
        tool TEXT NOT NULL, arguments TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'queued',
        result TEXT, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE(scope,retry_key));
        CREATE INDEX IF NOT EXISTS mcp_actions_pending ON mcp_actions_v1(state,created_at);
        CREATE TABLE IF NOT EXISTS mcp_sessions_v1 (
        id TEXT PRIMARY KEY, owner TEXT NOT NULL, mission_id TEXT, expires_at INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0,
        subject_kind TEXT NOT NULL DEFAULT 'mission', client_label TEXT, host_hint TEXT, project_scope TEXT, hard_expires_at INTEGER);")
        .map_err(|e|e.to_string())?;
    for col in [
        "subject_kind TEXT NOT NULL DEFAULT 'mission'",
        "client_label TEXT",
        "host_hint TEXT",
        "project_scope TEXT",
        "hard_expires_at INTEGER",
    ] {
        if let Err(e) = conn.execute(&format!("ALTER TABLE mcp_sessions_v1 ADD COLUMN {col}"), []) {
            let msg = e.to_string();
            if !msg.contains("duplicate column name") {
                return Err(msg);
            }
        }
    }
    Ok(())
}
fn scope(p: &Principal) -> String {
    json!([p.sub, p.action_scope_actor(), p.project]).to_string()
}
fn canonical(value: &Value) -> Value {
    match value {
        Value::Object(o) => serde_json::to_value(
            o.iter()
                .map(|(k, v)| (k.clone(), canonical(v)))
                .collect::<std::collections::BTreeMap<_, _>>(),
        )
        .unwrap(),
        Value::Array(a) => Value::Array(a.iter().map(canonical).collect()),
        v => v.clone(),
    }
}
pub fn reserve(conn: &Connection, p: &Principal, call: &Call) -> Result<Value, String> {
    let key = call.arguments["idempotency_key"]
        .as_str()
        .filter(|s| !s.trim().is_empty() && s.len() <= 200)
        .ok_or("idempotency_key must contain 1–200 bytes")?;
    let fingerprint = crate::project_context::digest(
        canonical(&json!({"tool":call.name,"arguments":call.arguments}))
            .to_string()
            .as_bytes(),
    );
    let id = Uuid::new_v4().to_string();
    conn.execute("INSERT OR IGNORE INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",params![id,p.sub,scope(p),key,fingerprint,serde_json::to_string(p).unwrap(),call.name,call.arguments.to_string()]).map_err(|e|e.to_string())?;
    let (id, old): (String, String) = conn
        .query_row(
            "SELECT id,fingerprint FROM mcp_actions_v1 WHERE scope=?1 AND retry_key=?2",
            params![scope(p), key],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(|e| e.to_string())?;
    if old != fingerprint {
        return Err("Idempotency key already belongs to different arguments".into());
    }
    read(conn, p, &id)
}
pub fn read(conn: &Connection, p: &Principal, id: &str) -> Result<Value, String> {
    let row: (String, Option<String>, String) = conn
        .query_row(
            "SELECT state,result,principal FROM mcp_actions_v1 WHERE id=?1 AND scope=?2",
            params![id, scope(p)],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .map_err(|_| "Action unavailable")?;
    let issuer: Principal = serde_json::from_str(&row.2).map_err(|_| "Unreadable action scope")?;
    if p.role != super::Role::Operator
        && issuer.role != super::Role::Executor
        && p.role != issuer.role
    {
        return Err("Action requires its original role or higher".into());
    }
    if let Some(raw) = row.1 {
        return serde_json::from_str(&raw).map_err(|_| "Unreadable receipt".into());
    }
    Ok(
        json!({"action_id":id,"state":row.0,"accepted":if row.0=="reconciliation_required"{"unknown"}else{"yes"},"next_tool":"get_action"}),
    )
}
pub fn claim(conn: &Connection) -> Result<Option<(String, Principal, Call)>, String> {
    // All callers hold the ProjectsStore mutex across SELECT and UPDATE.
    let row:Option<(String,String,String,String)>=conn.query_row("SELECT id,principal,tool,arguments FROM mcp_actions_v1 WHERE state='queued' ORDER BY created_at,id LIMIT 1",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional().map_err(|e|e.to_string())?;
    let Some((id, p, name, args)) = row else {
        return Ok(None);
    };
    let principal =
        serde_json::from_str(&p).map_err(|e| format!("Invalid action principal: {e}"))?;
    let arguments =
        serde_json::from_str(&args).map_err(|e| format!("Invalid action arguments: {e}"))?;
    let updated=conn.execute("UPDATE mcp_actions_v1 SET state='dispatching',updated_at=CURRENT_TIMESTAMP WHERE id=?1 AND state='queued'",[&id]).map_err(|e|e.to_string())?;
    if updated != 1 {
        return Ok(None);
    }
    Ok(Some((id, principal, Call { name, arguments })))
}

/// Cancellation and its own retry receipt commit together under the store
/// mutex. A dispatcher cannot claim the target between the check and update.
pub fn cancel(conn: &Connection, p: &Principal, call: &Call) -> Result<Value, String> {
    let target = call.arguments["action_id"]
        .as_str()
        .ok_or("Missing action ID")?;
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    let target_receipt = read(&tx, p, target)?;
    let receipt = reserve(&tx, p, call)?;
    if receipt["state"] != "queued" {
        tx.commit().map_err(|e| e.to_string())?;
        return Ok(receipt);
    }
    let id = receipt["action_id"]
        .as_str()
        .ok_or("Missing cancellation receipt")?;
    let cancelled = target_receipt["state"] == "queued" || target_receipt["state"] == "cancelled";
    if target_receipt["state"] == "queued" {
        let result = json!({"action_id":target,"state":"cancelled","accepted":"no"});
        tx.execute("UPDATE mcp_actions_v1 SET state='cancelled',result=?1,updated_at=CURRENT_TIMESTAMP WHERE id=?2 AND state='queued'",
            params![result.to_string(),target]).map_err(|e|e.to_string())?;
    }
    let result = json!({"action_id":id,"state":"completed","result":{
        "target_action_id":target,"cancelled":cancelled,
        "reason":if cancelled {"Cancelled before dispatch"} else {"Dispatch already started or settled; inspect the target before cancelling its mission/job"}
    }});
    tx.execute("UPDATE mcp_actions_v1 SET state='completed',result=?1,updated_at=CURRENT_TIMESTAMP WHERE id=?2 AND state='queued'",
        params![result.to_string(),id]).map_err(|e|e.to_string())?;
    tx.commit().map_err(|e| e.to_string())?;
    Ok(result)
}
pub fn finish(conn: &Connection, id: &str, value: &Value) -> Result<(), String> {
    let status = value["state"].as_str().ok_or("Missing action state")?;
    let count=conn.execute("UPDATE mcp_actions_v1 SET state=?1,result=?2,updated_at=CURRENT_TIMESTAMP WHERE id=?3 AND state='dispatching'",params![status,value.to_string(),id]).map_err(|e|e.to_string())?;
    if count != 1 {
        return Err("Action was not dispatching".into());
    }
    Ok(())
}

/// An operator records evidence after inspecting an uncertain target. This
/// settles the existing action, never replays its side effect.
pub fn reconcile(conn: &Connection, p: &Principal, call: &Call) -> Result<Value, String> {
    if p.role != super::Role::Operator {
        return Err("Operator role required".into());
    }
    let target = call.arguments["action_id"]
        .as_str()
        .ok_or("Missing target")?;
    let resolution = call.arguments["resolution"]
        .as_str()
        .filter(|s| matches!(*s, "completed" | "rejected"))
        .ok_or("Invalid resolution")?;
    let evidence = call.arguments["evidence"]
        .as_str()
        .filter(|s| !s.trim().is_empty() && s.len() <= 4096)
        .ok_or("Evidence is required")?;
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    let previous = read(&tx, p, target)?;
    let receipt = reserve(&tx, p, call)?;
    if receipt["state"] != "queued" {
        tx.commit().map_err(|e| e.to_string())?;
        return Ok(receipt);
    }
    if previous["state"] != "reconciliation_required" {
        return Err("Only uncertain actions may be reconciled".into());
    }
    let id = receipt["action_id"]
        .as_str()
        .ok_or("Missing reconciliation receipt")?;
    let mut settled = json!({"action_id":target,"state":resolution,"accepted":if resolution=="completed"{"yes"}else{"no"},
        "result":{"reconciled":true,"evidence":evidence},
        "reconciliation":{"action_id":id,"operator":p.sub,"previous_receipt":previous}});
    super::assistant::scrub_sensitive_json(&mut settled);
    tx.execute("UPDATE mcp_actions_v1 SET state=?1,result=?2,updated_at=CURRENT_TIMESTAMP WHERE id=?3 AND state='reconciliation_required'",
        params![resolution,settled.to_string(),target]).map_err(|e|e.to_string())?;
    let result = json!({"action_id":id,"state":"completed","result":{"target_action_id":target,"receipt":settled}});
    tx.execute("UPDATE mcp_actions_v1 SET state='completed',result=?1,updated_at=CURRENT_TIMESTAMP WHERE id=?2 AND state='queued'",params![result.to_string(),id]).map_err(|e|e.to_string())?;
    tx.commit().map_err(|e| e.to_string())?;
    Ok(result)
}
/// History deletion preserves files and action receipts. Unlike filesystem
/// purge, it only needs to retain missions an accepted action can depend on.
/// Unknown tools/legacy scopes remain conservative until their dependencies
/// have been audited here. Callers hold the dispatch admission fence.
pub(crate) fn require_history_deletable(
    conn: &Connection,
    owner: &str,
    mission_ids: &std::collections::HashSet<Uuid>,
    board_task_ids: &std::collections::HashSet<String>,
) -> Result<Vec<(String, Uuid)>, String> {
    let exists: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='mcp_actions_v1')",
        [], |r| r.get(0),
    ).map_err(|e| e.to_string())?;
    if !exists || mission_ids.is_empty() {
        return Ok(Vec::new());
    }
    let mut stmt = conn.prepare(
        "SELECT id,tool,state,principal,arguments FROM mcp_actions_v1 WHERE owner=?1 AND state IN ('queued','dispatching','reconciliation_required') ORDER BY created_at,id",
    ).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([owner], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, String>(4)?,
            ))
        })
        .map_err(|e| e.to_string())?;
    let mut replacements = Vec::new();
    for row in rows {
        let (id, tool, state, principal, arguments) = row.map_err(|e| e.to_string())?;
        let disjoint = (|| {
            let p: Principal = serde_json::from_str(&principal).ok()?;
            if p.sub != owner {
                return None;
            }
            let args: Value = serde_json::from_str(&arguments).ok()?;
            args.as_object()?;
            if p.mission_id.is_some_and(|id| mission_ids.contains(&id)) {
                return Some(false);
            }
            // These are canonical UUIDs, normalized/validated at acceptance.
            // Do not treat missing/invalid legacy targets as disjoint.
            for field in [
                "mission_id",
                "parent_mission_id",
                "supersedes_mission_id",
                "owner_mission_id",
            ] {
                if let Some(value) = args.get(field).filter(|v| !v.is_null()) {
                    let id = Uuid::parse_str(value.as_str()?).ok()?;
                    if mission_ids.contains(&id) {
                        return Some(false);
                    }
                }
            }
            match tool.as_str() {
                "resume_mission"
                | "send_message_to_mission"
                | "ask_mission"
                | "answer_mission_question"
                | "cancel_mission"
                | "acknowledge_mission"
                | "adopt_mission"
                | "link_mission_to_project"
                | "update_mission_settings"
                | "start_workspace_job"
                | "create_worktree"
                | "remove_worktree"
                | "merge_branch" => {
                    Uuid::parse_str(args.get("mission_id")?.as_str()?).ok()?;
                }
                // New children depend on their issuer/parent and superseded
                // mission, not every historical mission in the project.
                "start_mission" | "consult_model" => {
                    if let Some(prior) = args.get("supersedes_mission_id").and_then(Value::as_str) {
                        // The caller resolves inherited successor lineage under
                        // admission, after releasing the SQLite mutex.
                        replacements.push((id.clone(), Uuid::parse_str(prior).ok()?));
                    }
                    // Creation also infers lineage from Hermes' per-mission
                    // session. Reuse its parser so deletion cannot orphan an
                    // accepted launch from an unbound operator session.
                    if args
                        .get("origin_session_id")
                        .and_then(Value::as_str)
                        .and_then(crate::managed::lifecycle::mission_of_orb_session)
                        .is_some_and(|id| mission_ids.contains(&id))
                    {
                        return Some(false);
                    }
                }
                "schedule_wakeup" | "schedule_job_wakeup" | "plan_tasks" => {
                    p.mission_id?;
                }
                // Indirect worker board mutations resolve their worker from the
                // board at dispatch time rather than carrying a mission UUID.
                "reject_task" | "review_task" => return Some(false),
                // Accept records a board verdict without resuming its worker,
                // but deletion of its boss cascades to the task record.
                // Keys are board-local: the issuer check above protects their
                // boss. Only task UUIDs may be compared across boards.
                // VM destruction owns a machine, not conversation history;
                // unsettled mission jobs are checked separately by deletion.
                "accept_task" => {
                    let mut identified = false;
                    for field in ["task_id", "task_key"] {
                        if let Some(value) = args.get(field).filter(|v| !v.is_null()) {
                            let reference = value.as_str()?;
                            if reference.is_empty()
                                || (field == "task_id"
                                    && args.get("task_key").is_none_or(Value::is_null)
                                    && board_task_ids.contains(reference))
                            {
                                return Some(false);
                            }
                            identified = true;
                        }
                    }
                    if !identified {
                        return None;
                    }
                }
                "cancel_workspace_job" => {
                    Uuid::parse_str(args.get("job_id")?.as_str()?).ok()?;
                }
                "cancel_action" | "reconcile_action" => {
                    Uuid::parse_str(args.get("action_id")?.as_str()?).ok()?;
                }
                "update_project_status" => {
                    if crate::api::controller_honesty::parse_inspect_mission_id(
                        args.get("next_action").and_then(Value::as_str),
                    )
                    .is_some_and(|id| mission_ids.contains(&id))
                    {
                        return Some(false);
                    }
                }
                "spawn_managed_machine"
                | "destroy_managed_machine"
                | "extend_managed_machine"
                | "snapshot_managed_machine"
                | "delete_managed_snapshot"
                | "fork_managed_machine"
                | "stop_managed_machine"
                | "resume_managed_machine"
                | "exec_raw_managed_machine"
                | "set_project_track"
                | "accept_project_track_evidence"
                | "reopen_project_track"
                | "accept_project_track"
                | "invalidate_project_track_evidence"
                | "add_project_steer"
                | "record_project_decision"
                | "answer_project_decision"
                | "plan_project_tasks"
                | "update_project_task"
                | "cancel_project_task"
                | "set_project_grant"
                | "create_workspace"
                | "update_workspace"
                | "delete_workspace"
                | "save_workspace_template"
                | "delete_workspace_template"
                | "rebuild_workspace_from_template"
                | "deploy_sandboxed_sh" => {}
                _ => return None,
            }
            Some(true)
        })() == Some(true);
        if !disjoint {
            return Err(format!(
                "Accepted MCP action {id} ({tool}, {state}) may depend on this mission; inspect get_action and settle it before deleting"
            ));
        }
    }
    Ok(replacements)
}

fn has_http_status_in(message: &str, range: std::ops::RangeInclusive<u16>) -> bool {
    for prefix in ["(", "HTTP "] {
        let mut rest = message;
        while let Some(pos) = rest.find(prefix) {
            let after = &rest[pos + prefix.len()..];
            if after.len() >= 3 && after.as_bytes()[..3].iter().all(u8::is_ascii_digit) {
                let next_ok = after
                    .as_bytes()
                    .get(3)
                    .is_none_or(|b| matches!(b, b' ' | b')' | b':'));
                if next_ok {
                    if let Ok(code) = after[..3].parse::<u16>() {
                        if range.contains(&code) {
                            return true;
                        }
                    }
                }
            }
            rest = after;
        }
    }
    false
}

/// True when a workspace Git mutation (`create_worktree`, `remove_worktree`,
/// `merge_branch`) may have reached the target machine or repository without a
/// confirmed terminal receipt. Deterministic preflight/refusal errors return
/// `false` so the action settles as `rejected` (`accepted = "no"`).
pub(crate) fn is_uncertain_workspace_error(error: &str) -> bool {
    error.contains("Node operation outcome unknown")
        || error.contains("Workspace operation outcome unknown")
        || error.contains("Invalid workspace receipt")
        || error.contains("Workspace operation produced no valid receipt")
        || error.contains("Backend diagnostic contained credentials")
}

/// True when an MCP mutation error leaves side effects unconfirmed and must
/// hold the receipt in `reconciliation_required` (`accepted = "unknown"`).
/// Deterministic validation, authorization, HTTP 4xx, and cleaned-up spawn
/// rejections return `false` so the receipt settles as `rejected`.
pub(crate) fn is_uncertain_dispatch_error(tool: &str, error: &str) -> bool {
    let stripped = error
        .strip_prefix("Outcome unconfirmed; inspect before retrying. ")
        .or_else(|| {
            error.strip_prefix(
                "Workspace operation outcome is unconfirmed; inspect its target before retrying. ",
            )
        })
        .unwrap_or(error)
        .trim();
    if matches!(tool, "create_worktree" | "remove_worktree" | "merge_branch") {
        if stripped
            == "Workspace operation outcome is unconfirmed; inspect its target before retrying"
        {
            return true;
        }
        return is_uncertain_workspace_error(stripped);
    }
    if stripped.is_empty()
        || stripped.contains("Backend diagnostic contained credentials")
        || stripped.contains("HTTP request failed:")
        || stripped.contains("Failed to read ")
        || stripped.contains("Failed to parse ")
        || stripped.contains("Invalid cancellation receipt")
        || stripped.contains("Cancellation outcome is unknown")
        || stripped.contains("Invalid wake-up receipt:")
        || stripped.contains("Created mission response did not include an id")
        || stripped.contains("Mission ACK mutation succeeded")
        || stripped.contains("Save workspace template succeeded")
        || stripped.contains("Outcome unconfirmed")
        || stripped.contains("SSE stream error:")
        || stripped.contains("Deploy failed:")
        || stripped.contains("Missing worktree path receipt")
    {
        return true;
    }
    if has_http_status_in(stripped, 500..=599) {
        // Pre-commit / cleaned-up 5xx exceptions:
        // - `disabled (503)`: managed-machines manager not initialised.
        // - `provision_failed (502)` / `provision_failed (500)`: ManagedManager::spawn
        //   destroys the failed sandbox before returning and never hands out a VM.
        // - `No assistant LLM configured` (503): rejected before Ask thread creation.
        // - Pre-fix `ask_mission` workspace resolution 500s: rejected before Ask LLM run.
        if stripped.starts_with("disabled (503")
            || stripped.starts_with("provision_failed (502")
            || stripped.starts_with("provision_failed (500")
            || (tool == "ask_mission"
                && (stripped.contains("No assistant LLM configured")
                    || stripped.contains("mission workspace is unavailable or not prepared:")
                    || stripped.contains("persisted mission workspace root is unavailable:")
                    || stripped.contains("explicit working_directory owner is unavailable")))
        {
            return false;
        }
        return true;
    }
    false
}

pub fn recover(conn: &Connection) -> Result<usize, String> {
    // Queued work can be safely started. Dispatched work cannot be blindly
    // replayed: a provider may have accepted it before Core lost the response.
    let recovered = conn
        .execute(
            "UPDATE mcp_actions_v1 SET state='reconciliation_required',updated_at=CURRENT_TIMESTAMP WHERE state='dispatching'",
            [],
        )
        .map_err(|e| e.to_string())?;
    reclassify_deterministic_rejections(conn)?;
    Ok(recovered)
}

/// Settle historical `reconciliation_required` receipts that recorded a known
/// deterministic pre-commit rejection before `run_accepted` distinguished
/// `accepted = "no"` from `accepted = "unknown"`. Rows with `result IS NULL`
/// (in-flight crash recovery) or genuine transport/5xx/readback uncertainty are
/// never touched.
fn reclassify_deterministic_rejections(conn: &Connection) -> Result<usize, String> {
    let exists: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='mcp_actions_v1')",
            [],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    if !exists {
        return Ok(0);
    }
    let rows: Vec<(String, String, String)> = {
        let mut stmt = conn
            .prepare(
                "SELECT id, tool, result FROM mcp_actions_v1 WHERE state='reconciliation_required' AND result IS NOT NULL",
            )
            .map_err(|e| e.to_string())?;
        let mapped = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map_err(|e| e.to_string())?;
        mapped
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?
    };
    let mut updates = Vec::new();
    for (id, tool, raw_result) in rows {
        let Ok(mut receipt) = serde_json::from_str::<Value>(&raw_result) else {
            continue;
        };
        let Some(message) = receipt
            .get("error")
            .and_then(|e| e.get("message"))
            .and_then(Value::as_str)
            .map(str::to_string)
        else {
            continue;
        };
        if is_uncertain_dispatch_error(&tool, &message) {
            continue;
        }
        let clean = message
            .strip_prefix("Outcome unconfirmed; inspect before retrying. ")
            .unwrap_or(&message)
            .to_string();
        receipt["state"] = json!("rejected");
        if let Some(err_obj) = receipt.get_mut("error").and_then(Value::as_object_mut) {
            err_obj.insert("accepted".into(), json!("no"));
            err_obj.insert("code".into(), json!("execution_rejected"));
            err_obj.insert("message".into(), json!(clean));
        }
        updates.push((id, receipt.to_string()));
    }
    if updates.is_empty() {
        return Ok(0);
    }
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    let mut changed = 0usize;
    for (id, updated_result) in updates {
        changed += tx
            .execute(
                "UPDATE mcp_actions_v1 SET state='rejected', result=?1, updated_at=CURRENT_TIMESTAMP WHERE id=?2 AND state='reconciliation_required' AND result IS NOT NULL",
                params![updated_result, id],
            )
            .map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())?;
    Ok(changed)
}

#[cfg(test)]
mod tests {
    use super::super::Role;
    use super::*;
    fn principal() -> Principal {
        Principal {
            sub: "alice".into(),
            username: "alice".into(),
            role: Role::Executor,
            mission_id: Some(Uuid::new_v4()),
            project: None,
            action_run_generation: None,
            session_id: Uuid::new_v4(),
            exp: usize::MAX,
            client_kind: None,
            client_label: None,
            host_hint: None,
        }
    }
    fn call() -> Call {
        Call {
            name: "start_mission".into(),
            arguments: json!({"title":"x","prompt":"x","idempotency_key":"stable"}),
        }
    }
    #[test]
    fn history_deletion_scopes_accepted_actions_without_settling_them() {
        let conn = Connection::open_in_memory().unwrap();
        init(&conn).unwrap();
        let target = Uuid::new_v4();
        let ids = std::collections::HashSet::from([target]);
        let mut p = principal();
        let mut c = call();
        c.name = "resume_mission".into();
        c.arguments["mission_id"] = json!(Uuid::new_v4());
        let receipt = reserve(&conn, &p, &c).unwrap();
        let action = receipt["action_id"].as_str().unwrap();
        for state in ["queued", "dispatching", "reconciliation_required"] {
            conn.execute("UPDATE mcp_actions_v1 SET state=?1", [state])
                .unwrap();
            // Regression: unrelated old uncertainty cannot lock all deletion.
            require_history_deletable(&conn, &p.sub, &ids, &std::collections::HashSet::new())
                .unwrap();
            c.arguments["mission_id"] = json!(target);
            conn.execute(
                "UPDATE mcp_actions_v1 SET arguments=?1",
                [c.arguments.to_string()],
            )
            .unwrap();
            let error =
                require_history_deletable(&conn, &p.sub, &ids, &std::collections::HashSet::new())
                    .unwrap_err();
            assert!(error.contains(action) && error.contains(state));
            c.arguments["mission_id"] = json!(Uuid::new_v4());
            conn.execute(
                "UPDATE mcp_actions_v1 SET arguments=?1",
                [c.arguments.to_string()],
            )
            .unwrap();
        }
        // The entire descendant deletion set is protected, not just its root.
        let child = Uuid::new_v4();
        c.arguments["mission_id"] = json!(child);
        conn.execute(
            "UPDATE mcp_actions_v1 SET arguments=?1",
            [c.arguments.to_string()],
        )
        .unwrap();
        require_history_deletable(&conn, &p.sub, &ids, &std::collections::HashSet::new()).unwrap();
        assert!(require_history_deletable(
            &conn,
            &p.sub,
            &std::collections::HashSet::from([target, child]),
            &std::collections::HashSet::new()
        )
        .is_err());
        // Other owners' receipts cannot block deletion or disclose their IDs.
        require_history_deletable(
            &conn,
            "other-owner",
            &std::collections::HashSet::from([child]),
            &std::collections::HashSet::new(),
        )
        .unwrap();
        // The issuer can be the parent of new work, even with another target.
        p.mission_id = Some(target);
        conn.execute(
            "UPDATE mcp_actions_v1 SET principal=?1",
            [serde_json::to_string(&p).unwrap()],
        )
        .unwrap();
        assert!(
            require_history_deletable(&conn, &p.sub, &ids, &std::collections::HashSet::new())
                .is_err()
        );
        p.mission_id = None;
        conn.execute(
            "UPDATE mcp_actions_v1 SET principal=?1",
            [serde_json::to_string(&p).unwrap()],
        )
        .unwrap();
        for (tool, args, allowed) in [
            ("start_mission", json!({"parent_mission_id":target}), false),
            (
                "start_mission",
                json!({"supersedes_mission_id":target}),
                false,
            ),
            ("start_mission", json!({}), true),
            (
                "start_mission",
                json!({"origin_session_id":format!("orb_{}", target.simple())}),
                false,
            ),
            (
                "consult_model",
                json!({"origin_session_id":format!("orb_{}", target.simple())}),
                false,
            ),
            (
                "start_mission",
                json!({"origin_session_id":format!("orb_{}", Uuid::new_v4().simple())}),
                true,
            ),
            (
                "start_mission",
                json!({"origin_session_id":"shared-chat"}),
                true,
            ),
            ("resume_mission", json!({}), false),
            ("resume_mission", json!({"mission_id":"short-id"}), false),
            ("new_unknown_tool", json!({}), false),
            ("reject_task", json!({"task_id":"indirect-worker"}), false),
            ("schedule_wakeup", json!({}), false),
            ("accept_task", json!({"task_id":"settled-verdict"}), true),
            ("destroy_managed_machine", json!({"machine_id":"vm"}), true),
        ] {
            conn.execute(
                "UPDATE mcp_actions_v1 SET tool=?1,arguments=?2",
                params![tool, args.to_string()],
            )
            .unwrap();
            assert_eq!(
                require_history_deletable(&conn, &p.sub, &ids, &std::collections::HashSet::new())
                    .is_ok(),
                allowed,
                "{tool}: {args}"
            );
        }
        for field in ["task_id", "task_key"] {
            conn.execute(
                "UPDATE mcp_actions_v1 SET tool='accept_task', arguments=?1",
                [json!({field:"owned-task"}).to_string()],
            )
            .unwrap();
            assert_eq!(
                require_history_deletable(
                    &conn,
                    &p.sub,
                    &ids,
                    &std::collections::HashSet::from(["owned-task".to_string()])
                )
                .is_err(),
                field == "task_id"
            );
        }
        // The resolver gives task_key precedence over task_id.
        conn.execute(
            "UPDATE mcp_actions_v1 SET arguments=?1",
            [json!({"task_key":"owned-task", "task_id":"owned-task"}).to_string()],
        )
        .unwrap();
        require_history_deletable(
            &conn,
            &p.sub,
            &ids,
            &std::collections::HashSet::from(["owned-task".to_string()]),
        )
        .unwrap();
        // The same key on another boss's board is disjoint; deleting the
        // issuing boss is blocked by identity, regardless of the key text.
        for boss in [Uuid::new_v4(), target] {
            p.mission_id = Some(boss);
            conn.execute(
                "UPDATE mcp_actions_v1 SET principal=?1",
                [serde_json::to_string(&p).unwrap()],
            )
            .unwrap();
            assert_eq!(
                require_history_deletable(
                    &conn,
                    &p.sub,
                    &ids,
                    &std::collections::HashSet::from(["owned-task".to_string()])
                )
                .is_err(),
                boss == target
            );
        }
        conn.execute("UPDATE mcp_actions_v1 SET principal='{}'", [])
            .unwrap();
        assert!(
            require_history_deletable(&conn, &p.sub, &ids, &std::collections::HashSet::new())
                .is_err()
        );
        conn.execute("UPDATE mcp_actions_v1 SET state='completed'", [])
            .unwrap();
        require_history_deletable(&conn, &p.sub, &ids, &std::collections::HashSet::new()).unwrap();
    }

    #[test]
    fn duplicate_collision_and_cross_user_access() {
        let conn = Connection::open_in_memory().unwrap();
        init(&conn).unwrap();
        let p = principal();
        let mut c = call();
        let first = reserve(&conn, &p, &c).unwrap();
        assert_eq!(first, reserve(&conn, &p, &c).unwrap());
        c.arguments["title"] = json!("different");
        assert!(reserve(&conn, &p, &c).is_err());
        let mut other = p.clone();
        other.sub = "bob".into();
        assert!(read(&conn, &other, first["action_id"].as_str().unwrap()).is_err());
    }
    #[test]
    fn queued_cancellation_is_atomic_idempotent_and_does_not_claim_running_work_stopped() {
        let conn = Connection::open_in_memory().unwrap();
        init(&conn).unwrap();
        let p = principal();
        let target = reserve(&conn, &p, &call()).unwrap();
        let cancellation = Call {
            name: "cancel_action".into(),
            arguments: json!({
                "action_id":target["action_id"],"idempotency_key":"cancel-once"
            }),
        };
        let receipt = cancel(&conn, &p, &cancellation).unwrap();
        assert_eq!(receipt["result"]["cancelled"], true);
        assert_eq!(receipt, cancel(&conn, &p, &cancellation).unwrap());
        assert!(claim(&conn).unwrap().is_none());
        let mut next = call();
        next.arguments["idempotency_key"] = json!("next");
        let target = reserve(&conn, &p, &next).unwrap();
        assert!(claim(&conn).unwrap().is_some());
        let cancellation = Call {
            name: "cancel_action".into(),
            arguments: json!({
                "action_id":target["action_id"],"idempotency_key":"cancel-running"
            }),
        };
        let receipt = cancel(&conn, &p, &cancellation).unwrap();
        assert_eq!(receipt["result"]["cancelled"], false);
        assert_eq!(
            read(&conn, &p, target["action_id"].as_str().unwrap()).unwrap()["state"],
            "dispatching"
        );
    }

    #[test]
    fn lower_role_cannot_read_or_reuse_an_elevated_action_receipt() {
        let conn = Connection::open_in_memory().unwrap();
        init(&conn).unwrap();
        let mut operator = principal();
        operator.role = Role::Operator;
        let receipt = reserve(&conn, &operator, &call()).unwrap();
        let id = receipt["action_id"].as_str().unwrap();
        let mut executor = operator.clone();
        executor.role = Role::Executor;
        assert!(read(&conn, &executor, id).is_err());
        assert!(reserve(&conn, &executor, &call()).is_err());
        assert!(read(&conn, &operator, id).is_ok());
    }

    #[test]
    fn crash_keeps_queued_work_and_does_not_redispatch_uncertain_work() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("actions.db");
        let p = principal();
        let id = {
            let conn = Connection::open(&path).unwrap();
            init(&conn).unwrap();
            let v = reserve(&conn, &p, &call()).unwrap();
            v["action_id"].as_str().unwrap().to_string()
        };
        let conn = Connection::open(&path).unwrap();
        recover(&conn).unwrap();
        let (claimed, _, _) = claim(&conn).unwrap().unwrap();
        assert_eq!(claimed, id);
        assert!(claim(&conn).unwrap().is_none());
        recover(&conn).unwrap();
        assert!(claim(&conn).unwrap().is_none());
        assert_eq!(
            read(&conn, &p, &id).unwrap()["state"],
            "reconciliation_required"
        );
        assert_eq!(reserve(&conn, &p, &call()).unwrap()["action_id"], id);
    }

    #[test]
    fn reconciliation_requires_operator_evidence_is_durable_and_never_replays() {
        let conn = Connection::open_in_memory().unwrap();
        init(&conn).unwrap();
        let mut p = principal();
        let original = call();
        let target = reserve(&conn, &p, &original).unwrap()["action_id"].clone();
        claim(&conn).unwrap();
        let c = Call {
            name: "reconcile_action".into(),
            arguments: json!({"action_id":target,"resolution":"completed","evidence":"Verified mission receipt at /api/control/missions/example","idempotency_key":"reconcile-once"}),
        };
        assert!(reconcile(&conn, &p, &c).is_err());
        p.role = Role::Operator;
        assert!(reconcile(&conn, &p, &c).is_err());
        recover(&conn).unwrap();
        let mut empty = c.clone();
        empty.arguments["evidence"] = json!(" ");
        assert!(reconcile(&conn, &p, &empty).is_err());
        let receipt = reconcile(&conn, &p, &c).unwrap();
        assert_eq!(reconcile(&conn, &p, &c).unwrap(), receipt);
        assert_eq!(reserve(&conn, &p, &original).unwrap()["state"], "completed");
        assert!(claim(&conn).unwrap().is_none());
    }
    #[test]
    fn completed_result_survives_retry_and_session_renewal() {
        let conn = Connection::open_in_memory().unwrap();
        init(&conn).unwrap();
        let mut p = principal();
        let c = call();
        let id = reserve(&conn, &p, &c).unwrap()["action_id"]
            .as_str()
            .unwrap()
            .to_string();
        claim(&conn).unwrap();
        let result = json!({"action_id":id,"state":"completed","result":{"mission_id":"verified"}});
        finish(&conn, &id, &result).unwrap();
        p.session_id = Uuid::new_v4();
        assert_eq!(reserve(&conn, &p, &c).unwrap(), result);
        assert!(finish(&conn, &id, &result).is_err());
    }
    #[test]
    fn project_sessions_cannot_read_or_replay_each_others_actions() {
        let conn = Connection::open_in_memory().unwrap();
        init(&conn).unwrap();
        let mut p = principal();
        p.mission_id = None;
        p.project = Some("first".into());
        let original = reserve(&conn, &p, &call()).unwrap();
        p.project = Some("second".into());
        assert!(read(&conn, &p, original["action_id"].as_str().unwrap()).is_err());
        assert_ne!(
            reserve(&conn, &p, &call()).unwrap()["action_id"],
            original["action_id"]
        );
    }
    #[test]
    fn legacy_missionless_actions_stay_addressable_while_external_sessions_isolate_by_session_id() {
        let conn = Connection::open_in_memory().unwrap();
        init(&conn).unwrap();
        let mut legacy = principal();
        legacy.role = Role::Coordinator;
        legacy.mission_id = None;
        legacy.client_kind = None;
        let c = call();
        let legacy_receipt = reserve(&conn, &legacy, &c).unwrap();
        let legacy_id = legacy_receipt["action_id"].as_str().unwrap();
        // Simulated pre-upgrade row shape `[owner, null, project]` stays readable & idempotent:
        assert_eq!(
            scope(&legacy),
            json!([legacy.sub, null, legacy.project]).to_string()
        );
        assert_eq!(
            read(&conn, &legacy, legacy_id).unwrap()["action_id"],
            legacy_id
        );
        assert_eq!(reserve(&conn, &legacy, &c).unwrap()["action_id"], legacy_id);

        // Newly minted external sessions (`client_kind.is_some()`) isolate by `session_id`:
        let mut ext1 = legacy.clone();
        ext1.session_id = Uuid::new_v4();
        ext1.client_kind = Some(crate::api::approval_flow::ExternalClientKind::Cli);
        let ext1_receipt = reserve(&conn, &ext1, &c).unwrap();
        let ext1_id = ext1_receipt["action_id"].as_str().unwrap();
        assert_ne!(ext1_id, legacy_id);
        assert_eq!(reserve(&conn, &ext1, &c).unwrap()["action_id"], ext1_id);

        let mut ext2 = ext1.clone();
        ext2.session_id = Uuid::new_v4();
        assert!(read(&conn, &ext2, ext1_id).is_err());
        assert_ne!(reserve(&conn, &ext2, &c).unwrap()["action_id"], ext1_id);
    }

    #[test]
    fn every_registered_mutation_tool_has_explicit_history_delete_scoping() {
        let conn = Connection::open_in_memory().unwrap();
        init(&conn).unwrap();
        let target = Uuid::new_v4();
        let other = Uuid::new_v4();
        let ids = std::collections::HashSet::from([target]);
        let issuer = Principal {
            sub: "alice".into(),
            username: "alice".into(),
            role: Role::Operator,
            mission_id: Some(other),
            project: None,
            action_run_generation: Some(1),
            session_id: Uuid::new_v4(),
            exp: usize::MAX,
            client_kind: None,
            client_label: None,
            host_hint: None,
        };
        let mut mutation_tools: Vec<String> = super::super::registry()
            .into_iter()
            .filter(|t| t.mutation)
            .map(|t| t.definition.name)
            .collect();
        mutation_tools.sort();
        assert!(!mutation_tools.is_empty());

        for tool in &mutation_tools {
            let args = match tool.as_str() {
                "cancel_workspace_job" => json!({"job_id": other}),
                "cancel_action" | "reconcile_action" => json!({"action_id": other}),
                "accept_task" => json!({"task_key": "k1"}),
                "reject_task" | "review_task" => json!({"task_key": "k1", "feedback": "f"}),
                name if matches!(
                    name,
                    "resume_mission"
                        | "send_message_to_mission"
                        | "ask_mission"
                        | "answer_mission_question"
                        | "cancel_mission"
                        | "acknowledge_mission"
                        | "adopt_mission"
                        | "link_mission_to_project"
                        | "update_mission_settings"
                        | "start_workspace_job"
                        | "create_worktree"
                        | "remove_worktree"
                        | "merge_branch"
                ) =>
                {
                    json!({"mission_id": other})
                }
                _ => json!({}),
            };
            conn.execute("DELETE FROM mcp_actions_v1", []).unwrap();
            conn.execute(
                "INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state) VALUES('row',?1,'s','k','f',?2,?3,?4,'reconciliation_required')",
                params![issuer.sub, serde_json::to_string(&issuer).unwrap(), tool, args.to_string()],
            )
            .unwrap();
            let res = require_history_deletable(
                &conn,
                &issuer.sub,
                &ids,
                &std::collections::HashSet::new(),
            );
            if matches!(tool.as_str(), "reject_task" | "review_task") {
                assert!(
                    res.is_err(),
                    "{tool} must conservatively block indirect worker lookup"
                );
            } else {
                assert!(
                    res.is_ok(),
                    "registered mutation tool `{tool}` with disjoint args blocked history delete: {res:?}"
                );
            }
        }

        // `owner_mission_id` and `update_project_status` `inspect <uuid>` block matching targets.
        let missionless = Principal {
            mission_id: None,
            ..issuer
        };
        conn.execute("DELETE FROM mcp_actions_v1", []).unwrap();
        conn.execute(
            "INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state) VALUES('vm',?1,'s','k1','f',?2,'spawn_managed_machine',?3,'reconciliation_required')",
            params![
                missionless.sub,
                serde_json::to_string(&missionless).unwrap(),
                json!({"owner_mission_id": target}).to_string()
            ],
        )
        .unwrap();
        assert!(require_history_deletable(
            &conn,
            &missionless.sub,
            &ids,
            &std::collections::HashSet::new()
        )
        .is_err());
        conn.execute(
            "UPDATE mcp_actions_v1 SET tool='update_project_status', arguments=?1 WHERE id='vm'",
            [json!({"slug": "orb", "next_action": format!("inspect {target}")}).to_string()],
        )
        .unwrap();
        assert!(require_history_deletable(
            &conn,
            &missionless.sub,
            &ids,
            &std::collections::HashSet::new()
        )
        .is_err());
    }

    #[test]
    fn recover_reclassifies_deterministic_rejections_and_preserves_true_uncertainty() {
        let conn = Connection::open_in_memory().unwrap();
        init(&conn).unwrap();
        let p = principal();
        let p_json = serde_json::to_string(&p).unwrap();

        let insert = |id: &str, tool: &str, result: Option<Value>| {
            conn.execute(
                "INSERT INTO mcp_actions_v1(id,owner,scope,retry_key,fingerprint,principal,tool,arguments,state,result) VALUES(?1,?2,'s',?1,'f',?3,?4,'{}','reconciliation_required',?5)",
                params![
                    id,
                    p.sub,
                    p_json,
                    tool,
                    result.map(|v| v.to_string()),
                ],
            )
            .unwrap();
        };

        // 1. Crash-recovered row (`result IS NULL`) MUST stay `reconciliation_required`.
        insert("null-crash", "start_mission", None);
        // 2. Network transport failure MUST stay `reconciliation_required`.
        insert(
            "net-timeout",
            "send_message_to_mission",
            Some(json!({
                "action_id": "net-timeout",
                "state": "reconciliation_required",
                "error": {
                    "code": "execution_failed",
                    "accepted": "unknown",
                    "retryable": false,
                    "message": "Outcome unconfirmed; inspect before retrying. HTTP request failed: operation timed out"
                }
            })),
        );
        // 3. Provider 502 on VM destroy MUST stay `reconciliation_required`.
        insert(
            "destroy-502",
            "destroy_managed_machine",
            Some(json!({
                "action_id": "destroy-502",
                "state": "reconciliation_required",
                "error": {
                    "code": "execution_failed",
                    "accepted": "unknown",
                    "retryable": false,
                    "message": "Outcome unconfirmed; inspect before retrying. provider_error (502 Bad Gateway): upstream error"
                }
            })),
        );
        // 4. Deterministic 409 resume rejection MUST reclassify to `rejected` (`accepted = "no"`).
        insert(
            "resume-409",
            "resume_mission",
            Some(json!({
                "action_id": "resume-409",
                "state": "reconciliation_required",
                "error": {
                    "code": "execution_failed",
                    "accepted": "unknown",
                    "retryable": false,
                    "message": "Outcome unconfirmed; inspect before retrying. Failed to resume mission (409 Conflict): Cannot resume mission with status 'completed'."
                }
            })),
        );
        // 5. Cleaned-up `provision_failed (502)` on `spawn_managed_machine` MUST reclassify to `rejected`.
        insert(
            "spawn-prov-fail",
            "spawn_managed_machine",
            Some(json!({
                "action_id": "spawn-prov-fail",
                "state": "reconciliation_required",
                "error": {
                    "code": "execution_failed",
                    "accepted": "unknown",
                    "retryable": false,
                    "message": "Outcome unconfirmed; inspect before retrying. provision_failed (502 Bad Gateway): sandbox did not enroll within 180s"
                }
            })),
        );
        // 6. Historical `ask_mission` unavailable-workspace 500 MUST reclassify to `rejected`.
        insert(
            "ask-ws-missing",
            "ask_mission",
            Some(json!({
                "action_id": "ask-ws-missing",
                "state": "reconciliation_required",
                "error": {
                    "code": "execution_failed",
                    "accepted": "unknown",
                    "retryable": false,
                    "message": "Outcome unconfirmed; inspect before retrying. Failed to ask mission (500 Internal Server Error): mission workspace is unavailable or not prepared: /var/lib/sandboxed-sh/workspaces/missions/453427ed"
                }
            })),
        );

        recover(&conn).unwrap();

        let state_of = |id: &str| -> (String, Option<Value>) {
            let (st, res): (String, Option<String>) = conn
                .query_row(
                    "SELECT state, result FROM mcp_actions_v1 WHERE id=?1",
                    [id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .unwrap();
            (st, res.map(|s| serde_json::from_str(&s).unwrap()))
        };

        assert_eq!(state_of("null-crash").0, "reconciliation_required");
        assert_eq!(state_of("net-timeout").0, "reconciliation_required");
        assert_eq!(state_of("destroy-502").0, "reconciliation_required");

        for id in ["resume-409", "spawn-prov-fail", "ask-ws-missing"] {
            let (st, receipt) = state_of(id);
            let receipt = receipt.unwrap();
            assert_eq!(st, "rejected", "{id}: {receipt}");
            assert_eq!(receipt["state"], "rejected", "{id}");
            assert_eq!(receipt["error"]["accepted"], "no", "{id}");
            assert!(
                !receipt["error"]["message"]
                    .as_str()
                    .unwrap()
                    .starts_with("Outcome unconfirmed"),
                "{id}: {receipt}"
            );
        }
    }
}
