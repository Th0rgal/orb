//! Core-side mission, cloud, project and workspace tool handlers.
//! Authentication and authorization are supplied by the unified gateway.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::de::IntoDeserializer;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

use super::ToolDefinition;

#[derive(Debug, Deserialize)]
struct MissionIdParams {
    mission_id: String,
}

#[derive(Debug, Deserialize)]
struct ProjectSlugParams {
    slug: String,
}

#[derive(Debug, Deserialize)]
struct UpdateProjectStatusParams {
    #[serde(default)]
    consumed_steer_ids: Vec<String>,
    slug: String,
    mode: String,
    #[serde(default)]
    next_action: Option<String>,
    #[serde(default)]
    blocker: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AcceptProjectTrackParams {
    slug: String,
    track: String,
    idempotency_key: String,
    #[serde(default)]
    expected_revision: Option<u64>,
    evidence: Vec<Value>,
}

#[derive(Debug, Deserialize)]
struct InvalidateProjectTrackEvidenceParams {
    slug: String,
    track: String,
    receipt_id: String,
    reason: String,
}

#[derive(Debug, Deserialize)]
struct SetProjectTrackParams {
    slug: String,
    track: String,
    #[serde(default)]
    desired_state: Option<String>,
    #[serde(default)]
    status: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AcceptProjectTrackEvidenceParams {
    slug: String,
    track: String,
    #[serde(default)]
    criterion: Option<String>,
    verifier_class: String,
    evidence_ref: String,
    artifact_version: String,
    #[serde(default)]
    observed_at: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ReopenProjectTrackParams {
    slug: String,
    track: String,
    reason: String,
    #[serde(default)]
    governed_artifact_version: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SetProjectGrantParams {
    slug: String,
    #[serde(default)]
    merge_authority: Option<String>,
    #[serde(default)]
    budget_per_tick: Option<String>,
    #[serde(default)]
    parallel_missions: Option<i64>,
    #[serde(default)]
    pause_reason: Option<String>,
    #[serde(default)]
    resume_condition: Option<String>,
    #[serde(default)]
    material_bar: Option<String>,
    #[serde(default)]
    autonomy_level: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AddProjectSteerParams {
    slug: String,
    body: String,
}

#[derive(Debug, Deserialize)]
struct ProposalTaskInput {
    task_key: String,
    title: String,
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default)]
    acceptance_criteria: Vec<String>,
    #[serde(default)]
    depends_on: Vec<String>,
    #[serde(default)]
    position: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct PlanProjectTasksParams {
    slug: String,
    tasks: Vec<ProposalTaskInput>,
}

#[derive(Debug, Deserialize)]
struct UpdateProjectTaskParams {
    slug: String,
    task_key: String,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default)]
    acceptance_criteria: Option<Vec<String>>,
    #[serde(default)]
    depends_on: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
struct CancelProjectTaskParams {
    slug: String,
    task_key: String,
}

#[derive(Debug, Deserialize)]
struct RecordProjectDecisionParams {
    slug: String,
    question: String,
    #[serde(default)]
    rationale: Option<String>,
    /// merge | dispatch | abandon | pause | resume | scope | budget | retry | …
    #[serde(default)]
    kind: Option<String>,
    /// granted (autonomous act) | escalation (question for the owner, default).
    #[serde(default)]
    authority: Option<String>,
    /// decided | pending_user; defaults follow the authority.
    #[serde(default)]
    status: Option<String>,
    /// {"pr_url": …, "mission_id": …}
    #[serde(default)]
    evidence: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct AnswerProjectDecisionParams {
    slug: String,
    /// The decision's `at` key, as returned by record/get_project.
    at: String,
    answer: String,
}

#[derive(Debug, Deserialize)]
struct LinkMissionToProjectParams {
    mission_id: String,
    slug: String,
    #[serde(default)]
    track: Option<String>,
    #[serde(default)]
    writer: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct AdoptMissionParams {
    mission_id: String,
    /// The Hermes session that should own this mission's callbacks from now
    /// on. The sandboxed-origin-session plugin stamps it exactly as it does
    /// for start_mission; the model itself should not pass it.
    #[serde(default)]
    origin_session_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ListMissionsParams {
    #[serde(default)]
    offset: usize,
    #[serde(default)]
    status: Option<String>,
    #[serde(default = "default_limit")]
    limit: usize,
    #[serde(default)]
    project: Option<String>,
    /// Project family: matches `X` and `X-*`.
    #[serde(default)]
    project_prefix: Option<String>,
    #[serde(default)]
    track: Option<String>,
    #[serde(default)]
    tag: Option<String>,
    /// The Hermes conversation a mission was launched from.
    #[serde(default)]
    origin_session_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct MissionEventsParams {
    mission_id: String,
    #[serde(default = "default_event_limit")]
    limit: usize,
    #[serde(default)]
    view: Option<String>,
    #[serde(default)]
    since_seq: Option<i64>,
    /// Page backwards: return the newest `limit` events with sequence below
    /// this value (ascending order). Takes precedence over `since_seq`.
    /// When neither cursor is provided, the MCP defaults to the newest page.
    #[serde(default)]
    before_seq: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct MissionSharedFilesParams {
    mission_id: String,
    #[serde(default = "default_event_limit")]
    limit: usize,
}

#[derive(Debug, Deserialize)]
struct DownloadSharedFileParams {
    mission_id: String,
    url: String,
    #[serde(default)]
    filename: Option<String>,
    #[serde(default)]
    output_dir: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SpawnManagedParams {
    #[serde(default)]
    provider: Option<String>,
    #[serde(default)]
    provisioning_mode: Option<crate::managed::ProvisioningMode>,
    #[serde(default)]
    size: Option<String>,
    #[serde(default)]
    cpu: Option<u32>,
    #[serde(default)]
    ram_gb: Option<u32>,
    #[serde(default)]
    gpu: Option<String>,
    #[serde(default)]
    arch: Option<String>,
    #[serde(default)]
    max_hourly_usd: Option<f64>,
    #[serde(default)]
    allow_24h_commitment: Option<bool>,
    #[serde(default)]
    ttl_minutes: Option<u64>,
    #[serde(default)]
    image: Option<String>,
    #[serde(default)]
    reason: Option<String>,
    /// Registry name of a project snapshot to start from.
    #[serde(default)]
    from_snapshot: Option<String>,
    /// Set by the gateway to the calling mission; never trusted from agents.
    #[serde(default)]
    owner_mission_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawManagedOperationParams {
    machine_id: String,
    operation: String,
    #[serde(default)]
    command: Option<String>,
    #[serde(default)]
    timeout_secs: Option<u64>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    idempotency_key: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ManagedActionParams {
    machine_id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    size: Option<String>,
    #[serde(default)]
    ttl_minutes: Option<u64>,
    #[serde(default)]
    reason: Option<String>,
    /// Set by the gateway to the calling mission.
    #[serde(default)]
    owner_mission_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SnapshotScopeParams {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    project: Option<String>,
    /// Set by the gateway to the calling mission.
    #[serde(default)]
    owner_mission_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ListManagedParams {
    /// Full rows (every field, last 24 h history) instead of the summary.
    #[serde(default)]
    verbose: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct GetBudgetParams {
    /// Set by the gateway to the calling mission (executors); Hermes may name one.
    #[serde(default)]
    mission_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ManagedIdParams {
    machine_id: String,
    #[serde(default)]
    ttl_minutes: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct StartMissionParams {
    #[serde(default)]
    parent_mission_id: Option<Uuid>,
    /// Set only by the mission gateway (`"mission"`) when a mission's agent
    /// starts a child through MCP; never part of the public tool schema.
    #[serde(default)]
    caller: Option<String>,
    #[serde(default)]
    cloud: Option<serde_json::Value>,
    title: String,
    prompt: String,
    #[serde(default)]
    workspace_id: Option<String>,
    #[serde(default)]
    remote_node_id: Option<String>,
    #[serde(default)]
    managed_ttl_minutes: Option<u64>,
    #[serde(default)]
    managed_from_snapshot: Option<String>,
    #[serde(default)]
    managed_allow_24h_commitment: Option<bool>,
    /// Optional managed-machine budget (USD) for the new mission's subtree;
    /// under a parent budget it is a sub-budget carved from the parent pool.
    #[serde(default)]
    budget_usd: Option<f64>,
    #[serde(default)]
    backend: Option<String>,
    #[serde(default)]
    model_override: Option<String>,
    #[serde(default)]
    model_effort: Option<String>,
    #[serde(default)]
    fast_mode: Option<bool>,
    #[serde(default)]
    config_profile: Option<String>,
    #[serde(default)]
    agent: Option<String>,
    // Project tagging — forwarded so missions are created WITH structured
    // metadata instead of null (watchdogs then don't have to parse titles).
    #[serde(default)]
    project: Option<String>,
    #[serde(default)]
    track: Option<String>,
    #[serde(default)]
    idempotency_key: Option<String>,
    #[serde(default)]
    supersedes_mission_id: Option<String>,
    #[serde(default)]
    intent: Option<String>,
    #[serde(default)]
    github_pr: Option<String>,
    #[serde(default)]
    writer: Option<bool>,
    /// Model-visible request for merge capability. It is not authority: this
    /// server derives grants only from its operator-owned environment.
    #[serde(default)]
    request_merge_authority: Option<bool>,
    #[serde(default)]
    tags: Option<Vec<String>>,
    #[serde(default)]
    desired_state: Option<String>,
    #[serde(default)]
    acceptance_criteria: Vec<String>,
    #[serde(default)]
    next_check_at: Option<String>,
    #[serde(default)]
    estimated_disk_gib: Option<u64>,
    /// Hermes session that spawned this mission. Forwarded as the mission's
    /// `origin_session_id` so clients group it as a worker of that session.
    #[serde(default)]
    origin_session_id: Option<String>,
    #[serde(default)]
    attachments: Option<Vec<Value>>,
}

#[derive(Debug, Deserialize)]
struct ConsultModelParams {
    /// Full `<provider>/<model>` or a short alias (`gpt-6-astra`, `fable-5.1`).
    model: String,
    question: String,
    #[serde(default)]
    files: Vec<String>,
    /// Default true: the consultant is a pr-readonly reviewer.
    #[serde(default)]
    read_only: Option<bool>,
    /// Retired: waiting would hold a shared dispatcher permit. Rejected
    /// with a pointer to get_consult_result.
    #[serde(default)]
    wait_secs: Option<u64>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    project: Option<String>,
    #[serde(default)]
    github_pr: Option<String>,
    #[serde(default)]
    idempotency_key: Option<String>,
    #[serde(default)]
    origin_session_id: Option<String>,
    // Placement and lineage: filled by the mission gateway from the caller.
    #[serde(default)]
    parent_mission_id: Option<Uuid>,
    #[serde(default)]
    caller: Option<String>,
    #[serde(default)]
    workspace_id: Option<String>,
    #[serde(default)]
    remote_node_id: Option<String>,
}

fn normalize_model_token(raw: &str) -> String {
    raw.trim().to_ascii_lowercase().replace(['.', '_'], "-")
}

/// Resolve `consult_model`'s `model` against the opencode model options
/// (`provider/model` values plus routing chain ids). A full id must exist; a
/// short alias must name exactly one model (optionally without its `claude-`
/// prefix). Unknown and ambiguous inputs list the close valid ids.
fn resolve_consult_model(input: &str, options: &[String]) -> Result<String, String> {
    let wanted = normalize_model_token(input);
    if wanted.is_empty() {
        return Err("model is required, e.g. openai/gpt-6-astra or fable-5.1".into());
    }
    // Gemini 4 Argon is served by Google (one Gemini CLI login) and by the
    // Antigravity pool (several Ultra logins with their own quotas): the bare
    // alias goes to the pool first; the proxy fails over between the two.
    if matches!(wanted.as_str(), "argon" | "gemini-4-argon" | "gemini-argon") {
        if let Some(preferred) = ["antigravity/gemini-4-argon-medium", "google/gemini-4-argon"]
            .iter()
            .find_map(|id| options.iter().find(|o| o.as_str() == *id))
        {
            return Ok(preferred.clone());
        }
    }
    if let Some(exact) = options.iter().find(|o| normalize_model_token(o) == wanted) {
        return Ok(exact.clone());
    }
    let mut matches: Vec<&String> = if wanted.contains('/') {
        Vec::new()
    } else {
        options
            .iter()
            .filter(|o| {
                let model = normalize_model_token(o.split_once('/').map_or(o.as_str(), |(_, m)| m));
                model == wanted || model == format!("claude-{wanted}")
            })
            .collect()
    };
    matches.sort();
    matches.dedup();
    match matches.as_slice() {
        [one] => Ok((*one).clone()),
        [] => {
            let family = wanted
                .rsplit('/')
                .next()
                .unwrap_or(&wanted)
                .split('-')
                .find(|t| !t.is_empty() && *t != "claude")
                .unwrap_or("")
                .to_string();
            let mut close: Vec<&str> = options
                .iter()
                .filter(|o| !family.is_empty() && normalize_model_token(o).contains(&family))
                .map(String::as_str)
                .collect();
            if close.is_empty() {
                close = options.iter().map(String::as_str).collect();
            }
            close.truncate(25);
            Err(format!(
                "Unknown model '{input}' for backend opencode. Pass one of these exact ids (or an unambiguous short alias): {}",
                close.join(", ")
            ))
        }
        many => Err(format!(
            "Model alias '{input}' is ambiguous; pass the full id, one of: {}",
            many.iter()
                .map(|m| m.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
}

fn consult_prompt(question: &str, files: &[String], read_only: bool) -> String {
    let mut prompt = String::new();
    if read_only {
        prompt.push_str(
            "You are consulted for a second opinion. Work read-only: inspect files, run read-only commands, do not modify files, branches or PRs.\n\n",
        );
    }
    prompt.push_str(question.trim());
    let files: Vec<&str> = files
        .iter()
        .map(|f| f.trim())
        .filter(|f| !f.is_empty())
        .collect();
    if !files.is_empty() {
        prompt.push_str("\n\nRead these files before answering:\n");
        for file in files {
            prompt.push_str("- ");
            prompt.push_str(file);
            prompt.push('\n');
        }
    }
    prompt.push_str("\n\nEnd with a concise, self-contained final answer.");
    prompt
}

fn mission_is_running(status: &str) -> bool {
    matches!(status, "pending" | "active" | "waiting_background")
}

/// PR writers own an outcome, not one conversational turn. Make that runtime
/// invariant explicit even when a controller forgets the `/goal` prefix; a
/// bounded reviewer (`writer: false`) remains a normal one-turn mission.
fn writer_goal_prompt(prompt: String, writer: bool) -> String {
    if !writer {
        return prompt;
    }
    let trimmed = prompt.trim_start();
    let already_goal = trimmed
        .strip_prefix("/goal")
        .is_some_and(|rest| rest.chars().next().is_some_and(char::is_whitespace));
    if already_goal {
        prompt
    } else {
        format!("/goal {prompt}")
    }
}

/// Deserialize a tool's arguments, naming the offending field when it fails.
///
/// `serde_json::from_value` reports the shape mismatch but not its location:
/// `invalid type: map, expected a string` for a struct with fourteen string
/// fields. An agent that reads that has no way to know which argument to fix.
///
/// Measured 2026-08-05: a controller called `start_mission` seven times in
/// ninety seconds, each time getting exactly that sentence back, until the
/// tool-loop guard cut it off. It was never told which field was wrong, so
/// each retry was a guess.
///
/// `serde_path_to_error` wraps the deserializer and tracks the path, turning
/// the same failure into `desired_state: invalid type: map, expected a
/// string` — actionable on the first read.
fn parse_params<T: serde::de::DeserializeOwned>(arguments: Value) -> Result<T, String> {
    let deserializer = arguments.into_deserializer();
    serde_path_to_error::deserialize(deserializer).map_err(|error| {
        let path = error.path().to_string();
        // The path is "." for a failure on the root value itself (arguments
        // that are not an object at all). Naming "." there would be noise.
        if path.is_empty() || path == "." {
            format!("Invalid params: {}", error.inner())
        } else {
            format!("Invalid params: {path}: {}", error.inner())
        }
    })
}

/// Accept only conservative session identifiers for `origin_session_id`
/// (Hermes session ids look like `20260803_150605_59ab72`; channel-keyed
/// sessions contain `:`). Keeping the shape tight means the value stays
/// machine-routable by the delivery handler.
fn valid_origin_session_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'))
}

fn native_backend_from_agent(agent: Option<&str>) -> Option<String> {
    match agent?.trim().to_ascii_lowercase().as_str() {
        "codex" => Some("codex".to_string()),
        "claudecode" => Some("claudecode".to_string()),
        "grok" => Some("grok".to_string()),
        "antigravity" => Some("antigravity".to_string()),
        "vibe" => Some("vibe".to_string()),
        _ => None,
    }
}

fn mission_start_tags(
    origin_tag: &str,
    tags: Option<Vec<String>>,
    request_merge_authority: bool,
    writer: bool,
    github_pr: Option<&str>,
    merge_grant: Option<&MergeGrantConfig>,
) -> Result<Vec<String>, String> {
    let mut tags: Vec<String> = tags
        .unwrap_or_default()
        .into_iter()
        .map(|tag| tag.trim().to_string())
        .filter(|tag| !tag.is_empty())
        .collect();
    tags.retain(|tag| {
        tag != "origin:hermes-assistant"
            && tag != "origin:mission"
            && tag != "merge-authority:granted"
            && !tag.starts_with("merge-authority-source:")
            && !tag.starts_with("merge-authority-target:")
            && !tag.starts_with("origin-session:")
            && !tag.starts_with("origin-platform:")
    });
    tags.push(origin_tag.to_string());

    if !request_merge_authority {
        return Ok(tags);
    }
    if !writer {
        return Err(
            "merge authority requires writer=true so the PR writer lease is held".to_string(),
        );
    }
    let github_pr = github_pr
        .map(str::trim)
        .filter(|value| canonical_github_pr_ref(value))
        .ok_or_else(|| {
            "merge authority requires github_pr in owner/repository#123 form".to_string()
        })?;
    let merge_grant = merge_grant.ok_or_else(|| {
        "merge authority was requested but no operator grant is configured".to_string()
    })?;
    let repository = github_pr.split_once('#').expect("validated PR ref").0;
    if !merge_grant.allows(repository) {
        return Err(format!(
            "merge authority was requested outside the configured repository scope: {repository}"
        ));
    }
    tags.push("merge-authority:granted".to_string());
    tags.push(format!(
        "merge-authority-source:{}",
        merge_grant.authority_source
    ));
    tags.push(format!("merge-authority-target:{github_pr}"));
    Ok(tags)
}

#[derive(Debug)]
struct MergeGrantConfig {
    authority_source: String,
    repositories: Vec<String>,
}

impl MergeGrantConfig {
    fn from_environment() -> Option<Self> {
        let authority_source = std::env::var("HERMES_MERGE_AUTHORITY_SOURCE")
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| {
                !value.is_empty()
                    && value.len() <= 128
                    && value.chars().all(|character| {
                        character.is_ascii_alphanumeric()
                            || matches!(character, '-' | '_' | ':' | '/' | '#' | '.')
                    })
            })?;
        let repositories: Vec<String> = std::env::var("HERMES_MERGE_AUTHORITY_REPOSITORIES")
            .ok()?
            .split(',')
            .map(|value| value.trim().to_ascii_lowercase())
            .filter(|value| !value.is_empty())
            .collect();
        if repositories.is_empty() {
            return None;
        }
        Some(Self {
            authority_source,
            repositories,
        })
    }

    fn allows(&self, repository: &str) -> bool {
        let repository = repository.to_ascii_lowercase();
        let owner = repository.split_once('/').map(|(owner, _)| owner);
        self.repositories.iter().any(|allowed| {
            allowed == &repository
                || allowed
                    .strip_suffix("/*")
                    .is_some_and(|allowed_owner| owner == Some(allowed_owner))
        })
    }
}

fn canonical_github_pr_ref(value: &str) -> bool {
    let Some((repository, number)) = value.split_once('#') else {
        return false;
    };
    if number.is_empty() || !number.bytes().all(|byte| byte.is_ascii_digit()) {
        return false;
    }
    let mut parts = repository.split('/');
    let (Some(owner), Some(repo), None) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    let valid_component = |component: &str| {
        !component.is_empty()
            && component.len() <= 100
            && component
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    };
    valid_component(owner) && valid_component(repo)
}

/// Shared by send and resume so both HTTP stages carry the same contract.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
struct DispatchIdentityParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    continue_identity: Option<crate::api::writer_recycle::WriterContinuation>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    github_pr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    track: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    title: Option<String>,
}

impl DispatchIdentityParams {
    fn add_to(&self, body: &mut Value) {
        body.as_object_mut().expect("request object").extend(
            serde_json::to_value(self)
                .expect("identity serialization")
                .as_object()
                .unwrap()
                .clone(),
        );
    }
}

fn dispatch_identity_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["project", "track", "github_pr"],
        "properties": {
            "project": {"type": ["string", "null"]},
            "track": {"type": "string", "minLength": 1},
            "github_pr": {"type": ["string", "null"]}
        },
        "description": "Trusted caller assertion, not proof of unchanged objective. Assert this turn continues the mission's existing work. Copy the exact stored project, track and github_pr (explicit null if unset) from get_mission. Prose may mention excluded or collaborating PRs. Cannot accompany title/track/github_pr updates; never use for different work. Does not grant PR ownership."
    })
}

#[derive(Debug, Deserialize)]
struct SendMessageParams {
    #[serde(default)]
    cloud_model: Option<String>,
    #[serde(default)]
    cloud_model_params: Option<Vec<crate::api::cloud_agents::ModelParam>>,
    #[serde(default)]
    client_message_id: Option<String>,
    #[serde(flatten)]
    identity: DispatchIdentityParams,
    mission_id: String,
    content: String,
}

#[derive(Debug, Deserialize)]
struct AskMissionParams {
    mission_id: String,
    content: String,
    /// Continue an existing Ask thread. Omit to start a new one.
    #[serde(default)]
    thread_id: Option<String>,
    /// Run the Ask bash tool in an isolated copy of the workspace (writes never
    /// touch the live tree). Opt-in.
    #[serde(default)]
    sandbox: bool,
}

#[derive(Debug, Deserialize)]
struct AnswerMissionQuestionParams {
    mission_id: String,
    /// Target a specific AskUserQuestion call. Omit to auto-resolve the
    /// mission's single unanswered question.
    #[serde(default)]
    tool_call_id: Option<String>,
    /// One inner array per question; each entry is an option label or free
    /// text.
    answers: Vec<Vec<String>>,
}

#[derive(Debug, Deserialize)]
struct WorkspaceBashParams {
    command: String,
    #[serde(default)]
    workspace_id: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    timeout_secs: Option<u64>,
    /// Supplying both ownership fields selects restart-safe execution.
    #[serde(default)]
    mission_id: Option<String>,
    #[serde(default)]
    idempotency_key: Option<String>,
}

#[derive(Debug, Deserialize)]
struct StartWorkspaceJobParams {
    #[serde(default)]
    command: Option<String>,
    #[serde(default)]
    argv: Option<Vec<String>>,
    #[serde(default)]
    workspace_id: Option<String>,
    mission_id: String,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    timeout_secs: Option<u64>,
    #[serde(default)]
    resource_class: Option<String>,
    idempotency_key: String,
}

#[derive(Debug, Deserialize)]
struct WorkspaceJobParams {
    job_id: String,
    #[serde(default = "default_job_tail_bytes")]
    tail_bytes: usize,
}

fn default_job_tail_bytes() -> usize {
    16 * 1024
}

fn shell_quote_arg(value: &str) -> String {
    if value.is_empty() {
        return "''".to_string();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn workspace_job_command(
    command: Option<String>,
    argv: Option<Vec<String>>,
) -> Result<String, String> {
    match (command, argv) {
        (Some(command), None) if !command.trim().is_empty() => Ok(command),
        (None, Some(argv)) if !argv.is_empty() => Ok(argv
            .iter()
            .map(|arg| shell_quote_arg(arg))
            .collect::<Vec<_>>()
            .join(" ")),
        (Some(_), Some(_)) => Err("Pass exactly one of command or argv, not both".to_string()),
        _ => Err("Pass a non-empty command or argv".to_string()),
    }
}

fn compact_workspace_job(job: Value) -> Value {
    json!({
        "id": job.get("id").cloned().unwrap_or(Value::Null),
        "status": job.get("status").cloned().unwrap_or(Value::Null),
        "remote": job.get("remote").cloned().unwrap_or(Value::Null),
        "spawn_accepted": job.get("spawn_accepted").cloned().unwrap_or(Value::Null),
        "heartbeat_at": job.get("heartbeat_at").cloned().unwrap_or(Value::Null),
        "deadline_at": job.get("deadline_at").cloned().unwrap_or(Value::Null),
        "scope_unit": job.get("scope_unit").cloned().unwrap_or(Value::Null),
        "pid": job.get("pid").cloned().unwrap_or(Value::Null),
        "exit_code": job.get("exit_code").cloned().unwrap_or(Value::Null),
        "signal": job.get("signal").cloned().unwrap_or(Value::Null),
        "workspace_id": job.get("workspace_id").cloned().unwrap_or(Value::Null),
        "mission_id": job.get("started_by_mission_id").cloned().unwrap_or(Value::Null),
        "resource_class": job.get("resource_class").cloned().unwrap_or(Value::Null),
        "created_at": job.get("created_at").cloned().unwrap_or(Value::Null),
        "updated_at": job.get("updated_at").cloned().unwrap_or(Value::Null),
    })
}

#[derive(Debug, Deserialize)]
struct WorkspaceIdParams {
    workspace_id: String,
}

#[derive(Debug, Deserialize)]
struct DeleteWorkspaceParams {
    workspace_id: String,
    #[serde(default)]
    confirm: bool,
}

#[derive(Debug, Deserialize)]
struct CreateWorkspaceParams {
    name: String,
    #[serde(default)]
    workspace_type: Option<String>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    skills: Option<Vec<String>>,
    #[serde(default)]
    plugins: Option<Vec<String>>,
    #[serde(default)]
    template: Option<String>,
    #[serde(default)]
    distro: Option<String>,
    #[serde(default)]
    env_vars: Option<HashMap<String, String>>,
    #[serde(default)]
    init_script: Option<String>,
    #[serde(default)]
    shared_network: Option<bool>,
    #[serde(default)]
    tailscale_mode: Option<String>,
    #[serde(default)]
    mcps: Option<Vec<String>>,
    #[serde(default)]
    mcps_replace_defaults: Option<bool>,
    #[serde(default)]
    config_profile: Option<String>,
}

#[derive(Debug, Deserialize)]
struct UpdateWorkspaceParams {
    workspace_id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    skills: Option<Vec<String>>,
    #[serde(default)]
    plugins: Option<Vec<String>>,
    #[serde(default)]
    template: Option<String>,
    #[serde(default)]
    distro: Option<String>,
    #[serde(default)]
    env_vars: Option<HashMap<String, String>>,
    #[serde(default)]
    init_script: Option<String>,
    #[serde(default)]
    init_scripts: Option<Vec<String>>,
    #[serde(default)]
    shared_network: Option<bool>,
    #[serde(default)]
    tailscale_mode: Option<String>,
    #[serde(default)]
    mcps: Option<Vec<String>>,
    #[serde(default)]
    mcps_replace_defaults: Option<bool>,
    #[serde(default)]
    config_profile: Option<String>,
    #[serde(default)]
    config: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct WorkspaceTemplateNameParams {
    name: String,
}

#[derive(Debug, Deserialize)]
struct SaveWorkspaceTemplateParams {
    name: String,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    distro: Option<String>,
    #[serde(default)]
    skills: Option<Vec<String>>,
    #[serde(default)]
    env_vars: Option<HashMap<String, String>>,
    #[serde(default)]
    encrypted_keys: Option<Vec<String>>,
    #[serde(default)]
    init_scripts: Option<Vec<String>>,
    #[serde(default)]
    init_script: Option<String>,
    #[serde(default)]
    shared_network: Option<bool>,
    #[serde(default)]
    tailscale_mode: Option<String>,
    #[serde(default)]
    mcps: Option<Vec<String>>,
    #[serde(default)]
    mcps_replace_defaults: Option<bool>,
    #[serde(default)]
    config_profile: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DeleteWorkspaceTemplateParams {
    name: String,
    #[serde(default)]
    confirm: bool,
}

#[derive(Debug, Deserialize)]
struct RebuildWorkspaceFromTemplateParams {
    workspace_id: String,
    #[serde(default)]
    template: Option<String>,
    #[serde(default)]
    confirm: bool,
}

#[derive(Debug, Deserialize)]
struct UpdateSettingsParams {
    mission_id: String,
    #[serde(default)]
    backend: Option<String>,
    #[serde(default)]
    model_override: Option<String>,
    #[serde(default)]
    model_effort: Option<String>,
    #[serde(default)]
    fast_mode: Option<bool>,
    #[serde(default)]
    agent: Option<String>,
    #[serde(default)]
    config_profile: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ResumeMissionParams {
    #[serde(flatten)]
    identity: DispatchIdentityParams,
    mission_id: String,
    /// Optional steering message delivered as the resume turn's prompt instead
    /// of the default "continue where you left off" text.
    #[serde(default)]
    content: Option<String>,
    /// Wipe the mission work directory before resuming. Rarely needed.
    #[serde(default)]
    clean_workspace: bool,
}

#[derive(Debug, Deserialize)]
struct MissionHealthParams {
    mission_id: String,
}

#[derive(Debug, Deserialize)]
struct MissionDiagnosticsParams {
    mission_id: String,
    #[serde(default = "default_diagnostics_limit")]
    limit: usize,
}

/// Readable projection only: the persisted trace remains the raw receipt.
fn diagnostic_result_snippet(content: &str) -> String {
    fn collect(value: &Value, parts: &mut Vec<String>, depth: usize) {
        if depth > 12 {
            return;
        }
        match value {
            Value::String(text) => {
                if !text.trim().is_empty() && !parts.contains(text) {
                    parts.push(text.clone());
                }
            }
            Value::Array(values) => {
                // Node Buffer/byte output must not become hundreds of integer tokens.
                if !values.is_empty()
                    && values
                        .iter()
                        .all(|value| value.as_u64().is_some_and(|byte| byte <= 255))
                {
                    let bytes: Vec<u8> = values
                        .iter()
                        .map(|value| value.as_u64().unwrap() as u8)
                        .collect();
                    if let Ok(text) = String::from_utf8(bytes) {
                        collect(&Value::String(text), parts, depth + 1);
                    }
                } else {
                    for value in values {
                        collect(value, parts, depth + 1);
                    }
                }
            }
            Value::Object(fields) => {
                for key in ["text", "content", "stdout", "stderr", "output", "rawOutput"] {
                    if let Some(value) = fields.get(key) {
                        collect(value, parts, depth + 1);
                    }
                }
                if fields.get("type").and_then(Value::as_str) == Some("Buffer") {
                    if let Some(value) = fields.get("data") {
                        collect(value, parts, depth + 1);
                    }
                }
            }
            _ => {}
        }
    }
    let mut parts = Vec::new();
    if let Ok(value) = serde_json::from_str::<Value>(content) {
        collect(&value, &mut parts, 0);
    }
    let text = if parts.is_empty() {
        content.to_string()
    } else {
        parts.join("\n")
    };
    truncate_snippet(&text, 800)
}

fn default_diagnostics_limit() -> usize {
    80
}

fn default_limit() -> usize {
    50
}

fn default_event_limit() -> usize {
    40
}

fn mission_events_path(
    id: Uuid,
    limit: usize,
    view: &str,
    before_seq: Option<i64>,
    since_seq: Option<i64>,
) -> String {
    let mut path =
        format!("/api/control/missions/{id}/events?limit={limit}&view={view}&include_counts=false");
    if let Some(before_seq) = before_seq {
        path.push_str(&format!("&before_seq={before_seq}"));
    } else if let Some(since_seq) = since_seq {
        path.push_str(&format!("&since_seq={since_seq}"));
    } else {
        // The events endpoint already defaults to the newest page when no
        // cursor is supplied, but Hermes uses this bounded tool for live
        // reconciliation, so we pin the tail explicitly to stay robust against
        // any future change to the server-side default.
        path.push_str(&format!("&before_seq={}", i64::MAX));
    }
    path
}

/// One unanswered AskUserQuestion tool call found in a mission's events.
#[derive(Debug, PartialEq, Eq)]
struct PendingAskQuestion {
    tool_call_id: String,
    sequence: i64,
    /// Question texts parsed from the call args, best-effort.
    questions: Vec<String>,
}

impl PendingAskQuestion {
    fn summary(&self) -> String {
        if self.questions.is_empty() {
            "(question text unavailable)".to_string()
        } else {
            self.questions.join(" | ")
        }
    }
}

/// Unanswered AskUserQuestion calls in `events`, newest first. A call is
/// unanswered when no tool_result event anywhere in the page shares its
/// tool_call_id.
fn pending_ask_user_questions(events: &[Value]) -> Vec<PendingAskQuestion> {
    let mut answered: std::collections::HashSet<&str> = std::collections::HashSet::new();
    for event in events {
        if event.get("event_type").and_then(Value::as_str) == Some("tool_result") {
            if let Some(id) = event.get("tool_call_id").and_then(Value::as_str) {
                answered.insert(id);
            }
        }
    }
    let mut pending = Vec::new();
    for event in events {
        if event.get("event_type").and_then(Value::as_str) != Some("tool_call")
            || event.get("tool_name").and_then(Value::as_str) != Some("AskUserQuestion")
        {
            continue;
        }
        let Some(id) = event.get("tool_call_id").and_then(Value::as_str) else {
            continue;
        };
        if answered.contains(id) {
            continue;
        }
        let questions = event
            .get("content")
            .and_then(Value::as_str)
            .and_then(|content| serde_json::from_str::<Value>(content).ok())
            .as_ref()
            .and_then(|args| args.get("questions"))
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.get("question").and_then(Value::as_str))
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        pending.push(PendingAskQuestion {
            tool_call_id: id.to_string(),
            sequence: event.get("sequence").and_then(Value::as_i64).unwrap_or(0),
            questions,
        });
    }
    pending.sort_by_key(|question| std::cmp::Reverse(question.sequence));
    pending
}

fn insert_optional<T: Serialize>(
    body: &mut serde_json::Map<String, Value>,
    key: &str,
    value: Option<T>,
) -> Result<(), String> {
    if let Some(value) = value {
        body.insert(
            key.to_string(),
            serde_json::to_value(value)
                .map_err(|error| format!("Failed to encode {key}: {error}"))?,
        );
    }
    Ok(())
}

fn require_resource_name(name: &str, resource: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err(format!("{resource} name cannot be empty"));
    }
    Ok(name.to_string())
}

fn create_workspace_body(params: CreateWorkspaceParams) -> Result<Value, String> {
    let mut body = serde_json::Map::new();
    body.insert(
        "name".to_string(),
        json!(require_resource_name(&params.name, "Workspace")?),
    );
    insert_optional(&mut body, "workspace_type", params.workspace_type)?;
    insert_optional(&mut body, "path", params.path)?;
    insert_optional(&mut body, "skills", params.skills)?;
    insert_optional(&mut body, "plugins", params.plugins)?;
    insert_optional(&mut body, "template", params.template)?;
    insert_optional(&mut body, "distro", params.distro)?;
    insert_optional(&mut body, "env_vars", params.env_vars)?;
    insert_optional(&mut body, "init_script", params.init_script)?;
    insert_optional(&mut body, "shared_network", params.shared_network)?;
    insert_optional(&mut body, "tailscale_mode", params.tailscale_mode)?;
    insert_optional(&mut body, "mcps", params.mcps)?;
    insert_optional(
        &mut body,
        "mcps_replace_defaults",
        params.mcps_replace_defaults,
    )?;
    insert_optional(&mut body, "config_profile", params.config_profile)?;
    Ok(Value::Object(body))
}

fn update_workspace_body(params: UpdateWorkspaceParams) -> Result<(Uuid, Value), String> {
    let id = parse_uuid(&params.workspace_id)?;
    let mut body = serde_json::Map::new();
    insert_optional(&mut body, "name", params.name)?;
    insert_optional(&mut body, "skills", params.skills)?;
    insert_optional(&mut body, "plugins", params.plugins)?;
    insert_optional(&mut body, "template", params.template)?;
    insert_optional(&mut body, "distro", params.distro)?;
    insert_optional(&mut body, "env_vars", params.env_vars)?;
    insert_optional(&mut body, "init_script", params.init_script)?;
    insert_optional(&mut body, "init_scripts", params.init_scripts)?;
    insert_optional(&mut body, "shared_network", params.shared_network)?;
    insert_optional(&mut body, "tailscale_mode", params.tailscale_mode)?;
    insert_optional(&mut body, "mcps", params.mcps)?;
    insert_optional(
        &mut body,
        "mcps_replace_defaults",
        params.mcps_replace_defaults,
    )?;
    insert_optional(&mut body, "config_profile", params.config_profile)?;
    insert_optional(&mut body, "config", params.config)?;
    if body.is_empty() {
        return Err("No workspace fields supplied to update".to_string());
    }
    Ok((id, Value::Object(body)))
}

fn apply_template_patch(
    template: &mut serde_json::Map<String, Value>,
    params: SaveWorkspaceTemplateParams,
) -> Result<(), String> {
    insert_optional(template, "description", params.description)?;
    insert_optional(template, "distro", params.distro)?;
    insert_optional(template, "skills", params.skills)?;
    insert_optional(template, "env_vars", params.env_vars)?;
    insert_optional(template, "encrypted_keys", params.encrypted_keys)?;
    insert_optional(template, "init_scripts", params.init_scripts)?;
    insert_optional(template, "init_script", params.init_script)?;
    insert_optional(template, "shared_network", params.shared_network)?;
    insert_optional(template, "tailscale_mode", params.tailscale_mode)?;
    insert_optional(template, "mcps", params.mcps)?;
    insert_optional(
        template,
        "mcps_replace_defaults",
        params.mcps_replace_defaults,
    )?;
    insert_optional(template, "config_profile", params.config_profile)?;
    Ok(())
}

fn default_artifact_dir() -> PathBuf {
    std::env::var("HERMES_ASSISTANT_ARTIFACT_DIR")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/hermes-assistant-artifacts"))
}

fn sanitize_filename(name: &str) -> String {
    let clean = name
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-' | '_') {
                ch
            } else {
                '_'
            }
        })
        .collect::<String>()
        .trim_matches('_')
        .trim_start_matches('.')
        .to_string();
    if clean.is_empty() {
        "artifact".to_string()
    } else {
        clean.chars().take(180).collect()
    }
}

fn output_dir_for_shared_file(
    mission_id: &Uuid,
    requested: Option<String>,
) -> Result<PathBuf, String> {
    let base = requested
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(default_artifact_dir);
    if !base.is_absolute() {
        return Err("output_dir must be an absolute path".to_string());
    }
    // Reject `..` components: `starts_with` is lexical, so `/tmp/../etc` would
    // pass the prefix check below while resolving outside the real /tmp tree.
    if base
        .components()
        .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err("output_dir must not contain '..' components".to_string());
    }
    if !base.starts_with(Path::new("/tmp")) {
        return Err(
            "output_dir must be under /tmp so Paloma's email attachment policy can allow it"
                .to_string(),
        );
    }
    Ok(base.join(mission_id.to_string()))
}

fn shared_file_name_from_url(url: &str) -> Option<String> {
    let marker = "path=";
    let encoded = url.split(marker).nth(1)?.split('&').next()?;
    let decoded = urlencoding::decode(encoded).ok()?;
    Path::new(decoded.as_ref())
        .file_name()
        .and_then(|name| name.to_str())
        .map(ToString::to_string)
}

fn shared_file_download_path(url: &str) -> Result<String, String> {
    if url.starts_with("/api/fs/download?") {
        return Ok(url.to_string());
    }
    let parsed =
        reqwest::Url::parse(url).map_err(|error| format!("Invalid shared file URL: {error}"))?;
    if parsed.path() != "/api/fs/download" {
        return Err("Only /api/fs/download shared file URLs can be downloaded".to_string());
    }
    let query = parsed
        .query()
        .map(|query| format!("?{query}"))
        .unwrap_or_default();
    Ok(format!("{}{}", parsed.path(), query))
}

pub(super) struct AssistantMcp {
    api_url: String,
    api_token: Option<String>,
    /// Slugs this instance may MUTATE (`SANDBOXED_PROJECT_SCOPE`, comma-list).
    /// None = unrestricted (the owner's interactive Hermes). Reads are never
    /// scoped — cross-project awareness is a feature, not a leak.
    project_scope: Option<std::collections::HashSet<String>>,
    client: reqwest::Client,
}

impl AssistantMcp {
    pub(super) fn connected(api_url: String, api_token: String) -> Self {
        Self {
            api_url,
            api_token: Some(api_token),
            project_scope: None,
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(120))
                .build()
                .expect("HTTP client"),
        }
    }

    /// Scope gate for mission-level mutators. A scoped controller may only
    /// touch missions tagged with one of its projects — anything else
    /// (another project's mission, or an untagged one it cannot prove it
    /// owns) is refused. Unscoped instances skip the lookup entirely.
    async fn assert_mission_scope(&self, mission_id: Uuid) -> Result<(), String> {
        if self.project_scope.is_none() {
            return Ok(());
        }
        let response = self
            .api_get(&format!("/api/control/missions/{mission_id}"))
            .await?;
        let mission = Self::response_value(response, "load mission for scope check").await?;
        let project = mission
            .get("project")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|slug| !slug.is_empty());
        match project {
            Some(slug) => self.assert_project_scope(slug),
            None => Err(format!(
                "mission {mission_id} carries no project tag — a scoped controller may only \
                 act on missions tagged with its own project"
            )),
        }
    }

    /// Gate for MUTATING project tools. Scoped controllers stay inside their
    /// own project; unscoped instances (owner chat) pass untouched.
    fn assert_project_scope(&self, slug: &str) -> Result<(), String> {
        let slug = slug.trim();
        match &self.project_scope {
            Some(scope) if !scope.contains(slug) => {
                let mut allowed: Vec<&str> = scope.iter().map(String::as_str).collect();
                allowed.sort_unstable();
                Err(format!(
                    "project '{slug}' is outside this controller's scope ({}). \
                     Mutating tools are limited to your own project; reads are unrestricted.",
                    allowed.join(", ")
                ))
            }
            _ => Ok(()),
        }
    }

    fn auth_header(&self) -> Option<(String, String)> {
        // Core supplies this short-lived internal credential after scope checks.
        self.api_token
            .clone()
            .map(|token| ("Authorization".to_string(), format!("Bearer {token}")))
    }

    /// Turn whatever the caller has into a mission UUID.
    ///
    /// Dashboards, logs and transcripts all show the 8-character prefix, so a
    /// controller keeping notes across days inevitably feeds one back. A full
    /// UUID resolves locally with no round trip; anything else asks the
    /// server, which is the only party that can tell whether the fragment is
    /// unambiguous. Ambiguity surfaces the candidates instead of guessing.
    async fn resolve_mission_id(&self, raw: &str) -> Result<Uuid, String> {
        let trimmed = raw.trim();
        if let Ok(id) = Uuid::parse_str(trimmed) {
            return Ok(id);
        }
        let response = self
            .api_get(&format!(
                "/api/control/missions/resolve?id={}",
                urlencoding::encode(trimmed)
            ))
            .await?;
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        if status.is_success() {
            let value: Value = serde_json::from_str(&body)
                .map_err(|error| format!("Failed to parse mission resolve response: {error}"))?;
            return value
                .get("mission_id")
                .and_then(Value::as_str)
                .and_then(|id| Uuid::parse_str(id).ok())
                .ok_or_else(|| format!("Mission resolve returned no id for '{trimmed}'"));
        }
        // Name the candidates so the next call can be exact.
        if let Ok(value) = serde_json::from_str::<Value>(&body) {
            if value.get("error").and_then(Value::as_str) == Some("ambiguous") {
                let listed = value
                    .get("candidates")
                    .and_then(Value::as_array)
                    .map(|rows| {
                        rows.iter()
                            .filter_map(|row| {
                                let id = row.get("id")?.as_str()?;
                                let title = row.get("title").and_then(Value::as_str).unwrap_or("");
                                let mission_status =
                                    row.get("status").and_then(Value::as_str).unwrap_or("");
                                Some(format!("{id} ({mission_status}, {title:?})"))
                            })
                            .collect::<Vec<_>>()
                            .join("; ")
                    })
                    .unwrap_or_default();
                return Err(format!(
                    "Ambiguous mission id '{trimmed}' — candidates: {listed}. Pass the full id."
                ));
            }
        }
        Err(format!(
            "Failed to resolve mission '{trimmed}' ({status}): {body}"
        ))
    }

    async fn api_get(&self, path: &str) -> Result<reqwest::Response, String> {
        let mut req = self.client.get(format!("{}{}", self.api_url, path));
        if let Some((name, value)) = self.auth_header() {
            req = req.header(name, value);
        }
        req.send()
            .await
            .map_err(|error| format!("HTTP request failed: {error}"))
    }

    async fn api_get_bytes(&self, path: &str) -> Result<Vec<u8>, String> {
        let response = self.api_get(path).await?;
        if !response.status().is_success() {
            return Err(format!(
                "Failed to download shared file: {}",
                response.status()
            ));
        }
        response
            .bytes()
            .await
            .map(|bytes| bytes.to_vec())
            .map_err(|error| format!("Failed to read shared file bytes: {error}"))
    }

    async fn api_post(&self, path: &str, body: Value) -> Result<reqwest::Response, String> {
        self.api_post_with_timeout(path, body, None).await
    }

    /// POST with an optional per-request timeout override. The shared client's
    /// default is 120s; synchronous long-running endpoints (`/ask`) need more
    /// headroom than that but must still resolve before the Hermes-side MCP
    /// request timeout (600s in the generated config) so the caller gets a
    /// clean error instead of a severed stdio call.
    async fn api_post_with_timeout(
        &self,
        path: &str,
        body: Value,
        timeout: Option<std::time::Duration>,
    ) -> Result<reqwest::Response, String> {
        let mut req = self
            .client
            .post(format!("{}{}", self.api_url, path))
            .json(&body);
        if let Some(timeout) = timeout {
            req = req.timeout(timeout);
        }
        if let Some((name, value)) = self.auth_header() {
            req = req.header(name, value);
        }
        req.send()
            .await
            .map_err(|error| format!("HTTP request failed: {error}"))
    }

    async fn api_patch(&self, path: &str, body: Value) -> Result<reqwest::Response, String> {
        let mut req = self
            .client
            .patch(format!("{}{}", self.api_url, path))
            .json(&body);
        if let Some((name, value)) = self.auth_header() {
            req = req.header(name, value);
        }
        req.send()
            .await
            .map_err(|error| format!("HTTP request failed: {error}"))
    }

    async fn api_put(&self, path: &str, body: Value) -> Result<reqwest::Response, String> {
        let mut req = self
            .client
            .put(format!("{}{}", self.api_url, path))
            .json(&body);
        if let Some((name, value)) = self.auth_header() {
            req = req.header(name, value);
        }
        req.send()
            .await
            .map_err(|error| format!("HTTP request failed: {error}"))
    }

    async fn api_delete(&self, path: &str) -> Result<reqwest::Response, String> {
        let mut req = self.client.delete(format!("{}{}", self.api_url, path));
        if let Some((name, value)) = self.auth_header() {
            req = req.header(name, value);
        }
        req.send()
            .await
            .map_err(|error| format!("HTTP request failed: {error}"))
    }

    async fn response_value(response: reqwest::Response, operation: &str) -> Result<Value, String> {
        let status = response.status();
        let bytes = response
            .bytes()
            .await
            .map_err(|error| format!("Failed to read {operation} response: {error}"))?;
        if !status.is_success() {
            let detail = String::from_utf8_lossy(&bytes);
            return Err(format!("{operation} failed ({status}): {detail}"));
        }
        if bytes.is_empty() {
            return Ok(json!({"success": true}));
        }
        match serde_json::from_slice(&bytes) {
            Ok(value) => Ok(value),
            Err(_) => Ok(json!({
                "success": true,
                "message": String::from_utf8_lossy(&bytes).trim(),
            })),
        }
    }

    pub(super) fn tools() -> Vec<ToolDefinition> {
        vec![
            ToolDefinition {
                name: "spawn_managed_machine".to_string(),
                description: "Rent a fresh, disposable cloud VM across Core's native providers (`boat` default, `hetzner`, `vastai`, `scaleway`) and enroll it as a compute node (or raw guest), so you can run a subagent or heavy CPU/GPU/ARM64/macOS job with Core-enforced ownership, budget caps, and automatic idle reaping. NEVER fetch cloud API keys via `secret_get` to rent VMs directly. Sizes by provider: `boat` (`small` 2 vCPU/4 GB, `default` 4 vCPU/8 GB, `large` 8 vCPU/16 GB, `xlarge` 16 vCPU/32 GB on Zen 5), `hetzner` (`cpx21`, `cpx31`, `cpx41`, `cpx51` x86_64; `cax21`, `cax31`, `cax41` arm64), `vastai` (`rtx4090`, `a100`, `h100` CUDA GPUs), `scaleway` (`PRO2-S`, `PRO2-M`, `L4-1-24G`, `H100-1-80G`, and `M2-M`/`M2-L` Apple Silicon macOS with `allow_24h_commitment=true`). Or pass `cpu`, `ram_gb`, `gpu`, or `arch` and Core picks the cheapest fitting tier. Shortcut: `start_mission(remote_node_id=\"auto-managed:<provider>:<size>\")` spawns and places in one call. Every machine has a TTL (default 60 min, auto-extended while busy, max 720) and is reaped automatically after your mission ends, after 15 min idle while unused (5 min post-job), or at its TTL. Call `destroy_managed_machine` as soon as you are done.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "properties": {
                        "provider": {"type": "string", "enum": ["boat", "hetzner", "vastai", "scaleway"], "description": "Cloud provider (default `boat`; `hetzner` for cheap EU x86_64/arm64 Linux, `vastai` for disposable CUDA GPUs, `scaleway` for EU Linux/GPU or Apple Silicon macOS)."},
                        "size": {"type": "string", "description": "Provider size tier (e.g. `small`/`default`/`large`/`xlarge` on boat; `cpx41`/`cax31` on hetzner; `rtx4090`/`a100`/`h100` on vastai; `PRO2-S`/`L4-1-24G`/`M2-M` on scaleway). Omit to pick from cpu/ram_gb/gpu/arch or the provider default."},
                        "cpu": {"type": "integer", "minimum": 1, "maximum": 128, "description": "Minimum vCPUs needed (alternative to size)."},
                        "ram_gb": {"type": "integer", "minimum": 1, "maximum": 512, "description": "Minimum RAM in GB needed (alternative to size)."},
                        "gpu": {"type": "string", "description": "Optional GPU requirement (e.g. `rtx4090`, `l4`, `a100`, `h100`)."},
                        "arch": {"type": "string", "enum": ["x86_64", "arm64"], "description": "Optional CPU architecture (`x86_64` or `arm64`)."},
                        "max_hourly_usd": {"type": "number", "minimum": 0, "description": "Optional ceiling on hourly rate (USD/h) when Core selects a tier."},
                        "allow_24h_commitment": {"type": "boolean", "description": "Explicit opt-in required for providers/tiers with a 24-hour minimum billing lease (Scaleway Apple Silicon `M2-*`)."},
                        "ttl_minutes": {"type": "integer", "minimum": 5, "maximum": 720, "description": "Initial lifetime; auto-extended while busy (within budget). Default 60."},
                        "image": {"type": "string", "description": "Optional image or snapshot override."},
                        "provisioning_mode": {"type": "string", "enum": ["worker", "raw"], "description": "Worker installs/enrolls Orb (default). Raw only rents the VM (Boat): use `exec_raw_managed_machine` for bounded guest ops."},
                        "from_snapshot": {"type": "string", "description": "Start from one of your project's Boat snapshots (`list_managed_snapshots`) with repos, toolchains and caches ready."},
                        "reason": {"type": "string", "description": "Why you need it (shown to the operator and in the cost ledger)."}
                    }
                }),
            },
            ToolDefinition {
                name: "exec_raw_managed_machine".to_string(),
                description: "Run an owner-scoped, at-most-once command or file operation (`exec`, `write_file`, `read_file`) on a `provisioning_mode=\"raw\"` managed VM without SSH keys or Orb worker enrollment.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["machine_id", "operation"],
                    "properties": {
                        "machine_id": {"type": "string", "description": "Raw managed machine name or id."},
                        "operation": {"type": "string", "enum": ["exec", "write_file", "read_file"]},
                        "command": {"type": "string", "description": "Shell command for `operation=\"exec\"` (<= 64 KB)."},
                        "timeout_secs": {"type": "integer", "minimum": 1, "maximum": 120, "description": "Timeout in seconds for `operation=\"exec\"` (default 60)."},
                        "path": {"type": "string", "description": "Absolute guest path (`/…`) for `write_file` or `read_file`."},
                        "content": {"type": "string", "description": "UTF-8 file content for `write_file` (<= 64 KB)."}
                    }
                }),
            },
            ToolDefinition {
                name: "list_managed_machines".to_string(),
                description: "List live managed VMs across all configured providers (`boat`, `hetzner`, `vastai`, `scaleway`) compactly: name, provider, size, state, project, owner, expires_at, reap_at, deletable_at, cost so far, plus configured providers, today's spend, running count and caps. Pass verbose=true for full rows and the last 24 h of destroyed machines. Check this before spawning to reuse a machine you already own.".to_string(),
                input_schema: json!({"type": "object", "properties": {"verbose": {"type": "boolean", "description": "Full rows and history (large)."}}}),
            },
            ToolDefinition {
                name: "snapshot_managed_machine".to_string(),
                description: "Save a named snapshot of a managed VM for your project (warm image: repos cloned, toolchains installed, build caches built). Put state outside /tmp and ~/.cache (snapshots do not keep them). Takes seconds to minutes (status saving -> ready); delivered secrets are removed first. Start children from it with spawn_managed_machine(from_snapshot=name) or start_mission(remote_node_id=\"auto-managed:<size>\", managed_from_snapshot=name). 10 snapshots are free, then $1.70/month each; Core keeps the newest 2 per project and deletes ones unused for 14 days.".to_string(),
                input_schema: json!({"type":"object","required":["machine_id","name"],"properties":{"machine_id":{"type":"string"},"name":{"type":"string","description":"Short label, e.g. lean-native-warm"}}}),
            },
            ToolDefinition {
                name: "list_managed_snapshots".to_string(),
                description: "List your project's managed-VM snapshots: name, label, status, source machine, size, created/last used, monthly storage cost.".to_string(),
                input_schema: json!({"type":"object","properties":{}}),
            },
            ToolDefinition {
                name: "delete_managed_snapshot".to_string(),
                description: "Delete one of your project's snapshots (refused while a machine is being created from it).".to_string(),
                input_schema: json!({"type":"object","required":["name"],"properties":{"name":{"type":"string"}}}),
            },
            ToolDefinition {
                name: "fork_managed_machine".to_string(),
                description: "Create a new managed VM from another VM's current state (a subagent starting from your built tree). Boat forks from the latest background snapshot, which can be about a minute stale: write and `sync` what the child needs and wait ~60 s first, or take a named snapshot for an exact copy. Same size unless size is given; budget and caps apply like a new VM. Then start_mission(remote_node_id=<returned name>).".to_string(),
                input_schema: json!({"type":"object","required":["machine_id"],"properties":{"machine_id":{"type":"string"},"size":{"type":"string","enum":["small","default","large","xlarge"]},"ttl_minutes":{"type":"integer","minimum":5,"maximum":720},"reason":{"type":"string"}}}),
            },
            ToolDefinition {
                name: "stop_managed_machine".to_string(),
                description: "Stop a managed VM you will need again later: billing stops, the disk is kept (resume within 24 h). Prefer this to leaving a VM idle.".to_string(),
                input_schema: json!({"type":"object","required":["machine_id"],"properties":{"machine_id":{"type":"string"}}}),
            },
            ToolDefinition {
                name: "resume_managed_machine".to_string(),
                description: "Resume a stopped managed VM (same name and node id; files kept, processes restart). Budget and caps apply.".to_string(),
                input_schema: json!({"type":"object","required":["machine_id"],"properties":{"machine_id":{"type":"string"},"ttl_minutes":{"type":"integer","minimum":5,"maximum":720}}}),
            },
            ToolDefinition {
                name: "get_budget".to_string(),
                description: "Your mission's managed-VM spending budget: mode (own, pooled from an ancestor, or none = only the daily cap), the pool's budget, spent, reserved (min(TTL, 60 min) of each live VM), held by children's sub-budgets, remaining, the most you may grant a child (start_mission budget_usd), and each child's usage. Spawns, extensions and sub-budgets beyond the remaining amount are refused with budget_exceeded / sub_budget_exceeds_pool.".to_string(),
                input_schema: json!({"type": "object", "properties": {"mission_id": {"type": "string", "description": "Hermes only; missions always get their own."}}}),
            },
            ToolDefinition {
                name: "destroy_managed_machine".to_string(),
                description: "Destroy a managed VM you no longer need (stops billing immediately and closes its cost ledger). Idempotent. Pass the machine name (e.g. small-a), id (mm…) or node id (managed-mm…).".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["machine_id"],
                    "properties": {"machine_id": {"type": "string"}}
                }),
            },
            ToolDefinition {
                name: "extend_managed_machine".to_string(),
                description: "Extend a managed VM's TTL by ttl_minutes beyond its current expiry (total lifetime capped at 720 minutes after creation).".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["machine_id", "ttl_minutes"],
                    "properties": {"machine_id": {"type": "string"}, "ttl_minutes": {"type": "integer", "minimum": 5, "maximum": 720}}
                }),
            },
            ToolDefinition {
                name: "list_active_missions".to_string(),
                description: "List active, pending, blocked, or awaiting-user missions in sandboxed.sh. Includes goal_mode separately from mission_mode and a goal_objective preview of at most 1,000 characters plus a truncation ellipsis.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "properties": {
                        "limit": {"type": "integer", "description": "Maximum missions to return, default 50."},
                        "project": {"type": "string", "description": "Optional filter: exact project id."},
                        "project_prefix": {"type": "string", "description": "Optional filter: project FAMILY — matches the id and its `-` suffixed variants (e.g. verity covers verity-core, verity-phase1d). Use this when a project's work is still split across per-phase ids."},
                        "track": {"type": "string", "description": "Optional filter: exact track within a project."},
                        "tag": {"type": "string", "description": "Optional filter: only missions carrying this tag."},
                        "origin_session_id": {"type": "string", "description": "Optional filter: only missions launched from this Hermes conversation."}
                    }
                }),
            },
            ToolDefinition {
                name: "list_missions".to_string(),
                description: "List missions on the attention horizon: live, waiting, blocked, and unabsorbed failed/interrupted attempts. Acknowledged, completed, and replaced attempts are omitted unless you pass an explicit status. Filter by project or track to see attempts on one item. Prefer get_project for the item-first inventory. Includes goal_mode separately from mission_mode and a goal_objective preview of at most 1,000 characters plus a truncation ellipsis.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "properties": {
                        "status": {"type": "string", "description": "Optional mission status filter."},
                        "limit": {"type": "integer", "description": "Maximum missions to return, default 50."},
                        "project": {"type": "string", "description": "Optional filter: exact project id."},
                        "project_prefix": {"type": "string", "description": "Optional filter: project FAMILY — matches the id and its `-` suffixed variants (e.g. verity covers verity-core, verity-phase1d). Use this when a project's work is still split across per-phase ids."},
                        "track": {"type": "string", "description": "Optional filter: exact track within a project."},
                        "tag": {"type": "string", "description": "Optional filter: only missions carrying this tag."},
                        "origin_session_id": {"type": "string", "description": "Optional filter: only missions launched from this Hermes conversation."}
                    }
                }),
            },
            ToolDefinition {
                name: "get_mission".to_string(),
                description: "Compatibility alias for the compact ~2KB mission digest. It never returns the full history; use get_mission_events with a bounded limit for transcript or trace details. Includes goal_mode separately from mission_mode and a goal_objective preview of at most 1,000 characters plus a truncation ellipsis.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id"],
                    "properties": {"mission_id": {"type": "string", "description": "Mission UUID, or an unambiguous leading fragment of one (the 8-character form dashboards and logs display)."}}
                }),
            },
            ToolDefinition {
                name: "get_mission_digest".to_string(),
                description: "Compact ~2KB mission status: state, awaiting_kind, last user/assistant messages (truncated), GitHub PR links, project metadata. Use this instead of get_mission/get_mission_events for recaps and 'where is it?' checks — it avoids pulling whole transcripts into context. Includes goal_mode separately from mission_mode and a goal_objective preview of at most 1,000 characters plus a truncation ellipsis.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id"],
                    "properties": {"mission_id": {"type": "string", "description": "Mission UUID, or an unambiguous leading fragment of one (the 8-character form dashboards and logs display)."}}
                }),
            },
            ToolDefinition {
                name: "get_mission_events".to_string(),
                description: "Fetch persisted mission events. Without a cursor, returns the newest bounded page in ascending order; use before_seq to page backwards or since_seq for deltas.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id"],
                    "properties": {
                        "mission_id": {"type": "string"},
                        "limit": {"type": "integer", "description": "Maximum events to return, default 40 newest events."},
                        "view": {"type": "string", "enum": ["transcript", "trace", "history", "all"]},
                        "since_seq": {"type": "integer", "description": "Return events with sequence greater than this value."},
                        "before_seq": {"type": "integer", "description": "Page backwards: return the newest events with sequence below this value (takes precedence over since_seq)."}
                    }
                }),
            },
            ToolDefinition {
                name: "list_mission_shared_files".to_string(),
                description: "List files and screenshots shared by assistant messages in a sandboxed.sh mission.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id"],
                    "properties": {
                        "mission_id": {"type": "string"},
                        "limit": {"type": "integer", "description": "Maximum mission events to scan, default 40."}
                    }
                }),
            },
            ToolDefinition {
                name: "download_shared_file".to_string(),
                description: "Download a mission shared file URL to a local /tmp artifact path suitable for inspection or attachments. Use list_mission_shared_files first.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id", "url"],
                    "properties": {
                        "mission_id": {"type": "string"},
                        "url": {"type": "string", "description": "A shared_files[].url value returned by list_mission_shared_files or get_mission_events."},
                        "filename": {"type": "string", "description": "Optional output filename override."},
                        "output_dir": {"type": "string", "description": "Optional absolute directory under /tmp. Defaults to /tmp/hermes-assistant-artifacts."}
                    }
                }),
            },
            ToolDefinition {name:"list_cloud_models".into(),description:"Discover actual hosted model IDs, labels and supported parameter combinations before creating or following up a cloud mission. Grok Bot has no model selector.".into(),input_schema:json!({"type":"object","required":["provider"],"properties":{"provider":{"type":"string","enum":["chatgpt","cursor_cloud","hermes"]}}})},
            ToolDefinition { name: "list_cloud_accounts".into(), description: "Discover hosted agent accounts and effective capabilities. Unavailable connectors cannot launch; connecting never starts work.".into(), input_schema: json!({"type":"object","properties":{}}) },
            ToolDefinition { name: "get_cloud_execution".into(), description: "Read a bounded page of durable hosted turns, external identities and results. Defaults to the latest turn and 4096 characters per result/detail; prompts are omitted. Pass offset=0 to read from the beginning. Follow page.next_offset for subsequent turns. To continue text, select that turn with offset and limit=1, then pass its text_slices field's next_offset as text_offset. Character offsets are Unicode scalar values. Poll the last unfinished turn again until terminal; revision changes as execution advances. Artifact/branch payloads are omitted; counts are included. Transport loss is not completion.".into(), input_schema: json!({"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":5},"text_offset":{"type":"integer","minimum":0},"text_limit":{"type":"integer","minimum":1,"maximum":8192},"include_prompt":{"type":"boolean"}}}) },
            ToolDefinition {
                name: "start_mission".to_string(),
                description: "Start a new attempt on a work item. Pass project+track (the durable item) together with a stable idempotency_key; the server atomically declares/revises the track, reserves its owner lease, links the mission, and supersedes the previous owner. Retrying the same logical dispatch MUST reuse the key. Missions are attempts, not the work itself — use get_project_tasks for the declared roadmap and its separate unplanned_attempts. Set backend explicitly when possible. For Codex GPT-5.6/5.5/5.4, set fast_mode=true to request the native fast service tier; this consumes ChatGPT credits faster. To consult another model (review, second opinion, very hard read-only question), use consult_model instead: it creates the read-only opencode child (same project and machine, writer=false) and resolves short model aliases. For compatibility, a native agent name (codex/claudecode/antigravity/grok) selects the matching backend when backend is omitted; ordinary library agent names do not. Pass project/track/intent/github_pr/tags so the mission carries structured metadata (so watchdogs/dashboards don't have to parse the title). Reviewers and certifiers must use writer=false: the server tags them pr-readonly and blocks git/gh mutations. Any PR-changing mission must use writer=true; the API rejects concurrent writers for the same PR and automatically runs writers in persistent /goal mode so a normal one-turn model stop cannot masquerade as completion. Codex native /goal objectives are limited to 4000 Unicode characters, including automatically promoted writer prompts; provide a bounded objective and put supporting detail in referenced artifacts. Oversized objectives are rejected before dispatch and are never truncated.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["title", "prompt"],
                    "properties": {
                        "title": {"type": "string"},
                        "prompt": {"type": "string", "description": "Codex native /goal objective: maximum 4000 Unicode characters, including automatic writer promotion. Put supporting detail in referenced artifacts; never rely on truncation."},
                        "cloud": {"type":"object","description":"Hosted execution. Discover availability with list_cloud_accounts. Requires idempotency_key; never pass credentials, machine paths or attachments.","required":["provider","account"],"properties":{"provider":{"type":"string","enum":["chatgpt","grok_bot","cursor_cloud","hermes"]},"account":{"type":"string"},"repository":{"type":"string"},"git_ref":{"type":"string"},"model":{"type":"string"},"model_params":{"type":"array","items":{"type":"object","required":["id","value"],"properties":{"id":{"type":"string"},"value":{"type":"string"}}}}},"additionalProperties":false},
                        "workspace_id": {"type": "string"},
                        "backend": {"type": "string", "enum": ["opencode", "claudecode", "codex", "grok", "antigravity", "vibe"]},
                        "model_override": {"type": "string", "description": "Exact account-supported model ID. For opencode use <provider>/<model> (e.g. openai/gpt-6-astra). For Codex Terra use gpt-5.6-terra with medium effort. Never invent variants such as gpt-5.5-sol. Codex on a remote node (remote_node_id, e.g. auto-managed:default / auto-managed:large) runs through the core proxy: pass model_override explicitly (e.g. gpt-6.1-sol); if omitted, the configured Codex default is used and recorded on the mission."},
                        "model_effort": {"type": "string", "enum": ["low", "medium", "high", "xhigh", "max"]},
                        "fast_mode": {"type": "boolean", "description": "Enable Codex fast mode (service tier fast). Requires backend=codex and an explicit GPT-5.6, GPT-5.5, or GPT-5.4 model_override. Uses ChatGPT credits faster."},
                        "config_profile": {"type": "string"},
                        "agent": {"type": "string"},
                        "project": {"type": "string", "description": "Stable project id (e.g. \"verity\")."},
                        "track": {"type": "string", "description": "Track/workstream (e.g. \"core-c3\")."},
                        "intent": {"type": "string", "description": "Intent (e.g. \"review_merge_pr\")."},
                        "github_pr": {"type": "string", "description": "Associated PR ref (e.g. \"owner/repo#123\")."},
                        "writer": {"type": "boolean", "description": "Capability boundary for the associated PR. Use false for every reviewer/certifier (server-enforced read-only git/gh); use true for any branch, comment, thread, approval, or merge mutation. Concurrent writers for one PR are rejected."},
                        "request_merge_authority": {"type": "boolean", "description": "Request final guarded merge capability for a dedicated integrator. This is not self-authorization: the trusted Hermes client grants it only when github_pr matches the operator-configured repository allowlist."},
                        "tags": {"type": "array", "items": {"type": "string"}},
                        "desired_state": {"type": "string", "description": "Track state, e.g. waiting_ci / waiting_review / blocked_external."},
                        "acceptance_criteria": {"type": "array", "items": {"type": "string"}, "description": "Outcome contract used when this dispatch declares the track. Existing satisfied tracks are never reopened implicitly."},
                        "idempotency_key": {"type": "string", "description": "Stable retry key for one logical dispatch. Reusing it returns the existing mission receipt instead of starting a duplicate."},
                        "supersedes_mission_id": {"type": "string", "description": "The failed/interrupted attempt this mission relays (same project). It is tagged superseded_by and acknowledged, so the board stops flagging it. Use this on every handoff/relay instead of a separate acknowledge_mission call."},
                        "next_check_at": {"type": "string", "description": "When the track should next be checked (RFC3339)."},
                        "estimated_disk_gib": {"type": "integer", "minimum": 1, "maximum": 512, "description": "Expected peak local scratch use. Set this for Lean/build-heavy missions; omit for small/no-build work."},
                        "origin_session_id": {"type": "string", "description": "Implementation routing hint (Hermes session id). Injected by the Hermes plugin when present. Controllers should pass project/track instead; completion is a mission row, not a chat callback. Never invent another session's id."},
                        "attachments": {
                            "type": "array",
                            "description": "Ordinary files to materialize under .paloma/ before the harness starts. Not vendor-CLI @ syntax.",
                            "items": {
                                "type": "object",
                                "required": ["kind"],
                                "properties": {
                                    "kind": {"type": "string", "enum": ["file", "folder", "controller"]},
                                    "path": {"type": "string", "description": "Project-relative path for file/folder chips."}
                                }
                            }
                        }
                    }
                }),
            },
            ToolDefinition {
                name: "consult_model".to_string(),
                description: "Ask another model a question (review, second opinion, very hard read-only question) without hand-building a mission. Creates a child mission in the caller's project, on the caller's machine and workspace, with backend=opencode, model_override=<provider>/<model> and writer=false (pr-readonly) unless read_only=false. `model` is a full <provider>/<model> id or a short alias (gpt-6-astra, fable-5.1, opus-5.5); unknown or ambiguous names are rejected with the valid ids. It returns {mission_id} at once and never waits: poll get_consult_result(mission_id) until it returns the answer.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["model", "question"],
                    "properties": {
                        "model": {"type": "string", "description": "<provider>/<model> (e.g. openai/gpt-6-astra) or a short alias (gpt-6-astra, fable-5.1, opus-5.5)."},
                        "question": {"type": "string", "description": "The question, with all context the consultant needs."},
                        "files": {"type": "array", "items": {"type": "string"}, "description": "Paths (in the shared workspace) the consultant must read."},
                        "read_only": {"type": "boolean", "description": "Default true (writer=false, pr-readonly). false lets the consultant write."},
                        "title": {"type": "string"},
                        "project": {"type": "string", "description": "Defaults to the calling mission's project."},
                        "github_pr": {"type": "string", "description": "PR under review (owner/repo#123), if any."},
                        "origin_session_id": {"type": "string", "description": "Injected by the Hermes plugin when present; never invent one."}
                    }
                }),
            },
            ToolDefinition {
                name: "get_consult_result".to_string(),
                description: "Read the outcome of a consult_model mission without waiting: {status, done} while it runs, plus the consultant's final answer once it is no longer pending/active. Poll it (e.g. every minute) instead of blocking.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id"],
                    "properties": {"mission_id": {"type": "string"}}
                }),
            },
            ToolDefinition {
                name: "send_message_to_mission".to_string(),
                description: "Send a follow-up message to an existing mission, waking it if it is idle. This is the general way to restart a parked mission and KEEP THE SAME mission id: it activates pending, awaiting_user, acknowledged, waiting_background, interrupted, blocked, completed and failed missions alike. If the mission is already running the message is delivered to the live turn. There is no idle status that requires starting a new mission just to get the agent's attention. For existing work with excluded/collaborating PR references, read get_mission and pass continue_identity with the exact stored project, track and github_pr (null if unset). For different work use explicit github_pr/track identity updates instead; ownership checks still apply.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id", "content"],
                    "properties": {
                        "cloud_model":{"type":"string","description":"Model for this cloud turn only. Discover supported models before selecting."},
                        "cloud_model_params":{"type":"array","items":{"type":"object","required":["id","value"],"properties":{"id":{"type":"string"},"value":{"type":"string"}}}},
                        "client_message_id": {"type":"string","format":"uuid","description":"Required stable UUID for cloud follow-ups. Reuse on retries."},
                        "continue_identity": dispatch_identity_schema(),
                        "github_pr": {"type": "string", "description": "Explicit retask identity update; empty string clears. Omit to preserve."},
                        "track": {"type": "string", "description": "Explicit retask identity update; empty string clears. Omit to preserve."},
                        "title": {"type": "string", "description": "Explicit identity title update. Cannot accompany continue_identity."},
                        "mission_id": {"type": "string"},
                        "content": {"type": "string"}
                    }
                }),
            },
            ToolDefinition {
                name: "ask_mission".to_string(),
                description: "Ask a read-only question to a mission's Ask copilot (a sidecar with bash + workspace access) WITHOUT disturbing the mission or waking its main agent. Use this to inspect a mission's workspace/state or get analysis. Returns the copilot's answer and a thread_id; pass thread_id back to continue the same conversation. This does NOT send a message to the mission agent — use send_message_to_mission for that.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id", "content"],
                    "properties": {
                        "mission_id": {"type": "string"},
                        "content": {"type": "string", "description": "The question for the copilot."},
                        "thread_id": {"type": "string", "description": "Optional: continue an existing Ask thread."},
                        "sandbox": {"type": "boolean", "description": "Optional: isolate bash writes in a throwaway copy of the workspace (default false)."}
                    }
                }),
            },
            ToolDefinition {
                name: "answer_mission_question".to_string(),
                description: "Answer a mission's pending AskUserQuestion so its blocked turn resumes immediately. A mission parked on a question cannot be unblocked with send_message_to_mission — plain messages QUEUE BEHIND the blocked turn — so this is the way a controller answers instead of leaving the mission in awaiting_user. `answers` is an array of arrays: one inner array per question, each entry an option label (preferred) or free text. Omit tool_call_id to auto-target the mission's single unanswered question; if several are pending you get an error listing them.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id", "answers"],
                    "properties": {
                        "mission_id": {"type": "string", "description": "Mission UUID or an unambiguous leading fragment."},
                        "tool_call_id": {"type": "string", "description": "Optional: the AskUserQuestion tool_call id to answer. Omit to use the newest unanswered one."},
                        "answers": {"type": "array", "items": {"type": "array", "items": {"type": "string"}}, "description": "One inner array per question, e.g. [[\"Option A\"]]."}
                    }
                }),
            },
            ToolDefinition {
                name: "cancel_mission".to_string(),
                description: "Request cancellation of a running or pending mission. Acceptance is not proof of termination. Follow the receipt's next_tool: get_cloud_execution for provider confirmation, or get_mission_health for native runner termination.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id"],
                    "properties": {"mission_id": {"type": "string", "description": "Mission UUID, or an unambiguous leading fragment of one (the 8-character form dashboards and logs display)."}}
                }),
            },
            ToolDefinition {
                name: "acknowledge_mission".to_string(),
                description: "Acknowledge a mission only after independently verifying its terminal result. This is the safe host-authenticated replacement for asking a workspace container to use the service JWT. It accepts awaiting_user missions whose awaiting_kind is ack, and failed/interrupted missions once you have relayed or abandoned their work (prefer start_mission with supersedes_mission_id for a relay); decision waits and live missions are refused.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id"],
                    "properties": {"mission_id": {"type": "string", "description": "Mission UUID, or an unambiguous leading fragment of one (the 8-character form dashboards and logs display)."}}
                }),
            },
            ToolDefinition {
                name: "adopt_mission".to_string(),
                description: "Re-point a mission's origin to THIS conversation so its completion callback lands here. Use when you are waiting on a mission that was dispatched from another session (or with no origin): without adoption, its terminal webhook pins into the conversation that started it — or nowhere — and this conversation is never woken. After adopting, do not poll: the mission-complete callback will arrive as a delivery in this conversation.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id"],
                    "properties": {"mission_id": {"type": "string", "description": "Mission UUID, or an unambiguous leading fragment of one (the 8-character form dashboards and logs display)."}}
                }),
            },
            ToolDefinition {
                name: "get_compute_fleet".to_string(),
                description: "Get a compact live view of sandboxed.sh compute capacity: remote node health, labels, Lean readiness/toolchains, available slots, active/queued jobs, and recent placement receipts. Use this before dispatching parallel compute or choosing a remote validation node. Ordinary CPU/Lean work should prefer non-GPU nodes while they have immediate capacity; request the gpu label only for GPU work.".to_string(),
                input_schema: json!({"type": "object", "properties": {}}),
            },
            ToolDefinition {
                name: "list_projects".to_string(),
                description: "List the projects you supervise (the authoritative roster): slug, status, mode (active/blocked/paused), how many consecutive ticks in that mode, and the next action. Read this at the start of a tick instead of scanning tracker files.".to_string(),
                input_schema: json!({"type": "object", "properties": {}}),
            },
            ToolDefinition {
                name: "get_project".to_string(),
                description: "Get one project's compact snapshot: slug, mode, next_action, blocker, grant, pending operator steers, open decisions, bound conversation, and the highest-priority items (live / awaiting / recent unabsorbed attempts). `items` are the durable work — do not treat the mission list as the inventory. Pending steers outrank “nothing to do”. The snapshot is capped (see items_omitted / item_counts); call list_missions with a track filter for one item. Prefer this over an unfiltered list_missions and over markdown trackers.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug"],
                    "properties": {"slug": {"type": "string", "description": "Project slug, e.g. 'verity' or 'coldcard-rng-cracker'."}}
                }),
            },
            ToolDefinition {
                name: "get_situation".to_string(),
                description: "One bounded read of a project's plan: `summary` (total, verified_satisfied, claim_only, open, blocked, live_attempts, source_unavailable, cursor), `steers` (pending operator orders for this tick, plus last consumed), and every track with its derived_state (ready | executing | waiting | blocked | satisfied | claim_only | cancelled), origin (declared | absorbed), owner attempt, and title. Read pending steers first — they outrank “nothing to do” / [SILENT]. This is the only progress number to quote; do not recount items yourself. `claim_only` tracks were marked done without evidence — never report them as verified. An unchanged `cursor` since your last tick means nothing moved. Steers are not standing authority; the grant still wins.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug"],
                    "properties": {"slug": {"type": "string", "description": "Project slug or alias."}}
                }),
            },
            ToolDefinition {
                name: "update_project_status".to_string(),
                description: "Report your project's state for this tick: mode (active | blocked | paused), the next action, and the blocker if any. Replaces the [CTRL:] trailer with a structured write; the store counts how long you have been in this mode, so blocked/paused staleness is visible without parsing your reports.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug", "mode"],
                    "properties": {
                        "slug": {"type": "string"},
                        "mode": {"type": "string", "enum": ["active", "blocked", "paused"]},
                        "next_action": {"type": "string", "description": "The next concrete step, or the resume/unblock condition."},
                        "blocker": {"type": "string", "description": "What you are blocked on. Set only when mode=blocked."},
                        "consumed_steer_ids": {"type": "array", "items": {"type": "string"}, "description": "IDs from steers.pending that this tick actually read and handled. Omit to leave all pending."}
                    }
                }),
            },
            ToolDefinition {
                name: "set_project_track".to_string(),
                description: "Declare or update one workstream using the validated lifecycle. This cannot mark a track satisfied without accepted criterion evidence and cannot reopen a satisfied track; use accept_project_track_evidence or reopen_project_track for those transitions.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug", "track"],
                    "properties": {
                        "slug": {"type": "string"},
                        "track": {"type": "string"},
                        "desired_state": {"type": "string"},
                        "status": {"type": "string", "enum": ["planned", "ready", "executing", "waiting", "blocked", "satisfied", "cancelled"]}
                    }
                }),
            },
            ToolDefinition {
                name: "accept_project_track_evidence".to_string(),
                description: "Accept immutable evidence for one track criterion. The server derives satisfaction only when every current criterion has accepted evidence at the governed artifact version; a mission self-report alone is not evidence.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug", "track", "verifier_class", "evidence_ref", "artifact_version"],
                    "properties": {
                        "slug": {"type": "string"},
                        "track": {"type": "string"},
                        "criterion": {"type": "string", "description": "Exact acceptance criterion. May be omitted for a zero- or one-criterion track."},
                        "verifier_class": {"type": "string", "enum": ["external_state", "command", "review", "operator", "manual"]},
                        "evidence_ref": {"type": "string", "description": "Immutable receipt/URL/commit/job/review reference."},
                        "artifact_version": {"type": "string", "description": "Immutable governed version, normally a full commit SHA."},
                        "observed_at": {"type": "string"}
                    }
                }),
            },
            ToolDefinition {
                name: "reopen_project_track".to_string(),
                description: "Explicitly reopen a satisfied or cancelled track. Requires a reason, records the authenticated actor, increments the contract revision, and prevents old evidence from satisfying the new revision.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug", "track", "reason"],
                    "properties": {
                        "slug": {"type": "string"},
                        "track": {"type": "string"},
                        "reason": {"type": "string"},
                        "governed_artifact_version": {"type": "string"}
                    }
                }),
            },
            ToolDefinition {
                name: "accept_project_track".to_string(),
                description: "Satisfy a track with evidence — the ONLY way a track becomes satisfied (set_project_track rejects done/closed). Pass one evidence entry per declared acceptance criterion (criterion_id = the criterion text or c1, c2, …; omit when the track declares none). Each entry names an immutable handle: kind pr_merged | pr_head_review | review with subject_id 'owner/repo#233@<head sha>', or command / external_state / operator / manual with a job id, commit, or named decision. Head-bound evidence is invalidated automatically when the PR head moves. Use a stable idempotency_key per acceptance (retry-safe); pass expected_revision from get_situation to detect concurrent edits (409 on mismatch).".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug", "track", "idempotency_key", "evidence"],
                    "properties": {
                        "slug": {"type": "string"},
                        "track": {"type": "string"},
                        "idempotency_key": {"type": "string"},
                        "expected_revision": {"type": "integer"},
                        "evidence": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "required": ["kind", "subject_id"],
                                "properties": {
                                    "criterion_id": {"type": "string"},
                                    "kind": {"type": "string", "enum": ["pr_merged", "pr_head_review", "review", "command", "external_state", "operator", "manual"]},
                                    "subject_id": {"type": "string", "description": "Immutable handle, e.g. 'lfglabs-dev/verity#233@20494801f6e2'."},
                                    "verifier": {"type": "string", "description": "Who or what verified it (reviewer, check name, mission id)."},
                                    "payload": {"type": "object"}
                                }
                            }
                        }
                    }
                }),
            },
            ToolDefinition {
                name: "invalidate_project_track_evidence".to_string(),
                description: "Withdraw one piece of evidence on a track (receipt_id from get_situation / the track's receipts) with a reason. Appends an invalidate receipt; the track reopens if no other evidence stands. Use when a certification turned out wrong or the governed artifact changed in a way the watcher cannot see.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug", "track", "receipt_id", "reason"],
                    "properties": {
                        "slug": {"type": "string"},
                        "track": {"type": "string"},
                        "receipt_id": {"type": "string"},
                        "reason": {"type": "string"}
                    }
                }),
            },
            ToolDefinition {
                name: "get_project_grant".to_string(),
                description: "Read your project's autonomy grant: merge authority (full | repo:… | review-first), budget per tick, parallel missions, and the structured PAUSED(pause_reason; resume_condition). This is the durable source of what you are authorized to do — it survives prompt rewrites. Read it at your first tick.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug"],
                    "properties": {"slug": {"type": "string"}}
                }),
            },
            ToolDefinition {
                name: "set_project_grant".to_string(),
                description: "Record the owner's autonomy grant for a project after they answer the setup questions: the normalized autonomy level, merge authority, budget, parallel missions, pause reason + machine-checkable resume condition, and the material-report bar. The project must already exist.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug"],
                    "properties": {
                        "slug": {"type": "string"},
                        "autonomy_level": {"type": "string", "enum": ["observe", "propose", "act_reversible", "act_full"], "description": "What the controller may do without asking: observe (report only), propose (escalate every act), act_reversible (act, but irreversible kinds — merge/abandon/delete/publish/deploy/force_push — still escalate), act_full."},
                        "merge_authority": {"type": "string", "description": "full | repo:a,b | review-first"},
                        "budget_per_tick": {"type": "string"},
                        "parallel_missions": {"type": "integer"},
                        "pause_reason": {"type": "string"},
                        "resume_condition": {"type": "string", "description": "A condition you can check yourself, e.g. 'FTDI device enumerates on spark-de79'."},
                        "material_bar": {"type": "string"}
                    }
                }),
            },
            ToolDefinition {
                name: "add_project_steer".to_string(),
                description: "Queue a one-off operator order for the project's next controller tick. Pending steers appear on get_situation / get_project and outrank “nothing to do”; acknowledge only handled IDs using update_project_status.consumed_steer_ids. This is not a grant — standing authority still uses set_project_grant.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug", "body"],
                    "properties": {
                        "slug": {"type": "string"},
                        "body": {"type": "string", "description": "What the next tick must acknowledge and act on."}
                    }
                }),
            },
            ToolDefinition {
                name: "record_project_decision".to_string(),
                description: "Write to the project's decision ledger. Two uses: (1) declare an autonomous act BEFORE doing it (authority=granted, status=decided, kind, evidence with pr_url/mission_id) — if the response says coerced=true your grant does not cover it, treat it as an escalation and do NOT execute; (2) ask the owner a question (authority=escalation or just omit the new fields — the legacy shape still means 'ask'). Non-blocking either way.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug", "question"],
                    "properties": {
                        "slug": {"type": "string"},
                        "question": {"type": "string", "description": "The question for the owner, or the past-tense statement of the act ('Merged verity#2213')."},
                        "rationale": {"type": "string"},
                        "kind": {"type": "string", "description": "merge | dispatch | abandon | pause | resume | scope | budget | retry | ..."},
                        "authority": {"type": "string", "enum": ["granted", "escalation"]},
                        "status": {"type": "string", "enum": ["decided", "pending_user"]},
                        "evidence": {"type": "object", "description": "Supporting links, e.g. {\"pr_url\": ..., \"mission_id\": ...}."}
                    }
                }),
            },
            ToolDefinition {
                name: "answer_project_decision".to_string(),
                description: "Resolve a pending owner escalation in a project's decision ledger with the owner's answer. Use only when relaying a decision the owner actually expressed.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug", "at", "answer"],
                    "properties": {
                        "slug": {"type": "string"},
                        "at": {"type": "string", "description": "The decision's 'at' timestamp key from get_project/record_project_decision."},
                        "answer": {"type": "string"}
                    }
                }),
            },
            ToolDefinition {
                name: "get_project_tasks".to_string(),
                description: "The project's roadmap: every board task planned under the project's boss missions, with status, dependencies, result digest, PR link, and worker mission. Read this to see what is done/running/failed across the whole project without walking individual mission boards.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug"],
                    "properties": {"slug": {"type": "string"}}
                }),
            },
            ToolDefinition {
                name: "plan_project_tasks".to_string(),
                description: "Declare or revise project tracks. These rows are the only roadmap denominator. Re-planning preserves terminal lifecycle and current evidence; use explicit reopen for terminal work. Set position when the operator declares an exact sequence.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug", "tasks"],
                    "properties": {
                        "slug": {"type": "string"},
                        "tasks": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "required": ["task_key", "title"],
                                "properties": {
                                    "task_key": {"type": "string", "description": "Stable kebab-case key, unique within the project."},
                                    "title": {"type": "string"},
                                    "prompt": {"type": "string", "description": "What a worker should actually do, if known."},
                                    "acceptance_criteria": {"type": "array", "items": {"type": "string"}},
                                    "depends_on": {"type": "array", "items": {"type": "string"}},
                                    "position": {"type": "integer", "minimum": 0, "description": "Optional zero-based declarative order. Omission preserves an existing position or appends a new track."}
                                }
                            }
                        }
                    }
                }),
            },
            ToolDefinition {
                name: "update_project_task".to_string(),
                description: "Edit an open roadmap proposal (title, prompt, acceptance criteria, dependencies). Only proposals are editable — once a boss mission plans the key as a real board task, edits flow through that mission.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug", "task_key"],
                    "properties": {
                        "slug": {"type": "string"},
                        "task_key": {"type": "string"},
                        "title": {"type": "string"},
                        "prompt": {"type": "string"},
                        "acceptance_criteria": {"type": "array", "items": {"type": "string"}},
                        "depends_on": {"type": "array", "items": {"type": "string"}}
                    }
                }),
            },
            ToolDefinition {
                name: "cancel_project_task".to_string(),
                description: "Cancel an open roadmap proposal. Board tasks already adopted by a boss mission are not touched — cancel those through the mission's own board.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["slug", "task_key"],
                    "properties": {
                        "slug": {"type": "string"},
                        "task_key": {"type": "string"}
                    }
                }),
            },
            ToolDefinition {
                name: "link_mission_to_project".to_string(),
                description: "Tag a mission as belonging to your project (and optionally a track), so it appears in the project's inventory. Optional writer=false persists read-only capability, including when no PR is attached; writer=true requests writer capability through the existing ownership checks. Capability or assignment changes require stopped, drained work; Pending work must be cancelled first and resumed on the same mission after the update.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id", "slug"],
                    "properties": {
                        "mission_id": {"type": "string", "description": "Mission UUID or an unambiguous leading fragment."},
                        "slug": {"type": "string"},
                        "track": {"type": "string"},
                        "writer": {"type": "boolean", "description": "Explicit capability update. False persists read-only; true requests writer ownership. Omit to preserve existing behavior."}
                    }
                }),
            },
            ToolDefinition {
                name: "list_workspaces".to_string(),
                description: "List sandboxed.sh workspaces so new missions can target the right environment.".to_string(),
                input_schema: json!({"type": "object", "properties": {}}),
            },
            ToolDefinition {
                name: "get_workspace".to_string(),
                description: "Get the complete configuration and current build status of one sandboxed.sh workspace.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["workspace_id"],
                    "properties": {"workspace_id": {"type": "string", "description": "Workspace UUID."}}
                }),
            },
            ToolDefinition {
                name: "create_workspace".to_string(),
                description: "Create a sandboxed.sh workspace. A template always creates an isolated container and starts its build automatically; a host workspace requires a path inside the server working directory.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["name"],
                    "properties": {
                        "name": {"type": "string"},
                        "workspace_type": {"type": "string", "enum": ["host", "container"], "description": "Defaults to host unless template is set."},
                        "path": {"type": "string", "description": "Required for host workspaces; omit for the standard container path."},
                        "skills": {"type": "array", "items": {"type": "string"}},
                        "plugins": {"type": "array", "items": {"type": "string"}},
                        "template": {"type": "string", "description": "Workspace template name. Forces container type and starts a build."},
                        "distro": {"type": "string"},
                        "env_vars": {"type": "object", "additionalProperties": {"type": "string"}},
                        "init_script": {"type": "string"},
                        "shared_network": {"type": "boolean"},
                        "tailscale_mode": {"type": "string", "enum": ["exit_node", "tailnet_only"]},
                        "mcps": {"type": "array", "items": {"type": "string"}},
                        "mcps_replace_defaults": {"type": "boolean"},
                        "config_profile": {"type": "string"}
                    }
                }),
            },
            ToolDefinition {
                name: "update_workspace".to_string(),
                description: "Update only the supplied fields of an existing workspace. Setting template changes the association but does not reapply template contents; use rebuild_workspace_from_template for that.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["workspace_id"],
                    "properties": {
                        "workspace_id": {"type": "string"},
                        "name": {"type": "string"},
                        "skills": {"type": "array", "items": {"type": "string"}},
                        "plugins": {"type": "array", "items": {"type": "string"}},
                        "template": {"type": "string", "description": "Empty string clears the association."},
                        "distro": {"type": "string", "description": "Empty string clears the override."},
                        "env_vars": {"type": "object", "additionalProperties": {"type": "string"}, "description": "Replaces the workspace env map."},
                        "init_script": {"type": "string"},
                        "init_scripts": {"type": "array", "items": {"type": "string"}},
                        "shared_network": {"type": "boolean"},
                        "tailscale_mode": {"type": "string", "enum": ["exit_node", "tailnet_only"]},
                        "mcps": {"type": "array", "items": {"type": "string"}},
                        "mcps_replace_defaults": {"type": "boolean"},
                        "config_profile": {"type": "string", "description": "Empty string clears the profile."},
                        "config": {"type": "object", "description": "Shallow-merged into freeform workspace config."}
                    }
                }),
            },
            ToolDefinition {
                name: "delete_workspace".to_string(),
                description: "Delete a sandboxed.sh workspace and its managed container data. Requires confirm=true; active missions that reference it are not deleted.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["workspace_id", "confirm"],
                    "properties": {
                        "workspace_id": {"type": "string"},
                        "confirm": {"type": "boolean", "description": "Must be true to perform deletion."}
                    }
                }),
            },
            ToolDefinition {
                name: "list_workspace_templates".to_string(),
                description: "List reusable sandboxed.sh workspace templates from the Library.".to_string(),
                input_schema: json!({"type": "object", "properties": {}}),
            },
            ToolDefinition {
                name: "get_workspace_template".to_string(),
                description: "Get a reusable workspace template. Sensitive values are redacted from the tool result.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["name"],
                    "properties": {"name": {"type": "string"}}
                }),
            },
            ToolDefinition {
                name: "save_workspace_template".to_string(),
                description: "Create or update a reusable workspace template. Existing templates are patch-updated: omitted fields are preserved, while supplied arrays/maps replace that field.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["name"],
                    "properties": {
                        "name": {"type": "string"},
                        "description": {"type": "string"},
                        "distro": {"type": "string"},
                        "skills": {"type": "array", "items": {"type": "string"}},
                        "env_vars": {"type": "object", "additionalProperties": {"type": "string"}},
                        "encrypted_keys": {"type": "array", "items": {"type": "string"}, "description": "Env var keys to encrypt at rest."},
                        "init_scripts": {"type": "array", "items": {"type": "string"}},
                        "init_script": {"type": "string"},
                        "shared_network": {"type": "boolean"},
                        "tailscale_mode": {"type": "string", "enum": ["exit_node", "tailnet_only"]},
                        "mcps": {"type": "array", "items": {"type": "string"}},
                        "mcps_replace_defaults": {"type": "boolean"},
                        "config_profile": {"type": "string"}
                    }
                }),
            },
            ToolDefinition {
                name: "delete_workspace_template".to_string(),
                description: "Delete a reusable workspace template. Requires confirm=true and does not delete workspaces already created from it.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["name", "confirm"],
                    "properties": {
                        "name": {"type": "string"},
                        "confirm": {"type": "boolean", "description": "Must be true to perform deletion."}
                    }
                }),
            },
            ToolDefinition {
                name: "rebuild_workspace_from_template".to_string(),
                description: "Reapply the latest template definition to an existing container workspace, replacing template-controlled fields, then force-rebuild its container. Requires confirm=true because container state may be replaced.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["workspace_id", "confirm"],
                    "properties": {
                        "workspace_id": {"type": "string"},
                        "template": {"type": "string", "description": "Optional template name; defaults to the workspace's current template."},
                        "confirm": {"type": "boolean", "description": "Must be true to force rebuild."}
                    }
                }),
            },
            ToolDefinition {
                name: "workspace_bash".to_string(),
                description: "Run a command inside a sandboxed.sh workspace. For builds or any work that must survive this call, supply both mission_id and idempotency_key: returns a durable job id immediately, with no polling. Without those fields, runs a bounded diagnostic (default 60 seconds, maximum 120) and kills it at timeout. Command text is never used to guess execution mode.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["command"],
                    "properties": {
                        "command": {"type": "string", "description": "Shell command to run in the workspace."},
                        "workspace_id": {"type": "string", "description": "Workspace UUID. Defaults to the assistant's default workspace."},
                        "cwd": {"type": "string", "description": "Working directory relative to the workspace root."},
                        "timeout_secs": {"type": "integer", "description": "Runtime limit: diagnostic default 60/max 120; durable default 7200/max 86400."},
                        "mission_id": {"type": "string", "description": "Owning mission UUID; supply together with idempotency_key for durable execution."},
                        "idempotency_key": {"type": "string", "description": "Stable retry key for durable execution; requires mission_id. Reuse after a lost response."}
                    }
                }),
            },
            ToolDefinition {
                name: "start_workspace_job".to_string(),
                description: "Start a restart-safe long-running command in a workspace and return immediately with a durable job id. Supply exactly one of command or argv. Retries must reuse the same idempotency_key; a reused key cannot submit duplicate work.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id", "idempotency_key"],
                    "properties": {
                        "command": {"type": "string", "description": "Shell command. Mutually exclusive with argv."},
                        "argv": {"type": "array", "items": {"type": "string"}, "description": "Argument vector, safely shell-quoted. Mutually exclusive with command."},
                        "workspace_id": {"type": "string", "description": "Workspace UUID. Defaults to the assistant default workspace."},
                        "mission_id": {"type": "string", "description": "Owning mission UUID."},
                        "cwd": {"type": "string", "description": "Working directory relative to the workspace root."},
                        "timeout_secs": {"type": "integer", "description": "Absolute runtime limit. Default 7200 seconds, maximum 86400."},
                        "resource_class": {"type": "string", "description": "Scheduling hint such as lean_heavy, cpu, or io."},
                        "idempotency_key": {"type": "string", "description": "Stable retry key for this logical submission."}
                    }
                }),
            },
            ToolDefinition {
                name: "get_workspace_job".to_string(),
                description: "Inspect a durable workspace job by id, including heartbeat, deadline, scope, exit status, and bounded stdout/stderr tails.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["job_id"],
                    "properties": {
                        "job_id": {"type": "string"},
                        "tail_bytes": {"type": "integer", "description": "Maximum bytes from each log, default 16384, maximum 65536."}
                    }
                }),
            },
            ToolDefinition {
                name: "cancel_workspace_job".to_string(),
                description: "Idempotently request cancellation of a durable workspace job. Returns after cancellation is recorded; process teardown continues asynchronously.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["job_id"],
                    "properties": {"job_id": {"type": "string"}}
                }),
            },
            ToolDefinition {
                name: "get_mission_health".to_string(),
                description: "Diagnose where a mission stands: live run state, stall severity, detected error signals (rate limit / auth / capacity / context-limit / network), suspected tool loops, the last assistant message, and a one-line recommendation. Use this first when babysitting a long-running mission — it summarizes 'where it is struggling' instead of making you read raw events. Includes goal_mode separately from mission_mode and a goal_objective preview of at most 1,000 characters plus a truncation ellipsis.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id"],
                    "properties": {"mission_id": {"type": "string", "description": "Mission UUID, or an unambiguous leading fragment of one (the 8-character form dashboards and logs display)."}}
                }),
            },
            ToolDefinition {
                name: "get_mission_diagnostics".to_string(),
                description: "Deep-dive a mission: recent tool calls, deduplicated result snippets, per-tool counts, repeated calls, and bounded error summaries. Use get_mission_events for raw receipts. Use when get_mission_health flags a problem and you need to see exactly what the model is doing.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id"],
                    "properties": {
                        "mission_id": {"type": "string"},
                        "limit": {"type": "integer", "description": "Trace events to scan from the tail, default 80, max 300."}
                    }
                }),
            },
            ToolDefinition {
                name: "update_mission_settings".to_string(),
                description: "Change a mission's run settings for its NEXT turn: switch backend (claudecode/codex/opencode/antigravity/grok/vibe), model, reasoning effort, fast mode, or agent. On a failed or interrupted mission the server resumes it on the new settings automatically (resume_queued in the response) — a handoff is one call, no separate resume_mission. Applies between turns — the mission must be idle (awaiting_user/acknowledged/interrupted/failed), not actively running. If it is running, cancel_mission first (or wait), then update, then send_message_to_mission or resume_mission to kick the next turn. model_effort applies to claudecode/codex; fast_mode applies only to Codex GPT-5.6/5.5/5.4 and consumes ChatGPT credits faster.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id"],
                    "properties": {
                        "mission_id": {"type": "string"},
                        "backend": {"type": "string", "enum": ["opencode", "claudecode", "codex", "grok", "antigravity", "vibe"]},
                        "model_override": {"type": "string", "description": "Model id. Empty string clears it. When backend changes this is reset unless set explicitly."},
                        "model_effort": {"type": "string", "enum": ["low", "medium", "high", "xhigh", "max"]},
                        "fast_mode": {"type": "boolean", "description": "Enable or disable Codex fast mode for future turns. Only backend=codex with GPT-5.6/5.5/5.4."},
                        "agent": {"type": "string", "description": "Agent name. Omission preserves it on the same backend and clears it on a backend switch. Empty string clears it."},
                        "config_profile": {"type": "string"}
                    }
                }),
            },
            ToolDefinition {
                name: "resume_mission".to_string(),
                description: "Resume an interrupted, blocked or failed mission. Bound Codex missions reattach to the same native thread, cwd, HOME and account; existing native goals preserve their objective, token budget and accumulated usage. Grok resumes its recorded native session; a first handoff creates a Grok session while preserving other harness identities. For a mission parked in awaiting_user or acknowledged, send_message_to_mission wakes it on the same id and is the normal choice. Pass `content` as the exact current steering input; on a bound native goal it steers that goal's turn. A new Codex /goal objective must be at most 4000 Unicode characters; oversized objectives are rejected without truncation. Without `content`, persisted Codex goal missions resume the full stored /goal objective; other missions receive the default continue-where-you-left-off prompt. Native blocked/paused/usageLimited/budgetLimited stops park as blocked with terminal_reason=native_goal_stopped after the final response drains; they never mean goal completion. Resolve the reported stop before resuming. codex_continuity_required or native_continuity_required means native identity/history or a tool outcome requires reconciliation: do not repeat identical resumes, change accounts, or assume a fresh thread or reset budget. Queued steering retains its durable order; unconfirmed native delivery is reported explicitly. For existing work with excluded/collaborating PR references, read get_mission and pass continue_identity with the exact stored project, track and github_pr (null if unset). For different work use explicit github_pr/track identity updates instead; ownership checks still apply.".to_string(),
                input_schema: json!({
                    "type": "object",
                    "required": ["mission_id"],
                    "properties": {
                        "continue_identity": dispatch_identity_schema(),
                        "github_pr": {"type": "string", "description": "Explicit retask identity update; empty string clears. Omit to preserve."},
                        "track": {"type": "string", "description": "Explicit retask identity update; empty string clears. Omit to preserve."},
                        "title": {"type": "string", "description": "Explicit identity title update. Cannot accompany continue_identity."},
                        "mission_id": {"type": "string"},
                        "content": {"type": "string", "description": "Optional steering message used as the resume turn's prompt."},
                        "clean_workspace": {"type": "boolean", "description": "Wipe the work directory before resuming. Rarely needed; default false."}
                    }
                }),
            },
        ]
    }

    async fn list_missions(&self, params: ListMissionsParams) -> Result<Value, String> {
        let limit = params.limit.clamp(1, 100);
        // Forward filters to the API so it does the (paginated, scan-bounded)
        // matching server-side — filtering only the fetched page here would miss
        // matches outside the window on a larger fleet.
        let mut path = format!(
            "/api/control/missions?limit={limit}&offset={}",
            params.offset
        );
        if let Some(status) = params.status.as_deref() {
            path.push_str(&format!("&status={}", urlencoding::encode(status)));
        }
        if let Some(project) = params.project.as_deref() {
            path.push_str(&format!("&project={}", urlencoding::encode(project)));
        }
        if let Some(prefix) = params.project_prefix.as_deref() {
            path.push_str(&format!("&project_prefix={}", urlencoding::encode(prefix)));
        }
        if let Some(track) = params.track.as_deref() {
            path.push_str(&format!("&track={}", urlencoding::encode(track)));
        }
        if let Some(tag) = params.tag.as_deref() {
            path.push_str(&format!("&tag={}", urlencoding::encode(tag)));
        }
        if let Some(session) = params.origin_session_id.as_deref() {
            path.push_str(&format!(
                "&origin_session_id={}",
                urlencoding::encode(session)
            ));
        }
        let response = self.api_get(&path).await?;
        if !response.status().is_success() {
            return Err(format!("Failed to list missions: {}", response.status()));
        }
        let missions: Vec<Value> = response
            .json()
            .await
            .map_err(|error| format!("Failed to parse missions: {error}"))?;
        let missions = missions
            .into_iter()
            .map(compact_mission_summary)
            .collect::<Vec<_>>();
        let next_offset =
            (missions.len() == limit).then_some(params.offset.saturating_add(missions.len()));
        Ok(json!({ "missions": missions, "next_offset": next_offset }))
    }

    /// Takes the whole filter set so an active-mission query can be narrowed
    /// exactly like a full listing (by conversation, family, track, …).
    async fn list_active_missions(&self, params: ListMissionsParams) -> Result<Value, String> {
        let requested = params.limit.clamp(1, 100);
        let offset = params.offset;
        let mut result = self
            .list_missions(ListMissionsParams {
                limit: 100,
                status: None,
                ..params
            })
            .await?;
        let rows = result["missions"].as_array_mut().unwrap();
        let raw = std::mem::take(rows);
        let raw_len = raw.len();
        let mut consumed = 0usize;
        for mission in raw {
            consumed += 1;
            if matches!(
                mission["status"].as_str(),
                Some("active" | "pending" | "awaiting_user" | "blocked")
            ) {
                rows.push(mission);
                if rows.len() == requested {
                    break;
                }
            }
        }
        result["next_offset"] = if consumed < raw_len || raw_len == 100 {
            json!(offset.saturating_add(consumed))
        } else {
            Value::Null
        };
        Ok(result)
    }

    async fn get_mission(&self, params: MissionIdParams) -> Result<Value, String> {
        // Keep the legacy tool name safe for autonomous controllers. Models
        // routinely chose `get_mission` despite its former "heavy" warning,
        // pulling entire transcripts into every reconciliation tick. Detailed
        // history remains available through the bounded/paginated events tool.
        self.get_mission_digest(params).await
    }

    async fn get_mission_digest(&self, params: MissionIdParams) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        let response = self
            .api_get(&format!("/api/control/missions/{id}/digest"))
            .await?;
        if !response.status().is_success() {
            return Err(format!("Mission not found: {}", response.status()));
        }
        response
            .json()
            .await
            .map_err(|error| format!("Failed to parse mission digest: {error}"))
    }

    async fn get_mission_events(&self, params: MissionEventsParams) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        let limit = params.limit.clamp(1, 200);
        // Validate against the declared enum rather than interpolating a
        // free-form string into the URL, which would let a caller smuggle
        // extra query parameters (e.g. `all&foo=bar`) into the internal request.
        let view = match params.view.as_deref() {
            None | Some("transcript") => "transcript",
            Some("trace") => "trace",
            Some("history") => "history",
            Some("all") => "all",
            Some(other) => {
                return Err(format!(
                    "Invalid view '{other}'; expected one of: transcript, trace, history, all"
                ))
            }
        };
        let path = mission_events_path(id, limit, view, params.before_seq, params.since_seq);
        let response = self.api_get(&path).await?;
        if !response.status().is_success() {
            return Err(format!(
                "Failed to fetch mission events: {}",
                response.status()
            ));
        }
        response
            .json()
            .await
            .map_err(|error| format!("Failed to parse mission events: {error}"))
    }

    async fn list_mission_shared_files(
        &self,
        params: MissionSharedFilesParams,
    ) -> Result<Value, String> {
        let mission_id = self.resolve_mission_id(&params.mission_id).await?;
        // Page backwards from the end of the transcript: shared files are
        // "current attachments", so we must scan the NEWEST `limit` events —
        // the default (no cursor) pagination returns the oldest rows and would
        // silently drop recent attachments on long missions.
        let events = self
            .get_mission_events(MissionEventsParams {
                mission_id: mission_id.to_string(),
                limit: params.limit.clamp(1, 200),
                view: Some("transcript".to_string()),
                since_seq: None,
                before_seq: Some(i64::MAX),
            })
            .await?;
        let mut files = Vec::new();
        for event in events.as_array().into_iter().flatten() {
            let Some(shared_files) = event
                .get("metadata")
                .and_then(|metadata| metadata.get("shared_files"))
                .and_then(Value::as_array)
            else {
                continue;
            };
            for file in shared_files {
                let mut item = file.clone();
                if let Some(object) = item.as_object_mut() {
                    object.insert("mission_id".to_string(), json!(mission_id.to_string()));
                    if let Some(sequence) = event.get("sequence").cloned() {
                        object.insert("event_sequence".to_string(), sequence);
                    }
                    if let Some(timestamp) = event.get("timestamp").cloned() {
                        object.insert("event_timestamp".to_string(), timestamp);
                    }
                }
                files.push(item);
            }
        }
        Ok(json!({ "mission_id": mission_id.to_string(), "shared_files": files }))
    }

    async fn download_shared_file(
        &self,
        params: DownloadSharedFileParams,
    ) -> Result<Value, String> {
        let mission_id = self.resolve_mission_id(&params.mission_id).await?;
        let path = shared_file_download_path(&params.url)?;
        let filename = params
            .filename
            .or_else(|| shared_file_name_from_url(&params.url))
            .unwrap_or_else(|| "artifact".to_string());
        let filename = sanitize_filename(&filename);
        let output_dir = output_dir_for_shared_file(&mission_id, params.output_dir)?;
        tokio::fs::create_dir_all(&output_dir)
            .await
            .map_err(|error| format!("Failed to create artifact directory: {error}"))?;
        let output_path = output_dir.join(filename);
        let bytes = self.api_get_bytes(&path).await?;
        tokio::fs::write(&output_path, &bytes)
            .await
            .map_err(|error| format!("Failed to write shared file: {error}"))?;
        Ok(json!({
            "mission_id": mission_id.to_string(),
            "path": output_path.to_string_lossy(),
            "bytes": bytes.len(),
        }))
    }

    async fn start_mission(&self, mut params: StartMissionParams) -> Result<Value, String> {
        // A scoped controller must launch work under its own project — an
        // untagged mission would escape both the roster and this scope.
        if let (Some(scope), None) = (
            &self.project_scope,
            params
                .project
                .as_deref()
                .map(str::trim)
                .filter(|p| !p.is_empty()),
        ) {
            // One allowed project is unambiguous: launch there instead of
            // refusing the call.
            if scope.len() == 1 {
                params.project = scope.iter().next().cloned();
            }
        }
        if self.project_scope.is_some() {
            match params
                .project
                .as_deref()
                .map(str::trim)
                .filter(|p| !p.is_empty())
            {
                Some(project) => self.assert_project_scope(project)?,
                None => {
                    let mut allowed: Vec<&str> = self
                        .project_scope
                        .iter()
                        .flatten()
                        .map(String::as_str)
                        .collect();
                    allowed.sort_unstable();
                    return Err(format!(
                        "scoped controllers must pass `project` on start_mission so the mission stays inside their scope: pass project=\"{}\" (allowed: {})",
                        allowed.first().copied().unwrap_or_default(),
                        allowed.join(", ")
                    ));
                }
            }
        }
        let workspace_id = if params.cloud.is_some() {
            if params.workspace_id.is_some() {
                return Err("Cloud execution does not accept a workspace: remove workspace_id, or drop `cloud` and launch natively (e.g. backend=opencode with model_override=<provider>/<model>)".into());
            }
            None
        } else {
            resolve_default_workspace_id(params.workspace_id)
        };
        let backend = params
            .backend
            .or_else(|| native_backend_from_agent(params.agent.as_deref()));
        let writer = params.writer.unwrap_or(false);
        let prompt = writer_goal_prompt(params.prompt, writer);
        if backend.as_deref() == Some("codex") {
            crate::backend::codex::validate_goal_message(&prompt)?;
        }
        // A mission's agent starting a subagent through the gateway is not the
        // Hermes assistant: attributing it to Hermes made the child look like
        // an assistant dispatch (origin=hermes, origin:hermes-assistant).
        let started_by_mission =
            params.caller.as_deref() == Some("mission") && params.parent_mission_id.is_some();
        let tags = mission_start_tags(
            if started_by_mission {
                "origin:mission"
            } else {
                "origin:hermes-assistant"
            },
            params.tags,
            params.request_merge_authority.unwrap_or(false),
            writer,
            params.github_pr.as_deref(),
            MergeGrantConfig::from_environment().as_ref(),
        )?;
        // An explicitly supplied origin session must be usable for routing:
        // silently dropping a blank/malformed id would create exactly the
        // unreachable mission this field exists to prevent. Only omitting the
        // field opts out.
        let origin_session_id = match params.origin_session_id.as_deref().map(str::trim) {
            Some(session) if valid_origin_session_id(session) => Some(session),
            Some(session) => {
                return Err(format!(
                    "origin_session_id `{session}` is invalid: use 1-128 chars of \
                     [A-Za-z0-9._:-]"
                ))
            }
            None => None,
        };
        let mut managed_machine = Value::Null;
        let mut managed_reused = false;
        let auto_managed = params
            .remote_node_id
            .as_deref()
            .and_then(parse_auto_managed_spec);
        if let Some((provider, size)) = auto_managed {
            // Validate the launch (model, harness auth, caps, budget) before
            // renting: a rejected child must never cost a VM.
            let check = self
                .api_post(
                    "/api/control/missions",
                    json!({
                        "validate_only": true,
                        "title": params.title,
                        "parent_mission_id": params.parent_mission_id,
                        "remote_node_id": params.remote_node_id,
                        "backend": backend,
                        "model_override": params.model_override,
                        "model_effort": params.model_effort,
                        "fast_mode": params.fast_mode.unwrap_or(false),
                        "prompt": prompt,
                        "project": params.project,
                        "track": params.track,
                        "idempotency_key": params.idempotency_key,
                        "github_pr": params.github_pr,
                        "writer": writer,
                        "tags": tags,
                        "budget_usd": params.budget_usd,
                        "origin": if started_by_mission { "mission" } else { "hermes" },
                        "origin_session_id": origin_session_id,
                    }),
                )
                .await?;
            let status = check.status();
            let text = check.text().await.unwrap_or_default();
            if !status.is_success() {
                return Err(format!(
                    "start_mission rejected before renting a managed VM (nothing was created or billed): {text}"
                ));
            }
            let parsed: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
            if parsed["valid"].as_bool() != Some(true) && parsed["id"].as_str().is_some() {
                // Idempotent replay of an existing mission: nothing to rent.
                return Ok(json!({ "mission": parsed }));
            }
            let spawned = self
                .spawn_managed_machine_with(
                    SpawnManagedParams {
                        provider,
                        // Mission placement requires an enrolled worker. Never inherit
                        // raw mode from a snapshot and rent an unusable machine.
                        provisioning_mode: Some(crate::managed::ProvisioningMode::Worker),
                        size,
                        cpu: None,
                        ram_gb: None,
                        gpu: None,
                        arch: None,
                        max_hourly_usd: None,
                        allow_24h_commitment: params.managed_allow_24h_commitment,
                        ttl_minutes: params.managed_ttl_minutes,
                        image: None,
                        reason: Some(format!("start_mission: {}", params.title)),
                        from_snapshot: params.managed_from_snapshot.clone(),
                        owner_mission_id: None,
                    },
                    params.parent_mission_id.map(|id| id.to_string()),
                    params.budget_usd,
                    true,
                )
                .await?;
            params.remote_node_id = spawned["node_id"].as_str().map(str::to_string);
            managed_reused = spawned["machine"]["reused"].as_bool() == Some(true);
            managed_machine = spawned["machine"].clone();
        }
        let mut body = json!({
            "title": params.title,
            "parent_mission_id": params.parent_mission_id,
            "workspace_id": workspace_id,
            "remote_node_id": params.remote_node_id,
            "backend": backend,
            "model_override": params.model_override,
            "model_effort": params.model_effort,
            "fast_mode": params.fast_mode.unwrap_or(false),
            "config_profile": params.config_profile,
            "agent": params.agent,
            // Atomic create+start: the API stores the prompt as the mission's
            // deferred goal and the scheduler dispatches it as soon as
            // capacity allows. The old create-then-send_message pattern could
            // be dropped at capacity, leaving zombie Pending missions.
            "prompt": prompt,
            // Project tagging at creation so the mission isn't born with null
            // metadata (Paloma watchdogs then route by these, not titles).
            "project": params.project,
            "track": params.track,
            "idempotency_key": params.idempotency_key,
            "supersedes_mission_id": params.supersedes_mission_id,
            "intent": params.intent,
            "github_pr": params.github_pr,
            "writer": writer,
            "tags": tags,
            "desired_state": params.desired_state,
            "acceptance_criteria": params.acceptance_criteria,
            "next_check_at": params.next_check_at,
            "estimated_disk_gib": params.estimated_disk_gib,
            // Mission-level provenance. `origin` is fixed by this server (not
            // model-controlled); the session id ties the mission to the Hermes
            // conversation that spawned it, and the mission-status webhook
            // carries it back so the result reaches that conversation.
            "origin": if started_by_mission { "mission" } else { "hermes" },
            "origin_session_id": origin_session_id,
            "attachments": params.attachments,
            // The VM rented above serves this new mission: Core makes the
            // mission its owner (the caller becomes the requester).
            "claim_managed_machine_id": managed_machine["id"].as_str(),
            "budget_usd": params.budget_usd,
        });
        if let Some(cloud) = params.cloud {
            body["cloud"] = cloud;
        }
        let created = self.api_post("/api/control/missions", body).await;
        let created = match created {
            Ok(response) if response.status().is_success() => response
                .json::<Value>()
                .await
                .map_err(|error| format!("Failed to parse created mission: {error}")),
            Ok(response) => Err(format!(
                "Failed to create mission: {}",
                response.text().await.unwrap_or_default()
            )),
            Err(error) => Err(error),
        };
        let mission = match created {
            Ok(mission) if mission["id"].as_str().is_some() => mission,
            other => {
                // Do not leave a rented VM behind for a mission that never
                // started (a reused sibling VM is released to its grace).
                if let (Some(id), false) = (managed_machine["id"].as_str(), managed_reused) {
                    let _ = self
                        .managed_request(
                            reqwest::Method::DELETE,
                            format!("/api/managed-machines/{id}?reason=launch_failed"),
                            None,
                        )
                        .await;
                }
                return Err(match other {
                    Err(e) => e,
                    Ok(_) => "Created mission response did not include an id".to_string(),
                });
            }
        };
        if managed_machine.is_null() {
            Ok(json!({ "mission": mission }))
        } else {
            Ok(json!({
                "mission": mission,
                "managed_machine": managed_machine,
                "reused_idle_machine": managed_reused,
                "note": "The subagent runs on a managed VM (reused from an ended sibling when one of the same size was idle). It belongs to the subagent: it is destroyed a few minutes after the subagent ends (or 15 idle minutes after it is interrupted or waiting), and at its TTL at the latest (default 60 min, auto-extended in 30 min chunks while busy and within budget). destroy_managed_machine releases it earlier."
            }))
        }
    }

    /// Model ids an opencode mission accepts (`provider/model` and chains).
    async fn opencode_model_options(&self) -> Result<Vec<String>, String> {
        let response = self.api_get("/api/providers/backend-models").await?;
        let catalog = Self::response_value(response, "List opencode models").await?;
        Ok(catalog["backends"]["opencode"]
            .as_array()
            .map(|options| {
                options
                    .iter()
                    .filter_map(|o| o["value"].as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default())
    }

    /// `consult_model`: a read-only opencode child built on `start_mission`.
    async fn consult_model(&self, params: ConsultModelParams) -> Result<Value, String> {
        if params.wait_secs.is_some_and(|w| w > 0) {
            return Err("consult_model never waits (a blocking wait would hold a shared dispatcher slot): drop wait_secs, then poll get_consult_result(mission_id) until it returns the answer".into());
        }
        if params.question.trim().is_empty() {
            return Err("question is required: write the full question for the consultant".into());
        }
        let model = resolve_consult_model(&params.model, &self.opencode_model_options().await?)?;
        let read_only = params.read_only.unwrap_or(true);
        let title = params
            .title
            .filter(|t| !t.trim().is_empty())
            .unwrap_or_else(|| format!("Consult {model}"));
        let started = self
            .start_mission(StartMissionParams {
                parent_mission_id: params.parent_mission_id,
                caller: params.caller,
                cloud: None,
                title,
                prompt: consult_prompt(&params.question, &params.files, read_only),
                workspace_id: params.workspace_id,
                remote_node_id: params.remote_node_id,
                managed_ttl_minutes: None,
                managed_from_snapshot: None,
                managed_allow_24h_commitment: None,
                budget_usd: None,
                backend: Some("opencode".into()),
                model_override: Some(model.clone()),
                model_effort: None,
                fast_mode: None,
                config_profile: None,
                agent: None,
                project: params.project,
                track: None,
                idempotency_key: params.idempotency_key,
                supersedes_mission_id: None,
                intent: Some("consult_model".into()),
                github_pr: params.github_pr,
                writer: Some(!read_only),
                request_merge_authority: None,
                tags: Some(vec!["consult-model".into()]),
                desired_state: None,
                acceptance_criteria: Vec::new(),
                next_check_at: None,
                estimated_disk_gib: None,
                origin_session_id: params.origin_session_id,
                attachments: None,
            })
            .await?;
        let mission_id = started["mission"]["id"]
            .as_str()
            .ok_or("Created mission response did not include an id")?
            .to_string();
        let status = started["mission"]["status"].as_str().unwrap_or("pending");
        Ok(json!({
            "mission_id": mission_id,
            "model": model,
            "status": status,
            "read_only": read_only,
            "next": format!("Poll get_consult_result(mission_id=\"{mission_id}\") until done=true; it returns the consultant's answer."),
        }))
    }

    /// Non-blocking read of a consult_model mission's answer.
    async fn get_consult_result(&self, params: MissionIdParams) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        let digest = self
            .get_mission_digest(MissionIdParams {
                mission_id: id.to_string(),
            })
            .await?;
        let status = digest["status"].as_str().unwrap_or("pending").to_string();
        let done = !mission_is_running(&status);
        let mut out = json!({"mission_id": id, "status": status, "done": done});
        if done {
            out["answer"] = json!(self.last_assistant_message_bounded(&id, 20_000).await);
        } else {
            out["next"] = json!("Still running: call get_consult_result again later.");
        }
        Ok(out)
    }

    /// Run a bash command through `POST /api/workspaces/:id/exec`, which
    /// executes in the workspace context with its configured `env_vars`
    /// merged in (host: process env; container: --setenv). This gives the
    /// assistant mission-equivalent access to workspace secrets without
    /// copying them into the gateway's own service environment.
    async fn workspace_bash(&self, params: WorkspaceBashParams) -> Result<Value, String> {
        if params.command.trim().is_empty() {
            return Err("Command is empty".to_string());
        }
        match (params.mission_id, params.idempotency_key) {
            (Some(mission_id), Some(idempotency_key)) => {
                if mission_id.trim().is_empty() || idempotency_key.trim().is_empty() {
                    return Err("mission_id and idempotency_key must both be non-empty".into());
                }
                // Reuse the durable admission API: never submit synchronously first
                // and then retry in the background, which could execute twice.
                return self.start_workspace_job(StartWorkspaceJobParams {
                    command: Some(params.command),
                    argv: None,
                    workspace_id: params.workspace_id,
                    mission_id,
                    cwd: params.cwd,
                    timeout_secs: params.timeout_secs,
                    resource_class: None,
                    idempotency_key,
                }).await;
            }
            (None, None) => {}
            _ => return Err("Supply both mission_id and idempotency_key for durable execution, or omit both for a bounded diagnostic".into()),
        }
        let workspace_id = resolve_default_workspace_id(params.workspace_id).ok_or_else(|| {
            "No workspace_id given and no default workspace configured \
             (HERMES_DEFAULT_WORKSPACE_ID / ASSISTANT_DEFAULT_WORKSPACE_ID)"
                .to_string()
        })?;
        let id = parse_uuid(&workspace_id)?;
        let response = self
            .api_post(
                &format!("/api/workspaces/{id}/exec"),
                json!({
                    "command": params.command,
                    "cwd": params.cwd,
                    "timeout_secs": params.timeout_secs.unwrap_or(60).clamp(1, 120),
                }),
            )
            .await?;
        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(format!("Workspace exec failed ({status}): {text}"));
        }
        response
            .json()
            .await
            .map_err(|error| format!("Failed to parse exec result: {error}"))
    }

    async fn start_workspace_job(&self, params: StartWorkspaceJobParams) -> Result<Value, String> {
        let workspace_id = resolve_default_workspace_id(params.workspace_id).ok_or_else(|| {
            "No workspace_id given and no default workspace configured (HERMES_DEFAULT_WORKSPACE_ID / ASSISTANT_DEFAULT_WORKSPACE_ID)".to_string()
        })?;
        let workspace_id = parse_uuid(&workspace_id)?;
        let mission_id = self.resolve_mission_id(&params.mission_id).await?;
        self.assert_mission_scope(mission_id).await?;
        let command = workspace_job_command(params.command, params.argv)?;
        let key = params.idempotency_key.trim();
        if key.is_empty() {
            return Err("idempotency_key is required".to_string());
        }
        let response = self
            .api_post(
                "/api/durable-jobs",
                json!({
                    "command": command,
                    "cwd": params.cwd,
                    "workspace_id": workspace_id,
                    "started_by_mission_id": mission_id,
                    "timeout_secs": params.timeout_secs.unwrap_or(7200).clamp(1, 86400),
                    "resource_class": params.resource_class,
                    "idempotency_key": key,
                }),
            )
            .await?;
        let job = Self::response_value(response, "Start workspace job").await?;
        Ok(json!({"job": compact_workspace_job(job)}))
    }

    async fn get_workspace_job(&self, params: WorkspaceJobParams) -> Result<Value, String> {
        let id = parse_uuid(&params.job_id)?;
        let response = self.api_get(&format!("/api/durable-jobs/{id}")).await?;
        let job = Self::response_value(response, "Get workspace job").await?;
        let tail_bytes = params.tail_bytes.clamp(1, 64 * 1024);
        let response = self
            .api_get(&format!(
                "/api/durable-jobs/{id}/logs?tail_bytes={tail_bytes}"
            ))
            .await?;
        let logs = Self::response_value(response, "Get workspace job logs").await?;
        Ok(json!({"job": compact_workspace_job(job), "logs": logs}))
    }

    async fn cancel_workspace_job(&self, params: WorkspaceJobParams) -> Result<Value, String> {
        let id = parse_uuid(&params.job_id)?;
        let response = self
            .api_post(&format!("/api/durable-jobs/{id}/cancel"), json!({}))
            .await?;
        let job = Self::response_value(response, "Cancel workspace job").await?;
        Ok(json!({"job": compact_workspace_job(job), "cancellation_acknowledged": true}))
    }

    async fn send_message(&self, params: SendMessageParams) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        self.assert_mission_scope(id).await?;
        let mut body = json!({"mission_id": id.to_string(), "content": params.content});
        if let Some(key) = params.client_message_id {
            body["client_message_id"] = json!(key);
        }
        if let Some(model) = params.cloud_model {
            body["cloud_model"] = json!(model);
        }
        if let Some(params) = params.cloud_model_params {
            body["cloud_model_params"] = json!(params);
        }
        params.identity.add_to(&mut body);
        let response = self.api_post("/api/control/message", body).await?;
        if !response.status().is_success() {
            let text = response.text().await.unwrap_or_default();
            return Err(format!("Failed to send message: {text}"));
        }
        response
            .json()
            .await
            .map_err(|error| format!("Failed to parse send result: {error}"))
    }

    async fn ask_mission(&self, params: AskMissionParams) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        self.assert_mission_scope(id).await?;
        let mut body = json!({
            "content": params.content,
            "sandbox": params.sandbox,
        });
        if let Some(tid) = params.thread_id.as_deref() {
            let tid = parse_uuid(tid)?;
            body["thread_id"] = json!(tid.to_string());
        }
        // Ask turns make multiple sequential LLM/tool calls, so the shared
        // client default of 120s would abort long asks. But TWO budgets sit
        // above this call, and both are 600s: the Hermes-side MCP request
        // timeout, and the cron scheduler's idle watchdog — which counts from
        // the moment the tool STARTS, so id resolution, connect time and this
        // whole request all spend it. At 570s the margin was 30s; measured
        // 2026-08-06 05:18, a busy mission ate it and the watchdog killed the
        // whole tick ("idle for 600s — last activity: executing tool:
        // ask_mission"), turning one slow answer into a failed controller
        // run. 450s keeps ample room for real asks and returns a clean
        // "mission busy" error while both outer budgets still have 150s left.
        let response = self
            .api_post_with_timeout(
                &format!("/api/control/missions/{id}/ask"),
                body,
                Some(std::time::Duration::from_secs(450)),
            )
            .await?;
        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(format!("Failed to ask mission ({status}): {text}"));
        }
        let result: Value = response
            .json()
            .await
            .map_err(|error| format!("Failed to parse ask result: {error}"))?;
        // Return just the answer + thread_id (drop the full message history to
        // keep the tool result compact).
        Ok(json!({
            "thread_id": result.get("thread_id").cloned().unwrap_or(Value::Null),
            "answer": result.get("answer").cloned().unwrap_or(Value::Null),
        }))
    }

    async fn answer_mission_question(
        &self,
        params: AnswerMissionQuestionParams,
    ) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        self.assert_mission_scope(id).await?;
        if params.answers.is_empty() || params.answers.iter().any(Vec::is_empty) {
            return Err(
                "answers must contain one non-empty inner array per question, e.g. [[\"Option A\"]]"
                    .to_string(),
            );
        }
        let tool_call_id =
            match params
                .tool_call_id
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                Some(explicit) => explicit.to_string(),
                None => {
                    // Page backwards from the end of the transcript: the pending
                    // question is by definition among the NEWEST events, and the
                    // default (no cursor) pagination returns the oldest rows.
                    let events = self
                        .get_mission_events(MissionEventsParams {
                            mission_id: id.to_string(),
                            limit: 200,
                            view: Some("transcript".to_string()),
                            since_seq: None,
                            before_seq: Some(i64::MAX),
                        })
                        .await?;
                    let empty = Vec::new();
                    let events = events.as_array().unwrap_or(&empty);
                    let pending = pending_ask_user_questions(events);
                    match pending.as_slice() {
                        [] => return Err(
                            "No unanswered AskUserQuestion found in the mission's recent events. \
                             If the mission is merely idle or awaiting an ack, use \
                             send_message_to_mission / acknowledge_mission instead."
                                .to_string(),
                        ),
                        [only] => only.tool_call_id.clone(),
                        many => {
                            let listing = many
                                .iter()
                                .map(|question| {
                                    format!("{} — {}", question.tool_call_id, question.summary())
                                })
                                .collect::<Vec<_>>()
                                .join("; ");
                            return Err(format!(
                                "Multiple unanswered AskUserQuestion calls are pending; pass \
                             tool_call_id explicitly. Pending (newest first): {listing}"
                            ));
                        }
                    }
                }
            };
        let body = json!({
            "tool_call_id": tool_call_id,
            "name": "AskUserQuestion",
            "result": { "answers": params.answers },
        });
        let response = self.api_post("/api/control/tool_result", body).await?;
        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(format!("Failed to submit answer ({status}): {text}"));
        }
        let result: Value = response
            .json()
            .await
            .map_err(|error| format!("Failed to parse tool_result response: {error}"))?;
        // `delivered: false` means no live turn was parked on that call (the
        // mission ended or was interrupted) and the answer was dropped.
        let delivered = result
            .get("delivered")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let mut out = json!({
            "mission_id": id.to_string(),
            "tool_call_id": tool_call_id,
            "delivered": delivered,
        });
        if !delivered {
            out["note"] = json!(
                "The answer did not reach a live parked turn — the mission has likely ended or \
                 been interrupted. Use resume_mission or send_message_to_mission to wake it, \
                 then answer again if it re-asks."
            );
        }
        Ok(out)
    }

    async fn cancel_mission(&self, params: MissionIdParams) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        self.assert_mission_scope(id).await?;
        let response = self
            .api_post(&format!("/api/control/missions/{id}/cancel"), json!({}))
            .await?;
        if !response.status().is_success() {
            let text = response.text().await.unwrap_or_default();
            return Err(format!("Failed to cancel mission: {text}"));
        }
        let receipt: Value = response
            .json()
            .await
            .map_err(|_| "Invalid cancellation receipt")?;
        cancellation_receipt(id, receipt)
    }

    async fn adopt_mission(&self, params: AdoptMissionParams) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        self.assert_mission_scope(id).await?;
        // The session id is stamped by the sandboxed-origin-session plugin,
        // exactly as for start_mission. Refuse to adopt into nothing: an
        // adoption without a session would silently CLEAR the mission's
        // origin, which is the opposite of what the caller wanted.
        let session = params
            .origin_session_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                "adopt_mission needs the calling session's id; it is normally \
                 injected automatically. If you see this, the origin-session \
                 plugin did not stamp the call — report that rather than \
                 passing a session id by hand."
                    .to_string()
            })?;
        if !valid_origin_session_id(session) {
            return Err(format!(
                "origin_session_id {session:?} is not a valid session id"
            ));
        }
        let response = self
            .api_post(
                &format!("/api/control/missions/{id}/origin"),
                json!({ "origin": "hermes", "origin_session_id": session }),
            )
            .await?;
        let mission = Self::response_value(response, "adopt mission").await?;
        Ok(json!({
            "success": true,
            "adopted": id.to_string(),
            "origin_session_id": session,
            "mission": mission,
            "note": "This conversation now receives the mission's completion callback; do not poll.",
        }))
    }

    async fn acknowledge_mission(&self, params: MissionIdParams) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        self.assert_mission_scope(id).await?;
        let response = self
            .api_get(&format!("/api/control/missions/{id}/digest"))
            .await?;
        let digest = Self::response_value(response, "Read mission before ACK").await?;
        if !mission_requires_acknowledgement(&digest)? {
            return Ok(json!({
                "success": true,
                "acknowledged": id.to_string(),
                "already_acknowledged": true,
            }));
        }

        let response = self
            .api_post(
                &format!("/api/control/missions/{id}/status"),
                json!({"status": "acknowledged"}),
            )
            .await?;
        Self::response_value(response, "Acknowledge mission").await?;

        // The status mutation response is only an operation envelope. Re-read
        // the mission so controllers never mistake a successful HTTP response
        // for a confirmed state transition.
        let response = self
            .api_get(&format!("/api/control/missions/{id}/digest"))
            .await?;
        let digest = Self::response_value(response, "Verify mission ACK").await?;
        let mission = digest.get("mission").unwrap_or(&digest);
        if mission.get("status").and_then(Value::as_str) != Some("acknowledged") {
            return Err(
                "Mission ACK mutation succeeded but readback is not acknowledged".to_string(),
            );
        }

        Ok(json!({
            "success": true,
            "acknowledged": id.to_string(),
            "already_acknowledged": false,
        }))
    }

    async fn managed_request(
        &self,
        method: reqwest::Method,
        path: String,
        body: Option<Value>,
    ) -> Result<Value, String> {
        let mut req = self
            .client
            .request(method, format!("{}{}", self.api_url, path))
            // Spawning waits for the VM to enroll (typically 20-90 s).
            .timeout(std::time::Duration::from_secs(420));
        if let Some(body) = body {
            req = req.json(&body);
        }
        if let Some((name, value)) = self.auth_header() {
            req = req.header(name, value);
        }
        let response = req
            .send()
            .await
            .map_err(|error| format!("HTTP request failed: {error}"))?;
        let status = response.status();
        let value: Value = response.json().await.unwrap_or(Value::Null);
        if !status.is_success() {
            return Err(format!(
                "{} ({status}): {}",
                value["error"].as_str().unwrap_or("managed_machine_error"),
                value["message"].as_str().unwrap_or("request failed")
            ));
        }
        Ok(value)
    }

    async fn spawn_managed_machine(
        &self,
        params: SpawnManagedParams,
        owner_mission_id: Option<String>,
    ) -> Result<Value, String> {
        self.spawn_managed_machine_with(params, owner_mission_id, None, false)
            .await
    }

    async fn spawn_managed_machine_with(
        &self,
        params: SpawnManagedParams,
        owner_mission_id: Option<String>,
        sub_budget_usd: Option<f64>,
        reuse_idle: bool,
    ) -> Result<Value, String> {
        let machine = self
            .managed_request(
                reqwest::Method::POST,
                "/api/managed-machines".into(),
                Some(json!({
                    "provider": params.provider,
                    "size": params.size,
                    "cpu": params.cpu,
                    "ram_gb": params.ram_gb,
                    "gpu": params.gpu,
                    "arch": params.arch,
                    "max_hourly_usd": params.max_hourly_usd,
                    "allow_24h_commitment": params.allow_24h_commitment.unwrap_or(false),
                    "ttl_minutes": params.ttl_minutes,
                    "image": params.image,
                    "reason": params.reason,
                    "from_snapshot": params.from_snapshot,
                    "provisioning_mode": params.provisioning_mode,
                    "owner_mission_id": owner_mission_id,
                    "sub_budget_usd": sub_budget_usd,
                    "reuse_idle": reuse_idle,
                    "wait": true,
                })),
            )
            .await?;
        Ok(json!({
            "machine": machine,
            "node_id": machine["node_id"],
            "name": machine["name"],
            "next": if machine["provisioning_mode"] == "raw" { format!("Raw VM ready; no Orb node is installed. Use exec_raw_managed_machine(machine_id=\"{name}\", operation=...) for bounded guest ops, then destroy_managed_machine(machine_id=\"{name}\") when done.", name = machine["name"].as_str().unwrap_or_default()) } else { format!(
                "start_mission(remote_node_id=\"{name}\", backend=..., prompt=...) runs a subagent on it (its node id {node} also works); destroy_managed_machine(machine_id=\"{name}\") when done",
                name = machine["name"].as_str().unwrap_or_default(),
                node = machine["node_id"].as_str().unwrap_or_default(),
            ) },
        }))
    }

    async fn get_compute_fleet(&self) -> Result<Value, String> {
        let response = self.api_get("/api/remote-nodes").await?;
        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(format!("Failed to get compute fleet ({status}): {text}"));
        }
        let fleet: Value = response
            .json()
            .await
            .map_err(|error| format!("Failed to parse compute fleet: {error}"))?;
        Ok(compact_compute_fleet(&fleet))
    }

    // ---- Project roster tools (see projects_store.rs / projects_overview.rs) ----

    async fn list_projects(&self) -> Result<Value, String> {
        // Reuse the overview endpoint, but return only the light roster fields
        // a controller needs at the top of a tick — not the full board payload.
        let response = self.api_get("/api/projects/overview").await?;
        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(format!("Failed to list projects ({status}): {text}"));
        }
        let overview: Value = response
            .json()
            .await
            .map_err(|error| format!("Failed to parse projects: {error}"))?;
        let rows: Vec<Value> = overview
            .get("projects")
            .and_then(Value::as_array)
            .map(|projects| {
                projects
                    .iter()
                    .map(|p| {
                        let latest = p.get("latest_update");
                        json!({
                            "slug": p.get("slug"),
                            "bucket": p.get("bucket"),
                            "mode": latest.and_then(|u| u.get("mode")),
                            "health": p.get("health").and_then(|h| h.get("tracks_needing_attention")),
                            "latest_at": latest.and_then(|u| u.get("at")),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(json!({ "projects": rows }))
    }

    async fn get_project(&self, params: ProjectSlugParams) -> Result<Value, String> {
        let slug = params.slug.trim();
        let response = self.api_get(&format!("/api/projects/{slug}")).await?;
        let raw = Self::response_value(response, "get project").await?;
        Ok(compact_project(raw))
    }

    async fn get_situation(&self, params: ProjectSlugParams) -> Result<Value, String> {
        let slug = params.slug.trim();
        let response = self
            .api_get(&format!("/api/projects/{slug}/situation"))
            .await?;
        let raw = Self::response_value(response, "get situation").await?;
        Ok(compact_situation(raw))
    }

    async fn update_project_status(
        &self,
        params: UpdateProjectStatusParams,
    ) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let body = json!({
            "mode": params.mode,
            "next_action": params.next_action,
            "blocker": params.blocker,
            "consumed_steer_ids": params.consumed_steer_ids,
        });
        let response = self
            .api_post(&format!("/api/projects/{slug}/status"), body)
            .await?;
        Self::response_value(response, "update project status").await
    }

    async fn set_project_track(&self, params: SetProjectTrackParams) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let body = json!({
            "track": params.track,
            "desired_state": params.desired_state,
            "status": params.status,
        });
        let response = self
            .api_post(&format!("/api/projects/{slug}/track"), body)
            .await?;
        Self::response_value(response, "set project track").await
    }

    async fn accept_project_track(
        &self,
        params: AcceptProjectTrackParams,
    ) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let track = params.track.trim();
        let body = json!({
            "idempotency_key": params.idempotency_key,
            "expected_revision": params.expected_revision,
            "evidence": params.evidence,
            "actor_type": "controller",
            "actor_id": self.actor_id(),
        });
        let response = self
            .api_post(&format!("/api/projects/{slug}/tracks/{track}/accept"), body)
            .await?;
        Self::response_value(response, "accept project track").await
    }

    async fn invalidate_project_track_evidence(
        &self,
        params: InvalidateProjectTrackEvidenceParams,
    ) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let track = params.track.trim();
        let body = json!({
            "receipt_id": params.receipt_id,
            "reason": params.reason,
            "actor": self.actor_id(),
        });
        let response = self
            .api_post(
                &format!("/api/projects/{slug}/tracks/{track}/invalidate"),
                body,
            )
            .await?;
        Self::response_value(response, "invalidate project track evidence").await
    }

    /// Per-criterion acceptance (the 2026-09-01 tool shape). Delegates to the
    /// same receipt store as `accept_project_track`.
    async fn accept_project_track_evidence(
        &self,
        params: AcceptProjectTrackEvidenceParams,
    ) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let track = params.track.trim();
        let response = self
            .api_post(
                &format!("/api/projects/{slug}/tracks/{track}/evidence"),
                json!({
                    "criterion": params.criterion,
                    "verifier_class": params.verifier_class,
                    "evidence_ref": params.evidence_ref,
                    "artifact_version": params.artifact_version,
                    "observed_at": params.observed_at,
                }),
            )
            .await?;
        Self::response_value(response, "accept project track evidence").await
    }

    async fn reopen_project_track(
        &self,
        params: ReopenProjectTrackParams,
    ) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let track = params.track.trim();
        let response = self
            .api_post(
                &format!("/api/projects/{slug}/tracks/{track}/reopen"),
                json!({
                    "reason": params.reason,
                    "governed_artifact_version": params.governed_artifact_version,
                }),
            )
            .await?;
        Self::response_value(response, "reopen project track").await
    }

    /// Who this MCP acts as, for receipts: the bound project scope or the
    /// generic connector identity.
    fn actor_id(&self) -> String {
        std::env::var("HERMES_CONTROLLER_ID")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "assistant-mcp".to_string())
    }

    async fn get_project_grant(&self, params: ProjectSlugParams) -> Result<Value, String> {
        let slug = params.slug.trim();
        let response = self.api_get(&format!("/api/projects/{slug}/grant")).await?;
        Self::response_value(response, "get project grant").await
    }

    async fn set_project_grant(&self, params: SetProjectGrantParams) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let body = json!({
            "merge_authority": params.merge_authority,
            "budget_per_tick": params.budget_per_tick,
            "parallel_missions": params.parallel_missions,
            "pause_reason": params.pause_reason,
            "resume_condition": params.resume_condition,
            "material_bar": params.material_bar,
            "autonomy_level": params.autonomy_level,
        });
        let response = self
            .api_post(&format!("/api/projects/{slug}/grant"), body)
            .await?;
        Self::response_value(response, "set project grant").await
    }

    async fn add_project_steer(&self, params: AddProjectSteerParams) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let body = json!({
            "body": params.body,
            "origin": "mcp",
        });
        let response = self
            .api_post(&format!("/api/projects/{slug}/steers"), body)
            .await?;
        Self::response_value(response, "add project steer").await
    }

    async fn record_project_decision(
        &self,
        params: RecordProjectDecisionParams,
    ) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let body = json!({
            "question": params.question,
            "rationale": params.rationale,
            "kind": params.kind,
            "authority": params.authority,
            "status": params.status,
            "evidence": params.evidence,
        });
        let response = self
            .api_post(&format!("/api/projects/{slug}/decision"), body)
            .await?;
        Self::response_value(response, "record project decision").await
    }

    async fn answer_project_decision(
        &self,
        params: AnswerProjectDecisionParams,
    ) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let body = json!({ "at": params.at, "answer": params.answer });
        let response = self
            .api_post(&format!("/api/projects/{slug}/decision/answer"), body)
            .await?;
        Self::response_value(response, "answer project decision").await
    }

    async fn get_project_tasks(&self, params: ProjectSlugParams) -> Result<Value, String> {
        let slug = params.slug.trim();
        let response = self.api_get(&format!("/api/projects/{slug}/tasks")).await?;
        Self::response_value(response, "get project tasks").await
    }

    async fn plan_project_tasks(&self, params: PlanProjectTasksParams) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let tasks: Vec<Value> = params
            .tasks
            .iter()
            .map(|task| {
                json!({
                    "task_key": task.task_key,
                    "title": task.title,
                    "prompt": task.prompt,
                    "acceptance_criteria": task.acceptance_criteria,
                    "depends_on": task.depends_on,
                    "position": task.position,
                })
            })
            .collect();
        let response = self
            .api_post(
                &format!("/api/projects/{slug}/tasks"),
                json!({ "tasks": tasks }),
            )
            .await?;
        Self::response_value(response, "plan project tasks").await
    }

    async fn update_project_task(&self, params: UpdateProjectTaskParams) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let task_key = params.task_key.trim();
        let response = self
            .api_patch(
                &format!("/api/projects/{slug}/tasks/{task_key}"),
                json!({
                    "title": params.title,
                    "prompt": params.prompt,
                    "acceptance_criteria": params.acceptance_criteria,
                    "depends_on": params.depends_on,
                }),
            )
            .await?;
        Self::response_value(response, "update project task").await
    }

    async fn cancel_project_task(&self, params: CancelProjectTaskParams) -> Result<Value, String> {
        let slug = params.slug.trim();
        self.assert_project_scope(slug)?;
        let task_key = params.task_key.trim();
        let response = self
            .api_delete(&format!("/api/projects/{slug}/tasks/{task_key}"))
            .await?;
        Self::response_value(response, "cancel project task").await
    }

    async fn link_mission_to_project(
        &self,
        params: LinkMissionToProjectParams,
    ) -> Result<Value, String> {
        self.assert_project_scope(&params.slug)?;
        let id = self.resolve_mission_id(&params.mission_id).await?;
        let mut body = serde_json::Map::new();
        body.insert("project".to_string(), json!(params.slug.trim()));
        if let Some(track) = params
            .track
            .as_deref()
            .map(str::trim)
            .filter(|t| !t.is_empty())
        {
            body.insert("track".to_string(), json!(track));
        }
        if let Some(writer) = params.writer {
            body.insert("writer".to_string(), json!(writer));
        }
        let response = self
            .api_post(
                &format!("/api/control/missions/{id}/project"),
                Value::Object(body),
            )
            .await?;
        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(format!(
                "Failed to link mission to project ({status}): {text}"
            ));
        }
        Ok(json!({ "success": true, "mission_id": id.to_string(), "project": params.slug.trim() }))
    }

    async fn list_workspaces(&self) -> Result<Value, String> {
        let response = self.api_get("/api/workspaces").await?;
        if !response.status().is_success() {
            return Err(format!("Failed to list workspaces: {}", response.status()));
        }
        let workspaces: Value = response
            .json()
            .await
            .map_err(|error| format!("Failed to parse workspaces: {error}"))?;
        Ok(json!({ "workspaces": workspaces }))
    }

    async fn get_workspace(&self, params: WorkspaceIdParams) -> Result<Value, String> {
        let id = parse_uuid(&params.workspace_id)?;
        let response = self.api_get(&format!("/api/workspaces/{id}")).await?;
        let workspace = Self::response_value(response, "Get workspace").await?;
        Ok(json!({"workspace": workspace}))
    }

    async fn create_workspace(&self, params: CreateWorkspaceParams) -> Result<Value, String> {
        let body = create_workspace_body(params)?;
        let response = self.api_post("/api/workspaces", body).await?;
        let workspace = Self::response_value(response, "Create workspace").await?;
        Ok(json!({"workspace": workspace}))
    }

    async fn update_workspace(&self, params: UpdateWorkspaceParams) -> Result<Value, String> {
        let (id, body) = update_workspace_body(params)?;
        let response = self.api_put(&format!("/api/workspaces/{id}"), body).await?;
        let workspace = Self::response_value(response, "Update workspace").await?;
        Ok(json!({"workspace": workspace}))
    }

    async fn delete_workspace(&self, params: DeleteWorkspaceParams) -> Result<Value, String> {
        if !params.confirm {
            return Err("Workspace deletion requires confirm=true".to_string());
        }
        let id = parse_uuid(&params.workspace_id)?;
        let response = self.api_delete(&format!("/api/workspaces/{id}")).await?;
        Self::response_value(response, "Delete workspace").await?;
        Ok(json!({"deleted": true, "workspace_id": id.to_string()}))
    }

    async fn list_workspace_templates(&self) -> Result<Value, String> {
        let response = self.api_get("/api/library/workspace-template").await?;
        let templates = Self::response_value(response, "List workspace templates").await?;
        Ok(json!({"templates": templates}))
    }

    async fn get_workspace_template(
        &self,
        params: WorkspaceTemplateNameParams,
    ) -> Result<Value, String> {
        let name = require_resource_name(&params.name, "Workspace template")?;
        let encoded = urlencoding::encode(&name);
        let response = self
            .api_get(&format!("/api/library/workspace-template/{encoded}"))
            .await?;
        let template = Self::response_value(response, "Get workspace template").await?;
        Ok(json!({"template": template}))
    }

    async fn save_workspace_template(
        &self,
        params: SaveWorkspaceTemplateParams,
    ) -> Result<Value, String> {
        let name = require_resource_name(&params.name, "Workspace template")?;
        let encoded = urlencoding::encode(&name);
        let path = format!("/api/library/workspace-template/{encoded}");
        let response = self.api_get(&path).await?;
        let has_env_override = params.env_vars.is_some();
        let mut template = if response.status().is_success() {
            let current = Self::response_value(response, "Get workspace template").await?;
            if !has_env_override
                && current
                    .get("env_vars")
                    .and_then(Value::as_object)
                    .is_some_and(|env| {
                        env.values().any(|value| {
                            value
                                .as_str()
                                .is_some_and(|raw| raw.starts_with("[DECRYPTION_FAILED]"))
                        })
                    })
            {
                return Err(
                    "Template contains env vars that could not be decrypted; supply a complete env_vars replacement before saving"
                        .to_string(),
                );
            }
            current.as_object().cloned().ok_or_else(|| {
                "Existing workspace template response was not an object".to_string()
            })?
        } else if response.status() == reqwest::StatusCode::NOT_FOUND {
            serde_json::Map::new()
        } else {
            return match Self::response_value(response, "Get workspace template").await {
                Err(error) => Err(error),
                Ok(_) => Err("Unexpected successful template response".to_string()),
            };
        };
        template.remove("name");
        template.remove("path");
        apply_template_patch(&mut template, params)?;

        let response = self.api_put(&path, Value::Object(template)).await?;
        Self::response_value(response, "Save workspace template").await?;
        let response = self.api_get(&path).await?;
        let saved = Self::response_value(response, "Read saved workspace template").await?;
        Ok(json!({"saved": true, "template": saved}))
    }

    async fn delete_workspace_template(
        &self,
        params: DeleteWorkspaceTemplateParams,
    ) -> Result<Value, String> {
        if !params.confirm {
            return Err("Template deletion requires confirm=true".to_string());
        }
        let name = require_resource_name(&params.name, "Workspace template")?;
        let encoded = urlencoding::encode(&name);
        let response = self
            .api_delete(&format!("/api/library/workspace-template/{encoded}"))
            .await?;
        Self::response_value(response, "Delete workspace template").await?;
        Ok(json!({"deleted": true, "name": name}))
    }

    async fn rebuild_workspace_from_template(
        &self,
        params: RebuildWorkspaceFromTemplateParams,
    ) -> Result<Value, String> {
        if !params.confirm {
            return Err("Forced workspace rebuild requires confirm=true".to_string());
        }
        let id = parse_uuid(&params.workspace_id)?;
        let apply_response = self
            .api_post(
                &format!("/api/workspaces/{id}/apply-template"),
                json!({"template": params.template}),
            )
            .await?;
        let applied = Self::response_value(apply_response, "Apply workspace template").await?;

        let build_response = self
            .api_post(
                &format!("/api/workspaces/{id}/build"),
                json!({"rebuild": true}),
            )
            .await?;
        let build = Self::response_value(build_response, "Rebuild workspace").await?;
        Ok(json!({
            "workspace_id": id.to_string(),
            "template_applied": applied.get("template").cloned().unwrap_or(Value::Null),
            "status": build.get("status").cloned().unwrap_or(Value::Null),
            "rebuild_started": true,
        }))
    }

    async fn update_mission_settings(&self, params: UpdateSettingsParams) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        self.assert_mission_scope(id).await?;
        let mut body = serde_json::Map::new();
        if let Some(backend) = params
            .backend
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            body.insert("backend".to_string(), json!(backend));
        }
        // model_override / model_effort / agent / config_profile use a "patch"
        // deserializer on the server: present (incl. empty string) = set/clear,
        // omitted = leave unchanged. So only insert what the caller provided.
        if let Some(model_override) = params.model_override {
            body.insert("model_override".to_string(), json!(model_override));
        }
        if let Some(model_effort) = params.model_effort {
            body.insert("model_effort".to_string(), json!(model_effort));
        }
        if let Some(fast_mode) = params.fast_mode {
            body.insert("fast_mode".to_string(), json!(fast_mode));
        }
        if let Some(agent) = params.agent {
            body.insert("agent".to_string(), json!(agent));
        }
        if let Some(config_profile) = params.config_profile {
            body.insert("config_profile".to_string(), json!(config_profile));
        }
        if body.is_empty() {
            return Err("No settings provided. Set at least one of: backend, \
                        model_override, model_effort, fast_mode, agent, config_profile."
                .to_string());
        }
        let response = self
            .api_patch(
                &format!("/api/control/missions/{id}/settings"),
                Value::Object(body),
            )
            .await?;
        let status = response.status();
        if !status.is_success() {
            let text = response.text().await.unwrap_or_default();
            if status.as_u16() == 409 {
                return Err(format!(
                    "Mission is running, so settings cannot change mid-turn ({text}). \
                     Cancel it with cancel_mission (or wait for it to reach awaiting_user), \
                     update settings, then resume_mission or send_message_to_mission to start \
                     the next turn on the new backend."
                ));
            }
            return Err(format!(
                "Failed to update mission settings ({status}): {text}"
            ));
        }
        let mission: Value = response
            .json()
            .await
            .map_err(|error| format!("Failed to parse updated mission: {error}"))?;
        Ok(json!({ "mission": compact_mission_summary(mission) }))
    }

    async fn resume_mission(&self, params: ResumeMissionParams) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        self.assert_mission_scope(id).await?;
        let hint = params
            .content
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);
        let has_hint = hint.is_some();
        // The backend admits the custom prompt and identity in the same actor
        // command. Never replay identity edits in a second HTTP send.
        let mut body = json!({
            "clean_workspace": params.clean_workspace,
            "skip_message": false,
            "content": hint,
        });
        params.identity.add_to(&mut body);
        let response = self
            .api_post(&format!("/api/control/missions/{id}/resume"), body)
            .await?;
        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(format!(
                "Failed to resume mission ({status}): {text}. \
                 Only interrupted, blocked, or failed missions can be resumed."
            ));
        }
        let _accepted_mission: Value = response
            .json()
            .await
            .map_err(|error| format!("Failed to parse resumed mission: {error}"))?;
        // Mutation success and state readback failure are different outcomes:
        // do not invite a duplicate resume if only this GET failed, and do not
        // substitute the old interrupted snapshot for an unknown current state.
        let (mission, state_warning) = match self
            .get_mission_digest(MissionIdParams {
                mission_id: id.to_string(),
            })
            .await
        {
            Ok(digest) => (compact_digest_mission_summary(digest), None),
            Err(error) => (
                Value::Null,
                Some(format!(
                    "Resume request accepted, but current mission state could not be read: {error}. \
                     Check get_mission_health; do not repeat the resume solely for this readback failure."
                )),
            ),
        };
        let response_body = json!({
            "mission_id": id,
            "resume_accepted": true,
            "mission": mission,
            "steered": has_hint,
            "steer_warning": Value::Null,
            "state_warning": state_warning,
        });
        Ok(response_body)
    }

    /// Fetch the live runner entry for one mission from `/api/control/running`,
    /// or `Value::Null` if the mission is not currently running (idle/finished).
    ///
    /// Network failures and 5xx responses are propagated as `Err` so callers can
    /// surface them — masking them as "not running" would make a stalled but
    /// still-active mission look healthy.
    async fn find_running_info(&self, mission_id: &Uuid) -> Result<Value, String> {
        let response = self.api_get("/api/control/running").await?;
        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(format!(
                "Failed to fetch live runner state ({status}): {text}"
            ));
        }
        let running: Value = response
            .json()
            .await
            .map_err(|error| format!("Failed to parse running missions: {error}"))?;
        let needle = mission_id.to_string();
        let found = running
            .as_array()
            .into_iter()
            .flatten()
            .find(|entry| entry.get("mission_id").and_then(Value::as_str) == Some(needle.as_str()))
            .cloned()
            .unwrap_or(Value::Null);
        Ok(found)
    }

    /// Most recent assistant message content (truncated), for judging whether a
    /// mission gave up early or finished cleanly.
    async fn last_assistant_message(&self, mission_id: &Uuid) -> Option<String> {
        self.last_assistant_message_bounded(mission_id, 600).await
    }

    async fn last_assistant_message_bounded(
        &self,
        mission_id: &Uuid,
        max: usize,
    ) -> Option<String> {
        let events = self
            .get_mission_events(MissionEventsParams {
                mission_id: mission_id.to_string(),
                limit: 12,
                view: Some("transcript".to_string()),
                since_seq: None,
                before_seq: Some(i64::MAX),
            })
            .await
            .ok()?;
        events
            .as_array()?
            .iter()
            .rev()
            .find(|event| {
                matches!(
                    event.get("event_type").and_then(Value::as_str),
                    Some("assistant_message" | "assistant_message_canonical")
                )
            })
            .and_then(|event| event.get("content").and_then(Value::as_str))
            .map(|content| truncate_snippet(content, max))
    }

    async fn get_mission_health(&self, params: MissionHealthParams) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        let mission = self
            .get_mission(MissionIdParams {
                mission_id: id.to_string(),
            })
            .await?;
        let status = mission
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
        // Live runner state is best-effort: a transient API error should not
        // blind the babysitter to the rest of the health picture. Surface the
        // error inline so the caller (and the recommendation) can see that
        // stall/health data is unavailable, rather than silently reporting
        // "no problems".
        let (live, live_warning) = match self.find_running_info(&id).await {
            Ok(live) => (live, None),
            Err(error) => (Value::Null, Some(error)),
        };
        let events = self
            .get_mission_events(MissionEventsParams {
                mission_id: id.to_string(),
                limit: 60,
                view: Some("trace".to_string()),
                since_seq: None,
                before_seq: Some(i64::MAX),
            })
            .await?;
        let empty = Vec::new();
        let events = events.as_array().unwrap_or(&empty);
        let analysis = analyze_trace_events(events);
        let last_assistant = self.last_assistant_message(&id).await;
        let backend = mission.get("backend").and_then(Value::as_str);
        let queue_wait = mission.get("queue_wait").cloned().unwrap_or(Value::Null);
        let mut recommendation = queue_wait_recommendation(&status, &queue_wait)
            .unwrap_or_else(|| build_recommendation(&status, backend, &live, &analysis));
        if let Some(warning) = &live_warning {
            recommendation =
                format!("{recommendation} (Note: live runner state unavailable — {warning})");
        }
        Ok(json!({
            "mission_id": id.to_string(),
            "title": mission.get("title").cloned().unwrap_or(Value::Null),
            "status": status,
            "mission_mode": mission.get("mission_mode").cloned().unwrap_or(Value::Null),
            "goal_mode": mission.get("goal_mode").cloned().unwrap_or(Value::Null),
            "goal_objective": compact_opt_text(mission.get("goal_objective"), 1000),
            "backend": mission.get("backend").cloned().unwrap_or(Value::Null),
            "model_override": mission.get("model_override").cloned().unwrap_or(Value::Null),
            "model_effort": mission.get("model_effort").cloned().unwrap_or(Value::Null),
            "live": live,
            "live_warning": live_warning,
            "queue_wait": queue_wait,
            "signals": analysis.signals_json(),
            "recent_errors": analysis.recent_errors,
            "suspected_loop": analysis.loop_json(),
            "trace_tool_calls": analysis.tool_call_count,
            "last_assistant_message": last_assistant,
            "recommendation": recommendation,
        }))
    }

    async fn get_mission_diagnostics(
        &self,
        params: MissionDiagnosticsParams,
    ) -> Result<Value, String> {
        let id = self.resolve_mission_id(&params.mission_id).await?;
        let limit = params.limit.clamp(10, 300);
        let events = self
            .get_mission_events(MissionEventsParams {
                mission_id: id.to_string(),
                limit,
                view: Some("trace".to_string()),
                since_seq: None,
                before_seq: Some(i64::MAX),
            })
            .await?;
        let empty = Vec::new();
        let events = events.as_array().unwrap_or(&empty);

        let mut timeline = Vec::new();
        let mut tool_counts: std::collections::BTreeMap<String, usize> =
            std::collections::BTreeMap::new();
        let mut repeat_counts: std::collections::BTreeMap<(String, String), usize> =
            std::collections::BTreeMap::new();
        let mut errors = Vec::new();
        let mut results = Vec::new();

        for event in events {
            let event_type = event
                .get("event_type")
                .and_then(Value::as_str)
                .unwrap_or("");
            match event_type {
                "tool_call" => {
                    let tool = event
                        .get("tool_name")
                        .and_then(Value::as_str)
                        .unwrap_or("(unknown)")
                        .to_string();
                    let args = event.get("content").and_then(Value::as_str).unwrap_or("");
                    *tool_counts.entry(tool.clone()).or_insert(0) += 1;
                    *repeat_counts
                        .entry((tool.clone(), args.trim().to_string()))
                        .or_insert(0) += 1;
                    timeline.push(json!({
                        "sequence": event.get("sequence").cloned().unwrap_or(Value::Null),
                        "tool": tool,
                        "args": truncate_snippet(args, 200),
                    }));
                }
                "tool_result" => {
                    let content = event.get("content").and_then(Value::as_str).unwrap_or("");
                    results.push(json!({
                        "sequence": event.get("sequence"),
                        "tool_call_id": event.get("tool_call_id"),
                        "snippet": diagnostic_result_snippet(content),
                    }));
                }
                "error" => {
                    let content = event.get("content").and_then(Value::as_str).unwrap_or("");
                    errors.push(json!({
                        "sequence": event.get("sequence").cloned().unwrap_or(Value::Null),
                        "timestamp": event.get("timestamp").cloned().unwrap_or(Value::Null),
                        "content": truncate_snippet(content, 800),
                        "signals": error_signals_in(content),
                    }));
                }
                _ => {}
            }
        }

        // Keep the most recent slice of the tool timeline to bound output.
        let timeline_tail: Vec<Value> = timeline.iter().rev().take(30).rev().cloned().collect();
        let repeated: Vec<Value> = repeat_counts
            .into_iter()
            .filter(|(_, count)| *count >= 2)
            .map(|((tool, args), count)| {
                json!({ "tool": tool, "repeats": count, "args": truncate_snippet(&args, 160) })
            })
            .collect();
        let tool_counts: Vec<Value> = tool_counts
            .into_iter()
            .map(|(tool, count)| json!({ "tool": tool, "count": count }))
            .collect();

        Ok(json!({
            "mission_id": id.to_string(),
            "events_scanned": events.len(),
            "tool_timeline": timeline_tail,
            "tool_results": results.into_iter().rev().take(30).collect::<Vec<_>>(),
            "tool_counts": tool_counts,
            "repeated_calls": repeated,
            "errors": errors,
        }))
    }

    pub(super) async fn handle_call(&self, name: &str, arguments: Value) -> Result<Value, String> {
        match name {
            "list_cloud_accounts" => {
                let response = self.api_get("/api/cloud/accounts").await?;
                if !response.status().is_success() {
                    return Err(format!("Cloud discovery failed: {}", response.status()));
                }
                response.json().await.map_err(|e| e.to_string())
            }
            "list_cloud_models" => {
                let path = match arguments.get("provider").and_then(Value::as_str) {
                    Some("chatgpt") => "/api/cloud/chatgpt/options",
                    Some("cursor_cloud") => "/api/cloud/cursor/options",
                    Some("hermes") => "/api/cloud/hermes/options",
                    _ => return Err("This provider does not expose model selection".into()),
                };
                let response = self.api_get(path).await?;
                if !response.status().is_success() {
                    return Err(format!(
                        "Cloud model discovery failed: {}",
                        response.status()
                    ));
                }
                response.json().await.map_err(|e| e.to_string())
            }
            "get_cloud_execution" => {
                let params: MissionIdParams = parse_params(arguments.clone())?;
                let id = self.resolve_mission_id(&params.mission_id).await?;
                self.assert_mission_scope(id).await?;
                let response = self
                    .api_get(&format!("/api/control/missions/{id}/cloud"))
                    .await?;
                if !response.status().is_success() {
                    return Err(format!("Cloud receipt unavailable: {}", response.status()));
                }
                let mut execution: Value = response.json().await.map_err(|e| e.to_string())?;
                // Redact complete values before slicing: a fragment of a token
                // may no longer match the credential detector.
                scrub_sensitive_json(&mut execution);
                Ok(super::cloud_read::page(execution, &arguments))
            }
            "list_active_missions" => {
                let params: ListMissionsParams = parse_params(arguments)?;
                self.list_active_missions(params).await
            }
            "list_missions" => {
                let params: ListMissionsParams = parse_params(arguments)?;
                self.list_missions(params).await
            }
            "get_mission" => {
                let params: MissionIdParams = parse_params(arguments)?;
                self.get_mission(params).await
            }
            "get_mission_digest" => {
                let params: MissionIdParams = parse_params(arguments)?;
                self.get_mission_digest(params).await
            }
            "get_mission_events" => {
                let params: MissionEventsParams = parse_params(arguments)?;
                self.get_mission_events(params).await
            }
            "list_mission_shared_files" => {
                let params: MissionSharedFilesParams = parse_params(arguments)?;
                self.list_mission_shared_files(params).await
            }
            "download_shared_file" => {
                let params: DownloadSharedFileParams = parse_params(arguments)?;
                self.download_shared_file(params).await
            }
            "start_mission" => {
                let params: StartMissionParams = parse_params(arguments)?;
                self.start_mission(params).await
            }
            "consult_model" => {
                let params: ConsultModelParams = parse_params(arguments)?;
                self.consult_model(params).await
            }
            "get_consult_result" => {
                let params: MissionIdParams = parse_params(arguments)?;
                self.get_consult_result(params).await
            }
            "send_message_to_mission" => {
                let params: SendMessageParams = parse_params(arguments)?;
                self.send_message(params).await
            }
            "ask_mission" => {
                let params: AskMissionParams = parse_params(arguments)?;
                self.ask_mission(params).await
            }
            "answer_mission_question" => {
                let params: AnswerMissionQuestionParams = parse_params(arguments)?;
                self.answer_mission_question(params).await
            }
            "cancel_mission" => {
                let params: MissionIdParams = parse_params(arguments)?;
                self.cancel_mission(params).await
            }
            "acknowledge_mission" => {
                let params: MissionIdParams = parse_params(arguments)?;
                self.acknowledge_mission(params).await
            }
            "adopt_mission" => {
                let params: AdoptMissionParams = parse_params(arguments)?;
                self.adopt_mission(params).await
            }
            "get_compute_fleet" => self.get_compute_fleet().await,
            "spawn_managed_machine" => {
                let params: SpawnManagedParams = parse_params(arguments)?;
                let owner = params.owner_mission_id.clone();
                self.spawn_managed_machine(params, owner).await
            }
            "exec_raw_managed_machine" => {
                let p: RawManagedOperationParams = parse_params(arguments)?;
                let raw_key = p
                    .idempotency_key
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| "idempotency_key is required".to_string())?;
                let idempotency_key = if raw_key.len() <= 128
                    && raw_key
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"_-.:".contains(&b))
                {
                    raw_key.to_string()
                } else {
                    format!("mcp:{}", crate::managed::sha256_hex(raw_key))
                };
                let operation = match p.operation.trim() {
                    "exec" => {
                        let command = p
                            .command
                            .filter(|c| !c.is_empty())
                            .ok_or_else(|| "`command` is required for operation=\"exec\"".to_string())?;
                        json!({
                            "kind": "exec",
                            "command": command,
                            "timeout_secs": p.timeout_secs.unwrap_or(60),
                        })
                    }
                    "write_file" => {
                        let path = p
                            .path
                            .filter(|s| !s.is_empty())
                            .ok_or_else(|| "`path` is required for operation=\"write_file\"".to_string())?;
                        json!({
                            "kind": "write_file",
                            "path": path,
                            "content": p.content.unwrap_or_default(),
                        })
                    }
                    "read_file" => {
                        let path = p
                            .path
                            .filter(|s| !s.is_empty())
                            .ok_or_else(|| "`path` is required for operation=\"read_file\"".to_string())?;
                        json!({
                            "kind": "read_file",
                            "path": path,
                        })
                    }
                    other => {
                        return Err(format!(
                            "Unsupported raw operation `{other}` (expected exec, write_file, or read_file)"
                        ))
                    }
                };
                self.managed_request(
                    reqwest::Method::POST,
                    format!(
                        "/api/managed-machines/{}/operations",
                        urlencoding::encode(&p.machine_id)
                    ),
                    Some(json!({
                        "idempotency_key": idempotency_key,
                        "operation": operation,
                    })),
                )
                .await
            }
            "list_managed_machines" => {
                let params: ListManagedParams = parse_params(arguments)?;
                let list = self
                    .managed_request(reqwest::Method::GET, "/api/managed-machines".into(), None)
                    .await?;
                Ok(if params.verbose == Some(true) {
                    list
                } else {
                    compact_managed_list(&list)
                })
            }
            "snapshot_managed_machine" => {
                let p: ManagedActionParams = parse_params(arguments)?;
                self.managed_request(
                    reqwest::Method::POST,
                    format!("/api/managed-machines/{}/snapshot", urlencoding::encode(&p.machine_id)),
                    Some(json!({"name": p.name.unwrap_or_default(), "owner_mission_id": p.owner_mission_id})),
                )
                .await
            }
            "fork_managed_machine" => {
                let p: ManagedActionParams = parse_params(arguments)?;
                self.managed_request(
                    reqwest::Method::POST,
                    format!("/api/managed-machines/{}/fork", urlencoding::encode(&p.machine_id)),
                    Some(json!({"size": p.size, "ttl_minutes": p.ttl_minutes, "reason": p.reason, "owner_mission_id": p.owner_mission_id, "wait": true})),
                )
                .await
            }
            "stop_managed_machine" | "resume_managed_machine" => {
                let p: ManagedActionParams = parse_params(arguments)?;
                let action = if name == "stop_managed_machine" {
                    "stop"
                } else {
                    "resume"
                };
                self.managed_request(
                    reqwest::Method::POST,
                    format!(
                        "/api/managed-machines/{}/{action}",
                        urlencoding::encode(&p.machine_id)
                    ),
                    Some(json!({"ttl_minutes": p.ttl_minutes})),
                )
                .await
            }
            "list_managed_snapshots" | "delete_managed_snapshot" => {
                let p: SnapshotScopeParams = parse_params(arguments)?;
                let mut query = Vec::new();
                if let Some(o) = &p.owner_mission_id {
                    query.push(format!("owner_mission_id={}", urlencoding::encode(o)));
                } else if let Some(pr) = &p.project {
                    query.push(format!("project={}", urlencoding::encode(pr)));
                }
                let q = if query.is_empty() {
                    String::new()
                } else {
                    format!("?{}", query.join("&"))
                };
                if name == "list_managed_snapshots" {
                    self.managed_request(
                        reqwest::Method::GET,
                        format!("/api/managed-machines/snapshots{q}"),
                        None,
                    )
                    .await
                } else {
                    let n = p.name.ok_or("delete_managed_snapshot needs name")?;
                    self.managed_request(
                        reqwest::Method::DELETE,
                        format!(
                            "/api/managed-machines/snapshots/{}{q}",
                            urlencoding::encode(&n)
                        ),
                        None,
                    )
                    .await
                }
            }
            "get_budget" => {
                let params: GetBudgetParams = parse_params(arguments)?;
                let id = params
                    .mission_id
                    .ok_or("get_budget needs mission_id (set automatically for missions)")?;
                self.managed_request(
                    reqwest::Method::GET,
                    format!("/api/control/missions/{}/budget", urlencoding::encode(&id)),
                    None,
                )
                .await
            }
            "destroy_managed_machine" => {
                let params: ManagedIdParams = parse_params(arguments)?;
                self.managed_request(
                    reqwest::Method::DELETE,
                    format!(
                        "/api/managed-machines/{}",
                        urlencoding::encode(&params.machine_id)
                    ),
                    None,
                )
                .await
            }
            "extend_managed_machine" => {
                let params: ManagedIdParams = parse_params(arguments)?;
                self.managed_request(
                    reqwest::Method::POST,
                    format!(
                        "/api/managed-machines/{}/extend",
                        urlencoding::encode(&params.machine_id)
                    ),
                    Some(json!({"ttl_minutes": params.ttl_minutes.unwrap_or(60)})),
                )
                .await
            }
            "list_projects" => self.list_projects().await,
            "get_project" => {
                let params: ProjectSlugParams = parse_params(arguments)?;
                self.get_project(params).await
            }
            "get_situation" => {
                let params: ProjectSlugParams = parse_params(arguments)?;
                self.get_situation(params).await
            }
            "update_project_status" => {
                let params: UpdateProjectStatusParams = parse_params(arguments)?;
                self.update_project_status(params).await
            }
            "set_project_track" => {
                let params: SetProjectTrackParams = parse_params(arguments)?;
                self.set_project_track(params).await
            }
            "accept_project_track" => {
                let params: AcceptProjectTrackParams = parse_params(arguments)?;
                self.accept_project_track(params).await
            }
            "invalidate_project_track_evidence" => {
                let params: InvalidateProjectTrackEvidenceParams = parse_params(arguments)?;
                self.invalidate_project_track_evidence(params).await
            }
            "accept_project_track_evidence" => {
                let params: AcceptProjectTrackEvidenceParams = parse_params(arguments)?;
                self.accept_project_track_evidence(params).await
            }
            "reopen_project_track" => {
                let params: ReopenProjectTrackParams = parse_params(arguments)?;
                self.reopen_project_track(params).await
            }
            "get_project_grant" => {
                let params: ProjectSlugParams = parse_params(arguments)?;
                self.get_project_grant(params).await
            }
            "set_project_grant" => {
                let params: SetProjectGrantParams = parse_params(arguments)?;
                self.set_project_grant(params).await
            }
            "add_project_steer" => {
                let params: AddProjectSteerParams = parse_params(arguments)?;
                self.add_project_steer(params).await
            }
            "record_project_decision" => {
                let params: RecordProjectDecisionParams = parse_params(arguments)?;
                self.record_project_decision(params).await
            }
            "answer_project_decision" => {
                let params: AnswerProjectDecisionParams = parse_params(arguments)?;
                self.answer_project_decision(params).await
            }
            "get_project_tasks" => {
                let params: ProjectSlugParams = parse_params(arguments)?;
                self.get_project_tasks(params).await
            }
            "plan_project_tasks" => {
                let params: PlanProjectTasksParams = parse_params(arguments)?;
                self.plan_project_tasks(params).await
            }
            "update_project_task" => {
                let params: UpdateProjectTaskParams = parse_params(arguments)?;
                self.update_project_task(params).await
            }
            "cancel_project_task" => {
                let params: CancelProjectTaskParams = parse_params(arguments)?;
                self.cancel_project_task(params).await
            }
            "link_mission_to_project" => {
                let params: LinkMissionToProjectParams = parse_params(arguments)?;
                self.link_mission_to_project(params).await
            }
            "list_workspaces" => self.list_workspaces().await,
            "get_workspace" => {
                let params: WorkspaceIdParams = parse_params(arguments)?;
                self.get_workspace(params).await
            }
            "create_workspace" => {
                let params: CreateWorkspaceParams = parse_params(arguments)?;
                self.create_workspace(params).await
            }
            "update_workspace" => {
                let params: UpdateWorkspaceParams = parse_params(arguments)?;
                self.update_workspace(params).await
            }
            "delete_workspace" => {
                let params: DeleteWorkspaceParams = parse_params(arguments)?;
                self.delete_workspace(params).await
            }
            "list_workspace_templates" => self.list_workspace_templates().await,
            "get_workspace_template" => {
                let params: WorkspaceTemplateNameParams = parse_params(arguments)?;
                self.get_workspace_template(params).await
            }
            "save_workspace_template" => {
                let params: SaveWorkspaceTemplateParams = parse_params(arguments)?;
                self.save_workspace_template(params).await
            }
            "delete_workspace_template" => {
                let params: DeleteWorkspaceTemplateParams = parse_params(arguments)?;
                self.delete_workspace_template(params).await
            }
            "rebuild_workspace_from_template" => {
                let params: RebuildWorkspaceFromTemplateParams = parse_params(arguments)?;
                self.rebuild_workspace_from_template(params).await
            }
            "workspace_bash" => {
                let params: WorkspaceBashParams = parse_params(arguments)?;
                self.workspace_bash(params).await
            }
            "start_workspace_job" => {
                let params: StartWorkspaceJobParams = parse_params(arguments)?;
                self.start_workspace_job(params).await
            }
            "get_workspace_job" => {
                let params: WorkspaceJobParams = parse_params(arguments)?;
                self.get_workspace_job(params).await
            }
            "cancel_workspace_job" => {
                let params: WorkspaceJobParams = parse_params(arguments)?;
                self.cancel_workspace_job(params).await
            }
            "get_mission_health" => {
                let params: MissionHealthParams = parse_params(arguments)?;
                self.get_mission_health(params).await
            }
            "get_mission_diagnostics" => {
                let params: MissionDiagnosticsParams = parse_params(arguments)?;
                self.get_mission_diagnostics(params).await
            }
            "update_mission_settings" => {
                let params: UpdateSettingsParams = parse_params(arguments)?;
                self.update_mission_settings(params).await
            }
            "resume_mission" => {
                let params: ResumeMissionParams = parse_params(arguments)?;
                self.resume_mission(params).await
            }
            other => Err(format!("Unknown tool: {other}")),
        }
    }
}

