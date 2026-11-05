//! State-progress tool loop detector.
//!
//! Hashes `(normalized_command_without_comments, watched_file_tree_hash, exit_code)`
//! rather than exact raw shell argument strings so:
//! - comment spoofing (`lake env lean Foo.lean # step-01`, `# step-02`, `# step-03`)
//!   and cosmetic JSON wrapper fields (`description`, `timeout`, `toolSummary`)
//!   still collapse to the same normalized command key; and
//! - legitimate re-runs after `.lean` / source files changed (`watched_file_tree_hash`
//!   advanced, or a file-writing tool modified the workspace) or after `exit_code`
//!   changed (`1 -> 0`) are recognized as state progress instead of false-positive loops.

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::time::{Duration, Instant, UNIX_EPOCH};

/// Canonicalize tool names across harnesses (`Bash` / `bash` / `run_command` / `command_execution`).
pub fn canonical_tool_name(name: &str) -> String {
    let trimmed = name.trim();
    match trimmed.to_ascii_lowercase().as_str() {
        "bash" | "run_command" | "shell" | "exec_command" | "command_execution"
        | "workspace_bash" => "bash".to_string(),
        "edit" | "edit_file" | "multiedit" | "multi_edit" | "str_replace_editor" => {
            "edit".to_string()
        }
        "write" | "write_file" | "create_file" => "write".to_string(),
        "apply_patch" | "patch" | "file_change" => "apply_patch".to_string(),
        "notebookedit" | "notebook_edit" => "notebook_edit".to_string(),
        "" => "(unknown)".to_string(),
        other => other.to_string(),
    }
}

/// True when `tool_name` is a dedicated file-mutation tool whose completion
/// advances workspace state when explicit `watched_tree_hash` snapshots are absent.
pub fn is_workspace_mutating_tool(tool_name: &str) -> bool {
    matches!(
        canonical_tool_name(tool_name).as_str(),
        "edit" | "write" | "apply_patch" | "notebook_edit"
    )
}

/// Strip unquoted shell `# ...` comments (line-leading and trailing after whitespace
/// or command separators) while preserving `#` inside single quotes, double quotes,
/// `${#var}` parameter expansions, `$#`, and backslash-escaped `\#`. Collapses runs
/// of whitespace so minor formatting differences normalize identically.
pub fn normalize_shell_command(raw: &str) -> String {
    let mut stripped = String::with_capacity(raw.len());
    let chars: Vec<char> = raw.chars().collect();
    let mut i = 0usize;
    let mut in_single = false;
    let mut in_double = false;
    let mut brace_depth = 0usize;

    while i < chars.len() {
        let c = chars[i];
        if in_single {
            stripped.push(c);
            if c == '\'' {
                in_single = false;
            }
            i += 1;
            continue;
        }
        if c == '\\' && i + 1 < chars.len() {
            stripped.push(c);
            stripped.push(chars[i + 1]);
            i += 2;
            continue;
        }
        if in_double {
            if c == '"' {
                in_double = false;
            } else if c == '$' && i + 1 < chars.len() && chars[i + 1] == '{' {
                brace_depth += 1;
            } else if c == '}' && brace_depth > 0 {
                brace_depth -= 1;
            }
            stripped.push(c);
            i += 1;
            continue;
        }
        match c {
            '\'' => {
                in_single = true;
                stripped.push(c);
                i += 1;
            }
            '"' => {
                in_double = true;
                stripped.push(c);
                i += 1;
            }
            '$' if i + 1 < chars.len() && chars[i + 1] == '{' => {
                brace_depth += 1;
                stripped.push('$');
                stripped.push('{');
                i += 2;
            }
            '}' if brace_depth > 0 => {
                brace_depth -= 1;
                stripped.push('}');
                i += 1;
            }
            '#' if brace_depth == 0 => {
                // In POSIX sh/bash, `#` starts a comment at the start of input
                // or immediately after whitespace or an unquoted shell operator
                // (`;`, `&`, `|`, `(`, `)`, `\n`). Things like `$#` or `foo#bar`
                // are NOT comments.
                let prev = stripped.chars().last();
                let starts_comment = match prev {
                    None => true,
                    Some(p) => {
                        p.is_whitespace() || matches!(p, ';' | '&' | '|' | '(' | ')' | '\n' | '\r')
                    }
                };
                if starts_comment {
                    while i < chars.len() && chars[i] != '\n' {
                        i += 1;
                    }
                } else {
                    stripped.push('#');
                    i += 1;
                }
            }
            _ => {
                stripped.push(c);
                i += 1;
            }
        }
    }

    // Collapse whitespace lines/tokens into a canonical single-spaced form.
    let mut out = String::with_capacity(stripped.len());
    let mut pending_space = false;
    let mut pending_newline = false;
    for ch in stripped.chars() {
        if ch == '\n' || ch == '\r' {
            if !out.is_empty() {
                pending_newline = true;
            }
            pending_space = false;
        } else if ch.is_whitespace() {
            if !out.is_empty() && !pending_newline {
                pending_space = true;
            }
        } else {
            if pending_newline {
                out.push('\n');
                pending_newline = false;
            } else if pending_space {
                out.push(' ');
                pending_space = false;
            }
            out.push(ch);
        }
    }
    out.trim().to_string()
}

