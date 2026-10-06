//! Native Antigravity CLI 1.2 event protocol. Shared by Core and Orb.
#[path = "antigravity_thoughts.rs"]
pub mod thoughts;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashSet};

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
    completed_steps: HashSet<u64>,
    tools: HashSet<String>,
}

impl Stream {
    fn response_event(&mut self, step: u64, delta: &str, done: bool) -> Option<Value> {
        let response = self.responses.entry(step).or_default();
        if response.2 || (delta.is_empty() && (!done || response.0.is_empty())) {
            return None;
        }
        response.0.push_str(delta);
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
            "init" => value,
            "step_update" => &value["step_update"],
            "result" => &value["result"],
            _ => return vec![],
        };
        if let Some(id) = body["conversation_id"].as_str().filter(|s| !s.is_empty()) {
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
            if !self.success {
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
                // Some CLI versions return only the final response. Never erase
                // the intermediate responses already displayed by a local client.
                if response != self.text && !self.responses.values().any(|r| r.0 == response) {
                    self.text.push_str(response);
                    if let Some(event) = self.response_event(u64::MAX, response, true) {
                        events.push(event);
                    }
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
        if self.completed_steps.contains(&step) {
            return vec![];
        }
        if matches!(body["state"].as_str(), Some("DONE" | "ERROR")) {
            self.completed_steps.insert(step);
            self.input_tokens += body["usage"]["input_tokens"].as_u64().unwrap_or(0);
            self.output_tokens += body["usage"]["output_tokens"].as_u64().unwrap_or(0);
            if let Some(tokens) = body["usage"]["thinking_tokens"].as_u64() {
                *self.thinking_tokens.get_or_insert(0) += tokens;
            }
            self.cache_read_tokens += body["usage"]["cache_read_tokens"].as_u64().unwrap_or(0);
        }
        let mut events = vec![];
        if body["step_type"] == "agent_response" {
            self.agent_response_active = body["state"] == "ACTIVE";
            if let Some(delta) = body["text_delta"].as_str() {
                self.text.push_str(delta);
            }
            if let Some(event) = self.response_event(
                step,
                body["text_delta"].as_str().unwrap_or_default(),
                matches!(body["state"].as_str(), Some("DONE" | "ERROR")),
            ) {
                events.push(event);
            }
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
        if matches!(body["state"].as_str(), Some("DONE" | "ERROR")) {
            events.push(json!({"type":"tool_call_update","toolCallId":id,"name":name,"toolName":name,"status":if body["state"] == "ERROR" || !info["error"].is_null() {"failed"} else {"completed"},"output":info["output"],"rawOutput":info["output"]}));
        }
        events
    }

    pub fn observe_stderr(&mut self, line: &str) {
        if let Some(marker) = ErrorMarker::parse(line) {
            self.error_marker = Some(marker);
        }
    }

    pub fn is_retryable(&self) -> bool {
        !self.identity_error
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
}
