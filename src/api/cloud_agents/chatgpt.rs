//! Reuses the service-side browser, profile locks, ledger, and artifact validator.
use super::*;
use crate::api::{
    mission_store::MissionStore,
    runners::{chatgpt_ui, chatgpt_ui_jobs as jobs},
};
use std::{path::Path, sync::Arc};
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

fn failure_detail(result: &crate::agents::AgentResult) -> String {
    let stage = result
        .data
        .as_ref()
        .and_then(|data| data.get("driver_failure_stage"))
        .and_then(Value::as_str)
        .filter(|stage| {
            matches!(
                *stage,
                "launch"
                    | "recovery_probe"
                    | "model_selection"
                    | "resume"
                    | "continuation"
                    | "composer"
                    | "send"
                    | "fresh_chat"
                    | "blank_chat_check"
                    | "response"
                    | "final_history"
                    | "artifacts"
            )
        })
        .unwrap_or("unknown");
    // Keep the typed reason and an allowlisted stage. Browser output may
    // contain account/page content and must not be copied into this receipt.
    format!("ChatGPT requires account or submission reconciliation; reason={:?}; stage={stage}; no replacement conversation was created", result.terminal_reason)
}

/// Stored in `Turn::cursor`: this turn goes to a new conversation that starts
/// with the recorded history, because the original can no longer be opened.
const REPLACEMENT: &str = "replacement";
/// Recorded history carried into a replacement conversation, in characters.
const REPLACEMENT_HISTORY_LIMIT: usize = 60_000;

/// What is typed into ChatGPT for this turn. It must be the same on every
/// tick: the job ledger identifies a submission by this text.
fn outgoing(e: &Execution, i: usize) -> String {
    let turn = &e.turns[i];
    if turn.cursor.as_deref() != Some(REPLACEMENT) {
        return turn.prompt.clone();
    }
    // Most recent exchanges first, until the budget is spent.
    let mut kept = Vec::new();
    let mut budget = REPLACEMENT_HISTORY_LIMIT;
    for earlier in e.turns[..i].iter().rev() {
        let question = earlier.prompt.trim();
        let answer = earlier.result.as_deref().unwrap_or_default().trim();
        let exchange = format!("User:\n{question}\n\nAssistant:\n{answer}");
        let size = exchange.chars().count();
        if size > budget {
            // The latest exchange is always carried: its question in full when
            // it fits, and as much of the beginning of its answer as remains.
            if kept.is_empty() {
                let asked: String = question.chars().take(budget).collect();
                let room = budget.saturating_sub(asked.chars().count());
                let said: String = answer.chars().take(room).collect();
                kept.push(format!(
                    "User:\n{asked}\n\nAssistant:\n{said}\n[The rest of this answer was left out for length.]"
                ));
            }
            break;
        }
        budget -= size;
        kept.push(exchange);
    }
    kept.reverse();
    format!(
        "This continues an earlier conversation that can no longer be opened. Its exchanges follow, oldest first. Treat them as the history of this conversation and answer only the new message.\n\n{}\n\nNew message:\n{}",
        kept.join("\n\n"),
        turn.prompt.trim()
    )
}

/// Every earlier answer is on record, so the conversation can go on elsewhere.
fn history_recorded(e: &Execution, i: usize) -> bool {
    i > 0
        && e.turns[..i].iter().all(|t| {
            t.phase == Phase::ResponseComplete
                && t.result.as_deref().is_some_and(|r| !r.trim().is_empty())
        })
}

/// Marks the turn only. The stale ledger pointer is dropped once this state
/// is saved, and again at the start of any later tick that still finds it.
fn replace_conversation(e: &mut Execution, i: usize) {
    e.turns[i].cursor = Some(REPLACEMENT.into());
    e.turns[i].phase = Phase::Queued;
    e.turns[i].external_id = None;
    e.external_id = None;
    e.external_url = None;
}

/// The browser could not open the recorded conversation and sent nothing.
fn conversation_unreachable(result: &crate::agents::AgentResult) -> bool {
    result.data.as_ref().is_some_and(|data| {
        data.get("resume_resolution").and_then(Value::as_str) == Some("continuation_not_found")
            && data.get("fresh_prompt_submitted").and_then(Value::as_bool) == Some(false)
    })
}