/// Extract a normalized, comment-stripped command or canonicalized argument
/// representation for `tool_call` loop detection. Returns `(normalized_key, display_snippet)`.
pub fn normalize_tool_call_args(tool_name: &str, args_raw: &str) -> (String, String) {
    let trimmed = args_raw.trim();
    let canon_tool = canonical_tool_name(tool_name);
    if let Ok(val) = serde_json::from_str::<Value>(trimmed) {
        if canon_tool == "bash" {
            if let Some(cmd) = val
                .get("command")
                .or_else(|| val.get("cmd"))
                .or_else(|| val.get("CommandLine"))
                .and_then(Value::as_str)
            {
                let norm = normalize_shell_command(cmd);
                return (norm.clone(), norm);
            }
            if let Some(argv) = val.get("command").and_then(Value::as_array) {
                let joined = argv
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(" ");
                let norm = normalize_shell_command(&joined);
                return (norm.clone(), norm);
            }
        }
        let cleaned = strip_cosmetic_json_fields(&val);
        let serialized = serde_json::to_string(&cleaned).unwrap_or_else(|_| trimmed.to_string());
        return (serialized.clone(), serialized);
    }
    if canon_tool == "bash" {
        let norm = normalize_shell_command(trimmed);
        return (norm.clone(), norm);
    }
    (trimmed.to_string(), trimmed.to_string())
}

fn strip_cosmetic_json_fields(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut sorted: BTreeMap<String, Value> = BTreeMap::new();
            for (k, v) in map {
                if matches!(
                    k.as_str(),
                    "description"
                        | "toolSummary"
                        | "timeout"
                        | "WaitMsBeforeAsync"
                        | "aggregated_output"
                        | "status"
                        | "id"
                ) {
                    continue;
                }
                sorted.insert(k.clone(), strip_cosmetic_json_fields(v));
            }
            Value::Object(sorted.into_iter().collect())
        }
        Value::Array(arr) => Value::Array(arr.iter().map(strip_cosmetic_json_fields).collect()),
        other => other.clone(),
    }
}

/// Extract an integer exit code from a `tool_result` JSON value, persisted
/// metadata, or human-readable output trailer (`[exit code 1]`, `Exit code: 1`).
pub fn extract_exit_code(result_content: &str, metadata: Option<&Value>) -> Option<i32> {
    if let Some(meta) = metadata {
        if let Some(code) = meta
            .get("exit_code")
            .or_else(|| meta.get("exit"))
            .and_then(Value::as_i64)
            .and_then(|v| i32::try_from(v).ok())
        {
            return Some(code);
        }
    }
    if let Ok(val) = serde_json::from_str::<Value>(result_content.trim()) {
        if let Some(code) = extract_exit_code_from_value(&val) {
            return Some(code);
        }
    }
    parse_exit_code_from_text(result_content)
}

