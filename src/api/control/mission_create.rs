//! Mission creation, model normalization and dispatch admission for new missions.

use super::*;

/// Create a new mission and switch to it.
/// Request body for creating a mission
#[derive(Debug, Deserialize)]
pub struct CreateMissionRequest {
    pub cyber_access: Option<cyber::Mode>,
    pub title: Option<String>,
    /// Workspace ID to run the mission in (defaults to host workspace)
    pub workspace_id: Option<Uuid>,
    /// Agent name from library (e.g., "code-reviewer")
    pub agent: Option<String>,
    /// Optional model override (provider/model) - deprecated, use config_profile instead
    pub model_override: Option<String>,
    /// Optional model effort override (supports: low, medium, high, xhigh, max)
    pub model_effort: Option<String>,
    /// Enable Codex fast service tier for supported GPT models.
    #[serde(default)]
    pub fast_mode: bool,
    pub service_tier: Option<crate::codex_speed::Tier>,
    /// Config profile to use for this mission (overrides workspace's default profile)
    pub config_profile: Option<String>,
    /// Backend to use for this mission ("opencode" or "claudecode")
    pub backend: Option<String>,
    /// Parent mission ID (for orchestrated worker missions)
    pub parent_mission_id: Option<Uuid>,
    /// The attempt this mission replaces (a relay after a failure, a
    /// backend handoff). The prior mission is tagged `superseded_by:<id>`
    /// and acknowledged, so the board stops flagging it. Must be on the
    /// same project.
    #[serde(default)]
    pub supersedes_mission_id: Option<Uuid>,
    /// Working directory override (for git worktrees etc.)
    pub working_directory: Option<String>,
    /// FLEET-001 scheduling hint: dispatch priority (higher = more important,
    /// default 0). The scheduler dispatches higher-priority scheduled missions
    /// first, FIFO within the same priority.
    pub priority: Option<i32>,
    /// FLEET-001 scheduling hint: do not dispatch before this timestamp. The
    /// mission's first message is held (as `deferred_goal`) until then.
    pub not_before: Option<chrono::DateTime<chrono::Utc>>,
    /// FLEET-001 scheduling hint: deadline. A scheduled mission that never
    /// dispatches before this is failed with reason `deadline_exceeded`.
    pub deadline: Option<chrono::DateTime<chrono::Utc>>,
    /// Project tagging: stable project identifier (e.g. "verity-core").
    pub project: Option<String>,
    /// Project tagging: track / workstream within the project. Resolved
    /// against the plan (key, alias, single PR ref) and absorbed as a new
    /// `origin = absorbed` track when unknown.
    pub track: Option<String>,
    /// Caller-supplied idempotency key for the dispatch. Keys the track lease
    /// so a retried create cannot take a second lease; generated per mission
    /// when absent.
    pub idempotency_key: Option<String>,
    /// Project tagging: intent (e.g. "review_merge_pr").
    pub intent: Option<String>,
    /// Project tagging: associated GitHub PR ref (e.g. "owner/repo#123").
    pub github_pr: Option<String>,
    /// Whether this mission may modify the associated PR branch. When omitted,
    /// Sandboxed.sh infers writer intent from `intent`/`prompt`. At most one
    /// non-terminal writer may own a PR at a time.
    pub writer: Option<bool>,
    /// Project tagging: freeform tags.
    pub tags: Option<Vec<String>>,
    /// Track state, e.g. "waiting_ci" / "waiting_review" / "blocked_external".
    pub desired_state: Option<String>,
    /// Acceptance contract declared (or revised) on the track by this dispatch.
    #[serde(default)]
    pub acceptance_criteria: Vec<String>,
    /// When the track should next be checked (RFC3339).
    pub next_check_at: Option<String>,
    /// Initial prompt for the mission. Stored as the mission's deferred goal:
    /// the FLEET-001 scheduler dispatches it as the first user message as soon
    /// as parallel capacity allows (immediately when a slot is free, honoring
    /// `not_before` when set). This makes create+start atomic — callers no
    /// longer need a follow-up `POST /api/control/message`, whose delivery
    /// used to be droppable at capacity, orphaning the mission.
    pub prompt: Option<String>,
    /// Remote runner node id. When set, core creates the mission locally and
    /// dispatches `remote_command` to that node behind the remote-node flag.
    /// The special value `"auto"` picks a node via capacity-aware placement
    /// (`FleetMonitor::place_auto`) before the mission is persisted.
    pub remote_node_id: Option<String>,
    /// Label requirements for `remote_node_id: "auto"` placement. Defaults to
    /// no requirements for raw remote commands (`lean_build` dispatch via
    /// `POST /api/remote-build` defaults to `["lean"]`).
    pub remote_requirements: Option<Vec<String>>,
    /// MVP remote execution payload. Full AI mission streaming remains local.
    pub remote_command: Option<String>,
    /// When true (with `remote_node_id` + `remote_command`), dispatch through
    /// the node's async job API: the mission goes Active immediately and a
    /// background poll loop finalizes it when the job completes. Default
    /// false keeps the synchronous blocking `/execute` path unchanged.
    pub remote_async: Option<bool>,
    /// Expected peak local scratch consumption in GiB. Small/no-build missions
    /// may omit it; disk-heavy missions should set it so warn-level operation
    /// can continue without admitting work that would cross the emergency
    /// reserve.
    pub estimated_disk_gib: Option<u64>,
    /// Which system created this mission (e.g. "hermes" for the assistant
    /// MCP). Clients group foreign-origin missions as workers of their owning
    /// conversation instead of standalone rows.
    pub origin: Option<String>,
    /// External conversation that spawned this mission — the Hermes session id
    /// when `origin` is "hermes". Only stored when `origin` is set.
    pub origin_session_id: Option<String>,
    /// Orb `@` chips: materialized into `.paloma/` before the harness starts.
    #[serde(default)]
    pub attachments: Option<Vec<crate::api::mission_payload::MissionAttachment>>,
    /// `"client"` means the Orb desktop that created the mission runs the CLI.
    /// The backend records the mission and does not start a harness.
    #[serde(default)]
    pub placement: Option<String>,
    /// Managed machine rented for this mission (`start_mission` with
    /// `auto-managed`): once the mission exists it becomes the machine's
    /// owner, and the parent its requester.
    #[serde(default)]
    pub claim_managed_machine_id: Option<String>,
    /// Optional initial TTL (minutes) when Core resolves `auto-managed` server-side.
    #[serde(default)]
    pub managed_ttl_minutes: Option<u64>,
    /// Optional Boat project snapshot name when Core resolves `auto-managed` server-side.
    #[serde(default)]
    pub managed_from_snapshot: Option<String>,
    /// Explicit confirmation for 24h minimum-lease hardware with `auto-managed:scaleway:M2-*`.
    #[serde(default)]
    pub managed_allow_24h_commitment: Option<bool>,
    /// Optional managed-machine spending budget (USD) for this mission and
    /// its descendants. Under an ancestor budget it is a sub-budget and must
    /// fit the ancestor pool's remaining amount.
    #[serde(default)]
    pub budget_usd: Option<f64>,
    /// Run every check a create would run (model, harness auth, caps,
    /// budget) and return `{"valid": true}` without creating anything.
    /// `start_mission` with `auto-managed` calls this before renting a VM.
    #[serde(default)]
    pub validate_only: Option<bool>,
    /// Catch-all for unrecognized request fields. Serde ignores unknown fields
    /// by default, which has repeatedly hidden client bugs (a `prompt` sent
    /// before the field existed, a mistyped `target_mission_id`). Captured
    /// here so the handler can surface them via the `X-Ignored-Fields`
    /// response header and a warning log instead of dropping them silently.
    #[serde(flatten)]
    pub extra: std::collections::HashMap<String, serde_json::Value>,
}

pub(super) fn deserialize_string_patch<'de, D>(
    deserializer: D,
) -> Result<Option<Option<String>>, D::Error>
where
    D: Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer).map(Some)
}

#[derive(Debug, Deserialize)]
pub struct UpdateMissionSettingsRequest {
    /// Backend to use on the next turn ("opencode", "claudecode", "codex", etc.).
    pub backend: Option<String>,
    /// Agent name. Omit to preserve on the same backend, or clear on a backend
    /// switch. Explicit null/empty string also clears it.
    #[serde(default, deserialize_with = "deserialize_string_patch")]
    pub agent: Option<Option<String>>,
    /// Model override. Omit to leave unchanged, null/empty string to clear.
    #[serde(default, deserialize_with = "deserialize_string_patch")]
    pub model_override: Option<Option<String>>,
    /// Model effort. Omit to leave unchanged, null/empty string to clear.
    #[serde(default, deserialize_with = "deserialize_string_patch")]
    pub model_effort: Option<Option<String>>,
    /// Codex fast service tier. Omit to leave unchanged.
    pub fast_mode: Option<bool>,
    pub service_tier: Option<crate::codex_speed::Tier>,
    /// Config profile. Omit to leave unchanged, null/empty string to clear.
    #[serde(default, deserialize_with = "deserialize_string_patch")]
    pub config_profile: Option<Option<String>>,
    /// After a settings change on a Failed/Interrupted mission, queue a
    /// resume on the new settings (default true). A handoff that leaves the
    /// mission dead is the failure mode this exists to remove: the controller
    /// changed the backend, the mission stayed `failed`, work stalled.
    pub resume: Option<bool>,
}

/// Does a settings change on a mission in `previous` status queue a resume?
/// Only terminal-but-resumable statuses; a live, paused or acknowledged
/// mission is left exactly where it is.
pub(super) fn should_queue_resume(previous: MissionStatus, requested: Option<bool>) -> bool {
    requested.unwrap_or(true)
        && matches!(previous, MissionStatus::Failed | MissionStatus::Interrupted)
}

pub(super) fn normalize_model_effort(raw: &str) -> Option<String> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "low" => Some("low".to_string()),
        "medium" => Some("medium".to_string()),
        "high" => Some("high".to_string()),
        "xhigh" => Some("xhigh".to_string()),
        "max" => Some("max".to_string()),
        // Codex-only (gpt-6-astra, gpt-5.6-sol/terra): maximum reasoning with
        // automatic task delegation.
        "ultra" => Some("ultra".to_string()),
        _ => None,
    }
}

pub(super) fn normalize_model_effort_for_backend(
    backend: Option<&str>,
    raw: &str,
) -> Option<String> {
    let normalized = normalize_model_effort(raw)?;
    match (backend, normalized.as_str()) {
        (Some("antigravity"), "low" | "medium" | "high") => Some(normalized),
        (Some("claudecode"), "low" | "medium" | "high" | "xhigh" | "max") => Some(normalized),
        // Codex app-server accepts the GPT reasoning-effort values and passes
        // them through as `reasoningEffort`.
        (Some("codex"), "low" | "medium" | "high" | "xhigh" | "max") => Some(normalized),
        _ => None,
    }
}

pub(super) fn supported_model_efforts_for_backend(backend: Option<&str>) -> &'static str {
    match backend {
        Some("antigravity") => "low, medium, high",
        Some("claudecode") => "low, medium, high, xhigh, max",
        Some("codex") => "low, medium, high, xhigh, max",
        _ => "none",
    }
}

pub(super) fn codex_fast_mode_model_supported(model: Option<&str>) -> bool {
    let Some(model) = model else {
        return false;
    };
    let model = model.rsplit('/').next().unwrap_or(model);
    ["gpt-6.1", "gpt-6", "gpt-5.6", "gpt-5.5", "gpt-5.4"]
        .iter()
        .any(|prefix| model == *prefix || model.starts_with(&format!("{prefix}-")))
}

pub(super) fn validate_fast_mode(
    backend: &str,
    model: Option<&str>,
    fast_mode: bool,
) -> Result<(), String> {
    if !fast_mode {
        return Ok(());
    }
    if backend != "codex" {
        return Err("fast_mode is only supported by the Codex backend".to_string());
    }
    if model.is_none() {
        return Err(format!(
            "fast_mode requires an explicit model_override; without one the Codex default '{}' would be used. Pass model_override with a GPT-6.1, GPT-6, GPT-5.6, GPT-5.5, or GPT-5.4 model (e.g. model_override=\"{}\")",
            resolve_codex_default_model(),
            resolve_codex_default_model()
        ));
    }
    if !codex_fast_mode_model_supported(model) {
        return Err(format!(
            "fast_mode requires an explicit supported model; use a GPT-6.1, GPT-6, GPT-5.6, GPT-5.5, or GPT-5.4 model (received '{}')",
            model.unwrap_or("none")
        ));
    }
    Ok(())
}

pub(super) fn normalize_string_patch(value: Option<Option<String>>) -> Option<Option<String>> {
    value.map(|inner| {
        inner.and_then(|value| {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        })
    })
}

/// Default model recorded on a remote Codex mission that did not pick one.
/// `None` when the launch is not a typed remote Codex launch.
pub(super) fn remote_codex_default_model(
    backend: Option<&str>,
    remote_node_id: Option<&str>,
    remote_command: Option<&str>,
) -> Option<String> {
    let remote = remote_node_id.is_some_and(|id| !id.trim().is_empty());
    let raw = remote_command.is_some_and(|c| !c.trim().is_empty());
    (backend == Some("codex") && remote && !raw).then(resolve_codex_default_model)
}

pub(super) fn normalize_model_override_for_backend(
    backend: Option<&str>,
    raw_model: &str,
) -> Option<String> {
    let trimmed = raw_model.trim();
    if trimmed.is_empty() {
        return None;
    }
    if backend == Some("opencode") {
        return Some(
            crate::api::runners::opencode::normalize_opencode_model_id(trimmed).into_owned(),
        );
    }
    if backend == Some("vibe") {
        return Some(trimmed.to_string());
    }
    if backend == Some("codex") && trimmed == "gpt-5.6" {
        return Some("gpt-5.6-sol".to_string());
    }
    if backend == Some("codex") && trimmed == "gpt-6" {
        return Some("gpt-6-astra".to_string());
    }
    if backend == Some("codex") && trimmed == "gpt-6.1" {
        return Some("gpt-6.1-sol".to_string());
    }
    if backend != Some("opencode") {
        if let Some((_, model_id)) = trimmed.split_once('/') {
            if backend == Some("codex") && model_id == "gpt-5.6" {
                return Some("gpt-5.6-sol".to_string());
            }
            if backend == Some("codex") && model_id == "gpt-6" {
                return Some("gpt-6-astra".to_string());
            }
            if backend == Some("codex") && model_id == "gpt-6.1" {
                return Some("gpt-6.1-sol".to_string());
            }
            return Some(model_id.to_string());
        }
    }
    Some(trimmed.to_string())
}

