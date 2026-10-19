//! Antigravity (`agy`): one process per turn, JSON events on stdout, a
//! structured error marker on stderr and thoughts read from its brain files.

use super::*;
use crate::sync_util::lock;
use std::ops::ControlFlow;

// A durable create-new marker also fences retries after an Orb restart or lost stdout.
// Only a confirmed OS spawn failure may release it; a known native ID can resume.
pub(crate) fn claim_antigravity_attempt(
    root: &std::path::Path,
    id: &str,
    cwd: &std::path::Path,
    session: Option<&str>,
) -> Result<Option<PathBuf>, String> {
    if session.is_some_and(|id| !id.trim().is_empty()) {
        return Ok(None);
    }
    std::fs::create_dir_all(root).map_err(|e| e.to_string())?;
    use sha2::{Digest, Sha256};
    let mut key = Sha256::new();
    key.update(id.as_bytes());
    key.update([0]);
    key.update(
        cwd.canonicalize()
            .map_err(|e| e.to_string())?
            .as_os_str()
            .as_encoded_bytes(),
    );
    let name = format!("{:x}", key.finalize());
    let path = root.join(name);
    let file = std::fs::OpenOptions::new().write(true).create_new(true).open(&path)
        .map_err(|e| if e.kind() == std::io::ErrorKind::AlreadyExists {
            "Antigravity has an earlier launch without a recorded conversation ID. Reconcile that native conversation before retrying; automatic replay is blocked.".to_string()
        } else { e.to_string() })?;
    file.sync_all().map_err(|e| e.to_string())?;
    std::fs::File::open(root)
        .and_then(|dir| dir.sync_all())
        .map_err(|e| e.to_string())?;
    Ok(Some(path))
}

pub(crate) fn spawn(
    request: &StartRequest,
    ctx: &RunCtx,
    env: &[(String, String)],
) -> Result<Child, String> {
    crate::antigravity::validate_prompt(&request.prompt)?;
    let home = std::env::var_os("HOME").ok_or("HOME is unavailable")?;
    crate::antigravity::clear_historical_error_steps(
        std::path::Path::new(&home),
        request.session_id.as_deref(),
    );
    let mut claim_root = PathBuf::from(&home).join(".orb/antigravity-attempts");
    if request
        .session_id
        .as_deref()
        .is_none_or(|id| id.trim().is_empty())
    {
        let bindings = crate::local_bindings(None, None)?;
        if let Some(transfer) = bindings[&request.id]["transferId"].as_str() {
            let transfer =
                uuid::Uuid::parse_str(transfer).map_err(|_| "Invalid transfer identity")?;
            claim_root = claim_root.join(transfer.to_string());
        }
    }
    let claim = claim_antigravity_attempt(
        &claim_root,
        &request.id,
        std::path::Path::new(&request.cwd),
        request.session_id.as_deref(),
    )?;
    let mut command = mission_command(request, env);
    let mut child = command
        .current_dir(&request.cwd)
        .args(crate::antigravity::args_with_effort(
            request.model.as_deref(),
            request.effort.as_deref(),
            request.session_id.as_deref(),
            &request.prompt,
        ))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn_logged(ctx)
        .map_err(|e| {
            if let Some(path) = &claim {
                let _ = std::fs::remove_file(path);
            }
            format!("Cannot start Antigravity: {e}")
        })?;
    let stdout = child
        .stdout
        .take()
        .ok_or("Antigravity stdout unavailable")?;
    let stderr = child
        .stderr
        .take()
        .ok_or("Antigravity stderr unavailable")?;
    let stderr_reader = drain_stderr(stderr, ctx, StderrPolicy::AntigravityMarker);
    let thoughts = Arc::new(Mutex::new(crate::antigravity::thoughts::Reader::new(
        std::path::Path::new(&home),
    )));
    let thoughts_done = Arc::new(AtomicBool::new(false));
    {
        let thoughts = Arc::clone(&thoughts);
        let stop = Arc::clone(&thoughts_done);
        let output = Arc::clone(&ctx.output);
        let guard = ctx.output.reader();
        thread::spawn(move || {
            let _guard = guard;
            loop {
                for event in lock(&thoughts).poll() {
                    output.antigravity_thought(&event);
                }
                if stop.load(Ordering::Acquire) {
                    break;
                }
                thread::sleep(Duration::from_millis(500));
            }
        });
    }
    let mut stream = crate::antigravity::Stream::default();
    stream.expected_session = request.session_id.clone();
    ctx.output.antigravity_progress(&stream);
    ctx.output.publish_activities();
    spawn_line_reader(
        stdout,
        &ctx.output,
        Reader {
            ctx: ctx.clone(),
            stream,
            expected: request.session_id.clone(),
            thoughts,
            thoughts_done,
            stderr_reader: Some(stderr_reader),
            pid: child.id(),
            transcript_home: PathBuf::from(&home),
        },
    );
    Ok(child)
}

pub(crate) struct Reader {
    ctx: RunCtx,
    stream: crate::antigravity::Stream,
    expected: Option<String>,
    thoughts: Arc<Mutex<crate::antigravity::thoughts::Reader>>,
    thoughts_done: Arc<AtomicBool>,
    stderr_reader: Option<thread::JoinHandle<Option<crate::antigravity::ErrorMarker>>>,
    pid: u32,
    transcript_home: PathBuf,
}