pub(super) async fn tick(
    store: &Arc<dyn MissionStore>,
    mut e: Execution,
    app_dir: &Path,
) -> Result<(), String> {
    let Some(i) = e.turns.iter().position(|t| !t.phase.terminal()) else {
        return Ok(());
    };
    let mut phase = e.turns[i].phase;
    if matches!(phase, Phase::Incompatible | Phase::SubmissionUncertain) {
        return Ok(());
    }
    let mut prior = jobs::load_job(app_dir, e.mission_id);
    // A replacement turn whose ledger still describes another prompt was
    // interrupted before anything was sent: a submission would have rewritten
    // that record. Drop the pointer to the lost conversation and start over.
    if e.turns[i].cursor.as_deref() == Some(REPLACEMENT)
        && matches!(phase, Phase::Queued | Phase::Submitting)
        && prior.as_ref().is_some_and(|r| {
            r.state != jobs::JobState::Submitted
                && r.prompt_sha256
                    != jobs::prompt_fingerprint(
                        &outgoing(&e, i),
                        e.turns[i].model.as_deref().or(e.selection.model.as_deref()),
                    )
        })
    {
        jobs::forget_unreachable_conversation(app_dir, e.mission_id);
        prior = None;
        phase = Phase::Queued;
    }
    // Retry observation only, never submission, for transient hydration/transport
    // failures. Bound retries and preserve genuine authentication holds.
    if phase == Phase::ReconnectRequired
        && !prior.as_ref().is_some_and(|j| {
            j.state == jobs::JobState::Submitted
                && j.attempts < 4
                && (chrono::Utc::now() - j.updated_at).num_seconds() >= 60
                && matches!(
                    j.last_error_code.as_deref(),
                    Some("resume_not_found" | "transport_unavailable" | "browser_launch")
                )
        })
    {
        return Ok(());
    }

    if phase != Phase::Queued
        && prior.as_ref().is_none_or(|r| {
            r.state != jobs::JobState::Submitted
                || r.prompt_sha256
                    != jobs::prompt_fingerprint(
                        &outgoing(&e, i),
                        e.turns[i].model.as_deref().or(e.selection.model.as_deref()),
                    )
        })
    {
        e.turns[i].phase = Phase::SubmissionUncertain;
        worker::receipt(store, e, i).await?;
        return Ok(());
    }
    if i > 0
        && e.turns[i].cursor.as_deref() != Some(REPLACEMENT)
        && prior.as_ref().is_none_or(|r| {
            !jobs::continuable_conversation(r) && r.state != jobs::JobState::Submitted
        })
    {
        // Every earlier answer is on record: the conversation can go on in a
        // new chat that starts with that history. Nothing was sent for this
        // turn yet, so no submission can be duplicated.
        if phase != Phase::Queued || !history_recorded(&e, i) {
            e.turns[i].phase = Phase::SubmissionUncertain;
            e.turns[i].detail = Some("The original ChatGPT conversation cannot be verified".into());
            worker::receipt(store, e, i).await?;
            return Ok(());
        }
        replace_conversation(&mut e, i);
        // Saved as queued first: the pointer is dropped only once this is on
        // record, so an interruption in between is healed by the next tick.
        e = worker::save(store, e).await?;
        jobs::forget_unreachable_conversation(app_dir, e.mission_id);
    }
    e.turns[i].phase = Phase::Submitting;
    e = worker::save(store, e).await?;
    // Service-owned output directory: never the Orb folder and never browser credentials.
    let output = app_dir
        .join(".sandboxed-sh/cloud-artifacts")
        .join(e.mission_id.to_string());
    tokio::fs::create_dir_all(&output)
        .await
        .map_err(|e| e.to_string())?;
    let (tx, mut rx) = broadcast::channel(256);
    let message = outgoing(&e, i);
    let model = e.turns[i]
        .model
        .clone()
        .or_else(|| e.selection.model.clone());
    let account = e.selection.account.clone();
    let expected_conversation = e.external_id.clone();
    let run = chatgpt_ui::run_chatgpt_ui_account_turn(
        &output,
        &message,
        model.as_deref(),
        e.mission_id,
        tx,
        CancellationToken::new(),
        app_dir,
        Some(&account),
        expected_conversation.as_deref(),
    );
    tokio::pin!(run);
    let mut observer = tokio::time::interval(std::time::Duration::from_secs(2));
    // The driver streams the answer so far and its current step; publish them
    // on the observer cadence so the conversation shows progress, not silence.
    let (mut partial, mut step, mut events_open) = (None::<String>, None::<String>, true);
    let result = loop {
        tokio::select! {
            result = &mut run => break result,
            event = rx.recv(), if events_open => match event {
                Ok(crate::api::control::AgentEvent::TextDelta { content, .. }) => partial = Some(content).filter(|c| !c.trim().is_empty()),
                Ok(crate::api::control::AgentEvent::MissionActivity { label, .. }) => step = Some(label),
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => events_open = false,
            },
            _ = observer.tick() => {
                let mut changed = false;
                if let Some(job) = jobs::load_job(app_dir,e.mission_id).filter(|j| j.state == jobs::JobState::Submitted && j.prompt_sha256 == jobs::prompt_fingerprint(&message,model.as_deref())) {
                    e.external_id = Some(job.conversation_path.clone());
                    e.external_url = Some(format!("https://chatgpt.com{}",job.conversation_path));
                    e.turns[i].external_id = Some(job.job_id.to_string());
                    e.turns[i].phase = Phase::Running;
                    changed = true;
                }
                let detail = if partial.is_some() { None } else { step.clone() };
                if e.turns[i].detail != detail || (partial.is_some() && e.turns[i].result != partial) {
                    e.turns[i].detail = detail;
                    if partial.is_some() { e.turns[i].result = partial.clone(); }
                    changed = true;
                }
                if changed { worker::receipt(store,e.clone(),i).await?; }
            }
        }
    };
    // Preserve follow-ups which arrived while Pro was working.
    if let Some(latest) = store
        .cloud_executions()
        .await?
        .into_iter()
        .find(|r| r.mission_id == e.mission_id)
    {
        e = latest;
    }
    if let Some(job) = jobs::load_job(app_dir, e.mission_id) {
        e.external_id = Some(job.conversation_path.clone());
        e.external_url = Some(format!("https://chatgpt.com{}", job.conversation_path));
        e.turns[i].external_id = Some(job.job_id.to_string());
    }
    if result.success {
        e.turns[i].phase = Phase::ResponseComplete;
        e.turns[i].detail = None;
        e.turns[i].result = Some(result.output);
        e.turns[i].artifacts = result
            .data
            .as_ref()
            .and_then(|d| d.get("artifacts"))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
    } else if conversation_unreachable(&result)
        && e.turns[i].cursor.as_deref() != Some(REPLACEMENT)
        && history_recorded(&e, i)
    {
        // Found out only now, in the browser. Nothing was sent: the next tick
        // sends this message to a replacement conversation.
        replace_conversation(&mut e, i);
        e.turns[i].detail = Some(
            "The original ChatGPT conversation could not be opened; continuing in a new one".into(),
        );
        // A receipt keeps identifiers it is not given. Removing the pointer to
        // the lost conversation needs a full save.
        let mission = e.mission_id;
        worker::save(store, e).await?;
        jobs::forget_unreachable_conversation(app_dir, mission);
        return Ok(());
    } else {
        e.turns[i].phase = if jobs::load_job(app_dir, e.mission_id)
            .is_some_and(|j| j.state == jobs::JobState::Submitted)
        {
            Phase::ReconnectRequired
        } else {
            Phase::SubmissionUncertain
        };
        e.turns[i].detail = Some(failure_detail(&result));
    }
    worker::receipt(store, e, i).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn execution(turns: Vec<Turn>) -> Execution {
        serde_json::from_value(serde_json::json!({
            "mission_id": uuid::Uuid::new_v4(),
            "request_key": "k",
            "request_signature": "s",
            "revision": 1,
            "selection": {"provider":"chatgpt","account":"a","model":"gpt-6-pro","repository":null,"git_ref":null},
            "external_id": null,
            "external_url": null,
            "parent_mission_id": null,
            "turns": turns,
        }))
        .unwrap()
    }
    fn answered(prompt: &str, result: &str) -> Turn {
        let mut turn = Turn::new(prompt.into(), prompt.into());
        turn.phase = Phase::ResponseComplete;
        turn.result = Some(result.into());
        turn
    }

    #[test]
    fn a_replacement_conversation_starts_with_the_recorded_history() {
        let mut next = Turn::new("n".into(), "And in Rust?".into());
        let plain = execution(vec![answered("Hello", "Hi."), next.clone()]);
        assert_eq!(outgoing(&plain, 1), "And in Rust?");
        next.cursor = Some(REPLACEMENT.into());
        let e = execution(vec![
            answered("First question", "First answer"),
            answered("Second question", "Second answer"),
            next,
        ]);
        let sent = outgoing(&e, 2);
        let order: Vec<_> = [
            "First question",
            "First answer",
            "Second question",
            "Second answer",
            "New message:\nAnd in Rust?",
        ]
        .iter()
        .map(|part| sent.find(part).expect(part))
        .collect();
        assert!(order.windows(2).all(|pair| pair[0] < pair[1]), "{sent}");
        // The ledger identifies the submission by this text.
        assert_eq!(sent, outgoing(&e, 2));
    }

    #[test]
    fn only_an_unopened_conversation_with_nothing_sent_is_replaced() {
        let unreachable = crate::agents::AgentResult::failure("x", 0).with_data(
            serde_json::json!({"resume_resolution":"continuation_not_found","fresh_prompt_submitted":false}),
        );
        assert!(conversation_unreachable(&unreachable));
        for data in [
            serde_json::json!({"resume_resolution":"resume_mismatch","fresh_prompt_submitted":false}),
            serde_json::json!({"resume_resolution":"continuation_not_found","fresh_prompt_submitted":true}),
            serde_json::json!({"driver_failure_stage":"send"}),
        ] {
            assert!(!conversation_unreachable(
                &crate::agents::AgentResult::failure("x", 0).with_data(data)
            ));
        }
        let mut pending = Turn::new("p".into(), "Unanswered".into());
        pending.phase = Phase::SubmissionUncertain;
        let next = Turn::new("n".into(), "Next".into());
        assert!(history_recorded(
            &execution(vec![answered("a", "b"), next.clone()]),
            1
        ));
        assert!(!history_recorded(
            &execution(vec![pending, next.clone()]),
            1
        ));
        assert!(!history_recorded(&execution(vec![next]), 0));
        let mut e = execution(vec![
            answered("a", "b"),
            Turn::new("n".into(), "Next".into()),
        ]);
        e.external_id = Some("/c/old".into());
        e.turns[1].phase = Phase::Submitting;
        replace_conversation(&mut e, 1);
        assert_eq!(e.turns[1].phase, Phase::Queued);
        assert_eq!(e.turns[1].cursor.as_deref(), Some(REPLACEMENT));
        assert!(e.external_id.is_none());
    }

    #[test]
    fn a_replacement_keeps_the_most_recent_history_within_its_budget() {
        let mut next = Turn::new("n".into(), "Next".into());
        next.cursor = Some(REPLACEMENT.into());
        let long = "x".repeat(REPLACEMENT_HISTORY_LIMIT);
        let e = execution(vec![
            answered("Oldest question", &long),
            answered("Recent question", "Recent answer"),
            next,
        ]);
        let sent = outgoing(&e, 2);
        assert!(sent.contains("Recent question") && sent.contains("Recent answer"));
        assert!(!sent.contains("Oldest question"));
        assert!(sent.chars().count() < REPLACEMENT_HISTORY_LIMIT + 1_000);
        // One exchange larger than the budget keeps its question and the
        // beginning of its answer.
        let mut next = Turn::new("n".into(), "Next".into());
        next.cursor = Some(REPLACEMENT.into());
        let answer = format!("BEGINNING {} END", "y".repeat(REPLACEMENT_HISTORY_LIMIT));
        let sent = outgoing(
            &execution(vec![answered("The only question", &answer), next]),
            1,
        );
        assert!(sent.contains("User:\nThe only question\n\nAssistant:\nBEGINNING"));
        assert!(!sent.contains(" END"));
        assert!(sent.contains("left out for length"));
        // A long question is kept whole; the answer takes what is left.
        let mut next = Turn::new("n".into(), "Next".into());
        next.cursor = Some(REPLACEMENT.into());
        let question = format!(
            "{} QUESTION-END",
            "q".repeat(REPLACEMENT_HISTORY_LIMIT * 2 / 3)
        );
        let sent = outgoing(&execution(vec![answered(&question, &answer), next]), 1);
        assert!(sent.contains("QUESTION-END\n\nAssistant:\nBEGINNING"));
        assert!(sent.chars().count() < REPLACEMENT_HISTORY_LIMIT + 1_000);
    }

    #[test]
    fn failure_receipt_preserves_stage_without_copying_browser_content() {
        let result = crate::agents::AgentResult::failure("private browser page content", 0)
            .with_terminal_reason(crate::agents::TerminalReason::AuthError)
            .with_data(serde_json::json!({"driver_failure_stage":"model_selection"}));
        let detail = super::failure_detail(&result);
        assert!(detail.contains("AuthError"));
        assert!(detail.contains("stage=model_selection"));
        assert!(!detail.contains("private browser"));
        let result = result
            .with_data(serde_json::json!({"driver_failure_stage":"private browser page content"}));
        assert!(super::failure_detail(&result).contains("stage=unknown"));
    }
}