pub(crate) fn native_backend_prefix(raw_model: &str) -> Option<&str> {
    let (prefix, model_id) = raw_model.trim().split_once('/')?;
    if model_id.trim().is_empty() {
        return None;
    }
    match prefix {
        "codex" | "claudecode" | "grok" | "antigravity" | "vibe" => Some(prefix),
        _ => None,
    }
}

pub(super) fn native_backend_agent(raw_agent: &str) -> Option<&'static str> {
    match raw_agent.trim().to_ascii_lowercase().as_str() {
        "codex" => Some("codex"),
        "claudecode" => Some("claudecode"),
        "antigravity" => Some("antigravity"),
        "vibe" => Some("vibe"),
        "grok" => Some("grok"),
        _ => None,
    }
}

/// Consume native harness names used through the legacy `agent` field.
///
/// These values select a backend; they are not library/sub-agent names and
/// must not reach the native CLI (Claude Code would otherwise receive e.g.
/// `--agent claudecode`). OpenCode remains the exception because it can have a
/// real library agent named `codex`.
pub(crate) fn apply_native_backend_agent_selector(
    agent: &mut Option<String>,
    backend: &mut Option<String>,
) -> Result<(), String> {
    let Some(agent_backend) = agent.as_deref().and_then(native_backend_agent) else {
        return Ok(());
    };

    match backend.as_deref() {
        None => {
            *backend = Some(agent_backend.to_string());
            *agent = None;
        }
        Some("opencode") => {}
        Some(selected) if selected != agent_backend => {
            return Err(format!(
                "Agent '{}' selects backend '{}', but mission backend is '{}'",
                agent.as_deref().unwrap_or_default(),
                agent_backend,
                selected
            ));
        }
        Some(_) => *agent = None,
    }

    Ok(())
}

/// Whether `session_id` names a real Hermes session, when that is checkable.
///
/// `None` means "could not check" — no `HERMES_STATE_DB` configured, or the
/// database was unreadable — and the caller must treat the id as plausible.
/// The distinction between "not found" and "could not ask" is load-bearing:
/// refusing stamps whenever the check is unavailable would strip attribution
/// on every deployment that runs without a Hermes state database.
pub(super) fn hermes_session_exists(session_id: &str) -> Option<bool> {
    let path = super::super::projects_overview::hermes_state_db_path()?;
    let connection =
        rusqlite::Connection::open_with_flags(&path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .ok()?;
    connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?1)",
            [session_id],
            |row| row.get::<_, bool>(0),
        )
        .ok()
}

/// Window inside which an identical create is treated as a retry, not intent.
///
/// Measured 2026-08-05 on prod: seven groups of missions with the same title
/// and the same origin session created 26–90 seconds apart, one of them a
/// triple (`PR #2231 writer-fix v2`, three copies in 69 seconds). The shape is
/// always the same — an agent calls `start_mission`, the answer is slow or the
/// MCP transport errors, the agent retries, and a full duplicate mission runs
/// to completion. Ten minutes comfortably covers every observed retry gap
/// while staying far below the cadence at which a controller legitimately
/// re-dispatches the same lane (hours).
pub(super) const CREATE_RETRY_WINDOW_SECS: i64 = 600;

/// A recent, non-terminal mission that an identical create should coalesce to.
///
/// Conservative on purpose — all four must hold:
/// * the incoming request carries an explicit, non-empty title that matches
///   exactly (trimmed); auto-titled creates never coalesce,
/// * `origin_session_id` matches exactly (including both absent),
/// * the existing mission is **not terminal** — retrying a failed or
///   completed mission with the same title is a legitimate re-dispatch,
/// * the existing mission was created inside [`CREATE_RETRY_WINDOW_SECS`].
///
/// Scan errors return `None`: creating a duplicate is recoverable (that is
/// today's behaviour), refusing a legitimate create is not.
pub(super) async fn find_recent_identical_mission(
    mission_store: &Arc<dyn MissionStore>,
    title: &str,
    origin_session_id: Option<&str>,
) -> Option<Mission> {
    const PAGE: usize = 100;
    let title = title.trim();
    if title.is_empty() {
        return None;
    }
    let now = chrono::Utc::now();
    let missions = mission_store.list_missions(PAGE, 0).await.ok()?;
    missions.into_iter().find(|mission| {
        // Coalesce only onto work that is genuinely still going to run. NOT
        // simply `!is_terminal()`: `Acknowledged` and `AwaitingUser` are
        // non-terminal but parked — answering a create with a parked mission
        // would silently swallow a deliberate re-dispatch. An unlisted status
        // falls through to "do not coalesce", which is today's behaviour
        // (a duplicate runs) and therefore the safe failure direction.
        let in_flight = matches!(
            mission.status,
            MissionStatus::Pending | MissionStatus::Active | MissionStatus::WaitingBackground
        );
        if !in_flight {
            return false;
        }
        if mission.title.as_deref().map(str::trim) != Some(title) {
            return false;
        }
        if mission.origin_session_id.as_deref() != origin_session_id {
            return false;
        }
        chrono::DateTime::parse_from_rfc3339(&mission.created_at)
            .map(|created| {
                (now - created.with_timezone(&chrono::Utc)).num_seconds() < CREATE_RETRY_WINDOW_SECS
            })
            .unwrap_or(false)
    })
}

/// The model a turn about to be dispatched should actually use, persisting the
/// choice so the UI and the harness agree.
///
/// A mission created before this deployment retired a model still carries that
/// model in `model_override`. That field is current configuration, not
/// transcript — it is what every client reads to say which model the *next*
/// turn will use — so leaving it stale would show one model while another ran.
/// Rewriting it here, on the mission that is dispatching right now, keeps the
/// two the same on both a new turn and a plain refresh. Recorded events and
/// completed turns are untouched, and a mission that is not dispatching is
/// never rewritten. Every dispatch path (new turn, queued message, resume,
/// remote) funnels through this, so they cannot diverge.
///
/// When the upgrade cannot be recorded this returns the stored model unchanged,
/// which for a retired id the pre-harness guard in `mission_runner` then refuses
/// to run. A turn that fails loudly is the intended outcome: it is better than
/// running a retired model, and better than running a model no client reports.
pub(super) async fn model_for_dispatch(
    mission_store: &Arc<dyn MissionStore>,
    mission: &Mission,
) -> Option<String> {
    let stored = mission.model_override.clone()?;
    // Everything this deployment still runs — every Codex, Grok, OpenCode and
    // current Claude selection — passes straight through. Only a retired id is
    // touched, and only ever by replacing it with the current model of its own
    // line, keeping any provider prefix (`anthropic/…`) the caller relies on.
    let upgraded = crate::model_policy::current_claude_model(&stored);
    if upgraded == stored {
        return Some(stored);
    }
    let upgraded = upgraded.into_owned();
    match mission_store
        .update_mission_run_settings(
            mission.id,
            None,
            None,
            Some(Some(&upgraded)),
            None,
            None,
            None,
            None,
            // Settings writes also rewrite `session_id`. Passing the mission's
            // own id back keeps the native harness session — a model upgrade
            // must not cost the conversation its context.
            mission.session_id.as_deref().unwrap_or(""),
        )
        .await
    {
        Ok(_) => {
            tracing::info!(
                mission_id = %mission.id,
                from = %stored,
                to = %upgraded,
                "retired model upgraded for the next turn"
            );
            Some(upgraded)
        }
        Err(error) => {
            // The upgrade could not be recorded. Hand back the stored id
            // unchanged rather than a model no client would report: the
            // pre-harness guard refuses to run a retired id, so this turn fails
            // instead of quietly running either the wrong model or a retired
            // one. The next dispatch retries the upgrade.
            tracing::warn!(
                mission_id = %mission.id,
                from = %stored,
                to = %upgraded,
                %error,
                "could not persist the model upgrade; this turn will be refused rather than run a retired model"
            );
            Some(stored)
        }
    }
}

/// Whether a mission in this status holds its project's single campaign slot.
///
/// Campaign missions are long-running per-project drivers; two of them racing
/// on the same project duplicate work and fight over the same PRs. Anything
/// that can still run (or be resumed) blocks a new campaign: `Pending`
/// (created/queued), `Active`, `AwaitingUser`, `WaitingBackground`, and
/// `Paused`. `Acknowledged` is archived and terminal-in-practice, so it does
/// not hold the slot; a genuinely terminal status never does.
pub(super) fn campaign_slot_held_by(status: MissionStatus) -> bool {
    matches!(
        status,
        MissionStatus::Pending
            | MissionStatus::Active
            | MissionStatus::AwaitingUser
            | MissionStatus::WaitingBackground
            | MissionStatus::Paused
    )
}

pub(super) fn chatgpt_oauth_refresh_invalidated(text: &str) -> bool {
    let t = text.to_ascii_lowercase();
    t.contains("refresh_token_invalidated") || t.contains("chatgpt oauth refresh failed")
}

/// The default host workspace is not one worktree: each mission gets its own
/// generated `mission-<id8>` directory. There, only a mission using the
/// requested directory occupies it (a fork of a blocked mission must not be
/// refused because an unrelated chat is idle on the host). Dedicated
/// workspaces stay single-occupant.
pub(super) async fn live_mission_on_workspace(
    mission_store: &Arc<dyn MissionStore>,
    workspace_id: Uuid,
    working_directory: Option<&str>,
    excluded_parent: Option<Uuid>,
) -> Option<Mission> {
    const PAGE: usize = 200;
    let shared = workspace_id == workspace::DEFAULT_WORKSPACE_ID;
    if shared && working_directory.is_none() {
        return None;
    }
    let directory = working_directory.map(std::path::Path::new);
    let mut offset = 0;
    loop {
        let page = mission_store.list_missions(PAGE, offset).await.ok()?;
        let count = page.len();
        if let Some(mission) = page.into_iter().find(|mission| {
            Some(mission.id) != excluded_parent
                && mission.workspace_id == workspace_id
                && !matches!(mission.backend.as_str(), "cloud_grok_bot" | "cloud_cursor")
                && campaign_slot_held_by(mission.status)
                && (!shared || directory.is_some_and(|dir| mission_uses_directory(mission, dir)))
        }) {
            return Some(mission);
        }
        if count < PAGE {
            return None;
        }
        offset += count;
    }
}

/// The directory as the runner reaches it. An absolute path is walked one
/// component at a time, resolving symlinks before `..` is applied, for as far
/// as the path exists. A relative path is only folded: it belongs to a
/// workspace root this comparison does not know, never to the daemon's
/// current directory.
pub(super) fn normalized_directory(path: &std::path::Path) -> std::path::PathBuf {
    let absolute = path.is_absolute();
    let mut out = std::path::PathBuf::new();
    for part in path.components() {
        match part {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => {
                out.push(other);
                if absolute {
                    if let Ok(real) = std::fs::canonicalize(&out) {
                        out = real;
                    }
                }
            }
        }
    }
    out
}

/// Two spellings of one directory must compare equal, and a directory inside
/// another belongs to the same worktree. A relative path is matched against
/// the end of an absolute one: when in doubt the directory is occupied,
/// because two harnesses writing the same files is the worse error.
pub(super) fn same_directory(a: &std::path::Path, b: &std::path::Path) -> bool {
    let (a, b) = (normalized_directory(a), normalized_directory(b));
    if a.as_os_str().is_empty() || b.as_os_str().is_empty() {
        return false;
    }
    a == b
        || (a.is_absolute() && b.is_absolute() && (a.starts_with(&b) || b.starts_with(&a)))
        || (a.is_relative() && b.ends_with(&a))
        || (b.is_relative() && a.ends_with(&b))
}

pub(super) fn mission_uses_directory(mission: &Mission, dir: &std::path::Path) -> bool {
    match mission.working_directory.as_deref() {
        Some(own) => same_directory(std::path::Path::new(own), dir),
        // Its generated root, or anything the runner accepts below it.
        None => {
            let root = format!("mission-{}", &mission.id.to_string()[..8]);
            normalized_directory(dir)
                .components()
                .any(|part| part.as_os_str() == root.as_str())
        }
    }
}

pub(super) async fn recent_codex_oauth_invalidation(
    mission_store: &Arc<dyn MissionStore>,
) -> Option<Mission> {
    const PAGE: usize = 200;
    let cutoff = chrono::Utc::now() - chrono::Duration::hours(6);
    mission_store
        .list_missions(PAGE, 0)
        .await
        .ok()?
        .into_iter()
        .find(|mission| {
            mission.backend == "codex"
                && matches!(
                    mission.status,
                    MissionStatus::Failed | MissionStatus::Interrupted
                )
                && chatgpt_oauth_refresh_invalidated(
                    mission.short_description.as_deref().unwrap_or(""),
                )
                && chrono::DateTime::parse_from_rfc3339(&mission.updated_at)
                    .ok()
                    .is_some_and(|at| at.with_timezone(&chrono::Utc) >= cutoff)
        })
}

/// Find a non-terminal `track == "campaign"` mission for `project`, if any.
/// Scan errors return `None` (a duplicate campaign is recoverable; refusing a
/// legitimate create is not) — same failure direction as the retry coalescer.
pub(super) async fn find_open_campaign_mission(
    mission_store: &Arc<dyn MissionStore>,
    project: &str,
) -> Option<Mission> {
    const PAGE: usize = 200;
    let filter = crate::api::mission_store::MissionFilter {
        project: Some(project.to_string()),
        track: Some("campaign".to_string()),
        ..Default::default()
    };
    mission_store
        .list_missions_filtered(&filter, PAGE, 0)
        .await
        .ok()?
        .into_iter()
        .find(|mission| campaign_slot_held_by(mission.status))
}