fn parse_uuid(raw: &str) -> Result<Uuid, String> {
    Uuid::parse_str(raw.trim()).map_err(|_| format!("Invalid UUID: {raw}"))
}

fn resolve_default_workspace_id(explicit_workspace_id: Option<String>) -> Option<String> {
    explicit_workspace_id
        .or_else(|| std::env::var("HERMES_DEFAULT_WORKSPACE_ID").ok())
        .or_else(|| std::env::var("ASSISTANT_DEFAULT_WORKSPACE_ID").ok())
        .filter(|value| !value.trim().is_empty())
}

fn compact_compute_fleet(fleet: &Value) -> Value {
    let nodes = fleet
        .get("nodes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let compact_nodes: Vec<Value> = nodes
        .iter()
        .map(|node| {
            json!({
                "id": node.get("id").cloned().unwrap_or(Value::Null),
                "status": node.get("status").cloned().unwrap_or(Value::Null),
                "labels": node.get("labels").cloned().unwrap_or_else(|| json!([])),
                "capacity_total": node.get("capacity_total").cloned().unwrap_or(Value::Null),
                "capacity_available": node.get("capacity_available").cloned().unwrap_or(Value::Null),
                "active_jobs": node.get("active_jobs").cloned().unwrap_or(Value::Null),
                "queued_jobs": node.get("queued_jobs").cloned().unwrap_or(Value::Null),
                "cpu_total": node.get("cpu_total").cloned().unwrap_or(Value::Null),
                "mem_available_bytes": node.get("mem_available_bytes").cloned().unwrap_or(Value::Null),
                "disk_available_bytes": node.get("disk_available_bytes").cloned().unwrap_or(Value::Null),
                "min_free_disk_bytes": node.get("min_free_disk_bytes").cloned().unwrap_or(Value::Null),
                "disk_pressure_pinned": node.get("disk_pressure_pinned").and_then(Value::as_bool).unwrap_or(false),
                "cached_toolchains": node.get("cached_toolchains").cloned().unwrap_or_else(|| json!([])),
                "lean_runtime_ready": node.get("lean_runtime_ready").cloned().unwrap_or(Value::Null),
                "source_bundle_capacity": node.get("source_bundle_capacity").cloned().unwrap_or(Value::Null),
                "error": node.get("error").cloned().unwrap_or(Value::Null),
            })
        })
        .collect();

    let online = nodes
        .iter()
        .filter(|node| node.get("status").and_then(Value::as_str) == Some("online"));
    let online_nodes = online.clone().count();
    let lean_nodes: Vec<&Value> = online
        .filter(|node| {
            node.get("lean_runtime_ready").and_then(Value::as_bool) != Some(false)
                && node.get("disk_pressure_pinned").and_then(Value::as_bool) != Some(true)
                && node
                    .get("labels")
                    .and_then(Value::as_array)
                    .is_some_and(|labels| labels.iter().any(|label| label.as_str() == Some("lean")))
        })
        .collect();
    let lean_slots_total = lean_nodes
        .iter()
        .filter_map(|node| node.get("capacity_total").and_then(Value::as_u64))
        .sum::<u64>();
    let lean_slots_available = lean_nodes
        .iter()
        .filter_map(|node| node.get("capacity_available").and_then(Value::as_u64))
        .sum::<u64>();
    let active_jobs = nodes
        .iter()
        .filter_map(|node| node.get("active_jobs").and_then(Value::as_u64))
        .sum::<u64>();
    let queued_jobs = nodes
        .iter()
        .filter_map(|node| node.get("queued_jobs").and_then(Value::as_u64))
        .sum::<u64>();

    json!({
        "enabled": fleet.get("enabled").cloned().unwrap_or(Value::Bool(false)),
        "summary": {
            "nodes_total": nodes.len(),
            "nodes_online": online_nodes,
            "lean_nodes_online": lean_nodes.len(),
            "lean_slots_total": lean_slots_total,
            "lean_slots_available": lean_slots_available,
            "active_remote_jobs": active_jobs,
            "queued_remote_jobs": queued_jobs,
        },
        "placement_policy": {
            "ordinary_cpu_work": "prefer online non-GPU nodes with immediate capacity, then lowest normalized utilization",
            "gpu_work": "request the gpu label explicitly",
            "parallel_clean_builds": "use distinct missions and verify distinct node/job/head receipts",
            "lean_builds": "workspaces listed under spark_offload.enabled_workspaces can also offload Lean builds to the DGX Spark lane (separate from these nodes)",
        },
        "nodes": compact_nodes,
        "recent_jobs": fleet.get("recent_jobs").cloned().unwrap_or_else(|| json!([])),
        "spark_offload": fleet.get("spark_offload").cloned().unwrap_or(Value::Null),
    })
}

fn compact_mission_summary(mission: Value) -> Value {
    json!({
        "id": mission.get("id").cloned().unwrap_or(Value::Null),
        "title": mission.get("title").cloned().unwrap_or(Value::Null),
        "status": mission.get("status").cloned().unwrap_or(Value::Null),
        "mission_mode": mission.get("mission_mode").cloned().unwrap_or(Value::Null),
        "goal_mode": mission.get("goal_mode").cloned().unwrap_or(Value::Null),
        "goal_objective": compact_opt_text(mission.get("goal_objective"), 1000),
        "backend": mission.get("backend").cloned().unwrap_or(Value::Null),
        "model_override": mission.get("model_override").cloned().unwrap_or(Value::Null),
        "model_effort": mission.get("model_effort").cloned().unwrap_or(Value::Null),
        "fast_mode": mission.get("fast_mode").cloned().unwrap_or(json!(false)),
        "workspace_id": mission.get("workspace_id").cloned().unwrap_or(Value::Null),
        "workspace_name": mission.get("workspace_name").cloned().unwrap_or(Value::Null),
        "short_description": mission.get("short_description").cloned().unwrap_or(Value::Null),
        "updated_at": mission.get("updated_at").cloned().unwrap_or(Value::Null),
        // Project tagging + awaiting classification + staleness anchors so
        // consumers can group/route/triage missions without parsing titles or
        // replaying events.
        "project": mission.get("project").cloned().unwrap_or(Value::Null),
        "track": mission.get("track").cloned().unwrap_or(Value::Null),
        "intent": mission.get("intent").cloned().unwrap_or(Value::Null),
        "github_pr": mission.get("github_pr").cloned().unwrap_or(Value::Null),
        "tags": mission.get("tags").cloned().unwrap_or_else(|| json!([])),
        "desired_state": mission.get("desired_state").cloned().unwrap_or(Value::Null),
        "next_check_at": mission.get("next_check_at").cloned().unwrap_or(Value::Null),
        // Creation provenance. Hermes is what SETS this, and until now could
        // not read it back — so it could not tell which of its own
        // conversations a mission belonged to.
        "origin": mission.get("origin").cloned().unwrap_or(Value::Null),
        "origin_session_id": mission.get("origin_session_id").cloned().unwrap_or(Value::Null),
        "awaiting_kind": mission.get("awaiting_kind").cloned().unwrap_or(Value::Null),
        "last_activity_at": mission.get("last_activity_at").cloned().unwrap_or(Value::Null),
        "last_status_change_at": mission.get("last_status_change_at").cloned().unwrap_or(Value::Null),
    })
}

/// The digest nests project tags; retain the mutation tools' flat summary
/// shape while projecting only fields present in the fresh readback.
fn compact_digest_mission_summary(digest: Value) -> Value {
    let mut mission = digest.get("mission").cloned().unwrap_or(digest);
    if let Some(project) = mission
        .get("project")
        .filter(|value| value.is_object())
        .cloned()
    {
        for key in [
            "project",
            "track",
            "intent",
            "tags",
            "github_pr",
            "desired_state",
            "next_check_at",
        ] {
            mission[key] = project.get(key).cloned().unwrap_or_else(|| {
                // MissionProject omits empty tags during serialization. Keep
                // the existing array contract for an untagged mission.
                if key == "tags" {
                    json!([])
                } else {
                    Value::Null
                }
            });
        }
    }
    // Today's digest does not expose fast_mode. Missing means unknown, not
    // the false default used when projecting a full Mission response.
    let fast_mode = mission.get("fast_mode").cloned().unwrap_or(Value::Null);
    let mut summary = compact_mission_summary(mission);
    summary["fast_mode"] = fast_mode;
    summary
}

/// Verity's HTTP `get_project` is ~120 unabsorbed tracks / ~64KB. Dumping that
/// on every controller tick is what exhausted the bound Hermes session
/// (159,959 tokens, "Cannot compress further"). The dashboard still reads the
/// full HTTP payload; MCP gets a ranked, capped snapshot.
const MCP_PROJECT_ITEM_CAP: usize = 20;
const MCP_PROJECT_ATTEMPT_CAP: usize = 2;
const MCP_PROJECT_DECISION_CAP: usize = 8;
const MCP_PROJECT_TEXT_CAP: usize = 200;

fn attempt_priority(status: &str) -> u8 {
    match status {
        "active" | "starting" | "queued" | "running" => 0,
        "awaiting_user" => 1,
        "paused" => 2,
        "failed" | "interrupted" => 3,
        _ => 4,
    }
}

fn item_status_bucket(item: &Value) -> &'static str {
    let Some(attempts) = item.get("attempts").and_then(Value::as_array) else {
        return "other";
    };
    let best = attempts
        .iter()
        .map(|row| row.get("status").and_then(Value::as_str).unwrap_or(""))
        .min_by_key(|status| attempt_priority(status))
        .unwrap_or("");
    match best {
        "active" | "starting" | "queued" | "running" => "active",
        "awaiting_user" => "awaiting_user",
        "paused" => "paused",
        "failed" => "failed",
        "interrupted" => "interrupted",
        _ => "other",
    }
}

