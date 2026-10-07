//! Native Antigravity CLI 1.2 event protocol. Shared by Core and Orb.
#[path = "antigravity_thoughts.rs"]
pub mod thoughts;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, HashSet};

/// Bound the native argv and the remote shell's worst-case quote expansion.
pub fn validate_prompt(prompt: &str) -> Result<(), String> {
    if prompt.len() > 16 * 1024 {
        Err(
            "Antigravity prompts must be at most 16 KiB; put large context in workspace files"
                .into(),
        )
    } else {
        Ok(())
    }
}

pub fn args(model: Option<&str>, session: Option<&str>, prompt: &str) -> Vec<String> {
    args_with_effort(model, None, session, prompt)
}

pub fn args_with_effort(
    model: Option<&str>,
    effort: Option<&str>,
    session: Option<&str>,
    prompt: &str,
) -> Vec<String> {
    let mut args = vec![
        "--output-format".into(),
        "stream-json".into(),
        "--dangerously-skip-permissions".into(),
    ];
    let variant_effort = model
        .and_then(|id| id.strip_prefix("agy-demo-"))
        .filter(|level| matches!(*level, "low" | "medium" | "high"));
    let model = if variant_effort.is_some() {
        Some("agy-demo")
    } else {
        model
    };
    if let Some(model) = model.filter(|s| !s.is_empty()) {
        args.extend(["--model".into(), model.into()]);
    }
    // agy-demo no longer supplies its own effort default. Preserve explicit choices.
    if let Some(effort) = effort
        .filter(|s| !s.is_empty())
        .or(variant_effort)
        .or_else(|| (model == Some("agy-demo")).then_some("high"))
    {
        args.extend(["--effort".into(), effort.into()]);
    }
    if let Some(session) = session.filter(|s| !s.is_empty()) {
        args.extend(["--conversation".into(), session.into()]);
    }
    args.extend(["-p".into(), prompt.into()]);
    args
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ErrorMarker {
    pub short_error: Option<String>,
    pub status: Option<String>,
    pub error_code: Option<i64>,
    pub code_kind: Option<String>,
    pub retryable: bool,
}

fn contains_sensitive_auth(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    lower.contains("accounts.google.com")
        || lower.contains("oauth2")
        || lower.contains("access_token")
        || lower.contains("refresh_token")
        || lower.contains("client_secret")
}

impl ErrorMarker {
    /// Parse a structured `AGY_ERROR: {...}` line from stderr without retaining
    /// OAuth URLs, tokens, or unstructured account diagnostics.
    pub fn parse(line: &str) -> Option<Self> {
        let payload = line.trim().strip_prefix("AGY_ERROR:")?.trim();
        let value: Value = serde_json::from_str(payload).ok()?;
        let obj = value.as_object()?;
        let short_error = obj
            .get("short_error")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty() && !contains_sensitive_auth(s))
            .map(str::to_owned);
        Some(Self {
            short_error,
            status: obj
                .get("status")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
            error_code: obj.get("error_code").and_then(Value::as_i64),
            code_kind: obj
                .get("code_kind")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
            retryable: obj
                .get("retryable")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        })
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct CompletedStep {
    step_type: String,
    state: String,
    text_len: usize,
}

/// Antigravity CLI 1.2.10 / 1.3.1 records `initialStepIndex` in `runTurn` before
/// `StreamConversation` has finished loading the resumed conversation's steps into memory,
/// so `initialStepIndex` is 0 and `postResponseFailure(turnSteps)` scans the entire
/// historical conversation (`steps[0..lastResponseIdx]`) for any prior `CortexStepErrorMessage`
/// (`step_type = 17`) whose `CortexErrorDetails.is_benign` (field 4) is false.
///
/// Before spawning `agy --conversation <id>`, mark existing `step_type = 17` rows in the
/// conversation SQLite DB as `is_benign = true` so historical transient errors from earlier
/// turns cannot false-fail a newly resumed turn.
pub fn clear_historical_error_steps(home: &std::path::Path, session: Option<&str>) {
    let Some(session) = session.map(str::trim).filter(|s| !s.is_empty()) else {
        return;
    };
    let db_path = home
        .join(".gemini/antigravity-cli/conversations")
        .join(format!("{session}.db"));
    if !db_path.is_file() {
        return;
    }
    let Ok(conn) = rusqlite::Connection::open(&db_path) else {
        return;
    };
    let _ = conn.busy_timeout(std::time::Duration::from_millis(500));
    let Ok(mut stmt) = conn.prepare("SELECT idx, step_payload FROM steps WHERE step_type = 17")
    else {
        return;
    };
    let Ok(rows) = stmt.query_map([], |row| {
        Ok((row.get::<_, i64>(0)?, row.get::<_, Vec<u8>>(1)?))
    }) else {
        return;
    };
    let updates: Vec<(i64, Vec<u8>)> = rows
        .flatten()
        .filter_map(|(idx, payload)| {
            mark_step_error_payload_benign(&payload).map(|updated| (idx, updated))
        })
        .collect();
    drop(stmt);
    for (idx, payload) in updates {
        let _ = conn.execute(
            "UPDATE steps SET step_payload = ?1 WHERE idx = ?2",
            rusqlite::params![payload, idx],
        );
    }
}

fn decode_varint(buf: &[u8], mut pos: usize) -> Option<(u64, usize)> {
    let mut val = 0u64;
    let mut shift = 0u32;
    while pos < buf.len() {
        let byte = buf[pos];
        pos += 1;
        val |= u64::from(byte & 0x7f).checked_shl(shift)?;
        if byte & 0x80 == 0 {
            return Some((val, pos));
        }
        shift += 7;
        if shift >= 64 {
            return None;
        }
    }
    None
}

fn encode_varint(mut val: u64, out: &mut Vec<u8>) {
    while val >= 0x80 {
        out.push((val as u8 & 0x7f) | 0x80);
        val >>= 7;
    }
    out.push(val as u8);
}

fn skip_proto_field(buf: &[u8], pos: usize, wire_type: u64) -> Option<usize> {
    match wire_type {
        0 => decode_varint(buf, pos).map(|(_, next)| next),
        1 => pos.checked_add(8).filter(|&next| next <= buf.len()),
        2 => {
            let (len, next) = decode_varint(buf, pos)?;
            next.checked_add(usize::try_from(len).ok()?)
                .filter(|&end| end <= buf.len())
        }
        5 => pos.checked_add(4).filter(|&next| next <= buf.len()),
        _ => None,
    }
}

/// Sets `CortexErrorDetails.is_benign = true` (field 4, varint 1) inside
/// `CortexStep.error_message` (field 24) -> `CortexStepErrorMessage.error` (field 3).
/// Returns `Some(updated_bytes)` only if the payload was modified.
fn mark_step_error_payload_benign(step_payload: &[u8]) -> Option<Vec<u8>> {
    let mut pos = 0;
    let mut out = Vec::with_capacity(step_payload.len() + 4);
    let mut changed = false;
    while pos < step_payload.len() {
        let start = pos;
        let (tag, next) = decode_varint(step_payload, pos)?;
        let field_num = tag >> 3;
        let wire_type = tag & 7;
        if field_num == 24 && wire_type == 2 {
            let (len, sub_start) = decode_varint(step_payload, next)?;
            let sub_end = sub_start.checked_add(usize::try_from(len).ok()?)?;
            if sub_end > step_payload.len() {
                return None;
            }
            if let Some(updated_24) = mark_error_message_benign(&step_payload[sub_start..sub_end]) {
                encode_varint((24 << 3) | 2, &mut out);
                encode_varint(updated_24.len() as u64, &mut out);
                out.extend_from_slice(&updated_24);
                changed = true;
                pos = sub_end;
                continue;
            }
            pos = sub_end;
        } else {
            pos = skip_proto_field(step_payload, next, wire_type)?;
        }
        out.extend_from_slice(&step_payload[start..pos]);
    }
    changed.then_some(out)
}

fn mark_error_message_benign(buf: &[u8]) -> Option<Vec<u8>> {
    let mut pos = 0;
    let mut out = Vec::with_capacity(buf.len() + 4);
    let mut changed = false;
    while pos < buf.len() {
        let start = pos;
        let (tag, next) = decode_varint(buf, pos)?;
        let field_num = tag >> 3;
        let wire_type = tag & 7;
        if field_num == 3 && wire_type == 2 {
            let (len, sub_start) = decode_varint(buf, next)?;
            let sub_end = sub_start.checked_add(usize::try_from(len).ok()?)?;
            if sub_end > buf.len() {
                return None;
            }
            if let Some(updated_3) = mark_error_details_benign(&buf[sub_start..sub_end]) {
                encode_varint((3 << 3) | 2, &mut out);
                encode_varint(updated_3.len() as u64, &mut out);
                out.extend_from_slice(&updated_3);
                changed = true;
                pos = sub_end;
                continue;
            }
            pos = sub_end;
        } else {
            pos = skip_proto_field(buf, next, wire_type)?;
        }
        out.extend_from_slice(&buf[start..pos]);
    }
    changed.then_some(out)
}

fn mark_error_details_benign(buf: &[u8]) -> Option<Vec<u8>> {
    let mut pos = 0;
    while pos < buf.len() {
        let (tag, next) = decode_varint(buf, pos)?;
        let field_num = tag >> 3;
        let wire_type = tag & 7;
        if field_num == 4 && wire_type == 0 {
            let (val, end) = decode_varint(buf, next)?;
            if val != 0 {
                return None;
            }
            pos = end;
        } else {
            pos = skip_proto_field(buf, next, wire_type)?;
        }
    }
    let mut out = Vec::with_capacity(buf.len() + 2);
    out.extend_from_slice(buf);
    out.extend_from_slice(&[0x20, 0x01]);
    Some(out)
}

#[derive(Debug, Default)]
pub struct Stream {
    pub turn_id: String,
    responses: BTreeMap<u64, (String, u64, bool)>,
    pub session: Option<String>,
    pub expected_session: Option<String>,
    pub text: String,
    pub error: Option<String>,
    pub error_marker: Option<ErrorMarker>,
    identity_error: bool,
    pub success: bool,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub thinking_tokens: Option<u64>,
    pub agent_response_active: bool,
    pub goal_mode: bool,
    pub goal_iterations: u32,
    pub goal_status: Option<&'static str>,
    pub reconciled_post_response_failure: bool,
    completed_steps: BTreeMap<u64, CompletedStep>,
    tools: HashSet<String>,
    active_command_steps: BTreeSet<u64>,
    pub background_tasks: BTreeMap<String, bool>,
}

fn parse_background_task_started(output: &str) -> Option<String> {
    for line in output.lines() {
        let Some(rest) = line
            .trim_start()
            .strip_prefix("Tool is running as a background task with task id:")
        else {
            continue;
        };
        let rest = rest.split("\\n").next().unwrap_or(rest).trim_start();
        let id = rest
            .split(|c: char| c.is_whitespace() || c == '"' || c == '\\')
            .next()
            .unwrap_or_default()
            .trim();
        if !id.is_empty() {
            return Some(id.to_owned());
        }
    }
    None
}

fn parse_running_task_ids_from_list(output: &str) -> Option<Vec<String>> {
    if output
        .to_ascii_lowercase()
        .contains("no background tasks are currently running")
    {
        return Some(vec![]);
    }
    let start = output.find('[')?;
    let end = output.rfind(']')?;
    if end < start {
        return None;
    }
    let items = serde_json::from_str::<Vec<Value>>(&output[start..=end]).ok()?;
    let mut ids = Vec::new();
    for item in items {
        if let Some(id) = item["taskId"].as_str().map(str::trim).filter(|s| !s.is_empty()) {
            ids.push(id.to_owned());
        }
    }
    Some(ids)
}

fn strip_task_step_index(task_id: &str) -> Option<u64> {
    let (_, step) = task_id.rsplit_once("/task-")?;
    step.parse::<u64>().ok()
}

fn strip_goal_sentinels(text: &str) -> (String, Option<&'static str>) {
    let mut status = None;
    if text.contains("<!-- GOAL_COMPLETE -->") {
        status = Some("complete");
    } else if text.contains("<!-- GOAL_CANCELLED -->") {
        status = Some("aborted:cancelled");
    }
    let cleaned = text
        .replace("<!-- GOAL_COMPLETE -->", "")
        .replace("<!-- GOAL_CANCELLED -->", "");
    (cleaned, status)
}

impl Stream {
    fn response_event(&mut self, step: u64, delta: &str, done: bool) -> Option<Value> {
        let response = self.responses.entry(step).or_default();
        if response.2 || (delta.is_empty() && (!done || response.0.is_empty())) {
            return None;
        }
        response.0.push_str(delta);
        if self.goal_mode {
            let (cleaned, status) = strip_goal_sentinels(&response.0);
            if let Some(status) = status {
                self.goal_status = Some(status);
                response.0 = cleaned.trim_end().to_owned();
            }
        }
        response.1 += 1;
        response.2 = done;
        if self.turn_id.is_empty() {
            self.turn_id = uuid::Uuid::new_v4().to_string();
        }
        let mut ops = vec![json!({"type":"snapshot","text":response.0,"revision":response.1})];
        if done {
            ops.push(json!({"type":"finalize"}));
        }
        Some(
            json!({"type":"text_op","bubble_id":format!("antigravity:{}:{}:{step}",self.session.as_deref().unwrap_or("unknown"),self.turn_id),"ops":ops}),
        )
    }

    fn close_responses(&mut self) -> Vec<Value> {
        let steps: Vec<_> = self
            .responses
            .iter()
            .filter(|(_, r)| !r.2)
            .map(|(step, _)| *step)
            .collect();
        steps
            .into_iter()
            .filter_map(|step| self.response_event(step, "", true))
            .collect()
    }

    /// Returns ordered response snapshots and tool events. Each native step is durable.
    pub fn feed(&mut self, value: &Value) -> Vec<Value> {
        let kind = value["event"].as_str().unwrap_or_default();
        let body = match kind {
            "init" => value.get("init").unwrap_or(value),
            "step_update" => &value["step_update"],
            "result" => &value["result"],
            _ => return vec![],
        };
        if kind == "init"
            && body["expanded_commands"]
                .as_array()
                .or_else(|| value["expanded_commands"].as_array())
                .is_some_and(|cmds| cmds.iter().any(|c| c["name"].as_str() == Some("goal")))
        {
            self.goal_mode = true;
            if self.goal_iterations == 0 {
                self.goal_iterations = 1;
            }
        }
        let conv_id = body["conversation_id"]
            .as_str()
            .or_else(|| value["conversation_id"].as_str())
            .filter(|s| !s.is_empty());
        if let Some(id) = conv_id {
            if self.session.as_deref().is_some_and(|old| old != id)
                || self
                    .expected_session
                    .as_deref()
                    .is_some_and(|old| old != id)
            {
                self.identity_error = true;
                self.error =
                    Some("Antigravity changed conversation identity during the turn".into());
                return vec![];
            }
            self.session = Some(id.into());
        }
        if kind == "result" {
            self.success = body["status"] == "SUCCESS";
            if self.success {
                if let Some(session) = self.session.as_deref() {
                    for &step in &self.active_command_steps {
                        self.background_tasks
                            .entry(format!("{session}/task-{step}"))
                            .or_insert(true);
                    }
                }
            } else {
                self.error = Some(
                    body["error"]
                        .as_str()
                        .filter(|s| !s.trim().is_empty())
                        .map(str::to_owned)
                        .unwrap_or_else(|| {
                            format!(
                                "Antigravity result: {}",
                                body["status"].as_str().unwrap_or("missing status")
                            )
                        }),
                );
            }
            let mut events = self.close_responses();
            if let Some(response) = body["response"].as_str().filter(|s| !s.is_empty()) {
                let (cleaned_resp, status) = if self.goal_mode {
                    let (c, s) = strip_goal_sentinels(response);
                    (c.trim_end().to_owned(), s)
                } else {
                    (response.to_owned(), None)
                };
                if let Some(status) = status {
                    self.goal_status = Some(status);
                }
                // Some CLI versions return only the final response. Never erase
                // the intermediate responses already displayed by a local client.
                if !cleaned_resp.is_empty()
                    && cleaned_resp != self.text
                    && !self.responses.values().any(|r| r.0 == cleaned_resp)
                {
                    self.text.push_str(&cleaned_resp);
                    if let Some(event) = self.response_event(u64::MAX, &cleaned_resp, true) {
                        events.push(event);
                    }
                }
            }
            if self.goal_mode {
                let (cleaned_text, status) = strip_goal_sentinels(&self.text);
                if let Some(status) = status {
                    self.goal_status = Some(status);
                    self.text = cleaned_text.trim_end().to_owned();
                }
            }
            // result.usage is lifetime cumulative on resumed conversations.
            // Count only per-step usage so follow-ups are not charged twice.
            return events;
        }
        if kind != "step_update" {
            return vec![];
        }
        let Some(step) = body["step_index"].as_u64() else {
            return vec![];
        };
        if self.completed_steps.contains_key(&step) {
            return vec![];
        }
        if matches!(body["state"].as_str(), Some("DONE" | "ERROR")) {
            self.input_tokens += body["usage"]["input_tokens"].as_u64().unwrap_or(0);
            self.output_tokens += body["usage"]["output_tokens"].as_u64().unwrap_or(0);
            if let Some(tokens) = body["usage"]["thinking_tokens"].as_u64() {
                *self.thinking_tokens.get_or_insert(0) += tokens;
            }
            self.cache_read_tokens += body["usage"]["cache_read_tokens"].as_u64().unwrap_or(0);
            if self.goal_mode && body["step_type"] == "system_message" && body["state"] == "DONE" {
                self.goal_iterations = self.goal_iterations.saturating_add(1);
            }
        }
        let mut events = vec![];
        if body["step_type"] == "agent_response" {
            self.agent_response_active = body["state"] == "ACTIVE";
            if let Some(delta) = body["text_delta"].as_str() {
                self.text.push_str(delta);
                if self.goal_mode {
                    let (cleaned_text, status) = strip_goal_sentinels(&self.text);
                    if let Some(status) = status {
                        self.goal_status = Some(status);
                        self.text = cleaned_text.trim_end().to_owned();
                    }
                }
            }
            if let Some(event) = self.response_event(
                step,
                body["text_delta"].as_str().unwrap_or_default(),
                matches!(body["state"].as_str(), Some("DONE" | "ERROR")),
            ) {
                events.push(event);
            }
        }
        if matches!(body["state"].as_str(), Some("DONE" | "ERROR")) {
            let text_len = self.responses.get(&step).map_or(0, |(t, _, _)| t.len());
            self.completed_steps.insert(
                step,
                CompletedStep {
                    step_type: body["step_type"].as_str().unwrap_or_default().to_owned(),
                    state: body["state"].as_str().unwrap_or_default().to_owned(),
                    text_len,
                },
            );
        }
        if body["step_type"] != "tool" {
            return events;
        }
        events.extend(self.close_responses());
        self.agent_response_active = false;
        let id = format!("{}:{step}", self.session.as_deref().unwrap_or("unknown"));
        let info = &body["tool_info"];
        let name = body["tool_name"]
            .as_str()
            .or_else(|| info["name"].as_str())
            .unwrap_or("tool");
        if self.tools.insert(id.clone()) {
            events.push(json!({"type":"tool_call","toolCallId":id,"name":name,"toolName":name,"rawInput":info["parameters"]}));
        }
        if name == "run_command" && body["state"] == "ACTIVE" {
            self.active_command_steps.insert(step);
        }
        if matches!(body["state"].as_str(), Some("DONE" | "ERROR")) {
            if name == "run_command" {
                self.active_command_steps.remove(&step);
            }
            if let Some(output) = info["output"].as_str() {
                if let Some(task_id) = parse_background_task_started(output) {
                    self.background_tasks.insert(task_id, true);
                } else {
                    if name == "run_command" {
                        if let Some(session) = self.session.as_deref() {
                            let task_id = format!("{session}/task-{step}");
                            if let Some(running) = self.background_tasks.get_mut(&task_id) {
                                *running = false;
                            }
                        }
                    }
                    if name == "manage_task" {
                        let action = info["parameters"]["Action"].as_str().unwrap_or_default();
                        let task_id = info["parameters"]["TaskId"]
                            .as_str()
                            .map(|s| s.trim_matches('"'));
                        let lower = output.to_ascii_lowercase();
                        if action == "kill" {
                            if let Some(task_id) = task_id {
                                self.background_tasks.insert(task_id.to_owned(), false);
                                if let Some(idx) = strip_task_step_index(task_id) {
                                    self.active_command_steps.remove(&idx);
                                }
                            }
                        } else if action == "kill_all" {
                            for running in self.background_tasks.values_mut() {
                                *running = false;
                            }
                            self.active_command_steps.clear();
                        } else if action == "list" {
                            if let Some(running_ids) = parse_running_task_ids_from_list(output) {
                                for running in self.background_tasks.values_mut() {
                                    *running = false;
                                }
                                self.active_command_steps.clear();
                                for id in running_ids {
                                    self.background_tasks.insert(id, true);
                                }
                            }
                        } else if action == "status" {
                            if lower.contains("not running")
                                || lower.contains("completed")
                                || lower.contains("finished")
                                || lower.contains("exited")
                                || lower.contains("killed")
                                || lower.contains("terminated")
                                || lower.contains("status: done")
                                || lower.contains("status: error")
                                || lower.contains("status: canceled")
                                || lower.contains("status: cancelled")
                            {
                                if let Some(task_id) = task_id {
                                    self.background_tasks.insert(task_id.to_owned(), false);
                                    if let Some(idx) = strip_task_step_index(task_id) {
                                        self.active_command_steps.remove(&idx);
                                    }
                                }
                            } else if lower.contains("status: running") {
                                if let Some(task_id) = task_id {
                                    self.background_tasks.insert(task_id.to_owned(), true);
                                }
                            }
                        }
                    }
                }
            }
            events.push(json!({"type":"tool_call_update","toolCallId":id,"name":name,"toolName":name,"status":if body["state"] == "ERROR" || !info["error"].is_null() {"failed"} else {"completed"},"output":info["output"],"rawOutput":info["output"]}));
        }
        events
    }

    pub fn observe_stderr(&mut self, line: &str) {
        if let Some(marker) = ErrorMarker::parse(line) {
            self.error_marker = Some(marker);
        }
    }

    pub fn unfinished_background_tasks(&self) -> Vec<&str> {
        self.background_tasks
            .iter()
            .filter_map(|(id, running)| (*running).then_some(id.as_str()))
            .collect()
    }

    pub fn reconcile_transcript_background_tasks(&mut self, home: &std::path::Path) {
        let Some(session) = self.session.clone() else {
            return;
        };
        self.reconcile_false_post_response_failure(home, &session);
        let path = home
            .join(".gemini/antigravity-cli/brain")
            .join(&session)
            .join(".system_generated/logs/transcript.jsonl");
        let Ok(content) = std::fs::read_to_string(path) else {
            return;
        };
        let min_turn_step = self
            .completed_steps
            .keys()
            .next()
            .copied()
            .into_iter()
            .chain(self.active_command_steps.iter().copied())
            .min();
        for line in content.lines() {
            let Ok(entry) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            let step_idx = entry["step_index"].as_u64();
            let Some(text) = entry["content"].as_str() else {
                continue;
            };
            if entry["type"] == "GENERIC"
                && entry["status"] == "RUNNING"
                && min_turn_step.is_none_or(|min_idx| step_idx.is_some_and(|idx| idx >= min_idx))
            {
                if let Some(task_id) = parse_background_task_started(text) {
                    self.background_tasks.entry(task_id).or_insert(true);
                }
            }
            for (task_id, running) in &mut self.background_tasks {
                if *running
                    && (text.contains(&format!("Task id \"{task_id}\" finished with result:"))
                        || text.contains(&format!("Task id \"{task_id}\" was canceled"))
                        || text.contains(&format!("Task id \"{task_id}\" was cancelled"))
                        || text.contains(&format!("Task id \"{task_id}\" was killed"))
                        || text.contains(&format!("Task id \"{task_id}\" was terminated"))
                        || text.contains(&format!(
                            "<background_task_notification>\nTask ID: {task_id}\n"
                        )))
                {
                    *running = false;
                }
            }
        }
    }

    /// Reconcile a false `postResponseFailure` emitted by `agy` 1.2.10 / 1.3.1 when a
    /// resumed conversation had a historical `CortexStepErrorMessage` (`step_type = 17`)
    /// from an earlier turn.
    ///
    /// In `agy`, `postResponseFailure` always appends `" (response may be truncated)"` to
    /// `result.error`. If the current turn's final step in `completed_steps` is a `DONE`
    /// `agent_response` with non-empty text, no `error_message` step occurred during this
    /// turn, and the native `transcript.jsonl` confirms that final step is `PLANNER_RESPONSE`
    /// with status `DONE` and no subsequent `ERROR_MESSAGE` step, then the turn completed
    /// cleanly and the historical error step is neutralized.
    fn reconcile_false_post_response_failure(&mut self, home: &std::path::Path, session: &str) {
        if self.reconciled_post_response_failure {
            self.error_marker = None;
            return;
        }
        if self.identity_error || self.success || self.agent_response_active {
            return;
        }
        let Some(err) = self.error.as_deref() else {
            return;
        };
        if !err.ends_with("(response may be truncated)")
            && !err.contains("There was a network issue connecting to the server")
        {
            return;
        }
        let Some((&last_step_idx, last_step)) = self.completed_steps.last_key_value() else {
            return;
        };
        if last_step.step_type != "agent_response"
            || last_step.state != "DONE"
            || last_step.text_len == 0
            || self
                .completed_steps
                .values()
                .any(|step| step.step_type == "error_message")
        {
            return;
        }
        let Some(&first_step_idx) = self.completed_steps.keys().next() else {
            return;
        };
        let path = home
            .join(".gemini/antigravity-cli/brain")
            .join(session)
            .join(".system_generated/logs/transcript.jsonl");
        let Ok(content) = std::fs::read_to_string(path) else {
            return;
        };
        let mut last_step_confirmed_done = false;
        for line in content.lines() {
            let Ok(entry) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            let Some(idx) = entry["step_index"].as_u64() else {
                continue;
            };
            if idx < first_step_idx {
                continue;
            };
            if entry["type"] == "ERROR_MESSAGE" || idx > last_step_idx {
                return;
            }
            if idx == last_step_idx {
                last_step_confirmed_done =
                    entry["type"] == "PLANNER_RESPONSE" && entry["status"] == "DONE";
            }
        }
        if last_step_confirmed_done {
            self.reconciled_post_response_failure = true;
            self.success = true;
            self.error = None;
            self.error_marker = None;
            clear_historical_error_steps(home, Some(session));
        }
    }

    pub fn is_retryable(&self) -> bool {
        !self.identity_error
            && !self.success
            && self.session.is_some()
            && self
                .error_marker
                .as_ref()
                .is_some_and(|marker| marker.retryable)
    }

    /// The terminal receipt repeats only the last response, not every update.
    pub fn summary(&self) -> String {
        self.responses
            .values()
            .rev()
            .find(|r| !r.0.is_empty())
            .map(|r| r.0.clone())
            .unwrap_or_else(|| self.text.clone())
    }

    pub fn finish(&self) -> Result<(), String> {
        let marker_error = if self.identity_error {
            None
        } else {
            self.error_marker
                .as_ref()
                .and_then(|marker| marker.short_error.as_deref())
        };
        if let Some(error) = &self.error {
            if error.starts_with("Antigravity result:") {
                if let Some(short) = marker_error {
                    return Err(short.to_owned());
                }
            } else if let Some(short) = marker_error.filter(|short| !error.contains(*short)) {
                return Err(format!("{error} ({short})"));
            }
            return Err(error.clone());
        }
        if self.session.is_none() {
            if let Some(short) = marker_error {
                return Err(short.to_owned());
            }
            return Err("Antigravity did not report a conversation ID".into());
        }
        if !self.success {
            if let Some(short) = marker_error {
                return Err(short.to_owned());
            }
            return Err("Antigravity ended without a SUCCESS result; resume this conversation before retrying work".into());
        }
        let unfinished = self.unfinished_background_tasks();
        if !unfinished.is_empty() {
            return Err(format!(
                "Antigravity ended its headless turn while background task(s) {} were still running; resume this conversation to inspect task logs or re-run foreground commands",
                unfinished.join(", ")
            ));
        }
        Ok(())
    }
}

/// Authenticated native discovery, bounded and without retaining stderr (OAuth URLs).
pub fn models(binary: &std::path::Path) -> Result<Vec<(String, String)>, String> {
    models_in_home(binary, None)
}

pub fn models_in_home(
    binary: &std::path::Path,
    home: Option<&std::path::Path>,
) -> Result<Vec<(String, String)>, String> {
    use std::process::{Command, Stdio};
    let mut command = Command::new(binary);
    if let Some(home) = home {
        command.env("HOME", home);
    }
    let mut child = command
        .arg("models")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "Antigravity CLI is not installed")?;
    let stdout = child.stdout.take().ok_or("Cannot read model discovery")?;
    let reader = std::thread::spawn(move || {
        use std::io::Read;
        let mut text = String::new();
        stdout
            .take(1024 * 1024)
            .read_to_string(&mut text)
            .map(|_| text)
    });
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(Some(_)) => return Err("Sign in with agy as this machine's execution user".into()),
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("Antigravity model discovery failed".into());
            }
            _ if std::time::Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("Antigravity model discovery timed out; check sign-in".into());
            }
            _ => std::thread::sleep(std::time::Duration::from_millis(50)),
        }
    }
    let text = reader
        .join()
        .map_err(|_| "Model discovery reader failed")?
        .map_err(|_| "Cannot read models")?;
    let models = group_models(
        text.lines()
            .filter_map(|line| line.split_once('\t'))
            .filter(|(id, label)| !id.is_empty() && !label.is_empty())
            .map(|(id, label)| (id.to_string(), label.to_string()))
            .collect(),
    );
    if models.is_empty() {
        return Err("No Antigravity models are available for this account".into());
    }
    Ok(models)
}