/// Non-terminal missions currently held by a project — the live coordination
/// footprint used to enforce the grant's `parallel_missions` cap and the
/// per-(project, track) dedup. Mirrors `find_open_campaign_mission`'s "slot
/// held" notion (`campaign_slot_held_by`) but across all tracks.
/// The server-side dispatch gate for a project's operator status. `paused` and
/// `archived` block a new mission (with the status code + structured error the
/// handler returns); anything else (`active`, unknown) permits dispatch. Pure so
/// the gate is unit-tested without a full handler.
pub(super) fn dispatch_gate_for_status(status: &str) -> Option<(StatusCode, &'static str)> {
    match status {
        "paused" => Some((StatusCode::LOCKED, "project_paused")),
        "archived" => Some((StatusCode::CONFLICT, "project_archived")),
        _ => None,
    }
}

pub(super) async fn nonterminal_missions_for_project(
    mission_store: &Arc<dyn MissionStore>,
    project: &str,
) -> Vec<Mission> {
    const PAGE: usize = 200;
    let filter = crate::api::mission_store::MissionFilter {
        project: Some(project.to_string()),
        ..Default::default()
    };
    mission_store
        .list_missions_filtered(&filter, PAGE, 0)
        .await
        .ok()
        .unwrap_or_default()
        .into_iter()
        .filter(|mission| campaign_slot_held_by(mission.status))
        .collect()
}

/// Resolve or absorb the track for a freshly created mission and take its
/// lease. On a held writer lease the new mission is durably interrupted
/// (reason `track_owned`) and a 409 is returned; on a missing track under
/// `SANDBOXED_TRACK_REQUIRED` the mission is interrupted with `track_required`
/// and a 400 is returned. Returns the canonical track key.
#[allow(clippy::too_many_arguments)]
pub(super) async fn bind_mission_to_track(
    state: &Arc<AppState>,
    control: &ControlState,
    mission: &Mission,
    project: &str,
    track: Option<&str>,
    title: Option<&str>,
    github_pr: Option<&str>,
    intent: Option<&str>,
    writer_flag: Option<bool>,
    tags: &[String],
    request_is_writer: bool,
    idempotency_key: Option<&str>,
    acceptance_criteria: &[String],
) -> Result<String, (StatusCode, String)> {
    use super::super::track_leases;
    let mission_id = mission.id.to_string();
    let requested = match track.map(str::trim).filter(|value| !value.is_empty()) {
        Some(track) => track.to_string(),
        None if track_leases::track_required() => {
            interrupt_new_mission(control, mission.id, "track_required").await;
            return Err((
                StatusCode::BAD_REQUEST,
                serde_json::json!({
                    "error": "track_required",
                    "project": project,
                    "message": "a project mission must name its track (the plan item it attempts); call get_situation and pass `track`",
                })
                .to_string(),
            ));
        }
        None => {
            let generated = track_leases::generated_track_key(&mission_id);
            tracing::warn!(
                mission_id = %mission_id,
                project,
                track = %generated,
                "project mission dispatched without a track; absorbed under a generated key (compatibility window)"
            );
            generated
        }
    };
    let pr = track_leases::pr_number(github_pr);
    let outcome = state
        .projects
        .absorb_track(project, &requested, title, pr)
        .map_err(internal_error)?;
    if outcome.created || outcome.matched_by == "pr_ref" {
        tracing::info!(
            mission_id = %mission_id,
            project,
            requested = %requested,
            track = %outcome.key,
            matched_by = outcome.matched_by,
            "mission track absorbed onto the plan"
        );
    }
    let mode = if request_is_writer {
        "writer"
    } else {
        track_leases::lease_mode(writer_flag, tags, intent)
    };
    // A dispatch may declare or revise the track's acceptance contract, but
    // never a satisfied track's (planning rules apply).
    if !acceptance_criteria.is_empty() {
        if let Err(error) = state.projects.patch_track(
            project,
            &outcome.key,
            None,
            None,
            None,
            Some(acceptance_criteria),
            None,
        ) {
            tracing::warn!(mission_id = %mission_id, project, track = %outcome.key, %error,
                "could not declare acceptance criteria from dispatch");
        }
    }
    let request =
        track_leases::lease_request(project, &outcome.key, &mission_id, mode, idempotency_key);
    match track_leases::acquire_locked(state, &request).await {
        Ok(_) => Ok(outcome.key),
        Err(super::super::projects_store::LeaseError::Store(error)) => {
            interrupt_new_mission(control, mission.id, "track_lease_unavailable").await;
            Err(internal_error(error))
        }
        Err(super::super::projects_store::LeaseError::NotFound) => Err(internal_error(format!(
            "track '{}' of '{project}' vanished between absorption and lease",
            outcome.key
        ))),
        Err(error @ super::super::projects_store::LeaseError::Owned { .. }) => {
            interrupt_new_mission(control, mission.id, "track_owned").await;
            Err((
                StatusCode::CONFLICT,
                track_leases::owned_body(project, &outcome.key, &error).to_string(),
            ))
        }
    }
}

/// Durably interrupt a mission that lost an admission check after creation,
/// so it can never receive a goal or become a writer.
pub(super) async fn interrupt_new_mission(control: &ControlState, mission_id: Uuid, reason: &str) {
    if let Err(error) = control
        .mission_store
        .update_mission_status_with_reason(mission_id, MissionStatus::Interrupted, Some(reason))
        .await
    {
        tracing::warn!(mission_id = %mission_id, %error, reason, "could not interrupt rejected mission");
    }
    let _ = control.events_tx.send(AgentEvent::MissionStatusChanged {
        completion: None,
        execution: None,
        mission_id,
        status: MissionStatus::Interrupted,
        summary: Some(reason.to_string()),
    });
}

// Coalescing a create must not acknowledge attachment selections that were
// never saved on the existing mission. New context belongs in a follow-up.
pub(super) fn verify_coalesced_attachments(
    config: &Config,
    req: &CreateMissionRequest,
    existing: &Mission,
) -> Result<(), (StatusCode, String)> {
    if req.service_tier.is_some()
        && crate::codex_speed::Tier::from_legacy(req.service_tier, req.fast_mode)
            != crate::codex_speed::Tier::from_legacy(existing.service_tier, existing.fast_mode)
    {
        return Err((StatusCode::CONFLICT,"The existing mission has a different speed selection. Change its settings or use a distinct idempotency key.".into()));
    }
    if existing.backend == "codex" || req.cyber_access.is_some() {
        let requested_mode = match (req.cyber_access, req.supersedes_mission_id) {
            (Some(mode), _) => mode,
            (None, Some(source)) if existing.backend == "codex" => {
                cyber::read(&config.working_dir, source)
                    .map_err(internal_error)?
                    .mode
            }
            _ => cyber::Mode::Automatic,
        };
        if cyber::read(&config.working_dir, existing.id)
            .map_err(internal_error)?
            .mode
            != requested_mode
        {
            return Err((StatusCode::CONFLICT,"The existing mission has a different cyber selection. Use its settings or a distinct idempotency key/title.".into()));
        }
    }
    if let Some(attachments) = req.attachments.as_ref().filter(|a| !a.is_empty()) {
        let saved = crate::api::mission_payload::read_sidecar(&config.working_dir, existing.id)
            .map_err(internal_error)?;
        if !saved.is_some_and(|p| p.attachments == *attachments && p.project == req.project) {
            return Err((StatusCode::CONFLICT, format!("mission {} already exists with different or unavailable attachments; send the attachments as a follow-up or use a distinct title", existing.id)));
        }
    }
    Ok(())
}

/// Resolve the complete successor lineage of a replacement's inherited parent.
/// Creation uses the last ID; deletion retains every intermediate record needed
/// to reach it. Store failures and cycles cannot prove a disjoint dependency.
pub(super) async fn replacement_parent_lineage(
    store: &Arc<dyn MissionStore>,
    prior_id: Uuid,
) -> Result<Vec<Uuid>, String> {
    let Some(prior) = store.get_mission(prior_id).await? else {
        return Ok(Vec::new());
    };
    let mut id = prior.parent_mission_id;
    let mut lineage = Vec::new();
    for _ in 0..64 {
        let Some(current) = id else {
            return Ok(lineage);
        };
        if lineage.contains(&current) {
            return Err("Replacement parent chain contains a cycle".into());
        }
        lineage.push(current);
        let Some(mission) = store.get_mission(current).await? else {
            return Ok(lineage);
        };
        id = mission
            .project
            .tags
            .iter()
            .rev()
            .find_map(|tag| tag.strip_prefix("superseded_by:"))
            .and_then(|raw| Uuid::parse_str(raw).ok());
        if id.is_none() || id == Some(current) {
            return Ok(lineage);
        }
    }
    Err("Replacement parent chain exceeds the resolution limit".into())
}

pub async fn create_mission(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    body: Option<Json<CreateMissionRequest>>,
) -> Result<(axum::http::HeaderMap, Json<serde_json::Value>), (StatusCode, String)> {
    let mut body = body;
    if let Some(req) = body.as_mut() {
        if let Some(selection) = req.extra.remove("cloud") {
            let selection = serde_json::from_value(selection).map_err(|e| {
                (
                    StatusCode::BAD_REQUEST,
                    format!("Invalid cloud selection: {e}"),
                )
            })?;
            return super::super::cloud_agents::http::create(
                state,
                user,
                body.unwrap().0,
                selection,
            )
            .await;
        }
    }
    create_mission_inner(State(state), Extension(user), body, false, None).await
}