fn item_sort_key(item: &Value) -> (u8, std::cmp::Reverse<String>) {
    let attempts = item.get("attempts").and_then(Value::as_array);
    let best = attempts
        .map(|rows| {
            rows.iter()
                .map(|row| {
                    attempt_priority(row.get("status").and_then(Value::as_str).unwrap_or(""))
                })
                .min()
                .unwrap_or(5)
        })
        .unwrap_or(5);
    let latest = attempts
        .and_then(|rows| rows.first())
        .and_then(|row| row.get("updated_at"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    (best, std::cmp::Reverse(latest))
}

fn compact_opt_text(value: Option<&Value>, max: usize) -> Value {
    match value.and_then(Value::as_str) {
        Some(text) => Value::String(truncate_snippet(text, max)),
        None => Value::Null,
    }
}

fn compact_attempt(attempt: &Value) -> Value {
    json!({
        "id": attempt.get("id").cloned().unwrap_or(Value::Null),
        "status": attempt.get("status").cloned().unwrap_or(Value::Null),
        "title": compact_opt_text(attempt.get("title"), 80),
        "updated_at": attempt.get("updated_at").cloned().unwrap_or(Value::Null),
        "role": attempt.get("role").cloned().unwrap_or(Value::Null),
    })
}

fn compact_item(item: &Value) -> Value {
    let attempts = item
        .get("attempts")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let kept: Vec<Value> = attempts
        .iter()
        .take(MCP_PROJECT_ATTEMPT_CAP)
        .map(compact_attempt)
        .collect();
    let omitted = attempts.len().saturating_sub(kept.len());
    let mut out = json!({
        "key": item.get("key").cloned().unwrap_or(Value::Null),
        "kind": item.get("kind").cloned().unwrap_or(Value::Null),
        "open": item.get("open").cloned().unwrap_or(Value::Null),
        "status": compact_opt_text(item.get("status"), MCP_PROJECT_TEXT_CAP),
        "desired_state": compact_opt_text(item.get("desired_state"), MCP_PROJECT_TEXT_CAP),
        "title": compact_opt_text(item.get("title"), 120),
        "derived_state": item.get("derived_state").cloned().unwrap_or(Value::Null),
        "origin": item.get("origin").cloned().unwrap_or(Value::Null),
        "attempts": kept,
    });
    if omitted > 0 {
        out["attempts_omitted"] = json!(omitted);
    }
    out
}

fn compact_grant(grant: &Value) -> Value {
    if grant.is_null() {
        return Value::Null;
    }
    json!({
        "autonomy_level": grant.get("autonomy_level").cloned().unwrap_or(Value::Null),
        "merge_authority": grant.get("merge_authority").cloned().unwrap_or(Value::Null),
        "budget_per_tick": grant.get("budget_per_tick").cloned().unwrap_or(Value::Null),
        "parallel_missions": grant.get("parallel_missions").cloned().unwrap_or(Value::Null),
        "pause_reason": compact_opt_text(grant.get("pause_reason"), MCP_PROJECT_TEXT_CAP),
        "resume_condition": compact_opt_text(grant.get("resume_condition"), MCP_PROJECT_TEXT_CAP),
    })
}

fn compact_decision(decision: &Value) -> Value {
    json!({
        "at": decision.get("at").cloned().unwrap_or(Value::Null),
        "question": compact_opt_text(decision.get("question"), MCP_PROJECT_TEXT_CAP),
        "status": decision.get("status").cloned().unwrap_or(Value::Null),
        "authority": decision.get("authority").cloned().unwrap_or(Value::Null),
        "kind": decision.get("kind").cloned().unwrap_or(Value::Null),
    })
}

fn compact_project(raw: Value) -> Value {
    let project = raw.get("project").cloned().unwrap_or(json!({}));
    let mut items = raw
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut counts = serde_json::Map::new();
    for item in &items {
        let bucket = item_status_bucket(item).to_string();
        let next = counts.get(&bucket).and_then(Value::as_u64).unwrap_or(0) + 1;
        counts.insert(bucket, json!(next));
    }
    items.sort_by_key(item_sort_key);
    let items_total = items.len();
    let kept_items: Vec<Value> = items
        .iter()
        .take(MCP_PROJECT_ITEM_CAP)
        .map(compact_item)
        .collect();

    let decisions = raw
        .get("open_decisions")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let decisions_total = decisions.len();
    let kept_decisions: Vec<Value> = decisions
        .iter()
        .take(MCP_PROJECT_DECISION_CAP)
        .map(compact_decision)
        .collect();

    let conversation = raw.get("conversation").map(|conversation| {
        json!({
            "session_id": conversation.get("session_id").cloned().unwrap_or(Value::Null),
            "source": conversation.get("source").cloned().unwrap_or(Value::Null),
        })
    });

    json!({
        "slug": project.get("slug").cloned().unwrap_or(Value::Null),
        "title": project.get("title").cloned().unwrap_or(Value::Null),
        "objective": compact_opt_text(project.get("objective"), 400),
        "status": project.get("status").cloned().unwrap_or(Value::Null),
        "mode": project.get("mode").cloned().unwrap_or(Value::Null),
        "wait_ticks": project.get("wait_ticks").cloned().unwrap_or(Value::Null),
        "next_action": compact_opt_text(project.get("next_action"), MCP_PROJECT_TEXT_CAP),
        "blocker": compact_opt_text(project.get("blocker"), MCP_PROJECT_TEXT_CAP),
        "repository": project.get("repository").cloned().unwrap_or(Value::Null),
        "grant": compact_grant(raw.get("grant").unwrap_or(&Value::Null)),
        "items": kept_items,
        "items_total": items_total,
        "items_omitted": items_total.saturating_sub(kept_items.len()),
        "item_counts": counts,
        "summary": raw.get("summary").cloned().unwrap_or(Value::Null),
        "open_decisions": kept_decisions,
        "open_decisions_omitted": decisions_total.saturating_sub(kept_decisions.len()),
        "conversation": conversation,
        "steers": compact_steers(raw.get("steers")),
    })
}

/// The situation is already bounded server-side; only trim prose and cap
/// the item list so a 200-track project cannot flood the controller's turn.
fn compact_situation(raw: Value) -> Value {
    let items = raw
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let items_total = items.len();
    // Dormant absorbed rows are history, not work: hide them from the compact
    // view so an agent never mistakes them for pending items.
    let dormant_hidden = items
        .iter()
        .filter(|item| item.get("derived_state").and_then(Value::as_str) == Some("dormant"))
        .count();
    let kept: Vec<Value> = items
        .iter()
        .filter(|item| item.get("derived_state").and_then(Value::as_str) != Some("dormant"))
        .take(MCP_PROJECT_ITEM_CAP)
        .map(|item| {
            let mut out = json!({
                "key": item.get("key").cloned().unwrap_or(Value::Null),
                "title": compact_opt_text(item.get("title"), 120),
                "derived_state": item.get("derived_state").cloned().unwrap_or(Value::Null),
                "origin": item.get("origin").cloned().unwrap_or(Value::Null),
                "acceptance": item.get("acceptance").cloned().unwrap_or(Value::Null),
                "updated_at": item.get("updated_at").cloned().unwrap_or(Value::Null),
            });
            if let Some(owner) = item.get("owner") {
                out["owner"] = owner.clone();
            }
            if let Some(blocked_by) = item.get("blocked_by") {
                out["blocked_by"] = blocked_by.clone();
            }
            out
        })
        .collect();
    json!({
        "slug": raw.get("slug").cloned().unwrap_or(Value::Null),
        "summary": raw.get("summary").cloned().unwrap_or(Value::Null),
        "items": kept,
        "items_total": items_total,
        "items_omitted": items_total.saturating_sub(kept.len()),
        "dormant_hidden": dormant_hidden,
        "steers": compact_steers(raw.get("steers")),
    })
}

fn compact_steers(raw: Option<&Value>) -> Value {
    let Some(raw) = raw else {
        return json!({ "pending": [], "recent": [] });
    };
    let compact_row = |row: &Value| {
        json!({
            "id": row.get("id").cloned().unwrap_or(Value::Null),
            "body": row.get("body").cloned().unwrap_or(Value::Null),
            "created_at": row.get("created_at").cloned().unwrap_or(Value::Null),
            "consumed_at": row.get("consumed_at").cloned().unwrap_or(Value::Null),
            "origin": row.get("origin").cloned().unwrap_or(Value::Null),
        })
    };
    let pending: Vec<Value> = raw
        .get("pending")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(compact_row)
        .collect();
    let recent: Vec<Value> = raw
        .get("recent")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(compact_row)
        .collect();
    json!({ "pending": pending, "recent": recent })
}

fn truncate_snippet(text: &str, max: usize) -> String {
    let trimmed = text.trim();
    let mut out: String = trimmed.chars().take(max).collect();
    if trimmed.chars().count() > max {
        out.push('…');
    }
    out
}

/// Classify a free-form error/content string into the failure modes a mission
/// babysitter cares about. Mirrors the server's `is_rate_limited_error` /
/// `is_auth_error` / `is_capacity_limited_error` families (see
/// src/api/mission_runner.rs) but works on text we can see from the event
/// stream.
fn error_signals_in(text: &str) -> Vec<&'static str> {
    let lower = text.to_ascii_lowercase();
    // Match complete tokens: mission IDs and hashes often contain HTTP digits.
    let has_code = |code: &str| {
        lower
            .split(|c: char| !c.is_ascii_alphanumeric() && c != '_' && c != '-')
            .any(|token| token == code)
    };
    let mut signals = Vec::new();
    if has_code("429")
        || has_code("529")
        || lower.contains("rate limit")
        || lower.contains("rate-limit")
        || lower.contains("rate_limit")
        || lower.contains("too many requests")
        || lower.contains("overloaded")
        || lower.contains("overloaded_error")
        || lower.contains("resource_exhausted")
        || lower.contains("status code: 429")
        || lower.contains("status code: 529")
        || lower.contains("error: 429")
        || lower.contains("error: 529")
        || lower.contains("hit your limit")
        || lower.contains("hit your usage limit")
        || lower.contains("out of extra usage")
        || lower.contains("out of regular usage")
        || lower.contains("weekly quota exhausted")
        || lower.contains("weekly quota exceeded")
        || lower.contains("weekly limit reached")
        || lower.contains("weekly usage limit reached")
        || lower.contains("purchase more credits")
        || lower.contains("settings/usage")
    {
        signals.push("rate_limited");
    }
    if has_code("401")
        || has_code("403")
        || lower.contains("unauthorized")
        || lower.contains("forbidden")
        || lower.contains("invalid api key")
        || lower.contains("invalid_api_key")
        || lower.contains("authentication")
        || lower.contains("credential")
        || lower.contains("refresh token was already used")
        || lower.contains("refresh_token was already used")
    {
        signals.push("auth_error");
    }
    if lower.contains("capacity")
        || has_code("503")
        || lower.contains("service unavailable")
        || lower.contains("no capacity")
        || lower.contains("already have five missions running")
        || lower.contains("already have 5 missions running")
        || lower.contains("concurrent mission limit")
        || lower.contains("selected model is at capacity")
        || lower.contains("model is at capacity")
    {
        signals.push("capacity_limited");
    }
    if lower.contains("context length")
        || lower.contains("context window")
        || lower.contains("maximum context")
        || lower.contains("context_length_exceeded")
        || lower.contains("token limit")
        || lower.contains("prompt is too long")
    {
        signals.push("context_limit");
    }
    // Network / edge errors: be specific. Bare "timeout" or "idle timeout"
    // (e.g. OpenCode "idle timeout: the model stopped producing output") are
    // harness-level problems, not routing/edge issues. Only tag network_error
    // for clear transport indicators.
    let has_edge_code = ["502", "520", "521", "522"]
        .iter()
        .any(|code| has_code(code));
    let is_transport_timeout = lower.contains("connection timed out")
        || lower.contains("request timed out")
        || lower.contains("read timeout")
        || lower.contains("write timeout")
        || (lower.contains("timed out")
            && (lower.contains("connection")
                || lower.contains("reset")
                || lower.contains("cloudflare")
                || lower.contains("peer")
                || lower.contains("dns")))
        || (lower.contains("timeout")
            && (lower.contains("cloudflare")
                || lower.contains("econn")
                || lower.contains("reset by peer")
                || lower.contains("dns")));
    if lower.contains("cloudflare")
        || lower.contains("connection reset")
        || lower.contains("econnreset")
        || lower.contains("reset by peer")
        || is_transport_timeout
        || has_edge_code
        || lower.contains("dns")
    {
        signals.push("network_error");
    }
    signals
}

#[derive(Default)]
struct TraceAnalysis {
    signals: std::collections::BTreeSet<&'static str>,
    recent_errors: Vec<Value>,
    loop_tool: Option<String>,
    loop_repeats: usize,
    loop_snippet: Option<String>,
    tool_call_count: usize,
}

impl TraceAnalysis {
    fn signals_json(&self) -> Value {
        json!({
            "rate_limited": self.signals.contains("rate_limited"),
            "auth_error": self.signals.contains("auth_error"),
            "capacity_limited": self.signals.contains("capacity_limited"),
            "context_limit": self.signals.contains("context_limit"),
            "network_error": self.signals.contains("network_error"),
            "suspected_loop": self.loop_tool.is_some(),
        })
    }

    fn loop_json(&self) -> Value {
        match &self.loop_tool {
            Some(tool) => json!({
                "tool": tool,
                "repeats": self.loop_repeats,
                "args": self.loop_snippet.clone().unwrap_or_default(),
            }),
            None => Value::Null,
        }
    }
}

/// Scan trace events (ascending) for error signals and looping tool calls.
fn analyze_trace_events(events: &[Value]) -> TraceAnalysis {
    let mut analysis = TraceAnalysis::default();
    let mut repeat_counts: std::collections::BTreeMap<(String, String), usize> =
        std::collections::BTreeMap::new();

    for event in events {
        match event.get("event_type").and_then(Value::as_str) {
            Some("error") => {
                let content = event.get("content").and_then(Value::as_str).unwrap_or("");
                for signal in error_signals_in(content) {
                    analysis.signals.insert(signal);
                }
                // Keep only the last few error snippets to bound output.
                if analysis.recent_errors.len() >= 5 {
                    analysis.recent_errors.remove(0);
                }
                analysis.recent_errors.push(json!({
                    "sequence": event.get("sequence").cloned().unwrap_or(Value::Null),
                    "timestamp": event.get("timestamp").cloned().unwrap_or(Value::Null),
                    "snippet": truncate_snippet(content, 400),
                }));
            }
            Some("tool_call") => {
                analysis.tool_call_count += 1;
                let tool = event
                    .get("tool_name")
                    .and_then(Value::as_str)
                    .unwrap_or("(unknown)")
                    .to_string();
                let args = event
                    .get("content")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string();
                let count = repeat_counts
                    .entry((tool.clone(), args.clone()))
                    .or_insert(0);
                *count += 1;
                // 3+ identical calls (same tool + same args) within the window
                // is a strong loop signal.
                if *count >= 3 && *count > analysis.loop_repeats {
                    analysis.loop_repeats = *count;
                    analysis.loop_tool = Some(tool);
                    analysis.loop_snippet = Some(truncate_snippet(&args, 160));
                }
            }
            _ => {}
        }
    }
    analysis
}

/// Synthesize a single actionable next-step hint for the babysitter.
/// A pending mission waiting for a parallel slot is not stuck and not
/// healthy-and-running: say which missions hold the slots and how to get more.
fn queue_wait_recommendation(status: &str, queue_wait: &Value) -> Option<String> {
    if status != "pending"
        || queue_wait.get("reason").and_then(Value::as_str) != Some("waiting_for_slot")
    {
        return None;
    }
    let used = queue_wait
        .get("slots_used")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let max = queue_wait
        .get("slots_max")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let holders: Vec<&str> = queue_wait
        .get("running_mission_ids")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let held_by = if holders.is_empty() {
        String::new()
    } else {
        format!(" by {}", holders.join(", "))
    };
    Some(format!(
        "Waiting for a free parallel slot ({used}/{max} in use{held_by}). Not stuck: it starts \
         automatically when a slot frees. To run more missions at once, raise \
         max_parallel_missions (PUT /api/settings)."
    ))
}

fn build_recommendation(
    status: &str,
    _backend: Option<&str>,
    live: &Value,
    analysis: &TraceAnalysis,
) -> String {
    let live_state = live.get("state").and_then(Value::as_str);
    if status == "pending"
        && live_state != Some("running")
        && analysis.recent_errors.iter().any(|error| {
            error
                .get("snippet")
                .and_then(Value::as_str)
                .is_some_and(|text| text.contains("queued_assignment_unowned:"))
        })
    {
        return "Queued mission could not acquire its admitted track assignment. Inspect the \
                recorded reader/writer capability and track lease before retrying; the \
                queued_assignment_unowned error does not by itself prove the lease was released."
            .to_string();
    }
    if analysis.signals.contains("rate_limited") || analysis.signals.contains("capacity_limited") {
        return "Provider is rate-limiting or at capacity. Switch to a different backend/provider \
                with update_mission_settings, or wait and resume_mission."
            .to_string();
    }
    if analysis.signals.contains("auth_error") {
        return "Auth/credential failure for this backend. Verify backend auth; switching backend \
                via update_mission_settings may unblock it."
            .to_string();
    }
    if analysis.signals.contains("context_limit") {
        return "Hit the model context limit. Switch to a larger-context backend/model with \
                update_mission_settings, then resume_mission."
            .to_string();
    }
    if analysis.signals.contains("network_error") {
        return "Network/edge errors (e.g. Cloudflare drops, resets, timeouts). Usually transient \
                routing — resume_mission, and if it recurs switch backend with update_mission_settings."
            .to_string();
    }
    if let Some(tool) = &analysis.loop_tool {
        return format!(
            "Agent looks stuck looping on `{tool}` ({}× identical calls). Send a concrete hint \
             with send_message_to_mission, or switch backend/model with update_mission_settings.",
            analysis.loop_repeats
        );
    }

    let health_status = live
        .get("health")
        .and_then(|health| health.get("status"))
        .and_then(Value::as_str);
    let severity = live
        .get("health")
        .and_then(|health| health.get("severity"))
        .and_then(Value::as_str);
    if health_status == Some("stalled") {
        let seconds = live
            .get("seconds_since_activity")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        if severity == Some("severe") {
            return format!(
                "Mission appears severely stalled (no activity for {seconds}s and no live tool). \
                 Consider cancel_mission then resume_mission, or send_message_to_mission with a \
                 concrete next step."
            );
        }
        return format!(
            "Mission is quiet ({seconds}s since last activity) but a tool may still be running. \
             Watch it; only intervene if it stays stalled."
        );
    }

    // Only interrupted/blocked/failed are resumable server-side (see
    // `mission_can_be_resumed` in src/api/control.rs). The other idle
    // statuses need a different intervention.
    if matches!(status, "interrupted" | "blocked" | "failed") {
        return format!(
            "Mission is idle in status '{status}'. If the goal isn't done, resume_mission with a \
             hint to keep going (e.g. 'you still have budget — continue until done, don't stop to ask')."
        );
    }
    if status == "not_feasible" {
        return "Mission concluded the goal is not feasible as specified. This status is not \
                resumable — review the last assistant message, adjust the prompt/goal, and start \
                a new mission or send_message_to_mission once the task is reframed."
            .to_string();
    }
    if matches!(status, "awaiting_user" | "acknowledged") {
        return "Mission finished its turn and is waiting. If the goal isn't fully done, nudge it \
                with send_message_to_mission to continue rather than letting it idle."
            .to_string();
    }

    "No problems detected; mission appears healthy.".to_string()
}

fn is_sensitive_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    key.contains("token")
        || key.contains("secret")
        || key.contains("password")
        || key.contains("api_key")
        || key.contains("apikey")
        || key.contains("authkey")
        || key.contains("private_key")
        || key.contains("credential")
}