/// Argon's discovered variants are one model with a separate effort control.
pub fn group_models(models: Vec<(String, String)>) -> Vec<(String, String)> {
    let mut seen = HashSet::new();
    models
        .into_iter()
        .filter_map(|(id, label)| {
            let variant = id
                .strip_prefix("agy-demo-")
                .filter(|level| matches!(*level, "low" | "medium" | "high"));
            let (id, label) = if let Some(level) = variant {
                let suffix = format!(
                    " ({})",
                    match level {
                        "low" => "Low",
                        "medium" => "Medium",
                        _ => "High",
                    }
                );
                (
                    "agy-demo".to_string(),
                    label.strip_suffix(&suffix).unwrap_or(&label).to_string(),
                )
            } else {
                (id, label)
            };
            seen.insert(id.clone()).then_some((id, label))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn responses_have_stable_step_ids_and_survive_tool_boundaries_and_short_final_receipts() {
        let mut stream = Stream::default();
        stream.turn_id = "turn".into();
        stream.feed(&json!({"event":"init","conversation_id":"session"}));
        let first = stream.feed(&json!({"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"First 🦀"}}));
        assert_eq!(first[0]["bubble_id"], "antigravity:session:turn:1");
        assert_eq!(first[0]["ops"][0]["revision"], 1);
        let boundary = stream.feed(&json!({"event":"step_update","step_update":{"step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"bash"}}));
        assert_eq!(boundary[0]["bubble_id"], first[0]["bubble_id"]);
        assert_eq!(boundary[0]["ops"][0]["revision"], 2);
        assert_eq!(boundary[0]["ops"][1]["type"], "finalize");
        assert_eq!(boundary[1]["type"], "tool_call");
        let second = stream.feed(&json!({"event":"step_update","step_update":{"step_index":3,"state":"DONE","step_type":"agent_response","text_delta":"Second"}}));
        assert_ne!(second[0]["bubble_id"], first[0]["bubble_id"]);
        let final_event = stream
            .feed(&json!({"event":"result","result":{"status":"SUCCESS","response":"Second"}}));
        assert!(final_event.is_empty());
        assert_eq!(stream.text, "First 🦀Second");
        assert_eq!(stream.summary(), "Second");
        assert!(stream.finish().is_ok());
    }

    #[test]
    fn argon_variants_are_one_model_and_explicit_effort_overrides_old_variant() {
        let models = group_models(vec![
            ("agy-demo-medium".into(), "Gemini 4 Argon (Medium)".into()),
            ("agy-demo-high".into(), "Gemini 4 Argon (High)".into()),
            ("agy-demo-low".into(), "Gemini 4 Argon (Low)".into()),
            ("other".into(), "Other".into()),
        ]);
        assert_eq!(
            models,
            vec![
                ("agy-demo".into(), "Gemini 4 Argon".into()),
                ("other".into(), "Other".into())
            ]
        );
        let args = args_with_effort(
            Some("agy-demo-medium"),
            Some("high"),
            Some("same-session"),
            "continue",
        );
        assert!(args.windows(2).any(|v| v == ["--model", "agy-demo"]));
        assert!(args.windows(2).any(|v| v == ["--effort", "high"]));
        let args = args_with_effort(Some("agy-demo-low"), None, None, "continue");
        assert!(args.windows(2).any(|v| v == ["--effort", "low"]));
    }
    #[test]
    fn thinking_usage_is_per_turn_and_duplicate_steps_are_idempotent() {
        let mut s = Stream::default();
        assert_eq!(s.thinking_tokens, None);
        let active = json!({"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"agent_response"}});
        s.feed(&active);
        assert!(s.agent_response_active);
        let done = json!({"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","usage":{"thinking_tokens":42}}});
        s.feed(&done);
        s.feed(&done);
        assert!(!s.agent_response_active);
        assert_eq!(s.thinking_tokens, Some(42));
        s.feed(&json!({"event":"result","result":{"status":"SUCCESS","usage":{"thinking_tokens":9999}}}));
        assert_eq!(s.thinking_tokens, Some(42));
        assert!(s.text.is_empty());
    }
    #[test]
    fn real_argon_turn_has_tools_usage_and_an_explicit_result() {
        let mut stream = Stream::default();
        let mut tools = 0;
        let mut failed_tools = 0;
        for line in include_str!("../tests/fixtures/antigravity_turn.jsonl").lines() {
            let events = stream.feed(&serde_json::from_str(line).unwrap());
            failed_tools += events
                .iter()
                .filter(|event| event["status"] == "failed")
                .count();
            tools += events.len();
        }
        assert!(stream.finish().is_ok());
        assert!(tools >= 4);
        assert_eq!(failed_tools, 1);
        assert!(stream.input_tokens > 0);
        assert_eq!(stream.cache_read_tokens, 40593);
        assert!(stream.text.contains("node --test"));
    }
    #[test]
    fn delta_result_and_usage_do_not_duplicate() {
        let mut s = Stream::default();
        s.feed(&json!({"event":"init","conversation_id":"one"}));
        s.feed(&json!({"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"hello"}}));
        let done = json!({"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"!","usage":{"input_tokens":10,"output_tokens":2}}});
        s.feed(&done);
        s.feed(&done);
        s.feed(&json!({"event":"result","result":{"status":"SUCCESS","response":"hello!","usage":{"input_tokens":999}}}));
        assert_eq!(s.text, "hello!");
        assert_eq!(s.input_tokens, 10);
        assert!(s.finish().is_ok());
    }
    #[test]
    fn missing_terminal_and_changed_identity_fail_closed() {
        let mut s = Stream::default();
        s.feed(&json!({"event":"init","conversation_id":"one"}));
        assert!(s.finish().is_err());
        s.feed(&json!({"event":"result","result":{"conversation_id":"two","status":"SUCCESS"}}));
        assert!(s.finish().is_err());
    }
    #[test]
    fn resume_requires_reported_matching_identity() {
        let mut s = Stream {
            expected_session: Some("expected".into()),
            ..Default::default()
        };
        s.feed(&json!({"event":"result","result":{"status":"SUCCESS"}}));
        assert!(s.finish().is_err());
        s.feed(&json!({"event":"init","conversation_id":"different"}));
        assert!(s.finish().is_err());
        let mut s = Stream {
            expected_session: Some("expected".into()),
            ..Default::default()
        };
        s.feed(
            &json!({"event":"result","result":{"conversation_id":"expected","status":"SUCCESS"}}),
        );
        assert!(s.finish().is_ok());
    }
    #[test]
    fn rejects_oversized_prompt_before_native_launch() {
        assert!(validate_prompt(&"a".repeat(16 * 1024)).is_ok());
        assert!(validate_prompt(&"'".repeat(16 * 1024 + 1)).is_err());
        assert!(validate_prompt(&"é".repeat(16 * 1024)).is_err());
    }
    #[test]
    fn resumes_exact_session_and_keeps_prompt_one_argument() {
        let a = args(Some("agy-demo"), Some("abc"), "$(false)\nhello");
        assert!(a.windows(2).any(|p| p == ["--conversation", "abc"]));
        assert_eq!(a.last().unwrap(), "$(false)\nhello");
        assert!(!a.contains(&"--continue".into()));
    }
    #[test]
    fn effort_default_and_explicit_choices_preserve_conversation() {
        for effort in [None, Some("low"), Some("medium"), Some("high")] {
            let args = args_with_effort(Some("agy-demo"), effort, Some("existing"), "resume");
            assert!(args
                .windows(2)
                .any(|p| p == ["--effort", effort.unwrap_or("high")]));
            assert!(args.windows(2).any(|p| p == ["--conversation", "existing"]));
        }
        assert!(!args(None, None, "hello").contains(&"--effort".into()));
    }

    #[test]
    fn native_startup_error_is_preserved_without_conversation_id() {
        let mut stream = Stream::default();
        let error = "invalid model selection: agy-demo requires --effort";
        stream.feed(&json!({"event":"result","result":{"conversation_id":"","status":"ERROR","error":error}}));
        assert_eq!(stream.finish().unwrap_err(), error);
        assert!(stream.session.is_none());
    }

    #[test]
    fn stderr_error_marker_enriches_friendly_error_and_marks_bound_session_retryable() {
        let mut stream = Stream::default();
        stream.feed(
            &json!({"event":"init","conversation_id":"ddd67091-4a2f-4fba-b905-7a8144dee4eb"}),
        );
        stream.observe_stderr("non-marker line https://accounts.google.com/o/oauth2/auth?secret=1");
        assert!(stream.error_marker.is_none());
        stream.observe_stderr(
            r#"AGY_ERROR: {"short_error":"agent executor error: generating and executing: request failed: Post \"https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse\": read tcp [2a01:14:8010:4250:115a:9d6:a0ad:1246]:57897->[2001:4860:4841:400::]:443: read: no route to host","status":"UNKNOWN","error_code":2,"code_kind":"grpc","retryable":true,"error_id":"err-1"}"#,
        );
        stream.feed(&json!({
            "event":"result",
            "result":{
                "conversation_id":"ddd67091-4a2f-4fba-b905-7a8144dee4eb",
                "status":"ERROR",
                "error":"There was a network issue connecting to the server, please try again. (response may be truncated)"
            }
        }));
        assert!(stream.is_retryable());
        let err = stream.finish().unwrap_err();
        assert!(
            err.contains("There was a network issue connecting to the server, please try again.")
        );
        assert!(err.contains("read: no route to host"));
    }

    #[test]
    fn stderr_error_marker_redacts_oauth_and_never_marks_unbound_or_changed_identity_retryable() {
        let marker = ErrorMarker::parse(
            r#"AGY_ERROR: {"short_error":"visit https://accounts.google.com/o/oauth2/v2/auth","status":"UNAUTHENTICATED","retryable":true}"#,
        )
        .unwrap();
        assert!(marker.short_error.is_none());
        let mut unbound = Stream::default();
        unbound.observe_stderr(
            r#"AGY_ERROR: {"short_error":"API error (attempt 1): UNAVAILABLE (code 503): The service is currently unavailable.","status":"UNAVAILABLE","error_code":14,"code_kind":"grpc","retryable":true}"#,
        );
        assert!(!unbound.is_retryable());
        assert_eq!(
            unbound.finish().unwrap_err(),
            "API error (attempt 1): UNAVAILABLE (code 503): The service is currently unavailable."
        );
        let mut mismatch = Stream {
            expected_session: Some("expected".into()),
            ..Default::default()
        };
        mismatch.observe_stderr(
            r#"AGY_ERROR: {"short_error":"read: no route to host","retryable":true}"#,
        );
        mismatch.feed(&json!({"event":"init","conversation_id":"wrong"}));
        assert!(!mismatch.is_retryable());
        assert_eq!(
            mismatch.finish().unwrap_err(),
            "Antigravity changed conversation identity during the turn"
        );
    }

    #[test]
    fn unfinished_background_task_fails_finish_until_killed_or_completed_in_transcript() {
        let mut stream = Stream::default();
        let session = "54998702-4037-4d0c-9514-b32d90d6465c";
        let task_id = format!("{session}/task-988");
        stream.feed(&json!({"event":"init","conversation_id":session}));
        stream.feed(&json!({
            "event":"step_update",
            "step_update":{
                "conversation_id":session,
                "step_index":988,
                "state":"DONE",
                "step_type":"tool",
                "tool_name":"run_command",
                "tool_info":{
                    "name":"run_command",
                    "parameters":{"CommandLine":"pytest -q"},
                    "output":format!("Created At: 2026-10-06T18:36:14Z\nTool is running as a background task with task id: {task_id}\nTask logs are available at: file:///root/.gemini/antigravity-cli/brain/{session}/.system_generated/tasks/task-988.log")
                }
            }
        }));
        stream.feed(&json!({
            "event":"step_update",
            "step_update":{
                "conversation_id":session,
                "step_index":989,
                "state":"DONE",
                "step_type":"agent_response",
                "text_delta":"Running full test suite (`task-988`); waiting for completion."
            }
        }));
        stream.feed(&json!({
            "event":"result",
            "result":{
                "conversation_id":session,
                "status":"SUCCESS",
                "response":"Running full test suite (`task-988`); waiting for completion."
            }
        }));
        let err = stream.finish().unwrap_err();
        assert!(err.contains(&task_id));
        assert!(err.contains("background task(s)"));

        // Reconciling against a transcript where the task finished clears the pending state.
        let home = tempfile::tempdir().unwrap();
        let logs_dir = home
            .path()
            .join(".gemini/antigravity-cli/brain")
            .join(session)
            .join(".system_generated/logs");
        std::fs::create_dir_all(&logs_dir).unwrap();
        std::fs::write(
            logs_dir.join("transcript.jsonl"),
            serde_json::to_string(&json!({
                "step_index": 990,
                "source": "SYSTEM",
                "type": "SYSTEM_MESSAGE",
                "status": "DONE",
                "content": format!("<SYSTEM_MESSAGE>\nTask id \"{task_id}\" finished with result:\n\nThe command exited with code 0.\n</SYSTEM_MESSAGE>")
            }))
            .unwrap()
                + "\n",
        )
        .unwrap();
        stream.reconcile_transcript_background_tasks(home.path());
        assert!(stream.finish().is_ok());
    }

    #[test]
    fn native_goal_tracks_iterations_and_strips_completion_sentinels() {
        let mut stream = Stream::default();
        stream.feed(&json!({
            "event": "init",
            "init": {
                "conversation_id": "goal-session",
                "expanded_commands": [{"name": "goal", "type": "system"}]
            }
        }));
        assert!(stream.goal_mode);
        assert_eq!(stream.goal_iterations, 1);
        stream.feed(&json!({
            "event": "step_update",
            "step_update": {
                "conversation_id": "goal-session",
                "step_index": 2,
                "state": "DONE",
                "step_type": "agent_response",
                "text_delta": "Working on step 1."
            }
        }));
        stream.feed(&json!({
            "event": "step_update",
            "step_update": {
                "conversation_id": "goal-session",
                "step_index": 3,
                "state": "DONE",
                "step_type": "system_message",
                "text_delta": "Stop hook: verify before completing."
            }
        }));
        assert_eq!(stream.goal_iterations, 2);
        stream.feed(&json!({
            "event": "step_update",
            "step_update": {
                "conversation_id": "goal-session",
                "step_index": 5,
                "state": "DONE",
                "step_type": "agent_response",
                "text_delta": "Verified!\n<!-- GOAL_COMPLETE -->"
            }
        }));
        stream.feed(&json!({
            "event": "result",
            "result": {
                "conversation_id": "goal-session",
                "status": "SUCCESS",
                "response": "Verified!\n<!-- GOAL_COMPLETE -->"
            }
        }));
        assert_eq!(stream.goal_status, Some("complete"));
        assert_eq!(stream.summary(), "Verified!");
        assert!(!stream.text.contains("GOAL_COMPLETE"));
        assert!(stream.finish().is_ok());
    }

    #[test]
    fn clear_historical_error_steps_marks_cortex_error_details_benign_idempotently() {
        let home = tempfile::tempdir().unwrap();
        let session = "ddd67091-4a2f-4fba-b905-7a8144dee4eb";
        let conv_dir = home.path().join(".gemini/antigravity-cli/conversations");
        std::fs::create_dir_all(&conv_dir).unwrap();
        let db_path = conv_dir.join(format!("{session}.db"));
        let conn = rusqlite::Connection::open(&db_path).unwrap();
        conn.execute(
            "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER NOT NULL, step_payload BLOB NOT NULL)",
            [],
        )
        .unwrap();
        // Minimal CortexStep protobuf with field 1 = 17, field 4 = 7, and field 24 (CortexStepErrorMessage)
        // containing field 3 (CortexErrorDetails) with field 1 ("err") and field 6 (retryable = 1).
        let error_details = b"\x0a\x03err\x30\x01";
        let mut error_msg = Vec::new();
        error_msg.push(0x1a);
        error_msg.push(error_details.len() as u8);
        error_msg.extend_from_slice(error_details);
        let mut step_payload = vec![0x08, 0x11, 0x20, 0x07, 0xc2, 0x01, error_msg.len() as u8];
        step_payload.extend_from_slice(&error_msg);
        conn.execute(
            "INSERT INTO steps (idx, step_type, step_payload) VALUES (1081, 17, ?1)",
            [&step_payload],
        )
        .unwrap();
        drop(conn);

        clear_historical_error_steps(home.path(), Some(session));
        let conn = rusqlite::Connection::open(&db_path).unwrap();
        let updated: Vec<u8> = conn
            .query_row(
                "SELECT step_payload FROM steps WHERE idx = 1081",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(updated.len(), step_payload.len() + 2);
        assert!(updated.ends_with(&[0x20, 0x01]));
        assert!(mark_step_error_payload_benign(&updated).is_none());
    }

    #[test]
    fn reconciles_false_post_response_failure_from_historical_error_step_but_keeps_live_turn_error()
    {
        let home = tempfile::tempdir().unwrap();
        let session = "ddd67091-4a2f-4fba-b905-7a8144dee4eb";
        let logs_dir = home
            .path()
            .join(".gemini/antigravity-cli/brain")
            .join(session)
            .join(".system_generated/logs");
        std::fs::create_dir_all(&logs_dir).unwrap();
        std::fs::write(
            logs_dir.join("transcript.jsonl"),
            [
                json!({
                    "step_index": 1081,
                    "source": "CORTEX_STEP_SOURCE_SYSTEM",
                    "type": "ERROR_MESSAGE",
                    "status": "ERROR"
                }),
                json!({
                    "step_index": 2540,
                    "source": "CORTEX_STEP_SOURCE_USER_EXPLICIT",
                    "type": "USER_INPUT",
                    "status": "DONE",
                    "content": "Check status"
                }),
                json!({
                    "step_index": 2542,
                    "source": "CORTEX_STEP_SOURCE_MODEL",
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "content": "Tout est déjà terminé, signé et poussé."
                }),
            ]
            .iter()
            .map(|v| serde_json::to_string(v).unwrap())
            .collect::<Vec<_>>()
            .join("\n")
                + "\n",
        )
        .unwrap();

        let mut stream = Stream::default();
        stream.feed(&json!({"event":"init","conversation_id":session}));
        stream.feed(&json!({
            "event":"step_update",
            "step_update":{
                "conversation_id":session,
                "step_index":2542,
                "state":"DONE",
                "step_type":"agent_response",
                "text_delta":"Tout est déjà terminé, signé et poussé."
            }
        }));
        stream.feed(&json!({
            "event":"result",
            "result":{
                "conversation_id":session,
                "status":"ERROR",
                "error":"There was a network issue connecting to the server, please try again. (response may be truncated)"
            }
        }));
        stream.reconcile_transcript_background_tasks(home.path());
        stream.observe_stderr(
            r#"AGY_ERROR: {"short_error":"read: no route to host","status":"UNKNOWN","retryable":true}"#,
        );
        stream.reconcile_transcript_background_tasks(home.path());
        assert!(stream.reconciled_post_response_failure);
        assert!(stream.finish().is_ok());
        assert!(!stream.is_retryable());
        assert_eq!(stream.summary(), "Tout est déjà terminé, signé et poussé.");

        // Also reconciles when agy emits the bare network issue error without "(response may be truncated)".
        let mut bare_stream = Stream::default();
        bare_stream.feed(&json!({"event":"init","conversation_id":session}));
        bare_stream.feed(&json!({
            "event":"step_update",
            "step_update":{
                "conversation_id":session,
                "step_index":2542,
                "state":"DONE",
                "step_type":"agent_response",
                "text_delta":"Tout est déjà terminé, signé et poussé."
            }
        }));
        bare_stream.feed(&json!({
            "event":"result",
            "result":{
                "conversation_id":session,
                "status":"ERROR",
                "error":"There was a network issue connecting to the server, please try again."
            }
        }));
        bare_stream.reconcile_transcript_background_tasks(home.path());
        assert!(bare_stream.reconciled_post_response_failure);
        assert!(bare_stream.finish().is_ok());

        // If an ERROR_MESSAGE actually occurred during the current turn, do not reconcile.
        std::fs::write(
            logs_dir.join("transcript.jsonl"),
            [
                json!({
                    "step_index": 2542,
                    "source": "CORTEX_STEP_SOURCE_MODEL",
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "content": "Partial answer"
                }),
                json!({
                    "step_index": 2543,
                    "source": "CORTEX_STEP_SOURCE_SYSTEM",
                    "type": "ERROR_MESSAGE",
                    "status": "ERROR"
                }),
            ]
            .iter()
            .map(|v| serde_json::to_string(v).unwrap())
            .collect::<Vec<_>>()
            .join("\n")
                + "\n",
        )
        .unwrap();
        let mut live_err = Stream::default();
        live_err.feed(&json!({"event":"init","conversation_id":session}));
        live_err.feed(&json!({
            "event":"step_update",
            "step_update":{
                "conversation_id":session,
                "step_index":2542,
                "state":"DONE",
                "step_type":"agent_response",
                "text_delta":"Partial answer"
            }
        }));
        live_err.observe_stderr(
            r#"AGY_ERROR: {"short_error":"read: no route to host","status":"UNKNOWN","retryable":true}"#,
        );
        live_err.feed(&json!({
            "event":"result",
            "result":{
                "conversation_id":session,
                "status":"ERROR",
                "error":"There was a network issue connecting to the server, please try again. (response may be truncated)"
            }
        }));
        live_err.reconcile_transcript_background_tasks(home.path());
        assert!(!live_err.reconciled_post_response_failure);
        assert!(live_err.finish().is_err());
        assert!(live_err.is_retryable());
    }

    #[test]
    fn tracks_active_background_run_command_and_manage_task_list_and_status() {
        let session = "869fd922-78ac-4a06-8994-2bda1baed391";
        let task_id = format!("{session}/task-2065");
        let mut stream = Stream::default();
        stream.feed(&json!({"event":"init","conversation_id":session}));

        // Tailing a historical transcript.jsonl line must not register a bogus background task.
        stream.feed(&json!({
            "event":"step_update",
            "step_update":{
                "conversation_id":session,
                "step_index":2060,
                "state":"DONE",
                "step_type":"tool",
                "tool_name":"run_command",
                "tool_info":{
                    "name":"run_command",
                    "parameters":{"CommandLine":"tail -n 30 transcript.jsonl"},
                    "output":r#"{"step_index":587,"content":"Tool is running as a background task with task id: 92989fb6-86ef-4642-81c9-0eb8060354f2/task-587\nCommand: lake build"}"#
                }
            }
        }));
        assert!(stream.unfinished_background_tasks().is_empty());

        // In stream-json, a backgrounded run_command emits state: "ACTIVE" and stays active
        // while the agent inspects it via manage_task(list/status) and waits for wakeup.
        stream.feed(&json!({
            "event":"step_update",
            "step_update":{
                "conversation_id":session,
                "step_index":2065,
                "state":"ACTIVE",
                "step_type":"tool",
                "tool_name":"run_command",
                "tool_info":{
                    "name":"run_command",
                    "parameters":{"CommandLine":"lake build","WaitMsBeforeAsync":10000}
                }
            }
        }));
        stream.feed(&json!({
            "event":"step_update",
            "step_update":{
                "conversation_id":session,
                "step_index":2067,
                "state":"DONE",
                "step_type":"tool",
                "tool_name":"manage_task",
                "tool_info":{
                    "name":"manage_task",
                    "parameters":{"Action":"list"},
                    "output":format!("Currently running background tasks (1):\n[\n  {{\n    \"taskId\": \"{task_id}\",\n    \"title\": \"Running InvStop Lean build\"\n  }}\n]")
                }
            }
        }));
        stream.feed(&json!({
            "event":"step_update",
            "step_update":{
                "conversation_id":session,
                "step_index":2069,
                "state":"DONE",
                "step_type":"tool",
                "tool_name":"manage_task",
                "tool_info":{
                    "name":"manage_task",
                    "parameters":{"Action":"status","TaskId":&task_id},
                    "output":format!("Task ID: {task_id}\nStatus: RUNNING\nLog URI: file:///tmp/task-2065.log")
                }
            }
        }));
        stream.feed(&json!({
            "event":"step_update",
            "step_update":{
                "conversation_id":session,
                "step_index":2072,
                "state":"DONE",
                "step_type":"agent_response",
                "text_delta":"I will wait for the background build task to notify me when it finishes.\n\n"
            }
        }));
        stream.feed(&json!({
            "event":"result",
            "result":{
                "conversation_id":session,
                "status":"SUCCESS",
                "response":"I will wait for the background build task to notify me when it finishes.\n\n"
            }
        }));
        let err = stream.finish().unwrap_err();
        assert!(err.contains(&task_id), "unexpected err: {err}");
        assert!(err.contains("while background task(s)"));

        // If manage_task(list) later confirms no tasks are running, finish() succeeds.
        stream.feed(&json!({
            "event":"step_update",
            "step_update":{
                "conversation_id":session,
                "step_index":2073,
                "state":"DONE",
                "step_type":"tool",
                "tool_name":"manage_task",
                "tool_info":{
                    "name":"manage_task",
                    "parameters":{"Action":"list"},
                    "output":"No background tasks are currently running."
                }
            }
        }));
        assert!(stream.finish().is_ok());
    }
}
