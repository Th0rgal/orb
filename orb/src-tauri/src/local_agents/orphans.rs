//! Harness processes a mission left behind: found by their argv, stopped
//! with the mission, or followed again after an Orb restart (Antigravity).

use super::*;

pub(crate) fn find_orphan_mission_pids(id: &str, session_id: Option<&str>) -> Vec<u32> {
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};
    let mut system = System::new();
    system.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::new()
            .with_cmd(UpdateKind::Always)
            .with_exe(UpdateKind::Always),
    );
    let session = session_id.map(str::trim).filter(|s| !s.is_empty());
    let mut pids = Vec::new();
    for (pid, proc_info) in system.processes() {
        let pid_u32 = pid.as_u32();
        if pid_u32 == std::process::id() {
            continue;
        }
        let cmd: Vec<String> = proc_info
            .cmd()
            .iter()
            .map(|s| s.to_string_lossy().into_owned())
            .collect();
        if cmd.is_empty() {
            continue;
        }
        let matches_mission = uuid::Uuid::parse_str(id).is_ok()
            && cmd
                .windows(2)
                .any(|pair| pair[0] == "--mission-id" && pair[1] == id);
        let matches_session = session.is_some_and(|sid| {
            cmd.windows(2).any(|pair| {
                matches!(
                    pair[0].as_str(),
                    "--conversation" | "--resume" | "--session" | "--session-id"
                ) && pair[1] == sid
            })
        });
        if matches_mission || matches_session {
            pids.push(pid_u32);
        }
    }
    pids
}

pub(crate) fn has_orphan_mission_processes(id: &str) -> bool {
    let session_id = crate::local_bindings(None, None)
        .ok()
        .and_then(|b| b[id]["sessionId"].as_str().map(str::to_owned));
    !find_orphan_mission_pids(id, session_id.as_deref()).is_empty()
}