fn is_sensitive_value(value: &str) -> bool {
    static CREDENTIAL: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r#"(?i)(?:gh[pousr]_[a-z0-9_]{16,}|github_pat_[a-z0-9_]{16,}|\bsk-[a-z0-9_-]{16,}|\btskey-[a-z0-9_-]+|mcp1\.[a-z0-9_.-]+|\bBearer\s+[^\s"']{8,}|eyJ[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+)"#).unwrap()
    });
    if CREDENTIAL.is_match(value)
        || std::env::vars().any(|(key, secret)| {
            is_sensitive_key(&key) && secret.len() >= 8 && value.contains(&secret)
        })
    {
        return true;
    }
    let trimmed = value.trim();
    trimmed.starts_with("ghp_")
        || trimmed.starts_with("github_pat_")
        || trimmed.starts_with("sk-")
        || trimmed.starts_with("tskey-")
        || trimmed.contains("BEGIN OPENSSH PRIVATE KEY")
        || trimmed.contains("BEGIN PGP PRIVATE KEY")
        || trimmed.contains("<encrypted")
}

fn cancellation_receipt(id: Uuid, receipt: Value) -> Result<Value, String> {
    if receipt["cancel_requested"] == true {
        return Ok(
            json!({"mission_id":id,"cancel_requested":true,"termination_confirmed":false,"next_tool":"get_cloud_execution"}),
        );
    }
    if receipt["ok"] == true && receipt["cancelled"] == id.to_string() {
        // The native actor acknowledges its cancellation token before the
        // runner exits; its historical `cancelled` key is not terminal proof.
        return Ok(
            json!({"mission_id":id,"cancel_requested":true,"termination_confirmed":false,"next_tool":"get_mission_health"}),
        );
    }
    Err("Cancellation outcome is unknown: missing backend confirmation".into())
}

