use super::*;
use crate::api::mission_store::MissionStore;
use std::{sync::Arc, time::Duration};
/// Spawned once with the owning Core session. Orb is only an observer.
pub fn start(
    store: Arc<dyn MissionStore>,
    app_dir: std::path::PathBuf,
    config: crate::config::Config,
    user_id: String,
) {
    tokio::spawn(async move {
        let mut active = std::collections::HashMap::<Uuid, tokio::task::JoinHandle<()>>::new();
        loop {
            active.retain(|_, task| !task.is_finished());
            if let Ok(rows) = store.cloud_executions().await {
                for row in rows {
                    if active.contains_key(&row.mission_id)
                        || !row.turns.iter().any(|t| !t.phase.terminal())
                    {
                        continue;
                    }
                    let store = store.clone();
                    let dir = app_dir.clone();
                    let config = config.clone();
                    let user_id = user_id.clone();
                    active.insert(
                        row.mission_id,
                        tokio::spawn(async move {
                            let result = if row.selection.provider == Provider::Chatgpt {
                                super::chatgpt::tick(&store, row, &dir).await
                            } else if row.selection.provider == Provider::GrokBot {
                                super::grok::tick(&store, row).await
                            } else if row.selection.provider == Provider::Hermes {
                                super::hermes::tick(&store, row, &config, &user_id).await
                            } else {
                                tick(&store, row).await
                            };
                            if let Err(error) = result {
                                tracing::warn!(%error, "Cloud reconciliation deferred");
                            }
                        }),
                    );
                }
            }
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    });
}

pub(super) async fn save(store: &Arc<dyn MissionStore>, e: Execution) -> Result<Execution, String> {
    let revision = e.revision;
    store
        .save_cloud_execution(e, Some(revision), None, None, vec![])
        .await
}
pub(super) async fn tick(store: &Arc<dyn MissionStore>, mut e: Execution) -> Result<(), String> {
    let Some(i) = e.turns.iter().position(|t| !t.phase.terminal()) else {
        return Ok(());
    };
    if matches!(e.turns[i].phase, Phase::Incompatible) {
        return Ok(());
    }
    if e.selection.provider != Provider::CursorCloud {
        return Ok(());
    }
    let adapter = match cursor::Cursor::from_account(&e.selection.account) {
        Ok(a) => a,
        Err(_) => {
            // Keep cancellation and submission ambiguity: only a turn known not
            // to be in flight may later be requeued from ReconnectRequired.
            if !matches!(
                e.turns[i].phase,
                Phase::CancelRequested
                    | Phase::Submitting
                    | Phase::SubmissionUncertain
                    | Phase::ReconnectRequired
            ) {
                // Persist only the transition: the worker polls every 5s and an
                // unchanged receipt would still bump the revision and updated_at.
                e.turns[i].phase = Phase::ReconnectRequired;
                receipt(store, e, i).await?;
            }
            return Ok(());
        }
    };
    if e.turns[i].phase == Phase::Queued {
        // CAS claims the submission before the network boundary. A restart only reconciles.
        e.turns[i].phase = Phase::Submitting;
        e = save(store, e).await?;
        let result = if let Some(agent) = &e.external_id {
            adapter
                .follow_up(agent, &e.turns[i])
                .await
                .map(|run| (agent.clone(), run))
        } else {
            adapter.create(&e, &e.turns[i]).await
        };
        match result {
            Ok((agent, run)) => {
                e.external_url = Some(format!("https://cursor.com/agents/{agent}"));
                e.external_id = Some(agent);
                e.turns[i].external_id = Some(run);
                e.turns[i].phase = Phase::Running;
            }
            Err(error) => {
                e.turns[i].phase = match error.as_str() {
                    "reconnect_required" => Phase::ReconnectRequired,
                    "quota_exhausted" | "invalid_request" => Phase::Failed,
                    "conflict" if e.external_id.is_some() => Phase::Queued,
                    _ => Phase::SubmissionUncertain,
                };
                e.turns[i].detail = Some(error);
            }
        }
        receipt(store, e, i).await?;
        return Ok(());
    }
    if e.turns[i].external_id.is_none() {
        // Only initial creation has a provider-enforced unique identity. A follow-up
        // without a receipt MUST NOT guess latestRunId or submit a second prompt.
        if i != 0 {
            // Authentication rejected this follow-up before any provider work
            // started: resubmit once the account answers again.
            if let (Phase::ReconnectRequired, Some(agent)) =
                (e.turns[i].phase, e.external_id.clone())
            {
                match adapter.agent(&agent).await {
                    Ok(_) => {
                        e.turns[i].phase = Phase::Queued;
                        e.turns[i].detail = None;
                    }
                    Err(error) => e.turns[i].detail = Some(error),
                }
                receipt(store, e, i).await?;
                return Ok(());
            }
            e.turns[i].phase = Phase::SubmissionUncertain;
            receipt(store, e, i).await?;
            return Ok(());
        }
        let agent_id = format!("bc-{}", e.mission_id);
        match adapter.agent(&agent_id).await {
            Ok(agent) => {
                if let Some(run) = agent["latestRunId"].as_str() {
                    e.external_id = Some(agent_id.clone());
                    e.external_url = Some(format!("https://cursor.com/agents/{agent_id}"));
                    e.turns[i].external_id = Some(run.into());
                    e.turns[i].phase = Phase::Running;
                } else {
                    e.turns[i].phase = Phase::SubmissionUncertain;
                }
            }
            Err(error) => {
                e.turns[i].phase = match error.as_str() {
                    "reconnect_required" => Phase::ReconnectRequired,
                    // The deterministic agent id was never created: nothing ran.
                    "not_found" => Phase::Queued,
                    _ => Phase::SubmissionUncertain,
                };
                e.turns[i].detail = (error != "not_found").then_some(error);
            }
        }
        receipt(store, e, i).await?;
        return Ok(());
    }
    let agent = e
        .external_id
        .clone()
        .ok_or("Missing durable agent identity")?;
    let run = e.turns[i]
        .external_id
        .clone()
        .ok_or("Missing run identity")?;
    if e.turns[i].phase == Phase::CancelRequested {
        if let Err(error) = adapter.cancel(&agent, &run).await {
            e.turns[i].detail = Some(error);
        }
    }
    if let Ok(events) = adapter
        .stream_window(&agent, &run, e.turns[i].cursor.as_deref())
        .await
    {
        for event in events {
            let cursor = event.id.clone();
            store.append_cloud_event(e.mission_id, event).await?;
            e.turns[i].cursor = Some(cursor);
        }
    }
    match adapter.observe(&agent, &run).await {
        Ok(value) => {
            let phase = cursor::phase(value["status"].as_str().unwrap_or(""));
            let turn = &mut e.turns[i];
            // Do not discard a durable cancellation request until termination is observed.
            if turn.phase != Phase::CancelRequested || phase.terminal() {
                turn.phase = phase;
            }
            turn.result = value["result"].as_str().map(str::to_owned);
            turn.branches = value
                .pointer("/git/branches")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if phase.terminal() {
                turn.artifacts = adapter
                    .results(&agent)
                    .await
                    .ok()
                    .and_then(|v| v["items"].as_array().cloned())
                    .unwrap_or_default();
                turn.usage = adapter.usage(&agent).await.ok();
            }
            turn.detail = None;
        }
        Err(error) => {
            if error == "reconnect_required" && e.turns[i].phase != Phase::CancelRequested {
                e.turns[i].phase = Phase::ReconnectRequired;
            }
            e.turns[i].detail = Some(error);
        }
    }
    receipt(store, e, i).await?;
    Ok(())
}

/// Persist remote identifiers even if a user queued another turn during the call.
/// The submission claim above remains a strict CAS and is never merged.
pub(super) async fn receipt(
    store: &Arc<dyn MissionStore>,
    observed: Execution,
    index: usize,
) -> Result<(), String> {
    for _ in 0..8 {
        let mut latest = store
            .cloud_executions()
            .await?
            .into_iter()
            .find(|e| e.mission_id == observed.mission_id)
            .ok_or("Cloud mission removed while observing")?;
        if let Some(agent) = &observed.external_id {
            if latest.external_id.as_ref().is_some_and(|old| old != agent) {
                return Err("External conversation identity changed".into());
            }
            latest.external_id = Some(agent.clone());
            latest.external_url = observed.external_url.clone();
        }
        if let Some(turn) = observed.turns.get(index) {
            if let Some(target) = latest.turns.iter_mut().find(|t| t.key == turn.key) {
                if target.phase.terminal() && !turn.phase.terminal() {
                    return Ok(());
                }
                let cancel = target.phase == Phase::CancelRequested && !turn.phase.terminal();
                let external_id = target.external_id.clone();
                *target = turn.clone();
                if target.external_id.is_none() {
                    target.external_id = external_id;
                }
                if cancel {
                    target.phase = Phase::CancelRequested;
                }
            }
        }
        let revision = latest.revision;
        match store
            .save_cloud_execution(latest, Some(revision), None, None, vec![])
            .await
        {
            Ok(_) => return Ok(()),
            Err(error) if error == "Cloud execution revision changed" => continue,
            Err(error) => return Err(error),
        }
    }
    Err("Cloud receipt conflicted repeatedly; reconcile before sending".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::mission_store::SqliteMissionStore;
    #[tokio::test]
    async fn cancellation_survives_missing_credentials_for_both_providers() {
        for provider in [Provider::CursorCloud, Provider::GrokBot] {
            let dir = tempfile::tempdir().unwrap();
            let store: Arc<dyn MissionStore> = Arc::new(
                SqliteMissionStore::new(dir.path().into(), "cancel-auth")
                    .await
                    .unwrap(),
            );
            let mut turn = Turn::new("turn".into(), "hello".into());
            turn.phase = Phase::CancelRequested;
            turn.external_id = Some("run".into());
            let e = Execution {
                parent_mission_id: None,
                mission_id: Uuid::new_v4(),
                request_key: "launch".into(),
                request_signature: "launch".into(),
                revision: 0,
                selection: Selection {
                    provider,
                    account: "missing-account".into(),
                    repository: None,
                    git_ref: None,
                    model: None,
                    model_params: vec![],
                },
                external_id: Some("agent".into()),
                external_url: None,
                turns: vec![turn],
            };
            let e = store
                .save_cloud_execution(e, None, None, None, vec![])
                .await
                .unwrap();
            if provider == Provider::CursorCloud {
                tick(&store, e).await.unwrap();
            } else {
                super::super::grok::tick(&store, e).await.unwrap();
            }
            assert_eq!(
                store.cloud_executions().await.unwrap()[0].turns[0].phase,
                Phase::CancelRequested
            );
        }
    }
    #[tokio::test]
    async fn a_disconnected_turn_is_not_rewritten_on_every_poll() {
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().into(), "disconnected")
                .await
                .unwrap(),
        );
        let e = Execution {
            parent_mission_id: None,
            mission_id: Uuid::new_v4(),
            request_key: "launch".into(),
            request_signature: "launch".into(),
            revision: 0,
            selection: Selection {
                provider: Provider::CursorCloud,
                account: "missing-account".into(),
                repository: None,
                git_ref: None,
                model: None,
                model_params: vec![],
            },
            external_id: None,
            external_url: None,
            turns: vec![Turn::new("turn".into(), "hello".into())],
        };
        let e = store
            .save_cloud_execution(e, None, None, None, vec![])
            .await
            .unwrap();
        tick(&store, e).await.unwrap();
        let first = store.cloud_executions().await.unwrap().remove(0);
        assert_eq!(first.turns[0].phase, Phase::ReconnectRequired);
        tick(&store, first.clone()).await.unwrap();
        tick(&store, first.clone()).await.unwrap();
        assert_eq!(
            store.cloud_executions().await.unwrap()[0].revision,
            first.revision
        );
    }

    #[tokio::test]
    async fn missing_credentials_never_hide_an_ambiguous_submission() {
        // A turn that may already be in flight must not become ReconnectRequired:
        // that phase is requeued after reconnecting and would submit twice.
        for phase in [Phase::Submitting, Phase::SubmissionUncertain] {
            let dir = tempfile::tempdir().unwrap();
            let store: Arc<dyn MissionStore> = Arc::new(
                SqliteMissionStore::new(dir.path().into(), "ambiguous-auth")
                    .await
                    .unwrap(),
            );
            let mut first = Turn::new("first".into(), "hello".into());
            first.phase = Phase::ResponseComplete;
            first.external_id = Some("run".into());
            let mut follow = Turn::new("follow".into(), "again".into());
            follow.phase = phase;
            let e = Execution {
                parent_mission_id: None,
                mission_id: Uuid::new_v4(),
                request_key: "launch".into(),
                request_signature: "launch".into(),
                revision: 0,
                selection: Selection {
                    provider: Provider::CursorCloud,
                    account: "missing-account".into(),
                    repository: None,
                    git_ref: None,
                    model: None,
                    model_params: vec![],
                },
                external_id: Some("agent".into()),
                external_url: None,
                turns: vec![first, follow],
            };
            let e = store
                .save_cloud_execution(e, None, None, None, vec![])
                .await
                .unwrap();
            tick(&store, e).await.unwrap();
            assert_eq!(
                store.cloud_executions().await.unwrap()[0].turns[1].phase,
                phase
            );
        }
    }
    #[tokio::test]
    async fn remote_receipt_preserves_concurrent_followup_and_does_not_regress_completion() {
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().into(), "receipt-race")
                .await
                .unwrap(),
        );
        let initial = Execution {
            parent_mission_id: None,
            mission_id: Uuid::new_v4(),
            request_key: "launch".into(),
            request_signature: "launch".into(),
            revision: 0,
            selection: Selection {
                provider: Provider::CursorCloud,
                account: "cursor-default".into(),
                repository: None,
                git_ref: None,
                model_params: vec![],
                model: None,
            },
            external_id: None,
            external_url: None,
            turns: vec![Turn::new("first".into(), "Hello".into())],
        };
        let mut observed = store
            .save_cloud_execution(initial, None, None, None, vec![])
            .await
            .unwrap();
        observed.turns[0].phase = Phase::Submitting;
        observed = save(&store, observed).await.unwrap();
        let mut concurrent = observed.clone();
        concurrent
            .enqueue("next".into(), "Follow up".into())
            .unwrap();
        save(&store, concurrent).await.unwrap();
        observed.external_id = Some("bc-test".into());
        observed.turns[0].external_id = Some("run-test".into());
        observed.turns[0].phase = Phase::ResponseComplete;
        observed.turns[0].result = Some("Hello back".into());
        receipt(&store, observed.clone(), 0).await.unwrap();
        let row = store.cloud_executions().await.unwrap().remove(0);
        assert_eq!(row.turns.len(), 2);
        assert_eq!(row.turns[1].prompt, "Follow up");
        assert_eq!(row.turns[0].external_id.as_deref(), Some("run-test"));
        observed.turns[0].phase = Phase::Running;
        receipt(&store, observed, 0).await.unwrap();
        assert_eq!(
            store.cloud_executions().await.unwrap()[0].turns[0].phase,
            Phase::ResponseComplete
        );
    }
}
