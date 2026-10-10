//! Wait for a usage limit to reset instead of failing the mission.
//!
//! A turn that ends on a usage limit after every account was tried cannot
//! succeed before the limit resets, and the limit says when that is. The
//! mission is put back in the scheduler's hands: `Pending`, with `not_before`
//! set to the reset time and the resume prompt as its deferred goal. The
//! existing scheduler pass dispatches it once the time has come, and because
//! all three live in the mission store a backend restart changes nothing.

use std::sync::Arc;

use chrono::{DateTime, Duration, Utc};
use uuid::Uuid;

use super::{AgentEvent, MissionStatus};
use crate::account_limits::{self, AccountCooldowns, Zone};
use crate::agents::{AgentResult, TerminalReason};
use crate::api::mission_store::{Mission, MissionStore};

/// `terminal_reason` of a mission waiting for a usage limit to reset.
pub(crate) const USAGE_LIMIT_WAIT_REASON: &str = "usage_limit_wait";

/// Opens every automatic resume prompt, so a second wait in a row reuses the
/// prompt instead of wrapping it again.
const RESUME_PROMPT_MARKER: &str = "[Automatic resume after a usage limit]";
const RECOVERY_PROMPT_MARKER: &str = "[Automatic recovery]";

/// The resume is scheduled this long after the announced reset, so a clock a
/// few seconds ahead of the provider does not resume into the same limit.
const RESUME_MARGIN_SECS: i64 = 60;

/// A mission never resumes sooner than this, whatever the message says: a
/// reset time read wrong must not turn into a tight retry loop.
const MIN_WAIT_SECS: i64 = 5 * 60;

/// Why and until when a mission waits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct UsageLimitWait {
    /// The limit that was hit, e.g. "Claude session limit".
    pub limit: String,
    /// When the mission is resumed.
    pub resume_at: DateTime<Utc>,
    /// Whether the provider announced the reset, or the default delay applies.
    pub announced: bool,
}

/// Provider id and product name of the accounts a backend runs on. Only the
/// backends that rotate across subscription accounts wait for a reset.
fn accounts_of_backend(backend: &str) -> Option<(&'static str, &'static str)> {
    match backend {
        "claudecode" => Some(("anthropic", "Claude")),
        "codex" => Some(("openai", "Codex")),
        "antigravity" => Some(("google", "Antigravity")),
        // OpenCode may route through multiple providers. Do not borrow an
        // unrelated subscription account cooldown; use the reported reset.
        "opencode" => Some(("opencode", "Provider")),
        _ => None,
    }
}

/// The wait a finished turn calls for: `Some` when the turn failed on a usage
/// limit (the runner only reports one after trying every account).
///
/// The mission resumes at the earliest reset known for the provider: the one
/// the message announces, or an earlier one recorded for another account.
pub(crate) fn wait_for_result(
    backend: &str,
    result: &AgentResult,
    limits: &AccountCooldowns,
    now: DateTime<Utc>,
    zone: Zone,
) -> Option<UsageLimitWait> {
    let (provider, account_kind) = accounts_of_backend(backend)?;
    if result.success
        || result.terminal_reason != Some(TerminalReason::RateLimited)
        || !account_limits::is_usage_limit_message(&result.output)
    {
        return None;
    }
    Some(wait_until_reset(
        provider,
        account_kind,
        &result.output,
        limits,
        now,
        zone,
    ))
}

fn wait_until_reset(
    provider: &str,
    account_kind: &str,
    message: &str,
    limits: &AccountCooldowns,
    now: DateTime<Utc>,
    zone: Zone,
) -> UsageLimitWait {
    let announced = account_limits::limit_reset(message, now, zone);
    let recorded = limits
        .all_active_at(now)
        .into_iter()
        .map(|(_, cooldown)| cooldown)
        .filter(|cooldown| cooldown.provider == provider)
        .min_by_key(|cooldown| cooldown.until);
    let (reset, was_announced) = match recorded {
        Some(cooldown) if cooldown.until < announced.at || !announced.announced => {
            (cooldown.until, cooldown.announced)
        }
        _ => (announced.at, announced.announced),
    };
    UsageLimitWait {
        limit: account_limits::describe_limit(account_kind, message),
        resume_at: (reset + Duration::seconds(RESUME_MARGIN_SECS))
            .max(now + Duration::seconds(MIN_WAIT_SECS)),
        announced: was_announced,
    }
}

fn resume_time(wait: &UsageLimitWait) -> String {
    account_limits::format_reset(wait.resume_at, Zone::system())
}

/// What the operator reads under the failed turn.
pub(crate) fn annotate_output(output: &str, wait: &UsageLimitWait) -> String {
    let basis = if wait.announced {
        "when the limit resets"
    } else {
        "no reset time was announced, so it retries after the default delay"
    };
    format!(
        "{}\n\n{} reached on every configured account. This mission is waiting and will resume \
         automatically at {} ({basis}).",
        output.trim_end(),
        wait.limit,
        resume_time(wait),
    )
}

/// One-line status for mission lists.
pub(crate) fn status_summary(wait: &UsageLimitWait) -> String {
    format!(
        "Waiting for the {} to reset; resumes automatically at {}",
        wait.limit,
        resume_time(wait)
    )
}

/// The prompt the mission is resumed with. It repeats the message that was
/// being handled: a turn that hit the limit before reaching the model may
/// never have recorded it in the harness session.
pub(crate) fn resume_prompt(mission: &Mission, wait: &UsageLimitWait, interrupted: &str) -> String {
    if mission.backend == "codex" && mission.goal_mode {
        if let Some(objective) = mission.goal_objective.as_ref() {
            return format!("/goal {objective}");
        }
    }
    let interrupted = interrupted.trim();
    if interrupted.starts_with(RESUME_PROMPT_MARKER) {
        return interrupted.to_string();
    }
    let mut prompt = format!(
        "{RESUME_PROMPT_MARKER} The {} stopped your previous turn and has now reset. Resume your \
         work where it stopped, and check the state of anything you had started.",
        wait.limit
    );
    if !interrupted.is_empty() {
        prompt.push_str(
            "\n\nThe message you were handling when the limit was hit, in case it was not \
             recorded:\n\n",
        );
        prompt.push_str(interrupted);
    }
    if mission.backend == "antigravity" && mission.goal_mode {
        if let Some(objective) = mission.goal_objective.as_ref() {
            return format!("/goal {objective}\n\n{prompt}");
        }
    }
    prompt
}

/// Decide whether the mission of a finished turn waits for a usage limit.
///
/// `None` keeps the previous outcome (the mission fails) when the store
/// cannot hold a schedule, the mission is a task-board worker (the board owns
/// its retries), or the mission is no longer the running one.
pub(crate) async fn plan(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    result: &AgentResult,
) -> Option<(Mission, UsageLimitWait)> {
    if !mission_store.is_persistent() {
        return None;
    }
    // Cheap exit for the overwhelming majority of turns.
    if result.success || result.terminal_reason != Some(TerminalReason::RateLimited) {
        return None;
    }
    let mission = mission_store.get_mission(mission_id).await.ok()??;
    if !matches!(
        mission.status,
        MissionStatus::Active | MissionStatus::Pending
    ) {
        return None;
    }
    match mission_store.get_board_task_by_worker(mission_id).await {
        Ok(None) => {}
        Ok(Some(_)) | Err(_) => return None,
    }
    let wait = wait_for_result(
        &mission.backend,
        result,
        &account_limits::shared(),
        Utc::now(),
        Zone::system(),
    )?;
    // Waiting past the deadline would only fail later with a less useful
    // reason.
    let past_deadline = mission
        .scheduling
        .deadline
        .as_deref()
        .and_then(|deadline| DateTime::parse_from_rfc3339(deadline).ok())
        .is_some_and(|deadline| deadline.with_timezone(&Utc) <= wait.resume_at);
    if past_deadline {
        return None;
    }
    Some((mission, wait))
}

