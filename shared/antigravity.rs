//! Native Antigravity CLI 1.2 event protocol. Shared by Core and Orb.
#[path = "antigravity_thoughts.rs"]
pub mod thoughts;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, HashSet};

/// Bound the native argv (`MAX_ARG_STRLEN` is 128 KiB on Linux).
pub const MAX_PROMPT_BYTES: usize = 64 * 1024;

pub fn validate_prompt(prompt: &str) -> Result<(), String> {
    if prompt.len() > MAX_PROMPT_BYTES {
        Err(
            "Antigravity prompts must be at most 64 KiB; put large context in workspace files"
                .into(),
        )
    } else {
        Ok(())
    }
}

pub fn args(model: Option<&str>, session: Option<&str>, prompt: &str) -> Vec<String> {
    args_with_effort(model, None, session, prompt)
}

pub fn normalize_model_and_effort<'a>(
    model: Option<&'a str>,
    effort: Option<&'a str>,
) -> (Option<&'a str>, Option<&'a str>) {
    let raw = model
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.strip_prefix("antigravity/").unwrap_or(s));
    let explicit_effort = effort.map(str::trim).filter(|s| !s.is_empty());
    let (normalized_model, variant_effort, requires_default_high) = match raw {
        Some("agy-model" | "gemini-4-carbon" | "gemini-4-carbon-eap") => {
            (Some("agy-model"), None, true)
        }
        Some(id)
            if id
                .strip_prefix("agy-model-")
                .or_else(|| id.strip_prefix("gemini-4-carbon-"))
                .is_some_and(|level| matches!(level, "low" | "medium" | "high")) =>
        {
            let level = id
                .strip_prefix("agy-model-")
                .or_else(|| id.strip_prefix("gemini-4-carbon-"));
            (Some("agy-model"), level, true)
        }
        Some("agy-demo") => (Some("agy-demo"), None, true),
        Some(id)
            if id
                .strip_prefix("agy-demo-")
                .is_some_and(|level| matches!(level, "low" | "medium" | "high")) =>
        {
            (Some("agy-demo"), id.strip_prefix("agy-demo-"), true)
        }
        other => (other, None, false),
    };
    let effective_effort = explicit_effort
        .or(variant_effort)
        .or_else(|| requires_default_high.then_some("high"));
    (normalized_model, effective_effort)
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
    let (model, effort) = normalize_model_and_effort(model, effort);
    match model {
        // Native `agy` CLI exposes Gemini 4 Carbon exclusively as effort-baked
        // model IDs (`agy-model-low`, `agy-model-medium`, `agy-model-high`) and
        // rejects `--model agy-model --effort <level>` with:
        //   `--effort is not supported for model "agy-model"`.
        Some("agy-model") => {
            let cli_model = match effort {
                Some("low") => "agy-model-low",
                Some("medium") => "agy-model-medium",
                _ => "agy-model-high",
            };
            args.extend(["--model".into(), cli_model.into()]);
        }
        Some(model) => {
            args.extend(["--model".into(), model.into()]);
            if let Some(effort) = effort {
                args.extend(["--effort".into(), effort.into()]);
            }
        }
        None => {
            if let Some(effort) = effort {
                args.extend(["--effort".into(), effort.into()]);
            }
        }
    }
    if let Some(session) = session.filter(|s| !s.is_empty()) {
        args.extend(["--conversation".into(), session.into()]);
    }
    // `/plan …` (first turn or a follow-up) runs agy's native plan mode on the request body.
    let prompt = match plan_request(prompt) {
        Some(body) => {
            args.extend(["--mode".into(), "plan".into()]);
            body
        }
        None => prompt,
    };
    args.extend(["-p".into(), prompt.into()]);
    args
}

/// The request body of a `/plan` message, or None for an ordinary message.
pub fn plan_request(prompt: &str) -> Option<&str> {
    let rest = prompt.trim_start().strip_prefix("/plan")?;
    if !rest.is_empty() && !rest.starts_with(char::is_whitespace) {
        return None;
    }
    let body = rest.trim_start();
    Some(if body.is_empty() {
        "Review the conversation and workspace, then propose an implementation plan before making changes."
    } else {
        body
    })
}

/// Provider failures that can be continued in the same native conversation.
/// Kept here so local and remote observers do not kill the CLI's own retries.
pub fn is_transient_error(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    if [
        "unauthenticated",
        "permission_denied",
        "invalid_grant",
        "sign in",
        "log in",
        "oauth",
        "cancelled by",
        "canceled by",
    ]
    .iter()
    .any(|s| lower.contains(s))
    {
        return false;
    }
    [
        "unavailable (code 503)",
        "internal (code 500)",
        "internal error encountered",
        "deadline_exceeded (code 504)",
        "the stream was interrupted",
        "there was a network issue connecting to the server",
        "previous response was cut off because it exceeded the output token limit",
        "resource_exhausted",
        "too many requests",
        "no route to host",
        "connection reset by peer",
        "connection refused",
        "i/o timeout",
        "tls handshake timeout",
        "unexpected eof",
        "malformed function call",
        "api error (attempt ",
        "response may be truncated",
        IDLE_WAIT_INTERRUPTED_MARKER,
    ]
    .iter()
    .any(|s| lower.contains(s))
}

/// Lower-case marker of [`idle_wait_interrupted_message`]; recovery matches on it.
pub const IDLE_WAIT_INTERRUPTED_MARKER: &str =
    "interrupted while its root agent was idle waiting for background task(s)";

