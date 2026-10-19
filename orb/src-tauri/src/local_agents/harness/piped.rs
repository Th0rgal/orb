//! Argument-prompt harnesses (Grok, OpenCode): the prompt in argv, stdin
//! closed, JSON events on stdout and the start of stderr as the error.

use super::*;
use std::ops::ControlFlow;

/// What differs between argument-prompt harnesses.
pub(crate) trait PipedHarness {
    fn args(&self, request: &StartRequest) -> Vec<String>;
    /// Whether stdout is JSON events rather than plain text.
    fn json(&self) -> bool {
        true
    }
    /// Environment set before the launch environment, so it can override it.
    fn defaults(&self, _command: &mut Command) {}
    /// Environment derived from the launch environment.
    fn configure(
        &self,
        _command: &mut Command,
        _request: &StartRequest,
        _env: &[(String, String)],
    ) {
    }
    /// How to recover a final answer the CLI persisted without printing it.
    fn recovery(&self, _request: &StartRequest) -> Option<Recovery> {
        None
    }
}

/// `opencode export <session>` run from `cwd` after the stream ends.
pub(crate) struct Recovery {
    bin: String,
    cwd: String,
}

pub(crate) struct Grok;

impl PipedHarness for Grok {
    fn args(&self, request: &StartRequest) -> Vec<String> {
        grok_args(request)
    }
}

pub(crate) struct OpenCode;

impl PipedHarness for OpenCode {
    fn args(&self, request: &StartRequest) -> Vec<String> {
        opencode_args(request)
    }
    fn defaults(&self, command: &mut Command) {
        // Share the user's provider credentials/config, but not a database whose
        // schema may belong to a different OpenCode build (e.g. the desktop app).
        if std::env::var_os("OPENCODE_DB").is_none() {
            command.env("OPENCODE_DB", "orb-local.db");
        }
        command.env("OPENCODE_PERMISSION", r#"{"*":"allow"}"#);
    }
    fn configure(&self, command: &mut Command, request: &StartRequest, env: &[(String, String)]) {
        if let Some(wake_command) = crate::local_wakeups::command(&request.id) {
            let raw = env
                .iter()
                .find(|(k, _)| k == "OPENCODE_CONFIG_CONTENT")
                .map(|(_, v)| v.clone())
                .or_else(|| std::env::var("OPENCODE_CONFIG_CONTENT").ok());
            let mut config: Value = raw
                .and_then(|v| serde_json::from_str(&v).ok())
                .unwrap_or_else(|| json!({}));
            config["mcp"]["orb-wakeups"] =
                json!({"type":"local","command":wake_command,"enabled":true});
            command.env("OPENCODE_CONFIG_CONTENT", config.to_string());
        }
    }
    fn recovery(&self, request: &StartRequest) -> Option<Recovery> {
        Some(Recovery {
            bin: request.bin.clone(),
            cwd: request.cwd.clone(),
        })
    }
}

pub(crate) fn spawn(
    request: &StartRequest,
    harness: &dyn PipedHarness,
    ctx: &RunCtx,
    env: &[(String, String)],
) -> Result<Child, String> {
    let mut command = mission_command(request, env);
    harness.defaults(&mut command);
    command.envs(env.iter().map(|(key, value)| (key, value)));
    harness.configure(&mut command, request, env);
    command.env("NO_COLOR", "1");
    let mut child = command
        .current_dir(&request.cwd)
        .args(harness.args(request))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn_logged(ctx)
        .map_err(|e| format!("failed to start {}: {e}", request.harness))?;
    if let Some(stdout) = child.stdout.take() {
        if harness.json() {
            spawn_line_reader(
                stdout,
                &ctx.output,
                Reader {
                    ctx: ctx.clone(),
                    recovery: harness.recovery(request),
                },
            );
        } else {
            let output = Arc::clone(&ctx.output);
            let guard = ctx.output.reader();
            thread::spawn(move || {
                let _guard = guard;
                stream_plain(&mut std::io::BufReader::new(stdout), &output);
            });
        }
    }
    if let Some(stderr) = child.stderr.take() {
        drain_stderr(stderr, ctx, StderrPolicy::ErrorHead);
    }
    Ok(child)
}

pub(crate) struct Reader {
    ctx: RunCtx,
    recovery: Option<Recovery>,
}

impl LineHandler for Reader {
    fn line(&mut self, line: &str) -> Result<ControlFlow<()>, String> {
        let output = &self.ctx.output;
        if let Ok(value) = serde_json::from_str::<Value>(line) {
            if let Some(id) = session_id_from_event(&value) {
                self.ctx.bind_session(id.to_string());
            }
            output.native_activity(&value);
            if matches!(
                value["type"].as_str(),
                Some("tool_use" | "tool_call" | "tool_call_update" | "reasoning")
            ) {
                output.publish_activities();
            }
            if value["type"] == "error" {
                let message = value
                    .pointer("/error/data/message")
                    .or_else(|| value.pointer("/error/message"))
                    .or_else(|| value.get("message"))
                    .and_then(Value::as_str)
                    .unwrap_or("Harness reported a protocol error");
                self.ctx.error.set(message.chars().take(1000).collect());
            }
        }
        if let Some(piece) = extract_text(line).filter(|s| !s.is_empty()) {
            output.append(&piece);
        }
        Ok(ControlFlow::Continue(()))
    }