/// Extract exit code from an `AgentEvent::ToolResult` `result: &Value`.
pub fn extract_exit_code_from_value(val: &Value) -> Option<i32> {
    for ptr in [
        "/exit_code",
        "/exitCode",
        "/exit",
        "/exit_status",
        "/metadata/exit",
        "/metadata/exit_code",
        "/state/metadata/exit",
        "/rawInput/exit_code",
    ] {
        if let Some(code) = val
            .pointer(ptr)
            .and_then(Value::as_i64)
            .and_then(|v| i32::try_from(v).ok())
        {
            return Some(code);
        }
    }
    for text_ptr in ["/output", "/stdout", "/content", "/result", "/error"] {
        if let Some(s) = val.pointer(text_ptr).and_then(Value::as_str) {
            if let Some(code) = parse_exit_code_from_text(s) {
                return Some(code);
            }
        }
    }
    if let Some(status) = val.get("status").and_then(Value::as_str) {
        if status == "failed" || status == "error" {
            return Some(1);
        }
        if status == "completed" && val.get("error").is_none_or(Value::is_null) {
            return Some(0);
        }
    }
    if let Some(s) = val.as_str() {
        return parse_exit_code_from_text(s);
    }
    None
}

fn parse_exit_code_from_text(text: &str) -> Option<i32> {
    let tail_start = text.len().saturating_sub(512);
    let mut idx = tail_start;
    while idx < text.len() && !text.is_char_boundary(idx) {
        idx += 1;
    }
    let tail = &text[idx..];
    for line in tail.lines().rev().take(8) {
        let trimmed = line.trim();
        for prefix in [
            "[exit code ",
            "Exit code: ",
            "exit code: ",
            "Command exited with code ",
            "Process exited with code ",
        ] {
            if let Some(rest) = trimmed.strip_prefix(prefix) {
                let digits: String = rest
                    .chars()
                    .take_while(|c| *c == '-' || c.is_ascii_digit())
                    .collect();
                if let Ok(code) = digits.parse::<i32>() {
                    return Some(code);
                }
            }
        }
    }
    None
}

/// Extract an explicit `watched_tree_hash` from a `tool_result` event's metadata
/// or structured JSON payload when available.
pub fn extract_watched_tree_hash(result_content: &str, metadata: Option<&Value>) -> Option<String> {
    if let Some(meta) = metadata {
        if let Some(h) = meta
            .get("watched_tree_hash")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            return Some(h.to_string());
        }
    }
    if let Ok(val) = serde_json::from_str::<Value>(result_content.trim()) {
        for ptr in [
            "/watched_tree_hash",
            "/metadata/watched_tree_hash",
            "/state/metadata/watched_tree_hash",
        ] {
            if let Some(h) = val
                .pointer(ptr)
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            {
                return Some(h.to_string());
            }
        }
    }
    None
}

/// Compute a fast, bounded content/metadata SHA-256 hash over watched source &
/// proof files (`.lean`, `.rs`, `.py`, `.ts`, `.tsx`, `.js`, `.toml`, `.json`,
/// `.yaml`, `.yml`, `.sh`, `.md`, `lakefile.*`, `lean-toolchain`) under `root`,
/// skipping build/cache directories (`.git`, `.lake`, `target`, `node_modules`,
/// `.scratch`, `.sandboxed-sh`, `.paloma`).
pub fn compute_watched_file_tree_hash(root: &Path) -> Option<String> {
    if !root.is_dir() {
        return None;
    }
    const MAX_FILES: usize = 4_000;
    const MAX_CONTENT_HASH_BYTES: u64 = 256 * 1024;
    let deadline = Instant::now() + Duration::from_millis(75);
    let mut entries: Vec<(String, [u8; 32])> = Vec::new();
    let mut stack = vec![root.to_path_buf()];

    while let Some(dir) = stack.pop() {
        if entries.len() >= MAX_FILES || Instant::now() >= deadline {
            break;
        }
        let Ok(rd) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in rd.flatten() {
            if entries.len() >= MAX_FILES || Instant::now() >= deadline {
                break;
            }
            let file_name = entry.file_name();
            let name = file_name.to_string_lossy();
            let Ok(ft) = entry.file_type() else {
                continue;
            };
            if ft.is_symlink() {
                continue;
            }
            let path = entry.path();
            if ft.is_dir() {
                if matches!(
                    name.as_ref(),
                    ".git"
                        | ".lake"
                        | "target"
                        | "node_modules"
                        | ".next"
                        | "dist"
                        | "build"
                        | ".scratch"
                        | ".sandboxed-sh"
                        | ".paloma"
                        | "__pycache__"
                        | ".venv"
                ) {
                    continue;
                }
                stack.push(path);
                continue;
            }
            if !ft.is_file() || !is_watched_source_file(&name) {
                continue;
            }
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            let rel = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            let mut file_hasher = Sha256::new();
            file_hasher.update(rel.as_bytes());
            file_hasher.update(b"\0");
            let len = meta.len();
            if len <= MAX_CONTENT_HASH_BYTES {
                if let Ok(bytes) = std::fs::read(&path) {
                    file_hasher.update(b"content:");
                    file_hasher.update(&bytes);
                } else {
                    hash_mtime_and_len(&mut file_hasher, &meta);
                }
            } else {
                hash_mtime_and_len(&mut file_hasher, &meta);
            }
            let digest: [u8; 32] = file_hasher.finalize().into();
            entries.push((rel, digest));
        }
    }

    entries.sort_by(|a, b| a.0.cmp(&b.0));
    let mut tree_hasher = Sha256::new();
    tree_hasher.update(b"orb-watched-tree-v1\0");
    for (rel, digest) in entries {
        tree_hasher.update(rel.as_bytes());
        tree_hasher.update(b"=");
        tree_hasher.update(digest);
        tree_hasher.update(b"\n");
    }
    Some(hex::encode(tree_hasher.finalize()))
}