pub(in crate::api) async fn create_mission_inner(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    body: Option<Json<CreateMissionRequest>>,
    shared_side_workspace: bool,
    side_launch_fingerprint: Option<&str>,
) -> Result<(axum::http::HeaderMap, Json<serde_json::Value>), (StatusCode, String)> {
    let (tx, rx) = oneshot::channel();

    let mut req = body.map(|b| b.0).unwrap_or(CreateMissionRequest {
        cyber_access: None,
        title: None,
        workspace_id: None,
        agent: None,
        model_override: None,
        model_effort: None,
        fast_mode: false,
        service_tier: None,
        config_profile: None,
        backend: None,
        parent_mission_id: None,
        supersedes_mission_id: None,
        working_directory: None,
        priority: None,
        not_before: None,
        deadline: None,
        project: None,
        track: None,
        idempotency_key: None,
        intent: None,
        github_pr: None,
        writer: None,
        acceptance_criteria: Vec::new(),
        tags: None,
        desired_state: None,
        next_check_at: None,
        prompt: None,
        remote_node_id: None,
        remote_requirements: None,
        remote_command: None,
        remote_async: None,
        estimated_disk_gib: None,
        origin: None,
        origin_session_id: None,
        attachments: None,
        placement: None,
        claim_managed_machine_id: None,
        managed_ttl_minutes: None,
        managed_from_snapshot: None,
        managed_allow_24h_commitment: None,
        budget_usd: None,
        validate_only: None,
        extra: Default::default(),
    });

    let parent_control = control_for_user(&state, &user).await;
    // A mission started from the Hermes session of a mission (`orb_<id>`,
    // a Hermes cloud agent calling start_mission) is that mission's child.
    // Unlike shared chat sessions, an `orb_<id>` session belongs to exactly
    // one mission, so it is real lineage. Resolve before `worker_location::inherit`
    // so child placement defaults apply uniformly.
    if req.parent_mission_id.is_none() && req.supersedes_mission_id.is_none() {
        if let Some(caller) = req
            .origin_session_id
            .as_deref()
            .and_then(crate::managed::lifecycle::mission_of_orb_session)
        {
            if matches!(
                parent_control.mission_store.get_mission(caller).await,
                Ok(Some(_))
            ) {
                req.parent_mission_id = Some(caller);
            }
        }
    }
    worker_location::inherit_for_user(&state, &parent_control, Some(&user.id), &mut req)
        .await
        .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
    // A replacement continues the same conversation, so it stays under the
    // superseded mission's parent (e.g. a coordinator's worker dispatch) unless
    // the caller places it elsewhere. Without this, replacements created by Orb
    // or the API surfaced as top-level missions detached from their coordinator.
    if req.parent_mission_id.is_none() {
        if let Some(prior_id) = req.supersedes_mission_id {
            req.parent_mission_id =
                replacement_parent_lineage(&parent_control.mission_store, prior_id)
                    .await
                    .map_err(internal_error)?
                    .last()
                    .copied();
        }
    }
    if req.parent_mission_id.is_none() {
        if let Some(caller) = req
            .origin_session_id
            .as_deref()
            .and_then(crate::managed::lifecycle::mission_of_orb_session)
        {
            if matches!(
                parent_control.mission_store.get_mission(caller).await,
                Ok(Some(_))
            ) {
                req.parent_mission_id = Some(caller);
            }
        }
    }

    // A generated track ("mission-<8 hex>") belongs to the mission that
    // created it. A replacement that carries its predecessor's (or an older
    // ancestor's) generated track would fail the remote queue's writer check:
    // follow-ups were refused with REMOTE_JOB_STILL_RUNNING instead of queued.
    if let (Some(prior_id), Some(track)) = (req.supersedes_mission_id, req.track.clone()) {
        let prior_track = parent_control
            .mission_store
            .get_mission(prior_id)
            .await
            .map_err(internal_error)?
            .and_then(|prior| prior.project.track);
        if replacement_drops_track(prior_id, prior_track.as_deref(), &track) {
            req.track = None;
        }
    }

    if let Some(prompt) = req.prompt.as_deref() {
        crate::api::mission_payload::validate_user_content(prompt)
            .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
        if let Some(attachments) = req.attachments.as_mut() {
            attachments.retain(|item| {
                !(item.kind == crate::api::mission_payload::AttachmentKind::File
                    && item
                        .path
                        .as_deref()
                        .map(|p| p.starts_with('/') && prompt.contains(&format!("[Uploaded: {p}]")))
                        .unwrap_or(false))
            });
        }
    }

    if let Some(attachments) = req.attachments.as_ref().filter(|a| !a.is_empty()) {
        if req.remote_node_id.is_some()
            && attachments.iter().any(|item| {
                !matches!(
                    item.kind,
                    crate::api::mission_payload::AttachmentKind::Context
                        | crate::api::mission_payload::AttachmentKind::Path
                )
            })
        {
            return Err((
                StatusCode::BAD_REQUEST,
                "remote launch attachments are not supported".into(),
            ));
        }
        if req.project.as_deref().is_none_or(|p| p.trim().is_empty()) {
            return Err((
                StatusCode::BAD_REQUEST,
                "attachments require a project".into(),
            ));
        }
        crate::api::mission_payload::validate(&crate::api::mission_payload::MissionPayload {
            attachments: attachments.clone(),
            project: req.project.clone(),
            controller_md: None,
        })
        .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    }

    // Persist the roster slug, not a nickname. An inverted alias
    // (`coldcard-rng-cracker` → `ec-defensive-research`) made Coldcard
    // missions and STATE_SIGNATURE trailers unroutable.
    if let Some(raw) = req
        .project
        .as_deref()
        .map(str::trim)
        .filter(|slug| !slug.is_empty())
        .map(str::to_string)
    {
        let canonical = state.projects.resolve_project_slug(&raw);
        if canonical != raw {
            tracing::info!(
                from = %raw,
                to = %canonical,
                "canonicalized mission project tag via alias or roster title"
            );
            req.project = Some(canonical);
        }
    }

    // Fail loud on unrecognized fields: log + surface in a response header so
    // a client bug (typo, field sent to the wrong endpoint) is observable
    // instead of silently changing behavior.
    let mut headers = axum::http::HeaderMap::new();
    // Serialize keyed child dispatches through persistence and initial delivery.
    // The receipt is stored on the mission, so response loss survives restarts.
    let dispatch_tag = req
        .parent_mission_id
        .zip(req.idempotency_key.as_deref())
        .filter(|(_, key)| !key.trim().is_empty())
        .map(|(parent, key)| {
            format!(
                "worker-dispatch:{}",
                Uuid::new_v5(&parent, key.trim().as_bytes())
            )
        });
    let _dispatch_guard = match dispatch_tag.as_deref() {
        Some(key) => Some(
            worker_location::dispatch_lock(&format!("{}:{key}", user.id))
                .lock_owned()
                .await,
        ),
        None => None,
    };
    if let Some(tag) = dispatch_tag.as_ref() {
        let existing = parent_control
            .mission_store
            .list_missions_filtered(
                &crate::api::mission_store::MissionFilter {
                    tag: Some(tag.clone()),
                    ..Default::default()
                },
                1,
                0,
            )
            .await
            .map_err(internal_error)?;
        if let Some(existing) = existing.into_iter().next() {
            worker_location::require_initialized(&existing)?;
            verify_coalesced_attachments(&state.config, &req, &existing)?;
            // Recover a crash between mission persistence and initial delivery.
            // Orb's durable receipt makes a repeated initial message harmless.
            if existing.status == MissionStatus::Pending
                && worker_location::client_owner(&existing).is_some()
            {
                if let Some(prompt) = req.prompt.as_deref().filter(|s| !s.trim().is_empty()) {
                    let prompt =
                        canonical_goal_message(prompt).unwrap_or_else(|| prompt.to_owned());
                    worker_location::enqueue(
                        &parent_control.mission_store,
                        existing.id,
                        worker_location::initial_delivery_id(existing.id),
                        prompt,
                    )
                    .await
                    .map_err(internal_error)?;
                }
            }
            return Ok((
                headers,
                Json(mission_create_response(&state, &parent_control, existing).await?),
            ));
        }
        req.tags.get_or_insert_with(Vec::new).push(tag.clone());
        // Track leases share a store; two different parents may both name
        // their first task "task-1" without coalescing onto one another.
        req.idempotency_key = req.idempotency_key.take().map(|key| {
            format!(
                "worker:{}:{}",
                req.parent_mission_id.expect("worker key has parent"),
                key.trim()
            )
        });
    }
    if !req.extra.is_empty() {
        let ignored: Vec<&str> = req.extra.keys().map(String::as_str).collect();
        let joined = ignored.join(",");
        tracing::warn!(
            user_id = %user.id,
            ignored_fields = %joined,
            "create_mission request carried unrecognized fields (ignored)"
        );
        if let Ok(value) = axum::http::HeaderValue::from_str(&joined) {
            headers.insert("x-ignored-fields", value);
        }
    }

    // Retried dispatch: the caller's idempotency key already holds a live
    // track lease. Answer with the mission that holds it instead of creating
    // (and then interrupting) a duplicate.
    if let Some(key) = req
        .idempotency_key
        .as_deref()
        .map(str::trim)
        .filter(|key| side_launch_fingerprint.is_none() && !key.is_empty())
    {
        if let Ok(Some(lease)) = state.projects.lease_by_key(&format!("lease:{key}")) {
            if let Ok(mission_id) = Uuid::parse_str(&lease.attempt_id) {
                let control_state = control_for_user(&state, &user).await;
                if let Ok(Some(existing)) =
                    control_state.mission_store.get_mission(mission_id).await
                {
                    // A dispatch that already failed closed (for example a
                    // rejected remote submission) is not the work the retry
                    // asks for; only live or finished attempts coalesce.
                    if existing.status != MissionStatus::Failed {
                        verify_coalesced_attachments(&state.config, &req, &existing)?;
                        tracing::info!(
                            mission_id = %existing.id,
                            idempotency_key = key,
                            "create_mission coalesced onto the mission holding this dispatch key"
                        );
                        if let Ok(value) =
                            axum::http::HeaderValue::from_str(&existing.id.to_string())
                        {
                            headers.insert("x-coalesced-with", value);
                        }
                        let value =
                            mission_create_response(&state, &control_state, existing).await?;
                        return Ok((headers, Json(value)));
                    }
                }
            }
        }
    }

    // Retry-shaped duplicate? Same explicit title, same origin session, an
    // existing NON-terminal mission created moments ago: answer with that
    // mission instead of running the work twice. The response carries a header
    // so the caller can tell a coalesced answer from a fresh create; a client
    // that genuinely wants a parallel duplicate retitles it.
    if let Some(title) = req.title.as_deref().filter(|t| {
        side_launch_fingerprint.is_none() && !t.trim().is_empty() && req.parent_mission_id.is_none()
    }) {
        let control_state = control_for_user(&state, &user).await;
        if let Some(existing) = find_recent_identical_mission(
            &control_state.mission_store,
            title,
            req.origin_session_id.as_deref(),
        )
        .await
        {
            verify_coalesced_attachments(&state.config, &req, &existing)?;
            tracing::info!(
                mission_id = %existing.id,
                title = %title,
                "create_mission coalesced onto a recent identical mission \
                 (retry-shaped duplicate)"
            );
            if let Ok(value) = axum::http::HeaderValue::from_str(&existing.id.to_string()) {
                headers.insert("x-coalesced-with", value);
            }
            let value = mission_create_response(&state, &control_state, existing).await?;
            return Ok((headers, Json(value)));
        }
    }

    // Lineage guard: a child spawned by a mission that is parked on a remote
    // build, on the same project/track, is a poller in disguise. Refuse it
    // with the job id so the parent attaches or waits instead. Lineage is the
    // explicit parent_mission_id, never origin_session_id (which sibling
    // missions share).
    if let (Some(parent_id), Some(project), Some(track)) = (
        req.parent_mission_id,
        req.project
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty()),
        req.track
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty()),
    ) {
        let control_state = control_for_user(&state, &user).await;
        if let Ok(Some(parent)) = control_state.mission_store.get_mission(parent_id).await {
            let same_project = parent
                .project
                .project
                .as_deref()
                .map(super::super::projects_overview::canonicalize_project_slug)
                .is_some_and(|slug| {
                    slug == super::super::projects_overview::canonicalize_project_slug(project)
                });
            let same_track = parent
                .project
                .track
                .as_deref()
                .map(super::super::projects_store::normalize_track_key)
                .is_some_and(|key| key == super::super::projects_store::normalize_track_key(track));
            if same_project && same_track {
                if let Ok(Some(handle)) =
                    crate::remote_node::job_ledger::current_remote_build_wait_handle(
                        &state.config.working_dir,
                        parent_id,
                    )
                    .await
                {
                    tracing::info!(
                        parent_mission_id = %parent_id,
                        job_id = %handle.job_id,
                        project,
                        track,
                        "create_mission rejected: parent is waiting on a remote build for this track"
                    );
                    return Err((
                        StatusCode::CONFLICT,
                        serde_json::json!({
                            "error": "BUILD_IN_PROGRESS",
                            "job_id": handle.job_id,
                            "node_id": handle.node_id,
                            "parent_mission_id": parent_id,
                            "message": "the parent mission already waits on a remote build for this track; do not spawn a helper to poll it — the parent is woken when the job ends, and re-running the same build command attaches to it",
                        })
                        .to_string(),
                    ));
                }
            }
        }
    }

    // Campaign uniqueness guard: at most one non-terminal campaign mission per
    // project. Checked on the explicit request tags (project inherited from a
    // bound conversation never carries track="campaign").
    if let (Some(project), Some("campaign")) = (
        req.project
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty()),
        req.track
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty()),
    ) {
        let control_state = control_for_user(&state, &user).await;
        if let Some(existing) =
            find_open_campaign_mission(&control_state.mission_store, project).await
        {
            tracing::info!(
                mission_id = %existing.id,
                project = %project,
                "create_mission rejected: a non-terminal campaign mission already \
                 exists for this project"
            );
            return Err((
                StatusCode::CONFLICT,
                serde_json::json!({
                    "error": "campaign_exists",
                    "mission_id": existing.id.to_string(),
                })
                .to_string(),
            ));
        }
    }

    // Native coordination guard (resilient — no external fleet daemon needed):
    // enforce the project's declared `parallel_missions` cap, which was only
    // advisory. This is the over-subscription filet that stops two controllers
    // (or one launching cross-project) from piling missions onto a project past
    // what its grant allows. Only bites when the grant sets a cap > 0 — projects
    // without a cap are unaffected. (A per-(project, track) dedup is a
    // deliberate follow-up: a track is sometimes legitimately shared by a
    // writer+reviewer pair, so a hard dedup needs track-semantics confirmation
    // before it can safely reject.)
    if let Some(project) = req
        .project
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        // `paused`/`archived` are now a real server-side dispatch gate, not just
        // a board presentation: an operator who paused a project must not have a
        // controller keep piling missions onto it. Gates on the authoritative
        // roster status (`set_project_status`); the board-override pause is a
        // separate presentation flag reconciled into status in a later phase.
        if let Ok(Some(record)) = state.projects.get_project(project) {
            if let Some((code, error)) = dispatch_gate_for_status(&record.status) {
                tracing::info!(
                    project,
                    status = %record.status,
                    "create_mission rejected: project status blocks dispatch"
                );
                return Err((code, serde_json::json!({ "error": error }).to_string()));
            }
        }

        if let Ok(Some(grant)) = state.projects.get_grant(project) {
            if let Some(cap) = grant.parallel_missions.filter(|&c| c > 0) {
                let control_state = control_for_user(&state, &user).await;
                let active =
                    nonterminal_missions_for_project(&control_state.mission_store, project).await;
                if active.len() as i64 >= cap {
                    tracing::info!(
                        project,
                        cap,
                        active = active.len(),
                        "create_mission rejected: project is at its parallel_missions cap"
                    );
                    return Err((
                        StatusCode::TOO_MANY_REQUESTS,
                        serde_json::json!({
                            "error": "parallel_missions_cap",
                            "cap": cap,
                            "active": active.len(),
                        })
                        .to_string(),
                    ));
                }
            }
        }
    }

    // One live occupant per worktree. Lido E1 spawned a parallel Codex
    // worker (`6f1e92b0`) on the same workspace as the existing writer;
    // ChatGPT OAuth is single-use and the extra occupant also races the
    // files. Sequential certify-after-repair is fine: the writer is terminal.
    if let Some(ws_id) = req.workspace_id.filter(|_| !shared_side_workspace) {
        let control_state = control_for_user(&state, &user).await;
        if let Some(existing) = live_mission_on_workspace(
            &control_state.mission_store,
            ws_id,
            req.working_directory.as_deref(),
            req.parent_mission_id
                .filter(|_| ws_id == workspace::DEFAULT_WORKSPACE_ID),
        )
        .await
        {
            tracing::info!(
                workspace_id = %ws_id,
                existing = %existing.id,
                "create_mission rejected: workspace already has a live mission"
            );
            return Err((
                StatusCode::CONFLICT,
                serde_json::json!({
                    "error": "workspace_occupied",
                    "mission_id": existing.id.to_string(),
                    "title": existing.title,
                    "message": "this worktree already has a live mission; wait for it or reuse that mission instead of launching a parallel worker",
                })
                .to_string(),
            ));
        }
    }

    if req
        .backend
        .as_deref()
        .map(str::trim)
        .is_some_and(|b| b.eq_ignore_ascii_case("codex"))
    {
        let control_state = control_for_user(&state, &user).await;
        if let Some(failed) = recent_codex_oauth_invalidation(&control_state.mission_store).await {
            tracing::info!(
                failed = %failed.id,
                "create_mission rejected: Codex ChatGPT OAuth refresh is invalidated"
            );
            return Err((
                StatusCode::CONFLICT,
                serde_json::json!({
                    "error": "codex_oauth_invalidated",
                    "mission_id": failed.id.to_string(),
                    "message": "Codex ChatGPT OAuth refresh is invalidated (refresh_token_invalidated). Do not retry on backend=codex. Use claudecode, kimi, or glm on the existing worktree writer.",
                })
                .to_string(),
            ));
        }
    }

    let title = req.title.clone();
    let workspace_id = req.workspace_id;
    let mut agent = req.agent.clone();
    let config_profile = req.config_profile.clone();
    let mut backend = req.backend.clone();
    let mut model_override = req.model_override.clone();
    let mut model_effort = req.model_effort.clone();
    if let Some(value) = backend.as_ref() {
        if value.trim().is_empty() {
            backend = None;
        }
    }
    if let Some(value) = model_override.as_ref() {
        if value.trim().is_empty() {
            model_override = None;
        }
    }
    if let Some(value) = model_effort.as_ref() {
        if value.trim().is_empty() {
            model_effort = None;
        }
    }

    // Hermes historically used `agent="codex"` as the native harness selector
    // while leaving `backend` unset. Treat native harness agent names as an
    // unambiguous backend hint before applying the server default. Library
    // agent names such as `build` or `plan` remain independent of the backend.
    if let Err(error) = apply_native_backend_agent_selector(&mut agent, &mut backend) {
        return Err((StatusCode::BAD_REQUEST, error));
    }

    // Native harness-qualified model IDs (for example
    // `codex/gpt-5.6-terra`) carry an unambiguous backend. Hermes and older
    // orchestrator clients use this compact form. Resolve it before applying
    // the server default, otherwise the model is incorrectly validated against
    // that default backend's catalog (commonly Anthropic/Claude Code).
    if let Some(model) = model_override.as_deref() {
        if let Some(prefixed_backend) = native_backend_prefix(model) {
            match backend.as_deref() {
                None => backend = Some(prefixed_backend.to_string()),
                Some("opencode") => {}
                Some(selected) if selected != prefixed_backend => {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        format!(
                            "Model '{}' selects backend '{}', but mission backend is '{}'",
                            model, prefixed_backend, selected
                        ),
                    ));
                }
                Some(_) => {}
            }
        }
    }

    // If no backend specified, use the default from registry
    // This needs to happen BEFORE agent validation so we validate against the correct backend
    if backend.is_none() {
        let registry = state.backend_registry.read().await;
        backend = Some(registry.default_id().to_string());
    }

    if backend.as_deref() == Some("codex") {
        if let Some(prompt) = req.prompt.as_deref() {
            crate::backend::codex::validate_goal_message(prompt)
                .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
        }
    }
    if backend.as_deref() == Some("antigravity") {
        if let Some(prompt) = req.prompt.as_deref() {
            crate::antigravity::validate_prompt(prompt)
                .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
        }
    }

    // Model effort is supported for Codex and Claude Code missions.
    if !matches!(
        backend.as_deref(),
        Some("codex") | Some("claudecode") | Some("antigravity")
    ) {
        model_effort = None;
    } else if let Some(value) = model_effort.as_ref() {
        model_effort = normalize_model_effort_for_backend(backend.as_deref(), value);
        if model_effort.is_none() {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "Invalid model_effort for backend '{}'. Supported values: {}",
                    backend.as_deref().unwrap_or("unknown"),
                    supported_model_efforts_for_backend(backend.as_deref())
                ),
            ));
        }
    }

    // Normalize model override based on backend expectations.
    // OpenCode expects provider/model; Claude Code and Codex expect raw model IDs.
    if let Some(ref raw_model) = model_override {
        model_override = normalize_model_override_for_backend(backend.as_deref(), raw_model);
    }

    // Resolve the effective config profile:
    // 1. Use explicit config_profile from request if provided
    // 2. Otherwise use workspace's config_profile
    // 3. Fall back to "default"
    let effective_config_profile = if let Some(ref profile) = config_profile {
        Some(profile.clone())
    } else if let Some(ws_id) = workspace_id {
        state
            .workspaces
            .get(ws_id)
            .await
            .and_then(|ws| ws.config_profile)
    } else {
        None
    };

    // Validate backend exists
    if let Some(ref backend_id) = backend {
        if let Some(message) = crate::backend::retired_backend_error(backend_id) {
            return Err((StatusCode::BAD_REQUEST, message.to_string()));
        }
        let registry = state.backend_registry.read().await;
        if registry.get(backend_id).is_none() {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "Unknown backend: {}. Use one of: {}",
                    backend_id,
                    registry
                        .list()
                        .into_iter()
                        .map(|b| b.id)
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            ));
        }
    }

    // A remote Codex launch routes through this core's proxy and the node has
    // no ChatGPT login of its own, so it must run an explicit model. Callers
    // (agents using start_mission) rarely pass one: resolve the configured
    // Codex default here and record it on the mission instead of failing
    // with REMOTE_MODEL_REQUIRED.
    if model_override.is_none() {
        model_override = remote_codex_default_model(
            backend.as_deref(),
            req.remote_node_id.as_deref(),
            req.remote_command.as_deref(),
        );
    }

    // Validate model override if provided
    if let Some(ref model) = model_override {
        let backend_id = backend.as_deref().unwrap_or("claudecode");
        if let Err(e) =
            super::super::providers::validate_model_override(&state, backend_id, model).await
        {
            return Err((StatusCode::BAD_REQUEST, e));
        }
    }

    let requested_tier = crate::codex_speed::Tier::from_legacy(req.service_tier, req.fast_mode);
    req.fast_mode = requested_tier == crate::codex_speed::Tier::Fast;
    if !client_placement::is_client_placement(req.placement.as_deref()) {
        speed::validate(
            &state.config.working_dir,
            backend.as_deref().unwrap_or("unknown"),
            model_override.as_deref(),
            requested_tier,
            None,
        )
        .await
        .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
    }
    validate_fast_mode(
        backend.as_deref().unwrap_or("unknown"),
        model_override.as_deref(),
        req.fast_mode,
    )
    .map_err(|error| (StatusCode::BAD_REQUEST, error))?;

    // If no model_override specified, resolve from config profile for Claude Code
    if backend.as_deref() == Some("claudecode") && model_override.is_none() {
        if let Some(default_model) =
            resolve_claudecode_default_model(&state.library, effective_config_profile.as_deref())
                .await
        {
            model_override = Some(default_model);
        }
    }

    // Fail before persist when the chosen workspace cannot run the harness
    // and cannot auto-install it. Coldcard twice launched Codex on
    // `dgx-spark` (no CLI, no npm/bun); both missions died in minutes
    // and the completion never reached the dedicated session.
    //
    // Remote-node missions execute on the selected node, not in the local
    // workspace, so probing the local/container CLI would reject perfectly
    // runnable work — skip the preflight for them.
    let client_placement = client_placement::is_client_placement(req.placement.as_deref());
    if client_placement
        && req
            .remote_node_id
            .as_deref()
            .map(str::trim)
            .is_some_and(|id| !id.is_empty())
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "placement client cannot target a remote node".into(),
        ));
    }
    // A client placement executes on the Orb machine, same as a remote node:
    // do not probe the backend host for the CLI.
    let runs_locally = !client_placement
        && req
            .remote_node_id
            .as_deref()
            .map(str::trim)
            .is_none_or(str::is_empty);
    if runs_locally {
        if let Some(directory) = req.working_directory.as_deref() {
            let workspace =
                workspace::resolve_workspace(&state.workspaces, &state.config, workspace_id).await;
            if workspace.workspace_type == crate::workspace::WorkspaceType::Host {
                let tags = req.tags.get_or_insert_with(Vec::new);
                if !tags
                    .iter()
                    .any(|tag| tag == super::super::mission_runner::HOST_STATE_TAG)
                {
                    tags.push(super::super::mission_runner::HOST_STATE_TAG.to_string());
                }
            }
            super::super::mission_runner::ensure_mission_working_directory(
                &workspace.path,
                workspace.workspace_type,
                directory,
                &super::super::fs::path_allowed_roots(&state),
            )
            .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
            req.working_directory = Some(
                super::super::mission_runner::resolve_mission_working_directory(
                    &workspace.path,
                    workspace.workspace_type,
                    directory,
                )
                .map_err(|error| (StatusCode::BAD_REQUEST, error))?
                .to_string_lossy()
                .into_owned(),
            );
        }
    }
    if let (true, Some(ws_id), Some(backend_id)) = (runs_locally, workspace_id, backend.as_deref())
    {
        if matches!(
            backend_id,
            "codex" | "claudecode" | "grok" | "antigravity" | "vibe"
        ) {
            if let Some(workspace) = state.workspaces.get(ws_id).await {
                let cli_path =
                    if matches!(backend_id, "claudecode" | "codex" | "antigravity" | "vibe") {
                        state
                            .backend_configs
                            .get(backend_id)
                            .await
                            .and_then(|config| {
                                config
                                    .settings
                                    .get("cli_path")
                                    .and_then(|value| value.as_str())
                                    .map(str::to_string)
                            })
                    } else {
                        None
                    };
                let preflight = super::super::mission_runner::check_backend_prerequisites(
                    &workspace,
                    backend_id,
                    cli_path.as_deref(),
                )
                .await;
                if !preflight.available && !preflight.auto_install_possible {
                    tracing::warn!(
                        workspace_id = %ws_id,
                        backend = backend_id,
                        message = ?preflight.message,
                        "create_mission rejected: harness unavailable in workspace"
                    );
                    return Err((
                        StatusCode::CONFLICT,
                        serde_json::json!({
                            "error": "harness_unavailable",
                            "backend": backend_id,
                            "workspace_id": ws_id,
                            "workspace_name": workspace.name,
                            "missing": preflight.missing_dependencies,
                            "message": preflight.message,
                        })
                        .to_string(),
                    ));
                }
            }
        }
    }

    // Writer creation is checked once before actor creation and again while
    // tagging the returned mission. Never hold this mutex while waiting on the
    // control actor: actor commands also acquire it when resuming writers.
    let local_mission = !client_placement
        && req
            .remote_node_id
            .as_deref()
            .map(str::trim)
            .is_none_or(str::is_empty);
    let effective_estimated_disk_gib = req
        .estimated_disk_gib
        .or_else(|| local_mission.then(mission_disk_default_estimate_gib));
    if let Some(estimated_gib) = effective_estimated_disk_gib {
        if estimated_gib == 0 || estimated_gib > 512 {
            return Err((
                StatusCode::BAD_REQUEST,
                "estimated_disk_gib must be between 1 and 512".to_string(),
            ));
        }
        if local_mission {
            let workspace = state
                .workspaces
                .get(workspace_id.unwrap_or(workspace::DEFAULT_WORKSPACE_ID))
                .await
                .unwrap_or_else(|| {
                    workspace::Workspace::default_host(state.config.working_dir.clone())
                });
            let root = workspace::mission_workspace_root_for_workspace(&workspace, Uuid::nil());
            let usage = crate::api::monitoring::disk_usage_for_path(&root).map_err(|error| {
                (
                    StatusCode::INSUFFICIENT_STORAGE,
                    format!("mission creation refused: cannot measure workspace filesystem at {}: {error}", root.display()),
                )
            })?;
            if let Some(reason) =
                disk_estimate_refusal(&usage, estimated_gib, mission_disk_reserve_gib())
            {
                return Err((StatusCode::INSUFFICIENT_STORAGE, reason));
            }
        }
    }
    let mut normalized_request_tags = normalize_mission_tags(req.tags.as_deref());
    if let Some(tags) = normalized_request_tags.as_mut() {
        tags.retain(|tag| tag != worker_location::INITIALIZED_TAG);
    }
    if normalized_request_tags
        .as_deref()
        .is_some_and(contains_internal_disk_reservation_tag)
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "disk-reservation-v1 tags are reserved internal admission state".to_string(),
        ));
    }
    if client_placement {
        let tags = normalized_request_tags.get_or_insert_with(Vec::new);
        if !client_placement::is_tagged(tags) {
            tags.push(client_placement::TAG.to_string());
        }
    }
    if let Some(parent_id) = req.parent_mission_id {
        let mut cursor = Some(parent_id);
        let mut seen = std::collections::HashSet::new();
        let mut in_btw_subtree = false;
        while let Some(id) = cursor.filter(|id| seen.len() < 16 && seen.insert(*id)) {
            let Ok(Some(ancestor)) = parent_control.mission_store.get_mission(id).await else {
                break;
            };
            if crate::api::mission_horizon::is_btw_subtree_mission(&ancestor) {
                in_btw_subtree = true;
                break;
            }
            cursor = ancestor.parent_mission_id;
        }
        if in_btw_subtree {
            let tags = normalized_request_tags.get_or_insert_with(Vec::new);
            if !tags
                .iter()
                .any(|existing| existing == crate::api::mission_horizon::BTW_SUBAGENT_TAG)
            {
                tags.push(crate::api::mission_horizon::BTW_SUBAGENT_TAG.to_string());
            }
        }
    }
    if let Some(estimated_gib) = effective_estimated_disk_gib {
        let tag = format!("disk-estimate-gib:{estimated_gib}");
        let tags = normalized_request_tags.get_or_insert_with(Vec::new);
        if !tags.iter().any(|existing| existing == &tag) {
            tags.push(tag);
        }
    }
    let request_is_writer = requested_pr_writer(
        req.writer,
        normalized_request_tags.as_deref(),
        req.intent.as_deref(),
        req.prompt.as_deref(),
    );
    let request_needs_writer_lease = req
        .github_pr
        .as_deref()
        .is_some_and(|github_pr| !github_pr.trim().is_empty() && request_is_writer);

    // Validate the remote-node payload before persisting the mission so a
    // bad request cannot leave an orphaned pending mission behind.
    let mut remote_node_id = req
        .remote_node_id
        .as_deref()
        .map(str::trim)
        .filter(|id| !id.is_empty())
        // A managed machine may be named ("small-a"); persist its immutable
        // node id, never the reusable name.
        .map(crate::managed::resolve_node_alias);
    let remote_command = req
        .remote_command
        .as_deref()
        .map(str::trim)
        .filter(|command| !command.is_empty())
        .map(str::to_string);
    // Server-owned remote execution: the selected harness/model decide what
    // runs on the node (an explicit raw `remote_command` stays supported).
    // Planned before the mission exists so an unsupported selection is a
    // clean 400, never a failed mission.
    let mut remote_plan = match remote_node_id.as_deref() {
        Some(_) => Some(
            plan_remote_harness(
                remote_command.as_deref(),
                backend.as_deref().unwrap_or(""),
                model_override.as_deref(),
                req.prompt.as_deref(),
            )
            .map_err(|message| (StatusCode::BAD_REQUEST, message))?,
        ),
        None => None,
    };
    if let Some(plan) = remote_plan.as_ref() {
        validate_remote_vibe_auth(&state.config.working_dir, plan)
            .await
            .map_err(|message| (StatusCode::BAD_REQUEST, message))?;
    }
    if let Some(RemoteHarnessPlan::Codex {
        effort, fast_mode, ..
    }) = remote_plan.as_mut()
    {
        *effort = model_effort.clone();
        *fast_mode = req.fast_mode;
    }
    if let Some(RemoteHarnessPlan::Antigravity { effort, .. }) = remote_plan.as_mut() {
        *effort = model_effort.clone();
    }
    let mut auto_placement: Option<Vec<String>> = None;
    if let Some(node_id) = remote_node_id.as_deref() {
        if remote_dispatch_is_scheduled_for_future(
            Some(node_id),
            req.not_before,
            chrono::Utc::now(),
        ) {
            return Err((
                StatusCode::BAD_REQUEST,
                "remote-node MVP does not support future not_before scheduling yet; create the remote mission after the dispatch window opens".to_string(),
            ));
        }
        if is_auto_managed(node_id) {
            if req.validate_only != Some(true) {
                let Some(manager) = state.managed() else {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        "Managed machine provisioning is not configured for auto-managed placement"
                            .to_string(),
                    ));
                };
                let (provider, _) = parse_auto_managed_spec(node_id).unwrap_or((None, None));
                let target_provider = provider
                    .or_else(|| manager.default_provider().map(|p| p.name().to_string()))
                    .unwrap_or_else(|| manager.settings.provider.clone());
                if manager.settings.core_url.is_none()
                    || !manager.is_provider_enabled(&target_provider)
                    || manager.provider_for(&target_provider).is_none()
                {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        format!(
                            "Managed provider '{target_provider}' is disabled or unconfigured for auto-managed placement"
                        ),
                    ));
                }
            }
        } else if node_id.eq_ignore_ascii_case("auto") {
            // Capacity-aware auto placement, resolved BEFORE the mission is
            // persisted so placement failures surface as a clean API error
            // instead of an orphaned failed mission.
            if !state.config.remote_nodes.enabled {
                return Err((
                    StatusCode::BAD_REQUEST,
                    crate::remote_node::RemoteNodeError::Disabled.to_string(),
                ));
            }
            // Raw remote commands default to no label requirements; the
            // lean_build path (`POST /api/remote-build`) defaults to ["lean"].
            let requirements = req.remote_requirements.clone().unwrap_or_default();
            let resolved =
                match state
                    .fleet
                    .place_auto(&state.config.remote_nodes, &requirements)
                {
                    Ok(resolved) => resolved,
                    Err(initial_err) => {
                        // The periodic monitor may be disabled, or this request
                        // may race its first heartbeat. Match `/api/remote-build`:
                        // re-probe every configured node (including Online
                        // entries with potentially stale load), then retry
                        // placement once.
                        let retry_nodes: Vec<_> = state
                            .config
                            .remote_nodes
                            .nodes
                            .iter()
                            .filter(|node| {
                                let cached = state.fleet.get(&node.id);
                                remote_node_needs_on_demand_probe(
                                    cached.as_ref().map(|cached| &cached.status),
                                )
                            })
                            .collect();
                        if retry_nodes.is_empty() {
                            return Err((StatusCode::SERVICE_UNAVAILABLE, initial_err.to_string()));
                        }
                        let client = crate::remote_node::RemoteNodeClient::default();
                        futures::future::join_all(retry_nodes.into_iter().map(|node| {
                            crate::remote_node::probe_node(&state.fleet, &client, node)
                        }))
                        .await;
                        state
                            .fleet
                            .place_auto(&state.config.remote_nodes, &requirements)
                            .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, e.to_string()))?
                    }
                };
            tracing::info!(node_id = %resolved, "auto placement selected remote node");
            auto_placement = Some(requirements);
            remote_node_id = Some(resolved);
        } else {
            crate::remote_node::placement_for_selected_node(
                &state.config.remote_nodes,
                Some(node_id),
            )
            .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;
        }
    }

    if let (Some(node_id), Some(plan)) = (remote_node_id.as_deref(), remote_plan.as_ref()) {
        if is_auto_managed(node_id) {
            managed_auth_precheck(plan, state.managed().as_deref(), &user.id)
                .map_err(|message| (StatusCode::BAD_REQUEST, message))?;
        } else {
            remote_grok::require_node_managed_auth(&state, node_id, plan)
                .await
                .map_err(|message| (StatusCode::BAD_REQUEST, message))?;
        }
    }

    let control = control_for_user(&state, &user).await;
    // Helper: check whether an explicit `supersedes_mission_id` in the caller's
    // own store/project has no live execution (after settling any destroyed/gone
    // managed VM handles) so a replacement writer can cleanly inherit its PR lease.
    let supersedes_stopped_pr_holder = |target_project: Option<&str>| {
        let state = Arc::clone(&state);
        let control = control.clone();
        let prior_id = req.supersedes_mission_id;
        let target_project = target_project
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        async move {
            let Some(prior_id) = prior_id else {
                return Ok::<Option<Uuid>, String>(None);
            };
            let _ = super::remote_jobs::release_jobs_on_gone_nodes(
                &state.config.working_dir,
                control.mission_store.as_ref(),
                prior_id,
            )
            .await?;
            let Some(prior) = control.mission_store.get_mission(prior_id).await? else {
                return Ok(None);
            };
            let same_project = match (
                prior.project.project.as_deref().map(str::trim),
                target_project.as_deref(),
            ) {
                (Some(a), Some(b)) => a.eq_ignore_ascii_case(b),
                (None, _) => true,
                (Some(_), None) => false,
            };
            if !same_project
                || matches!(
                    prior.status,
                    MissionStatus::Pending
                        | MissionStatus::Active
                        | MissionStatus::WaitingBackground
                )
            {
                return Ok(None);
            }
            if control
                .mission_store
                .get_active_mission_run(prior_id)
                .await?
                .is_some()
            {
                return Ok(None);
            }
            let unresolved = execution_ownership::snapshot(&state.control)
                .await?
                .has_unresolved_execution(prior_id);
            Ok((!unresolved).then_some(prior_id))
        }
    };
    if request_needs_writer_lease {
        let _guard = acquire_durable_pr_writer_lock(&state.control)
            .await
            .map_err(internal_error)?;
        if let Some(github_pr) = req.github_pr.as_deref() {
            let superseded_holder = supersedes_stopped_pr_holder(req.project.as_deref())
                .await
                .map_err(internal_error)?;
            if let Some(existing) =
                find_existing_pr_writer_global(&state.control, github_pr, superseded_holder)
                    .await
                    .map_err(internal_error)?
            {
                return Err((
                    StatusCode::CONFLICT,
                    format!(
                        "PR writer lease is already held by mission {} (status={}); acknowledge, interrupt, or complete it before creating another writer for {}",
                        existing.id,
                        existing.status,
                        canonical_github_pr(github_pr)
                    ),
                ));
            }
        }
    }
    if req.cyber_access.is_none() && backend.as_deref() == Some("codex") {
        if let Some(source_id) = req.supersedes_mission_id {
            parent_control
                .mission_store
                .get_mission(source_id)
                .await
                .map_err(internal_error)?
                .ok_or((StatusCode::NOT_FOUND, "Source mission not found".into()))?;
            req.cyber_access = Some(
                cyber::read(&state.config.working_dir, source_id)
                    .map_err(internal_error)?
                    .mode,
            );
        }
    }
    if let Some(mode) = req.cyber_access {
        if backend.as_deref() != Some("codex") {
            return Err((
                StatusCode::BAD_REQUEST,
                "Cyber selection is available for Codex only.".into(),
            ));
        }
        cyber::program_for_model(mode, model_override.as_deref())
            .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
        if matches!(remote_plan, Some(RemoteHarnessPlan::Codex { .. })) {
            cyber::validate_remote(&state, mode, model_override.as_deref())
                .await
                .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
        }
    }
    // Budget: a sub-budget must fit the parent's pool (checked before the
    // mission exists; recorded once it does).
    if let Some(amount) = req.budget_usd {
        crate::managed::budget::validate_amount(amount)
            .map_err(|message| (StatusCode::BAD_REQUEST, message))?;
        if let (Some(parent), Some(manager)) = (req.parent_mission_id, state.managed()) {
            if let Some(pool) =
                crate::api::mission_budget::pool_for(&control.mission_store, parent, &user.id).await
            {
                if let Some(max) = manager.max_grant("", Some(&pool)).await {
                    if amount > max + 1e-9 {
                        return Err((
                            StatusCode::PAYMENT_REQUIRED,
                            serde_json::json!({
                                "error": "sub_budget_exceeds_pool",
                                "pool_id": pool,
                                "requested_usd": amount,
                                "remaining_usd": max,
                                "message": format!("budget_usd ${amount:.2} exceeds the parent pool's remaining ${max:.4}"),
                            })
                            .to_string(),
                        ));
                    }
                }
            }
        }
    }
    if req.validate_only == Some(true) {
        return Ok((
            axum::http::HeaderMap::new(),
            Json(serde_json::json!({ "valid": true })),
        ));
    }
    let mut rented_managed: Option<(crate::managed::ManagedMachine, bool)> = None;
    if let Some((provider, size)) = remote_node_id.as_deref().and_then(parse_auto_managed_spec) {
        let spawn_req = crate::managed::SpawnRequest {
            provider,
            provisioning_mode: Some(crate::managed::ProvisioningMode::Worker),
            size,
            cpu: None,
            ram_gb: None,
            gpu: None,
            arch: None,
            max_hourly_usd: None,
            allow_24h_commitment: req.managed_allow_24h_commitment,
            ttl_minutes: req.managed_ttl_minutes,
            image: None,
            reason: Some(format!(
                "start_mission: {}",
                title.as_deref().unwrap_or("subagent")
            )),
            from_snapshot: req.managed_from_snapshot.clone(),
            fork_of: None,
            snapshot_project: req.project.clone(),
            owner_mission_id: None,
            owner_user_id: Some(user.id.clone()),
            requested_by_mission_id: req.parent_mission_id.map(|id| id.to_string()),
            root_mission_id: None,
            budget_pool_id: None,
            cap_lineage: Vec::new(),
            sub_budget_usd: req.budget_usd,
            reuse_idle: Some(true),
            wait: Some(true),
        };
        let (machine, reused) = crate::api::managed_machines::spawn_for_inner(
            &state,
            &user,
            spawn_req,
            req.project.clone(),
            dispatch_tag.as_deref(),
        )
        .await
        .map_err(|e| {
            let status = StatusCode::from_u16(e.status).unwrap_or(StatusCode::BAD_GATEWAY);
            (status, format!("{}: {}", e.error, e.message))
        })?;
        remote_node_id = Some(machine.node_id.clone());
        req.remote_node_id = Some(machine.node_id.clone());
        req.claim_managed_machine_id = Some(machine.id.clone());
        rented_managed = Some((machine, reused));
    }

    let post_rent = async {
        if let Err(error) = control
            .cmd_tx
            .send(ControlCommand::CreateMission {
                title,
                workspace_id,
                agent,
                model_override,
                model_effort,
                fast_mode: req.fast_mode,
                service_tier: req.service_tier,
                backend,
                config_profile: effective_config_profile,
                parent_mission_id: req.parent_mission_id,
                working_directory: req.working_directory,
                scheduling: crate::api::mission_store::MissionScheduling {
                    priority: req.priority.unwrap_or(0),
                    not_before: req.not_before.map(|t| t.to_rfc3339()),
                    deadline: req.deadline.map(|t| t.to_rfc3339()),
                },
                requires_local_disk: local_mission,
                estimated_disk_gib: effective_estimated_disk_gib,
                admission_tags: normalized_request_tags.clone().unwrap_or_default(),
                respond: tx,
            })
            .await
        {
            return Err(session_unavailable(error));
        }

        let mut mission = match rx.await {
            Ok(Ok(mission)) => mission,
            Ok(Err(error)) => return Err(internal_error(error)),
            Err(error) => return Err(recv_failed(error)),
        };

        // The machine rented for this mission now serves it: its lifetime, not
        // the caller's, governs the VM (docs/specs/managed-vm-lifecycle.md).
        if let (Some(machine), Some(manager)) = (
            req.claim_managed_machine_id
                .as_deref()
                .map(str::trim)
                .filter(|m| !m.is_empty()),
            state.managed(),
        ) {
            // The requester is the server-resolved parent (gateway-attributed or
            // derived from the caller's `orb_<id>` session), and only when it
            // exists in this user's own store; claim_for_mission enforces that
            // the machine is this user's.
            let parent = match req.parent_mission_id {
                Some(p) if matches!(control.mission_store.get_mission(p).await, Ok(Some(_))) => {
                    Some(p.to_string())
                }
                _ => None,
            };
            if let Err(error) = manager
                .claim_for_mission(
                    machine,
                    &mission.id.to_string(),
                    parent.as_deref(),
                    Some(&user.id),
                )
                .await
            {
                tracing::warn!(mission_id = %mission.id, %machine, %error, "could not record the managed machine's owner");
            }
        }

        if let Some(amount) = req.budget_usd {
            if let Err(error) = crate::api::mission_budget::set_budget(
                &control.mission_store,
                &user,
                mission.id,
                Some(amount),
            )
            .await
            {
                tracing::warn!(mission_id = %mission.id, %error, "could not record the mission budget");
            }
        }
        // The claimed machine charges to the new mission's pool and concurrency cap pool.
        if let (Some(machine), Some(manager)) = (
            req.claim_managed_machine_id
                .as_deref()
                .map(str::trim)
                .filter(|m| !m.is_empty()),
            state.managed(),
        ) {
            let pool =
                crate::api::mission_budget::pool_for(&control.mission_store, mission.id, &user.id)
                    .await;
            if pool.is_some() {
                manager.set_machine_pool(machine, pool).await;
            }
            if let Some(m_row) = manager.get(machine).await {
                let cap_pool = crate::api::mission_budget::cap_pool_for(
                    &control.mission_store,
                    mission.id,
                    &user.id,
                    &m_row.provider,
                )
                .await;
                manager.set_machine_cap_pool(machine, cap_pool).await;
            }
            if let Some((ref mut rented, _)) = rented_managed {
                if let Some(updated_machine) = manager.get(machine).await {
                    *rented = updated_machine;
                }
            }
        }

        if let Some(requirements) = auto_placement.as_deref() {
            // Only auto-placed missions may later be moved off a full node.
            if let Err(error) =
                rebalance::record_auto(&state.config.working_dir, mission.id, requirements)
            {
                tracing::warn!(mission_id = %mission.id, %error, "could not record auto placement; the mission will not be rebalanced");
            }
        }
        if let Some(mode) = req.cyber_access {
            if let Err(error) = cyber::write(&state.config.working_dir, mission.id, mode) {
                interrupt_new_mission(&control, mission.id, "cyber_settings_unavailable").await;
                return Err(internal_error(error));
            }
        }

        if let Some(fingerprint) = side_launch_fingerprint {
            if let Err(error) = fork::record_side_launch(
                &state.config.working_dir,
                mission.id,
                req.idempotency_key.as_deref().unwrap_or_default(),
                fingerprint,
            ) {
                interrupt_new_mission(&control, mission.id, "side_launch_receipt_unavailable")
                    .await;
                return Err(internal_error(error));
            }
        } else if let Some(prior_id) = req.supersedes_mission_id {
            if let Some(prior_receipt) =
                fork::side_launch_receipt(&state.config.working_dir, prior_id)
                    .map_err(internal_error)?
            {
                if let Err(error) = fork::record_side_launch(
                    &state.config.working_dir,
                    mission.id,
                    req.idempotency_key.as_deref().unwrap_or(&prior_receipt.key),
                    &prior_receipt.fingerprint,
                )
                .and_then(|()| {
                    if prior_receipt.accepted {
                        fork::accept_side_launch(&state.config.working_dir, mission.id)
                    } else {
                        Ok(())
                    }
                }) {
                    interrupt_new_mission(&control, mission.id, "side_launch_receipt_unavailable")
                        .await;
                    return Err(internal_error(error));
                }
            }
        }

        // Match actor/sweep lock order before taking the PR-writer lock. The track
        // conflict path may reconcile a terminal predecessor, so admission must
        // remain serialized until the new lease and assignment are both persisted.
        let admission_guard = DISPATCH_ADMISSION.lock().await;
        let admission_file_guard = match dispatch_admission::durable_lock(&state.config).await {
            Ok(guard) => guard,
            Err(error) => {
                // The actor already persisted this candidate and its scratch
                // reservation. It has received no prompt or writer assignment.
                // Compensate directly: an actor roundtrip under admission can
                // deadlock, and the durable admission file itself is unavailable.
                let cleanup: Result<(), String> = async {
                    let reason = "dispatch_admission_unavailable";
                    control
                        .mission_store
                        .update_mission_status_with_reason(
                            mission.id,
                            MissionStatus::Interrupted,
                            Some(reason),
                        )
                        .await?;
                    let _ = control.events_tx.send(AgentEvent::MissionStatusChanged {
                        completion: None,
                        execution: None,
                        mission_id: mission.id,
                        status: MissionStatus::Interrupted,
                        summary: Some(reason.to_string()),
                    });
                    release_local_mission_disk(&state.config, mission.id).await
                }
                .await;
                return Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    serde_json::json!({
                        "error": "dispatch_admission_unavailable",
                        "mission_id": mission.id,
                        "detail": error,
                        "cleanup_error": cleanup.err(),
                    })
                    .to_string(),
                ));
            }
        };
        // Close the preflight-to-create race under the store-only mutex. Exactly
        // one concurrent creator wins; a loser is durably interrupted before it
        // can receive a goal or become a writer.
        let pr_writer_guard = if request_needs_writer_lease {
            Some(
                acquire_durable_pr_writer_lock(&state.control)
                    .await
                    .map_err(internal_error)?,
            )
        } else {
            None
        };
        if let (Some(github_pr), Some(_guard)) = (req.github_pr.as_deref(), pr_writer_guard.as_ref())
        {
            let superseded_holder = supersedes_stopped_pr_holder(req.project.as_deref())
                .await
                .map_err(internal_error)?;
            if let Some(existing) =
                find_existing_pr_writer_global(&state.control, github_pr, Some(mission.id))
                    .await
                    .map_err(internal_error)?
                    .filter(|existing| Some(existing.id) != superseded_holder)
            {
                let reason = "pr_writer_lease_conflict";
                control
                    .mission_store
                    .update_mission_status_with_reason(
                        mission.id,
                        MissionStatus::Interrupted,
                        Some(reason),
                    )
                    .await
                    .map_err(internal_error)?;
                let _ = control.events_tx.send(AgentEvent::MissionStatusChanged {
                    completion: None,
                    execution: None,
                    mission_id: mission.id,
                    status: MissionStatus::Interrupted,
                    summary: Some(reason.to_string()),
                });
                return Err((
                    StatusCode::CONFLICT,
                    format!(
                        "PR writer lease is already held by mission {} (status={}); interrupted duplicate mission {} for {}",
                        existing.id,
                        existing.status,
                        mission.id,
                        canonical_github_pr(github_pr)
                    ),
                ));
            }
        }

        // Apply project tagging metadata if provided at creation time. Empty/blank
        // strings are treated as unset; tags are trimmed and empties dropped.
        let nonblank = |s: &Option<String>| -> Option<String> {
            s.as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        };
        // A mission dispatched from a bound conversation inherits that project
        // when the caller did not name one. Agents omit it often — 11 of the 39
        // missions created in one 12h window on prod carried no project at all —
        // and an untagged mission is invisible to every project-scoped view:
        // the health rollup, the state timeline, the writer-slot counts, and the
        // inventory the controllers themselves query. Making the tag structural
        // beats asking every dispatcher to remember it.
        //
        // An explicit value always wins, including a deliberate blank, which is
        // how a caller says "this belongs to no project".
        let project = match nonblank(&req.project) {
            Some(explicit) => Some(
                super::super::projects_overview::resolve_roster_slug(&state.projects, &explicit)
                    .ok()
                    .flatten()
                    .unwrap_or(explicit),
            ),
            None if req.project.is_some() => None,
            None => req
                .origin_session_id
                .as_deref()
                .map(str::trim)
                .filter(|session| !session.is_empty())
                .and_then(|session| {
                    // A conversation rolls over into a continuation, and the
                    // binding names whichever id the operator declared — often
                    // several rollovers above this one. Walk up the ancestry,
                    // nearest first, so the closest binding wins.
                    let chain = match super::super::projects_overview::hermes_state_db_path() {
                        Some(path) => super::super::session_chain::ancestry(&path, session),
                        None => vec![session.to_string()],
                    };
                    chain.iter().find_map(|candidate| {
                        match state.projects.project_for_session(candidate) {
                            Ok(slug) => slug,
                            Err(error) => {
                                tracing::warn!(
                                    session_id = candidate,
                                    error = %error,
                                    "could not resolve a project for the origin session"
                                );
                                None
                            }
                        }
                    })
                }),
        };
        let mut track = nonblank(&req.track);
        let intent = nonblank(&req.intent);
        let github_pr = nonblank(&req.github_pr);
        let desired_state = nonblank(&req.desired_state);
        let next_check_at = nonblank(&req.next_check_at);
        let mut tags = normalized_request_tags;
        // Absorb at write time: a project mission always lands on a plan row
        // (existing key / alias / single PR ref, else a new `absorbed` track) and
        // takes a lease on it. A held writer lease interrupts this duplicate
        // instead of letting two writers race on one track.
        if let Some(project_slug) = project.as_deref() {
            match bind_mission_to_track(
                &state,
                &control,
                &mission,
                project_slug,
                track.as_deref(),
                req.title.as_deref(),
                github_pr.as_deref(),
                intent.as_deref(),
                req.writer,
                tags.as_deref().unwrap_or(&[]),
                request_is_writer,
                req.idempotency_key.as_deref(),
                &req.acceptance_criteria,
            )
            .await
            {
                Ok(canonical) => track = Some(canonical),
                Err(response) => {
                    drop(pr_writer_guard);
                    return Err(response);
                }
            }
        }
        // Explicit capability governs track admission and harness permissions even
        // without PR metadata. Persist it before deferred dispatch can re-infer
        // authority from an initial prompt such as "verity-integration-b".
        if req.writer.is_some()
            || req
                .github_pr
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
        {
            let capability = if request_is_writer {
                Some("pr-writer")
            } else if req.writer == Some(false) {
                Some("pr-readonly")
            } else {
                None
            };
            if let Some(capability) = capability {
                let tags = tags.get_or_insert_with(Vec::new);
                tags.retain(|tag| tag != "pr-writer" && tag != "pr-readonly");
                if !tags.iter().any(|tag| tag == capability) {
                    tags.push(capability.to_string());
                }
            }
        }
        // Creation persisted the admission lease before replying. This later
        // metadata patch must retain it, otherwise user tags could release it.
        let durable_reservation_tags: Vec<String> = mission
            .project
            .tags
            .iter()
            .filter(|tag| {
                tag.starts_with(DISK_RESERVATION_TAG_PREFIX)
                    || crate::api::mission_horizon::is_reserved_lineage_tag(tag)
            })
            .cloned()
            .collect();
        if !durable_reservation_tags.is_empty() {
            let requested = tags.get_or_insert_with(Vec::new);
            for reservation in durable_reservation_tags {
                if !requested.iter().any(|tag| tag == &reservation) {
                    requested.push(reservation);
                }
            }
        }
        let mut superseded_ids: Vec<Uuid> = Vec::new();
        if project.is_some()
            || track.is_some()
            || intent.is_some()
            || github_pr.is_some()
            || tags.is_some()
            || desired_state.is_some()
            || next_check_at.is_some()
        {
            control
                .mission_store
                .update_mission_project(
                    mission.id,
                    crate::api::mission_store::MissionProjectPatch {
                        title: None,
                        project: project.clone().map(Some),
                        track: track.clone().map(Some),
                        intent: intent.clone().map(Some),
                        github_pr: github_pr.clone().map(Some),
                        tags: tags.clone(),
                        preserve_updated_at: false,
                        tag_patch: None,
                        desired_state: desired_state.clone().map(Some),
                        next_check_at: next_check_at.clone().map(Some),
                    },
                )
                .await
                .map_err(internal_error)?;
            // Reflect the applied values in the returned mission without a re-fetch.
            mission.project.project = project.or(mission.project.project);
            mission.project.track = track.or(mission.project.track);
            mission.project.intent = intent.or(mission.project.intent);
            mission.project.github_pr = github_pr.or(mission.project.github_pr);
            mission.project.desired_state = desired_state.or(mission.project.desired_state);
            mission.project.next_check_at = next_check_at.or(mission.project.next_check_at);
            if let Some(v) = tags {
                mission.project.tags = v;
            }
            match super::super::mission_horizon::supersede_prior_attempts(
                control.mission_store.as_ref(),
                &mission,
            )
            .await
            {
                Ok(absorbed) => superseded_ids.extend(absorbed),
                Err(error) => {
                    tracing::warn!(
                        mission_id = %mission.id,
                        %error,
                        "could not absorb prior attempts on the same item"
                    );
                }
            }
        }
        if let Some(prior_id) = req.supersedes_mission_id {
            match super::super::mission_horizon::supersede_explicit(
                control.mission_store.as_ref(),
                &mission,
                prior_id,
            )
            .await
            {
                Ok(()) => {
                    if !superseded_ids.contains(&prior_id) {
                        superseded_ids.push(prior_id);
                    }
                }
                Err(error) => {
                    tracing::warn!(
                        mission_id = %mission.id,
                        %prior_id,
                        %error,
                        "supersedes_mission_id was not applied"
                    );
                }
            }
        }
        drop(pr_writer_guard);
        drop(admission_file_guard);
        drop(admission_guard);

        // Cancel superseded remote jobs ONLY after releasing `DISPATCH_ADMISSION`
        // and durable admission locks so a slow/unresponsive remote node never
        // blocks unrelated mission admission or terminal reconciliation.
        if !superseded_ids.is_empty() {
            let remote_supersede = super::super::mission_horizon::RemoteSupersedeContext {
                working_dir: &state.config.working_dir,
                remote_nodes: &state.config.remote_nodes,
                fleet: &state.fleet,
            };
            for prior_id in superseded_ids {
                super::super::mission_horizon::cancel_superseded_remote_jobs_by_id(
                    control.mission_store.as_ref(),
                    prior_id,
                    &remote_supersede,
                )
                .await;
            }
        }

        // Creation origin ("hermes" + owning session id). Written once here so
        // clients can group foreign-origin missions under their conversation.
        if let Some(origin) = req
            .origin
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let mut origin_session_id = req
                .origin_session_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty());
            // A fabricated session id is worse than none: it is BELIEVED. Measured
            // 2026-08-06, a controller hand-passed "20260805_night_supervision" —
            // valid in shape, existing nowhere — so the mission was invisible to
            // ?origin_session_id=, its completion callback could pin nowhere, and
            // the interruption that followed had no conversation to report into.
            // When the Hermes state database is available, verify the session
            // exists; an id that provably does not gets dropped with a warning,
            // leaving the mission honestly unattributed and adoptable later.
            // "Could not check" keeps the stamp — stripping attribution on every
            // deployment without HERMES_STATE_DB would be the larger harm.
            if let Some(session) = origin_session_id {
                if hermes_session_exists(session) == Some(false) {
                    tracing::warn!(
                        mission_id = %mission.id,
                        origin_session_id = %session,
                        "origin_session_id names no existing Hermes session; \
                         leaving the mission unattributed instead of stamping a \
                         fabricated id"
                    );
                    if let Ok(value) = axum::http::HeaderValue::from_str(session) {
                        headers.insert("x-dropped-origin-session", value);
                    }
                    origin_session_id = None;
                }
            }
            control
                .mission_store
                .set_mission_origin(mission.id, origin, origin_session_id)
                .await
                .map_err(internal_error)?;
            mission.origin = Some(origin.to_string());
            mission.origin_session_id = origin_session_id.map(str::to_string);
        }

        // Persist attachments before publishing the deferred-goal dispatch ticket.
        // The scheduler can run at every await after set_deferred_goal.
        if let Some(attachments) = req.attachments.as_ref().filter(|rows| !rows.is_empty()) {
            let mut payload = crate::api::mission_payload::MissionPayload {
                attachments: attachments.clone(),
                project: mission.project.project.clone(),
                controller_md: None,
            };
            if attachments
                .iter()
                .any(|row| row.kind == crate::api::mission_payload::AttachmentKind::Controller)
            {
                if let Some(project) = mission.project.project.as_deref() {
                    payload.controller_md = Some(
                        super::super::projects_overview::controller_snapshot_markdown(
                            &state, project,
                        )
                        .await,
                    );
                }
            }
            if let Err(error) = crate::api::mission_payload::write_sidecar(
                &state.config.working_dir,
                mission.id,
                &payload,
            ) {
                // A retry must not coalesce onto a half-created mission and report
                // success while discarding both its prompt and attachments.
                control
                    .mission_store
                    .update_mission_status_with_reason(
                        mission.id,
                        MissionStatus::Failed,
                        Some("attachment_persistence_failed"),
                    )
                    .await
                    .map_err(internal_error)?;
                state
                    .projects
                    .release_leases_for_attempt(&mission.id.to_string())
                    .map_err(internal_error)?;
                release_local_mission_disk(&state.config, mission.id)
                    .await
                    .map_err(internal_error)?;
                let _ = control.events_tx.send(AgentEvent::MissionStatusChanged {
                    completion: None,
                    execution: None,
                    mission_id: mission.id,
                    status: MissionStatus::Failed,
                    summary: Some("attachment_persistence_failed".into()),
                });
                return Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("persist attachments: {error}"),
                ));
            }
        }

        // Atomic create+start: stash the initial prompt as the deferred goal. The
        // FLEET-001 scheduler pass (every ~5s) dispatches pending missions with a
        // deferred goal as soon as parallel capacity allows, honoring `not_before`
        // when set. Unlike the old create-then-message pattern, this cannot be
        // dropped at capacity.
        // The initial prompt, keyed by the id of its queued broadcast so a later
        // non-queued event for the same message replaces it in live clients.
        let mut initial_prompt: Option<(Uuid, String)> = None;
        // A remote launch is owned by the node job from the moment it exists. A
        // deferred goal is the FLEET-001 scheduler's dispatch ticket: for a
        // remote mission it would make the mission eligible for a LOCAL harness
        // during every await below (node placement, proxy-key mint, the node
        // submit round-trip). Incident 620cdb74 (2026-09-20): the scheduler
        // started a local runner for a typed dgx-spark launch while the submit
        // was in flight, persisted the prompt a second time (source=scheduler),
        // and left the remote job without its run lease. Remote prompts are
        // persisted exactly once by `persist_remote_mission_prompt` instead.
        let remote_launch = remote_node_id.is_some() && remote_plan.is_some();
        if let Some(prompt) = nonblank(&req.prompt) {
            // Canonicalise `/goal\n…` to the space form before storing: the
            // deferred goal is later re-injected verbatim, and the backend goal
            // drivers only recognise `/goal <objective>` with a space.
            let prompt = canonical_goal_message(&prompt).unwrap_or(prompt);
            let prompt_event_id = if worker_location::client_owner(&mission).is_some() {
                worker_location::initial_delivery_id(mission.id)
            } else {
                Uuid::new_v4()
            };
            // Client placements keep the prompt out of the scheduler ticket.
            // `get_scheduled_pending_missions` only returns rows that still have
            // a deferred goal, and the stores also exclude `placement:client`.
            if !remote_launch && !client_placement {
                control
                    .mission_store
                    .set_deferred_goal(
                        mission.id,
                        Some(deferred_messages::encode(prompt_event_id, &prompt)),
                    )
                    .await
                    .map_err(internal_error)?;
            }
            // A `/goal …` prompt is a goal-mode mandate from the very first turn.
            // Persist it here, synchronously on the same store that created the
            // mission — the event-loop hook that also does this only sees events
            // while a control session is pumping, so MCP/API creations could
            // otherwise stay goal_mode=false forever.
            if let Some(objective) = parse_goal_objective(&prompt) {
                control
                    .mission_store
                    .update_mission_goal(mission.id, true, Some(&objective))
                    .await
                    .map_err(internal_error)?;
                mission.goal_mode = true;
                mission.goal_objective = Some(objective);
            }
            // Surface the queued goal so UIs show it as pending until dispatch.
            let _ = control.events_tx.send(AgentEvent::UserMessage {
                id: prompt_event_id,
                content: prompt.clone(),
                queued: true,
                mission_id: Some(mission.id),
                source: Some(format!("api:{}", user.id)),
            });
            initial_prompt = Some((prompt_event_id, prompt));
        }

        if let (Some(remote_node_id), Some(remote_plan)) =
            (remote_node_id.as_deref(), remote_plan.as_ref())
        {
            // All remote commands use the durable node job API. The legacy
            // synchronous `/execute` path has no cancellation handle if its HTTP
            // wait expires, so routing `remote_async=false` through it could orphan
            // a process on the node. The response contract here is unchanged: the
            // mission is returned Active while its durable poller owns completion.
            //
            // A raw remote mission never starts a local harness, so nothing else
            // would ever persist its prompt: the queued broadcast above is
            // deliberately dropped by the store until a runner starts the turn.
            // Persist it here, before dispatch and before the response, so the
            // mission's history and event replay carry the user's mandate even
            // when dispatch fails.
            let dispatch = match persist_remote_mission_prompt(
                &control,
                mission.id,
                &user.id,
                initial_prompt.take(),
            )
            .await
            {
                Ok(()) => {
                    dispatch_remote_job(
                        &state,
                        &control,
                        &mission,
                        remote_node_id,
                        remote_plan,
                        None,
                        None,
                    )
                    .await
                }
                Err(message) => Err(message),
            };
            match dispatch {
                Ok(mut updated) => {
                    worker_location::mark_initialized(&control.mission_store, &mut updated)
                        .await
                        .map_err(internal_error)?;
                    let mut value = mission_create_response(&state, &control, updated).await?;
                    if let Some((ref machine, reused)) = rented_managed {
                        if let Some(obj) = value.as_object_mut() {
                            obj.insert(
                                "managed_machine".to_string(),
                                serde_json::to_value(machine).unwrap_or(serde_json::Value::Null),
                            );
                            obj.insert(
                                "reused_idle_machine".to_string(),
                                serde_json::Value::Bool(reused),
                            );
                        }
                    }
                    return Ok((headers, Json(value)));
                }
                Err(message) => {
                    let _ = control
                        .mission_store
                        .update_mission_status_with_reason(
                            mission.id,
                            MissionStatus::Failed,
                            Some(REMOTE_DISPATCH_FAILED),
                        )
                        .await;
                    let _ = control.events_tx.send(AgentEvent::MissionStatusChanged {
                        completion: None,
                        execution: None,
                        mission_id: mission.id,
                        status: MissionStatus::Failed,
                        summary: Some(message.clone()),
                    });
                    return Err((StatusCode::BAD_GATEWAY, message));
                }
            }
        }

        if client_placement {
            // Persist history and the completion receipt before exposing a delivery.
            // A retry may replay delivery only after all initialization is durable.
            persist_remote_mission_prompt(&control, mission.id, &user.id, initial_prompt.clone())
                .await
                .map_err(internal_error)?;
            worker_location::mark_initialized(&control.mission_store, &mut mission)
                .await
                .map_err(internal_error)?;
            if worker_location::client_owner(&mission).is_some() {
                if let Some((id, prompt)) = &initial_prompt {
                    worker_location::enqueue(
                        &control.mission_store,
                        mission.id,
                        *id,
                        prompt.clone(),
                    )
                    .await
                    .map_err(internal_error)?;
                }
            }
            let value = mission_create_response(&state, &control, mission).await?;
            return Ok((headers, Json(value)));
        }

        worker_location::mark_initialized(&control.mission_store, &mut mission)
            .await
            .map_err(internal_error)?;
        let value = mission_create_response(&state, &control, mission).await?;
        Ok((headers, Json(value)))
    }
    .await;

    if post_rent.is_err() {
        // Never leave a freshly rented VM running when any post-rental admission,
        // track lease, attachment persistence, or dispatch step fails (reused
        // sibling VMs remain governed by their idle grace window).
        if let (Some((machine, false)), Some(manager)) = (&rented_managed, state.managed()) {
            let _ = manager.destroy(&machine.id, "launch_failed").await;
        }
    }
    post_rent
}

