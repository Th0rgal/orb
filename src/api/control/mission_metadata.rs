//! Mission title/description extraction, metadata refresh scheduling and title de-duplication.

use super::*;

/// Returns a safe index to truncate a string at, ensuring we don't cut UTF-8 characters.
pub(crate) fn safe_truncate_index(s: &str, max: usize) -> usize {
    if s.len() <= max {
        return s.len();
    }
    // Find a char boundary at or before max
    let mut idx = max;
    while idx > 0 && !s.is_char_boundary(idx) {
        idx -= 1;
    }
    idx
}

/// Derive a human-readable activity label from a tool call.
pub(super) fn activity_label_from_tool_call(tool_name: &str, args: &serde_json::Value) -> String {
    fn extract_str<'a>(args: &'a serde_json::Value, keys: &[&str]) -> Option<&'a str> {
        for key in keys {
            if let Some(v) = args.get(*key).and_then(|v| v.as_str()) {
                return Some(v);
            }
        }
        None
    }

    fn basename(path: &str) -> &str {
        std::path::Path::new(path)
            .file_name()
            .and_then(|f| f.to_str())
            .unwrap_or(path)
    }

    fn truncate(s: &str, max: usize) -> String {
        if s.len() <= max {
            s.to_string()
        } else {
            let end = safe_truncate_index(s, max);
            format!("{}…", &s[..end])
        }
    }

    match tool_name {
        "Bash" | "bash" => {
            let cmd = extract_str(args, &["command"]).unwrap_or("…");
            let first_line = cmd.lines().next().unwrap_or(cmd);
            format!("Running: {}", truncate(first_line, 60))
        }
        "Read" | "read_file" => {
            let path = extract_str(args, &["file_path", "path"]).unwrap_or("…");
            format!("Reading: {}", basename(path))
        }
        "Edit" | "edit_file" => {
            let path = extract_str(args, &["file_path", "path"]).unwrap_or("…");
            format!("Editing: {}", basename(path))
        }
        "Write" | "write_file" => {
            let path = extract_str(args, &["file_path", "path"]).unwrap_or("…");
            format!("Writing: {}", basename(path))
        }
        "Grep" | "grep" | "search" => {
            let pattern = extract_str(args, &["pattern"]).unwrap_or("…");
            format!("Searching: {}", truncate(pattern, 40))
        }
        "Glob" | "glob" => {
            let pattern = extract_str(args, &["pattern"]).unwrap_or("…");
            format!("Finding: {}", truncate(pattern, 50))
        }
        "WebSearch" | "web_search" => {
            let query = extract_str(args, &["query"]).unwrap_or("…");
            format!("Searching web: {}", truncate(query, 40))
        }
        "WebFetch" | "web_fetch" => "Fetching web page".to_string(),
        "Task" | "delegate_task" => {
            let desc = extract_str(args, &["description", "prompt", "subject"]).unwrap_or("…");
            format!("Subtask: {}", truncate(desc, 80))
        }
        "TaskCreate" => {
            let desc = extract_str(args, &["subject", "description"]).unwrap_or("…");
            format!("Creating task: {}", truncate(desc, 80))
        }
        "Skill" => {
            let skill = extract_str(args, &["skill"]).unwrap_or("…");
            format!("Running skill: {}", skill)
        }
        "AskUserQuestion" => "Waiting for input".to_string(),
        "NotebookEdit" => {
            let path = extract_str(args, &["notebook_path"]).unwrap_or("…");
            format!("Editing notebook: {}", basename(path))
        }
        name if name.starts_with("mcp__") => {
            let parts: Vec<&str> = name.splitn(3, "__").collect();
            if parts.len() == 3 {
                format!("{}: {}", parts[1], parts[2])
            } else {
                format!("Tool: {}", name)
            }
        }
        other => format!("Tool: {}", other),
    }
}

/// Extract a concise title from the assistant's first response.
/// Returns the first substantive line, cleaned of markdown formatting.
pub(super) fn extract_title_from_assistant(content: &str) -> Option<String> {
    let lines: Vec<&str> = content.lines().collect();
    let mut inside_fenced_block: Option<char> = None;
    let mut first_line: Option<&str> = None;
    for idx in 0..lines.len() {
        let line = lines[idx].trim();
        if let Some(fence_char) = markdown_fence_char(line) {
            if inside_fenced_block == Some(fence_char) {
                inside_fenced_block = None;
                continue;
            }
            if inside_fenced_block.is_none() {
                let has_closing_fence = lines[(idx + 1)..]
                    .iter()
                    .any(|candidate| markdown_fence_char(candidate.trim()) == Some(fence_char));
                if has_closing_fence {
                    inside_fenced_block = Some(fence_char);
                }
                continue;
            }
        }
        if inside_fenced_block.is_none() && !line.is_empty() {
            first_line = Some(line);
            break;
        }
    }
    let first_line = first_line?;

    // Strip markdown prefixes
    let cleaned = first_line.trim_start_matches(['#', '*', '-', ' ']).trim();

    if cleaned.len() < 5 {
        return None;
    }
    if is_unsuccessful_assistant_summary(cleaned) {
        return None;
    }

    let max_len = cleaned.len().min(100);
    let safe_end = safe_truncate_index(cleaned, max_len);
    if safe_end < cleaned.len() {
        Some(format!("{}...", &cleaned[..safe_end]))
    } else {
        Some(cleaned.to_string())
    }
}

pub(super) fn is_unsuccessful_assistant_summary(text: &str) -> bool {
    let normalized = normalize_metadata_text(text);
    if normalized.is_empty() {
        return true;
    }
    normalized.starts_with("error")
        || normalized.starts_with("failed")
        || normalized.starts_with("exception")
        || normalized.starts_with("traceback")
        || normalized.starts_with("i am sorry")
        || normalized.starts_with("im sorry")
        || normalized.starts_with("sorry")
}

/// Extract a concise short description from the first user or assistant message.
pub(super) fn extract_short_description_from_history(
    history: &[(String, String)],
    max_len: usize,
) -> Option<String> {
    history
        .iter()
        .find(|(role, _)| role == "user")
        .and_then(|(_, content)| extract_short_description_from_content(content, max_len))
        .or_else(|| {
            history
                .iter()
                .find(|(role, _)| role == "assistant")
                .and_then(|(_, content)| extract_short_description_from_content(content, max_len))
        })
}