/// Park the mission until `wait.resume_at`. Returns false, leaving the
/// mission untouched for the normal finalizer, when the schedule could not
/// be written.
pub(crate) async fn park(
    mission_store: &Arc<dyn MissionStore>,
    events_tx: &tokio::sync::broadcast::Sender<AgentEvent>,
    mission: &Mission,
    wait: &UsageLimitWait,
    interrupted_message: &str,
) -> bool {
    let mission_id = mission.id;
    let prompt = resume_prompt(mission, wait, interrupted_message);
    let mut scheduling = mission.scheduling.clone();
    scheduling.not_before = Some(wait.resume_at.to_rfc3339());

    // Schedule first, status last: a mission is only `Pending` once the
    // scheduler has everything it needs to resume it.
    if let Err(error) = mission_store
        .set_mission_scheduling(mission_id, &scheduling)
        .await
    {
        tracing::warn!(%mission_id, %error, "Could not schedule the resume after a usage limit");
        return false;
    }
    if let Err(error) = mission_store
        .set_deferred_goal(mission_id, Some(prompt))
        .await
    {
        tracing::warn!(%mission_id, %error, "Could not store the resume prompt after a usage limit");
        return false;
    }
    if let Err(error) = mission_store
        .update_mission_status_with_reason(
            mission_id,
            MissionStatus::Pending,
            Some(USAGE_LIMIT_WAIT_REASON),
        )
        .await
    {
        tracing::warn!(%mission_id, %error, "Could not park the mission after a usage limit");
        let _ = mission_store.set_deferred_goal(mission_id, None).await;
        return false;
    }
    tracing::info!(
        %mission_id,
        limit = %wait.limit,
        resume_at = %wait.resume_at,
        announced = wait.announced,
        "Mission waits for a usage limit to reset"
    );
    let _ = events_tx.send(AgentEvent::MissionStatusChanged {
        completion: None,
        execution: mission_store
            .get_latest_mission_run(mission_id)
            .await
            .ok()
            .flatten(),
        mission_id,
        status: MissionStatus::Pending,
        summary: Some(status_summary(wait)),
    });
    true
}

/// True for a mission parked by [`park`] and not resumed yet.
pub(crate) fn is_waiting(mission: &Mission) -> bool {
    mission.status == MissionStatus::Pending
        && mission.terminal_reason.as_deref() == Some(USAGE_LIMIT_WAIT_REASON)
}

/// True when an automation's message is already one of the messages the
/// mission will resume with. Messages that arrive during the wait are
/// appended to the resume prompt; an automation firing on an interval would
/// otherwise append the same text once per tick for hours. Only automation
/// deliveries (no source) are deduplicated, and only on an exact match:
/// whatever an operator sends is always kept.
pub(crate) fn already_deferred(deferred_goal: &str, source: Option<&str>, content: &str) -> bool {
    let content = content.trim();
    source.is_none()
        && !content.is_empty()
        && super::deferred_messages::decode(deferred_goal)
            .1
            .iter()
            .any(|(_, message)| message.trim() == content)
}

/// Let a waiting mission run now (operator resume): the schedule is lifted
/// and the stored resume prompt returned. The status is left to the caller.
pub(crate) async fn release(
    mission_store: &Arc<dyn MissionStore>,
    mission: &Mission,
) -> Result<Option<String>, String> {
    let prompt = mission_store.get_deferred_goal(mission.id).await?;
    let mut scheduling = mission.scheduling.clone();
    scheduling.not_before = None;
    mission_store
        .set_mission_scheduling(mission.id, &scheduling)
        .await?;
    mission_store.set_deferred_goal(mission.id, None).await?;
    Ok(prompt)
}

// ─────────────────────────────────────────────────────────────────────────────
// Remote-node jobs
// ─────────────────────────────────────────────────────────────────────────────
//
// A remote mission cannot go back to the local scheduler: `Pending` means
// "its node job is still owned" there, and the scheduler would start a local
// harness. It waits as `Interrupted` (resumable, not failed) and the replayer
// continues it on its node through the same path as an operator resume.

/// Waits of remote missions, next to the remote job ledger.
const REMOTE_WAITS_FILE: &str = ".sandboxed-sh/remote_usage_limit_waits.json";

/// Replays of one mission before a usage limit fails it like any other error.
const MAX_REMOTE_REPLAYS: u32 = 12;

/// Attempts to continue a mission whose node refuses for a passing reason.
const MAX_REPLAY_RETRIES: u32 = 6;
const REPLAY_RETRY_SECS: i64 = 5 * 60;

/// Delay before replaying on another account that is not at its limit.
const IMMEDIATE_REPLAY_SECS: i64 = 30;

/// One remote mission waiting for a usage limit, or replayed after one.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub(crate) struct RemoteWait {
    /// When to replay; `None` once replayed (the record keeps the count).
    pub resume_at: Option<DateTime<Utc>>,
    pub limit: String,
    /// Replays already made for this mission since its last served job.
    #[serde(default)]
    pub replays: u32,
    /// Failed attempts to start the pending replay.
    #[serde(default)]
    pub retries: u32,
    /// Fence duplicate terminal observations, including after a Core restart.
    #[serde(default)]
    pub failed_job_id: Option<Uuid>,
}

#[derive(Default, serde::Serialize, serde::Deserialize)]
struct RemoteWaitsFile {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    waits: std::collections::HashMap<Uuid, RemoteWait>,
}

static REMOTE_WAITS_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn read_remote_waits(working_dir: &std::path::Path) -> RemoteWaitsFile {
    let path = working_dir.join(REMOTE_WAITS_FILE);
    match std::fs::read_to_string(&path) {
        Ok(contents) => serde_json::from_str(&contents).unwrap_or_else(|error| {
            tracing::warn!(path = %path.display(), %error, "Ignoring unreadable remote usage-limit waits");
            RemoteWaitsFile::default()
        }),
        Err(_) => RemoteWaitsFile::default(),
    }
}

fn write_remote_waits(working_dir: &std::path::Path, file: &RemoteWaitsFile) {
    let path = working_dir.join(REMOTE_WAITS_FILE);
    let written = (|| -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(file)?)?;
        std::fs::rename(&tmp, &path)
    })();
    if let Err(error) = written {
        tracing::warn!(path = %path.display(), %error, "Could not persist remote usage-limit waits");
    }
}

/// Change the record of `mission_id`; returning `None` removes it.
pub(crate) async fn update_remote_wait(
    working_dir: &std::path::Path,
    mission_id: Uuid,
    change: impl FnOnce(Option<RemoteWait>) -> Option<RemoteWait>,
) {
    let _guard = REMOTE_WAITS_LOCK.lock().await;
    let mut file = read_remote_waits(working_dir);
    let previous = file.waits.remove(&mission_id);
    let had_record = previous.is_some();
    match change(previous) {
        Some(wait) => {
            file.waits.insert(mission_id, wait);
        }
        None if !had_record => return,
        None => {}
    }
    file.version = 1;
    write_remote_waits(working_dir, &file);
}