/// The terminal error of a turn that `agy` cut while its root agent waited for
/// subagents/background tasks. This is a normal end of turn, never a provider failure.
pub fn idle_wait_interrupted_message(tasks: u32) -> String {
    format!(
        "Antigravity was {IDLE_WAIT_INTERRUPTED_MARKER} ({tasks} still running); resume this conversation to check them"
    )
}

/// Parse `diagnostics: root agent idle; waiting up to 30m0s for 1 background task(s)`.
fn parse_idle_wait_diagnostic(line: &str) -> Option<u32> {
    let rest = line.split_once("root agent idle; waiting up to ")?.1;
    let count = rest.split_once(" for ")?.1;
    let (count, tail) = count.trim_start().split_once(' ')?;
    tail.starts_with("background task")
        .then(|| count.parse().ok())
        .flatten()
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

/// Clear historical `step_type = 17` error rows across all conversation DBs in `home`.
/// Used on remote nodes before spawning a raw `agy` command where the resumed
/// conversation ID is embedded in the command string.
pub fn clear_all_historical_error_steps(home: &std::path::Path) {
    let dir = home.join(".gemini/antigravity-cli/conversations");
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) == Some("db") {
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                clear_historical_error_steps(home, Some(stem));
            }
        }
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

/// Minimum time between two snapshots of the same streamed response.
const SNAPSHOT_INTERVAL: std::time::Duration = std::time::Duration::from_millis(250);

/// Snapshots carry the whole text, so space them out as the text grows:
/// 250 ms for a short reply, about 1.75 s at 15 KB. Bytes per second stay
/// bounded instead of growing with the square of the reply length.
fn snapshot_interval(text_len: usize) -> std::time::Duration {
    SNAPSHOT_INTERVAL + std::time::Duration::from_micros(text_len as u64 * 100)
}

#[derive(Debug, Default)]
pub struct Stream {
    pub turn_id: String,
    responses: BTreeMap<u64, (String, u64, bool)>,
    /// When each response step last emitted a snapshot, and steps whose newer
    /// text is still waiting for the next one (see `SNAPSHOT_INTERVAL`).
    last_snapshot: BTreeMap<u64, std::time::Instant>,
    unsent: BTreeSet<u64>,
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
    /// A native `schedule` tool call that was the last step of the turn. In
    /// headless `agy -p` the CLI exits instead of waking itself, so the host
    /// must turn it into a durable wake-up.
    pub native_schedule: Option<NativeSchedule>,
    /// A recurring native `schedule` (`CronExpression`). See [`NativeCron`].
    pub native_cron: Option<NativeCron>,
    /// The host took ownership of [`Self::native_cron`] and stopped the CLI on
    /// purpose; the interrupted result is a clean, handed-off end of turn.
    pub cron_handoff: bool,
    /// Background tasks the root agent announced it was idle-waiting for
    /// (`diagnostics: root agent idle; waiting up to … for N background task(s)`).
    pub idle_wait_tasks: Option<u32>,
}

/// Antigravity's built-in `schedule` tool (`DurationSeconds`, `Prompt`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeSchedule {
    pub step: u64,
    pub delay_seconds: u64,
    pub prompt: String,
}

/// Antigravity's recurring `schedule` tool (`CronExpression`, `Prompt`).
///
/// agy keeps this step `ACTIVE` for the lifetime of the cron, and its ordered
/// stream-json emitter holds every later step behind it until the process
/// exits (a SIGTERM loses them). The host must therefore own the schedule and
/// end the native process, or the turn goes silent while agy keeps working.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeCron {
    pub step: u64,
    pub expression: String,
    pub prompt: String,
}

fn parse_native_cron(step: u64, parameters: &Value) -> Option<NativeCron> {
    let expression = parameters["CronExpression"].as_str()?.trim();
    let prompt = parameters["Prompt"].as_str()?.trim();
    (!expression.is_empty() && !prompt.is_empty()).then(|| NativeCron {
        step,
        expression: expression.to_owned(),
        prompt: prompt.to_owned(),
    })
}