fn hash_mtime_and_len(hasher: &mut Sha256, meta: &std::fs::Metadata) {
    let mtime_ns = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    hasher.update(b"stat:");
    hasher.update(meta.len().to_le_bytes());
    hasher.update(mtime_ns.to_le_bytes());
}

fn is_watched_source_file(name: &str) -> bool {
    if matches!(
        name,
        "lean-toolchain" | "lakefile.lean" | "lakefile.toml" | "Cargo.toml" | "Makefile"
    ) {
        return true;
    }
    let Some((_, ext)) = name.rsplit_once('.') else {
        return false;
    };
    matches!(
        ext.to_ascii_lowercase().as_str(),
        "lean"
            | "rs"
            | "py"
            | "ts"
            | "tsx"
            | "js"
            | "jsx"
            | "sol"
            | "go"
            | "c"
            | "cc"
            | "cpp"
            | "h"
            | "hpp"
            | "toml"
            | "json"
            | "yaml"
            | "yml"
            | "sh"
            | "md"
    )
}

/// Stable SHA-256 fingerprint of `(tool, normalized_command_without_comments, watched_tree_state, exit_code)`.
pub fn state_progress_fingerprint(
    canonical_tool: &str,
    normalized_cmd: &str,
    watched_state_token: &str,
    exit_code: Option<i32>,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"orb-loop-progress-v1\0");
    hasher.update(canonical_tool.as_bytes());
    hasher.update(b"\0");
    hasher.update(normalized_cmd.as_bytes());
    hasher.update(b"\0");
    hasher.update(watched_state_token.as_bytes());
    hasher.update(b"\0");
    match exit_code {
        Some(code) => hasher.update(format!("exit:{code}").as_bytes()),
        None => hasher.update(b"exit:unknown"),
    }
    hex::encode(hasher.finalize())
}

/// Detected repeat group from [`analyze_tool_call_progress`].
#[derive(Debug, Clone)]
pub struct RepeatedStateCall {
    pub fingerprint: String,
    pub tool: String,
    pub normalized_args: String,
    pub watched_tree_hash: Option<String>,
    pub exit_code: Option<i32>,
    pub repeats: usize,
}

