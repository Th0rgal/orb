//! Start, exit watching, polling and Stop of a local run.

use super::*;
use crate::sync_util::lock;

pub(crate) const DIRECTORY_BUSY: &str =
    "This directory already has a running local mission. Choose a separate directory or worktree.";

pub(crate) fn start_with_env(
    request: StartRequest,
    env: &[(String, String)],
) -> Result<(), String> {
    start_with_env_fenced(request, env, None)
}

pub(crate) fn start_with_env_fenced(
    request: StartRequest,
    env: &[(String, String)],
    expected_stop: Option<u64>,
) -> Result<(), String> {
    start_with_options(
        request,
        env,
        expected_stop,
        &harness::claude::RECHECK_DELAYS,
    )
}

/// The full launch: `recheck_delays` are how long a Claude turn waits on the
/// same background tasks before Orb asks about them again.
pub(crate) fn start_with_options(
    request: StartRequest,
    env: &[(String, String)],
    expected_stop: Option<u64>,
    recheck_delays: &[Duration],
) -> Result<(), String> {
    let fence = launch_fence(&request.id);
    let generation = lock(&fence);
    if expected_stop.is_some_and(|expected| expected != *generation) {
        return Err(LAUNCH_CANCELLED.into());
    }
    if request
        .prompt
        .trim()
        .strip_prefix("/plan")
        .is_some_and(|s| s.is_empty() || s.starts_with(char::is_whitespace))
        && !matches!(request.harness.as_str(), "codex" | "claudecode" | "vibe")
    {
        return Err("Native plan mode is not supported by this integration.".into());
    }
    if request.id.trim().is_empty() {
        return Err("run id is required".into());
    }
    let cwd = PathBuf::from(&request.cwd);
    if !cwd.is_dir() {
        return Err("working directory does not exist".into());
    }
    let bin = PathBuf::from(&request.bin);
    if !bin.is_file() {
        return Err(format!("CLI not found at {}", request.bin));
    }
    let software_execution =
        crate::agent_software::begin(&request.id, &request.harness, Some(&bin))?;
    let mut map = lock(runs());
    if let Some(previous) = map.get(&request.id) {
        if !previous.is_done() {
            return Err("This mission is still running locally. Wait for it to finish or stop it before sending another message.".into());
        }
    }
    let canonical_cwd = cwd.canonicalize().map_err(|e| e.to_string())?;
    let shared_parent = request
        .shared_cwd_with
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    if map.iter().any(|(id, run)| {
        id != &request.id
            && shared_parent != Some(id.as_str())
            && run.shared_cwd_with.as_deref() != Some(request.id.as_str())
            && (shared_parent.is_none() || run.shared_cwd_with.as_deref() != shared_parent)
            && !run.is_done()
            && run.cwd.canonicalize().ok().as_ref() == Some(&canonical_cwd)
    }) {
        return Err(DIRECTORY_BUSY.into());
    }
    // Completed handles are retained for reconnect snapshots until the next turn.
    // Retire the old app-server before resuming its thread in a fresh process.
    if let Some(previous) = map.remove(&request.id) {
        reap(
            &mut lock(&previous.child),
            &request.id,
            "retire previous turn",
        );
    }
    let ctx = RunCtx::new(&request.id, &request.harness, request.session_id.clone());
    let resumed = request.session_id.as_deref().is_some_and(|s| !s.is_empty());
    let interaction = crate::interactions::begin(&request.id);
    let child = match harness::spawn_harness(&request, &ctx, env, recheck_delays) {
        Ok(child) => child,
        Err(error) => {
            crate::interactions::finish(&interaction);
            return Err(error);
        }
    };
    let mut run = Run::new(ctx, child, cwd, resumed);
    run.mcp_wrapped = env.iter().any(|(key, _)| key == "SANDBOXED_MCP_WRAPPER");
    run.shared_cwd_with = shared_parent.map(str::to_owned);
    watch_exit(
        software_execution,
        interaction,
        run.clone(),
        request.harness == "antigravity",
    );
    map.insert(request.id, run);
    Ok(())
}

/// Kill a child that may still run, then reap it.
pub(crate) fn reap(child: &mut Child, _mission: &str, _why: &str) {
    if child.try_wait().ok().flatten().is_none() {
        let _ = child.kill();
    }
    let _ = child.wait();
}