pub(super) fn extract_short_description_from_recent_role(
    history: &[(String, String)],
    role: &str,
    max_len: usize,
) -> Option<String> {
    history
        .iter()
        .rev()
        .filter(|(entry_role, _)| entry_role == role)
        .find_map(|(_, content)| extract_short_description_from_content(content, max_len))
}

pub(super) fn extract_short_description_from_recent_history(
    history: &[(String, String)],
    max_len: usize,
) -> Option<String> {
    extract_short_description_from_recent_role(history, "assistant", max_len)
        .or_else(|| extract_short_description_from_recent_role(history, "user", max_len))
}

pub(super) fn terminal_verdict_from_content(content: &str) -> Option<&'static str> {
    // The contract asks for a terminal line. Scan backward so a long review's
    // conclusion wins over status prose or quoted historical verdicts above.
    for raw_line in content.lines().rev().take(80) {
        let line = strip_markdown_prefixes(raw_line.trim());
        let normalized = line.replace(['`', '*'], "").trim().to_ascii_uppercase();
        let explicit = normalized
            .strip_prefix("VERDICT:")
            .or_else(|| normalized.strip_prefix("FINAL DECISION:"))
            .map(str::trim);
        let value = explicit.unwrap_or(normalized.as_str());
        if value == "INFRA_BLOCKED"
            || value == "INFRA BLOCKED"
            || value.starts_with("INFRA_BLOCKED ")
            || value.starts_with("INFRA BLOCKED ")
        {
            return Some("infra_blocked");
        }
        if value == "BLOCKED"
            || value == "NOT CERTIFIED"
            || value.starts_with("BLOCKED ")
            || value.starts_with("NOT CERTIFIED ")
        {
            return Some("blocked");
        }
        if value == "CLEAN"
            || value == "CERTIFIED"
            || value == "MERGE READY"
            || value == "MERGE-READY"
            || value.starts_with("CLEAN ")
            || value.starts_with("CERTIFIED ")
            || value.starts_with("MERGE READY ")
            || value.starts_with("MERGE-READY ")
        {
            return Some("clean");
        }
    }
    None
}

pub(super) fn terminal_verdict_from_history(history: &[(String, String)]) -> Option<&'static str> {
    history
        .iter()
        .rev()
        .find(|(role, content)| role == "assistant" && !content.trim().is_empty())
        .and_then(|(_, content)| terminal_verdict_from_content(content))
}

pub(super) fn terminal_verdict_description(verdict: &str) -> &'static str {
    match verdict {
        "clean" => "VERDICT: CLEAN — exact-head review reported no blocking finding.",
        "blocked" => "VERDICT: BLOCKED — exact-head review reported unresolved blockers.",
        "infra_blocked" => {
            "VERDICT: INFRA_BLOCKED — verification could not complete because of infrastructure."
        }
        _ => "VERDICT: UNKNOWN",
    }
}

pub(super) fn extract_short_description_from_first_successful_assistant(
    history: &[(String, String)],
    max_len: usize,
) -> Option<String> {
    history
        .iter()
        .filter(|(entry_role, _)| entry_role == "assistant")
        .find_map(|(_, content)| {
            extract_short_description_from_content(content, max_len)
                .filter(|candidate| !is_unsuccessful_assistant_summary(candidate))
        })
}

pub(super) fn assistant_reply_is_successful(content: &str) -> bool {
    extract_short_description_from_content(content, 160)
        .map(|candidate| !is_unsuccessful_assistant_summary(&candidate))
        .unwrap_or(false)
}

pub(super) fn extract_short_description_from_content(
    content: &str,
    max_len: usize,
) -> Option<String> {
    let lines: Vec<&str> = content.lines().collect();
    let mut inside_fenced_block: Option<char> = None;
    let mut first_line: Option<&str> = None;
    for idx in 0..lines.len() {
        let line = lines[idx].trim();
        if let Some(fence_char) = markdown_fence_char(line) {
            if inside_fenced_block == Some(fence_char) {
                inside_fenced_block = None;
                continue;
            }
            if inside_fenced_block.is_none() {
                let has_closing_fence = lines[(idx + 1)..]
                    .iter()
                    .any(|candidate| markdown_fence_char(candidate.trim()) == Some(fence_char));
                if has_closing_fence {
                    inside_fenced_block = Some(fence_char);
                }
                continue;
            }
        }
        if inside_fenced_block.is_none() && !line.is_empty() {
            first_line = Some(line);
            break;
        }
    }
    let first_line = first_line?;

    let cleaned = strip_markdown_prefixes(first_line);
    let collapsed = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        return None;
    }

    let max_len = collapsed.len().min(max_len);
    let safe_end = safe_truncate_index(&collapsed, max_len);
    if safe_end < collapsed.len() {
        Some(format!("{}...", &collapsed[..safe_end]))
    } else {
        Some(collapsed)
    }
}

pub(super) fn strip_markdown_prefixes(line: &str) -> &str {
    let mut cleaned = line.trim();
    loop {
        let next = if let Some(stripped) = cleaned.strip_prefix('#') {
            Some(stripped.trim_start())
        } else if let Some(stripped) = cleaned.strip_prefix('>') {
            Some(stripped.trim_start())
        } else if let Some(stripped) = cleaned.strip_prefix("- ") {
            Some(stripped.trim_start())
        } else if let Some(stripped) = cleaned.strip_prefix("* ") {
            Some(stripped.trim_start())
        } else if let Some(stripped) = cleaned.strip_prefix("+ ") {
            Some(stripped.trim_start())
        } else {
            strip_ordered_list_prefix(cleaned)
        };

        match next {
            Some(candidate) if candidate != cleaned => cleaned = candidate,
            _ => break,
        }
    }
    cleaned
}

pub(super) fn strip_ordered_list_prefix(line: &str) -> Option<&str> {
    let mut idx = 0;
    for ch in line.chars() {
        if ch.is_ascii_digit() {
            idx += ch.len_utf8();
        } else {
            break;
        }
    }
    if idx == 0 || idx >= line.len() {
        return None;
    }

    let marker = line[idx..].chars().next()?;
    if marker != '.' && marker != ')' {
        return None;
    }
    let marker_end = idx + marker.len_utf8();
    let suffix = line.get(marker_end..)?;
    if suffix.is_empty() {
        return None;
    }
    if !suffix.chars().next().is_some_and(char::is_whitespace) {
        return None;
    }
    Some(suffix.trim_start())
}