/// Analyze an ascending slice of serialized trace `events` (`tool_call` + `tool_result`)
/// and group calls by `(canonical_tool, normalized_command_without_comments, watched_tree_state, exit_code)`.
///
/// State token resolution:
/// 1. When `tool_result` events carry `watched_tree_hash` (in `metadata` or JSON output),
///    that exact tree hash anchors the state token.
/// 2. When explicit `watched_tree_hash` is absent (e.g. legacy or remote traces without
///    tree snapshots), workspace-mutating tool calls (`Edit`, `Write`, `MultiEdit`,
///    `apply_patch`, or shell commands with file-writing operators / `git checkout` / `sed -i`)
///    advance an inferred `epoch:<n>` token so legitimate edit-then-retest cycles
///    never false-positive as loops, while `# step-XX` comment spoofing without file
///    edits shares the same epoch and is caught immediately.
pub fn analyze_tool_call_progress(events: &[Value]) -> Vec<RepeatedStateCall> {
    #[derive(Clone)]
    struct ResultInfo {
        exit_code: Option<i32>,
        watched_tree_hash: Option<String>,
        failed: bool,
    }

    let mut results_by_id: HashMap<String, ResultInfo> = HashMap::new();
    for event in events {
        if event.get("event_type").and_then(Value::as_str) == Some("tool_result") {
            if let Some(tc_id) = event.get("tool_call_id").and_then(Value::as_str) {
                let content = event.get("content").and_then(Value::as_str).unwrap_or("");
                let metadata = event.get("metadata");
                let exit_code = extract_exit_code(content, metadata);
                let watched_tree_hash = extract_watched_tree_hash(content, metadata);
                let failed = exit_code.is_some_and(|c| c != 0)
                    || content.contains("\"error\"")
                    || content.contains("\"status\":\"failed\"");
                results_by_id.insert(
                    tc_id.to_string(),
                    ResultInfo {
                        exit_code,
                        watched_tree_hash,
                        failed,
                    },
                );
            }
        }
    }

    let mut current_tree_hash: Option<String> = None;
    let mut inferred_epoch: u64 = 0;
    let mut groups: BTreeMap<String, RepeatedStateCall> = BTreeMap::new();

    for event in events {
        if event.get("event_type").and_then(Value::as_str) != Some("tool_call") {
            continue;
        }
        let raw_tool = event
            .get("tool_name")
            .and_then(Value::as_str)
            .unwrap_or("(unknown)");
        let canon_tool = canonical_tool_name(raw_tool);
        let raw_args = event.get("content").and_then(Value::as_str).unwrap_or("");
        let (norm_key, norm_display) = normalize_tool_call_args(raw_tool, raw_args);
        let tc_id = event.get("tool_call_id").and_then(Value::as_str);
        let res = tc_id.and_then(|id| results_by_id.get(id));

        // State BEFORE/AT this call: if the result attached an explicit post-call
        // `watched_tree_hash` and this call is read/build-only, adopt it immediately
        // when `current_tree_hash` wasn't initialized yet so the first build and
        // second build against the same tree share the same hash.
        let mutating_call = is_workspace_mutating_tool(raw_tool)
            || (canon_tool == "bash" && bash_command_likely_mutates_files(&norm_key));

        if current_tree_hash.is_none() && !mutating_call {
            if let Some(h) = res.and_then(|r| r.watched_tree_hash.as_ref()) {
                current_tree_hash = Some(h.clone());
            }
        }

        let state_token = match &current_tree_hash {
            Some(h) => format!("tree:{h}"),
            None => format!("epoch:{inferred_epoch}"),
        };
        let exit_code = res.and_then(|r| r.exit_code);
        let fp = state_progress_fingerprint(&canon_tool, &norm_key, &state_token, exit_code);

        let entry = groups
            .entry(fp.clone())
            .or_insert_with(|| RepeatedStateCall {
                fingerprint: fp,
                tool: raw_tool.to_string(),
                normalized_args: norm_display,
                watched_tree_hash: current_tree_hash.clone(),
                exit_code,
                repeats: 0,
            });
        entry.repeats += 1;

        // Advance workspace state after the call completes.
        if let Some(next_hash) = res.and_then(|r| r.watched_tree_hash.as_ref()) {
            current_tree_hash = Some(next_hash.clone());
        } else if mutating_call && !res.is_some_and(|r| r.failed) {
            inferred_epoch += 1;
        }
    }

    let mut out: Vec<RepeatedStateCall> = groups.into_values().collect();
    out.sort_by(|a, b| {
        b.repeats
            .cmp(&a.repeats)
            .then_with(|| a.fingerprint.cmp(&b.fingerprint))
    });
    out
}

