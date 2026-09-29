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
    let announced = account_limits::limit_reset(&result.output, now, zone);
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
    Some(UsageLimitWait {
        limit: account_limits::describe_limit(account_kind, &result.output),
        resume_at: (reset + Duration::seconds(RESUME_MARGIN_SECS))
            .max(now + Duration::seconds(MIN_WAIT_SECS)),
        announced: was_announced,
    })
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

/// True when `content` is already part of the prompt the mission will resume
/// with. Messages that arrive during the wait are appended to that prompt;
/// an automation firing on an interval would otherwise append the same text
/// once per tick for hours.
pub(crate) fn already_deferred(deferred_goal: &str, content: &str) -> bool {
    let content = content.trim();
    !content.is_empty() && super::deferred_messages::strip(deferred_goal).contains(content)
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
        assert!(!waits("opencode", &limited(usage_limit)));
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
        let other = active_mission(&store, "opencode").await;
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
    fn a_message_repeated_during_the_wait_is_kept_once() {
        let first = super::super::deferred_messages::encode(Uuid::new_v4(), "check the CI");
        let goal = super::super::deferred_messages::join("resume prompt", &first);
        assert!(already_deferred(&goal, "check the CI"));
        assert!(already_deferred(&goal, "  check the CI\n"));
        assert!(!already_deferred(&goal, "check the deploy"));
        assert!(!already_deferred(&goal, "   "));
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
}