pub(crate) async fn remote_wait(
    working_dir: &std::path::Path,
    mission_id: Uuid,
) -> Option<RemoteWait> {
    let _guard = REMOTE_WAITS_LOCK.lock().await;
    read_remote_waits(working_dir).waits.remove(&mission_id)
}

/// Read the ledger once for a mission-list response, not once per row.
pub(crate) async fn remote_recoveries(
    working_dir: &std::path::Path,
) -> std::collections::HashMap<Uuid, RemoteWait> {
    let _guard = REMOTE_WAITS_LOCK.lock().await;
    read_remote_waits(working_dir).waits
}

pub(crate) fn attach_recovery(value: &mut serde_json::Value, wait: Option<&RemoteWait>) {
    // A stale ledger entry must never advertise a retry after Stop or Resume.
    if value["status"] != "interrupted" || value["terminal_reason"] != USAGE_LIMIT_WAIT_REASON {
        return;
    }
    let Some(wait) = wait.filter(|wait| wait.resume_at.is_some()) else {
        return;
    };
    let kind = if wait.limit == "Antigravity response truncated" {
        "output_limit"
    } else if wait.limit == "Antigravity background task handoff" {
        "background"
    } else if is_transient_wait(&wait.limit) {
        "transient"
    } else {
        "quota"
    };
    value["recovery"] = serde_json::json!({
        "kind": kind, "reason": wait.limit, "resume_at": wait.resume_at,
        "attempt": wait.replays + 1, "max_attempts": MAX_REMOTE_REPLAYS,
    });
}

/// The waits whose replay is due at `now`.
pub(crate) async fn due_remote_waits(
    working_dir: &std::path::Path,
    now: DateTime<Utc>,
) -> Vec<(Uuid, RemoteWait)> {
    let _guard = REMOTE_WAITS_LOCK.lock().await;
    read_remote_waits(working_dir)
        .waits
        .into_iter()
        .filter(|(_, wait)| wait.resume_at.is_some_and(|at| at <= now))
        .collect()
}

/// Classify a failed remote job: `Some` when it failed on a usage limit and
/// is to be replayed. `failure` is the harness error when the job reported
/// one, else the job report.
///
/// The first failure is replayed at once when another account of the
/// provider is not at its limit (the proxy picks it); otherwise, and for
/// every later failure, the mission waits for the reset.
pub(crate) fn remote_wait_for_failure(
    backend: &str,
    failure: &str,
    replays: u32,
    another_account_is_available: bool,
    limits: &AccountCooldowns,
    now: DateTime<Utc>,
    zone: Zone,
) -> Option<UsageLimitWait> {
    let (provider, account_kind) = accounts_of_backend(backend)?;
    if !account_limits::is_usage_limit_message(failure) || replays >= MAX_REMOTE_REPLAYS {
        return None;
    }
    if replays == 0 && another_account_is_available {
        return Some(UsageLimitWait {
            limit: account_limits::describe_limit(account_kind, failure),
            resume_at: now + Duration::seconds(IMMEDIATE_REPLAY_SECS),
            announced: false,
        });
    }
    Some(wait_until_reset(
        provider,
        account_kind,
        failure,
        limits,
        now,
        zone,
    ))
}

/// True when an enabled account of `provider` in the provider store is not
/// parked on a usage limit, nor its shared subscription.
pub(crate) fn provider_has_available_account(
    working_dir: &std::path::Path,
    provider: &str,
    limits: &AccountCooldowns,
) -> bool {
    let path = working_dir.join(crate::util::AI_PROVIDERS_PATH);
    let Ok(contents) = std::fs::read_to_string(path) else {
        return false;
    };
    let accounts: Vec<crate::ai_providers::AIProvider> =
        serde_json::from_str(&contents).unwrap_or_default();
    accounts.iter().any(|account| {
        account.enabled
            && account.provider_type.id() == provider
            && account.has_credentials()
            && !limits.is_cooling(&account_limits::account_key(account.id))
            && !crate::provider_health::store_account_subscription_key(
                account.provider_type,
                account,
            )
            .is_some_and(|key| limits.is_cooling(&account_limits::subscription_key(&key.0)))
    })
}

/// Classify a resumable Antigravity remote interruption or transient upstream
/// error on a mission that already has a persisted native conversation ID.
pub(crate) fn antigravity_resumable_interruption(failure: &str) -> Option<&'static str> {
    let lower = failure.to_ascii_lowercase();
    if account_limits::is_usage_limit_message(failure)
        || [
            "unauthenticated",
            "permission_denied",
            "invalid_grant",
            "sign in",
            "log in",
            "oauth",
            "cancelled by",
            "canceled by",
        ]
        .iter()
        .any(|s| lower.contains(s))
    {
        return None;
    }
    if lower.contains("previous response was cut off because it exceeded the output token limit") {
        Some("Antigravity response truncated")
    } else if failure.contains("Antigravity ended without a SUCCESS result") {
        Some("Antigravity interrupted turn")
    } else if failure.contains("Antigravity ended its headless turn while background task(s)") {
        Some("Antigravity background task handoff")
    } else if crate::antigravity::is_transient_error(failure) {
        Some("Antigravity transient upstream error")
    } else {
        None
    }
}

/// Require a sustained run, not a token threshold that a single response can
/// cross while the provider is still flapping. Never infer progress from the
/// native result's lifetime-cumulative usage counters.
pub(crate) fn sustained_recovery_progress(
    started_at: Option<&str>,
    now: DateTime<Utc>,
    output_tokens: u64,
) -> bool {
    output_tokens > 1000
        && started_at
            .and_then(|at| DateTime::parse_from_rfc3339(at).ok())
            .is_some_and(|at| now.signed_duration_since(at) >= Duration::minutes(10))
}

fn is_transient_wait(limit: &str) -> bool {
    limit == "Inference connection interrupted"
        || (limit.starts_with("Antigravity ") && !limit.ends_with("limit"))
}

fn recovery_delay_secs(replays: u32, mission_id: Uuid) -> i64 {
    // Deterministic jitter survives restarts and spreads a fleet-wide outage.
    let base = (60_i64 * (1_i64 << replays.min(4))).min(600);
    base + (mission_id.as_u128() % (base as u128 / 5 + 1)) as i64
}