fn bash_command_likely_mutates_files(normalized_cmd: &str) -> bool {
    // Only treat clear file-editing commands as workspace mutations when explicit
    // tree hashes are unavailable. Pure build/check invocations (`lake build`,
    // `lake env lean`, `cargo test`, `pytest`, `git status`, `cat`, `grep`) are
    // NOT treated as file mutations.
    for marker in [
        "cat >",
        "cat >>",
        "tee ",
        "sed -i",
        "perl -i",
        "perl -pi",
        "python3 -c",
        "python -c",
        "git apply",
        "git checkout",
        "git restore",
        "git reset",
        "git stash",
        "git cherry-pick",
        "patch ",
        "cp ",
        "mv ",
    ] {
        if normalized_cmd.contains(marker) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn strips_step_comments_while_preserving_quotes_and_param_expansions() {
        assert_eq!(
            normalize_shell_command("lake env lean Evm/Fast.lean # step-01"),
            "lake env lean Evm/Fast.lean"
        );
        assert_eq!(
            normalize_shell_command("lake   env   lean Evm/Fast.lean   # step-02 retry"),
            "lake env lean Evm/Fast.lean"
        );
        assert_eq!(
            normalize_shell_command("# header comment\nlake build Evm # trailing"),
            "lake build Evm"
        );
        // Quoted `#` and `${#arr[@]}` must stay intact!
        assert_eq!(
            normalize_shell_command("grep -n '# sorry' Evm/Fast.lean # step-99"),
            "grep -n '# sorry' Evm/Fast.lean"
        );
        assert_eq!(
            normalize_shell_command("echo \"a # not comment\" ${#foo} # real comment"),
            "echo \"a # not comment\" ${#foo}"
        );
    }

    #[test]
    fn comment_spoofed_lean_runs_collapse_into_loop_when_tree_and_exit_match() {
        let events = vec![
            json!({
                "event_type": "tool_call",
                "tool_call_id": "tc-1",
                "tool_name": "bash",
                "content": r#"{"command":"lake env lean Foo.lean # step-01","description":"try 1"}"#
            }),
            json!({
                "event_type": "tool_result",
                "tool_call_id": "tc-1",
                "content": "Foo.lean:12:4: error: unsolved goals\n[exit code 1]",
                "metadata": {"exit_code": 1, "watched_tree_hash": "aaa111"}
            }),
            json!({
                "event_type": "tool_call",
                "tool_call_id": "tc-2",
                "tool_name": "bash",
                "content": r#"{"command":"lake env lean Foo.lean # step-02","description":"try 2"}"#
            }),
            json!({
                "event_type": "tool_result",
                "tool_call_id": "tc-2",
                "content": "Foo.lean:12:4: error: unsolved goals\n[exit code 1]",
                "metadata": {"exit_code": 1, "watched_tree_hash": "aaa111"}
            }),
            json!({
                "event_type": "tool_call",
                "tool_call_id": "tc-3",
                "tool_name": "bash",
                "content": r#"{"command":"lake env lean Foo.lean # step-03","description":"try 3"}"#
            }),
            json!({
                "event_type": "tool_result",
                "tool_call_id": "tc-3",
                "content": "Foo.lean:12:4: error: unsolved goals\n[exit code 1]",
                "metadata": {"exit_code": 1, "watched_tree_hash": "aaa111"}
            }),
        ];
        let groups = analyze_tool_call_progress(&events);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].repeats, 3);
        assert_eq!(groups[0].exit_code, Some(1));
        assert_eq!(groups[0].normalized_args, "lake env lean Foo.lean");
    }

    #[test]
    fn legitimate_reruns_after_lean_file_changes_or_exit_code_change_do_not_loop() {
        // Explicit watched_tree_hash changes between runs -> each has repeats == 1.
        let events_with_tree_hash = vec![
            json!({
                "event_type": "tool_call",
                "tool_call_id": "tc-1",
                "tool_name": "bash",
                "content": r#"{"command":"lake env lean Foo.lean"}"#
            }),
            json!({
                "event_type": "tool_result",
                "tool_call_id": "tc-1",
                "content": "error",
                "metadata": {"exit_code": 1, "watched_tree_hash": "tree-v1"}
            }),
            json!({
                "event_type": "tool_call",
                "tool_call_id": "tc-edit-1",
                "tool_name": "edit",
                "content": r#"{"filePath":"Foo.lean","oldString":"simp","newString":"omega"}"#
            }),
            json!({
                "event_type": "tool_result",
                "tool_call_id": "tc-edit-1",
                "content": "ok",
                "metadata": {"exit_code": 0, "watched_tree_hash": "tree-v2"}
            }),
            json!({
                "event_type": "tool_call",
                "tool_call_id": "tc-2",
                "tool_name": "bash",
                "content": r#"{"command":"lake env lean Foo.lean"}"#
            }),
            json!({
                "event_type": "tool_result",
                "tool_call_id": "tc-2",
                "content": "error 2",
                "metadata": {"exit_code": 1, "watched_tree_hash": "tree-v2"}
            }),
            json!({
                "event_type": "tool_call",
                "tool_call_id": "tc-edit-2",
                "tool_name": "edit",
                "content": r#"{"filePath":"Foo.lean","oldString":"omega","newString":"ring"}"#
            }),
            json!({
                "event_type": "tool_result",
                "tool_call_id": "tc-edit-2",
                "content": "ok",
                "metadata": {"exit_code": 0, "watched_tree_hash": "tree-v3"}
            }),
            json!({
                "event_type": "tool_call",
                "tool_call_id": "tc-3",
                "tool_name": "bash",
                "content": r#"{"command":"lake env lean Foo.lean"}"#
            }),
            json!({
                "event_type": "tool_result",
                "tool_call_id": "tc-3",
                "content": "",
                "metadata": {"exit_code": 0, "watched_tree_hash": "tree-v3"}
            }),
        ];
        let groups = analyze_tool_call_progress(&events_with_tree_hash);
        assert!(
            groups.iter().all(|g| g.repeats < 3),
            "legitimate edit-rebuild cycle must not trigger loop: {groups:?}"
        );

        // Also verify fallback epoch advancement when no watched_tree_hash is attached.
        let events_without_hash = vec![
            json!({"event_type": "tool_call", "tool_call_id": "1", "tool_name": "Bash", "content": r#"{"command":"lake env lean Foo.lean"}"#}),
            json!({"event_type": "tool_result", "tool_call_id": "1", "content": "[exit code 1]"}),
            json!({"event_type": "tool_call", "tool_call_id": "2", "tool_name": "Edit", "content": r#"{"file_path":"Foo.lean"}"#}),
            json!({"event_type": "tool_result", "tool_call_id": "2", "content": "ok"}),
            json!({"event_type": "tool_call", "tool_call_id": "3", "tool_name": "Bash", "content": r#"{"command":"lake env lean Foo.lean"}"#}),
            json!({"event_type": "tool_result", "tool_call_id": "3", "content": "[exit code 1]"}),
            json!({"event_type": "tool_call", "tool_call_id": "4", "tool_name": "Edit", "content": r#"{"file_path":"Foo.lean"}"#}),
            json!({"event_type": "tool_result", "tool_call_id": "4", "content": "ok"}),
            json!({"event_type": "tool_call", "tool_call_id": "5", "tool_name": "Bash", "content": r#"{"command":"lake env lean Foo.lean"}"#}),
            json!({"event_type": "tool_result", "tool_call_id": "5", "content": "[exit code 0]"}),
        ];
        let fallback_groups = analyze_tool_call_progress(&events_without_hash);
        assert!(fallback_groups.iter().all(|g| g.repeats < 3));
    }

    #[test]
    fn watched_file_tree_hash_tracks_lean_edits_and_ignores_lake_cache() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".lake/build")).unwrap();
        std::fs::write(dir.path().join(".lake/build/Foo.olean"), b"binary-1").unwrap();
        std::fs::write(dir.path().join("Foo.lean"), "theorem t : True := trivial\n").unwrap();

        let h1 = compute_watched_file_tree_hash(dir.path()).unwrap();
        // Mutating `.lake` build artifacts must not change the watched source hash.
        std::fs::write(dir.path().join(".lake/build/Foo.olean"), b"binary-2").unwrap();
        let h2 = compute_watched_file_tree_hash(dir.path()).unwrap();
        assert_eq!(h1, h2);

        // Editing `.lean` source MUST change the watched source hash.
        std::fs::write(dir.path().join("Foo.lean"), "theorem t : 1 = 1 := rfl\n").unwrap();
        let h3 = compute_watched_file_tree_hash(dir.path()).unwrap();
        assert_ne!(h1, h3);
    }
}