pub(crate) fn stop_orphan_mission_processes(id: &str) {
    let session_id = crate::local_bindings(None, None)
        .ok()
        .and_then(|b| b[id]["sessionId"].as_str().map(str::to_owned));
    let pids = find_orphan_mission_pids(id, session_id.as_deref());
    if pids.is_empty() {
        return;
    }
    crate::orb_log!(
        warn,
        "orphan_kill",
        mission = id,
        extra = json!({"pids": pids, "signal": "SIGTERM"})
    );
    #[cfg(unix)]
    {
        for &pid in &pids {
            unsafe {
                libc::kill(pid as i32, libc::SIGTERM);
                libc::kill(-(pid as i32), libc::SIGTERM);
            }
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if find_orphan_mission_pids(id, session_id.as_deref()).is_empty() {
                return;
            }
            thread::sleep(Duration::from_millis(50));
        }
        crate::orb_log!(
            warn,
            "orphan_kill",
            mission = id,
            extra = json!({"pids": pids, "signal": "SIGKILL"})
        );
        for &pid in &pids {
            unsafe {
                libc::kill(pid as i32, libc::SIGKILL);
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
        }
    }
}

/// Follow an Antigravity conversation still running from before a restart.
pub(crate) fn reattach_if_orphaned(id: &str) {
    // Most unknown ids are simply not running: only a reattach is news.
    if try_reattach_orphan_antigravity(id) {
        crate::orb_log!(
            info,
            "reattach",
            mission = id,
            harness = "antigravity",
            extra = json!({"outcome": "following"})
        );
    }
}

pub(crate) fn try_reattach_orphan_antigravity(id: &str) -> bool {
    let Ok(bindings) = crate::local_bindings(None, None) else {
        return false;
    };
    let binding = &bindings[id];
    if binding["harness"].as_str() != Some("antigravity") {
        return false;
    }
    let Some(session) = binding["sessionId"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
    else {
        return false;
    };
    let Some(cwd_str) = binding["cwd"].as_str().filter(|s| !s.is_empty()) else {
        return false;
    };
    let pids = find_orphan_mission_pids(id, Some(&session));
    if pids.is_empty() {
        return false;
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return false;
    };
    let transcript_path = home
        .join(".gemini/antigravity-cli/brain")
        .join(&session)
        .join(".system_generated/logs/transcript.jsonl");
    if !transcript_path.is_file() {
        return false;
    }
    let Ok(mut map) = runs().lock() else {
        return false;
    };
    if map.contains_key(id) {
        return true;
    }
    let dummy_child = match Command::new("sh")
        .args(["-c", "while :; do sleep 3600; done"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(error) => {
            crate::orb_log!(
                error,
                "reattach",
                mission = id,
                harness = "antigravity",
                extra = json!({"outcome": "placeholder_spawn_failed", "error": error.to_string()})
            );
            return false;
        }
    };
    let ctx = RunCtx::new(id, "antigravity", Some(session.clone()));
    let run = Run::new(ctx.clone(), dummy_child, PathBuf::from(cwd_str), true);
    map.insert(id.to_owned(), run.clone());
    drop(map);

    let mission_id = id.to_owned();
    let guard = ctx.output.reader();
    thread::spawn(move || {
        let _guard = guard;
        let text = &ctx.output;
        let done = &ctx.done;
        let mut thoughts = crate::antigravity::thoughts::Reader::new(&home);
        let mut seen_steps = std::collections::HashSet::<u64>::new();
        let mut floor_step: Option<u64> = None;
        let mut latest_text = String::new();
        let mut stream = crate::antigravity::Stream::default();
        stream.session = Some(session.clone());
        text.antigravity_progress(&stream);
        text.publish_activities();

        loop {
            if let Ok(content) = std::fs::read_to_string(&transcript_path) {
                let entries: Vec<Value> = content
                    .lines()
                    .filter_map(|l| serde_json::from_str::<Value>(l).ok())
                    .collect();
                if floor_step.is_none() {
                    floor_step = entries
                        .iter()
                        .rev()
                        .find(|e| e["type"] == "USER_INPUT")
                        .and_then(|e| e["step_index"].as_u64());
                    if let Some(floor) = floor_step {
                        thoughts.observe(&json!({
                            "event": "step_update",
                            "step_update": {
                                "conversation_id": session,
                                "step_index": floor
                            }
                        }));
                    }
                }
                if let Some(floor) = floor_step {
                    let mut changed = false;
                    for entry in entries
                        .iter()
                        .filter(|e| e["step_index"].as_u64().is_some_and(|idx| idx > floor))
                    {
                        let Some(idx) = entry["step_index"].as_u64() else {
                            continue;
                        };
                        let status = entry["status"].as_str().unwrap_or("");
                        let step_type = entry["type"].as_str().unwrap_or("");
                        let is_done = matches!(status, "DONE" | "ERROR");
                        if step_type == "PLANNER_RESPONSE" {
                            if let Some(c) = entry["content"]
                                .as_str()
                                .map(str::trim)
                                .filter(|s| !s.is_empty())
                            {
                                if latest_text != c {
                                    latest_text = c.to_owned();
                                    text.replace(latest_text.clone());
                                }
                            }
                            if let Some(tools) = entry["tool_calls"].as_array() {
                                if !tools.is_empty() && seen_steps.insert(idx) {
                                    let tool = &tools[0];
                                    let name = tool["name"].as_str().unwrap_or("tool");
                                    let call_id = format!("{session}:{idx}");
                                    text.native_activity(&json!({
                                        "type": "tool_call",
                                        "toolCallId": call_id,
                                        "name": name,
                                        "toolName": name,
                                        "rawInput": tool["args"]
                                    }));
                                    changed = true;
                                }
                            }
                            if let Some(thinking) = entry["thinking"]
                                .as_str()
                                .map(str::trim)
                                .filter(|s| !s.is_empty())
                            {
                                let first_line = thinking
                                    .lines()
                                    .find(|l| !l.trim().is_empty())
                                    .unwrap_or("Thinking");
                                text.antigravity_thought(&json!({
                                    "conversation_id": session,
                                    "step_index": idx,
                                    "text": first_line,
                                    "done": is_done
                                }));
                                changed = true;
                            }
                        } else if step_type == "GENERIC" && is_done && seen_steps.insert(idx) {
                            let prev_idx = idx.saturating_sub(1);
                            let call_id = format!("{session}:{prev_idx}");
                            text.native_activity(&json!({
                                "type": "tool_call_update",
                                "toolCallId": call_id,
                                "status": if status == "ERROR" { "failed" } else { "completed" },
                                "rawOutput": entry["content"]
                            }));
                            changed = true;
                        }
                    }
                    for event in thoughts.poll() {
                        text.antigravity_thought(&event);
                        changed = true;
                    }
                    if changed {
                        text.publish_activities();
                    }
                }
            }
            let alive = !find_orphan_mission_pids(&mission_id, Some(&session)).is_empty();
            if !alive || done.load(Ordering::SeqCst) {
                break;
            }
            thread::sleep(Duration::from_millis(500));
        }
        stream.reconcile_orphan_transcript_turn(&home, floor_step);
        text.antigravity_progress(&stream);
        text.publish_activities();
        reap(
            &mut crate::sync_util::lock(&run.child),
            &mission_id,
            "reattach placeholder",
        );
        if let Err(message) = stream.finish() {
            ctx.error.set_if_none(message);
        }
        let failed = ctx.error.is_some();
        run.exit_code.update(|code| {
            if failed {
                *code = Some(1);
            } else if code.is_none() {
                *code = Some(0);
            }
        });
        done.store(true, Ordering::SeqCst);
        let _ = run.finished.set(Instant::now());
        let mut final_state = run.snapshot(stream.is_retryable(), None);
        final_state.done = true;
        text.finish(final_state);
        prune_finished_runs();
    });
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn find_orphan_mission_pids_returns_empty_for_unknown_ids() {
        let mission = uuid::Uuid::new_v4().to_string();
        let session = uuid::Uuid::new_v4().to_string();
        let pids = find_orphan_mission_pids(&mission, Some(&session));
        assert!(pids.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn stopping_orphans_spares_unrelated_process_groups() {
        use std::os::unix::process::CommandExt;
        let mission = uuid::Uuid::new_v4().to_string();
        let group = |args: &[&str]| {
            let mut command = Command::new("/bin/sh");
            command.args(args).process_group(0);
            command.spawn().unwrap()
        };
        // The orphan names the mission in its argv and leads a group with a
        // child of its own; the bystander leads another group.
        let mut orphan = group(&["-c", "sleep 30 & wait", "orphan", "--mission-id", &mission]);
        let mut bystander = group(&[
            "-c",
            "sleep 30 & wait",
            "bystander",
            "--mission-id",
            "other",
        ]);
        let deadline = Instant::now() + Duration::from_secs(5);
        while find_orphan_mission_pids(&mission, None).is_empty() {
            assert!(Instant::now() < deadline, "the orphan never appeared");
            thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(find_orphan_mission_pids(&mission, None), vec![orphan.id()]);
        stop_orphan_mission_processes(&mission);
        let status = orphan.wait().unwrap();
        assert!(!status.success(), "the orphan was signalled");
        let orphan_group = orphan.id() as i32;
        let deadline = Instant::now() + Duration::from_secs(5);
        // Its group (the background sleep) goes with it.
        while unsafe { libc::kill(-orphan_group, 0) } == 0 {
            assert!(Instant::now() < deadline, "the orphan's group survived");
            thread::sleep(Duration::from_millis(20));
        }
        assert!(
            bystander.try_wait().unwrap().is_none(),
            "an unrelated group was signalled"
        );
        assert_eq!(unsafe { libc::kill(-(bystander.id() as i32), 0) }, 0);
        unsafe {
            libc::kill(-(bystander.id() as i32), libc::SIGKILL);
        }
        let _ = bystander.wait();
    }
}
