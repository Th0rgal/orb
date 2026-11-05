//! Linux `/proc` process-tree inspection and child-tool `SIGINT` helpers.
//!
//! Used by both `sandboxed-node` (`JobRunner::interrupt_job`) and local
//! runners (`live_session::interrupt_child_tools`) to distinguish the long-lived
//! harness process (`opencode`, `claude`, `codex`, `grok`, `agy`, `vibe-acp`)
//! from its descendant child tool processes (`bash`, `lake`, `lean`, `cargo`,
//! `python`, `git`, `sleep`, etc.) without ever signaling the harness PID or
//! its MCP stdio sidecars.

#[cfg(target_os = "linux")]
use std::collections::{HashMap, HashSet};

#[cfg(target_os = "linux")]
#[derive(Debug, Clone)]
struct ProcEntry {
    ppid: u32,
    comm: String,
    cmdline: String,
}

#[cfg(target_os = "linux")]
fn read_proc_table() -> HashMap<u32, ProcEntry> {
    let mut table = HashMap::new();
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return table;
    };
    for entry in entries.flatten() {
        let Some(pid_str) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        let Ok(pid) = pid_str.parse::<u32>() else {
            continue;
        };
        let Ok(stat) = std::fs::read_to_string(entry.path().join("stat")) else {
            continue;
        };
        let Some(open_idx) = stat.find('(') else {
            continue;
        };
        let Some(close_idx) = stat.rfind(") ") else {
            continue;
        };
        let comm = stat[open_idx + 1..close_idx].to_string();
        let rest = &stat[close_idx + 2..];
        let mut fields = rest.split_whitespace();
        let state = fields.next().unwrap_or("");
        if matches!(state, "Z" | "X") {
            continue;
        }
        let Some(ppid) = fields.next().and_then(|s| s.parse::<u32>().ok()) else {
            continue;
        };
        let cmdline = std::fs::read(entry.path().join("cmdline"))
            .ok()
            .map(|bytes| {
                bytes
                    .split(|b| *b == 0)
                    .filter(|s| !s.is_empty())
                    .map(|s| String::from_utf8_lossy(s).into_owned())
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .unwrap_or_default();
        table.insert(
            pid,
            ProcEntry {
                ppid,
                comm,
                cmdline,
            },
        );
    }
    table
}

#[cfg(target_os = "linux")]
fn is_harness_entry(entry: &ProcEntry) -> bool {
    let comm = entry.comm.as_str();
    let cmd = entry.cmdline.as_str();
    if matches!(
        comm,
        "opencode" | "claude" | "codex" | "grok" | "agy" | "antigravity" | "vibe-acp"
    ) {
        return true;
    }
    if matches!(comm, "node" | "bun")
        && (cmd.contains("opencode")
            || cmd.contains("claude")
            || cmd.contains("codex")
            || cmd.contains("grok")
            || cmd.contains("antigravity")
            || cmd.contains("agy"))
    {
        return true;
    }
    false
}

#[cfg(target_os = "linux")]
fn is_auxiliary_harness_helper(entry: &ProcEntry) -> bool {
    let comm = entry.comm.as_str();
    let cmd = entry.cmdline.as_str();
    // Never signal MCP stdio sidecars, credential wrappers, or PTY/stdin plumbing.
    if comm.contains("mcp")
        || cmd.contains("sandboxed-mcp")
        || cmd.contains("control_mcp")
        || cmd.contains("mcp-stdio")
        || cmd.contains("--mcp")
    {
        return true;
    }
    if comm == "cat" && (cmd == "cat" || cmd.starts_with("cat ")) {
        return true;
    }
    if matches!(
        comm,
        "systemd-run" | "nsenter" | "script" | "sandboxed-launch"
    ) {
        return true;
    }
    if cmd.contains(".sandboxed-sh-opencode-cmd.sh") || cmd.contains("orb-native-plan") {
        return true;
    }
    false
}

/// Collect PIDs of active child tool processes running below `root_pid` (and any
/// additional root PIDs discovered via a systemd scope unit).
#[cfg(target_os = "linux")]
pub fn collect_inflight_child_tool_pids(root_pid: u32, scope_unit: Option<&str>) -> Vec<u32> {
    let table = read_proc_table();
    if table.is_empty() {
        return Vec::new();
    }
    let mut children_map: HashMap<u32, Vec<u32>> = HashMap::new();
    for (&pid, info) in &table {
        children_map.entry(info.ppid).or_default().push(pid);
    }

    let mut subtree = HashSet::new();
    let mut stack = vec![root_pid];
    if let Some(unit) = scope_unit {
        for pid in pids_in_systemd_unit(unit) {
            if table.contains_key(&pid) {
                stack.push(pid);
            }
        }
    }
    while let Some(pid) = stack.pop() {
        if subtree.insert(pid) {
            if let Some(kids) = children_map.get(&pid) {
                stack.extend(kids.iter().copied());
            }
        }
    }
    if subtree.is_empty() {
        return Vec::new();
    }

    // Locate any harness processes in the subtree.
    let harness_pids: HashSet<u32> = subtree
        .iter()
        .copied()
        .filter(|pid| table.get(pid).is_some_and(is_harness_entry))
        .collect();

    let mut candidate_roots = Vec::new();
    if !harness_pids.is_empty() {
        for &hpid in &harness_pids {
            if let Some(kids) = children_map.get(&hpid) {
                for &kid in kids {
                    if !harness_pids.contains(&kid) {
                        candidate_roots.push(kid);
                    }
                }
            }
        }
    } else {
        // Raw shell / mock harness in tests (`bash -lc "..."`) or systemd scope unit:
        // inspect non-root processes in the subtree so `sleep` / `lake` child tools
        // are caught even if reparented inside a transient systemd scope.
        candidate_roots.extend(subtree.iter().copied().filter(|&p| p != root_pid));
    }

    let mut tool_pids = Vec::new();
    let mut seen_tools = HashSet::new();
    let mut tool_stack = candidate_roots;
    while let Some(pid) = tool_stack.pop() {
        if !seen_tools.insert(pid) || pid == root_pid || harness_pids.contains(&pid) {
            continue;
        }
        let Some(entry) = table.get(&pid) else {
            continue;
        };
        if is_auxiliary_harness_helper(entry) {
            // Still traverse below wrapper shells (`script`, `.sandboxed-sh-opencode-cmd.sh`)
            // only if we had no explicit harness PID; when `harness_pids` is non-empty,
            // auxiliary helpers (like MCP servers) and their children are skipped completely.
            if harness_pids.is_empty() {
                if let Some(kids) = children_map.get(&pid) {
                    tool_stack.extend(kids.iter().copied());
                }
            }
            continue;
        }
        tool_pids.push(pid);
        if let Some(kids) = children_map.get(&pid) {
            tool_stack.extend(kids.iter().copied());
        }
    }
    tool_pids.sort_unstable();
    tool_pids
}

#[cfg(not(target_os = "linux"))]
pub fn collect_inflight_child_tool_pids(_root_pid: u32, _scope_unit: Option<&str>) -> Vec<u32> {
    Vec::new()
}

pub fn has_inflight_child_tools(root_pid: u32, scope_unit: Option<&str>) -> bool {
    !collect_inflight_child_tool_pids(root_pid, scope_unit).is_empty()
}

/// Send `SIGINT` to all in-flight child tool processes (never to `root_pid` or
/// the harness process itself). Returns the number of signaled PIDs.
pub fn sigint_inflight_child_tools(root_pid: u32, scope_unit: Option<&str>) -> usize {
    #[cfg(unix)]
    {
        let pids = collect_inflight_child_tool_pids(root_pid, scope_unit);
        let mut signalled = 0usize;
        // Signal deepest/highest PIDs first so leaf tools (`lean`, `lake`, `sleep`)
        // receive SIGINT simultaneously with their subshell (`bash -c`).
        for pid in pids.into_iter().rev() {
            if pid > 1 {
                let rc = unsafe { libc::kill(pid as i32, libc::SIGINT) };
                if rc == 0 {
                    signalled += 1;
                }
            }
        }
        signalled
    }
    #[cfg(not(unix))]
    {
        let _ = (root_pid, scope_unit);
        0
    }
}

#[cfg(target_os = "linux")]
fn pids_in_systemd_unit(unit: &str) -> Vec<u32> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return out;
    };
    let needle = format!("/{unit}");
    for entry in entries.flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|s| s.parse::<u32>().ok())
        else {
            continue;
        };
        if let Ok(cg) = std::fs::read_to_string(entry.path().join("cgroup")) {
            if cg.lines().any(|line| line.ends_with(&needle)) {
                out.push(pid);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn sigint_inflight_child_tools_interrupts_child_without_killing_parent() {
        // Parent shell acts as a stand-in harness that traps/survives child exit
        // and records a marker after its `sleep 30` child tool is interrupted.
        let mut parent = tokio::process::Command::new("bash")
            .arg("-c")
            .arg("sleep 30; code=$?; printf 'child_exit=%d\\n' \"$code\"; sleep 2")
            .stdout(std::process::Stdio::piped())
            .spawn()
            .expect("spawn parent");
        let root_pid = parent.id().expect("parent pid");

        // Wait until the `sleep 30` child tool appears in `/proc`.
        for _ in 0..40 {
            if has_inflight_child_tools(root_pid, None) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
        assert!(has_inflight_child_tools(root_pid, None));

        let count = sigint_inflight_child_tools(root_pid, None);
        assert!(count >= 1, "expected at least 1 signalled child PID");

        // Wait briefly: child `sleep 30` should exit, while `parent` stays alive in `sleep 2`
        // or finishes cleanly without `parent` itself receiving SIGINT directly.
        tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        assert!(
            parent.try_wait().unwrap().is_none(),
            "parent harness process must still be alive after child tool SIGINT"
        );
        let _ = parent.kill().await;
    }
}