/// Decide whether a failed remote job waits for a usage limit, and record
/// the wait. Recording is idempotent, so a finalization that is retried does
/// not count twice. A job that did not fail on a usage limit clears the
/// record, which resets the replay count.
pub(crate) async fn plan_remote(
    working_dir: &std::path::Path,
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    success: bool,
    failure: &str,
    job_id: Uuid,
    sustained_progress: bool,
) -> Option<UsageLimitWait> {
    let previous = remote_wait(working_dir, mission_id).await;
    if let Some(wait) = previous
        .as_ref()
        .filter(|wait| wait.failed_job_id == Some(job_id))
    {
        return wait.resume_at.map(|resume_at| UsageLimitWait {
            limit: wait.limit.clone(),
            resume_at,
            announced: false,
        });
    }
    let mission = mission_store.get_mission(mission_id).await.ok().flatten();
    let planned = async {
        if success {
            return None;
        }
        let mission = mission.as_ref()?;
        if !matches!(
            mission.status,
            MissionStatus::Active | MissionStatus::Pending
        ) {
            return None;
        }
        if mission
            .scheduling
            .deadline
            .as_deref()
            .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
            .is_some_and(|deadline| deadline <= Utc::now())
        {
            return None;
        }
        let replays = if sustained_progress {
            0
        } else {
            previous.as_ref().map_or(0, |wait| wait.replays)
        };
        let now = Utc::now();
        let classified = super::remote_failure::classify(failure);
        if matches!(
            classified.kind,
            super::remote_failure::FailureKind::Authentication
                | super::remote_failure::FailureKind::ProviderPolicy
                | super::remote_failure::FailureKind::Configuration
                | super::remote_failure::FailureKind::Cancelled
        ) {
            return None;
        }
        if mission.backend == "antigravity"
            && mission
                .session_id
                .as_deref()
                .is_some_and(|s| !s.trim().is_empty())
            && replays < MAX_REMOTE_REPLAYS
        {
            if let Some(interruption) = antigravity_resumable_interruption(failure) {
                let delay = recovery_delay_secs(replays, mission_id);
                return Some(UsageLimitWait {
                    limit: interruption.to_string(),
                    resume_at: now + Duration::seconds(delay),
                    announced: false,
                });
            }
        }
        if classified.kind == super::remote_failure::FailureKind::Transport
            && mission
                .session_id
                .as_deref()
                .is_some_and(|id| !id.trim().is_empty())
            && replays < MAX_REMOTE_REPLAYS
        {
            return Some(UsageLimitWait {
                limit: "Inference connection interrupted".into(),
                resume_at: now
                    + Duration::seconds(
                        recovery_delay_secs(replays, mission_id)
                            .max(classified.retry_after_seconds.unwrap_or(0)),
                    ),
                announced: false,
            });
        }
        let (provider, _) = accounts_of_backend(&mission.backend)?;
        let limits = account_limits::shared();
        remote_wait_for_failure(
            &mission.backend,
            failure,
            replays,
            provider_has_available_account(working_dir, provider, &limits),
            &limits,
            now,
            Zone::system(),
        )
    }
    .await
    .filter(|wait| {
        // A recovery must fit inside the mission deadline, including provider
        // Retry-After delays; otherwise the UI would promise an invalid replay.
        !mission
            .as_ref()
            .and_then(|mission| mission.scheduling.deadline.as_deref())
            .and_then(|deadline| DateTime::parse_from_rfc3339(deadline).ok())
            .is_some_and(|deadline| deadline <= wait.resume_at)
    });
    update_remote_wait(working_dir, mission_id, |previous| {
        if planned.is_none() && !success && !sustained_progress {
            if let Some(mut exhausted) = previous
                .clone()
                .filter(|wait| wait.replays >= MAX_REMOTE_REPLAYS)
            {
                // Keep the exhausted budget while finalization is retried; deleting
                // it here would let a repeated observation start again at attempt one.
                exhausted.resume_at = None;
                exhausted.failed_job_id = Some(job_id);
                return Some(exhausted);
            }
        }
        planned.as_ref().map(|wait| RemoteWait {
            resume_at: Some(wait.resume_at),
            limit: wait.limit.clone(),
            replays: if sustained_progress {
                0
            } else {
                previous.map_or(0, |previous| previous.replays)
            },
            retries: 0,
            failed_job_id: Some(job_id),
        })
    })
    .await;
    planned
}

/// What the operator reads under the failed remote job.
pub(crate) fn annotate_remote_output(output: &str, wait: &UsageLimitWait) -> String {
    if is_transient_wait(&wait.limit) {
        return format!(
            "{}\n\n{} detected. This mission is waiting and its conversation will be resumed \
             on the node automatically at {}.",
            output.trim_end(),
            wait.limit,
            resume_time(wait),
        );
    }
    format!(
        "{}\n\n{} reached. This mission is waiting and its job will be replayed on the node \
         automatically at {}.",
        output.trim_end(),
        wait.limit,
        resume_time(wait),
    )
}

/// The prompt a remote mission is continued with. Its native session on the
/// node already holds the message it was handling.
pub(crate) fn remote_resume_prompt(limit: &str) -> String {
    if limit == "Antigravity response truncated" {
        return format!(
            "{RECOVERY_PROMPT_MARKER} Your previous response exceeded the provider output token limit. \
             Check existing work and background tasks, then continue from where you stopped. \
             Keep responses short, write large outputs to workspace files, and split remaining work \
             into smaller steps. Do not restart completed work or duplicate running tasks."
        );
    }
    if is_transient_wait(limit) {
        return format!(
            "{RECOVERY_PROMPT_MARKER} {limit} stopped your previous turn. Resume your work where \
             it stopped, and check the state of anything you had started (including any \
             background tasks or systemd units) before continuing. Do not redo finished work."
        );
    }
    format!(
        "{RESUME_PROMPT_MARKER} The {limit} stopped your previous turn and has now reset. Resume \
         your work where it stopped, and check the state of anything you had started."
    )
}

/// True for a remote mission waiting for its replay.
pub(crate) fn is_waiting_remote(mission: &Mission) -> bool {
    mission.status == MissionStatus::Interrupted
        && mission.terminal_reason.as_deref() == Some(USAGE_LIMIT_WAIT_REASON)
}

/// What to do after a replay could not be started.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ReplayFailure {
    /// Try again at this time.
    Retry(DateTime<Utc>),
    /// The mission cannot be continued on its node.
    GiveUp,
}