/// Create/coalesce responses carry the same execution and remote placement
/// projection as mission reads, so a client can render an honest state from
/// the response alone (the Orb treats `remote_job.node_id`/`phase` as the
/// authoritative placement of a typed remote launch).
pub(super) async fn mission_create_response(
    state: &Arc<AppState>,
    control: &ControlState,
    mission: Mission,
) -> Result<serde_json::Value, (StatusCode, String)> {
    let active_run = control
        .mission_store
        .get_active_mission_run(mission.id)
        .await
        .map_err(internal_error)?;
    let placement_run = match active_run.clone() {
        Some(run) => Some(run),
        None => control
            .mission_store
            .get_latest_mission_run(mission.id)
            .await
            .map_err(internal_error)?,
    };
    let value = attach_execution_to_mission_value(
        serde_json::to_value(&mission).map_err(internal_error)?,
        &mission,
        active_run.as_ref(),
        None,
    );
    let (handles, outcomes) = remote_job_projection_inputs(state).await;
    Ok(attach_remote_job_to_mission_value(
        value,
        remote_job_projection(
            &handles,
            &outcomes,
            placement_run.as_ref(),
            mission.id,
            chrono::Utc::now(),
        ),
    ))
}

pub(super) fn remote_dispatch_is_scheduled_for_future(
    remote_node_id: Option<&str>,
    not_before: Option<chrono::DateTime<chrono::Utc>>,
    now: chrono::DateTime<chrono::Utc>,
) -> bool {
    remote_node_id
        .map(str::trim)
        .is_some_and(|id| !id.is_empty())
        && not_before.is_some_and(|t| t > now)
}

