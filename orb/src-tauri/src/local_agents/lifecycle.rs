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
    crate::orb_log!(
        info,
        "run_started",
        mission = request.id,
        harness = request.harness,
        pid = lock(&run.child).id(),
        generation = run.generation,
        extra = json!({"resumed": resumed, "mcp_wrapped": run.mcp_wrapped})
    );
    watch_exit(
        software_execution,
        interaction,
        run.clone(),
        request.harness == "antigravity",
    );
    map.insert(request.id, run);
    Ok(())
}

/// Kill a child that may still run, then reap it. Failures are logged: a
/// child that cannot be reaped stays a zombie.
pub(crate) fn reap(child: &mut Child, mission: &str, why: &str) {
    let pid = child.id();
    if child.try_wait().ok().flatten().is_none() {
        if let Err(error) = child.kill() {
            crate::orb_log!(
                warn,
                "kill_failed",
                mission = mission,
                pid = pid,
                extra = json!({"why": why, "error": error.to_string()})
            );
        }
    }
    if let Err(error) = child.wait() {
        crate::orb_log!(
            warn,
            "reap_failed",
            mission = mission,
            pid = pid,
            extra = json!({"why": why, "error": error.to_string()})
        );
    }
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
        let (pid, status) = {
            let mut child = lock(child);
            (child.id(), child.wait().ok())
        };
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
        let error = run.ctx.error.get();
        crate::orb_log!(
            (if error.is_some() { "warn" } else { "info" }),
            "exit",
            mission = run.ctx.mission,
            harness = run.ctx.harness,
            pid = pid,
            generation = run.generation,
            extra = json!({
                "code": run.exit_code.get(),
                "raw_code": status.and_then(|status| status.code()),
                "signal": status.and_then(exit_signal),
                "stopped": run.stopped.load(Ordering::SeqCst),
                "error": error.as_deref().map(|e| e.chars().take(500).collect::<String>()),
            })
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
        let started = Instant::now();
        let mut path = Vec::new();
        let mut child = lock(&run.child);
        let pid = child.id();
        // The trusted wrapper owns the CLI's child process group. Give it
        // time to forward termination and reap that group before escalation.
        #[cfg(unix)]
        if run.mcp_wrapped && !run.is_done() {
            path.push("wrapper_sigterm");
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
            path.push("group_sigkill");
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
        }
        if child.try_wait().map_err(|e| e.to_string())?.is_none() {
            path.push("kill");
            child.kill().map_err(|e| e.to_string())?;
        }
        let status = child.wait().map_err(|e| e.to_string())?;
        let reaped_ms = started.elapsed().as_millis() as u64;
        run.exit_code.replace(status.code());
        drop(child);
        if expected.is_none() {
            stop_orphan_mission_processes(id);
        }
        // The process is gone; a grandchild may still hold the pipe open. Stop the mission's
        // orphans and give the readers time, then finish anyway instead of failing the queued
        // follow-up ("has not finished closing its output", which a user could only retry).
        let mut drained = run.ctx.output.wait_drained(Some(Duration::from_secs(2)));
        if !drained {
            path.push("orphans_after_drain_timeout");
            stop_orphan_mission_processes(id);
            drained = run.ctx.output.wait_drained(Some(Duration::from_secs(8)));
            if !drained {
                crate::orb_log!(
                    warn,
                    "stop_readers_open",
                    mission = id,
                    harness = run.ctx.harness,
                    pid = pid,
                    extra = json!({"message": "output readers still open after stop; continuing"})
                );
            }
        }
        if path.is_empty() {
            path.push("already_exited");
        }
        crate::orb_log!(
            info,
            "stop",
            mission = id,
            harness = run.ctx.harness,
            pid = pid,
            generation = run.generation,
            extra = json!({
                "path": path,
                "reaped_ms": reaped_ms,
                "total_ms": started.elapsed().as_millis() as u64,
                "drained": drained,
                "code": status.code(),
            })
        );
        run.ctx.done.store(true, Ordering::SeqCst);
    } else if expected.is_none() {
        stop_orphan_mission_processes(id);
    }
    Ok(())
}