pub(super) fn safe_diagnostic(message: &str) -> String {
    if is_sensitive_value(message) {
        return "Backend diagnostic contained credentials and was withheld".into();
    }
    message.chars().take(2000).collect()
}

pub(super) fn scrub_sensitive_json(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (key, child) in map.iter_mut() {
                if key.eq_ignore_ascii_case("env_vars") {
                    if let Value::Object(env_vars) = child {
                        for env_value in env_vars.values_mut() {
                            *env_value = Value::String("[redacted]".to_string());
                        }
                    } else {
                        *child = Value::String("[redacted]".to_string());
                    }
                } else if child.as_u64().is_some()
                    && matches!(
                        key.as_str(),
                        "input_tokens"
                            | "output_tokens"
                            | "prompt_tokens"
                            | "completion_tokens"
                            | "total_tokens"
                            | "cached_tokens"
                            | "cache_read_input_tokens"
                            | "cache_creation_input_tokens"
                            | "reasoning_tokens"
                            | "inputTokens"
                            | "outputTokens"
                            | "totalTokens"
                            | "cacheReadTokens"
                            | "cacheWriteTokens"
                    )
                {
                    // Numeric usage counters are observability, not credentials.
                    // Keep the exception narrow: strings and arbitrary token keys
                    // must still be redacted, including numeric-looking secrets.
                } else if is_sensitive_key(key) {
                    *child = Value::String("[redacted]".to_string());
                } else {
                    scrub_sensitive_json(child);
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                scrub_sensitive_json(item);
            }
        }
        Value::String(raw) if is_sensitive_value(raw) => {
            *value = Value::String("[redacted]".to_string());
        }
        _ => {}
    }
}