    fn end(self, _read: Result<(), String>) {
        // OpenCode can persist a final text part without emitting it on
        // its CLI JSON stream. Reconcile before releasing the reader guard.
        let (Some(recovery), Some(id)) = (self.recovery, self.ctx.session.get()) else {
            return;
        };
        let mut command = Command::new(recovery.bin);
        command
            .args(["export", &id])
            .current_dir(recovery.cwd)
            .stdin(Stdio::null());
        if std::env::var_os("OPENCODE_DB").is_none() {
            command.env("OPENCODE_DB", "orb-local.db");
        }
        if let Ok(result) = command.output() {
            if result.status.success() {
                if let Ok(value) = serde_json::from_slice::<Value>(&result.stdout) {
                    if let Some(answer) = opencode_final_answer(&value) {
                        self.ctx.output.replace(answer);
                    }
                }
            }
        }
    }
}

pub(crate) fn grok_args(request: &StartRequest) -> Vec<String> {
    let mut args = vec![
        "--always-approve".into(),
        "--no-plan".into(),
        "--output-format".into(),
        "streaming-json".into(),
    ];
    if let Some(model) = request.model.as_deref().filter(|s| !s.is_empty()) {
        args.extend(["--model".into(), model.into()]);
    }
    if let Some(session) = request.session_id.as_deref().filter(|s| !s.is_empty()) {
        args.extend(["--resume".into(), session.into()]);
    }
    args.extend(["-p".into(), request.prompt.clone()]);
    args
}

pub(crate) fn opencode_args(request: &StartRequest) -> Vec<String> {
    let mut args = vec![
        "run".into(),
        "--format".into(),
        "json".into(),
        "--dir".into(),
        request.cwd.clone(),
    ];
    if let Some(model) = request.model.as_deref().filter(|m| !m.is_empty()) {
        args.push("--model".into());
        // Backend aliases need their configured OpenCode provider namespace.
        args.push(if model.starts_with("builtin/") {
            format!("sandboxed-sh/{model}")
        } else {
            model.to_string()
        });
    }
    match request.session_id.as_deref().filter(|s| !s.is_empty()) {
        Some(sid) if sid.starts_with("ses_") => {
            args.push("--session".into());
            args.push(sid.to_string());
        }
        Some(_) => args.push("--continue".into()),
        None => {}
    }
    args.push(request.prompt.clone());
    for path in &request.image_paths {
        args.extend(["--file".into(), path.clone()]);
    }
    args
}

pub(crate) fn opencode_final_answer(value: &Value) -> Option<String> {
    let messages = value["messages"].as_array()?;
    let start = messages.iter().rposition(|m| m["info"]["role"] == "user")?;
    let message = messages[start + 1..]
        .iter()
        .rev()
        .find(|m| m["info"]["role"] == "assistant" && m["info"]["finish"] == "stop")?;
    let text = message["parts"]
        .as_array()?
        .iter()
        .filter(|p| p["type"] == "text")
        .filter_map(|p| p["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n\n");
    (!text.trim().is_empty()).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opencode_export_recovers_only_latest_turn_final_answer() {
        let user = json!({"info":{"role":"user"},"parts":[]});
        let answer = |text: &str, finish: &str| json!({"info":{"role":"assistant","finish":finish},"parts":[{"type":"text","text":text}]});
        let export = json!({"messages":[user,answer("Old answer","stop"),user,answer("......","tool-calls"),answer("Full final answer","stop")]});
        assert_eq!(
            opencode_final_answer(&export).as_deref(),
            Some("Full final answer")
        );
        let incomplete =
            json!({"messages":[user,answer("Old answer","stop"),user,answer(".","tool-calls")]});
        assert_eq!(opencode_final_answer(&incomplete), None);
    }

    #[test]
    fn grok_and_opencode_args_match_the_pinned_flags() {
        let fresh = StartRequest {
            service_tier: None,
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            image_paths: vec![],
            id: "1".into(),
            harness: "opencode".into(),
            bin: "opencode".into(),
            cwd: "/tmp".into(),
            prompt: "hi".into(),
            model: Some("xai/grok".into()),
            session_id: None,
            shared_cwd_with: None,
        };
        let mut grok = fresh.clone();
        grok.harness = "grok".into();
        grok.model = None;
        assert_eq!(
            grok_args(&grok),
            vec![
                "--always-approve",
                "--no-plan",
                "--output-format",
                "streaming-json",
                "-p",
                "hi"
            ]
        );
        grok.model = Some("grok-4.7".into());
        grok.session_id = Some("existing-session".into());
        assert_eq!(
            grok_args(&grok),
            vec![
                "--always-approve",
                "--no-plan",
                "--output-format",
                "streaming-json",
                "--model",
                "grok-4.7",
                "--resume",
                "existing-session",
                "-p",
                "hi"
            ]
        );
        assert_eq!(
            opencode_args(&fresh),
            vec!["run", "--format", "json", "--dir", "/tmp", "--model", "xai/grok", "hi"]
                .into_iter()
                .map(str::to_string)
                .collect::<Vec<_>>()
        );
        let smart = StartRequest {
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            model: Some("builtin/smart".into()),
            ..fresh.clone()
        };
        assert!(opencode_args(&smart).contains(&"sandboxed-sh/builtin/smart".to_string()));
        let resumed = StartRequest {
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            session_id: Some("ses_abc".into()),
            ..fresh
        };
        assert!(opencode_args(&resumed)
            .windows(2)
            .any(|pair| pair == ["--session".to_string(), "ses_abc".to_string()]));
    }

    #[cfg(unix)]
    #[test]
    fn argument_prompt_harnesses_receive_eof_on_stdin() {
        let request = StartRequest {
            service_tier: None,
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            id: "stdin-test".into(),
            harness: "opencode".into(),
            bin: "/bin/sh".into(),
            cwd: "/tmp".into(),
            prompt: "hello".into(),
            model: None,
            session_id: None,
            image_paths: vec![],
            shared_cwd_with: None,
        };
        /// Plain-text output from a shell that only reads its stdin.
        struct Shell;
        impl PipedHarness for Shell {
            fn args(&self, _: &StartRequest) -> Vec<String> {
                vec!["-c".into(), "cat >/dev/null".into()]
            }
            fn json(&self) -> bool {
                false
            }
        }
        let ctx = RunCtx::new(&request.id, &request.harness, None);
        let mut child = spawn(&request, &Shell, &ctx, &[]).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("harness waited forever for stdin EOF");
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
}