pub(crate) fn watch_exit(
    software_execution: crate::agent_software::Execution,
    mission_id: crate::interactions::Session,
    run: Run,
    strict_terminal: bool,
) {
    thread::spawn(move || {
        let _software_execution = software_execution;
        let child = &run.child;
        // waitid leaves the child unreaped. Stop and the waiter serialize reaping
        // through Child's mutex, so a recycled PID is never signalled.
        #[cfg(unix)]
        {
            let pid = lock(child).id();
            loop {
                let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
                let result = unsafe {
                    libc::waitid(libc::P_PID, pid, &mut info, libc::WEXITED | libc::WNOWAIT)
                };
                if result == 0
                    || std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
                {
                    break;
                }
            }
        }
        #[cfg(windows)]
        {
            use std::os::windows::io::AsRawHandle;
            #[link(name = "kernel32")]
            unsafe extern "system" {
                fn WaitForSingleObject(handle: *mut std::ffi::c_void, milliseconds: u32) -> u32;
            }
            let handle = lock(child).as_raw_handle();
            unsafe {
                WaitForSingleObject(handle, u32::MAX);
            }
        }
        let status = lock(child).wait().ok();
        crate::interactions::finish(&mission_id);
        run.exit_code
            .replace(status.and_then(|status| status.code()));
        let output = &run.ctx.output;
        output.wait_drained(None);
        settle_exit(
            &run.ctx,
            strict_terminal,
            run.stopped.load(Ordering::SeqCst),
            status.and_then(exit_signal),
            &run.exit_code,
        );
        run.ctx.done.store(true, Ordering::SeqCst);
        let _ = run.finished.set(Instant::now());
        let mut terminal = run.snapshot(output.retryable(), None);
        terminal.done = true;
        output.finish(terminal);
        prune_finished_runs();
    });
}

#[cfg(unix)]
pub(crate) fn exit_signal(status: std::process::ExitStatus) -> Option<i32> {
    use std::os::unix::process::ExitStatusExt;
    status.signal()
}
#[cfg(not(unix))]
pub(crate) fn exit_signal(_: std::process::ExitStatus) -> Option<i32> {
    None
}

/// Decide the terminal error and exit code once the process is reaped.
pub(crate) fn settle_exit(
    ctx: &RunCtx,
    strict_terminal: bool,
    stopped: bool,
    signal: Option<i32>,
    exit_code: &Slot<i32>,
) {
    let harness = ctx.label();
    // stderr is diagnostic, not an outcome. Claude emits informational
    // gateway/connector notices here even after a successful native result.
    if exit_code.get() != Some(0) {
        if let Some(diagnostic) = ctx.output.diagnostic() {
            ctx.error.update(|slot| {
                if slot.is_none()
                    || slot.as_deref() == Some(harness::claude::STOPPED_WITHOUT_RESULT)
                {
                    *slot = Some(format!("{harness} process failed: {diagnostic}"));
                }
            });
        }
    }
    if strict_terminal {
        ctx.error.update(|error| {
            exit_code.update(|code| {
                if error.is_some() {
                    // A parsed error is a failure, whatever the process reported.
                    if matches!(*code, None | Some(0)) {
                        *code = Some(1);
                    }
                } else if *code != Some(0) && !stopped {
                    // A crash without a parsed error must not read as success.
                    *error = Some(match (*code, signal) {
                        (Some(code), _) => format!("{harness} exited with code {code}"),
                        (None, Some(signal)) => {
                            format!("{harness} was terminated by signal {signal}")
                        }
                        (None, None) => format!("{harness} exited without a status"),
                    });
                    code.get_or_insert(1);
                } else if *code != Some(0) {
                    // Stopped by the user: a deliberate end, not a failure.
                    *code = Some(0);
                }
            })
        });
    }
}

/// Read only the execution owned by the caller, under the same registry lock.
pub fn poll_generation(id: &str, expected: Option<&str>) -> Result<PollState, String> {
    if expected.is_none() && !has_run(id) {
        reattach_if_orphaned(id);
    }
    let map = lock(runs());
    let run = map.get(id).ok_or_else(|| "no local run".to_string())?;
    if expected.is_some_and(|generation| generation != run.generation) {
        return Err("Local execution generation changed".into());
    }
    Ok(run.snapshot(run.ctx.output.retryable(), run.ctx.output.waiting_since()))
}

/// In-process subscription (client link uplink); same atomic snapshot rule.
pub fn subscribe_native(
    id: &str,
    sink: std::sync::mpsc::Sender<OutputEvent>,
) -> Result<u64, String> {
    run_of(id)?.ctx.output.subscribe_native(sink)
}