/// Return true when a mission is an ACK-only wait that may transition to
/// `acknowledged`, false when it is already acknowledged, and reject every
/// live or decision-bearing state.
fn mission_requires_acknowledgement(digest: &Value) -> Result<bool, String> {
    let mission = digest.get("mission").unwrap_or(digest);
    let status = mission
        .get("status")
        .and_then(Value::as_str)
        .ok_or_else(|| "Mission digest did not include a status".to_string())?;
    if status == "acknowledged" {
        return Ok(false);
    }

    let awaiting_kind = mission.get("awaiting_kind").and_then(Value::as_str);
    if status == "awaiting_user" && awaiting_kind == Some("ack") {
        return Ok(true);
    }
    // A failed or interrupted attempt is terminal too: acknowledging it is
    // how a controller that relayed the work elsewhere clears the board's
    // "mission … is Failed" reason. Live missions and decision waits stay
    // refused.
    if status == "failed" || status == "interrupted" {
        return Ok(true);
    }

    Err(format!(
        "Mission cannot be ACKed from status={status}, awaiting_kind={}",
        awaiting_kind.unwrap_or("none")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn cancellation_request_does_not_claim_provider_termination() {
        let id = Uuid::new_v4();
        let requested = cancellation_receipt(id, json!({"cancel_requested":true})).unwrap();
        assert_eq!(requested["termination_confirmed"], false);
        assert_eq!(requested["next_tool"], "get_cloud_execution");
        assert!(requested.get("cancelled").is_none());
        let native = cancellation_receipt(id, json!({"ok":true,"cancelled":id})).unwrap();
        assert_eq!(native["termination_confirmed"], false);
        assert_eq!(native["next_tool"], "get_mission_health");
        assert!(native.get("cancelled").is_none());
        assert!(cancellation_receipt(id, json!({})).is_err());
        assert!(cancellation_receipt(id, json!({"ok":true,"cancelled":Uuid::new_v4()})).is_err());
    }

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct MockControl {
        requests: std::sync::Mutex<Vec<(String, Value)>>,
        mission: Value,
        refuse_resume: bool,
    }

    async fn mock_control(
        axum::extract::State(state): axum::extract::State<std::sync::Arc<MockControl>>,
        method: axum::http::Method,
        uri: axum::http::Uri,
        bytes: axum::body::Bytes,
    ) -> (axum::http::StatusCode, axum::Json<Value>) {
        let path = uri.path();
        if method == axum::http::Method::POST {
            let body = serde_json::from_slice(&bytes).unwrap();
            state.requests.lock().unwrap().push((path.into(), body));
            if state.refuse_resume && path.ends_with("/resume") {
                return (
                    axum::http::StatusCode::CONFLICT,
                    axum::Json(json!({"error": "writer_identity_stale"})),
                );
            }
        }
        let value = if path == "/api/control/missions" && method != axum::http::Method::POST {
            json!([state.mission.clone()])
        } else if path.ends_with("/events") || path.ends_with("/running") {
            json!([])
        } else {
            state.mission.clone()
        };
        (axum::http::StatusCode::OK, axum::Json(value))
    }

    async fn mock_assistant(
        mission: Value,
        refuse_resume: bool,
    ) -> (
        AssistantMcp,
        std::sync::Arc<MockControl>,
        tokio::task::JoinHandle<()>,
    ) {
        let state = std::sync::Arc::new(MockControl {
            requests: Default::default(),
            mission,
            refuse_resume,
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = axum::Router::new()
            .fallback(mock_control)
            .with_state(state.clone());
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (
            AssistantMcp {
                api_url: format!("http://{addr}"),
                api_token: None,
                project_scope: None,
                client: reqwest::Client::new(),
            },
            state,
            task,
        )
    }

    #[tokio::test]
    async fn send_message_preserves_authoritative_idle_continuation_receipt() {
        let mission_id = Uuid::new_v4().to_string();
        let reply = json!({
            "id": Uuid::new_v4(), "mission_id": mission_id,
            "queued": true, "message_accepted": true,
            "previous_execution": {"run_id": Uuid::new_v4(), "generation": 7}
        });
        let (mcp, state, server) = mock_assistant(reply.clone(), false).await;
        let result = mcp
            .send_message(
                parse_params(json!({
                    "mission_id": mission_id, "content": "Continue the same work"
                }))
                .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(result, reply);
        let requests = state.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].0, "/api/control/message");
        assert_eq!(requests[0].1["mission_id"], mission_id);
        server.abort();
    }

    #[tokio::test]
    async fn link_project_transports_explicit_reader_and_preserves_omission() {
        let id = Uuid::new_v4().to_string();
        let (mcp, state, server) = mock_assistant(json!({"id": id}), false).await;
        let tool = AssistantMcp::tools()
            .into_iter()
            .find(|tool| tool.name == "link_mission_to_project")
            .unwrap();
        assert_eq!(tool.input_schema["properties"]["writer"]["type"], "boolean");
        for writer in [None, Some(false), Some(true)] {
            let mut input = json!({"mission_id":id,"slug":"lido","track":"review"});
            if let Some(writer) = writer {
                input["writer"] = json!(writer);
            }
            let params = parse_params::<LinkMissionToProjectParams>(input).unwrap();
            mcp.link_mission_to_project(params).await.unwrap();
            let requests = state.requests.lock().unwrap();
            let (path, body) = requests.last().unwrap();
            assert_eq!(path, &format!("/api/control/missions/{id}/project"));
            assert_eq!(body["project"], "lido");
            assert_eq!(body["track"], "review");
            assert_eq!(
                body.get("writer"),
                writer.map(|value| json!(value)).as_ref()
            );
        }
        server.abort();
    }

    #[tokio::test]
    async fn continuation_and_retag_identity_use_one_atomic_resume_request() {
        let id = Uuid::new_v4().to_string();
        let (mcp, state, task) = mock_assistant(json!({"id": id}), false).await;
        for identity in [
            json!({"continue_identity": {"project": null, "track": "trio-reserve1", "github_pr": null}}),
            json!({"github_pr": "", "track": "new-track", "title": "New work"}),
        ] {
            let mut input =
                json!({"mission_id": id, "content": "Continue RESERVE-1 PR 244; exclude PR #230."});
            input
                .as_object_mut()
                .unwrap()
                .extend(identity.as_object().unwrap().clone());
            let result = mcp
                .resume_mission(parse_params(input).unwrap())
                .await
                .unwrap();
            assert_eq!(result["steered"], true);
            let requests = state.requests.lock().unwrap();
            let (path, body) = requests.last().unwrap();
            assert!(path.ends_with("/resume"));
            assert_eq!(body["skip_message"], false);
            assert!(body["content"].as_str().unwrap().contains("PR 244"));
            assert!(!requests
                .iter()
                .any(|(path, _)| path == "/api/control/message"));
            for (key, expected) in identity.as_object().unwrap() {
                assert_eq!(&body[key], expected);
            }
        }
        task.abort();
    }

    #[tokio::test]
    async fn refused_resume_does_not_send_a_steering_message() {
        let id = Uuid::new_v4().to_string();
        let (mcp, state, task) = mock_assistant(json!({"id": id}), true).await;
        let err = mcp
            .resume_mission(
                parse_params(json!({
                    "mission_id": id, "content": "Switch this writer to PR #90",
                }))
                .unwrap(),
            )
            .await
            .unwrap_err();
        assert!(err.contains("writer_identity_stale"));
        let requests = state.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].1["content"], "Switch this writer to PR #90");
        assert!(requests[0].1.get("continue_identity").is_none());
        task.abort();
    }

    #[tokio::test]
    async fn active_pagination_advances_past_empty_pages_without_skipping_matches() {
        async fn page(
            axum::extract::Query(query): axum::extract::Query<
                std::collections::HashMap<String, String>,
            >,
        ) -> axum::Json<Value> {
            let offset: usize = query["offset"].parse().unwrap();
            let limit: usize = query["limit"].parse().unwrap();
            axum::Json(json!((offset..103)
                .take(limit)
                .map(|i| json!({
                    "id":format!("mission-{i}"), "status":if i < 100 {"completed"} else {"active"}
                }))
                .collect::<Vec<_>>()))
        }
        let app = axum::Router::new().route("/api/control/missions", axum::routing::get(page));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let mcp = AssistantMcp::connected(url, "fixture".into());
        let first = mcp
            .list_active_missions(parse_params(json!({"limit":2})).unwrap())
            .await
            .unwrap();
        assert_eq!(first["missions"], json!([]));
        assert_eq!(first["next_offset"], 100);
        let second = mcp
            .list_active_missions(
                parse_params(json!({"limit":2,"offset":first["next_offset"]})).unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(second["missions"].as_array().unwrap().len(), 2);
        assert_eq!(second["next_offset"], 102);
        let third = mcp
            .list_active_missions(
                parse_params(json!({"limit":2,"offset":second["next_offset"]})).unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(third["missions"][0]["id"], "mission-102");
        assert!(third["next_offset"].is_null());
        server.abort();
    }

    #[tokio::test]
    async fn goal_persistence_is_visible_in_get_list_and_health() {
        let id = Uuid::new_v4().to_string();
        for goal_mode in [true, false] {
            let objective = if goal_mode {
                json!("Finish ALLOC-1")
            } else {
                Value::Null
            };
            let (mcp, _, task) = mock_assistant(
                json!({
                    "id": id, "status": "awaiting_user", "mission_mode": "task",
                    "goal_mode": goal_mode, "goal_objective": objective,
                }),
                false,
            )
            .await;
            let get = mcp
                .get_mission(MissionIdParams {
                    mission_id: id.clone(),
                })
                .await
                .unwrap();
            let list = mcp
                .list_missions(parse_params(json!({})).unwrap())
                .await
                .unwrap();
            let health = mcp
                .get_mission_health(MissionHealthParams {
                    mission_id: id.clone(),
                })
                .await
                .unwrap();
            for summary in [&get, &list["missions"][0], &health] {
                assert_eq!(summary["mission_mode"], "task");
                assert_eq!(summary["goal_mode"], goal_mode);
                assert_eq!(summary["goal_objective"], objective);
            }
            task.abort();
        }
        let long = "🦀".repeat(1500);
        let summary = compact_mission_summary(json!({"goal_mode": true, "goal_objective": long}));
        assert_eq!(
            summary["goal_objective"].as_str().unwrap().chars().count(),
            1001
        );
        assert!(summary["goal_objective"].as_str().unwrap().ends_with('…'));
        let legacy = compact_mission_summary(json!({}));
        assert!(
            legacy["goal_mode"].is_null(),
            "missing data must not claim goal mode is disabled"
        );
        assert!(legacy["goal_objective"].is_null());
    }

    #[test]
    fn consult_model_aliases_resolve_unambiguously() {
        let options: Vec<String> = [
            "openai/gpt-6-astra",
            "anthropic/claude-fable-5-1",
            "anthropic/claude-opus-5-5",
            "openrouter/claude-opus-5-5",
            "xai/grok-4.6",
            "grok",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let r = |m: &str| resolve_consult_model(m, &options);
        assert_eq!(r("gpt-6-astra").unwrap(), "openai/gpt-6-astra");
        assert_eq!(r("fable-5.1").unwrap(), "anthropic/claude-fable-5-1");
        assert_eq!(r("FABLE-5-1").unwrap(), "anthropic/claude-fable-5-1");
        assert_eq!(r("openai/gpt-6-astra").unwrap(), "openai/gpt-6-astra");
        assert_eq!(r("grok-4.6").unwrap(), "xai/grok-4.6");
        assert_eq!(r("grok").unwrap(), "grok");
        let ambiguous = r("opus-5.5").unwrap_err();
        assert!(ambiguous.contains("ambiguous"), "{ambiguous}");
        assert!(
            ambiguous.contains("anthropic/claude-opus-5-5"),
            "{ambiguous}"
        );
        assert!(
            ambiguous.contains("openrouter/claude-opus-5-5"),
            "{ambiguous}"
        );
        let unknown = r("gpt-6-nova").unwrap_err();
        assert!(unknown.contains("openai/gpt-6-astra"), "{unknown}");
        assert!(!unknown.contains("fable"), "{unknown}");
        assert!(r("openai/gpt-9").unwrap_err().contains("Unknown model"));
        assert!(r(" ").is_err());
    }

    #[test]
    fn consult_argon_alias_prefers_the_antigravity_pool() {
        let options: Vec<String> = [
            "google/gemini-4-argon",
            "antigravity/gemini-4-argon-low",
            "antigravity/gemini-4-argon-medium",
            "antigravity/gemini-4-argon-high",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        for alias in ["argon", "gemini-4-argon", "Gemini-4-Argon"] {
            assert_eq!(
                resolve_consult_model(alias, &options).unwrap(),
                "antigravity/gemini-4-argon-medium"
            );
        }
        // A full id is kept as given.
        assert_eq!(
            resolve_consult_model("google/gemini-4-argon", &options).unwrap(),
            "google/gemini-4-argon"
        );
        // Without Antigravity, the alias still reaches Google.
        let google_only = vec!["google/gemini-4-argon".to_string()];
        assert_eq!(
            resolve_consult_model("argon", &google_only).unwrap(),
            "google/gemini-4-argon"
        );
    }

    #[test]
    fn consult_prompt_is_read_only_and_lists_files() {
        let prompt = consult_prompt("Is this sound?", &["src/a.rs".into(), " ".into()], true);
        assert!(prompt.contains("read-only"));
        assert!(prompt.contains("- src/a.rs\n"));
        assert!(!prompt.contains("- \n"));
        assert!(!consult_prompt("q", &[], false).contains("read-only"));
    }

    #[tokio::test]
    async fn consult_model_creates_a_read_only_opencode_child() {
        let (assistant, state, task) = mock_assistant(
            json!({
                "id": "11111111-1111-1111-1111-111111111111",
                "status": "pending",
                "backends": {"opencode": [
                    {"value": "openai/gpt-6-astra"},
                    {"value": "anthropic/claude-fable-5-1"}
                ]}
            }),
            false,
        )
        .await;
        let parent = "22222222-2222-2222-2222-222222222222";
        let out = assistant
            .handle_call(
                "consult_model",
                json!({
                    "model": "fable-5.1", "question": "Review the plan",
                    "files": ["docs/plan.md"], "idempotency_key": "k1",
                    "parent_mission_id": parent, "caller": "mission",
                    "project": "orb", "workspace_id": "33333333-3333-3333-3333-333333333333"
                }),
            )
            .await
            .unwrap();
        let unknown = assistant
            .handle_call("consult_model", json!({"model": "gpt-9", "question": "q"}))
            .await
            .unwrap_err();
        task.abort();
        assert_eq!(out["mission_id"], "11111111-1111-1111-1111-111111111111");
        assert_eq!(out["model"], "anthropic/claude-fable-5-1");
        assert!(out["next"].as_str().unwrap().contains("get_consult_result"));
        assert!(unknown.contains("openai/gpt-6-astra"), "{unknown}");
        let requests = state.requests.lock().unwrap();
        assert_eq!(
            requests.len(),
            1,
            "an unknown model never creates a mission"
        );
        let (path, body) = &requests[0];
        assert_eq!(path, "/api/control/missions");
        assert_eq!(body["backend"], "opencode");
        assert_eq!(body["model_override"], "anthropic/claude-fable-5-1");
        assert_eq!(body["writer"], false);
        assert_eq!(body["parent_mission_id"], parent);
        assert_eq!(body["project"], "orb");
        assert_eq!(body["origin"], "mission");
        assert!(body["prompt"].as_str().unwrap().contains("docs/plan.md"));
        assert!(body["tags"]
            .as_array()
            .unwrap()
            .contains(&json!("consult-model")));
    }

    #[tokio::test]
    async fn consult_model_never_waits_and_results_are_polled() {
        let (assistant, state, task) = mock_assistant(
            json!({
                "id": "11111111-1111-1111-1111-111111111111",
                "status": "active",
                "backends": {"opencode": [{"value": "openai/gpt-6-astra"}]}
            }),
            false,
        )
        .await;
        let assistant = std::sync::Arc::new(assistant);
        let waiting = assistant
            .handle_call(
                "consult_model",
                json!({"model": "gpt-6-astra", "question": "q", "wait_secs": 60}),
            )
            .await
            .unwrap_err();
        assert!(waiting.contains("get_consult_result"), "{waiting}");
        // Many concurrent consults all return their handle promptly: nothing
        // sleeps or polls inside the shared action dispatcher.
        let calls = (0..16).map(|i| {
            let assistant = assistant.clone();
            tokio::spawn(async move {
                assistant
                    .handle_call(
                        "consult_model",
                        json!({"model": "gpt-6-astra", "question": "q", "idempotency_key": format!("k{i}")}),
                    )
                    .await
            })
        });
        let results = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            futures::future::join_all(calls),
        )
        .await
        .expect("consult_model must not block");
        for result in results {
            assert_eq!(result.unwrap().unwrap()["status"], "active");
        }
        let running = assistant
            .handle_call(
                "get_consult_result",
                json!({"mission_id": "11111111-1111-1111-1111-111111111111"}),
            )
            .await
            .unwrap();
        task.abort();
        assert_eq!(running["done"], false);
        assert!(running.get("answer").is_none());
        assert_eq!(state.requests.lock().unwrap().len(), 16);
    }

    #[tokio::test]
    async fn single_project_scope_fills_a_missing_project() {
        let (mut assistant, state, task) =
            mock_assistant(json!({"id": "11111111-1111-1111-1111-111111111111"}), false).await;
        assistant.project_scope = Some(["verity".to_string()].into_iter().collect());
        let params = parse_params(json!({"title": "t", "prompt": "p"})).unwrap();
        assistant.start_mission(params).await.unwrap();
        assistant.project_scope = Some(["a".to_string(), "b".to_string()].into_iter().collect());
        let params = parse_params(json!({"title": "t", "prompt": "p"})).unwrap();
        let error = assistant.start_mission(params).await.unwrap_err();
        task.abort();
        assert!(error.contains("project=\"a\""), "{error}");
        assert_eq!(state.requests.lock().unwrap()[0].1["project"], "verity");
    }

    #[tokio::test]
    async fn promoted_codex_goal_is_rejected_before_any_dispatch_request() {
        let (assistant, state, task) = mock_assistant(json!({}), false).await;
        let params = parse_params(json!({
            "title": "oversized native goal", "backend": "codex",
            "writer": true, "prompt": "🦀".repeat(4001),
        }))
        .unwrap();
        let error = assistant.start_mission(params).await.unwrap_err();
        task.abort();
        assert!(error.contains("4000"), "{error}");
        assert!(state.requests.lock().unwrap().is_empty());
    }

    #[test]
    fn diagnostic_projection_deduplicates_text_bytes_and_raw_output() {
        let receipt = json!({
            "content": [{"type": "content", "content": {"type": "text", "text": "done\n"}}],
            "rawOutput": {"stdout": {"type": "Buffer", "data": [100,111,110,101,10]}, "stderr": "warning"}
        }).to_string();
        assert_eq!(diagnostic_result_snippet(&receipt), "done\n\nwarning");
        assert!(receipt.contains("rawOutput"));
        assert_eq!(diagnostic_result_snippet("plain result"), "plain result");
        assert_eq!(
            diagnostic_result_snippet(r#"{"exitCode":2}"#),
            r#"{"exitCode":2}"#
        );
    }

    #[test]
    fn dispatch_tools_declare_and_parse_the_same_identity_contract() {
        for tool in AssistantMcp::tools().into_iter().filter(|t| {
            matches!(
                t.name.as_str(),
                "send_message_to_mission" | "resume_mission"
            )
        }) {
            assert_eq!(
                tool.input_schema["properties"]["continue_identity"],
                dispatch_identity_schema()
            );
            for field in ["github_pr", "track", "title"] {
                assert_eq!(tool.input_schema["properties"][field]["type"], "string");
            }
        }
        let incomplete = json!({"mission_id": "m", "content": "continue", "continue_identity": {"track": "trio-reserve1"}});
        assert!(parse_params::<SendMessageParams>(incomplete.clone()).is_err());
        assert!(parse_params::<ResumeMissionParams>(incomplete).is_err());
    }

    #[test]
    fn writers_are_goal_mode_even_when_controller_omits_prefix() {
        assert_eq!(
            writer_goal_prompt("finish the PR".into(), true),
            "/goal finish the PR"
        );
        assert_eq!(
            writer_goal_prompt("  /goal finish the PR".into(), true),
            "  /goal finish the PR"
        );
        assert_eq!(
            writer_goal_prompt("review the PR".into(), false),
            "review the PR"
        );
    }

    /// `adopt_mission` without a stamped session must refuse, not clear.
    #[test]
    fn adopt_without_a_session_is_refused() {
        let params: AdoptMissionParams =
            parse_params(json!({"mission_id": "57c1dfb4"})).expect("parse");
        assert!(params.origin_session_id.is_none());
        // The handler itself needs a live API to run; pin the refusal message
        // contract here instead: an empty stamp must not silently clear.
        let session = params
            .origin_session_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty());
        assert!(session.is_none(), "an absent stamp must read as absent");
    }

    #[test]
    fn adopt_params_accept_the_stamped_shape() {
        let params: AdoptMissionParams = parse_params(json!({
            "mission_id": "57c1dfb4-a782-4010-9f8b-aaa7f88afa7e",
            "origin_session_id": "20260805_190902_361101",
        }))
        .expect("parse");
        assert_eq!(
            params.origin_session_id.as_deref(),
            Some("20260805_190902_361101")
        );
        assert!(valid_origin_session_id(
            params.origin_session_id.as_deref().unwrap()
        ));
    }

    /// The 2026-08-05 incident: seven identical retries in ninety seconds,
    /// because the error named no field.
    #[test]
    fn a_params_error_names_the_offending_field() {
        let arguments = json!({
            "title": "t",
            "prompt": "p",
            "desired_state": {"status": "running"},
        });
        let error = parse_params::<StartMissionParams>(arguments)
            .expect_err("a map where a string belongs must not deserialize");
        assert!(
            error.contains("desired_state"),
            "the field must be named, got: {error}"
        );
        assert!(error.contains("invalid type: map"), "got: {error}");
    }

    #[test]
    fn a_nested_field_reports_its_path() {
        let arguments = json!({"title": "t", "prompt": "p", "tags": ["ok", {"a": 1}]});
        let error = parse_params::<StartMissionParams>(arguments).expect_err("a map is not a tag");
        assert!(error.contains("tags[1]"), "got: {error}");
    }

    #[test]
    fn a_missing_required_field_is_named_too() {
        let error = parse_params::<StartMissionParams>(json!({"title": "t"}))
            .expect_err("prompt is required");
        assert!(error.contains("prompt"), "got: {error}");
    }

    #[test]
    fn valid_params_still_deserialize() {
        let params: StartMissionParams =
            parse_params(json!({"title": "t", "prompt": "p", "tags": ["a"]}))
                .expect("valid arguments must parse");
        assert_eq!(params.title, "t");
        assert_eq!(params.tags.as_deref(), Some(&["a".to_string()][..]));
    }

    /// Arguments that are not an object at all have no field to name, and a
    /// bare "." would be noise rather than information.
    #[test]
    fn a_root_level_failure_reports_no_path() {
        let error = parse_params::<StartMissionParams>(json!("not an object"))
            .expect_err("a string is not a params object");
        assert!(
            error.starts_with("Invalid params: invalid type"),
            "got: {error}"
        );
    }

    /// A tool description is the only thing an autonomous agent knows about
    /// what a tool can do. When it understates the tool, the agent reasons
    /// correctly from wrong premises and gives up.
    ///
    /// That is not hypothetical. `resume_mission` said "interrupted, blocked,
    /// or failed" and `send_message_to_mission` said only "Send a follow-up
    /// message", so a controller holding an `acknowledged` mission concluded
    /// it could not be woken at all and reported the benchmark campaign
    /// blocked — while the server would have activated it on the same id.
    #[test]
    fn the_wake_tool_advertises_every_status_it_actually_wakes() {
        let tools = AssistantMcp::tools();
        let send = tools
            .iter()
            .find(|t| t.name == "send_message_to_mission")
            .expect("send_message_to_mission is registered");

        // These are exactly the statuses `message_activates_mission` accepts.
        // If that list grows, this description has to grow with it.
        for status in [
            "pending",
            "awaiting_user",
            "acknowledged",
            "waiting_background",
            "interrupted",
            "blocked",
            "completed",
            "failed",
        ] {
            assert!(
                send.description.contains(status),
                "send_message_to_mission wakes `{status}` but does not say so; \
                 an agent reading this will believe it cannot: {}",
                send.description
            );
        }

        // And the recovery tool must not read as the only way to wake a
        // mission, which is the inference that cost the benchmark track.
        let resume = tools
            .iter()
            .find(|t| t.name == "resume_mission")
            .expect("resume_mission is registered");
        assert!(
            resume.description.contains("send_message_to_mission"),
            "resume_mission should point at the normal wake path: {}",
            resume.description
        );
    }

    /// The binary's tool table IS the curated Hermes surface; the generated
    /// config allowlists are pinned to `HERMES_ASSISTANT_TOOL_ALLOWLIST`.
    /// Adding/removing a tool here must go through the canonical list.
    /// A full UUID must resolve without a round trip: no HTTP client is
    /// configured in tests, so any network attempt would fail here.
    #[tokio::test]
    async fn full_uuid_resolves_without_calling_the_server() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        clear_env();
        let mcp = AssistantMcp::connected("http://127.0.0.1:1".into(), "fixture".into());
        let id = Uuid::new_v4();
        assert_eq!(
            mcp.resolve_mission_id(&id.to_string())
                .await
                .expect("resolve"),
            id
        );
        // Mixed case with surrounding whitespace is the shape humans paste.
        assert_eq!(
            mcp.resolve_mission_id(&format!("  {}  ", id.to_string().to_uppercase()))
                .await
                .expect("resolve"),
            id
        );
    }

    async fn exercise_resume_readback(
        with_hint: bool,
        with_tags: bool,
        resume_status: axum::http::StatusCode,
        readback_status: axum::http::StatusCode,
        fast_mode: Option<bool>,
    ) -> (Result<Value, String>, Vec<String>) {
        use axum::{
            extract::State,
            routing::{get, post},
            Json, Router,
        };
        use std::sync::{Arc, Mutex};

        #[derive(Clone)]
        struct Fixture {
            id: Uuid,
            with_hint: bool,
            with_tags: bool,
            resume_status: axum::http::StatusCode,
            readback_status: axum::http::StatusCode,
            fast_mode: Option<bool>,
            calls: Arc<Mutex<Vec<String>>>,
        }
        async fn resume(
            State(state): State<Fixture>,
            Json(body): Json<Value>,
        ) -> (axum::http::StatusCode, Json<Value>) {
            assert_eq!(body["skip_message"], false);
            if state.with_hint {
                assert_eq!(body["content"], "Continue the existing proof");
            } else {
                assert!(body["content"].is_null());
            }
            state.calls.lock().unwrap().push("resume".into());
            (
                state.resume_status,
                Json(json!({"id": state.id, "status": "interrupted", "updated_at": "before"})),
            )
        }
        async fn readback(State(state): State<Fixture>) -> (axum::http::StatusCode, Json<Value>) {
            state.calls.lock().unwrap().push("readback".into());
            let status = if state.resume_status.is_success() {
                "active"
            } else {
                "interrupted"
            };
            let mut digest = json!({
                "id": state.id, "status": status, "updated_at": "after",
                "backend": "grok", "model_override": "verified-model",
                "project": {"project": "example", "track": "existing", "intent": "implementation", "tags": ["example"],
                    "github_pr": "https://github.com/example/repo/pull/1",
                    "desired_state": "running", "next_check_at": "later"}
            });
            if !state.with_tags {
                digest["project"].as_object_mut().unwrap().remove("tags");
            }
            if let Some(fast_mode) = state.fast_mode {
                digest["fast_mode"] = json!(fast_mode);
            }
            (state.readback_status, Json(digest))
        }
        let fixture = Fixture {
            id: Uuid::new_v4(),
            with_hint,
            with_tags,
            resume_status,
            readback_status,
            fast_mode,
            calls: Arc::new(Mutex::new(Vec::new())),
        };
        let router = Router::new()
            .route("/api/control/missions/:id/resume", post(resume))
            .route("/api/control/missions/:id/digest", get(readback))
            .with_state(fixture.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let api_url = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        let mcp = AssistantMcp {
            api_url,
            api_token: None,
            project_scope: None,
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(5))
                .build()
                .unwrap(),
        };
        let result = mcp
            .resume_mission(ResumeMissionParams {
                mission_id: fixture.id.to_string(),
                identity: Default::default(),
                clean_workspace: false,
                content: with_hint.then(|| "Continue the existing proof".to_string()),
            })
            .await;
        server.abort();
        let calls = fixture.calls.lock().unwrap().clone();
        (result, calls)
    }

    #[tokio::test]
    async fn resume_reads_state_after_atomic_resume_with_hint() {
        use axum::http::StatusCode;
        let (result, calls) =
            exercise_resume_readback(true, true, StatusCode::OK, StatusCode::OK, None).await;
        let result = result.expect("accepted resume");
        assert_eq!(calls, ["resume", "readback"]);
        assert_eq!(result["mission"]["status"], "active");
        assert_eq!(result["mission"]["updated_at"], "after");
        assert_eq!(result["mission"]["project"], "example");
        assert_eq!(result["mission"]["track"], "existing");
        assert_eq!(
            result["mission"]["github_pr"],
            "https://github.com/example/repo/pull/1"
        );
        assert_eq!(result["mission"]["desired_state"], "running");
        assert_eq!(result["mission"]["next_check_at"], "later");
        assert!(result["mission"]["fast_mode"].is_null());
        assert_eq!(result["steered"], true);
        assert!(result["state_warning"].is_null());
    }

    #[tokio::test]
    async fn resume_without_hint_also_returns_fresh_state() {
        use axum::http::StatusCode;
        let (result, calls) =
            exercise_resume_readback(false, true, StatusCode::OK, StatusCode::OK, None).await;
        let result = result.expect("accepted resume");
        assert_eq!(calls, ["resume", "readback"]);
        assert_eq!(result["mission"]["updated_at"], "after");
        assert_eq!(result["steered"], false);
        assert!(result["steer_warning"].is_null());
    }

    #[tokio::test]
    async fn resume_refusal_does_not_read_or_claim_current_state() {
        use axum::http::StatusCode;
        let (result, calls) =
            exercise_resume_readback(true, true, StatusCode::CONFLICT, StatusCode::OK, None).await;
        assert_eq!(calls, ["resume"]);
        assert!(result
            .unwrap_err()
            .contains("Failed to resume mission (409"));
    }

    #[tokio::test]
    async fn resume_readback_failure_does_not_return_the_old_snapshot() {
        use axum::http::StatusCode;
        let (result, calls) = exercise_resume_readback(
            true,
            true,
            StatusCode::OK,
            StatusCode::SERVICE_UNAVAILABLE,
            None,
        )
        .await;
        let result = result.expect("accepted resume");
        assert_eq!(calls, ["resume", "readback"]);
        assert_eq!(result["resume_accepted"], true);
        assert_eq!(result["steered"], true);
        assert!(result["mission"].is_null());
        assert!(result["state_warning"]
            .as_str()
            .unwrap()
            .contains("do not repeat"));
    }

    #[tokio::test]
    async fn resume_preserves_fast_mode_when_readback_exposes_it() {
        use axum::http::StatusCode;
        for enabled in [true, false] {
            let (result, _) =
                exercise_resume_readback(true, true, StatusCode::OK, StatusCode::OK, Some(enabled))
                    .await;
            let result = result.expect("accepted resume");
            assert_eq!(result["mission"]["fast_mode"], enabled);
        }
    }

    #[tokio::test]
    async fn resume_untagged_digest_preserves_empty_array() {
        use axum::http::StatusCode;
        let (result, _) =
            exercise_resume_readback(true, false, StatusCode::OK, StatusCode::OK, None).await;
        let result = result.expect("accepted resume");
        assert_eq!(result["mission"]["tags"], json!([]));
        assert!(result["mission"]["tags"].is_array());
    }

    #[test]
    fn compact_summary_exposes_creation_origin() {
        let summary = compact_mission_summary(json!({
            "id": "11111111-2222-3333-4444-555555555555",
            "status": "active",
            "origin": "hermes",
            "origin_session_id": "20260804_103847_86ca5c",
            "prompt": "secret",
            "api_token": "secret",
        }));
        assert_eq!(summary["origin"], "hermes");
        assert_eq!(summary["origin_session_id"], "20260804_103847_86ca5c");
        // The summary stays a projection, not a passthrough.
        assert!(summary.get("prompt").is_none());
        assert!(summary.get("api_token").is_none());
    }

    fn seeded_event(
        sequence: i64,
        event_type: &str,
        tool_name: Option<&str>,
        tool_call_id: Option<&str>,
        content: &str,
    ) -> Value {
        json!({
            "sequence": sequence,
            "event_type": event_type,
            "tool_name": tool_name,
            "tool_call_id": tool_call_id,
            "content": content,
        })
    }

    #[test]
    fn pending_question_lookup_finds_unanswered_call() {
        let events = vec![
            seeded_event(1, "user_message", None, None, "go"),
            // An older, already-answered question must NOT be pending.
            seeded_event(
                2,
                "tool_call",
                Some("AskUserQuestion"),
                Some("q-old"),
                r#"{"questions":[{"question":"Old?"}]}"#,
            ),
            seeded_event(
                3,
                "tool_result",
                Some("AskUserQuestion"),
                Some("q-old"),
                r#"{"answers":[["A"]]}"#,
            ),
            // An ordinary in-flight tool call is not a question.
            seeded_event(4, "tool_call", Some("Bash"), Some("b-1"), r#"{"cmd":"x"}"#),
            seeded_event(
                5,
                "tool_call",
                Some("AskUserQuestion"),
                Some("q-new"),
                r#"{"questions":[{"question":"Deploy to prod?"},{"question":"Which region?"}]}"#,
            ),
        ];
        let pending = pending_ask_user_questions(&events);
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].tool_call_id, "q-new");
        assert_eq!(pending[0].sequence, 5);
        assert_eq!(pending[0].summary(), "Deploy to prod? | Which region?");
    }

    #[test]
    fn pending_question_lookup_orders_newest_first_and_survives_bad_args() {
        let events = vec![
            // Unparseable args must still surface the pending call.
            seeded_event(
                1,
                "tool_call",
                Some("AskUserQuestion"),
                Some("q-1"),
                "not json",
            ),
            seeded_event(
                7,
                "tool_call",
                Some("AskUserQuestion"),
                Some("q-2"),
                r#"{"questions":[{"question":"Second?"}]}"#,
            ),
        ];
        let pending = pending_ask_user_questions(&events);
        assert_eq!(
            pending
                .iter()
                .map(|q| q.tool_call_id.as_str())
                .collect::<Vec<_>>(),
            vec!["q-2", "q-1"]
        );
        assert_eq!(pending[1].summary(), "(question text unavailable)");
    }

    #[test]
    fn pending_question_lookup_empty_when_all_answered() {
        let events = vec![
            seeded_event(
                1,
                "tool_call",
                Some("AskUserQuestion"),
                Some("q-1"),
                r#"{"questions":[{"question":"Only?"}]}"#,
            ),
            seeded_event(
                2,
                "tool_result",
                None,
                Some("q-1"),
                r#"{"answers":[["A"]]}"#,
            ),
        ];
        assert!(pending_ask_user_questions(&events).is_empty());
    }

    #[test]
    fn answer_mission_question_params_parse_with_and_without_tool_call_id() {
        let params: AnswerMissionQuestionParams = parse_params(json!({
            "mission_id": "abc",
            "answers": [["Option A"], ["free text"]],
        }))
        .expect("parse without tool_call_id");
        assert!(params.tool_call_id.is_none());
        assert_eq!(params.answers, vec![vec!["Option A"], vec!["free text"]]);

        let params: AnswerMissionQuestionParams = parse_params(json!({
            "mission_id": "abc",
            "tool_call_id": "q-1",
            "answers": [["Yes"]],
        }))
        .expect("parse with tool_call_id");
        assert_eq!(params.tool_call_id.as_deref(), Some("q-1"));
    }

    const ENV_KEYS: &[&str] = &[
        "HERMES_SANDBOXED_API_URL",
        "SANDBOXED_API_URL",
        "OPEN_AGENT_API_URL",
        "HERMES_SANDBOXED_API_TOKEN",
        "SANDBOXED_API_TOKEN",
        "OPEN_AGENT_API_TOKEN",
        "JWT_SECRET",
        "HERMES_DEFAULT_WORKSPACE_ID",
        "ASSISTANT_DEFAULT_WORKSPACE_ID",
    ];

    fn clear_env() {
        for key in ENV_KEYS {
            std::env::remove_var(key);
        }
    }

    #[test]
    fn compact_mission_summary_keeps_only_hermes_safe_fields() {
        let summary = compact_mission_summary(json!({
            "id": "mission-1",
            "title": "Fix the build",
            "status": "active",
            "mission_mode": "default",
            "backend": "codex",
            "model_override": "gpt-5.6-sol",
            "workspace_id": "workspace-1",
            "workspace_name": "assistant",
            "short_description": "Build fix",
            "updated_at": "2026-05-28T12:00:00Z",
            "project": "verity-core",
            "track": "C3-bridge-collapse",
            "github_pr": "lfglabs-dev/verity#2070",
            "tags": ["c3", "sprint-2"],
            "desired_state": "waiting_ci",
            "awaiting_kind": "decision",
            "prompt": "secret prompt",
            "api_token": "sk-test",
        }));

        assert_eq!(summary["id"], "mission-1");
        assert_eq!(summary["workspace_name"], "assistant");
        assert_eq!(summary["project"], "verity-core");
        assert_eq!(summary["track"], "C3-bridge-collapse");
        assert_eq!(summary["github_pr"], "lfglabs-dev/verity#2070");
        assert_eq!(summary["desired_state"], "waiting_ci");
        assert_eq!(summary["tags"][1], "sprint-2");
        assert_eq!(summary["awaiting_kind"], "decision");
        // Missions without tags get an empty array, not null.
        let bare = compact_mission_summary(json!({"id": "m2"}));
        assert_eq!(bare["tags"], json!([]));
        assert!(summary.get("prompt").is_none());
        assert!(summary.get("api_token").is_none());
    }

    #[test]
    fn scrub_sensitive_json_redacts_nested_keys_and_token_values() {
        let mut value = json!({
            "mission": {
                "title": "Hermes",
                "api_key": "sk-test",
                "notes": ["visible", "github_pat_123"],
                "env_vars": {
                    "DATABASE_URL": "postgres://user:password@example.test/db",
                    "AWS_ACCESS_KEY_ID": "not-matched-by-value-heuristics",
                    "PATH": "/usr/local/bin:/usr/bin"
                }
            },
            "token": "plain-token"
        });

        scrub_sensitive_json(&mut value);

        assert_eq!(value["mission"]["title"], "Hermes");
        assert_eq!(value["mission"]["api_key"], "[redacted]");
        assert_eq!(value["mission"]["notes"][0], "visible");
        assert_eq!(value["mission"]["notes"][1], "[redacted]");
        assert_eq!(value["mission"]["env_vars"]["DATABASE_URL"], "[redacted]");
        assert_eq!(
            value["mission"]["env_vars"]["AWS_ACCESS_KEY_ID"],
            "[redacted]"
        );
        assert_eq!(value["mission"]["env_vars"]["PATH"], "[redacted]");
        assert_eq!(value["token"], "[redacted]");
    }

    #[test]
    fn scrubbing_preserves_numeric_usage_without_exposing_token_credentials() {
        let mut value = json!({
            "usage": {"input_tokens": 100, "output_tokens": 12, "cached_tokens": 80, "cacheReadTokens": 70},
            "token": 123456,
            "access_token": 123456,
            "prompt_tokens": "123456",
            "env_vars": {"output_tokens": 123456}
        });
        scrub_sensitive_json(&mut value);
        assert_eq!(
            value["usage"],
            json!({"input_tokens":100,"output_tokens":12,"cached_tokens":80,"cacheReadTokens":70})
        );
        for key in ["token", "access_token", "prompt_tokens"] {
            assert_eq!(value[key], "[redacted]");
        }
        assert_eq!(value["env_vars"]["output_tokens"], "[redacted]");
    }

    #[test]
    fn diagnostics_redact_embedded_credentials_and_bound_error_text() {
        for value in [
            "remote rejected https://ghp_012345678901234567890123456789@example.invalid/repo",
            "request failed: Bearer fixture-private-credential",
            "failed session mcp1.header.payload.signature",
        ] {
            assert_eq!(
                safe_diagnostic(value),
                "Backend diagnostic contained credentials and was withheld"
            );
            let mut log = json!({"output":value});
            scrub_sensitive_json(&mut log);
            assert_eq!(log["output"], "[redacted]");
        }
        assert_eq!(safe_diagnostic("backend missing"), "backend missing");
        assert_eq!(safe_diagnostic(&"é".repeat(3000)).chars().count(), 2000);
    }

    #[test]
    fn explicit_workspace_id_takes_precedence_over_default_envs() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_env();
        std::env::set_var("HERMES_DEFAULT_WORKSPACE_ID", "hermes-workspace");
        std::env::set_var("ASSISTANT_DEFAULT_WORKSPACE_ID", "assistant-workspace");

        let workspace_id = resolve_default_workspace_id(Some("tool-workspace".to_string()));

        assert_eq!(workspace_id.as_deref(), Some("tool-workspace"));
        clear_env();
    }

    #[test]
    fn hermes_default_workspace_env_takes_precedence_over_legacy_name() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_env();
        std::env::set_var("HERMES_DEFAULT_WORKSPACE_ID", "hermes-workspace");
        std::env::set_var("ASSISTANT_DEFAULT_WORKSPACE_ID", "assistant-workspace");

        let workspace_id = resolve_default_workspace_id(None);

        assert_eq!(workspace_id.as_deref(), Some("hermes-workspace"));
        clear_env();
    }

    #[test]
    fn legacy_default_workspace_env_remains_supported_for_compatibility() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_env();
        std::env::set_var("ASSISTANT_DEFAULT_WORKSPACE_ID", "assistant-workspace");

        let workspace_id = resolve_default_workspace_id(None);

        assert_eq!(workspace_id.as_deref(), Some("assistant-workspace"));
        clear_env();
    }

    #[test]
    fn native_agent_names_select_the_matching_backend() {
        assert_eq!(
            native_backend_from_agent(Some("codex")).as_deref(),
            Some("codex")
        );
        assert_eq!(
            native_backend_from_agent(Some(" ClaudeCode ")).as_deref(),
            Some("claudecode")
        );
        assert_eq!(native_backend_from_agent(Some("build")), None);
        assert_eq!(native_backend_from_agent(None), None);
    }

    #[test]
    fn error_signals_do_not_classify_mission_identifiers_as_http_errors() {
        for fragment in [
            "b522", "a502", "a520", "a521", "a503", "a429", "a529", "401", "403",
        ] {
            assert!(error_signals_in(&format!(
                "Parallel mission {fragment}0000-dc42-49c3-88a0-26934b2255ce cancellation requested"
            ))
            .is_empty());
        }
        for code in ["502", "520", "521", "522"] {
            assert!(error_signals_in(&format!("HTTP {code}: upstream failed"))
                .contains(&"network_error"));
        }
    }

    #[test]
    fn error_signals_classify_known_failure_modes() {
        assert_eq!(
            error_signals_in("HTTP 429 Too Many Requests"),
            vec!["rate_limited"]
        );
        assert_eq!(
            error_signals_in("Error: 401 Unauthorized invalid api key"),
            vec!["auth_error"]
        );
        assert!(
            error_signals_in("context_length_exceeded: prompt is too long")
                .contains(&"context_limit")
        );
        assert!(error_signals_in("cloudflare 520: connection reset").contains(&"network_error"));
        assert!(error_signals_in("all good here").is_empty());

        // 529 and "hit your limit" family (server-side rate limit markers)
        assert!(error_signals_in("error: 529 overloaded").contains(&"rate_limited"));
        assert!(error_signals_in("status code: 529").contains(&"rate_limited"));
        assert!(
            error_signals_in("You've hit your limit · resets Jun 10, 5pm (Europe/Berlin)")
                .contains(&"rate_limited")
        );
        assert!(error_signals_in(
            "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage"
        )
        .contains(&"rate_limited"));

        // Harness-level idle timeouts are NOT network errors (they are local model/harness stalls)
        let idle = error_signals_in("OpenCode idle timeout: the model stopped producing output before finishing the turn. Partial output was discarded because it was incomplete.");
        assert!(
            !idle.contains(&"network_error"),
            "idle timeout must not be misclassified as network_error: {idle:?}"
        );
        // But real transport timeouts still are
        assert!(
            error_signals_in("connection timed out while talking to provider")
                .contains(&"network_error")
        );
    }

    #[test]
    fn analyze_trace_detects_repeated_tool_loop() {
        let events: Vec<Value> = (0..4)
            .map(|i| {
                json!({
                    "sequence": i,
                    "event_type": "tool_call",
                    "tool_name": "read_file",
                    "content": "{\"path\":\"main.rs\"}"
                })
            })
            .collect();
        let analysis = analyze_trace_events(&events);
        assert_eq!(analysis.loop_tool.as_deref(), Some("read_file"));
        assert_eq!(analysis.loop_repeats, 4);
        assert_eq!(analysis.tool_call_count, 4);
    }

    #[test]
    fn analyze_trace_collects_error_signals() {
        let events = vec![
            json!({"sequence": 1, "event_type": "error", "content": "provider 429 rate limit"}),
            json!({"sequence": 2, "event_type": "tool_call", "tool_name": "run_command", "content": "ls"}),
        ];
        let analysis = analyze_trace_events(&events);
        assert!(analysis.signals.contains("rate_limited"));
        assert_eq!(analysis.recent_errors.len(), 1);
        assert!(analysis.loop_tool.is_none());
    }

    #[test]
    fn recommendation_explains_a_pending_mission_waiting_for_a_slot() {
        let wait = json!({
            "reason": "waiting_for_slot",
            "slots_used": 1,
            "slots_max": 1,
            "running_mission_ids": ["6d25e770-cae3-4606-8a99-850ab70710ec"],
        });
        let rec = queue_wait_recommendation("pending", &wait).expect("slot wait");
        assert!(rec.contains("Waiting for a free parallel slot (1/1 in use by 6d25e770"));
        assert!(rec.contains("max_parallel_missions"));
        assert!(!rec.contains("healthy"));
        // Once it starts, or with no capacity data, the normal checks apply.
        assert!(queue_wait_recommendation("active", &wait).is_none());
        assert!(queue_wait_recommendation("pending", &Value::Null).is_none());
    }

    #[test]
    fn recommendation_reports_pending_assignment_failure_without_poisoning_active_run() {
        let analysis = analyze_trace_events(&[json!({
            "event_type":"error", "sequence":3,
            "content":"Cannot activate mission: queued_assignment_unowned: original track claim is no longer held"
        })]);
        let pending = build_recommendation("pending", None, &Value::Null, &analysis);
        assert!(pending.contains("Queued mission could not acquire"));
        assert!(!pending.contains("healthy"));
        let active = build_recommendation("active", None, &json!({"state":"running"}), &analysis);
        assert!(!active.contains("Queued mission could not acquire"));
        let starting =
            build_recommendation("pending", None, &json!({"state":"running"}), &analysis);
        assert!(!starting.contains("Queued mission could not acquire"));
        let ordinary_pending =
            build_recommendation("pending", None, &Value::Null, &TraceAnalysis::default());
        assert!(!ordinary_pending.contains("Queued mission could not acquire"));
    }

    #[test]
    fn recommendation_prioritizes_rate_limit_over_loop() {
        let mut analysis = TraceAnalysis::default();
        analysis.signals.insert("rate_limited");
        analysis.loop_tool = Some("read_file".to_string());
        analysis.loop_repeats = 5;
        let rec = build_recommendation("active", None, &Value::Null, &analysis);
        assert!(rec.contains("rate-limiting") || rec.contains("capacity"));
    }

    #[test]
    fn recommendation_flags_severe_stall() {
        let analysis = TraceAnalysis::default();
        let live = json!({
            "seconds_since_activity": 600,
            "health": {"status": "stalled", "severity": "severe"}
        });
        let rec = build_recommendation("active", None, &live, &analysis);
        assert!(rec.contains("stalled"));
    }

    #[test]
    fn recommendation_does_not_recommend_resume_for_not_feasible() {
        // not_feasible is not resumable server-side (see mission_can_be_resumed
        // in src/api/control.rs). The recommendation must steer the babysitter
        // away from calling resume_mission, otherwise it gets a hard failure.
        let analysis = TraceAnalysis::default();
        let rec = build_recommendation("not_feasible", None, &Value::Null, &analysis);
        assert!(
            !rec.contains("resume_mission with a hint"),
            "recommendation must not suggest resume_mission for not_feasible, got: {rec}"
        );
        assert!(
            rec.contains("not feasible") || rec.contains("not_feasible"),
            "recommendation should explain the status, got: {rec}"
        );
    }

    #[test]
    fn recommendation_still_recommends_resume_for_resumable_statuses() {
        for status in ["interrupted", "blocked", "failed"] {
            let analysis = TraceAnalysis::default();
            let rec = build_recommendation(status, None, &Value::Null, &analysis);
            assert!(
                rec.contains("resume_mission"),
                "expected resume_mission recommendation for status {status}, got: {rec}"
            );
        }
    }

    #[test]
    fn output_dir_accepts_paths_under_tmp() {
        let mission_id = Uuid::nil();
        let dir = output_dir_for_shared_file(&mission_id, Some("/tmp/artifacts".to_string()))
            .expect("plain /tmp path is allowed");
        assert!(dir.starts_with("/tmp/artifacts"));
    }

    #[test]
    fn output_dir_rejects_parent_traversal_and_non_tmp_paths() {
        let mission_id = Uuid::nil();
        // `/tmp/../etc` passes a lexical starts_with("/tmp") but resolves
        // outside the real /tmp tree — must be rejected.
        assert!(output_dir_for_shared_file(&mission_id, Some("/tmp/../etc".to_string())).is_err());
        assert!(
            output_dir_for_shared_file(&mission_id, Some("/tmp/a/../../etc".to_string())).is_err()
        );
        // Sibling prefixes and plainly foreign roots are rejected too.
        assert!(output_dir_for_shared_file(&mission_id, Some("/tmpdir/x".to_string())).is_err());
        assert!(output_dir_for_shared_file(&mission_id, Some("/var/tmp".to_string())).is_err());
        // Relative paths are rejected.
        assert!(output_dir_for_shared_file(&mission_id, Some("tmp/x".to_string())).is_err());
    }

    #[test]
    fn workspace_management_tools_are_exposed_with_destructive_confirmations() {
        let tools = AssistantMcp::tools();
        let names: Vec<_> = tools.iter().map(|tool| tool.name.as_str()).collect();
        assert!(names.contains(&"get_compute_fleet"));
        for expected in [
            "get_workspace",
            "create_workspace",
            "update_workspace",
            "delete_workspace",
            "list_workspace_templates",
            "get_workspace_template",
            "save_workspace_template",
            "delete_workspace_template",
            "rebuild_workspace_from_template",
            "start_workspace_job",
            "get_workspace_job",
            "cancel_workspace_job",
        ] {
            assert!(names.contains(&expected), "missing tool {expected}");
        }

        for destructive in [
            "delete_workspace",
            "delete_workspace_template",
            "rebuild_workspace_from_template",
        ] {
            let schema = &tools
                .iter()
                .find(|tool| tool.name == destructive)
                .unwrap()
                .input_schema;
            assert!(schema["required"]
                .as_array()
                .unwrap()
                .contains(&json!("confirm")));
        }
    }

    #[test]
    fn project_roster_tools_are_exposed() {
        let tools = AssistantMcp::tools();
        let names: Vec<_> = tools.iter().map(|tool| tool.name.as_str()).collect();
        for expected in [
            "list_projects",
            "get_project",
            "update_project_status",
            "set_project_track",
            "accept_project_track",
            "invalidate_project_track_evidence",
            "accept_project_track_evidence",
            "reopen_project_track",
            "get_project_grant",
            "set_project_grant",
            "add_project_steer",
            "record_project_decision",
            "answer_project_decision",
            "get_project_tasks",
            "plan_project_tasks",
            "update_project_task",
            "cancel_project_task",
            "link_mission_to_project",
        ] {
            assert!(names.contains(&expected), "missing project tool {expected}");
        }
        // The ledger tool exposes the authority split, and the grant tool the
        // normalized autonomy level — controllers discover both from schema.
        let decision = tools
            .iter()
            .find(|tool| tool.name == "record_project_decision")
            .unwrap();
        let authorities = decision.input_schema["properties"]["authority"]["enum"]
            .as_array()
            .unwrap();
        assert!(authorities.contains(&json!("granted")));
        let grant = tools
            .iter()
            .find(|tool| tool.name == "set_project_grant")
            .unwrap();
        let levels = grant.input_schema["properties"]["autonomy_level"]["enum"]
            .as_array()
            .unwrap();
        assert!(levels.contains(&json!("act_reversible")));
        // The status tool constrains mode to the three known regimes.
        let status = tools
            .iter()
            .find(|tool| tool.name == "update_project_status")
            .unwrap();
        let modes = status.input_schema["properties"]["mode"]["enum"]
            .as_array()
            .unwrap();
        assert!(modes.contains(&json!("blocked")));
    }

    #[test]
    fn mission_tools_expose_codex_fast_mode() {
        let tools = AssistantMcp::tools();
        assert!(!tools
            .iter()
            .any(|tool| tool.name == "get_chatgpt_ui_pool_status"));
        for name in ["start_mission", "update_mission_settings"] {
            let schema = &tools
                .iter()
                .find(|tool| tool.name == name)
                .unwrap_or_else(|| panic!("missing tool {name}"))
                .input_schema;
            assert_eq!(schema["properties"]["fast_mode"]["type"], "boolean");
        }
    }

    #[test]
    fn workspace_job_argv_is_quoted() {
        assert_eq!(
            workspace_job_command(None, Some(vec!["printf".into(), "%s".into(), "a'b".into()]))
                .unwrap(),
            "'printf' '%s' 'a'\\''b'"
        );
        assert!(workspace_job_command(Some("true".into()), Some(vec!["true".into()])).is_err());
    }

    #[tokio::test]
    async fn workspace_diagnostics_do_not_classify_quoted_command_text() {
        let workspace_id = Uuid::new_v4().to_string();
        let (mcp, state, task) = mock_assistant(json!({"exit_code": 0}), false).await;
        let command = "ps -eo pid,args | rg 'lake build|cargo test --all'";
        mcp.workspace_bash(
            parse_params(json!({
                "workspace_id": workspace_id, "command": command, "timeout_secs": 1000
            }))
            .unwrap(),
        )
        .await
        .unwrap();
        let requests = state.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(
            requests[0].0,
            format!("/api/workspaces/{workspace_id}/exec")
        );
        assert_eq!(requests[0].1["command"], command);
        assert_eq!(requests[0].1["timeout_secs"], 120);
        task.abort();
    }

    #[tokio::test]
    async fn workspace_durable_execution_routes_each_call_with_the_same_retry_key() {
        let mission_id = Uuid::new_v4().to_string();
        let workspace_id = Uuid::new_v4().to_string();
        let (mcp, state, task) =
            mock_assistant(json!({"id": mission_id, "status": "queued"}), false).await;
        // A build and an unrecognizable script use exactly the same durable route.
        for (index, command) in ["lake build Target", "./long-running-script"]
            .iter()
            .enumerate()
        {
            for _ in 0..2 {
                let result = mcp.workspace_bash(parse_params(json!({
                    "workspace_id": workspace_id, "mission_id": mission_id,
                    "idempotency_key": format!("build-input-sha-{index}"), "command": command,
                    "cwd": "/workspaces/proof"
                })).unwrap()).await.unwrap();
                assert_eq!(result["job"]["id"], mission_id);
            }
        }
        let requests = state.requests.lock().unwrap();
        assert_eq!(requests.len(), 4);
        for (index, (path, body)) in requests.iter().enumerate() {
            assert_eq!(path, "/api/durable-jobs");
            assert_eq!(
                body["idempotency_key"],
                format!("build-input-sha-{}", index / 2)
            );
            assert_eq!(body["started_by_mission_id"], mission_id);
            assert_eq!(body["workspace_id"], workspace_id);
            assert_eq!(body["cwd"], "/workspaces/proof");
            assert_eq!(body["timeout_secs"], 7200);
        }
        task.abort();
    }

    #[tokio::test]
    async fn workspace_partial_durable_ownership_never_executes_a_command() {
        let (mcp, state, task) = mock_assistant(json!({}), false).await;
        for fields in [
            json!({"mission_id": Uuid::new_v4().to_string()}),
            json!({"idempotency_key": "input-sha"}),
            json!({"mission_id": "", "idempotency_key": "input-sha"}),
            json!({"mission_id": Uuid::new_v4().to_string(), "idempotency_key": " "}),
        ] {
            let mut input = fields;
            input["command"] = json!("./long-running-script");
            assert!(mcp
                .workspace_bash(parse_params(input).unwrap())
                .await
                .is_err());
        }
        assert!(state.requests.lock().unwrap().is_empty());
        task.abort();
    }

    #[tokio::test]
    async fn workspace_durable_execution_respects_project_scope_on_both_entrypoints() {
        let mission_id = Uuid::new_v4().to_string();
        let workspace_id = Uuid::new_v4().to_string();
        for project in [json!("eip-8282"), Value::Null, json!("verity-lido")] {
            let (mut mcp, state, task) = mock_assistant(
                json!({
                    "id": mission_id, "project": project
                }),
                false,
            )
            .await;
            mcp.project_scope = Some(["verity-lido".to_string()].into_iter().collect());
            let input = json!({
                "workspace_id": workspace_id, "mission_id": mission_id,
                "idempotency_key": "same-command", "command": "./build"
            });
            let via_bash = mcp
                .workspace_bash(parse_params(input.clone()).unwrap())
                .await;
            let direct = mcp.start_workspace_job(parse_params(input).unwrap()).await;
            let allowed = project == json!("verity-lido");
            assert_eq!(via_bash.is_ok(), allowed);
            assert_eq!(direct.is_ok(), allowed);
            assert_eq!(
                state.requests.lock().unwrap().len(),
                if allowed { 2 } else { 0 }
            );
            task.abort();
        }
    }

    #[test]
    fn compute_fleet_summary_is_compact_and_capacity_aware() {
        let raw = json!({
            "enabled": true,
            "nodes": [
                {
                    "id": "cpu",
                    "status": "online",
                    "labels": ["lean"],
                    "capacity_total": 2,
                    "capacity_available": 1,
                    "active_jobs": 1,
                    "queued_jobs": 0,
                    "cpu_total": 8,
                    "mem_available_bytes": 32_u64 << 30,
                    "disk_available_bytes": 100_u64 << 30,
                    "min_free_disk_bytes": 30_u64 << 30,
                    "disk_pressure_pinned": false,
                    "cached_toolchains": ["leanprover--lean4---v4.24.0"],
                    "lean_runtime_ready": true,
                    "source_bundle_capacity": {"overlay_bytes": 1048576, "complete_bytes": 8388608},
                    "base_url": "must-not-leak"
                },
                {
                    "id": "general",
                    "status": "online",
                    "labels": ["general"],
                    "capacity_total": 1,
                    "capacity_available": 1,
                    "active_jobs": 0,
                    "queued_jobs": 0,
                    "lean_runtime_ready": false
                },
                {
                    "id": "gpu-only",
                    "status": "online",
                    "labels": ["gpu"],
                    "capacity_total": 4,
                    "capacity_available": 4,
                    "active_jobs": 0,
                    "queued_jobs": 0,
                    "lean_runtime_ready": true,
                    "error": "probe degraded"
                },
                {
                    "id": "legacy-lean",
                    "status": "online",
                    "labels": ["lean"],
                    "capacity_total": 1,
                    "capacity_available": 1,
                    "active_jobs": 0,
                    "queued_jobs": 0
                }
            ],
            "recent_jobs": [{"job_id": "job", "node_id": "cpu", "state": "succeeded"}]
        });

        let compact = compact_compute_fleet(&raw);
        assert_eq!(compact["summary"]["nodes_online"], 4);
        assert_eq!(compact["summary"]["lean_nodes_online"], 2);
        assert_eq!(compact["summary"]["lean_slots_total"], 3);
        assert_eq!(compact["summary"]["lean_slots_available"], 2);
        assert_eq!(compact["summary"]["active_remote_jobs"], 1);
        assert!(compact["nodes"][0].get("base_url").is_none());
        assert_eq!(
            compact["nodes"][0]["source_bundle_capacity"]["complete_bytes"],
            8388608
        );
        assert_eq!(compact["nodes"][0]["min_free_disk_bytes"], 30_u64 << 30);
        assert_eq!(compact["nodes"][0]["disk_pressure_pinned"], false);
        assert!(compact["nodes"][3]["source_bundle_capacity"].is_null());
        assert!(compact["nodes"][3]["min_free_disk_bytes"].is_null());
        assert_eq!(compact["nodes"][2]["error"], "probe degraded");
        assert_eq!(compact["recent_jobs"][0]["node_id"], "cpu");
    }

    #[test]
    fn compact_project_ranks_live_items_and_caps_the_dump() {
        let mut items = Vec::new();
        for i in 0..30 {
            items.push(json!({
                "key": format!("old-{i}"),
                "kind": "track",
                "open": true,
                "status": "failed",
                "desired_state": "x".repeat(400),
                "attempts": [{
                    "id": format!("fail-{i}"),
                    "status": "failed",
                    "title": "old failure",
                    "updated_at": format!("2026-08-01T00:{i:02}:00Z"),
                    "role": "pr-writer",
                    "prompt": "secret"
                }]
            }));
        }
        items.push(json!({
            "key": "live-writer",
            "kind": "track",
            "open": true,
            "status": "working",
            "attempts": [
                {
                    "id": "live-1",
                    "status": "active",
                    "title": "Grok #2332",
                    "updated_at": "2026-08-14T20:00:00Z",
                    "role": "pr-writer"
                },
                {
                    "id": "live-old",
                    "status": "interrupted",
                    "title": "previous",
                    "updated_at": "2026-08-14T18:00:00Z"
                },
                {
                    "id": "live-older",
                    "status": "failed",
                    "title": "older",
                    "updated_at": "2026-08-14T16:00:00Z"
                }
            ]
        }));
        items.push(json!({
            "key": "needs-owner",
            "kind": "track",
            "open": true,
            "attempts": [{
                "id": "ask-1",
                "status": "awaiting_user",
                "title": "question",
                "updated_at": "2026-08-14T19:00:00Z"
            }]
        }));

        let compact = compact_project(json!({
            "project": {
                "slug": "verity",
                "title": "Verity",
                "objective": "prove the world",
                "status": "active",
                "mode": "active",
                "wait_ticks": 2,
                "next_action": "rebase/repair #2332 onto main after #2333",
                "blocker": "source #2332 dirty",
                "repository": "lfglabs-dev/verity",
                "created_at": "2026-01-01T00:00:00Z",
                "updated_at": "2026-08-14T20:00:00Z"
            },
            "grant": {
                "autonomy_level": "act_full",
                "merge_authority": "full",
                "budget_per_tick": "generous",
                "material_bar": "omit me",
                "answered_at": "2026-08-01T00:00:00Z"
            },
            "tracks": [{"track": "noise", "status": "done", "updated_at": "2026-01-01T00:00:00Z"}],
            "items": items,
            "open_decisions": [{
                "at": "2026-08-14T12:00:00Z",
                "question": "merge #69?",
                "status": "pending_user",
                "authority": "escalation",
                "rationale": "long rationale that controllers do not need here"
            }],
            "recent_decisions": [{"at": "2026-07-01T00:00:00Z", "question": "old"}],
            "conversation": {
                "session_id": "20260813_213628_202eac",
                "source": "binding",
                "bound_at": "2026-08-13T20:57:04Z"
            },
            "steers": {
                "pending": [{
                    "id": "steer-1",
                    "body": format!("look at {}", "notes/".repeat(80)),
                    "created_at": "2026-09-21T11:00:00Z",
                    "origin": "orb"
                }],
                "recent": []
            }
        }));

        assert_eq!(compact["slug"], "verity");
        assert_eq!(compact["mode"], "active");
        assert_eq!(
            compact["next_action"],
            "rebase/repair #2332 onto main after #2333"
        );
        assert_eq!(compact["items_total"], 32);
        assert_eq!(compact["items_omitted"], 12);
        assert_eq!(compact["items"].as_array().unwrap().len(), 20);
        assert_eq!(compact["items"][0]["key"], "live-writer");
        assert_eq!(compact["items"][1]["key"], "needs-owner");
        assert_eq!(compact["items"][0]["attempts"].as_array().unwrap().len(), 2);
        assert_eq!(compact["items"][0]["attempts_omitted"], 1);
        assert_eq!(compact["item_counts"]["active"], 1);
        assert_eq!(compact["item_counts"]["awaiting_user"], 1);
        assert_eq!(compact["item_counts"]["failed"], 30);
        assert_eq!(compact["grant"]["autonomy_level"], "act_full");
        assert!(compact["grant"].get("material_bar").is_none());
        assert!(compact.get("tracks").is_none());
        assert!(compact.get("recent_decisions").is_none());
        assert!(compact["open_decisions"][0].get("rationale").is_none());
        assert_eq!(
            compact["conversation"]["session_id"],
            "20260813_213628_202eac"
        );
        assert!(compact["conversation"].get("bound_at").is_none());
        assert!(compact["items"][0]["attempts"][0].get("prompt").is_none());
        let desired = compact["items"][2]["desired_state"].as_str().unwrap();
        assert!(desired.chars().count() <= 201, "{desired}");
        assert!(desired.ends_with('…'));
        assert_eq!(compact["steers"]["pending"][0]["id"], "steer-1");
        let body = compact["steers"]["pending"][0]["body"].as_str().unwrap();
        assert_eq!(
            body,
            format!("look at {}", "notes/".repeat(80)),
            "operator instructions must not be truncated"
        );
    }

    #[test]
    fn mission_events_default_to_the_newest_bounded_page() {
        let id = Uuid::nil();
        let newest = mission_events_path(id, 40, "all", None, None);
        assert!(newest.ends_with(&format!("&before_seq={}", i64::MAX)));

        let delta = mission_events_path(id, 40, "all", None, Some(17));
        assert!(delta.ends_with("&since_seq=17"));
        assert!(!delta.contains("before_seq"));

        let backwards = mission_events_path(id, 40, "all", Some(99), Some(17));
        assert!(backwards.ends_with("&before_seq=99"));
        assert!(!backwards.contains("since_seq"));
    }

    #[test]
    fn project_scope_gates_mutations_only() {
        let scoped = AssistantMcp {
            api_url: "http://127.0.0.1:3000".to_string(),
            api_token: None,
            project_scope: Some(["verity".to_string()].into_iter().collect()),
            client: reqwest::Client::new(),
        };
        assert!(scoped.assert_project_scope("verity").is_ok());
        assert!(
            scoped.assert_project_scope(" verity ").is_ok(),
            "slugs are trimmed"
        );
        let err = scoped.assert_project_scope("lido").unwrap_err();
        assert!(err.contains("outside this controller's scope"), "{err}");

        let open = AssistantMcp {
            api_url: "http://127.0.0.1:3000".to_string(),
            api_token: None,
            project_scope: None,
            client: reqwest::Client::new(),
        };
        assert!(open.assert_project_scope("anything").is_ok());
    }

    #[test]
    fn mission_started_children_are_not_attributed_to_hermes() {
        // Real case 26e6bbcd: an OpenCode mission started a subagent on a
        // managed machine and the child was stamped origin:hermes-assistant.
        let tags = mission_start_tags(
            "origin:mission",
            Some(vec!["origin:hermes-assistant".into(), "pr-readonly".into()]),
            false,
            false,
            None,
            None,
        )
        .unwrap();
        assert_eq!(tags, vec!["pr-readonly", "origin:mission"]);
        let params: StartMissionParams = serde_json::from_value(json!({
            "title": "t", "prompt": "p", "caller": "mission",
            "parent_mission_id": "3a510e9b-31f3-4331-b334-d0fb6fbc8e67"
        }))
        .unwrap();
        assert_eq!(params.caller.as_deref(), Some("mission"));
        assert!(params.parent_mission_id.is_some());
    }

    #[test]
    fn mission_start_tags_record_hermes_merge_authority() {
        let grant = MergeGrantConfig {
            authority_source: "owner-standing-grant-2026-07-29".to_string(),
            repositories: vec!["lfglabs-dev/*".to_string()],
        };
        let tags = mission_start_tags(
            "origin:hermes-assistant",
            Some(vec![
                "verity".to_string(),
                " origin:hermes-assistant ".to_string(),
            ]),
            true,
            true,
            Some("lfglabs-dev/verity#2209"),
            Some(&grant),
        )
        .unwrap();

        assert_eq!(
            tags,
            vec![
                "verity",
                "origin:hermes-assistant",
                "merge-authority:granted",
                "merge-authority-source:owner-standing-grant-2026-07-29",
                "merge-authority-target:lfglabs-dev/verity#2209"
            ]
        );
    }

    #[test]
    fn mission_start_tags_reject_ambiguous_merge_authority() {
        let grant = MergeGrantConfig {
            authority_source: "owner-grant".to_string(),
            repositories: vec!["owner/repo".to_string()],
        };
        assert!(mission_start_tags(
            "origin:hermes-assistant",
            None,
            true,
            true,
            Some("owner/repo#1"),
            None
        )
        .is_err());
        assert!(mission_start_tags(
            "origin:hermes-assistant",
            None,
            true,
            true,
            Some("owner/repo"),
            Some(&grant)
        )
        .is_err());
        assert!(mission_start_tags(
            "origin:hermes-assistant",
            None,
            true,
            true,
            Some("other/repo#1"),
            Some(&grant)
        )
        .is_err());
        assert!(mission_start_tags(
            "origin:hermes-assistant",
            None,
            true,
            false,
            Some("owner/repo#1"),
            Some(&grant)
        )
        .is_err());
        let tags = mission_start_tags(
            "origin:hermes-assistant",
            Some(vec![
                "merge-authority:granted".to_string(),
                "merge-authority-source:spoofed".to_string(),
            ]),
            false,
            false,
            Some("owner/repo#1"),
            Some(&grant),
        )
        .unwrap();
        assert!(!tags.iter().any(|tag| tag.starts_with("merge-authority:")));
    }

    #[test]
    fn origin_session_ids_are_validated_not_silently_dropped() {
        assert!(valid_origin_session_id("20260803_150605_59ab72"));
        assert!(valid_origin_session_id("agent:main:telegram:dm:1139694048"));
        // A blank or malformed id must not pass as "no origin": the mission
        // would complete with nowhere to report back to.
        assert!(!valid_origin_session_id(""));
        assert!(!valid_origin_session_id("   ".trim()));
        assert!(!valid_origin_session_id("bad session id"));
        assert!(!valid_origin_session_id(&"x".repeat(129)));
    }

    #[test]
    fn mission_acknowledgement_accepts_only_ack_waits_and_is_idempotent() {
        assert!(mission_requires_acknowledgement(&json!({
            "status": "awaiting_user",
            "awaiting_kind": "ack"
        }))
        .unwrap());
        assert!(!mission_requires_acknowledgement(&json!({
            "mission": {
                "status": "acknowledged",
                "awaiting_kind": null
            }
        }))
        .unwrap());
        assert!(mission_requires_acknowledgement(&json!({
            "status": "awaiting_user",
            "awaiting_kind": "decision"
        }))
        .is_err());
        assert!(mission_requires_acknowledgement(&json!({
            "status": "active",
            "awaiting_kind": null
        }))
        .is_err());
        assert!(mission_requires_acknowledgement(&json!({
            "status": "failed",
            "awaiting_kind": null
        }))
        .unwrap());
        assert!(mission_requires_acknowledgement(&json!({
            "status": "interrupted",
            "awaiting_kind": null
        }))
        .unwrap());
    }

    #[test]
    fn create_workspace_body_omits_unspecified_defaults_and_keeps_false() {
        let params: CreateWorkspaceParams = serde_json::from_value(json!({
            "name": "  hermes-test  ",
            "shared_network": false,
            "mcps": []
        }))
        .unwrap();

        let body = create_workspace_body(params).unwrap();

        assert_eq!(body["name"], "hermes-test");
        assert_eq!(body["shared_network"], false);
        assert_eq!(body["mcps"], json!([]));
        assert!(body.get("workspace_type").is_none());
        assert!(body.get("skills").is_none());
    }

    #[test]
    fn update_workspace_body_requires_a_change_and_preserves_explicit_empty_values() {
        let id = Uuid::new_v4();
        let empty: UpdateWorkspaceParams =
            serde_json::from_value(json!({"workspace_id": id})).unwrap();
        assert!(update_workspace_body(empty).is_err());

        let params: UpdateWorkspaceParams = serde_json::from_value(json!({
            "workspace_id": id,
            "skills": [],
            "shared_network": false,
            "config_profile": ""
        }))
        .unwrap();
        let (parsed_id, body) = update_workspace_body(params).unwrap();
        assert_eq!(parsed_id, id);
        assert_eq!(body["skills"], json!([]));
        assert_eq!(body["shared_network"], false);
        assert_eq!(body["config_profile"], "");
    }

    #[test]
    fn template_patch_preserves_omitted_fields_and_replaces_supplied_fields() {
        let mut current = json!({
            "description": "existing",
            "skills": ["old"],
            "env_vars": {"TOKEN": "secret"},
            "mcps_replace_defaults": true
        })
        .as_object()
        .unwrap()
        .clone();
        let params: SaveWorkspaceTemplateParams = serde_json::from_value(json!({
            "name": "lean",
            "skills": ["lean", "github"],
            "mcps_replace_defaults": false
        }))
        .unwrap();

        apply_template_patch(&mut current, params).unwrap();

        assert_eq!(current["description"], "existing");
        assert_eq!(current["env_vars"]["TOKEN"], "secret");
        assert_eq!(current["skills"], json!(["lean", "github"]));
        assert_eq!(current["mcps_replace_defaults"], false);
    }
}