/// `auto-managed` / `auto-managed:<size>`: a VM start_mission rents.
pub(crate) fn is_auto_managed(node_id: &str) -> bool {
    node_id
        .trim()
        .to_ascii_lowercase()
        .starts_with("auto-managed")
}

/// Parse `auto-managed`, `auto-managed:<size>`, `auto-managed:<provider>`, or
/// `auto-managed:<provider>:<size>` into `(provider, size)`.
pub(crate) fn parse_auto_managed_spec(raw: &str) -> Option<(Option<String>, Option<String>)> {
    let trimmed = raw.trim();
    if !trimmed.to_ascii_lowercase().starts_with("auto-managed") {
        return None;
    }
    let Some((_, rest)) = trimmed.split_once(':') else {
        return Some((None, None));
    };
    let rest = rest.trim();
    if rest.is_empty() {
        return Some((None, None));
    }
    if let Some((provider, size)) = rest.split_once(':') {
        let p = provider.trim().to_ascii_lowercase();
        let s = size.trim();
        return Some((
            (!p.is_empty()).then_some(p),
            (!s.is_empty()).then(|| s.to_string()),
        ));
    }
    let lower = rest.to_ascii_lowercase();
    if matches!(lower.as_str(), "boat" | "hetzner" | "vastai" | "scaleway") {
        Some((Some(lower), None))
    } else {
        Some((None, Some(rest.to_string())))
    }
}