pub(super) fn markdown_fence_char(line: &str) -> Option<char> {
    if line.starts_with("```") {
        Some('`')
    } else if line.starts_with("~~~") {
        Some('~')
    } else {
        None
    }
}

pub(super) fn normalize_metadata_text(text: &str) -> String {
    text.to_lowercase()
        .chars()
        .map(|ch| {
            if ch.is_alphanumeric() || ch.is_whitespace() {
                ch
            } else {
                ' '
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

pub(super) const METADATA_SOURCE_BACKEND_HEURISTIC: &str = "backend_heuristic";
pub(super) const METADATA_SOURCE_USER: &str = "user";
pub(super) const METADATA_VERSION_V1: &str = "v1";
pub(super) static MISSION_TITLE_UPDATE_LOCK: std::sync::LazyLock<Mutex<()>> =
    std::sync::LazyLock::new(|| Mutex::new(()));

pub(super) struct MetadataRefreshTaskEntry {
    pub(super) handle: tokio::task::JoinHandle<()>,
    pub(super) force_refresh: bool,
    pub(super) task_id: u64,
}

pub(super) struct MetadataRefreshTaskRegistration {
    pub(super) superseded: Option<tokio::task::JoinHandle<()>>,
}

pub(super) static MISSION_METADATA_REFRESH_TASKS: std::sync::LazyLock<
    std::sync::Mutex<HashMap<Uuid, MetadataRefreshTaskEntry>>,
> = std::sync::LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));
pub(super) static MISSION_METADATA_REFRESH_TASK_ID: AtomicU64 = AtomicU64::new(1);
pub(super) static MISSION_METADATA_REFRESH_BASELINES: std::sync::LazyLock<
    std::sync::Mutex<HashMap<Uuid, usize>>,
> = std::sync::LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

pub(super) fn register_metadata_refresh_task(
    tasks: &mut HashMap<Uuid, MetadataRefreshTaskEntry>,
    mission_id: Uuid,
    force_refresh: bool,
    task_id: u64,
    handle: tokio::task::JoinHandle<()>,
) -> MetadataRefreshTaskRegistration {
    tasks.retain(|_, existing| !existing.handle.is_finished());

    if let Some(existing) = tasks.get(&mission_id) {
        if existing.force_refresh && !force_refresh {
            return MetadataRefreshTaskRegistration {
                superseded: Some(handle),
            };
        }
    }

    let replaced = tasks.insert(
        mission_id,
        MetadataRefreshTaskEntry {
            handle,
            force_refresh,
            task_id,
        },
    );
    MetadataRefreshTaskRegistration {
        superseded: replaced.map(|entry| entry.handle),
    }
}

pub(super) fn should_skip_metadata_refresh_schedule(
    tasks: &mut HashMap<Uuid, MetadataRefreshTaskEntry>,
    mission_id: Uuid,
    force_refresh: bool,
) -> bool {
    tasks.retain(|_, existing| !existing.handle.is_finished());
    matches!(
        tasks.get(&mission_id),
        Some(existing) if existing.force_refresh && !force_refresh
    )
}

pub(super) fn complete_metadata_refresh_task(
    tasks: &mut HashMap<Uuid, MetadataRefreshTaskEntry>,
    mission_id: Uuid,
    task_id: u64,
) {
    if tasks
        .get(&mission_id)
        .map(|entry| entry.task_id == task_id)
        .unwrap_or(false)
    {
        tasks.remove(&mission_id);
    }
}

pub(super) fn clear_mission_metadata_refresh_state(mission_id: Uuid) {
    let stale_task = {
        let mut tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        tasks.remove(&mission_id)
    };
    if let Some(stale_task) = stale_task {
        stale_task.handle.abort();
    }

    let mut baselines = MISSION_METADATA_REFRESH_BASELINES
        .lock()
        .expect("metadata refresh baseline lock poisoned");
    baselines.remove(&mission_id);
}

/// Build a one-time "backend handoff" context message used when a mission's
/// backend is switched (e.g. claudecode ↔ codex) via run-settings.
///
/// Each backend keeps its own session/reasoning format (Claude's signed
/// thinking blocks vs Codex reasoning), and on a switch the new backend starts
/// a fresh session — so without this the prior *reasoning* is silently lost
/// (the reconstructed history only carries user/assistant text, not `thinking`
/// events). This carries the recent reasoning forward as plain text, which any
/// backend can consume. The workspace files and user/assistant transcript carry
/// over on their own. Returns `None` when there's nothing worth carrying.
pub(super) async fn build_backend_handoff_context(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    old_backend: &str,
    new_backend: &str,
) -> Option<String> {
    const MAX_TRACES: usize = 6;
    const MAX_TRACE_CHARS: usize = 1500;
    const MAX_BODY_CHARS: usize = 6000;

    // Scan recent events for the latest reasoning. Prefer `thinking` traces;
    // fall back to recent assistant messages when a backend produced none.
    let events = mission_store
        .get_latest_events(mission_id, 600)
        .await
        .ok()?;
    let pick = |event_type: &str, limit: usize| -> Vec<String> {
        let mut picked: Vec<String> = events
            .iter()
            .rev()
            .filter(|e| e.event_type == event_type && !e.content.trim().is_empty())
            .take(limit)
            .map(|e| e.content.trim().to_string())
            .collect();
        picked.reverse();
        picked
    };

    let (label, traces) = {
        let thinking = pick("thinking", MAX_TRACES);
        if !thinking.is_empty() {
            ("most recent reasoning", thinking)
        } else {
            ("most recent progress notes", pick("assistant_message", 4))
        }
    };
    if traces.is_empty() {
        return None;
    }

    let mut body = String::new();
    for trace in traces {
        let idx = safe_truncate_index(&trace, MAX_TRACE_CHARS);
        let snippet = if idx < trace.len() {
            format!("{}…", &trace[..idx])
        } else {
            trace
        };
        if body.len() + snippet.len() > MAX_BODY_CHARS && !body.is_empty() {
            break;
        }
        if !body.is_empty() {
            body.push_str("\n\n---\n\n");
        }
        body.push_str(&snippet);
    }

    // The reconstructed content is prior agent/user output, so treat it as
    // untrusted: neutralize any closing `</prior_reasoning>` so it can't break
    // out of the framing tag (prompt injection). Case-insensitive.
    let mut safe_body = body;
    for variant in [
        "</prior_reasoning",
        "</PRIOR_REASONING",
        "</Prior_reasoning",
    ] {
        safe_body = safe_body.replace(variant, "<\u{200b}/prior_reasoning");
    }

    // Backend names come from run-settings input; render only a sanitized
    // identifier (alphanumeric/-/_) so a crafted value can't inject prompt
    // text or break the markdown.
    let sanitize_backend = |s: &str| -> String {
        let cleaned: String = s
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
            .take(40)
            .collect();
        if cleaned.is_empty() {
            "backend".to_string()
        } else {
            cleaned
        }
    };
    let new_label = sanitize_backend(new_backend);
    let old_label = sanitize_backend(old_backend);

    Some(format!(
        "## Backend handoff: now continuing on `{new_label}` (was `{old_label}`)\n\n\
         The previous backend's session is not carried over (different reasoning \
         format), but your work is intact in the workspace and the conversation \
         above is preserved. To keep continuity, here is your {label} from the \
         `{old_label}` session:\n\n\
         <prior_reasoning>\n{safe_body}\n</prior_reasoning>\n\n\
         Pick up exactly where you left off and continue toward the goal. \
         Re-orient by checking the current workspace state first, then proceed."
    ))
}

pub(super) async fn clear_stale_mission_metadata_refresh_state(
    mission_store: &Arc<dyn MissionStore>,
) {
    let tracked_ids: std::collections::HashSet<Uuid> = {
        let tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        let baselines = MISSION_METADATA_REFRESH_BASELINES
            .lock()
            .expect("metadata refresh baseline lock poisoned");

        tasks.keys().chain(baselines.keys()).copied().collect()
    };

    for mission_id in tracked_ids {
        match mission_store.get_mission(mission_id).await {
            Ok(Some(_)) => {}
            Ok(None) => clear_mission_metadata_refresh_state(mission_id),
            Err(err) => tracing::warn!(
                "Failed to verify mission {} while clearing stale metadata refresh state: {}",
                mission_id,
                err
            ),
        }
    }
}

pub(super) fn normalize_raw_title_for_dedupe(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

pub(super) fn strip_numeric_title_suffix(title: &str) -> &str {
    let trimmed = title.trim();
    if !trimmed.ends_with(')') {
        return trimmed;
    }
    let Some(open_idx) = trimmed.rfind(" (") else {
        return trimmed;
    };
    let suffix = &trimmed[(open_idx + 2)..(trimmed.len() - 1)];
    if suffix.is_empty() || !suffix.chars().all(|c| c.is_ascii_digit()) {
        return trimmed;
    }
    trimmed[..open_idx].trim_end()
}

pub(super) fn canonical_title_key(title: &str) -> String {
    normalize_metadata_text(strip_numeric_title_suffix(title))
}

pub(super) fn title_similarity_token(token: &str) -> String {
    if token.len() > 4 && token.ends_with("ies") {
        return format!("{}y", &token[..token.len() - 3]);
    }
    if token.len() > 4 && token.ends_with('s') && !token.ends_with("ss") {
        return token[..token.len() - 1].to_string();
    }
    token.to_string()
}

pub(super) fn title_similarity_tokens(title: &str) -> Vec<String> {
    normalize_metadata_text(strip_numeric_title_suffix(title))
        .split_whitespace()
        .filter(|token| !token.is_empty() && !is_search_stopword(token))
        .map(title_similarity_token)
        .filter(|token| !token.is_empty())
        .collect()
}

pub(super) fn token_similarity_strength(lhs: &str, rhs: &str) -> f64 {
    search_token_match_strength(lhs, rhs).max(search_token_match_strength(rhs, lhs))
}

pub(super) fn title_near_duplicate_score(lhs: &str, rhs: &str) -> f64 {
    let lhs_tokens = title_similarity_tokens(lhs);
    let rhs_tokens = title_similarity_tokens(rhs);
    if lhs_tokens.is_empty() || rhs_tokens.is_empty() {
        return 0.0;
    }

    let lhs_best_avg = lhs_tokens
        .iter()
        .map(|lhs_token| {
            rhs_tokens
                .iter()
                .map(|rhs_token| token_similarity_strength(lhs_token, rhs_token))
                .fold(0.0_f64, f64::max)
        })
        .sum::<f64>()
        / lhs_tokens.len() as f64;

    let rhs_best_avg = rhs_tokens
        .iter()
        .map(|rhs_token| {
            lhs_tokens
                .iter()
                .map(|lhs_token| token_similarity_strength(rhs_token, lhs_token))
                .fold(0.0_f64, f64::max)
        })
        .sum::<f64>()
        / rhs_tokens.len() as f64;

    (lhs_best_avg + rhs_best_avg) / 2.0
}

pub(super) fn is_near_duplicate_title(candidate: &str, existing: &str) -> bool {
    const NEAR_DUPLICATE_THRESHOLD: f64 = 0.9;
    title_near_duplicate_score(candidate, existing) >= NEAR_DUPLICATE_THRESHOLD
}

pub(super) fn title_collides_with_existing(candidate: &str, existing: &str) -> bool {
    let candidate_normalized = normalize_metadata_text(candidate);
    let existing_normalized = normalize_metadata_text(existing);
    if !candidate_normalized.is_empty() && candidate_normalized == existing_normalized {
        return true;
    }
    is_near_duplicate_title(candidate, existing)
}

pub(super) async fn load_recent_mission_titles(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
) -> Vec<String> {
    const RECENT_TITLE_SCAN_PAGE_SIZE: usize = 200;
    const RECENT_TITLE_SCAN_MAX: usize = 2_000;

    let mut titles = Vec::new();
    let mut offset = 0;

    while offset < RECENT_TITLE_SCAN_MAX {
        match mission_store
            .list_missions(RECENT_TITLE_SCAN_PAGE_SIZE, offset)
            .await
        {
            Ok(missions) => {
                if missions.is_empty() {
                    break;
                }
                let page_len = missions.len();
                titles.extend(
                    missions
                        .into_iter()
                        .filter(|mission| mission.id != mission_id)
                        .filter_map(|mission| mission.title)
                        .map(|title| title.trim().to_string())
                        .filter(|title| !title.is_empty()),
                );

                if page_len < RECENT_TITLE_SCAN_PAGE_SIZE {
                    break;
                }
                offset += RECENT_TITLE_SCAN_PAGE_SIZE;
            }
            Err(err) => {
                tracing::warn!(
                    "Failed to load recent mission titles for metadata generation: {err}"
                );
                break;
            }
        }
    }

    if offset >= RECENT_TITLE_SCAN_MAX {
        tracing::warn!(
            "Recent-title scan hit cap ({} missions); some older titles may be skipped",
            RECENT_TITLE_SCAN_MAX
        );
    }

    titles
}

pub(super) fn derive_title_qualifier_from_text(base_title: &str, text: &str) -> Option<String> {
    let base_tokens: HashSet<String> = normalize_metadata_text(base_title)
        .split_whitespace()
        .map(ToString::to_string)
        .collect();
    let qualifier_tokens: Vec<String> = normalize_metadata_text(text)
        .split_whitespace()
        .filter(|token| !base_tokens.contains(*token))
        .filter(|token| !is_search_stopword(token))
        .take(4)
        .map(ToString::to_string)
        .collect();

    if qualifier_tokens.len() < 2 {
        return None;
    }
    Some(qualifier_tokens.join(" "))
}

pub(super) fn append_title_qualifier(base_title: &str, qualifier: &str) -> String {
    let combined = format!("{} - {}", base_title.trim(), qualifier.trim());
    let max_len = combined.len().min(100);
    let safe_end = safe_truncate_index(&combined, max_len);
    if safe_end < combined.len() {
        format!("{}...", &combined[..safe_end])
    } else {
        combined
    }
}

pub(super) async fn diversify_generated_title_with_recent_context(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    title_candidate: String,
    history: &[(String, String)],
    fallback_user_content: Option<&str>,
) -> String {
    let recent_titles = load_recent_mission_titles(mission_store, mission_id).await;
    if recent_titles.is_empty()
        || !recent_titles
            .iter()
            .any(|existing| title_collides_with_existing(&title_candidate, existing))
    {
        return title_candidate;
    }

    // Prefer user-origin context as negative prompt signal to diversify generic duplicates.
    let mut qualifier_sources: Vec<&str> = Vec::new();
    if let Some(user_content) = fallback_user_content {
        qualifier_sources.push(user_content);
    }
    for (role, content) in history {
        if role == "user" {
            qualifier_sources.push(content);
        }
    }
    for (role, content) in history {
        if role == "assistant" {
            qualifier_sources.push(content);
        }
    }

    for source in qualifier_sources {
        if let Some(qualifier) = derive_title_qualifier_from_text(&title_candidate, source) {
            let diversified = append_title_qualifier(&title_candidate, &qualifier);
            if !recent_titles
                .iter()
                .any(|existing| title_collides_with_existing(&diversified, existing))
            {
                return diversified;
            }
        }
    }

    title_candidate
}

pub(super) fn has_significant_metadata_drift(existing: &str, candidate: &str) -> bool {
    let existing_normalized = normalize_metadata_text(existing);
    let candidate_normalized = normalize_metadata_text(candidate);

    if existing_normalized.is_empty() {
        return !candidate_normalized.is_empty();
    }
    if existing_normalized == candidate_normalized {
        return false;
    }
    if existing_normalized.contains(&candidate_normalized)
        || candidate_normalized.contains(&existing_normalized)
    {
        return false;
    }

    let existing_tokens: Vec<&str> = existing_normalized.split_whitespace().collect();
    let candidate_tokens: Vec<&str> = candidate_normalized.split_whitespace().collect();
    if existing_tokens.is_empty() || candidate_tokens.is_empty() {
        return true;
    }
    let existing_set: HashSet<&str> = existing_tokens.iter().copied().collect();
    let candidate_set: HashSet<&str> = candidate_tokens.iter().copied().collect();
    let overlap = existing_set.intersection(&candidate_set).count();
    let min_len = existing_set.len().min(candidate_set.len());
    if min_len > 0 {
        let overlap_ratio = overlap as f64 / min_len as f64;
        if overlap_ratio >= 0.8 {
            return false;
        }
    }

    true
}

pub(super) async fn disambiguate_generated_title(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    title: &str,
) -> String {
    const TITLE_DEDUPE_PAGE_SIZE: usize = 200;
    const TITLE_DEDUPE_MAX_SCAN: usize = 5_000;

    let base_title = title.trim();
    if base_title.is_empty() {
        return title.to_string();
    }

    let mut exact_titles = HashSet::new();
    let mut canonical_titles = HashSet::new();
    let mut raw_titles = HashSet::new();
    let mut canonical_raw_titles = HashSet::new();
    let mut dedupe_probe_titles = Vec::new();

    let mut offset = 0;
    while offset < TITLE_DEDUPE_MAX_SCAN {
        let missions = match mission_store
            .list_missions(TITLE_DEDUPE_PAGE_SIZE, offset)
            .await
        {
            Ok(missions) => missions,
            Err(err) => {
                tracing::warn!("Failed to load mission titles for dedupe guard: {}", err);
                return base_title.to_string();
            }
        };

        if missions.is_empty() {
            break;
        }

        for mission in &missions {
            if mission.id == mission_id {
                continue;
            }
            if let Some(existing_title) = &mission.title {
                let raw = normalize_raw_title_for_dedupe(existing_title);
                if !raw.is_empty() {
                    raw_titles.insert(raw);
                }
                let canonical_raw =
                    normalize_raw_title_for_dedupe(strip_numeric_title_suffix(existing_title));
                if !canonical_raw.is_empty() {
                    canonical_raw_titles.insert(canonical_raw);
                }

                let normalized = normalize_metadata_text(existing_title);
                if !normalized.is_empty() {
                    exact_titles.insert(normalized);
                }
                let canonical = canonical_title_key(existing_title);
                if !canonical.is_empty() {
                    canonical_titles.insert(canonical);
                }
                dedupe_probe_titles.push(existing_title.clone());
            }
        }

        if missions.len() < TITLE_DEDUPE_PAGE_SIZE {
            break;
        }
        offset += TITLE_DEDUPE_PAGE_SIZE;
    }

    if offset >= TITLE_DEDUPE_MAX_SCAN {
        tracing::warn!(
            "Title dedupe scan hit cap ({} missions); duplicates may still exist",
            TITLE_DEDUPE_MAX_SCAN
        );
    }

    let candidate_exact = normalize_metadata_text(base_title);
    let candidate_raw = normalize_raw_title_for_dedupe(base_title);
    let candidate_canonical = canonical_title_key(base_title);
    let candidate_canonical_raw =
        normalize_raw_title_for_dedupe(strip_numeric_title_suffix(base_title));

    let is_taken = |candidate: &str| {
        let normalized = normalize_metadata_text(candidate);
        let raw = normalize_raw_title_for_dedupe(candidate);
        let normalized_match = !normalized.is_empty() && exact_titles.contains(&normalized);
        let raw_match = !raw.is_empty() && raw_titles.contains(&raw);
        normalized_match || raw_match
    };

    let has_duplicate = if candidate_exact.is_empty() {
        if candidate_raw.is_empty() {
            false
        } else if candidate_canonical_raw.is_empty() {
            raw_titles.contains(&candidate_raw)
        } else {
            raw_titles.contains(&candidate_raw)
                || canonical_raw_titles.contains(&candidate_canonical_raw)
        }
    } else if candidate_canonical.is_empty() {
        exact_titles.contains(&candidate_exact)
    } else {
        exact_titles.contains(&candidate_exact) || canonical_titles.contains(&candidate_canonical)
    };
    let has_near_duplicate = dedupe_probe_titles
        .iter()
        .any(|existing| is_near_duplicate_title(base_title, existing));
    if !has_duplicate && !has_near_duplicate {
        return base_title.to_string();
    }

    for idx in 2..100 {
        let candidate = format!("{} ({})", base_title, idx);
        if !is_taken(&candidate) {
            return candidate;
        }
    }

    format!("{} ({})", base_title, Uuid::new_v4().as_simple())
}

pub(super) async fn generate_mission_metadata_updates(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    mission: &Mission,
    history: &[(String, String)],
    fallback_user_content: Option<&str>,
    should_refresh: bool,
) -> (Option<String>, Option<String>) {
    if history.is_empty() {
        return (None, None);
    }

    let title_missing = mission
        .title
        .as_ref()
        .map(|t| t.trim().is_empty())
        .unwrap_or(true);
    let short_description_missing = mission
        .short_description
        .as_ref()
        .map(|d| d.trim().is_empty())
        .unwrap_or(true);
    let title_user_managed =
        mission.metadata_source.as_deref() == Some(METADATA_SOURCE_USER) && !title_missing;
    let has_assistant_reply = history.iter().any(|(role, _)| role == "assistant");
    let has_successful_assistant_reply = history
        .iter()
        .any(|(role, content)| role == "assistant" && assistant_reply_is_successful(content));
    let deterministic_terminal_verdict = terminal_verdict_from_history(history);
    let should_bootstrap_title_from_first_assistant =
        title_missing && has_successful_assistant_reply;
    let should_bootstrap_short_description_from_first_assistant = has_successful_assistant_reply
        && (short_description_missing || title_missing)
        && !should_refresh;

    if !title_missing
        && !short_description_missing
        && !should_refresh
        && !should_bootstrap_title_from_first_assistant
        && !should_bootstrap_short_description_from_first_assistant
    {
        return (None, None);
    }

    // ── Try LLM-powered summarization first ────────────────────────────
    let needs_title = (title_missing || should_refresh) && !title_user_managed;
    let needs_description = short_description_missing
        || should_refresh
        || should_bootstrap_short_description_from_first_assistant;

    if (needs_title || needs_description) && has_successful_assistant_reply {
        if let Some((llm_title, llm_status)) =
            try_llm_metadata_summarization(history, mission, should_refresh).await
        {
            let mut updated_title: Option<String> = None;
            let mut updated_short_description: Option<String> = None;

            if needs_title {
                if let Some(candidate) = llm_title {
                    let candidate = diversify_generated_title_with_recent_context(
                        mission_store,
                        mission_id,
                        candidate,
                        history,
                        fallback_user_content,
                    )
                    .await;
                    if should_accept_metadata_candidate(
                        mission.title.as_deref(),
                        &candidate,
                        should_bootstrap_title_from_first_assistant,
                    ) {
                        updated_title = Some(candidate);
                    }
                }
            }

            if needs_description {
                if let Some(candidate) = deterministic_terminal_verdict
                    .map(terminal_verdict_description)
                    .map(str::to_string)
                    .or(llm_status)
                {
                    if should_accept_metadata_candidate(
                        mission.short_description.as_deref(),
                        &candidate,
                        should_bootstrap_short_description_from_first_assistant,
                    ) {
                        updated_short_description = Some(candidate);
                    }
                }
            }

            if updated_title.is_some() || updated_short_description.is_some() {
                return (updated_title, updated_short_description);
            }
        }
    }

    // ── Fallback: heuristic extraction from conversation text ──────────
    let title_candidate = if needs_title {
        let assistant_title_candidate = if should_bootstrap_title_from_first_assistant {
            history
                .iter()
                .filter(|(role, _)| role == "assistant")
                .find_map(|(_, content)| extract_title_from_assistant(content))
        } else {
            history
                .iter()
                .rev()
                .filter(|(role, _)| role == "assistant")
                .find_map(|(_, content)| extract_title_from_assistant(content))
        };

        assistant_title_candidate.or_else(|| {
            if should_bootstrap_title_from_first_assistant {
                fallback_user_content.map(|user_content| {
                    if user_content.len() > 100 {
                        let safe_end = safe_truncate_index(user_content, 100);
                        format!("{}...", &user_content[..safe_end])
                    } else {
                        user_content.to_string()
                    }
                })
            } else {
                None
            }
        })
    } else {
        None
    };
    let title_candidate = match title_candidate {
        Some(candidate) => Some(
            diversify_generated_title_with_recent_context(
                mission_store,
                mission_id,
                candidate,
                history,
                fallback_user_content,
            )
            .await,
        ),
        None => None,
    };

    let short_description_candidate = if needs_description {
        if let Some(verdict) = deterministic_terminal_verdict {
            Some(terminal_verdict_description(verdict).to_string())
        } else if should_bootstrap_short_description_from_first_assistant {
            extract_short_description_from_first_successful_assistant(history, 160)
                .or_else(|| extract_short_description_from_history(history, 160))
        } else if should_refresh {
            extract_short_description_from_recent_history(history, 160)
                .or_else(|| extract_short_description_from_history(history, 160))
        } else if has_assistant_reply {
            None
        } else {
            extract_short_description_from_history(history, 160)
        }
    } else {
        None
    };

    let mut updated_title: Option<String> = None;
    if let Some(candidate_title) = title_candidate {
        if should_accept_metadata_candidate(
            mission.title.as_deref(),
            &candidate_title,
            should_bootstrap_title_from_first_assistant,
        ) {
            updated_title = Some(candidate_title);
        }
    }

    let mut updated_short_description: Option<String> = None;
    if let Some(candidate_short_description) = short_description_candidate {
        if should_accept_metadata_candidate(
            mission.short_description.as_deref(),
            &candidate_short_description,
            should_bootstrap_short_description_from_first_assistant,
        ) {
            updated_short_description = Some(candidate_short_description);
        }
    }

    (updated_title, updated_short_description)
}

/// Check if a metadata candidate should replace the existing value.
pub(super) fn should_accept_metadata_candidate(
    existing: Option<&str>,
    candidate: &str,
    is_bootstrap: bool,
) -> bool {
    let should_update = if is_bootstrap {
        true
    } else {
        existing
            .map(|e| has_significant_metadata_drift(e, candidate))
            .unwrap_or(true)
    };
    if !should_update {
        return false;
    }
    existing
        .map(|e| normalize_metadata_text(e) != normalize_metadata_text(candidate))
        .unwrap_or(true)
}

/// Try to generate metadata using the configured LLM provider.
/// Returns `Some((title, status))` if the LLM was called successfully,
/// `None` if no LLM is configured or the call failed.
pub(super) async fn try_llm_metadata_summarization(
    history: &[(String, String)],
    mission: &Mission,
    is_refresh: bool,
) -> Option<(Option<String>, Option<String>)> {
    let llm = match super::super::metadata_llm::metadata_llm() {
        Some(l) => l,
        None => {
            tracing::debug!("[MetadataLLM] No LLM client available");
            return None;
        }
    };

    // Gather the most relevant user message and assistant reply
    let (user_msg, assistant_msg) = if is_refresh {
        // On refresh, use the most recent exchange
        let user = history
            .iter()
            .rev()
            .find(|(role, _)| role == "user")
            .map(|(_, c)| c.as_str())
            .unwrap_or("");
        let assistant = history
            .iter()
            .rev()
            .find(|(role, content)| role == "assistant" && assistant_reply_is_successful(content))
            .map(|(_, c)| c.as_str())
            .unwrap_or("");
        (user, assistant)
    } else {
        // On bootstrap, use the first exchange
        let user = history
            .iter()
            .find(|(role, _)| role == "user")
            .map(|(_, c)| c.as_str())
            .unwrap_or("");
        let assistant = history
            .iter()
            .find(|(role, content)| role == "assistant" && assistant_reply_is_successful(content))
            .map(|(_, c)| c.as_str())
            .unwrap_or("");
        (user, assistant)
    };

    if user_msg.is_empty() && assistant_msg.is_empty() {
        return None;
    }

    tracing::info!(
        "[MetadataLLM] Calling summarize_mission (is_refresh={}, user_len={}, assistant_len={})",
        is_refresh,
        user_msg.len(),
        assistant_msg.len()
    );

    let (title, status) = llm
        .summarize_mission(
            user_msg,
            assistant_msg,
            mission.title.as_deref(),
            is_refresh,
        )
        .await;

    tracing::info!(
        "[MetadataLLM] Result: title={:?}, status={:?}",
        title,
        status
    );

    // Only return Some if we got at least one result
    if title.is_some() || status.is_some() {
        Some((title, status))
    } else {
        None
    }
}

pub(super) async fn apply_generated_mission_metadata_updates(
    mission_store: &Arc<dyn MissionStore>,
    events_tx: &broadcast::Sender<AgentEvent>,
    mission_id: Uuid,
    generated_title: Option<String>,
    generated_short_description: Option<String>,
    metadata_source_update: Option<Option<&str>>,
    metadata_model: Option<&str>,
) -> bool {
    if generated_title.is_none() && generated_short_description.is_none() {
        return false;
    }

    let _title_update_guard = if generated_title.is_some() {
        Some(MISSION_TITLE_UPDATE_LOCK.lock().await)
    } else {
        None
    };

    let title_to_write = match generated_title {
        Some(title) => Some(disambiguate_generated_title(mission_store, mission_id, &title).await),
        None => None,
    };

    if let Err(err) = mission_store
        .update_mission_metadata(
            mission_id,
            title_to_write.as_deref().map(Some),
            generated_short_description.as_deref().map(Some),
            metadata_source_update,
            metadata_model.map(Some),
            Some(Some(METADATA_VERSION_V1)),
        )
        .await
    {
        tracing::warn!("Failed to update mission metadata: {}", err);
        return false;
    }

    match mission_store.get_mission(mission_id).await {
        Ok(Some(updated)) => {
            emit_mission_metadata_updated_event(events_tx, mission_id, &updated);
            if title_to_write.is_some() {
                if let Some(title) = updated.title {
                    let _ = events_tx.send(AgentEvent::MissionTitleChanged { mission_id, title });
                }
            }
        }
        Ok(None) => {
            tracing::warn!("Mission {} disappeared after metadata update", mission_id);
        }
        Err(err) => {
            tracing::warn!("Failed to reload mission metadata after update: {}", err);
        }
    }
    true
}

pub(super) fn emit_mission_metadata_updated_event(
    events_tx: &broadcast::Sender<AgentEvent>,
    mission_id: Uuid,
    mission: &Mission,
) {
    let _ = events_tx.send(AgentEvent::MissionMetadataUpdated {
        mission_id,
        title: mission.title.clone(),
        short_description: mission.short_description.clone(),
        metadata_updated_at: mission.metadata_updated_at.clone(),
        updated_at: Some(mission.updated_at.clone()),
        metadata_source: mission.metadata_source.clone(),
        metadata_model: mission.metadata_model.clone(),
        metadata_version: mission.metadata_version.clone(),
    });
}

pub(super) fn conversational_message_count(history: &[(String, String)]) -> usize {
    history
        .iter()
        .filter(|(role, _)| role == "user" || role == "assistant")
        .count()
}

pub(super) fn should_refresh_metadata_by_cadence(
    mission_id: Uuid,
    mission: &Mission,
    conversational_count: usize,
    force_refresh: bool,
) -> bool {
    if force_refresh {
        return true;
    }
    if conversational_count == 0 {
        return false;
    }

    let mut baselines = MISSION_METADATA_REFRESH_BASELINES
        .lock()
        .expect("metadata refresh baseline lock poisoned");
    let baseline = baselines.entry(mission_id).or_insert_with(|| {
        if mission.metadata_updated_at.is_some() {
            conversational_count
        } else {
            0
        }
    });

    if conversational_count < *baseline {
        *baseline = conversational_count;
        return false;
    }

    conversational_count.saturating_sub(*baseline) >= 10
}

pub(super) fn record_metadata_refresh_baseline(mission_id: Uuid, conversational_count: usize) {
    let mut baselines = MISSION_METADATA_REFRESH_BASELINES
        .lock()
        .expect("metadata refresh baseline lock poisoned");
    baselines.insert(mission_id, conversational_count);
}

pub(super) fn record_metadata_refresh_baseline_from_mission(mission_id: Uuid, mission: &Mission) {
    let conversational_count = mission
        .history
        .iter()
        .filter(|entry| entry.role == "user" || entry.role == "assistant")
        .count();
    record_metadata_refresh_baseline(mission_id, conversational_count);
}

pub(super) async fn persist_mission_history_and_schedule_metadata_refresh(
    mission_store: &Arc<dyn MissionStore>,
    events_tx: &broadcast::Sender<AgentEvent>,
    mission_id: Uuid,
    entries: &[MissionHistoryEntry],
) {
    if let Err(e) = mission_store
        .update_mission_history(mission_id, entries)
        .await
    {
        tracing::warn!("Failed to persist mission history: {}", e);
        return;
    }
    schedule_mission_metadata_refresh(mission_store, events_tx, mission_id, false);
}

pub(super) async fn refresh_mission_metadata_from_store(
    mission_store: &Arc<dyn MissionStore>,
    events_tx: &broadcast::Sender<AgentEvent>,
    mission_id: Uuid,
    force_refresh: bool,
) {
    let mission = match mission_store.get_mission(mission_id).await {
        Ok(Some(mission)) => mission,
        Ok(None) => {
            tracing::warn!(
                "Skipping metadata refresh; mission {} not found",
                mission_id
            );
            return;
        }
        Err(err) => {
            tracing::warn!(
                "Failed to load mission {} for metadata refresh: {}",
                mission_id,
                err
            );
            return;
        }
    };

    let history_pairs: Vec<(String, String)> = mission
        .history
        .iter()
        .map(|entry| (entry.role.clone(), entry.content.clone()))
        .collect();
    let fallback_user_content = history_pairs
        .iter()
        .find(|(role, _)| role == "user")
        .map(|(_, content)| content.as_str());
    let conversational_count = conversational_message_count(&history_pairs);
    let should_refresh = should_refresh_metadata_by_cadence(
        mission_id,
        &mission,
        conversational_count,
        force_refresh,
    );

    let (generated_title, generated_short_description) = generate_mission_metadata_updates(
        mission_store,
        mission_id,
        &mission,
        &history_pairs,
        fallback_user_content,
        should_refresh,
    )
    .await;
    let metadata_source_update = if generated_title.is_none()
        && mission.metadata_source.as_deref() == Some(METADATA_SOURCE_USER)
        && mission
            .title
            .as_deref()
            .map(|title| !title.trim().is_empty())
            .unwrap_or(false)
    {
        None
    } else {
        Some(Some(METADATA_SOURCE_BACKEND_HEURISTIC))
    };
    let metadata_updated = apply_generated_mission_metadata_updates(
        mission_store,
        events_tx,
        mission_id,
        generated_title,
        generated_short_description,
        metadata_source_update,
        mission.model_override.as_deref(),
    )
    .await;
    if should_refresh || metadata_updated {
        record_metadata_refresh_baseline(mission_id, conversational_count);
    }
}

pub(super) fn schedule_mission_metadata_refresh(
    mission_store: &Arc<dyn MissionStore>,
    events_tx: &broadcast::Sender<AgentEvent>,
    mission_id: Uuid,
    force_refresh: bool,
) {
    {
        let mut tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        if should_skip_metadata_refresh_schedule(&mut tasks, mission_id, force_refresh) {
            return;
        }
    }

    let task_id = MISSION_METADATA_REFRESH_TASK_ID.fetch_add(1, Ordering::Relaxed);
    let mission_store = Arc::clone(mission_store);
    let events_tx = events_tx.clone();
    let background_refresh = tokio::spawn(async move {
        refresh_mission_metadata_from_store(&mission_store, &events_tx, mission_id, force_refresh)
            .await;
        let mut tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        complete_metadata_refresh_task(&mut tasks, mission_id, task_id);
    });
    let registration = {
        let mut tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        register_metadata_refresh_task(
            &mut tasks,
            mission_id,
            force_refresh,
            task_id,
            background_refresh,
        )
    };
    if let Some(superseded) = registration.superseded {
        superseded.abort();
    }
}

pub(super) async fn refresh_mission_metadata_for_milestone(
    mission_store: &Arc<dyn MissionStore>,
    events_tx: &broadcast::Sender<AgentEvent>,
    mission_id: Uuid,
) {
    refresh_mission_metadata_from_store(mission_store, events_tx, mission_id, true).await;
}

pub(super) fn schedule_mission_metadata_refresh_for_milestone(
    mission_store: &Arc<dyn MissionStore>,
    events_tx: &broadcast::Sender<AgentEvent>,
    mission_id: Uuid,
) {
    {
        let mut tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        if should_skip_metadata_refresh_schedule(&mut tasks, mission_id, true) {
            return;
        }
    }

    let task_id = MISSION_METADATA_REFRESH_TASK_ID.fetch_add(1, Ordering::Relaxed);
    let mission_store = Arc::clone(mission_store);
    let events_tx = events_tx.clone();
    let background_refresh = tokio::spawn(async move {
        refresh_mission_metadata_for_milestone(&mission_store, &events_tx, mission_id).await;
        let mut tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        complete_metadata_refresh_task(&mut tasks, mission_id, task_id);
    });
    let registration = {
        let mut tasks = MISSION_METADATA_REFRESH_TASKS
            .lock()
            .expect("metadata refresh task registry lock poisoned");
        register_metadata_refresh_task(&mut tasks, mission_id, true, task_id, background_refresh)
    };
    if let Some(superseded) = registration.superseded {
        superseded.abort();
    }
}

pub(super) fn status_requires_metadata_milestone_refresh(status: MissionStatus) -> bool {
    !matches!(status, MissionStatus::Pending | MissionStatus::Active)
}

pub(crate) fn maybe_schedule_mission_metadata_refresh_for_status(
    mission_store: &Arc<dyn MissionStore>,
    events_tx: &broadcast::Sender<AgentEvent>,
    mission_id: Uuid,
    status: MissionStatus,
) {
    if status_requires_metadata_milestone_refresh(status) {
        schedule_mission_metadata_refresh_for_milestone(mission_store, events_tx, mission_id);
    }
}