/// Block until the run publishes its terminal state, then poll it. The
/// terminal event comes through the same subscription the client link uses,
/// so tests wait on an event instead of sleeping between polls.
#[cfg(test)]
pub(crate) fn wait_for_terminal(id: &str, timeout: Duration) -> PollState {
    let (sink, events) = std::sync::mpsc::channel();
    subscribe_native(id, sink).expect("the run exists");
    let deadline = Instant::now() + timeout;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        match events.recv_timeout(left) {
            Ok(event) if event.state.is_some() => break,
            Ok(_) => {}
            Err(_) => panic!("{id} did not finish within {timeout:?}"),
        }
    }
    poll_generation(id, None).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settled(
        harness: &str,
        strict: bool,
        stopped: bool,
        code: Option<i32>,
        signal: Option<i32>,
        diagnostic: Option<&str>,
        error: Option<&str>,
    ) -> (Option<i32>, Option<String>) {
        let ctx = RunCtx::new("settle", harness, None);
        if let Some(diagnostic) = diagnostic {
            ctx.output.set_diagnostic(diagnostic.into());
        }
        if let Some(error) = error {
            ctx.error.set(error.into());
        }
        let exit_code = Slot::new(code);
        settle_exit(&ctx, strict, stopped, signal, &exit_code);
        (exit_code.get(), ctx.error.get())
    }

    #[test]
    fn a_failed_process_is_labelled_with_its_own_harness() {
        assert_eq!(
            settled("opencode", false, false, Some(3), None, Some("boom"), None),
            (Some(3), Some("OpenCode process failed: boom".into()))
        );
        assert_eq!(
            settled(
                "claudecode",
                false,
                false,
                Some(9),
                None,
                Some("boom"),
                Some(harness::claude::STOPPED_WITHOUT_RESULT)
            ),
            (Some(9), Some("Claude process failed: boom".into()))
        );
        // A real protocol error is kept, and a success ignores stderr.
        assert_eq!(
            settled(
                "grok",
                false,
                false,
                Some(1),
                None,
                Some("noise"),
                Some("Rate limited")
            ),
            (Some(1), Some("Rate limited".into()))
        );
        assert_eq!(
            settled("codex", false, false, Some(0), None, Some("warning"), None),
            (Some(0), None)
        );
    }

    #[test]
    fn strict_terminal_keeps_a_crash_code_and_explains_it() {
        assert_eq!(
            settled("antigravity", true, false, Some(2), None, None, None),
            (Some(2), Some("Antigravity exited with code 2".into()))
        );
        assert_eq!(
            settled("antigravity", true, false, None, Some(11), None, None),
            (
                Some(1),
                Some("Antigravity was terminated by signal 11".into())
            )
        );
        // A parsed error fails even a clean exit, and keeps a real code.
        assert_eq!(
            settled(
                "antigravity",
                true,
                false,
                Some(0),
                None,
                None,
                Some("network")
            ),
            (Some(1), Some("network".into()))
        );
        assert_eq!(
            settled(
                "antigravity",
                true,
                false,
                Some(4),
                None,
                None,
                Some("network")
            ),
            (Some(4), Some("network".into()))
        );
        // Stop is deliberate: not reported as a crash.
        assert_eq!(
            settled("antigravity", true, true, None, Some(9), None, None),
            (Some(0), None)
        );
        assert_eq!(
            settled("antigravity", true, false, Some(0), None, None, None),
            (Some(0), None)
        );
    }

    #[cfg(unix)]
    #[test]
    fn strict_terminal_reports_a_silent_nonzero_exit_end_to_end() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("agy-fixture");
        // A resumed conversation that dies with code 3 and an empty stderr.
        std::fs::write(&bin, "#!/bin/sh\nexit 3\n").unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
        let request = StartRequest {
            id: format!("strict-exit-{}", uuid_like()),
            harness: "antigravity".into(),
            bin: bin.to_string_lossy().into_owned(),
            cwd: dir.path().to_string_lossy().into_owned(),
            prompt: "hello".into(),
            session_id: Some("native-session".into()),
            ..Default::default()
        };
        let ctx = RunCtx::new(&request.id, &request.harness, request.session_id.clone());
        let mut child = harness::spawn_harness(&request, &ctx, &[], &[]).unwrap();
        let status = child.wait().unwrap();
        assert!(ctx.output.wait_drained(Some(Duration::from_secs(5))));
        let exit_code = Slot::new(status.code());
        // The stream itself reports a missing result; without it, the
        // exit code alone must still read as a failure.
        ctx.error.replace(None);
        settle_exit(&ctx, true, false, exit_signal(status), &exit_code);
        assert_eq!(exit_code.get(), Some(3));
        assert_eq!(
            ctx.error.get().as_deref(),
            Some("Antigravity exited with code 3")
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_poisoned_slot_does_not_hang_the_exit_watcher() {
        let id = format!("poisoned-{}", uuid_like());
        let ctx = RunCtx::new(&id, "grok", None);
        let child = Command::new("/bin/sh")
            .args(["-c", "exit 5"])
            .spawn()
            .unwrap();
        let run = Run::new(ctx.clone(), child, PathBuf::from("/tmp"), false);
        let code = run.exit_code.clone();
        let _ = thread::spawn(move || code.update(|_| panic!("poison"))).join();
        let error = ctx.error.clone();
        let _ = thread::spawn(move || error.update(|_| panic!("poison"))).join();
        let _ = {
            let child = Arc::clone(&run.child);
            thread::spawn(move || {
                let _guard = child.lock().unwrap();
                panic!("poison the child");
            })
            .join()
        };
        assert!(run.child.is_poisoned());
        lock(runs()).insert(id.clone(), run.clone());
        watch_exit(
            crate::agent_software::begin(&id, "grok", None).unwrap(),
            crate::interactions::begin(&id),
            run.clone(),
            false,
        );
        let state = wait_for_terminal(&id, Duration::from_secs(5));
        assert!(state.done);
        assert_eq!(state.exit_code, Some(5));
        lock(runs()).remove(&id);
    }

    #[test]
    fn finished_runs_beyond_the_cap_are_pruned_oldest_first() {
        let prefix = format!("prune-{}", uuid_like());
        let ids: Vec<String> = (0..KEPT_FINISHED_RUNS + 3)
            .map(|n| format!("{prefix}-{n}"))
            .collect();
        // Older than any run another test finishes meanwhile, so only these
        // are pruned.
        let hour_ago = Instant::now() - Duration::from_secs(3600);
        for (n, id) in ids.iter().enumerate() {
            let child = Command::new("true").spawn().unwrap();
            let run = Run::new(
                RunCtx::new(id, "grok", None),
                child,
                PathBuf::from("/tmp"),
                false,
            );
            run.ctx.done.store(true, Ordering::SeqCst);
            let _ = run.finished.set(hour_ago + Duration::from_secs(n as u64));
            reap(&mut lock(&run.child), id, "test");
            lock(runs()).insert(id.clone(), run);
        }
        let running = format!("{prefix}-running");
        let child = Command::new("true").spawn().unwrap();
        let live = Run::new(
            RunCtx::new(&running, "grok", None),
            child,
            PathBuf::from("/tmp"),
            false,
        );
        reap(&mut lock(&live.child), &running, "test");
        lock(runs()).insert(running.clone(), live);
        let untouched_fence = launch_fence(&format!("{prefix}-fence"));
        *lock(&launch_fence(&format!("{prefix}-stopped"))) += 1;
        drop(untouched_fence);
        prune_finished_runs();
        let map = lock(runs());
        assert!(map.contains_key(&running), "a live run is never pruned");
        // Other tests may finish runs concurrently: only this test's oldest
        // runs must be gone, and its newest kept.
        assert!(!map.contains_key(&ids[0]));
        assert!(map.contains_key(ids.last().unwrap()));
        drop(map);
        let fences = lock(fences());
        assert!(!fences.contains_key(&format!("{prefix}-fence")));
        assert!(
            fences.contains_key(&format!("{prefix}-stopped")),
            "an advanced fence persists"
        );
        drop(fences);
        let mut map = lock(runs());
        map.retain(|id, _| !id.starts_with(&prefix));
    }

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
        assert!(
            wait_for_terminal(&request.id, Duration::from_secs(3)).done,
            "fixture did not complete"
        );
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