pub fn stop_generation(id: &str, expected: Option<&str>) -> Result<(), String> {
    let run = lock(runs()).get(id).cloned();
    // Waiting for this run must not block polling or stopping other missions.
    if let Some(run) = run {
        if expected.is_some_and(|token| token != run.generation) {
            return Ok(());
        }
        crate::interactions::cancel(id);
        run.stopped.store(true, Ordering::SeqCst);
        let mut child = lock(&run.child);
        // The trusted wrapper owns the CLI's child process group. Give it
        // time to forward termination and reap that group before escalation.
        #[cfg(unix)]
        if run.mcp_wrapped && !run.is_done() {
            unsafe {
                libc::kill(child.id() as i32, libc::SIGTERM);
            }
            let deadline = Instant::now() + Duration::from_secs(6);
            while child.try_wait().map_err(|e| e.to_string())?.is_none()
                && Instant::now() < deadline
            {
                thread::sleep(Duration::from_millis(10));
            }
        }
        // Completed runs stay cached for their transcript. Their old process
        // group ID may have been reused, so never signal it after completion.
        #[cfg(unix)]
        if child.try_wait().map_err(|e| e.to_string())?.is_none() {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
        }
        if child.try_wait().map_err(|e| e.to_string())?.is_none() {
            child.kill().map_err(|e| e.to_string())?;
        }
        let status = child.wait().map_err(|e| e.to_string())?;
        run.exit_code.replace(status.code());
        drop(child);
        if expected.is_none() {
            stop_orphan_mission_processes(id);
        }
        // The process is gone; a grandchild may still hold the pipe open. Stop the mission's
        // orphans and give the readers time, then finish anyway instead of failing the queued
        // follow-up ("has not finished closing its output", which a user could only retry).
        if !run.ctx.output.wait_drained(Some(Duration::from_secs(2))) {
            stop_orphan_mission_processes(id);
            if !run.ctx.output.wait_drained(Some(Duration::from_secs(8))) {
                eprintln!("orb: local agent {id} output readers still open after stop; continuing");
            }
        }
        run.ctx.done.store(true, Ordering::SeqCst);
    } else if expected.is_none() {
        stop_orphan_mission_processes(id);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn completed_local_run_can_be_replaced_by_a_followup() {
        let request = StartRequest {
            service_tier: None,
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            image_paths: vec![],
            id: format!("followup-test-{}", uuid_like()),
            harness: "grok".into(),
            bin: "/usr/bin/true".into(),
            cwd: "/tmp".into(),
            prompt: "test".into(),
            model: None,
            session_id: None,
            shared_cwd_with: None,
        };
        local_agents_start(request.clone()).unwrap();
        let initial_generation = native_generation(&request.id).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !local_agents_poll(request.id.clone()).unwrap().done {
            assert!(Instant::now() < deadline, "fixture did not complete");
            thread::sleep(Duration::from_millis(10));
        }
        local_agents_start(request.clone()).expect("a finished run must not block a new turn");
        assert!(
            poll_generation(&request.id, Some(&initial_generation)).is_err(),
            "initial-origin sync must not consume the follow-up's output"
        );
        local_agents_stop(request.id).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn stale_transfer_heartbeat_cannot_stop_a_new_native_generation() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("agent");
        std::fs::write(&bin, "#!/bin/sh\nsleep 10\n").unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
        let id = format!("generation-test-{}", uuid_like());
        local_agents_start(StartRequest {
            service_tier: None,
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            id: id.clone(),
            harness: "grok".into(),
            bin: bin.to_string_lossy().into_owned(),
            cwd: dir.path().to_string_lossy().into_owned(),
            prompt: "test".into(),
            model: None,
            session_id: None,
            image_paths: vec![],
            shared_cwd_with: None,
        })
        .unwrap();
        let generation = native_generation(&id).unwrap();
        assert!(poll_generation(&id, Some("old-generation")).is_err());
        assert!(poll_generation(&id, Some(&generation)).is_ok());
        stop_generation(&id, Some("old-generation")).unwrap();
        assert!(!local_agents_poll(id.clone()).unwrap().done);
        stop_generation(&id, Some(&generation)).unwrap();
        assert!(local_agents_poll(id.clone()).unwrap().done);
        runs().lock().unwrap().remove(&id);
    }

    #[cfg(unix)]
    #[test]
    fn stop_closes_output_held_by_codex_and_claude_launcher_children() {
        use std::os::unix::fs::PermissionsExt;
        for harness in ["codex", "claudecode"] {
            let dir = tempfile::tempdir().unwrap();
            let bin = dir.path().join("launcher");
            std::fs::write(&bin, "#!/bin/sh\n[ \"$1\" = --version ] && { echo launcher 1.0.0; exit 0; }\nsleep 30 &\necho $! > child.pid\nwait\n").unwrap();
            std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
            let id = format!("stop-launcher-{}", uuid_like());
            local_agents_start(StartRequest {
                service_tier: None,
                effort: None,
                cyber_revision: None,
                cyber_access: None,
                id: id.clone(),
                harness: harness.into(),
                bin: bin.to_string_lossy().into_owned(),
                cwd: dir.path().to_string_lossy().into_owned(),
                prompt: "test".into(),
                model: None,
                session_id: None,
                image_paths: vec![],
                shared_cwd_with: None,
            })
            .unwrap();
            let deadline = Instant::now() + Duration::from_secs(5);
            while !dir.path().join("child.pid").exists() {
                assert!(Instant::now() < deadline, "launcher did not start");
                thread::sleep(Duration::from_millis(10));
            }
            let run = runs().lock().unwrap().get(&id).unwrap().clone();
            let pid = run.child.lock().unwrap().id() as i32;
            let group = unsafe { libc::getpgid(pid) };
            // Clean up even when checking the pre-fix implementation.
            if group != pid {
                if let Ok(child) = std::fs::read_to_string(dir.path().join("child.pid")) {
                    if let Ok(child) = child.trim().parse::<i32>() {
                        unsafe {
                            libc::kill(child, libc::SIGKILL);
                        }
                    }
                }
            }
            let stopped = local_agents_stop(id.clone());
            assert_eq!(group, pid, "{harness} inherited Orb's process group");
            stopped.unwrap();
            assert!(
                run.ctx.output.drained(),
                "{harness} left a reader waiting for EOF"
            );
            assert!(local_agents_poll(id.clone()).unwrap().done);
            runs().lock().unwrap().remove(&id);
        }
    }
}
