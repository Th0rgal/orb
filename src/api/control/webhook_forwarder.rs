//! Paloma webhook forwarding of mission status callbacks.

use super::*;

/// Statuses worth forwarding to an external consumer (Paloma/Hermes): a mission
/// that FINISHED, hit a terminal failure, now needs the user, or was
/// acknowledged. We still skip the live churn (pending→active→paused) so a
/// callback means "something actionable happened", not "the status field moved".
///
/// `Interrupted` is included (P#1 asks for it) even though it can be emitted
/// transiently as resume-prep when a paused mission resumes — consumers dedupe
/// on the `event_id`/`sequence` carried in the payload and can treat a quickly
/// superseded interrupted→active as a no-op.
pub(super) fn webhook_forwardable_status(status: MissionStatus) -> bool {
    matches!(
        status,
        MissionStatus::Completed
            | MissionStatus::Failed
            | MissionStatus::NotFeasible
            | MissionStatus::Blocked
            | MissionStatus::AwaitingUser
            | MissionStatus::Interrupted
            | MissionStatus::Acknowledged
    )
}

pub(super) async fn current_callback_snapshot(
    store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    status: MissionStatus,
) -> Option<(Option<MissionRun>, MissionCompletionSnapshot)> {
    let before = store.get_mission(mission_id).await.ok().flatten()?;
    if before.status != status {
        return None;
    }
    let run = store.get_latest_mission_run(mission_id).await.ok()?;
    let events = store
        .get_events_before(
            mission_id,
            i64::MAX,
            Some(&["mission_status_changed"]),
            Some(16),
        )
        .await
        .ok()?;
    let event = events.into_iter().rev().find(|event| {
        event
            .metadata
            .get("status")
            .and_then(serde_json::Value::as_str)
            == Some(status.to_string().as_str())
            && before
                .activity
                .last_status_change_at
                .as_ref()
                .is_none_or(|changed| event.timestamp >= *changed)
    });
    let (captured, completion) = match (run.as_ref(), event) {
        (Some(run), Some(event)) => {
            let captured: Option<MissionRun> = event
                .metadata
                .get("execution")
                .cloned()
                .and_then(|value| serde_json::from_value(value).ok());
            let completion: Option<MissionCompletionSnapshot> = event
                .metadata
                .get("completion")
                .cloned()
                .and_then(|value| serde_json::from_value(value).ok());
            match (captured, completion) {
                (Some(captured), Some(completion))
                    if captured.run_id == run.run_id && captured.generation == run.generation =>
                {
                    (Some(captured), completion)
                }
                (None, None) => (
                    None,
                    MissionCompletionSnapshot {
                        result_summary: (!event.content.trim().is_empty()).then_some(event.content),
                        terminal_reason: before.terminal_reason.clone(),
                        terminal_evidence: before.terminal_evidence.clone(),
                    },
                ),
                _ => return None,
            }
        }
        (Some(_), None) if before.terminal_reason.as_deref() == Some("server_shutdown") => (
            None,
            MissionCompletionSnapshot {
                // Startup/drain intentionally persist this status without a
                // terminal event. Preserve its unbound outage notification.
                result_summary: None,
                terminal_reason: before.terminal_reason.clone(),
                terminal_evidence: before.terminal_evidence.clone(),
            },
        ),
        (Some(_), None) => return None, // exact event may still be in the logger queue
        (None, event) => (
            None,
            MissionCompletionSnapshot {
                result_summary: event
                    .and_then(|event| (!event.content.trim().is_empty()).then_some(event.content)),
                terminal_reason: before.terminal_reason.clone(),
                terminal_evidence: before.terminal_evidence.clone(),
            },
        ),
    };
    let after = store.get_mission(mission_id).await.ok().flatten()?;
    let checked_run = store.get_latest_mission_run(mission_id).await.ok()?;
    if before.updated_at != after.updated_at
        || after.status != status
        || run.as_ref().map(|r| (r.run_id, r.generation))
            != checked_run.as_ref().map(|r| (r.run_id, r.generation))
        || run
            .as_ref()
            .is_some_and(|run| run.started_at > before.updated_at)
    {
        return None;
    }
    Some((captured, completion))
}