pub(crate) fn after_replay_failure(
    wait: &RemoteWait,
    server_error: bool,
    message: &str,
    now: DateTime<Utc>,
) -> ReplayFailure {
    let passing = server_error || message.contains(super::remote_grok::REMOTE_JOB_STILL_RUNNING);
    if passing && wait.retries < MAX_REPLAY_RETRIES {
        ReplayFailure::Retry(now + Duration::seconds(REPLAY_RETRY_SECS))
    } else {
        ReplayFailure::GiveUp
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account_limits::LimitCooldown;
    use crate::api::mission_store::{select_next_runnable_mission, SqliteMissionStore};

    fn utc(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&Utc)
    }

    fn limited(message: &str) -> AgentResult {
        AgentResult::failure(message.to_string(), 0)
            .with_terminal_reason(TerminalReason::RateLimited)
    }

    fn parked(provider: &str, until: DateTime<Utc>) -> LimitCooldown {
        LimitCooldown {
            until,
            provider: provider.to_string(),
            limit: "usage limit".to_string(),
            announced: true,
            recorded_at: until - Duration::hours(1),
        }
    }

    #[test]
    fn claude_session_limit_waits_until_the_announced_reset() {
        let now = utc("2026-09-29T14:00:00Z");
        let wait = wait_for_result(
            "claudecode",
            &limited("You've hit your session limit · resets 5:30pm (Europe/Berlin)"),
            &AccountCooldowns::default(),
            now,
            Zone::UTC,
        )
        .expect("waits");
        assert_eq!(wait.limit, "Claude session limit");
        assert_eq!(wait.resume_at, utc("2026-09-29T15:31:00Z"));
        assert!(wait.announced);

        let text = annotate_output("You've hit your session limit · resets 5:30pm", &wait);
        assert!(text.starts_with("You've hit your session limit"));
        assert!(text.contains("Claude session limit reached on every configured account"));
        assert!(text.contains("will resume automatically at"));
        assert!(status_summary(&wait).starts_with("Waiting for the Claude session limit"));
    }

    #[test]
    fn codex_waits_for_the_earliest_reset_of_the_exhausted_accounts() {
        let now = utc("2026-09-29T14:00:00Z");
        let message = "All 2 connected Codex accounts are at their ChatGPT usage limit. Earliest \
            reset at Oct 1st, 2026 6:58 PM. Connect a Codex account with available quota.";
        let limits = AccountCooldowns::default();
        let wait = wait_for_result("codex", &limited(message), &limits, now, Zone::UTC).unwrap();
        assert_eq!(wait.limit, "Codex usage limit");
        assert_eq!(wait.resume_at, utc("2026-10-01T18:59:00Z"));

        // Another Codex account resets sooner; a Claude account does not
        // count, nor does a cooldown that has already ended.
        limits.set("other-codex", parked("openai", utc("2026-09-30T08:00:00Z")));
        limits.set("claude", parked("anthropic", utc("2026-09-29T16:00:00Z")));
        limits.set("ended", parked("openai", utc("2026-09-29T13:00:00Z")));
        let wait = wait_for_result("codex", &limited(message), &limits, now, Zone::UTC).unwrap();
        assert_eq!(wait.resume_at, utc("2026-09-30T08:01:00Z"));
    }

    #[test]
    fn a_limit_without_a_reset_time_retries_after_the_default_delay() {
        let now = utc("2026-09-29T14:00:00Z");
        let wait = wait_for_result(
            "claudecode",
            &limited("You're out of usage credits. Switch to another model to continue."),
            &AccountCooldowns::default(),
            now,
            Zone::UTC,
        )
        .unwrap();
        assert!(!wait.announced);
        assert_eq!(wait.resume_at, utc("2026-09-29T15:01:00Z"));
        assert!(annotate_output("out of credits", &wait).contains("default delay"));
    }

    #[test]
    fn a_reset_that_is_already_due_still_waits_a_few_minutes() {
        let now = utc("2026-09-29T15:29:30Z");
        let wait = wait_for_result(
            "claudecode",
            &limited("You've hit your limit · resets 5:30pm (Europe/Berlin)"),
            &AccountCooldowns::default(),
            now,
            Zone::UTC,
        )
        .unwrap();
        assert_eq!(wait.resume_at, now + Duration::minutes(5));
    }

    #[test]
    fn only_usage_limits_on_rotating_backends_wait() {
        let now = utc("2026-09-29T14:00:00Z");
        let limits = AccountCooldowns::default();
        let usage_limit = "You've hit your session limit · resets 5:30pm (UTC)";
        let waits = |backend: &str, result: &AgentResult| {
            wait_for_result(backend, result, &limits, now, Zone::UTC).is_some()
        };
        assert!(waits("claudecode", &limited(usage_limit)));
        assert!(waits("codex", &limited(usage_limit)));
        // Other backends keep failing.
        assert!(waits("opencode", &limited(usage_limit)));
        assert!(!waits("gemini", &limited(usage_limit)));
        // Transient rate limits and overloads keep failing.
        assert!(!waits("claudecode", &limited("overloaded_error")));
        assert!(!waits("codex", &limited("Error: 429 Too Many Requests")));
        // The same words in a turn that did not end on a rate limit.
        assert!(!waits(
            "claudecode",
            &AgentResult::failure(usage_limit.to_string(), 0)
                .with_terminal_reason(TerminalReason::LlmError)
        ));
        assert!(!waits("claudecode", &AgentResult::success(usage_limit, 0)));
        assert!(!waits(
            "codex",
            &AgentResult::failure(usage_limit.to_string(), 0)
                .with_terminal_reason(TerminalReason::CapacityLimited)
        ));
    }

    async fn sqlite_store() -> (tempfile::TempDir, Arc<dyn MissionStore>) {
        let dir = tempfile::tempdir().expect("temp dir");
        let store = SqliteMissionStore::new(dir.path().to_path_buf(), "test-user")
            .await
            .expect("sqlite store");
        (dir, Arc::new(store))
    }

    async fn active_mission(store: &Arc<dyn MissionStore>, backend: &str) -> Mission {
        let mission = store
            .create_mission(
                Some("Long audit"),
                None,
                None,
                None,
                None,
                Some(backend),
                None,
            )
            .await
            .expect("mission");
        store
            .update_mission_status(mission.id, MissionStatus::Active)
            .await
            .expect("active");
        store.get_mission(mission.id).await.unwrap().unwrap()
    }

    #[tokio::test]
    async fn exhausted_accounts_park_the_mission_and_the_scheduler_resumes_it() {
        let (_dir, store) = sqlite_store().await;
        let mission = active_mission(&store, "claudecode").await;
        let (events_tx, mut events_rx) = tokio::sync::broadcast::channel(8);
        let result = limited("You've hit your session limit · resets in 2 hours");

        let (mission, wait) = plan(&store, mission.id, &result)
            .await
            .expect("the turn calls for a wait");
        assert!(
            park(
                &store,
                &events_tx,
                &mission,
                &wait,
                "Audit the vault contracts"
            )
            .await
        );

        // Waiting: not failed, not terminal, and the wait is on record.
        let waiting = store.get_mission(mission.id).await.unwrap().unwrap();
        assert_eq!(waiting.status, MissionStatus::Pending);
        assert!(!waiting.status.is_terminal());
        assert_eq!(
            waiting.terminal_reason.as_deref(),
            Some(USAGE_LIMIT_WAIT_REASON)
        );
        assert!(is_waiting(&waiting));
        let not_before = DateTime::parse_from_rfc3339(
            waiting
                .scheduling
                .not_before
                .as_deref()
                .expect("resume time"),
        )
        .unwrap()
        .with_timezone(&Utc);
        assert_eq!(not_before, wait.resume_at);
        assert!(not_before > Utc::now() + Duration::minutes(115));
        match events_rx.try_recv() {
            Ok(AgentEvent::MissionStatusChanged {
                status: MissionStatus::Pending,
                summary: Some(summary),
                ..
            }) => {
                assert!(summary.contains("Claude session limit"), "{summary}");
                assert!(summary.contains("resumes automatically at"), "{summary}");
            }
            other => panic!("unexpected event: {other:?}"),
        }

        // The scheduler sees it, holds it until the reset, then resumes it
        // with a prompt that carries the interrupted message.
        let scheduled = store.get_scheduled_pending_missions().await.unwrap();
        assert_eq!(scheduled.len(), 1);
        assert!(select_next_runnable_mission(&scheduled, Utc::now()).is_none());
        let due = select_next_runnable_mission(&scheduled, not_before + Duration::seconds(1))
            .expect("due after the reset");
        assert_eq!(due.id, mission.id);
        let prompt = store.get_deferred_goal(mission.id).await.unwrap().unwrap();
        assert!(prompt.starts_with(RESUME_PROMPT_MARKER));
        assert!(prompt.contains("Claude session limit"));
        assert!(prompt.ends_with("Audit the vault contracts"));

        // A second limit in a row reuses the prompt instead of nesting it.
        assert_eq!(resume_prompt(&waiting, &wait, &prompt), prompt);

        // An operator resume lifts the schedule.
        let released = release(&store, &waiting).await.unwrap();
        assert_eq!(released.as_deref(), Some(prompt.as_str()));
        let lifted = store.get_mission(mission.id).await.unwrap().unwrap();
        assert_eq!(lifted.scheduling.not_before, None);
        assert!(store
            .get_scheduled_pending_missions()
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn the_wait_survives_a_restart() {
        let dir = tempfile::tempdir().expect("temp dir");
        let mission_id = {
            let store: Arc<dyn MissionStore> = Arc::new(
                SqliteMissionStore::new(dir.path().to_path_buf(), "test-user")
                    .await
                    .unwrap(),
            );
            let mission = active_mission(&store, "codex").await;
            let (events_tx, _events_rx) = tokio::sync::broadcast::channel(8);
            let result = limited("You've hit your usage limit. try again in 3 hours.");
            let (mission, wait) = plan(&store, mission.id, &result).await.unwrap();
            assert!(park(&store, &events_tx, &mission, &wait, "continue").await);
            mission.id
        };
        let reopened = SqliteMissionStore::new(dir.path().to_path_buf(), "test-user")
            .await
            .unwrap();
        let scheduled = reopened.get_scheduled_pending_missions().await.unwrap();
        assert_eq!(scheduled.len(), 1);
        assert_eq!(scheduled[0].id, mission_id);
        // The scheduler's listing is a reduced projection; the reason is on
        // the full record.
        let waiting = reopened.get_mission(mission_id).await.unwrap().unwrap();
        assert!(is_waiting(&waiting));
        assert!(!scheduled[0].is_dispatchable_at(Utc::now()));
        assert!(scheduled[0].is_dispatchable_at(Utc::now() + Duration::hours(4)));
        assert!(reopened
            .get_deferred_goal(mission_id)
            .await
            .unwrap()
            .is_some());
    }

    #[tokio::test]
    async fn missions_that_cannot_wait_keep_failing() {
        let (_dir, store) = sqlite_store().await;
        let usage_limit = limited("You've hit your session limit · resets in 2 hours");

        // Not a usage limit.
        let mission = active_mission(&store, "claudecode").await;
        assert!(plan(&store, mission.id, &limited("overloaded_error"))
            .await
            .is_none());
        // A backend that does not rotate accounts.
        let other = active_mission(&store, "grok").await;
        assert!(plan(&store, other.id, &usage_limit).await.is_none());
        // Already settled by something else.
        store
            .update_mission_status(mission.id, MissionStatus::Interrupted)
            .await
            .unwrap();
        assert!(plan(&store, mission.id, &usage_limit).await.is_none());
        // The reset falls after the mission's deadline.
        let urgent = active_mission(&store, "claudecode").await;
        store
            .set_mission_scheduling(
                urgent.id,
                &crate::api::mission_store::MissionScheduling {
                    priority: 0,
                    not_before: None,
                    deadline: Some((Utc::now() + Duration::minutes(30)).to_rfc3339()),
                },
            )
            .await
            .unwrap();
        assert!(plan(&store, urgent.id, &usage_limit).await.is_none());

        // A store that cannot hold a schedule.
        let memory: Arc<dyn MissionStore> =
            Arc::new(crate::api::mission_store::InMemoryMissionStore::new());
        let mission = memory
            .create_mission(None, None, None, None, None, Some("claudecode"), None)
            .await
            .unwrap();
        memory
            .update_mission_status(mission.id, MissionStatus::Active)
            .await
            .unwrap();
        assert!(plan(&memory, mission.id, &usage_limit).await.is_none());
    }

    #[test]
    fn an_automation_message_repeated_during_the_wait_is_kept_once() {
        let first = super::super::deferred_messages::encode(Uuid::new_v4(), "check the CI");
        let goal = super::super::deferred_messages::join("resume prompt, then run tests", &first);
        assert!(already_deferred(&goal, None, "check the CI"));
        assert!(already_deferred(&goal, None, "  check the CI\n"));
        assert!(!already_deferred(&goal, None, "check the deploy"));
        assert!(!already_deferred(&goal, None, "   "));
        // Words that merely occur in the stored prompt are not a repeat.
        assert!(!already_deferred(&goal, None, "run tests"));
        assert!(!already_deferred(&goal, None, "check"));
        // An operator's message is never dropped, even repeated.
        assert!(!already_deferred(&goal, Some("api:thomas"), "check the CI"));
        assert!(!already_deferred(&goal, Some("telegram"), "check the CI"));
    }

    #[tokio::test]
    async fn codex_goal_missions_resume_their_goal() {
        let wait = UsageLimitWait {
            limit: "Codex usage limit".to_string(),
            resume_at: utc("2026-09-29T15:00:00Z"),
            announced: true,
        };
        let memory = crate::api::mission_store::InMemoryMissionStore::new();
        let mut mission = memory
            .create_mission(None, None, None, None, None, Some("codex"), None)
            .await
            .unwrap();
        mission.goal_mode = true;
        mission.goal_objective = Some("prove the lemma".to_string());
        assert_eq!(
            resume_prompt(&mission, &wait, "anything"),
            "/goal prove the lemma"
        );
        mission.goal_mode = false;
        let prompt = resume_prompt(&mission, &wait, "  ");
        assert!(prompt.starts_with(RESUME_PROMPT_MARKER));
        assert!(!prompt.contains("in case it was not recorded"));
    }

    #[test]
    fn remote_usage_limit_failures_are_classified() {
        let now = utc("2026-09-29T14:00:00Z");
        let limits = AccountCooldowns::default();
        let codex = "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage \
            to purchase more credits or try again at Oct 3rd, 2026 6:58 PM.";
        let classify = |backend: &str, failure: &str, replays: u32, available: bool| {
            remote_wait_for_failure(
                backend,
                failure,
                replays,
                available,
                &limits,
                now,
                Zone::UTC,
            )
        };

        // Every account exhausted: wait for the announced reset.
        let wait = classify("codex", codex, 0, false).expect("usage limit");
        assert_eq!(wait.limit, "Codex usage limit");
        assert_eq!(wait.resume_at, utc("2026-10-03T18:59:00Z"));
        assert!(wait.announced);

        // Another account is available: replay at once, but only once.
        let wait = classify("codex", codex, 0, true).unwrap();
        assert_eq!(wait.resume_at, now + Duration::seconds(30));
        let wait = classify("codex", codex, 1, true).unwrap();
        assert_eq!(wait.resume_at, utc("2026-10-03T18:59:00Z"));

        let claude = "You've hit your session limit · resets 5:30pm (Europe/Berlin)";
        let wait = classify("claudecode", claude, 0, false).unwrap();
        assert_eq!(wait.limit, "Claude session limit");
        assert_eq!(wait.resume_at, utc("2026-09-29T15:31:00Z"));

        // Plain failures stay plain failures.
        for failure in [
            "command exited with Some(1)",
            "Error: 429 Too Many Requests",
            "overloaded_error",
            "timed out after 14400s",
            "",
        ] {
            assert_eq!(classify("codex", failure, 0, true), None, "{failure}");
        }
        // Harnesses that authenticate on the node are not replayed.
        assert_eq!(classify("grok", codex, 0, true), None);
        assert_eq!(classify("gemini", codex, 0, false), None);
        // A mission that keeps hitting the limit ends up failing.
        assert_eq!(classify("codex", codex, MAX_REMOTE_REPLAYS, false), None);
    }

    #[tokio::test]
    async fn remote_waits_are_recorded_and_survive_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let mission_id = Uuid::new_v4();
        let other = Uuid::new_v4();
        let due_at = Utc::now() - Duration::seconds(5);
        let record = |resume_at, replays| RemoteWait {
            resume_at,
            limit: "Codex usage limit".to_string(),
            replays,
            retries: 0,
            failed_job_id: None,
        };
        update_remote_wait(dir.path(), mission_id, |_| Some(record(Some(due_at), 0))).await;
        update_remote_wait(dir.path(), other, |_| {
            Some(record(Some(Utc::now() + Duration::hours(2)), 0))
        })
        .await;

        // Read back from the file alone, as after a restart.
        let due = due_remote_waits(dir.path(), Utc::now()).await;
        assert_eq!(due, vec![(mission_id, record(Some(due_at), 0))]);

        // Replayed: no longer due, and the count is kept for the next limit.
        update_remote_wait(dir.path(), mission_id, |previous| {
            previous.map(|wait| RemoteWait {
                resume_at: None,
                replays: wait.replays + 1,
                ..wait
            })
        })
        .await;
        assert!(due_remote_waits(dir.path(), Utc::now()).await.is_empty());
        assert_eq!(
            remote_wait(dir.path(), mission_id).await,
            Some(record(None, 1))
        );

        // A served job forgets the record.
        update_remote_wait(dir.path(), mission_id, |_| None).await;
        assert_eq!(remote_wait(dir.path(), mission_id).await, None);
        assert!(remote_wait(dir.path(), other).await.is_some());
    }

    #[tokio::test]
    async fn a_failed_remote_job_on_a_usage_limit_waits_instead_of_failing() {
        let (dir, store) = sqlite_store().await;
        let mission = active_mission(&store, "codex").await;
        let failure = "You've hit your usage limit. try again in 4 hours.";

        let wait = plan_remote(
            dir.path(),
            &store,
            mission.id,
            false,
            failure,
            Uuid::new_v4(),
            false,
        )
        .await
        .expect("classified as a usage limit");
        assert!(wait.resume_at > Utc::now() + Duration::minutes(235));
        let recorded = remote_wait(dir.path(), mission.id).await.unwrap();
        assert_eq!(recorded.resume_at, Some(wait.resume_at));
        assert_eq!(recorded.replays, 0);
        let text = annotate_remote_output("Remote codex job failed", &wait);
        assert!(text.contains("Codex usage limit reached"));
        assert!(text.contains("replayed on the node automatically at"));

        // Planning again (a retried finalization) keeps a single record.
        plan_remote(
            dir.path(),
            &store,
            mission.id,
            false,
            failure,
            Uuid::new_v4(),
            false,
        )
        .await
        .unwrap();
        assert_eq!(
            remote_wait(dir.path(), mission.id).await.unwrap().replays,
            0
        );

        // A later plain failure, or a success, is not a wait and clears it.
        assert!(plan_remote(
            dir.path(),
            &store,
            mission.id,
            false,
            "exit 1",
            Uuid::new_v4(),
            false
        )
        .await
        .is_none());
        assert_eq!(remote_wait(dir.path(), mission.id).await, None);
        assert!(plan_remote(
            dir.path(),
            &store,
            mission.id,
            true,
            failure,
            Uuid::new_v4(),
            false
        )
        .await
        .is_none());
    }

    #[test]
    fn available_accounts_are_read_from_the_provider_store() {
        let dir = tempfile::tempdir().unwrap();
        let limits = AccountCooldowns::default();
        assert!(!provider_has_available_account(
            dir.path(),
            "openai",
            &limits
        ));

        let mut capped = crate::ai_providers::AIProvider::new(
            crate::ai_providers::ProviderType::OpenAI,
            "capped".to_string(),
        );
        capped.api_key = Some("sk-a".to_string());
        let mut disabled = capped.clone();
        disabled.id = Uuid::new_v4();
        disabled.enabled = false;
        let mut healthy = capped.clone();
        healthy.id = Uuid::new_v4();
        let write = |accounts: &[&crate::ai_providers::AIProvider]| {
            let path = dir.path().join(crate::util::AI_PROVIDERS_PATH);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, serde_json::to_vec(accounts).unwrap()).unwrap();
        };
        limits.set(
            &account_limits::account_key(capped.id),
            parked("openai", Utc::now() + Duration::hours(2)),
        );

        write(&[&capped, &disabled]);
        assert!(!provider_has_available_account(
            dir.path(),
            "openai",
            &limits
        ));
        assert!(!provider_has_available_account(
            dir.path(),
            "anthropic",
            &limits
        ));
        write(&[&capped, &disabled, &healthy]);
        assert!(provider_has_available_account(
            dir.path(),
            "openai",
            &limits
        ));
    }

    #[test]
    fn a_replay_that_cannot_start_is_retried_or_given_up() {
        let now = utc("2026-09-29T14:00:00Z");
        let mut wait = RemoteWait {
            resume_at: Some(now),
            limit: "Codex usage limit".to_string(),
            replays: 0,
            retries: 0,
            failed_job_id: None,
        };
        let still_running = format!(
            "{}: mission still owns job",
            super::super::remote_grok::REMOTE_JOB_STILL_RUNNING
        );
        assert_eq!(
            after_replay_failure(&wait, false, &still_running, now),
            ReplayFailure::Retry(now + Duration::minutes(5))
        );
        assert_eq!(
            after_replay_failure(&wait, true, "store unavailable", now),
            ReplayFailure::Retry(now + Duration::minutes(5))
        );
        assert_eq!(
            after_replay_failure(&wait, false, "no recorded native session", now),
            ReplayFailure::GiveUp
        );
        wait.retries = MAX_REPLAY_RETRIES;
        assert_eq!(
            after_replay_failure(&wait, false, &still_running, now),
            ReplayFailure::GiveUp
        );
    }

    #[tokio::test]
    async fn antigravity_remote_interruption_with_session_schedules_automatic_replay() {
        let (dir, store) = sqlite_store().await;
        let mission = active_mission(&store, "antigravity").await;
        let failure = "Antigravity ended without a SUCCESS result; resume this conversation before retrying work";

        // Without a persisted native session ID, automatic replay is refused.
        assert!(plan_remote(
            dir.path(),
            &store,
            mission.id,
            false,
            failure,
            Uuid::new_v4(),
            false
        )
        .await
        .is_none());

        store
            .update_mission_session_id(
                mission.id,
                "ef77ed0f-551d-4624-aad9-2a54bba215b6",
                "antigravity",
                None,
            )
            .await
            .unwrap();
        let wait = plan_remote(
            dir.path(),
            &store,
            mission.id,
            false,
            failure,
            Uuid::new_v4(),
            false,
        )
        .await
        .expect("resumable Antigravity interruption schedules automatic replay");
        assert_eq!(wait.limit, "Antigravity interrupted turn");
        assert!(wait.resume_at <= Utc::now() + Duration::seconds(73));
        let text = annotate_remote_output("Remote antigravity job failed", &wait);
        assert!(text.contains("Antigravity interrupted turn detected"));
        assert!(text.contains("conversation will be resumed on the node automatically"));
        let prompt = remote_resume_prompt(&wait.limit);
        assert!(prompt.contains("Antigravity interrupted turn stopped your previous turn"));
        assert!(prompt.contains("background tasks or systemd units"));
    }
    #[tokio::test]
    async fn opencode_gateway_retry_is_durable_fenced_and_respects_stops() {
        let (dir, store) = sqlite_store().await;
        let mission = active_mission(&store, "opencode").await;
        store
            .update_mission_session_id(mission.id, "ses_existing", "opencode", None)
            .await
            .unwrap();
        let error = r#"{"data":{"statusCode":502,"isRetryable":true,"responseHeaders":{"retry-after":"60"}}}"#;
        let job = Uuid::new_v4();
        let before = Utc::now();
        let wait = plan_remote(dir.path(), &store, mission.id, false, error, job, false)
            .await
            .unwrap();
        assert!(wait.resume_at >= before + Duration::seconds(60));
        assert_eq!(wait.limit, "Inference connection interrupted");
        assert_eq!(
            plan_remote(dir.path(), &store, mission.id, false, error, job, false).await,
            Some(wait.clone())
        );
        assert_eq!(
            remote_wait(dir.path(), mission.id)
                .await
                .unwrap()
                .failed_job_id,
            Some(job)
        );
        let prompt = remote_resume_prompt(&wait.limit);
        assert!(prompt.starts_with(RECOVERY_PROMPT_MARKER));
        assert!(!prompt.contains("has now reset"));
        store
            .update_mission_status(mission.id, MissionStatus::Paused)
            .await
            .unwrap();
        assert!(plan_remote(
            dir.path(),
            &store,
            mission.id,
            false,
            error,
            Uuid::new_v4(),
            false
        )
        .await
        .is_none());
    }

    #[tokio::test]
    async fn remote_retry_after_must_fit_before_the_deadline() {
        let (dir, store) = sqlite_store().await;
        let mission = active_mission(&store, "opencode").await;
        store
            .update_mission_session_id(mission.id, "ses_existing", "opencode", None)
            .await
            .unwrap();
        let mut scheduling = mission.scheduling.clone();
        scheduling.deadline = Some((Utc::now() + Duration::minutes(5)).to_rfc3339());
        store
            .set_mission_scheduling(mission.id, &scheduling)
            .await
            .unwrap();
        let error = r#"{"data":{"statusCode":502,"isRetryable":true,"responseHeaders":{"retry-after":"3600"}}}"#;
        assert!(plan_remote(
            dir.path(),
            &store,
            mission.id,
            false,
            error,
            Uuid::new_v4(),
            false
        )
        .await
        .is_none());
        assert!(remote_wait(dir.path(), mission.id).await.is_none());
    }

    #[test]
    fn transient_errors_are_distinct_from_quota_auth_and_operator_stops() {
        let prompt = remote_resume_prompt("Antigravity response truncated");
        assert!(prompt.contains("Keep responses short"));
        assert!(prompt.contains("duplicate running tasks"));
        let mut value =
            serde_json::json!({"status":"interrupted","terminal_reason":USAGE_LIMIT_WAIT_REASON});
        attach_recovery(
            &mut value,
            Some(&RemoteWait {
                resume_at: Some(Utc::now()),
                limit: "Antigravity response truncated".into(),
                replays: 0,
                retries: 0,
                failed_job_id: None,
            }),
        );
        assert_eq!(value["recovery"]["kind"], "output_limit");
        for failure in [
            "Your previous response was cut off because it exceeded the output token limit",
            "UNAVAILABLE (code 503)",
            "RESOURCE_EXHAUSTED: too many requests",
            "read: no route to host",
            "The stream was interrupted. Please continue the task you were working on.",
        ] {
            assert!(
                antigravity_resumable_interruption(failure).is_some(),
                "{failure}"
            );
        }
        for failure in [
            "interrupted",
            "cancelled",
            "UNAUTHENTICATED: The stream was interrupted",
            "PERMISSION_DENIED: UNAVAILABLE (code 503)",
            "You've hit your usage limit. UNAVAILABLE (code 503)",
        ] {
            assert!(
                antigravity_resumable_interruption(failure).is_none(),
                "{failure}"
            );
        }
    }

    #[test]
    fn backoff_grows_with_bounded_jitter_and_requires_sustained_progress() {
        let id = Uuid::nil();
        assert_eq!(
            (0..7)
                .map(|n| recovery_delay_secs(n, id))
                .collect::<Vec<_>>(),
            vec![60, 120, 240, 480, 600, 600, 600]
        );
        for n in 0..20 {
            let delay = recovery_delay_secs(n, Uuid::new_v4());
            assert!((60..=720).contains(&delay));
        }
        let now = utc("2026-10-09T12:00:00Z");
        assert!(!sustained_recovery_progress(
            Some("2026-10-09T11:59:00Z"),
            now,
            1_000_000
        ));
        assert!(!sustained_recovery_progress(None, now, 1_000_000));
        assert!(!sustained_recovery_progress(
            Some("2026-10-09T11:30:00Z"),
            now,
            0
        ));
        assert!(sustained_recovery_progress(
            Some("2026-10-09T11:30:00Z"),
            now,
            1500
        ));
    }

    #[tokio::test]
    async fn replay_plan_is_fenced_by_job_and_stops_after_the_budget_or_operator_pause() {
        let (dir, store) = sqlite_store().await;
        let mission = active_mission(&store, "antigravity").await;
        store
            .update_mission_session_id(mission.id, "native-session", "antigravity", None)
            .await
            .unwrap();
        let error = "The stream was interrupted";
        let job = Uuid::new_v4();
        let first = plan_remote(dir.path(), &store, mission.id, false, error, job, false)
            .await
            .unwrap();
        let again = plan_remote(dir.path(), &store, mission.id, false, error, job, true)
            .await
            .unwrap();
        assert_eq!(first, again);
        update_remote_wait(dir.path(), mission.id, |prior| {
            prior.map(|mut wait| {
                wait.replays = 2;
                wait.resume_at = None;
                wait
            })
        })
        .await;
        let next = plan_remote(
            dir.path(),
            &store,
            mission.id,
            false,
            error,
            Uuid::new_v4(),
            false,
        )
        .await
        .unwrap();
        assert!(next.resume_at > first.resume_at + Duration::seconds(150));
        let mut value =
            serde_json::json!({"status":"interrupted","terminal_reason":USAGE_LIMIT_WAIT_REASON});
        let recorded = remote_wait(dir.path(), mission.id).await.unwrap();
        attach_recovery(&mut value, Some(&recorded));
        assert_eq!(value["recovery"]["kind"], "transient");
        assert_eq!(value["recovery"]["attempt"], 3);
        let mut stopped =
            serde_json::json!({"status":"paused","terminal_reason":USAGE_LIMIT_WAIT_REASON});
        attach_recovery(&mut stopped, Some(&recorded));
        assert!(stopped.get("recovery").is_none());
        update_remote_wait(dir.path(), mission.id, |prior| {
            prior.map(|mut wait| {
                wait.replays = MAX_REMOTE_REPLAYS;
                wait
            })
        })
        .await;
        let exhausted_job = Uuid::new_v4();
        for _ in 0..2 {
            assert!(plan_remote(
                dir.path(),
                &store,
                mission.id,
                false,
                error,
                exhausted_job,
                false
            )
            .await
            .is_none());
            let exhausted = remote_wait(dir.path(), mission.id).await.unwrap();
            assert_eq!(exhausted.replays, MAX_REMOTE_REPLAYS);
            assert!(exhausted.resume_at.is_none());
        }
        store
            .update_mission_status(mission.id, MissionStatus::Paused)
            .await
            .unwrap();
        assert!(plan_remote(
            dir.path(),
            &store,
            mission.id,
            false,
            error,
            Uuid::new_v4(),
            true
        )
        .await
        .is_none());
    }
}