/// Backend-level managed VM prerequisite check used both by pre-rent validation
/// and by child default placement (`auto-managed:boat` vs `auto` fallback).
pub(crate) fn managed_backend_auth_precheck(
    backend_id: &str,
    manager: Option<&crate::managed::ManagedManager>,
    user_id: &str,
) -> Result<(), String> {
    match backend_id.trim().to_ascii_lowercase().as_str() {
        "grok" => Err(format!(
            "{}: managed VMs (orb-node-base) have no grok login; pick claudecode, codex or opencode (with model_override) for auto-managed",
            remote_grok::REMOTE_AUTH_REQUIRED
        )),
        "vibe" => Err(
            "REMOTE_HARNESS_UNAVAILABLE: managed VMs (orb-node-base) do not install vibe-acp; pick claudecode, codex or opencode (with model_override) for auto-managed".to_string()
        ),
        "antigravity" => {
            let allowed = manager.is_some_and(|m| m.runtime_settings().antigravity_on_managed)
                && crate::managed::antigravity_owner_allowed(
                    Some(user_id),
                    std::env::var("SANDBOXED_MANAGED_ANTIGRAVITY_USERS")
                        .ok()
                        .as_deref(),
                );
            if allowed {
                Ok(())
            } else {
                Err(format!(
                    "{}: Antigravity sign-in projection onto managed VMs is disabled for this owner",
                    remote_grok::REMOTE_AUTH_REQUIRED
                ))
            }
        }
        _ => Ok(()),
    }
}

