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

pub(super) async fn tick(
    store: &Arc<dyn MissionStore>,
    mut e: Execution,
    app_dir: &Path,
) -> Result<(), String> {
    let Some(i) = e.turns.iter().position(|t| !t.phase.terminal()) else {
        return Ok(());
    };
    let phase = e.turns[i].phase;
    if matches!(phase, Phase::Incompatible | Phase::SubmissionUncertain) {
        return Ok(());
    }
    let prior = jobs::load_job(app_dir, e.mission_id);
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
                        &e.turns[i].prompt,
                        e.turns[i].model.as_deref().or(e.selection.model.as_deref()),
                    )
        })
    {
        e.turns[i].phase = Phase::SubmissionUncertain;
        worker::receipt(store, e, i).await?;
        return Ok(());
    }
    if i > 0
        && prior.as_ref().is_none_or(|r| {
            !jobs::continuable_conversation(r) && r.state != jobs::JobState::Submitted
        })
    {
        e.turns[i].phase = Phase::SubmissionUncertain;
        e.turns[i].detail = Some("The original ChatGPT conversation cannot be verified".into());
        worker::receipt(store, e, i).await?;
        return Ok(());
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
    let message = e.turns[i].prompt.clone();
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