fn parse_native_schedule(step: u64, parameters: &Value) -> Option<NativeSchedule> {
    let delay = &parameters["DurationSeconds"];
    let delay_seconds = delay
        .as_u64()
        .or_else(|| {
            delay
                .as_f64()
                .filter(|v| *v >= 0.0)
                .map(|v| v.ceil() as u64)
        })
        .or_else(|| {
            delay
                .as_str()
                .and_then(|v| v.trim().trim_matches('"').parse().ok())
        })?;
    let prompt = parameters["Prompt"].as_str()?.trim();
    (delay_seconds > 0 && !prompt.is_empty()).then(|| NativeSchedule {
        step,
        delay_seconds,
        prompt: prompt.to_owned(),
    })
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
        if let Some(id) = item["taskId"]
            .as_str()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
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
        // Each event carries the whole text so far. The CLI streams a long
        // reply as a thousand tiny deltas; one snapshot per delta pushed
        // megabytes through the event bus and stalled Core for minutes.
        let interval = snapshot_interval(response.0.len());
        if !done
            && self
                .last_snapshot
                .get(&step)
                .is_some_and(|at| at.elapsed() < interval)
        {
            self.unsent.insert(step);
            return None;
        }
        self.snapshot_event(step, done)
    }

    fn snapshot_event(&mut self, step: u64, done: bool) -> Option<Value> {
        let response = self.responses.get_mut(&step)?;
        response.1 += 1;
        response.2 = done;
        let (text, revision) = (response.0.clone(), response.1);
        self.unsent.remove(&step);
        self.last_snapshot.insert(step, std::time::Instant::now());
        if self.turn_id.is_empty() {
            self.turn_id = uuid::Uuid::new_v4().to_string();
        }
        let mut ops = vec![json!({"type":"snapshot","text":text,"revision":revision})];
        if done {
            ops.push(json!({"type":"finalize"}));
        }
        Some(
            json!({"type":"text_op","bubble_id":format!("antigravity:{}:{}:{step}",self.session.as_deref().unwrap_or("unknown"),self.turn_id),"ops":ops}),
        )
    }

    /// Text held back by the interval goes out once the interval has passed.
    fn due_snapshots(&mut self) -> Vec<Value> {
        let due: Vec<u64> = self
            .unsent
            .iter()
            .copied()
            .filter(|step| {
                let len = self.responses.get(step).map_or(0, |r| r.0.len());
                self.last_snapshot
                    .get(step)
                    .is_none_or(|at| at.elapsed() >= snapshot_interval(len))
            })
            .collect();
        due.into_iter()
            .filter_map(|step| self.snapshot_event(step, false))
            .collect()
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
        let mut due = self.due_snapshots();
        due.extend(self.feed_inner(value));
        due
    }

    fn feed_inner(&mut self, value: &Value) -> Vec<Value> {
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
            if let Some(session) = self.session.as_deref() {
                for &step in &self.active_command_steps {
                    self.background_tasks
                        .entry(format!("{session}/task-{step}"))
                        .or_insert(true);
                }
            }
            self.success = body["status"] == "SUCCESS";
            if self.success {
                // A native retry may succeed after an earlier ERROR result.
                self.error = None;
                self.error_marker = None;
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
                self.reconcile_stream_post_response_failure();
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
        // Only a schedule that is the turn's last step is a deliberate wake-up.
        if self
            .native_schedule
            .as_ref()
            .is_some_and(|s| s.step != step)
        {
            self.native_schedule = None;
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
        if name == "schedule" {
            let parameters = if info["parameters"].is_object() {
                &info["parameters"]
            } else {
                &body["parameters"]
            };
            let ok = body["state"] != "ERROR" && info["error"].is_null();
            self.native_schedule = ok
                .then(|| parse_native_schedule(step, parameters))
                .flatten();
            if let Some(cron) = ok.then(|| parse_native_cron(step, parameters)).flatten() {
                self.native_cron = Some(cron);
            }
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

    /// A recurring schedule whose `ACTIVE` step is now stalling the native
    /// event stream (see [`NativeCron`]).
    pub fn blocking_cron(&self) -> Option<&NativeCron> {
        self.native_cron
            .as_ref()
            .filter(|cron| !self.completed_steps.contains_key(&cron.step))
    }

    pub fn observe_stderr(&mut self, line: &str) {
        if let Some(marker) = ErrorMarker::parse(line) {
            self.error_marker = Some(marker);
        }
        if let Some(tasks) = parse_idle_wait_diagnostic(line) {
            self.idle_wait_tasks = Some(tasks);
        } else if self.idle_wait_tasks.is_some()
            && self.error.is_none()
            && !self.success
            && line.trim().eq_ignore_ascii_case("error: interrupted")
        {
            self.error = Some("interrupted".into());
        }
    }

    /// The turn ended on the CLI's generic interruption while the root agent
    /// was idle-waiting for its background tasks or subagents.
    pub fn idle_wait_interrupted(&self) -> Option<u32> {
        let tasks = self.idle_wait_tasks?;
        if self.identity_error || self.success {
            return None;
        }
        let error = self.error.as_deref()?.trim().to_ascii_lowercase();
        let error = error.strip_prefix("error:").unwrap_or(&error).trim();
        matches!(
            error,
            "interrupted" | "antigravity result: cancelled" | "antigravity result: interrupted"
        )
        .then_some(tasks)
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
        self.scan_transcript_background_tasks(&content, min_turn_step);
    }

    fn scan_transcript_background_tasks(&mut self, content: &str, min_turn_step: Option<u64>) {
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

    /// Reconcile an orphaned `agy` process whose stdout pipe was no longer attached to Orb
    /// when it exited. Inspects `transcript.jsonl` after the turn's `USER_INPUT` step (`floor_step`)
    /// to verify whether the turn ended on a `DONE` `PLANNER_RESPONSE` without tool calls or
    /// `ERROR_MESSAGE` steps, and checks for unfinished background tasks.
    pub fn reconcile_orphan_transcript_turn(
        &mut self,
        home: &std::path::Path,
        floor_step: Option<u64>,
    ) {
        let Some(session) = self.session.clone() else {
            return;
        };
        let path = home
            .join(".gemini/antigravity-cli/brain")
            .join(&session)
            .join(".system_generated/logs/transcript.jsonl");
        let Ok(content) = std::fs::read_to_string(path) else {
            return;
        };
        let entries: Vec<Value> = content
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .collect();
        let floor = floor_step.or_else(|| {
            entries
                .iter()
                .rev()
                .find(|e| e["type"] == "USER_INPUT")
                .and_then(|e| e["step_index"].as_u64())
        });
        let Some(floor) = floor else {
            return;
        };
        self.scan_transcript_background_tasks(&content, Some(floor + 1));
        let mut last_step_type = "";
        let mut last_step_status = "";
        let mut last_has_tools = false;
        let mut saw_error_step = false;
        for entry in entries
            .iter()
            .filter(|e| e["step_index"].as_u64().is_some_and(|idx| idx > floor))
        {
            let step_type = entry["type"].as_str().unwrap_or("");
            let status = entry["status"].as_str().unwrap_or("");
            if step_type == "ERROR_MESSAGE" {
                saw_error_step = true;
            }
            last_step_type = step_type;
            last_step_status = status;
            last_has_tools = entry["tool_calls"]
                .as_array()
                .is_some_and(|tools| !tools.is_empty());
        }
        if !saw_error_step
            && last_step_type == "PLANNER_RESPONSE"
            && last_step_status == "DONE"
            && !last_has_tools
        {
            self.success = true;
        }
    }

    fn is_reconcilable_post_response_error(err: &str) -> bool {
        err.ends_with("(response may be truncated)")
            || err.contains("There was a network issue connecting to the server")
            || err.starts_with("API error (attempt ")
            || err.contains("The stream was interrupted")
            || err.contains("Malformed function call:")
    }

    /// Reconcile a false `postResponseFailure` directly from the observed `stream-json`
    /// events when `agy` recovered from an earlier mid-turn `error_message` step (e.g. a
    /// background task notification woke `agy` after `"The stream was interrupted"`) and
    /// later completed at least one subsequent `DONE` `agent_response` with non-empty text.
    fn reconcile_stream_post_response_failure(&mut self) {
        if self.identity_error || self.success || self.agent_response_active {
            return;
        }
        let Some(err) = self.error.as_deref() else {
            return;
        };
        if !Self::is_reconcilable_post_response_error(err) {
            return;
        }
        let Some((&last_step_idx, last_step)) = self.completed_steps.last_key_value() else {
            return;
        };
        if last_step.step_type != "agent_response"
            || last_step.state != "DONE"
            || last_step.text_len == 0
        {
            return;
        }
        let last_error_idx = self
            .completed_steps
            .iter()
            .rev()
            .find(|(_, step)| step.step_type == "error_message")
            .map(|(&idx, _)| idx);
        if let Some(err_idx) = last_error_idx {
            let recovered_after_error =
                self.completed_steps.range((err_idx + 1)..).any(|(_, s)| {
                    s.step_type == "tool" || (s.step_type == "agent_response" && s.state == "DONE")
                });
            if !recovered_after_error || err_idx >= last_step_idx {
                return;
            }
            self.reconciled_post_response_failure = true;
            self.success = true;
            self.error = None;
            self.error_marker = None;
        }
    }

    /// Reconcile a false `postResponseFailure` emitted by `agy` 1.2.10 / 1.3.1 when a
    /// resumed conversation had a historical `CortexStepErrorMessage` (`step_type = 17`)
    /// from an earlier turn.
    ///
    /// In `agy`, `postResponseFailure` always appends `" (response may be truncated)"` to
    /// `result.error`. If the current turn's final step in `completed_steps` is a `DONE`
    /// `agent_response` with non-empty text, no `error_message` step occurred at or after
    /// that final response, and the native `transcript.jsonl` confirms that final step is
    /// `PLANNER_RESPONSE` with status `DONE` and no subsequent `ERROR_MESSAGE` step, then
    /// the turn completed cleanly and the historical error step is neutralized.
    fn reconcile_false_post_response_failure(&mut self, home: &std::path::Path, session: &str) {
        if self.reconciled_post_response_failure {
            self.error_marker = None;
            clear_historical_error_steps(home, Some(session));
            return;
        }
        if self.identity_error || self.success || self.agent_response_active {
            return;
        }
        let Some(err) = self.error.as_deref() else {
            return;
        };
        if !Self::is_reconcilable_post_response_error(err) {
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
                .iter()
                .any(|(&idx, step)| step.step_type == "error_message" && idx >= last_step_idx)
        {
            return;
        }
        let Some(&first_step_idx) = self.completed_steps.keys().next() else {
            return;
        };
        let floor_idx = self
            .completed_steps
            .iter()
            .rev()
            .find(|(_, step)| step.step_type == "error_message")
            .map(|(&idx, _)| idx + 1)
            .unwrap_or(first_step_idx);
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
            if idx < floor_idx {
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
        if self.identity_error || self.session.is_none() {
            return false;
        }
        if self.success {
            return !self.unfinished_background_tasks().is_empty();
        }
        if self.idle_wait_interrupted().is_some() {
            return true;
        }
        self.error.as_deref().is_some_and(is_transient_error)
            || self
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
        // The host owns the recurring schedule and ended the CLI on purpose:
        // its `interrupted` result and idle-wait diagnostic are expected.
        if self.cron_handoff && !self.identity_error && self.session.is_some() {
            return Ok(());
        }
        if let Some(tasks) = self.idle_wait_interrupted() {
            return Err(idle_wait_interrupted_message(tasks));
        }
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
            if self.native_schedule.is_some() {
                // The turn ended on a deliberate native wake-up, not a crash.
                return Ok(());
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

/// Carbon (`agy-model-*`) and Argon (`agy-demo-*`) discovered variants are
/// each one base model with a separate effort control.
pub fn group_models(models: Vec<(String, String)>) -> Vec<(String, String)> {
    let mut seen = HashSet::new();
    models
        .into_iter()
        .filter_map(|(id, label)| {
            let grouped = id
                .strip_prefix("agy-model-")
                .filter(|level| matches!(*level, "low" | "medium" | "high"))
                .map(|level| ("agy-model", level))
                .or_else(|| {
                    id.strip_prefix("agy-demo-")
                        .filter(|level| matches!(*level, "low" | "medium" | "high"))
                        .map(|level| ("agy-demo", level))
                });
            let (id, label) = if let Some((base, level)) = grouped {
                let suffix = format!(
                    " ({})",
                    match level {
                        "low" => "Low",
                        "medium" => "Medium",
                        _ => "High",
                    }
                );
                (
                    base.to_string(),
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
    /// Replays a real node job log: `ANTIGRAVITY_REPLAY_LOG=<path> cargo test -- --ignored replay`.
    #[test]
    #[ignore]
    fn replay_real_job_log() {
        let Ok(path) = std::env::var("ANTIGRAVITY_REPLAY_LOG") else {
            return;
        };
        let mut stream = Stream::default();
        let (mut events, mut bytes, mut result) = (0usize, 0usize, String::new());
        for line in std::fs::read_to_string(path).unwrap().lines() {
            let Ok(value) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            if value["event"] == "result" {
                result = value["result"]["response"]
                    .as_str()
                    .unwrap_or_default()
                    .to_owned();
            }
            for event in stream.feed(&value) {
                events += 1;
                bytes += event.to_string().len();
            }
        }
        eprintln!(
            "replay: {events} events, {bytes} bytes, final text {} chars",
            stream.text.len()
        );
        assert_eq!(stream.text, result);
        assert!(events < 100, "{events} events");
    }

    #[test]
    fn long_streamed_reply_is_coalesced_and_ends_with_the_full_text() {
        let mut stream = Stream::default();
        let piece = "word ".repeat(3);
        let mut events = vec![];
        for _ in 0..1000 {
            events.extend(stream.feed(&json!({"event":"step_update","step_update":{
                "conversation_id":"c","step_index":5,"state":"ACTIVE","step_type":"agent_response","text_delta":piece}})));
        }
        events.extend(stream.feed(&json!({"event":"step_update","step_update":{
            "conversation_id":"c","step_index":5,"state":"DONE","step_type":"agent_response","text_delta":"end"}})));
        // 1,001 deltas arrive within one interval: one opening snapshot plus the final one.
        assert!(events.len() <= 3, "{} events", events.len());
        let last = events.last().unwrap();
        let expected = format!("{}end", piece.repeat(1000));
        assert_eq!(last["ops"][0]["text"], expected);
        assert_eq!(last["ops"][1]["type"], "finalize");
        let revisions: Vec<u64> = events
            .iter()
            .map(|e| e["ops"][0]["revision"].as_u64().unwrap())
            .collect();
        assert!(
            revisions.windows(2).all(|w| w[0] < w[1]),
            "revisions increase: {revisions:?}"
        );
        assert_eq!(stream.text, expected);
    }

    #[test]
    fn held_back_text_is_sent_after_the_interval() {
        let mut stream = Stream::default();
        let delta = |d: &str| {
            json!({"event":"step_update","step_update":{
            "conversation_id":"c","step_index":7,"state":"ACTIVE","step_type":"agent_response","text_delta":d}})
        };
        assert_eq!(stream.feed(&delta("a")).len(), 1);
        assert!(stream.feed(&delta("b")).is_empty(), "within the interval");
        std::thread::sleep(SNAPSHOT_INTERVAL + std::time::Duration::from_millis(20));
        // Any later event flushes the held-back text first.
        let out = stream.feed(&json!({"event":"step_update","step_update":{
            "conversation_id":"c","step_index":8,"state":"ACTIVE","step_type":"tool","tool_name":"x"}}));
        assert_eq!(out[0]["ops"][0]["text"], "ab");
    }

    #[test]
    fn responses_have_stable_step_ids_and_survive_tool_boundaries_and_short_final_receipts() {
        let mut stream = Stream {
            turn_id: "turn".into(),
            ..Default::default()
        };
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

        let carbon_models = group_models(vec![
            ("agy-model-low".into(), "Gemini 4 Carbon (Low)".into()),
            ("agy-model-medium".into(), "Gemini 4 Carbon (Medium)".into()),
            ("agy-model-high".into(), "Gemini 4 Carbon (High)".into()),
        ]);
        assert_eq!(
            carbon_models,
            vec![("agy-model".into(), "Gemini 4 Carbon".into())]
        );
        for alias in ["agy-model", "gemini-4-carbon", "gemini-4-carbon-eap"] {
            let args = args_with_effort(Some(alias), None, None, "ping");
            assert!(args.windows(2).any(|v| v == ["--model", "agy-model-high"]));
            assert!(!args.iter().any(|v| v == "--effort"));
        }
        let args = args_with_effort(Some("agy-model"), Some("low"), None, "ping");
        assert!(args.windows(2).any(|v| v == ["--model", "agy-model-low"]));
        assert!(!args.iter().any(|v| v == "--effort"));
        let args = args_with_effort(Some("agy-model-medium"), None, None, "ping");
        assert!(args
            .windows(2)
            .any(|v| v == ["--model", "agy-model-medium"]));
        assert!(!args.iter().any(|v| v == "--effort"));
        let args = args_with_effort(Some("gemini-4-carbon-low"), Some("high"), None, "ping");
        assert!(args.windows(2).any(|v| v == ["--model", "agy-model-high"]));
        assert!(!args.iter().any(|v| v == "--effort"));
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
    /// Captured from agy 1.4.7: after an ACTIVE recurring `schedule` step the
    /// CLI emitted no further step (the turn's three later steps were only in
    /// its conversation database) and SIGTERM produced `interrupted`.
    #[test]
    fn recurring_schedule_stalls_the_stream_until_the_host_takes_it_over() {
        let mut s = Stream::default();
        let fixture = include_str!("../tests/fixtures/antigravity_cron_schedule.jsonl");
        let mut lines = fixture
            .lines()
            .map(|l| serde_json::from_str::<Value>(l).unwrap());
        let mut tools = vec![];
        for value in lines.by_ref().take(4) {
            tools.extend(s.feed(&value));
        }
        let cron = s
            .blocking_cron()
            .cloned()
            .expect("ACTIVE cron blocks the stream");
        assert_eq!(
            (cron.step, cron.expression.as_str(), cron.prompt.as_str()),
            (2, "*/30 * * * *", "status ping")
        );
        assert!(
            s.native_schedule.is_none(),
            "a cron is not a one-shot wake-up"
        );
        // The tool call is still surfaced to clients.
        assert!(tools
            .iter()
            .any(|t| t["type"] == "tool_call" && t["name"] == "schedule"));
        s.observe_stderr(
            "diagnostics: root agent idle; waiting up to 30m0s for 1 background task(s)",
        );
        for value in lines {
            s.feed(&value);
        }
        // Without the handoff an interrupted cron turn is a failure ...
        assert!(s.finish().is_err());
        // ... with it, a clean end of turn that keeps the conversation identity.
        s.cron_handoff = true;
        assert!(s.finish().is_ok());
        assert_eq!(
            s.session.as_deref(),
            Some("fd68616d-2d82-4199-bace-1286e5216688")
        );
        // A later DONE update of the same step means it no longer blocks.
        let mut done = Stream::default();
        done.feed(&json!({"event":"init","conversation_id":"c"}));
        for state in ["ACTIVE", "DONE"] {
            done.feed(
                &json!({"event":"step_update","step_update":{"conversation_id":"c","step_index":7,
                "state":state,"step_type":"tool","tool_name":"schedule","tool_info":{"parameters":
                {"CronExpression":"0 * * * *","Prompt":"p"}}}}),
            );
        }
        assert!(done.blocking_cron().is_none());
        assert!(done.native_cron.is_some());
        // A failed schedule call registers nothing, and a handoff never hides an identity change.
        let mut failed = Stream::default();
        failed.feed(
            &json!({"event":"step_update","step_update":{"conversation_id":"c","step_index":3,
            "state":"ERROR","step_type":"tool","tool_name":"schedule","tool_info":{"parameters":
            {"CronExpression":"*/5 * * * *","Prompt":"p"}}}}),
        );
        assert!(failed.native_cron.is_none());
        failed.cron_handoff = true;
        failed
            .feed(&json!({"event":"result","result":{"conversation_id":"other","status":"ERROR"}}));
        assert!(failed.finish().is_err());
    }

    #[test]
    fn trailing_native_schedule_is_a_clean_end_of_turn() {
        let mut s = Stream::default();
        s.feed(&json!({"event":"init","conversation_id":"c"}));
        s.feed(
            &json!({"event":"step_update","step_update":{"conversation_id":"c","step_index":4,
            "state":"DONE","step_type":"tool","tool_name":"schedule","tool_info":{"parameters":
            {"DurationSeconds":1800,"Prompt":"30-minute supervision check-in"}}}}),
        );
        assert_eq!(
            s.native_schedule,
            Some(NativeSchedule {
                step: 4,
                delay_seconds: 1800,
                prompt: "30-minute supervision check-in".into()
            })
        );
        assert!(s.finish().is_ok());
        // A later step means the schedule was not what ended the turn.
        s.feed(
            &json!({"event":"step_update","step_update":{"conversation_id":"c","step_index":5,
            "state":"DONE","step_type":"agent_response","text_delta":"more"}}),
        );
        assert!(s.native_schedule.is_none());
        assert!(s.finish().unwrap_err().contains("without a SUCCESS result"));
        // String durations and a failed schedule call.
        let mut s = Stream::default();
        s.feed(
            &json!({"event":"step_update","step_update":{"conversation_id":"c","step_index":1,
            "state":"DONE","step_type":"tool","tool_name":"schedule","tool_info":{"parameters":
            {"DurationSeconds":"60","Prompt":"p"}}}}),
        );
        assert_eq!(
            s.native_schedule.as_ref().map(|s| s.delay_seconds),
            Some(60)
        );
        s.feed(
            &json!({"event":"step_update","step_update":{"conversation_id":"c","step_index":2,
            "state":"ERROR","step_type":"tool","tool_name":"schedule","tool_info":{"parameters":
            {"DurationSeconds":60,"Prompt":"p"}}}}),
        );
        assert!(s.native_schedule.is_none());
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
        assert!(validate_prompt(&"a".repeat(MAX_PROMPT_BYTES)).is_ok());
        assert!(validate_prompt(&"'".repeat(MAX_PROMPT_BYTES + 1)).is_err());
        assert!(validate_prompt(&"é".repeat(MAX_PROMPT_BYTES)).is_err());
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

    #[test]
    fn reconcile_orphan_transcript_turn_rejects_unfinished_background_tasks_and_crashed_turns() {
        let home = tempfile::tempdir().unwrap();
        let session = "ddd67091-4a2f-4fba-b905-7a8144dee4eb";
        let task_id = format!("{session}/task-2964");
        let logs_dir = home
            .path()
            .join(".gemini/antigravity-cli/brain")
            .join(session)
            .join(".system_generated/logs");
        std::fs::create_dir_all(&logs_dir).unwrap();

        // Case 1: Orphan exited right after launching a background task (step 2964 RUNNING + step 2965 PLANNER_RESPONSE).
        std::fs::write(
            logs_dir.join("transcript.jsonl"),
            [
                json!({
                    "step_index": 2642,
                    "type": "USER_INPUT",
                    "status": "DONE",
                    "content": "Oui vas-y"
                }),
                json!({
                    "step_index": 2963,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "tool_calls": [{"name": "run_command", "args": {"CommandLine": "lean --stdin"}}]
                }),
                json!({
                    "step_index": 2964,
                    "type": "GENERIC",
                    "status": "RUNNING",
                    "content": format!("Created At: 2026-10-07T17:49:38+01:00\nTool is running as a background task with task id: {task_id}\nTask Description: lean --stdin")
                }),
                json!({
                    "step_index": 2965,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "content": "I am verifying the Lean 4.31.0 reference proof for succinct-safe and will continue creating the three new task families once the check completes."
                }),
            ]
            .iter()
            .map(|v| serde_json::to_string(v).unwrap())
            .collect::<Vec<_>>()
            .join("\n")
                + "\n",
        )
        .unwrap();

        let mut stream = Stream {
            session: Some(session.to_owned()),
            ..Default::default()
        };
        stream.reconcile_orphan_transcript_turn(home.path(), Some(2642));
        let err = stream.finish().unwrap_err();
        assert!(err.contains(&task_id), "unexpected err: {err}");
        assert!(err.contains("while background task(s)"));

        // Case 2: Background task finished and final PLANNER_RESPONSE completed cleanly.
        std::fs::write(
            logs_dir.join("transcript.jsonl"),
            [
                json!({
                    "step_index": 2642,
                    "type": "USER_INPUT",
                    "status": "DONE",
                    "content": "Oui vas-y"
                }),
                json!({
                    "step_index": 2964,
                    "type": "GENERIC",
                    "status": "RUNNING",
                    "content": format!("Created At: 2026-10-07T17:49:38+01:00\nTool is running as a background task with task id: {task_id}\nTask Description: lean --stdin")
                }),
                json!({
                    "step_index": 2966,
                    "type": "SYSTEM_MESSAGE",
                    "status": "DONE",
                    "content": format!("<SYSTEM_MESSAGE>\nTask id \"{task_id}\" finished with result:\nThe command exited with code 0.\n</SYSTEM_MESSAGE>")
                }),
                json!({
                    "step_index": 2967,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "content": "All three task families are complete."
                }),
            ]
            .iter()
            .map(|v| serde_json::to_string(v).unwrap())
            .collect::<Vec<_>>()
            .join("\n")
                + "\n",
        )
        .unwrap();

        let mut clean_stream = Stream {
            session: Some(session.to_owned()),
            ..Default::default()
        };
        clean_stream.reconcile_orphan_transcript_turn(home.path(), Some(2642));
        assert!(clean_stream.finish().is_ok());
    }

    #[test]
    fn clear_all_historical_error_steps_and_api_attempt_reconcile() {
        let home = tempfile::tempdir().unwrap();
        let conv_dir = home.path().join(".gemini/antigravity-cli/conversations");
        std::fs::create_dir_all(&conv_dir).unwrap();
        let session = "a2664f62-92f7-48f4-a506-ae80c95dca3a";
        let db_path = conv_dir.join(format!("{session}.db"));
        let conn = rusqlite::Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE steps(idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER, step_payload BLOB);",
        )
        .unwrap();
        // Field 24 (0xc2, 0x01) -> length 4 -> Field 3 (0x1a) -> length 2 -> Field 1 (0x08, 0x01)
        let raw_payload = vec![0xc2u8, 0x01, 0x04, 0x1a, 0x02, 0x08, 0x01];
        conn.execute(
            "INSERT INTO steps VALUES (1299, 17, 6, ?1)",
            rusqlite::params![raw_payload],
        )
        .unwrap();
        drop(conn);

        clear_all_historical_error_steps(home.path());

        let conn = rusqlite::Connection::open(&db_path).unwrap();
        let updated: Vec<u8> = conn
            .query_row(
                "SELECT step_payload FROM steps WHERE idx = 1299",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(updated.ends_with(&[0x20, 0x01]));

        let logs_dir = home
            .path()
            .join(".gemini/antigravity-cli/brain")
            .join(session)
            .join(".system_generated/logs");
        std::fs::create_dir_all(&logs_dir).unwrap();
        std::fs::write(
            logs_dir.join("transcript.jsonl"),
            format!(
                "{}\n",
                json!({
                    "step_index": 2234,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "content": "Final EV Bench report completed."
                })
            ),
        )
        .unwrap();

        let mut stream = Stream::default();
        stream.feed(&json!({
            "event": "init",
            "conversation_id": session
        }));
        stream.feed(&json!({
            "event": "step_update",
            "step_update": {
                "conversation_id": session,
                "step_index": 2234,
                "state": "DONE",
                "step_type": "agent_response",
                "text_delta": "Final EV Bench report completed."
            }
        }));
        stream.feed(&json!({
            "event": "result",
            "result": {
                "conversation_id": session,
                "status": "ERROR",
                "error": "API error (attempt 1): UNAVAILABLE (code 503): The service is currently unavailable."
            }
        }));
        stream.reconcile_transcript_background_tasks(home.path());
        assert!(stream.reconciled_post_response_failure);
        assert!(stream.success);
        assert!(stream.error.is_none());
        assert!(stream.finish().is_ok());
    }

    #[test]
    fn root_agent_idle_wait_interruption_is_a_retryable_end_of_turn() {
        assert_eq!(
            parse_idle_wait_diagnostic(
                "diagnostics: root agent idle; waiting up to 30m0s for 1 background task(s)"
            ),
            Some(1)
        );
        assert_eq!(parse_idle_wait_diagnostic("root agent idle"), None);
        // Interruption reported only on stderr (incident 3fe5c5a3 / job 10cfe462).
        let mut stream = Stream::default();
        stream.feed(&json!({"event":"init","conversation_id":"s"}));
        stream.observe_stderr(
            "diagnostics: root agent idle; waiting up to 30m0s for 2 background task(s)",
        );
        stream.observe_stderr("error: interrupted");
        assert!(stream.is_retryable());
        let err = stream.finish().unwrap_err();
        assert!(err.contains(IDLE_WAIT_INTERRUPTED_MARKER), "{err}");
        assert!(err.contains("2 still running"));
        assert!(is_transient_error(&err));
        // Interruption reported as the native result.
        let mut stream = Stream::default();
        stream.feed(&json!({"event":"init","conversation_id":"s"}));
        stream.observe_stderr(
            "diagnostics: root agent idle; waiting up to 30m0s for 1 background task(s)",
        );
        stream.feed(&json!({"event":"result","result":{"conversation_id":"s","status":"ERROR","error":"interrupted"}}));
        assert!(stream.is_retryable());
        assert!(stream
            .finish()
            .unwrap_err()
            .contains(IDLE_WAIT_INTERRUPTED_MARKER));
        // Without the idle diagnostic, a bare interruption stays unclassified,
        // and operator/auth failures are never rewritten.
        let mut stream = Stream::default();
        stream.feed(&json!({"event":"init","conversation_id":"s"}));
        stream.observe_stderr("error: interrupted");
        assert!(stream.error.is_none());
        stream.observe_stderr(
            "diagnostics: root agent idle; waiting up to 30m0s for 1 background task(s)",
        );
        stream.feed(&json!({"event":"result","result":{"conversation_id":"s","status":"ERROR","error":"UNAUTHENTICATED: sign in again"}}));
        assert!(!stream.is_retryable());
        assert!(!stream
            .finish()
            .unwrap_err()
            .contains(IDLE_WAIT_INTERRUPTED_MARKER));
        for transient in [
            "Malformed function call: missing name",
            "API error (attempt 2): INTERNAL",
            "model output stopped (response may be truncated)",
        ] {
            assert!(is_transient_error(transient), "{transient}");
        }
    }

    #[test]
    fn truncated_response_remains_retryable_and_a_later_success_clears_it() {
        let mut stream = Stream::default();
        stream.feed(&json!({"event":"init","conversation_id":"same-session"}));
        stream.feed(&json!({"event":"result","result":{"conversation_id":"same-session","status":"ERROR","error":"Your previous response was cut off because it exceeded the output token limit\nPlease continue from where you left off, keeping your response shorter\nRetries remaining: 3"}}));
        assert!(stream.is_retryable());
        assert!(stream.finish().is_err());
        stream.feed(&json!({"event":"result","result":{"conversation_id":"same-session","status":"SUCCESS","response":"Continued with a short response."}}));
        assert!(stream.finish().is_ok());
        assert!(stream.error.is_none());
        assert!(!is_transient_error(
            "UNAUTHENTICATED: UNAVAILABLE (code 503)"
        ));
        assert!(!is_transient_error(
            "cancelled by user: The stream was interrupted"
        ));
    }

    #[test]
    fn mid_turn_recovered_stream_interruption_reconciles_and_preserves_unfinished_task_guard() {
        let session = "1e2969c3-c37e-4bfb-816b-876b6df1f6a4";
        let mut stream = Stream::default();
        stream.feed(&json!({"event": "init", "conversation_id": session}));
        stream.feed(&json!({
            "event": "step_update",
            "step_update": {
                "conversation_id": session,
                "step_index": 11540,
                "state": "DONE",
                "step_type": "agent_response",
                "text_delta": "Starting compose build."
            }
        }));
        stream.feed(&json!({
            "event": "step_update",
            "step_update": {
                "conversation_id": session,
                "step_index": 11541,
                "state": "DONE",
                "step_type": "error_message",
                "duration_seconds": 0
            }
        }));
        stream.feed(&json!({
            "event": "step_update",
            "step_update": {
                "conversation_id": session,
                "step_index": 12634,
                "state": "ACTIVE",
                "step_type": "tool",
                "tool_name": "run_command",
                "tool_info": {
                    "name": "run_command",
                    "parameters": {"CommandLine": "lake build SigGolfCandidate.Packaging.Ready"}
                }
            }
        }));
        stream.feed(&json!({
            "event": "step_update",
            "step_update": {
                "conversation_id": session,
                "step_index": 12635,
                "state": "DONE",
                "step_type": "agent_response",
                "text_delta": "La compilation de C = 7 310 est en cours, j'attends sa fin."
            }
        }));
        stream.feed(&json!({
            "event": "result",
            "result": {
                "conversation_id": session,
                "status": "ERROR",
                "error": "The stream was interrupted. Please continue the task you were working on."
            }
        }));
        assert!(stream.reconciled_post_response_failure);
        assert!(stream.success);
        assert!(stream.error.is_none());
        let err = stream.finish().unwrap_err();
        assert!(err.contains("1e2969c3-c37e-4bfb-816b-876b6df1f6a4/task-12634"));
        assert!(stream.is_retryable());
    }
}