/// Harness prerequisites a fresh `orb-node-base` VM can satisfy, decided before
/// the VM is rented: the image has no grok login or `vibe-acp` installation,
/// and the owner's Antigravity sign-in is projected only when the operator
/// allows it.
pub(crate) fn managed_auth_precheck(
    plan: &RemoteHarnessPlan,
    manager: Option<&crate::managed::ManagedManager>,
    user_id: &str,
) -> Result<(), String> {
    match plan {
        RemoteHarnessPlan::Grok { .. } => managed_backend_auth_precheck("grok", manager, user_id),
        RemoteHarnessPlan::Vibe { .. } => managed_backend_auth_precheck("vibe", manager, user_id),
        RemoteHarnessPlan::Antigravity { .. } => {
            managed_backend_auth_precheck("antigravity", manager, user_id)
        }
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_normalization_and_fast_mode_cover_gpt_6_1_family() {
        assert_eq!(
            normalize_model_override_for_backend(Some("codex"), "gpt-6.1"),
            Some("gpt-6.1-sol".to_string())
        );
        assert_eq!(
            normalize_model_override_for_backend(Some("codex"), "openai/gpt-6.1"),
            Some("gpt-6.1-sol".to_string())
        );
        assert_eq!(
            normalize_model_override_for_backend(Some("codex"), "codex/gpt-6.1-terra"),
            Some("gpt-6.1-terra".to_string())
        );
        assert!(validate_fast_mode("codex", Some("gpt-6.1-terra"), true).is_ok());
        assert!(validate_fast_mode("codex", Some("gpt-6.1-sol"), true).is_ok());
        assert_eq!(
            supported_model_efforts_for_backend(Some("codex")),
            "low, medium, high, xhigh, max"
        );
    }
}
