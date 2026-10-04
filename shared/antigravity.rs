//! Native Antigravity CLI 1.2 event protocol. Shared by Core and Orb.
use serde_json::{json, Value};
use std::collections::HashSet;

pub fn args(model: Option<&str>, session: Option<&str>, prompt: &str) -> Vec<String> {
    let mut args = vec![
        "--output-format".into(),
        "stream-json".into(),
        "--dangerously-skip-permissions".into(),
    ];
    if let Some(model) = model.filter(|s| !s.is_empty()) {
        args.extend(["--model".into(), model.into()]);
    }
    if let Some(session) = session.filter(|s| !s.is_empty()) {
        args.extend(["--conversation".into(), session.into()]);
    }
    args.extend(["-p".into(), prompt.into()]);
    args
}

#[derive(Debug, Default)]
pub struct Stream {
    pub session: Option<String>,
    pub expected_session: Option<String>,
    pub text: String,
    pub error: Option<String>,
    pub success: bool,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    completed_steps: HashSet<u64>,
    tools: HashSet<String>,
}

impl Stream {
    /// Returns normalized tool events. Text remains an authoritative snapshot.
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
                self.error =
                    Some("Antigravity changed conversation identity during the turn".into());
                return vec![];
            }
            self.session = Some(id.into());
        }
        if kind == "result" {
            self.success = body["status"] == "SUCCESS";
            if !self.success {
                self.error = Some(format!(
                    "Antigravity result: {}",
                    body["status"].as_str().unwrap_or("missing status")
                ));
            }
            if let Some(response) = body["response"].as_str() {
                if !response.is_empty() {
                    self.text = response.into();
                }
            }
            // result.usage is lifetime cumulative on resumed conversations.
            // Count only per-step usage so follow-ups are not charged twice.
            return vec![];
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
        if body["state"] == "DONE" {
            self.completed_steps.insert(step);
            self.input_tokens += body["usage"]["input_tokens"].as_u64().unwrap_or(0);
            self.output_tokens += body["usage"]["output_tokens"].as_u64().unwrap_or(0);
            self.cache_read_tokens += body["usage"]["cache_read_tokens"].as_u64().unwrap_or(0);
        }
        if body["step_type"] == "agent_response" {
            if let Some(delta) = body["text_delta"].as_str() {
                self.text.push_str(delta);
            }
        }
        if body["step_type"] != "tool" {
            return vec![];
        }
        let id = format!("{}:{step}", self.session.as_deref().unwrap_or("unknown"));
        let info = &body["tool_info"];
        let name = body["tool_name"]
            .as_str()
            .or_else(|| info["name"].as_str())
            .unwrap_or("tool");
        let mut events = vec![];
        if self.tools.insert(id.clone()) {
            events.push(json!({"type":"tool_call","toolCallId":id,"name":name,"toolName":name,"rawInput":info["parameters"]}));
        }
        if body["state"] == "DONE" {
            events.push(json!({"type":"tool_call_update","toolCallId":id,"name":name,"toolName":name,"status":if info["error"].is_null() {"completed"} else {"failed"},"output":info["output"],"rawOutput":info["output"]}));
        }
        events
    }

    pub fn finish(&self) -> Result<(), String> {
        if let Some(error) = &self.error {
            return Err(error.clone());
        }
        if self.session.is_none() {
            return Err("Antigravity did not report a conversation ID".into());
        }
        if !self.success {
            return Err("Antigravity ended without a SUCCESS result; resume this conversation before retrying work".into());
        }
        Ok(())
    }
}

/// Authenticated native discovery, bounded and without retaining stderr (OAuth URLs).
pub fn models(binary: &std::path::Path) -> Result<Vec<(String, String)>, String> {
    use std::process::{Command, Stdio};
    let mut child = Command::new(binary)
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
    let models: Vec<_> = text
        .lines()
        .filter_map(|line| line.split_once('\t'))
        .filter(|(id, label)| !id.is_empty() && !label.is_empty())
        .map(|(id, label)| (id.to_string(), label.to_string()))
        .collect();
    if models.is_empty() {
        return Err("No Antigravity models are available for this account".into());
    }
    Ok(models)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn real_argon_turn_has_tools_usage_and_an_explicit_result() {
        let mut stream = Stream::default();
        let mut tools = 0;
        for line in include_str!("../tests/fixtures/antigravity_turn.jsonl").lines() {
            tools += stream.feed(&serde_json::from_str(line).unwrap()).len();
        }
        assert!(stream.finish().is_ok());
        assert!(tools >= 4);
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
    fn resumes_exact_session_and_keeps_prompt_one_argument() {
        let a = args(Some("agy-demo"), Some("abc"), "$(false)\nhello");
        assert!(a.windows(2).any(|p| p == ["--conversation", "abc"]));
        assert_eq!(a.last().unwrap(), "$(false)\nhello");
        assert!(!a.contains(&"--continue".into()));
    }
}