pub(super) async fn callback_snapshot(
    store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    status: MissionStatus,
    execution: Option<MissionRun>,
    completion: Option<MissionCompletionSnapshot>,
    reconcile_current: bool,
) -> (Option<MissionRun>, Option<MissionCompletionSnapshot>) {
    if reconcile_current {
        match current_callback_snapshot(store, mission_id, status).await {
            Some((run, completion)) => (run, Some(completion)),
            None => (None, None),
        }
    } else {
        (execution, completion)
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn paloma_webhook_forwarder_loop(
    app_state: Arc<std::sync::OnceLock<std::sync::Weak<AppState>>>,
    mut events_rx: broadcast::Receiver<AgentEvent>,
    mission_store: Arc<dyn MissionStore>,
    workspaces: workspace::SharedWorkspaceStore,
    working_dir: PathBuf,
    url: String,
    secret: Option<String>,
    http: reqwest::Client,
) {
    tracing::info!(webhook_url = %url, "Paloma mission-status webhook forwarder started");
    // The dedupe record is DURABLE and success-gated: a marker means "this
    // status has been fully processed" — trivially on observation for
    // non-forwardable statuses, only after a successful POST for forwardable
    // ones. That closes the two loss windows the in-memory map had: a restart
    // blanking history, and delivery failure counting as delivery. Divergence
    // store-vs-marker is exactly the set of undelivered transitions, and the
    // sweep retries them until they land.
    let markers = super::super::webhook_markers::MarkerStore::load(&working_dir);
    let first_boot = !markers.loaded_from_disk;
    let markers = Arc::new(tokio::sync::Mutex::new(markers));
    if first_boot {
        // Adopt current history without forwarding any of it: pre-feature
        // missions have long-settled statuses, and replaying them as fresh
        // events would flood every bound conversation exactly once.
        let mut adopted = 0usize;
        let mut offset = 0usize;
        let mut guard = markers.lock().await;
        while offset < 5_000 {
            let page = match mission_store.list_missions(500, offset).await {
                Ok(page) => page,
                Err(_) => break,
            };
            if page.is_empty() {
                break;
            }
            let len = page.len();
            for mission in page {
                guard.set(mission.id, mission.status);
                adopted += 1;
            }
            if len < 500 {
                break;
            }
            offset += 500;
        }
        drop(guard);
        tracing::info!(
            adopted,
            "webhook markers: first boot, adopted current mission statuses"
        );
    }
    // Transitions currently being POSTed, so the sweep cannot double-send what
    // the broadcast arm already has in flight (and vice versa).
    let in_flight: Arc<tokio::sync::Mutex<std::collections::HashSet<(Uuid, MissionStatus)>>> =
        Arc::new(tokio::sync::Mutex::new(std::collections::HashSet::new()));
    // Bound concurrent in-flight callbacks (each does a get_mission + HTTP POST).
    let sem = Arc::new(tokio::sync::Semaphore::new(8));
    // Process-monotonic sequence so the consumer can order events and dedupe
    // (at-least-once delivery: a single logical event keeps one `event_id`
    // across retries). Resets on restart — `event_id` is the durable key.
    let sequence = Arc::new(std::sync::atomic::AtomicU64::new(0));
    // One forwarding path shared by the live broadcast arm and the
    // reconcile sweep below, so a transition can never be forwardable in
    // one and skipped by the other.
    let http_c = http.clone();
    let url_c = url.clone();
    let secret_c = secret.clone();
    let mission_store_c = Arc::clone(&mission_store);
    let workspaces_c = workspaces.clone();
    let working_dir_c = working_dir.clone();
    let sem_c = Arc::clone(&sem);
    let sequence_c = Arc::clone(&sequence);
    let markers_c = Arc::clone(&markers);
    let in_flight_c = Arc::clone(&in_flight);
    let forward = move |mission_id: Uuid,
                        status: MissionStatus,
                        old_status: Option<MissionStatus>,
                        event_execution: Option<MissionRun>,
                        event_completion: Option<MissionCompletionSnapshot>,
                        reconcile_current: bool| {
        let app_state = app_state.clone();
        let http = http_c.clone();
        let url = url_c.clone();
        let secret = secret_c.clone();
        let mission_store = Arc::clone(&mission_store_c);
        let workspaces = workspaces_c.clone();
        let working_dir = working_dir_c.clone();
        let sem = Arc::clone(&sem_c);
        let sequence = Arc::clone(&sequence_c);
        let markers = Arc::clone(&markers_c);
        let in_flight = Arc::clone(&in_flight_c);
        // Stable per-logical-event identity for idempotent consumers.
        let event_id = Uuid::new_v4();
        let seq = sequence.fetch_add(1, std::sync::atomic::Ordering::SeqCst);

        // The mission load + POST run in a spawned, concurrency-bounded
        // task so neither a slow DB read nor a slow webhook can stall the
        // caller.
        tokio::spawn(async move {
            let _permit = sem.acquire_owned().await;
            let mission = mission_store.get_mission(mission_id).await.ok().flatten();
            let title = mission
                .as_ref()
                .and_then(|mission| mission.title.clone())
                .unwrap_or_else(|| mission_id.to_string());
            let project = mission.as_ref().map(|m| &m.project);
            // Live events can only carry producer-captured identity. In
            // particular, an unbound historical event must not adopt a later
            // generation just because that generation reached the same status.
            let (run, completion) = callback_snapshot(
                &mission_store,
                mission_id,
                status,
                event_execution,
                event_completion,
                reconcile_current,
            )
            .await;
            if reconcile_current && completion.is_none() {
                // Keep the marker pending until the precise event is persisted.
                in_flight.lock().await.remove(&(mission_id, status));
                return;
            }
            let wake = mission
                .as_ref()
                .map(|m| super::super::mission_horizon::wake_fields_for_mission(m, &working_dir));
            // A worker of another mission reports to that mission. Without a
            // conversation of its own or a bound project conversation, waking
            // Hermes would only open a throwaway session that acts on its own
            // (289 such sessions in two days started review missions nobody
            // asked for). The transition is recorded as handled.
            if let Some(m) = mission.as_ref() {
                if super::super::mission_horizon::reports_to_parent_mission(m, wake.as_ref()) {
                    tracing::info!(
                        mission_id = %mission_id,
                        parent = ?m.parent_mission_id,
                        ?status,
                        "status callback not sent: the mission reports to its parent mission"
                    );
                    markers.lock().await.set(mission_id, status);
                    in_flight.lock().await.remove(&(mission_id, status));
                    return;
                }
            }
            let mut remote_jobs = crate::remote_node::job_ledger::load(&working_dir)
                .await
                .unwrap_or_default()
                .into_iter()
                .filter(|handle| handle.mission_id == mission_id)
                .map(|handle| {
                    serde_json::json!({
                        "job_id": handle.job_id,
                        "node_id": handle.node_id,
                        "kind": handle.kind,
                        "accepted_at": handle.accepted_at,
                        "heartbeat_at": handle.heartbeat_at,
                        "identity": handle.identity,
                    })
                })
                .collect::<Vec<_>>();
            remote_jobs.extend(
                crate::remote_node::job_ledger::terminal_receipts_for_mission(
                    &working_dir,
                    mission_id,
                )
                .await
                .unwrap_or_default()
                .into_iter()
                .rev()
                .take(16)
                .map(|receipt| {
                    serde_json::json!({
                        "job_id": receipt.job_id,
                        "node_id": receipt.node_id,
                        "kind": "remote_build_receipt",
                        "state": receipt.state,
                        "started_at": receipt.started_at,
                        "finished_at": receipt.finished_at,
                        "exit_status": receipt.exit_status,
                        "identity": receipt.identity,
                        "artifacts": receipt.artifacts,
                    })
                }),
            );
            let terminal_reason = if completion.is_some() || run.is_some() {
                completion
                    .as_ref()
                    .and_then(|snapshot| snapshot.terminal_reason.as_deref())
            } else {
                mission
                    .as_ref()
                    .and_then(|mission| mission.terminal_reason.as_deref())
            };
            let terminal_evidence = if completion.is_some() || run.is_some() {
                completion
                    .as_ref()
                    .and_then(|snapshot| snapshot.terminal_evidence.as_deref())
            } else {
                mission
                    .as_ref()
                    .and_then(|mission| mission.terminal_evidence.as_deref())
            };
            let recommended_action = match terminal_reason {
                Some("server_shutdown" | "orphan_no_runner") => "resume_once",
                Some("native_goal_stopped") => "resolve_stop_then_resume",
                Some("codex_continuity_required" | "native_continuity_required") => {
                    "reconcile_native_session_before_resume"
                }
                Some("auth_error") => "disable_provider_and_reroute",
                Some("rate_limited" | "capacity_limited") => "reroute_or_queue",
                Some("watchdog_stalled" | "cancelled") => "inspect_artifacts",
                _ if status == MissionStatus::Interrupted => "reconcile_then_resume",
                _ if status == MissionStatus::Failed => "classify_failure",
                _ if status == MissionStatus::AwaitingUser => "inspect_result",
                _ => "notify",
            };
            // Resolve workspace_name from the registry (the store row
            // usually leaves it null), so the payload is self-contained.
            let workspace_name = match mission.as_ref() {
                Some(m) => match m.workspace_name.clone() {
                    Some(name) => Some(name),
                    None => workspaces.get(m.workspace_id).await.map(|ws| ws.name),
                },
                None => None,
            };
            // The mission's ACTUAL final output — not just status metadata — so
            // a mission-backed delegation returns a real work product to the
            // delegating Hermes agent (the fold prefers `result_summary`).
            // Fetched only for terminal (forwardable) transitions; best-effort.
            let result_summary: Option<String> = if completion.is_some() || run.is_some() {
                completion
                    .as_ref()
                    .and_then(|snapshot| snapshot.result_summary.clone())
            } else if webhook_forwardable_status(status) {
                mission_store
                    .latest_assistant_text(mission_id)
                    .await
                    .ok()
                    .flatten()
            } else {
                None
            };
            let body = serde_json::json!({
                // Idempotency / ordering (P#6): consumers dedupe on
                // `event_id` and may order by `sequence`.
                "event_id": event_id,
                // The mission's final assistant output on terminal transitions.
                "result_summary": result_summary,
                "sequence": seq,
                "mission_id": mission_id,
                "old_status": old_status,
                "status": status,
                // Event-type mirror of `status` so consumers with
                // route-level event filters (e.g. the Hermes webhook
                // platform reads `payload.type`) can drop unwanted
                // transitions like `acknowledged` before spawning an
                // agent run.
                "type": status,
                "title": title,
                "short_description": mission
                    .as_ref()
                    .and_then(|m| m.short_description.clone()),
                "workspace_id": mission.as_ref().map(|m| m.workspace_id),
                "workspace_name": workspace_name,
                "backend": mission.as_ref().map(|m| m.backend.clone()),
                "terminal_reason": terminal_reason,
                // What the terminating guard OBSERVED. Without it, consumers
                // invent causes: "transport bug", "GitHub is disabled",
                // "pool needs re-provisioning" — all measured this week.
                "terminal_evidence": terminal_evidence,
                "resumable": matches!(status, MissionStatus::Interrupted | MissionStatus::Failed | MissionStatus::Blocked),
                "recommended_action": recommended_action,
                "execution": run.as_ref().map(|run| serde_json::json!({
                    "run_id": run.run_id,
                    "generation": run.generation,
                    "state": run.execution_state,
                    "heartbeat_at": run.heartbeat_at,
                    "scope_unit": run.scope_unit,
                })),
                "remote_jobs": remote_jobs,
                "updated_at": mission.as_ref().map(|m| m.updated_at.clone()),
                // When the status itself last changed (P#5) — the most
                // relevant staleness anchor for a status-change webhook.
                "last_status_change_at": mission
                    .as_ref()
                    .and_then(|m| m.activity.last_status_change_at.clone()),
                // Project tagging so Paloma can route by project/track/
                // intent/PR instead of parsing titles.
                "project": project.and_then(|p| p.project.clone()),
                "track": project.and_then(|p| p.track.clone()),
                "intent": project.and_then(|p| p.intent.clone()),
                "github_pr": project.and_then(|p| p.github_pr.clone()),
                "tags": project.map(|p| p.tags.clone()).unwrap_or_default(),
                // Creation provenance. Without these, a status webhook
                // lands in an isolated consumer session with no way
                // back to the conversation that started the mission —
                // results then sit acknowledged and unreported. The
                // consumer routes the completion into `origin_session`.
                //
                // TRUST: `origin_session` is a routing HINT, not
                // authority. It is declared by the creating client and
                // the MCP transport carries no per-call session
                // context to verify it against, so a delivery handler
                // MUST confirm the target conversation actually
                // references this mission_id before delivering there,
                // and fall back to its default notification path
                // otherwise.
                "origin": mission.as_ref().and_then(|m| m.origin.clone()),
                "origin_session": mission
                    .as_ref()
                    .and_then(|m| m.origin_session_id.clone()),
                // Producer-resolved wake tip: the bound project conversation
                // if one exists, else the creating origin. Hermes prefers
                // this over opening an isolated webhook session.
                "wake_session": wake.as_ref().and_then(|w| w.session.clone()),
                "wake_source": wake.as_ref().map(|w| w.source),
                // Track state so a watchdog can tell "intentionally
                // waiting (CI/review/external)" from "no worker = stuck".
                "desired_state": project.and_then(|p| p.desired_state.clone()),
                "next_check_at": project.and_then(|p| p.next_check_at.clone()),
                // For awaiting_user, whether the agent needs a decision
                // or is just waiting to be acked/merged.
                "awaiting_kind": mission
                    .as_ref()
                    .and_then(|m| m.awaiting_kind)
                    .map(|k| k.as_str()),
            });

            // Serialize once so the signature is computed over the
            // exact bytes sent (consumers verify HMAC over the raw
            // body, e.g. the Hermes webhook platform's GitHub-style
            // `X-Hub-Signature-256` check).
            let payload = match serde_json::to_vec(&body) {
                Ok(bytes) => bytes,
                Err(err) => {
                    tracing::warn!(
                        mission_id = %mission_id,
                        "Failed to serialize Paloma webhook payload: {}",
                        err
                    );
                    return;
                }
            };
            let signature = secret.as_ref().and_then(|secret| {
                use hmac::{Hmac, Mac};
                let mut mac = Hmac::<sha2::Sha256>::new_from_slice(secret.as_bytes()).ok()?;
                mac.update(&payload);
                Some(format!(
                    "sha256={}",
                    hex::encode(mac.finalize().into_bytes())
                ))
            });

            // At-least-once: retry transient failures with the SAME
            // event_id so the consumer can dedupe. Bounded so a dead
            // endpoint can't pile up tasks.
            const MAX_ATTEMPTS: u32 = 3;
            for attempt in 1..=MAX_ATTEMPTS {
                let mut request = http
                    .post(&url)
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(payload.clone());
                if let Some(signature) = signature.as_deref() {
                    request = request.header("X-Hub-Signature-256", signature);
                }
                match request.send().await {
                    Ok(resp) if resp.status().is_success() => {
                        // Only a delivered event earns its durable marker. An
                        // exhausted retry leaves it unset, so the 60s sweep
                        // re-sends until the consumer is reachable again.
                        markers.lock().await.set(mission_id, status);
                        if webhook_forwardable_status(status) {
                            if let Some(slug) = mission
                                .as_ref()
                                .and_then(|m| m.project.project.clone())
                                .filter(|slug| !slug.is_empty())
                            {
                                if let Some(state) =
                                    app_state.get().and_then(std::sync::Weak::upgrade)
                                {
                                    tokio::spawn(async move {
                                        super::super::project_controller::wake_controller_for_slug(
                                            state, &slug,
                                        )
                                        .await;
                                    });
                                }
                            }
                        }
                        break;
                    }
                    Ok(resp) => {
                        tracing::warn!(
                            mission_id = %mission_id,
                            webhook_url = %url,
                            attempt,
                            status = %resp.status(),
                            "Paloma webhook returned non-success status"
                        );
                    }
                    Err(err) => {
                        tracing::warn!(
                            mission_id = %mission_id,
                            webhook_url = %url,
                            attempt,
                            "Failed to forward Paloma mission status webhook: {}",
                            err
                        );
                    }
                }
                if attempt < MAX_ATTEMPTS {
                    tokio::time::sleep(std::time::Duration::from_millis(250 * attempt as u64))
                        .await;
                }
            }
            in_flight.lock().await.remove(&(mission_id, status));
        });
    };
    // The broadcast channel is lossy under bursts, and not every status
    // writer broadcasts. Measured 2026-08-06: mission 45e54e0b reached
    // awaiting_user and acknowledged at 09:35:42Z, its origin conversation
    // was adopted and waiting, and neither transition was ever forwarded --
    // no lag warning, nothing to retry, the conversation simply never woke.
    // The sweep reconciles from the store: any mission whose CURRENT status
    // is forwardable, differs from what we last forwarded, and changed
    // recently is forwarded now. Older divergences are adopted silently so
    // a fresh map after restart cannot replay history.
    let mut reconcile = tokio::time::interval(std::time::Duration::from_secs(60));
    reconcile.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        let recv = tokio::select! {
            result = events_rx.recv() => Some(result),
            _ = reconcile.tick() => None,
        };
        let Some(result) = recv else {
            let missions = match mission_store.list_missions(400, 0).await {
                Ok(missions) => missions,
                Err(_) => continue,
            };
            for mission in missions {
                let status = mission.status;
                let prior = markers.lock().await.get(mission.id);
                if prior == Some(status) {
                    continue;
                }
                if !webhook_forwardable_status(status) {
                    // Nothing to deliver; recording it keeps re-entry
                    // detection exact (A -> B -> A must forward A again).
                    markers.lock().await.set(mission.id, status);
                    continue;
                }
                if !in_flight.lock().await.insert((mission.id, status)) {
                    continue;
                }
                // No recency window: the marker file is the durable authority,
                // so a divergence IS an undelivered transition, however old --
                // that is the whole lossless-across-outages property. First
                // boot cannot replay history because adoption above marked it.
                tracing::info!(
                    mission_id = %mission.id,
                    ?status,
                    "webhook reconcile: forwarding a status transition the \
                     broadcast never delivered"
                );
                forward(mission.id, status, prior, None, None, true);
            }
            continue;
        };
        match result {
            Ok(AgentEvent::MissionStatusChanged {
                mission_id,
                status,
                execution,
                completion,
                ..
            }) => {
                let old_status = markers.lock().await.get(mission_id);
                if old_status == Some(status) {
                    continue;
                }
                if !webhook_forwardable_status(status) {
                    markers.lock().await.set(mission_id, status);
                    continue;
                }
                if !in_flight.lock().await.insert((mission_id, status)) {
                    continue;
                }
                forward(mission_id, status, old_status, execution, completion, false);
            }
            Ok(_) => {}
            Err(broadcast::error::RecvError::Lagged(dropped)) => {
                tracing::warn!(
                    dropped,
                    webhook_url = %url,
                    "Paloma webhook forwarder lagged; continuing with latest event"
                );
            }
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
}