impl LineHandler for Reader {
    fn line(&mut self, line: &str) -> Result<ControlFlow<()>, String> {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            return Ok(ControlFlow::Continue(()));
        };
        let output = &self.ctx.output;
        let stream = &mut self.stream;
        for tool in stream.feed(&value) {
            output.native_activity(&tool);
        }
        if value["event"].as_str() == Some("result") && stream.error.is_some() {
            stream.reconcile_transcript_background_tasks(&self.transcript_home);
        }
        if stream.error.is_none() {
            lock(&self.thoughts).observe(&value);
        }
        if matches!(
            value["event"].as_str(),
            Some("init" | "step_update" | "result")
        ) {
            output.antigravity_progress(stream);
        }
        output.publish_activities();
        if let Some(id) = &stream.session {
            if self.expected.as_deref().is_some_and(|old| old != id) {
                stream.error = Some("Antigravity resumed a different conversation".into());
            } else {
                self.ctx.bind_session(id.clone());
            }
        }
        output.replace(stream.text.clone());
        // Transient result errors may be followed by the CLI's own retry.
        // Keep reading until its terminal result instead of cancelling it.
        if stream.error.is_some() && !stream.is_retryable() {
            #[cfg(unix)]
            unsafe {
                libc::kill(self.pid as i32, libc::SIGTERM);
            }
            return Ok(ControlFlow::Break(()));
        }
        Ok(ControlFlow::Continue(()))
    }

    fn end(mut self, _read: Result<(), String>) {
        self.thoughts_done.store(true, Ordering::Release);
        if let Some(Ok(Some(marker))) = self.stderr_reader.take().map(|reader| reader.join()) {
            self.stream.error_marker = Some(marker);
        }
        self.stream
            .reconcile_transcript_background_tasks(&self.transcript_home);
        self.ctx.output.set_retryable(self.stream.is_retryable());
        if let Err(message) = self.stream.finish() {
            self.ctx.error.set(message);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn antigravity_unbound_attempt_survives_retry_and_allows_known_resume() {
        let root = tempfile::tempdir().unwrap();
        let marker = claim_antigravity_attempt(root.path(), "mission", root.path(), None)
            .unwrap()
            .unwrap();
        assert!(marker.is_file());
        let destination = tempfile::tempdir().unwrap();
        assert!(
            claim_antigravity_attempt(root.path(), "mission", destination.path(), None).is_ok()
        );
        assert!(claim_antigravity_attempt(root.path(), "mission", root.path(), None).is_err());
        assert!(claim_antigravity_attempt(root.path(), "mission", root.path(), Some("")).is_err());
        assert!(
            claim_antigravity_attempt(root.path(), "mission", root.path(), Some("native-id"))
                .unwrap()
                .is_none()
        );
        assert!(claim_antigravity_attempt(root.path(), "other", root.path(), None).is_ok());
    }

    #[test]
    fn antigravity_process_requires_terminal_result_and_preserves_resume() {
        use std::os::unix::fs::PermissionsExt;
        for outcome in ["SUCCESS", "MISSING", "ERROR"] {
            let success = outcome == "SUCCESS";
            let dir = tempfile::tempdir().unwrap();
            let bin = dir.path().join("agy-fixture");
            let mut script = String::from("#!/bin/sh\nprintf '%s\\n' '{\"event\":\"init\",\"conversation_id\":\"native-session\"}'\n");
            if success {
                script.push_str("printf '%s\\n' '{\"event\":\"result\",\"result\":{\"conversation_id\":\"native-session\",\"status\":\"SUCCESS\",\"response\":\"Ready\"}}'\n");
            }
            if outcome == "ERROR" {
                script.push_str("printf '%s\\n' 'AGY_ERROR: {\"short_error\":\"read: no route to host\",\"status\":\"UNKNOWN\",\"error_code\":2,\"code_kind\":\"grpc\",\"retryable\":true}' >&2\n");
                script.push_str("printf '%s\\n' '{\"event\":\"result\",\"result\":{\"conversation_id\":\"native-session\",\"status\":\"ERROR\",\"error\":\"There was a network issue connecting to the server, please try again.\",\"response\":\"Partial answer\"}}'\n");
            }
            std::fs::write(&bin, script).unwrap();
            std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
            let request = StartRequest {
                service_tier: None,
                effort: None,
                cyber_revision: None,
                cyber_access: None,
                image_paths: vec![],
                id: "antigravity-fixture".into(),
                harness: "antigravity".into(),
                bin: bin.to_string_lossy().into_owned(),
                cwd: dir.path().to_string_lossy().into_owned(),
                prompt: "hello".into(),
                model: Some("agy-demo".into()),
                session_id: Some("native-session".into()),
                shared_cwd_with: None,
            };
            let ctx = RunCtx::new(&request.id, &request.harness, None);
            let (output, session, error) = (&ctx.output, &ctx.session, &ctx.error);
            let mut child = super::spawn_harness(&request, &ctx, &[], &[]).unwrap();
            let status = child.wait().unwrap();
            if outcome != "ERROR" {
                assert!(status.success());
            }
            assert!(output.wait_drained(Some(Duration::from_secs(2))));
            assert_eq!(session.get().as_deref(), Some("native-session"));
            assert_eq!(error.get().is_none(), success);
            assert_eq!(output.retryable(), outcome == "ERROR");
            if outcome == "ERROR" {
                let message = error.get().unwrap();
                assert!(message.contains(
                    "There was a network issue connecting to the server, please try again."
                ));
                assert!(message.contains("read: no route to host"));
            }
            if success {
                assert_eq!(output.snapshot(), "Ready");
            }
        }
    }
}
