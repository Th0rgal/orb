//! Shared native Vibe ACP transport and event reducer.
use serde_json::{json, Value};

pub const BRIDGE: &str = include_str!("vibe_bridge.py");

pub fn plan_mode(agent: Option<&str>, prompt: &str) -> bool {
    agent == Some("plan")
        || prompt
            .trim()
            .strip_prefix("/plan")
            .is_some_and(|tail| tail.is_empty() || tail.starts_with(char::is_whitespace))
}

pub fn args(
    cli: &str,
    mission: &str,
    model: Option<&str>,
    session: Option<&str>,
    prompt: &str,
    plan: bool,
    ack: bool,
) -> Vec<String> {
    let mut args = vec![
        "-u".into(),
        "-c".into(),
        BRIDGE.into(),
        "--cli".into(),
        cli.into(),
        "--mission".into(),
        mission.into(),
        "--prompt".into(),
        prompt.into(),
    ];
    for (flag, value) in [("--model", model), ("--resume", session)] {
        if let Some(value) = value.filter(|value| !value.trim().is_empty()) {
            args.extend([flag.into(), value.into()]);
        }
    }
    if plan {
        args.extend(["--mode".into(), "plan".into()]);
    }
    if ack {
        args.push("--ack".into());
    }
    args
}

#[derive(Debug, Default)]
pub struct Stream {
    pub session: Option<String>,
    pub text: String,
    pub thinking: String,
    pub success: bool,
    pub error: Option<String>,
}
impl Stream {
    pub fn feed(&mut self, event: &Value) -> Vec<Value> {
        match event["type"].as_str() {
            Some("session") => {
                if let Some(id) = event["session_id"].as_str().filter(|s| !s.is_empty()) {
                    if self
                        .session
                        .as_deref()
                        .is_some_and(|expected| expected != id)
                    {
                        self.error = Some("Vibe resumed a different native session".into());
                    } else {
                        self.session = Some(id.into());
                    }
                }
            }
            Some("error") => {
                self.error = Some(event["message"].as_str().unwrap_or("Vibe failed").into())
            }
            Some("result") => {
                self.success = event["stop_reason"] == "end_turn"
                    && self.session.is_some()
                    && self.error.is_none();
                if !self.success {
                    self.error = Some(format!("Vibe stopped: {}", event["stop_reason"]));
                }
            }
            Some("update") if self.session.is_some() && self.error.is_none() => {
                let update = &event["update"];
                match update["sessionUpdate"].as_str() {
                    Some("agent_message_chunk") => self
                        .text
                        .push_str(update["content"]["text"].as_str().unwrap_or_default()),
                    Some("agent_thought_chunk") => self
                        .thinking
                        .push_str(update["content"]["text"].as_str().unwrap_or_default()),
                    Some("tool_call" | "tool_call_update") => {
                        if update["sessionUpdate"] == "tool_call_update"
                            && !matches!(update["status"].as_str(), Some("completed" | "failed"))
                        {
                            return vec![];
                        }
                        let decode = |value: &Value| {
                            value
                                .as_str()
                                .and_then(|s| serde_json::from_str::<Value>(s).ok())
                                .unwrap_or_else(|| value.clone())
                        };
                        return vec![json!({
                            "type": update["sessionUpdate"], "toolCallId": update["toolCallId"],
                        "name": update["_meta"]["tool_name"].as_str().or_else(|| update["title"].as_str()).unwrap_or("Vibe tool"),
                        "toolName": update["_meta"]["tool_name"].as_str().or_else(|| update["title"].as_str()).unwrap_or("Vibe tool"),
                        "rawInput": decode(&update["rawInput"]), "rawOutput": decode(&update["rawOutput"]),
                            "content": update["content"], "status": update["status"]
                        })];
                    }
                    _ => {}
                }
            }
            _ => {}
        }
        vec![]
    }
    pub fn finish(&self) -> Result<(), String> {
        if let Some(error) = &self.error {
            return Err(error.clone());
        }
        if !self.success {
            return Err(
                "Vibe exited without an ACP end_turn result; resume the recorded native session"
                    .into(),
            );
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn plan_mode_accepts_selected_agent_or_explicit_command() {
        assert!(plan_mode(Some("plan"), "Inspect the workspace"));
        assert!(plan_mode(None, "/plan inspect"));
        assert!(!plan_mode(None, "/planet"));
        assert!(!plan_mode(Some("build"), "Inspect the workspace"));
    }

    #[test]
    fn native_result_is_required_and_identity_cannot_change() {
        let mut stream = Stream::default();
        stream.feed(&json!({"type":"session","session_id":"native"}));
        stream.feed(&json!({"type":"update","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"answer"}}}));
        assert!(stream.finish().is_err());
        stream.feed(&json!({"type":"result","stop_reason":"end_turn"}));
        assert!(stream.finish().is_ok());
        assert_eq!(stream.text, "answer");
        stream.feed(&json!({"type":"session","session_id":"different"}));
        assert!(stream.finish().is_err());
    }
}