/// Parse `auto-managed`, `auto-managed:<size>`, `auto-managed:<provider>`, or
/// `auto-managed:<provider>:<size>` into `(provider, size)`.
fn parse_auto_managed_spec(raw: &str) -> Option<(Option<String>, Option<String>)> {
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

/// `list_managed_machines` summary: live machines with the fields an agent
/// needs, plus the budget block (the full list was ~60 KB and truncated).
fn compact_managed_list(list: &Value) -> Value {
    let machines: Vec<Value> = list["machines"]
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter(|m| !matches!(m["state"].as_str(), Some("destroyed") | Some("failed")))
                .map(|m| {
                    json!({
                        "name": m["name"],
                        "id": m["id"],
                        "node_id": m["node_id"],
                        "provider": m["provider"],
                        "size": m["size"],
                        "state": m["state"],
                        "project": m["project"],
                        "owner_mission_id": m["owner_mission_id"],
                        "active_mission_ids": m["active_mission_ids"],
                        "expires_at": m["expires_at"],
                        "reap_at": m["reap_at"],
                        "reap_reason": m["reap_reason"],
                        "deletable_at": m["deletable_at"],
                        "cost_usd": m["cost_usd"],
                        "budget_pool_id": m["budget_pool_id"],
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let today = list["daily_spend"]
        .as_array()
        .and_then(|d| d.last())
        .map(|d| d["usd"].clone())
        .unwrap_or(Value::Null);
    json!({
        "enabled": list["enabled"],
        "providers": list["providers"],
        "machines": machines,
        "budget": list["budget"],
        "spend_today_usd": today,
        "hint": "verbose=true for full rows and history; get_budget for your mission's budget pool",
    })
}

#[cfg(test)]
mod compact_managed_tests {
    use serde_json::json;

    #[test]
    fn compact_list_keeps_live_summary_rows_only() {
        let full = json!({
            "enabled": true,
            "providers": [{"provider": "boat", "configured": true}],
            "machines": [
                {"name": "small-a", "id": "mm1", "provider": "boat", "state": "online", "size": "small",
                 "cpu": 2, "error": null, "reason": "long text"},
                {"name": "", "id": "mm0", "provider": "hetzner", "state": "destroyed", "size": "cpx41"}
            ],
            "budget": {"spent_today_usd": 0.1},
            "daily_spend": [{"day": "2026-10-23", "usd": 1.0}, {"day": "2026-10-24", "usd": 0.25}],
            "sizes": [{"size": "small"}],
        });
        let c = super::compact_managed_list(&full);
        assert_eq!(c["machines"].as_array().unwrap().len(), 1);
        assert_eq!(c["machines"][0]["name"], "small-a");
        assert_eq!(c["machines"][0]["provider"], "boat");
        assert!(c["machines"][0].get("reason").is_none());
        assert_eq!(c["spend_today_usd"], 0.25);
        assert_eq!(c["providers"][0]["provider"], "boat");
        assert!(c.get("sizes").is_none());
    }

    #[test]
    fn parse_auto_managed_spec_handles_legacy_and_multi_provider_forms() {
        use super::parse_auto_managed_spec;
        assert_eq!(parse_auto_managed_spec("static-node-1"), None);
        assert_eq!(parse_auto_managed_spec("auto-managed"), Some((None, None)));
        assert_eq!(
            parse_auto_managed_spec("auto-managed:large"),
            Some((None, Some("large".into())))
        );
        assert_eq!(
            parse_auto_managed_spec("auto-managed:hetzner"),
            Some((Some("hetzner".into()), None))
        );
        assert_eq!(
            parse_auto_managed_spec("auto-managed:hetzner:cpx41"),
            Some((Some("hetzner".into()), Some("cpx41".into())))
        );
        assert_eq!(
            parse_auto_managed_spec("auto-managed:vastai:rtx4090"),
            Some((Some("vastai".into()), Some("rtx4090".into())))
        );
        assert_eq!(
            parse_auto_managed_spec("auto-managed:scaleway:PRO2-S"),
            Some((Some("scaleway".into()), Some("PRO2-S".into())))
        );
    }
}
