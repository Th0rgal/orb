//! Mistral Vibe through Orb's ACP bridge: the prompt on stdin, JSON events on
//! stdout, and an acknowledgement once the bridge journaled the session.

use super::*;
use std::io::Write;
use std::ops::ControlFlow;

pub(crate) fn spawn(
    request: &StartRequest,
    ctx: &RunCtx,
    env: &[(String, String)],
) -> Result<Child, String> {
    let plan = request
        .prompt
        .trim()
        .strip_prefix("/plan")
        .filter(|s| s.is_empty() || s.starts_with(char::is_whitespace));
    let prompt = plan.map(str::trim).unwrap_or(&request.prompt);
    let (python, prefix) = vibe_python(&request.bin)?;
    let mut command = harness_command(&python);
    command.args(prefix);
    let bindings = crate::local_bindings(None, None)?;
    if let Some(transfer) = bindings[&request.id]["transferId"].as_str() {
        let transfer = uuid::Uuid::parse_str(transfer).map_err(|_| "Invalid transfer identity")?;
        command.env("SANDBOXED_VIBE_TRANSFER_ID", transfer.to_string());
    }
    command
        .envs(env.iter().map(|(k, v)| (k, v)))
        .current_dir(&request.cwd)
        .args(crate::vibe::args(
            &request.bin,
            &request.id,
            request.model.as_deref(),
            request.session_id.as_deref(),
            prompt,
            bindings[&request.id]["planMode"].as_bool().unwrap_or(false)
                || crate::vibe::plan_mode(None, &request.prompt),
            true,
        ))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut child = command
        .spawn()
        .map_err(|e| format!("Cannot start Vibe: {e}"))?;
    let stdout = child.stdout.take().ok_or("Vibe stdout unavailable")?;
    let mut stdin = child.stdin.take().ok_or("Vibe stdin unavailable")?;
    if let Err(err) = writeln!(stdin, "{}", serde_json::json!({"prompt":prompt})) {
        reap(&mut child, &request.id, "vibe prompt delivery failed");
        return Err(format!("Cannot deliver Vibe prompt: {err}"));
    }
    spawn_line_reader(
        stdout,
        &ctx.output,
        Reader {
            ctx: ctx.clone(),
            stream: crate::vibe::Stream {
                session: request.session_id.clone(),
                ..Default::default()
            },
            stdin,
            pid: child.id(),
        },
    );
    Ok(child)
}

pub(crate) struct Reader {
    ctx: RunCtx,
    stream: crate::vibe::Stream,
    stdin: std::process::ChildStdin,
    pid: u32,
}

impl LineHandler for Reader {
    fn line(&mut self, line: &str) -> Result<ControlFlow<()>, String> {
        let Ok(event) = serde_json::from_str::<Value>(line) else {
            return Ok(ControlFlow::Continue(()));
        };
        let output = &self.ctx.output;
        let stream = &mut self.stream;
        let previous_thinking = stream.thinking.len();
        for tool in stream.feed(&event) {
            output.native_activity(&tool);
        }
        if stream.thinking.len() != previous_thinking {
            output.native_activity(
                &json!({"type":"reasoning","part":{"id":"vibe","text":stream.thinking}}),
            );
        }
        if stream.error.is_none() && event["type"] == "session" {
            self.ctx.session.replace(stream.session.clone());
            // The bridge fsyncs its native-session journal before this acknowledgement.
            if self.stdin.write_all(b"{\"continue\":true}\n").is_err() {
                stream.error = Some("Vibe acknowledgement failed".into());
            }
        }
        output.replace(stream.text.clone());
        output.publish_activities();
        if stream.error.is_some() {
            #[cfg(unix)]
            unsafe {
                libc::kill(self.pid as i32, libc::SIGTERM);
            }
            return Ok(ControlFlow::Break(()));
        }
        Ok(ControlFlow::Continue(()))
    }

    fn end(self, _read: Result<(), String>) {
        if let Err(message) = self.stream.finish() {
            self.ctx.error.set(message);
        }
    }
}

/// Prefer Vibe's own interpreter, including uv's Windows tool environment.
/// The bridge needs Python 3.9+; a visible CLI alone does not imply python3 is on PATH.
pub(crate) fn vibe_python(cli: &str) -> Result<(String, Vec<String>), String> {
    let mut candidates: Vec<(PathBuf, Vec<String>)> = Vec::new();
    let mut add_directory = |directory: &Path| {
        for name in ["python.exe", "python3", "python"] {
            candidates.push((directory.join(name), vec![]));
        }
    };
    if let Ok(path) = Path::new(cli).canonicalize() {
        if let Some(directory) = path.parent() {
            add_directory(directory);
        }
    }
    let tool_root = std::env::var_os("UV_TOOL_DIR")
        .map(PathBuf::from)
        .or_else(|| {
            let uv = crate::agent_software::resolve("uv")?;
            command_output(Command::new(uv).args(["tool", "dir"])).map(PathBuf::from)
        });
    if let Some(root) = tool_root {
        add_directory(&root.join("mistral-vibe/Scripts"));
        add_directory(&root.join("mistral-vibe/bin"));
    }
    for name in ["python3", "python", "py"] {
        if let Some(path) = crate::agent_software::resolve(name) {
            candidates.push((
                path,
                if name == "py" {
                    vec!["-3".into()]
                } else {
                    vec![]
                },
            ));
        }
    }
    for (path, prefix) in candidates {
        if !path.is_file() {
            continue;
        }
        let version = command_output(Command::new(&path).args(&prefix).arg("--version"));
        let supported = version
            .as_deref()
            .and_then(|v| v.strip_prefix("Python "))
            .and_then(|v| {
                let mut parts = v.split('.');
                Some((
                    parts.next()?.parse::<u32>().ok()?,
                    parts.next()?.parse::<u32>().ok()?,
                ))
            })
            .is_some_and(|version| version >= (3, 9));
        if supported {
            return Ok((path.to_string_lossy().into_owned(), prefix));
        }
    }
    Err("Vibe requires Python 3.9+; install Python or uv's Mistral Vibe tool environment".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn vibe_uses_the_tool_interpreter_even_without_python3_on_path() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let scripts = dir.path().join("Scripts");
        std::fs::create_dir(&scripts).unwrap();
        let cli = scripts.join("vibe-acp.exe");
        std::fs::write(&cli, "stub").unwrap();
        let python = scripts.join("python.exe");
        std::fs::write(&python, "#!/bin/sh\necho 'Python 3.12.0'\n").unwrap();
        std::fs::set_permissions(&python, std::fs::Permissions::from_mode(0o755)).unwrap();
        let (selected, prefix) = vibe_python(cli.to_str().unwrap()).unwrap();
        assert_eq!(PathBuf::from(selected), python.canonicalize().unwrap());
        assert!(prefix.is_empty());
    }
}
