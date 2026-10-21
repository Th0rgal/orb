//! Remote job leases, remote build waits/wakes, remote finalize and dispatch.

use super::*;

/// Delete every proxy key minted for `mission_id`'s remote launches.
pub(crate) async fn retire_remote_launch_keys(
    proxy_keys: &super::super::proxy_keys::ProxyApiKeyStore,
    mission_id: Uuid,
) {
    if let Err(error) = proxy_keys
        .delete_named_except(&remote_launch_key_name(mission_id), None)
        .await
    {
        tracing::warn!(%mission_id, %error, "remote launch proxy key retirement failed");
    }
}

/// Boot sweep: a `remote-launch:*` key minted before `boot_cutoff` whose
/// mission holds no ledger handle belongs to a launch of a previous process
/// that never reached submission or whose observer already finished. No node
/// job can still be using it (submission always follows the tentative ledger
/// record). Keys minted after the cutoff belong to this process's launches
/// and are left alone even when the ledger snapshot predates their handle.
pub(crate) async fn retire_orphaned_remote_launch_keys(
    proxy_keys: &super::super::proxy_keys::ProxyApiKeyStore,
    handles: &[crate::remote_node::job_ledger::JobHandle],
    boot_cutoff: chrono::DateTime<chrono::Utc>,
) {
    let live: HashSet<Uuid> = handles.iter().map(|handle| handle.mission_id).collect();
    for key in proxy_keys.list().await {
        let Some(mission_id) = key
            .name
            .strip_prefix("remote-launch:")
            .and_then(|id| Uuid::parse_str(id).ok())
        else {
            continue;
        };
        if key.created_at >= boot_cutoff {
            continue;
        }
        if !live.contains(&mission_id) {
            tracing::info!(%mission_id, key_id = %key.id, "retiring orphaned remote launch proxy key");
            let _ = proxy_keys.delete(key.id).await;
        }
    }
}

/// Owner id of the run lease held by a raw remote mission job's poll loop.
pub(crate) fn remote_job_lease_owner(job_id: Uuid) -> String {
    format!("remote-job:{job_id}")
}

/// Whether a run lease belongs to a raw remote mission job observer.
pub(crate) fn is_remote_mission_job_owner(owner_actor_id: &str) -> bool {
    owner_actor_id.starts_with("remote-job:")
}

/// Scope label recorded on a remote job lease so placement survives in the
/// durable run row after the ledger handle is retired.
pub(super) fn remote_job_lease_scope(node_id: &str) -> String {
    format!("remote-node:{node_id}")
}

/// Persist the initial prompt of a raw remote mission as a real (non-queued)
/// user message. Returns an error message shaped for the dispatch-failure
/// path: a remote mission whose prompt cannot be persisted must not be
/// dispatched, because nothing later would ever record what the user asked.
pub(super) async fn persist_remote_mission_prompt(
    control: &ControlState,
    mission_id: Uuid,
    user_id: &str,
    prompt: Option<(Uuid, String)>,
) -> Result<(), String> {
    let Some((id, content)) = prompt else {
        return Ok(());
    };
    let event = AgentEvent::UserMessage {
        id,
        content,
        queued: false,
        mission_id: Some(mission_id),
        source: Some(format!("api:{user_id}")),
    };
    control
        .mission_store
        .log_event(mission_id, &event)
        .await
        .map_err(|error| format!("remote mission prompt could not be persisted: {error}"))?;
    let _ = control.events_tx.send(event);
    Ok(())
}

/// Make an accepted raw remote mission job authoritative execution evidence.
///
/// Raw remote missions never start a local harness, so without this lease the
/// mission is an Active row with no runner and no run — exactly what the
/// stuck-mission watchdog repairs as an orphan (incident ab1792b4,
/// 2026-09-20: the watchdog interrupted a freshly dispatched dgx-spark
/// mission seven seconds after acceptance and the poll loop then cancelled
/// the node job as if an operator had asked for it). The poll loop refreshes
/// this lease on every successful observation and finishes it with the
/// job's terminal reason.
///
/// Returns the lease when this job owns it. A lease owned by anyone else is
/// left untouched; a mission that already left Active/Pending gets none.
pub(super) async fn ensure_remote_job_lease(
    mission_store: &dyn MissionStore,
    mission_id: Uuid,
    job_id: Uuid,
    node_id: &str,
) -> Result<Option<MissionRun>, String> {
    let owner_actor_id = remote_job_lease_owner(job_id);
    if let Some(run) = mission_store.get_active_mission_run(mission_id).await? {
        if run.owner_actor_id != owner_actor_id {
            return Ok(None);
        }
        mission_store
            .heartbeat_mission_run(
                run.run_id,
                run.generation,
                MissionExecutionState::WaitingRemoteJob,
                None,
            )
            .await?;
        return mission_store.get_active_mission_run(mission_id).await;
    }
    let Some(mission) = mission_store.get_mission(mission_id).await? else {
        return Ok(None);
    };
    if !matches!(
        mission.status,
        MissionStatus::Active | MissionStatus::Pending
    ) {
        return Ok(None);
    }
    let run = mission_store
        .begin_mission_run(
            mission_id,
            &owner_actor_id,
            Some(&remote_job_lease_scope(node_id)),
        )
        .await?;
    mission_store
        .heartbeat_mission_run(
            run.run_id,
            run.generation,
            MissionExecutionState::WaitingRemoteJob,
            None,
        )
        .await?;
    mission_store.get_active_mission_run(mission_id).await
}

/// Finish the run lease held by `job_id`'s observer. Returns the settled run
/// (for the terminal status event) when this job owned the lease.
pub(crate) async fn finish_remote_job_lease(
    mission_store: &dyn MissionStore,
    mission_id: Uuid,
    job_id: Uuid,
    terminal_reason: &str,
) -> Result<Option<MissionRun>, String> {
    let Some(run) = mission_store.get_active_mission_run(mission_id).await? else {
        return Ok(None);
    };
    if run.owner_actor_id != remote_job_lease_owner(job_id) {
        return Ok(None);
    }
    mission_store
        .finish_mission_run(run.run_id, run.generation, Some(terminal_reason))
        .await?;
    Ok(mission_store
        .get_latest_mission_run(mission_id)
        .await?
        .filter(|latest| latest.run_id == run.run_id))
}

/// Placement metadata of a raw remote mission job for mission read models.
///
/// While the job is in flight the durable ledger handle is the source; after
/// it is retired the run lease (owner `remote-job:<id>`, scope
/// `remote-node:<id>`) still names the placement. The fleet monitor's bounded
/// in-memory outcome adds the last node-reported state when it is known.
/// `None` means the mission never dispatched a raw remote job.
pub(super) fn remote_job_projection(
    handles: &[crate::remote_node::job_ledger::JobHandle],
    outcomes: &[crate::remote_node::DispatchOutcome],
    run: Option<&MissionRun>,
    mission_id: Uuid,
    now: chrono::DateTime<chrono::Utc>,
) -> Option<serde_json::Value> {
    use crate::remote_node::job_ledger::JobHandleKind;
    let handle = handles
        .iter()
        .filter(|handle| {
            // Remote-build submissions also write tentative handles; those
            // carry a validation identity and belong to a harness tool call,
            // not to a raw remote mission.
            handle.mission_id == mission_id
                && (handle.kind == JobHandleKind::Mission
                    || (handle.kind == JobHandleKind::Tentative && handle.identity.is_none()))
        })
        .max_by_key(|handle| (handle.submission_sequence, handle.started_at));
    let lease = run.filter(|run| is_remote_mission_job_owner(&run.owner_actor_id));
    let (job_id, node_id) = match (handle, lease) {
        (Some(handle), _) => (handle.job_id, handle.node_id.clone()),
        (None, Some(run)) => {
            let job_id = run
                .owner_actor_id
                .strip_prefix("remote-job:")
                .and_then(|id| Uuid::parse_str(id).ok())?;
            let node_id = run
                .scope_unit
                .as_deref()
                .and_then(|scope| scope.strip_prefix("remote-node:"))
                .unwrap_or("unknown")
                .to_string();
            (job_id, node_id)
        }
        (None, None) => return None,
    };
    let outcome = outcomes
        .iter()
        .find(|outcome| outcome.job_id == Some(job_id));
    let last_proof = handle.and_then(|handle| match (handle.heartbeat_at, handle.accepted_at) {
        (Some(heartbeat), Some(accepted)) => Some(heartbeat.max(accepted)),
        (Some(heartbeat), None) => Some(heartbeat),
        (None, accepted) => accepted,
    });
    let observed_age_secs =
        last_proof.map(|proof| now.signed_duration_since(proof).num_seconds().max(0));
    let phase = match handle {
        Some(handle) if handle.kind == JobHandleKind::Tentative => "submit_ambiguous",
        Some(handle) if handle.accepted_at.is_none() => "submit_ambiguous",
        Some(_) => {
            if observed_age_secs
                .is_some_and(|age| age <= super::super::supervision::REMOTE_JOB_UNOBSERVED_SECS)
            {
                "observed"
            } else {
                "reconnecting"
            }
        }
        None => match lease {
            Some(run) if run.execution_state.is_terminal() => "finished",
            _ => "lease_only",
        },
    };
    Some(serde_json::json!({
        "job_id": job_id,
        "node_id": node_id,
        "phase": phase,
        "node_state": outcome.map(|outcome| outcome.state.clone()),
        "exit_code": outcome.and_then(|outcome| outcome.exit_code),
        "error": outcome.and_then(|outcome| outcome.error.clone()),
        "accepted_at": handle.and_then(|handle| handle.accepted_at),
        "heartbeat_at": handle.and_then(|handle| handle.heartbeat_at),
        "observed_age_secs": observed_age_secs,
        "started_at": handle
            .map(|handle| handle.started_at)
            .or_else(|| outcome.map(|outcome| outcome.started_at)),
        "finished_at": outcome.and_then(|outcome| outcome.finished_at),
        "lease_state": lease.map(|run| run.execution_state),
        "terminal_reason": lease.and_then(|run| run.terminal_reason.clone()),
    }))
}

/// Ledger handles and recent fleet outcomes for [`remote_job_projection`].
/// An unreadable ledger degrades to "no in-flight handle" for read models;
/// liveness decisions never go through this path.
pub(super) async fn remote_job_projection_inputs(
    state: &AppState,
) -> (
    Vec<crate::remote_node::job_ledger::JobHandle>,
    Vec<crate::remote_node::DispatchOutcome>,
) {
    let handles = match crate::remote_node::job_ledger::load(&state.config.working_dir).await {
        Ok(handles) => handles,
        Err(error) => {
            tracing::debug!(
                ?error,
                "remote job ledger unreadable for mission read model"
            );
            Vec::new()
        }
    };
    (handles, state.fleet.recent_outcomes(256))
}

pub(super) fn attach_remote_job_to_mission_value(
    mut value: serde_json::Value,
    remote_job: Option<serde_json::Value>,
) -> serde_json::Value {
    if let Some(object) = value.as_object_mut() {
        object.insert(
            "remote_job".to_string(),
            remote_job.unwrap_or(serde_json::Value::Null),
        );
    }
    value
}

pub(super) async fn remote_build_wait_owner(
    state: &AppState,
    mission_id: Uuid,
) -> Result<Option<(RemoteMissionOwner, Option<ControlState>)>, String> {
    for session in state.control.all_sessions().await {
        match session.mission_store.get_mission(mission_id).await {
            Ok(Some(_)) => {
                return Ok(Some((RemoteMissionOwner::live(&session), Some(session))));
            }
            Ok(None) => {}
            Err(error) => tracing::warn!(
                %mission_id,
                %error,
                "remote-build owner lookup skipped an unavailable live store"
            ),
        }
    }
    Ok(
        super::super::mission_workspace_gc::persisted_mission_store(state, mission_id)
            .await?
            .map(|(store, _)| (RemoteMissionOwner::offline(store), None)),
    )
}

/// Make a durable remote-build handle authoritative execution evidence.
/// This is called both while the submitting actor is alive and by startup
/// reconciliation, so a backend restart can reconstruct the lease before an
/// old `acknowledged` presentation hides live compute.
pub(crate) async fn ensure_remote_build_wait(
    state: &AppState,
    mission_id: Uuid,
    job_id: Uuid,
) -> Result<bool, String> {
    let current_job = crate::remote_node::job_ledger::current_remote_build_wait_handle(
        &state.config.working_dir,
        mission_id,
    )
    .await
    .map_err(|error| format!("load current remote-build owner: {error}"))?;
    let current_job_id = current_job.as_ref().map(|handle| handle.job_id);
    if current_job_id != Some(job_id) {
        tracing::debug!(
            %mission_id,
            %job_id,
            current_job = ?current_job_id,
            "remote build retained for receipt reconciliation without owning the mission wait lease"
        );
        return Ok(false);
    }
    if !current_job
        .as_ref()
        .is_some_and(|handle| handle.expects_mission_continuation())
    {
        tracing::debug!(
            %mission_id,
            %job_id,
            "fire-and-forget remote build retained without a mission wait lease"
        );
        return Ok(false);
    }
    let Some((owner, _)) = remote_build_wait_owner(state, mission_id).await? else {
        return Ok(false);
    };
    let Some(mission) = owner.mission_store.get_mission(mission_id).await? else {
        return Ok(false);
    };
    let active_run = owner
        .mission_store
        .get_active_mission_run(mission_id)
        .await?;
    if active_run
        .as_ref()
        .is_some_and(|run| run.execution_state == MissionExecutionState::Stopping)
    {
        return Ok(false);
    }
    if active_run.is_none()
        && matches!(
            mission.status,
            MissionStatus::Interrupted
                | MissionStatus::Paused
                | MissionStatus::Blocked
                | MissionStatus::NotFeasible
        )
    {
        // An operator/policy terminalization with no run lease is deliberate.
        // Keep observing the node receipt, but never resurrect execution.
        return Ok(false);
    }
    if mission.status != MissionStatus::Active {
        owner
            .mission_store
            .update_mission_status(mission_id, MissionStatus::Active)
            .await?;
        owner.send(AgentEvent::MissionStatusChanged {
            completion: None,
            execution: None,
            mission_id,
            status: MissionStatus::Active,
            summary: Some(format!(
                "Reconciled live remote validation {job_id}; waiting for its terminal receipt"
            )),
        });
    }
    if let Some(run) = active_run {
        return owner
            .mission_store
            .heartbeat_mission_run(
                run.run_id,
                run.generation,
                MissionExecutionState::WaitingRemoteJob,
                None,
            )
            .await;
    }

    let run = owner
        .mission_store
        .begin_mission_run(mission_id, &format!("remote-build:{job_id}"), None)
        .await?;
    owner
        .mission_store
        .heartbeat_mission_run(
            run.run_id,
            run.generation,
            MissionExecutionState::WaitingRemoteJob,
            None,
        )
        .await
}

pub(super) fn remote_build_terminal_message(
    receipt: &crate::remote_node::job_ledger::RemoteJobReceipt,
) -> String {
    format!(
        "Remote validation reached terminal state. Reconcile this exact receipt before any new submission.\n\njob_id: {}\nnode_id: {}\nstate: {}\nexit_status: {:?}\nrepository: {}\ncommit: {}\ncommand: {}\ntoolchain: {}\nsource_bundle_digest: {}\n\nConfirm the live PR head still equals the validated commit. Treat a successful receipt for an older head as STALE_SUCCESS, not as an integration gate.",
        receipt.job_id,
        receipt.node_id,
        receipt.state,
        receipt.exit_status,
        receipt.identity.repository,
        receipt.identity.commit,
        receipt.identity.command.join(" "),
        receipt.identity.toolchain.as_deref().unwrap_or("unspecified"),
        receipt
            .identity
            .source_bundle_digest
            .as_deref()
            .unwrap_or("none"),
    )
}

pub(super) async fn record_suppressed_remote_build_terminal_event(
    state: &AppState,
    receipt: &crate::remote_node::job_ledger::RemoteJobReceipt,
    superseding_job_id: Uuid,
) -> Result<(), String> {
    let Some((owner, _)) = remote_build_wait_owner(state, receipt.mission_id).await? else {
        return Err("remote-build owner is not available yet".to_string());
    };
    let event = AgentEvent::AssistantMessage {
        id: Uuid::new_v5(
            &Uuid::NAMESPACE_URL,
            format!("sandboxed:remote-build-superseded-event:{}", receipt.job_id).as_bytes(),
        ),
        content: format!(
            "{}\n\nThis terminal wake was suppressed because newer validation job {} already owns the mission continuation. The receipt remains durable evidence only.",
            remote_build_terminal_message(receipt), superseding_job_id
        ),
        success: receipt.state == "succeeded" && receipt.exit_status == Some(0),
        cost_cents: 0,
        cost_source: crate::agents::CostSource::Unknown,
        usage: None,
        model: None,
        model_normalized: None,
        mission_id: Some(receipt.mission_id),
        shared_files: None,
        resumable: true,
        completion_evidence: None,
    };
    owner
        .mission_store
        .log_event(receipt.mission_id, &event)
        .await?;
    owner.send(event);
    Ok(())
}

/// Ask the live control actor whether it still owns the mission process.
///
/// The durable run can still say `waiting_remote_job` for a short window after
/// the synchronous remote-build tool has returned: the harness may already be
/// consuming the result or running its next tool. Closing that lease from the
/// receipt outbox would leave a live actor emitting stale-generation events.
/// Query the actor directly instead of inferring process ownership from the
/// persisted execution state.
pub(super) async fn control_actor_mission_run(
    cmd_tx: &mpsc::Sender<ControlCommand>,
    mission_id: Uuid,
) -> Result<Option<(Uuid, u64)>, String> {
    let (respond, response) = oneshot::channel();
    cmd_tx
        .send(ControlCommand::GetActorRunLease {
            mission_id,
            respond,
        })
        .await
        .map_err(|_| "remote-build control actor is unavailable".to_string())?;
    tokio::time::timeout(std::time::Duration::from_secs(5), response)
        .await
        .map_err(|_| "remote-build control actor ownership query timed out".to_string())?
        .map_err(|_| "remote-build control actor ownership query was dropped".to_string())
}

pub(super) fn select_actor_run_lease(
    mission_id: Uuid,
    main_running: bool,
    main_mission_id: Option<Uuid>,
    main_lease: Option<(Uuid, u64)>,
    parallel_running: bool,
    parallel_lease: Option<(Uuid, u64)>,
) -> Option<(Uuid, u64)> {
    if main_running && main_mission_id == Some(mission_id) {
        main_lease
    } else if parallel_running {
        parallel_lease
    } else {
        None
    }
}

pub(super) fn terminal_wake_must_wait_for_harness(
    execution_state: MissionExecutionState,
    actor_owns_run: bool,
) -> bool {
    execution_state != MissionExecutionState::WaitingRemoteJob && actor_owns_run
}

pub(super) async fn deliver_remote_build_terminal_wake(
    state: &AppState,
    receipt: &crate::remote_node::job_ledger::RemoteJobReceipt,
) -> Result<bool, String> {
    let Some((owner, live_session)) = remote_build_wait_owner(state, receipt.mission_id).await?
    else {
        return Ok(false);
    };
    let Some(mission) = owner.mission_store.get_mission(receipt.mission_id).await? else {
        return Ok(false);
    };
    if matches!(
        mission.status,
        MissionStatus::Interrupted
            | MissionStatus::Paused
            | MissionStatus::Blocked
            | MissionStatus::NotFeasible
    ) {
        let actor_still_owns_run = if let Some(session) = live_session.as_ref() {
            control_actor_mission_run(&session.cmd_tx, receipt.mission_id)
                .await?
                .is_some()
        } else {
            false
        };
        if !actor_still_owns_run {
            if let Some(run) = owner
                .mission_store
                .get_active_mission_run(receipt.mission_id)
                .await?
            {
                if run.execution_state == MissionExecutionState::WaitingRemoteJob {
                    owner
                        .mission_store
                        .finish_mission_run(
                            run.run_id,
                            run.generation,
                            Some("remote_build_terminal_after_mission_parked"),
                        )
                        .await?;
                }
            }
        }
        let event = AgentEvent::AssistantMessage {
            id: Uuid::new_v5(
                &Uuid::NAMESPACE_URL,
                format!("sandboxed:remote-build-terminal-event:{}", receipt.job_id).as_bytes(),
            ),
            content: remote_build_terminal_message(receipt),
            success: receipt.state == "succeeded" && receipt.exit_status == Some(0),
            cost_cents: 0,
            cost_source: crate::agents::CostSource::Unknown,
            usage: None,
            model: None,
            model_normalized: None,
            mission_id: Some(receipt.mission_id),
            shared_files: None,
            resumable: true,
            completion_evidence: None,
        };
        let _ = owner
            .mission_store
            .log_event(receipt.mission_id, &event)
            .await;
        owner.send(event);
        return Ok(true);
    }
    let active_run = owner
        .mission_store
        .get_active_mission_run(receipt.mission_id)
        .await?;
    let actor_run = if let Some(session) = live_session.as_ref() {
        control_actor_mission_run(&session.cmd_tx, receipt.mission_id).await?
    } else {
        None
    };
    if let Some((actor_run_id, actor_generation)) = actor_run {
        let actor_matches_lease = active_run
            .as_ref()
            .is_some_and(|run| run.run_id == actor_run_id && run.generation == actor_generation);
        if !actor_matches_lease {
            return Err(format!(
                "remote-build actor/run lease conflict for mission {}: actor run {:?} generation {:?}",
                receipt.mission_id, actor_run_id, actor_generation
            ));
        }
    }
    if let Some(run) = active_run {
        if run.execution_state != MissionExecutionState::WaitingRemoteJob {
            if terminal_wake_must_wait_for_harness(run.execution_state, actor_run.is_some()) {
                // The harness is still consuming the synchronous result. Let
                // that turn finish rather than racing it with a continuation.
                return Ok(false);
            }
            // The turn is gone but the parking heartbeat lost its race with
            // finalization (observed on srv3: terminal receipt present while
            // the durable run stayed `running` forever). The immutable remote
            // receipt now owns the continuation, so repair the orphaned run
            // before delivery instead of deferring the wake indefinitely.
            owner
                .mission_store
                .finish_mission_run(
                    run.run_id,
                    run.generation,
                    Some("remote_build_terminal_after_unparked_turn"),
                )
                .await?;
        } else if actor_run.is_none() {
            owner
                .mission_store
                .finish_mission_run(
                    run.run_id,
                    run.generation,
                    Some(&format!("remote_build_{}", receipt.state)),
                )
                .await?;
        }
    }

    let content = remote_build_terminal_message(receipt);
    let delivery_id = remote_build_terminal_delivery_id(receipt.job_id);
    if let Some(session) = live_session {
        let (respond, response) = oneshot::channel();
        session
            .cmd_tx
            .send(ControlCommand::UserMessage {
                id: delivery_id,
                content,
                agent: None,
                target_mission_id: Some(receipt.mission_id),
                strict: true,
                source: Some("remote-build-terminal".to_string()),
                respond,
            })
            .await
            .map_err(|_| "remote-build terminal control session unavailable".to_string())?;
        return match tokio::time::timeout(std::time::Duration::from_secs(10), response).await {
            Ok(Ok(
                UserMessageAck::Queued
                | UserMessageAck::Delivered
                | UserMessageAck::Continued { .. },
            )) => Ok(true),
            Ok(Ok(UserMessageAck::Rejected(error))) => Err(error),
            Ok(Ok(UserMessageAck::Dropped)) => Ok(false),
            Ok(Err(_)) => Ok(false),
            Err(_) => Ok(false),
        };
    }

    // No control actor is booted for this user. Persist one exact deferred
    // continuation and make the normal scheduler pick it up when the session
    // returns. Repeating this write after a crash is idempotent.
    owner
        .mission_store
        .set_deferred_goal(
            receipt.mission_id,
            Some(deferred_messages::encode(delivery_id, &content)),
        )
        .await?;
    owner
        .mission_store
        .update_mission_status(receipt.mission_id, MissionStatus::Pending)
        .await?;
    Ok(true)
}

pub(crate) async fn deliver_pending_remote_build_wakes(state: &AppState) {
    let receipts =
        match crate::remote_node::job_ledger::pending_terminal_wakes(&state.config.working_dir)
            .await
        {
            Ok(receipts) => receipts,
            Err(error) => {
                tracing::warn!(?error, "remote-build wake outbox could not be loaded");
                return;
            }
        };
    for receipt in receipts {
        match crate::remote_node::job_ledger::terminal_wake_disposition(
            &state.config.working_dir,
            &receipt,
        )
        .await
        {
            Ok(crate::remote_node::job_ledger::TerminalWakeDisposition::Ready) => {}
            Ok(crate::remote_node::job_ledger::TerminalWakeDisposition::Deferred) => {
                tracing::debug!(
                    mission_id = %receipt.mission_id,
                    job_id = %receipt.job_id,
                    "remote-build terminal wake deferred behind another active validation"
                );
                continue;
            }
            Ok(crate::remote_node::job_ledger::TerminalWakeDisposition::SupersededBy(
                superseding_job_id,
            )) => {
                match crate::remote_node::job_ledger::mark_terminal_wake_suppressed(
                    &state.config.working_dir,
                    receipt.job_id,
                    receipt.mission_id,
                    superseding_job_id,
                )
                .await
                {
                    Ok(true) => {
                        if let Err(error) = record_suppressed_remote_build_terminal_event(
                            state,
                            &receipt,
                            superseding_job_id,
                        )
                        .await
                        {
                            // The receipt itself is the durable evidence. Do
                            // not re-arm a stale continuation just because its
                            // convenience transcript event could not be added.
                            tracing::warn!(
                                mission_id = %receipt.mission_id,
                                job_id = %receipt.job_id,
                                %superseding_job_id,
                                %error,
                                "remote-build superseded receipt event could not be recorded"
                            );
                        }
                        tracing::info!(
                            mission_id = %receipt.mission_id,
                            job_id = %receipt.job_id,
                            %superseding_job_id,
                            "remote-build terminal wake suppressed by newer validation"
                        );
                    }
                    Ok(false) => {}
                    Err(error) => {
                        tracing::warn!(
                            mission_id = %receipt.mission_id,
                            job_id = %receipt.job_id,
                            %superseding_job_id,
                            ?error,
                            "remote-build superseded wake acknowledgement failed"
                        );
                    }
                }
                continue;
            }
            Err(error) => {
                tracing::warn!(
                    mission_id = %receipt.mission_id,
                    job_id = %receipt.job_id,
                    ?error,
                    "remote-build wake ordering could not be reconciled"
                );
                continue;
            }
        }
        match deliver_remote_build_terminal_wake(state, &receipt).await {
            Ok(true) => {
                if let Err(error) = crate::remote_node::job_ledger::mark_terminal_wake_delivered(
                    &state.config.working_dir,
                    receipt.job_id,
                    receipt.mission_id,
                )
                .await
                {
                    tracing::warn!(job_id = %receipt.job_id, ?error, "remote-build wake receipt acknowledgement failed");
                }
            }
            Ok(false) => {}
            Err(error) => tracing::warn!(
                mission_id = %receipt.mission_id,
                job_id = %receipt.job_id,
                %error,
                "remote-build terminal wake will retry"
            ),
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn finalize_remote_mission(
    owner: &RemoteMissionOwner,
    mission_id: Uuid,
    job_id: Option<Uuid>,
    node_id: &str,
    success: bool,
    content: String,
    status_reason: &str,
    native_stream: bool,
    usage: Option<crate::cost::TokenUsage>,
    ledger_dir: Option<&std::path::Path>,
) -> Result<(), String> {
    // Recovery and the live observer can both see the same terminal receipt.
    // Serialize with dispatch, then require that this job still owns the run.
    // A duplicate old receipt must never complete a newer continuation.
    let _admission = DISPATCH_ADMISSION.lock().await;
    let _file = match ledger_dir {
        Some(root) => Some(dispatch_admission::durable_lock_root(root).await?),
        None => None,
    };
    if let Some(job_id) = job_id {
        let active = owner
            .mission_store
            .get_active_mission_run(mission_id)
            .await?;
        if active.is_none_or(|run| run.owner_actor_id != remote_job_lease_owner(job_id)) {
            return Ok(());
        }
        let current = owner.mission_store.get_mission(mission_id).await?;
        if !should_finalize_remote_job(current.map(|mission| mission.status)) {
            return Ok(());
        }
    }

    let model = if usage.is_some() {
        owner
            .mission_store
            .get_mission(mission_id)
            .await?
            .and_then(|mission| mission.model_override)
    } else {
        None
    };
    let model_normalized = model.as_deref().map(crate::cost::normalized_model);
    // Price the turn's own usage like local runners do; the proxy ledger
    // keeps billing, this is what the transcript shows (4ad4bc01 had usage
    // and a gemini-4-argon price but showed cost unknown).
    let (cost_cents, cost_source) = usage
        .as_ref()
        .map(|usage| crate::cost::resolve_cost_cents_and_source(None, model.as_deref(), usage))
        .unwrap_or((0, crate::agents::CostSource::Unknown));
    let event = AgentEvent::AssistantMessage {
        id: Uuid::new_v4(),
        content,
        success,
        cost_cents,
        cost_source,
        usage,
        model,
        model_normalized,
        mission_id: Some(mission_id),
        shared_files: None,
        resumable: !success,
        completion_evidence: None,
    };
    if native_stream {
        owner.publish_native(event).await;
    } else {
        let _ = owner.mission_store.log_event(mission_id, &event).await;
        owner.send(event);
    }
    // A job that failed on a usage limit is waiting for its replay:
    // resumable, not failed.
    let waiting = !success && status_reason == usage_limit_wait::USAGE_LIMIT_WAIT_REASON;
    let status = if waiting {
        MissionStatus::Interrupted
    } else if status_reason == "native_goal_stopped" {
        MissionStatus::Blocked
    } else if status_reason == usage_limit_wait::IDLE_WAIT_EXHAUSTED_REASON {
        // Not a failure: the agent was waiting on its own background work.
        MissionStatus::AwaitingUser
    } else if success {
        MissionStatus::Completed
    } else {
        MissionStatus::Failed
    };
    owner
        .mission_store
        .update_mission_status_with_reason(mission_id, status, Some(status_reason))
        .await?;
    // Settle the observer's run lease with the same reason so execution
    // truth and presentation status agree; the terminal event carries it.
    let execution = match job_id {
        Some(job_id) => finish_remote_job_lease(
            owner.mission_store.as_ref(),
            mission_id,
            job_id,
            status_reason,
        )
        .await
        .unwrap_or_else(|error| {
            tracing::warn!(
                %mission_id,
                %job_id,
                %error,
                "remote job run lease could not be finished after mission finalization"
            );
            None
        }),
        None => None,
    };
    owner.send(AgentEvent::MissionStatusChanged {
        completion: None,
        execution,
        mission_id,
        status,
        summary: Some(if waiting {
            format!("Remote node '{node_id}' paused; automatic recovery is scheduled")
        } else {
            format!("Remote node '{node_id}' finished")
        }),
    });
    Ok(())
}

/// Terminal reason of a remote launch whose dispatch failed or whose
/// submitting process died before the node acceptance became durable.
pub(crate) const REMOTE_DISPATCH_FAILED: &str = "remote_dispatch_failed";
pub(crate) const REMOTE_DISPATCH_INTERRUPTED: &str = "remote_dispatch_interrupted";

/// Dispatch a remote mission job with the run lease taken FIRST.
///
/// The lease (`owner remote-job:<job_id>`, state `waiting_remote_job`) is the
/// durable ownership fence every local execution path checks:
/// `begin_mission_run` refuses a second non-terminal run, so a targeted
/// message, the FLEET-001 scheduler or a resume cannot start a local harness
/// while placement, proxy-key minting and the node submit are awaiting.
/// Taking it after the submit (the pre-620cdb74 order) left that whole window
/// open. Every failure below settles the lease so a failed mission never
/// keeps a phantom run; the ledger handle keeps owning a maybe-accepted job.
pub(super) async fn dispatch_remote_job(
    state: &Arc<AppState>,
    control: &ControlState,
    mission: &Mission,
    remote_node_id: &str,
    plan: &RemoteHarnessPlan,
    scheduled_origin: Option<(Option<Uuid>, Uuid)>,
    queue_delivery: Option<(&str, Uuid)>,
) -> Result<Mission, String> {
    let node = crate::remote_node::placement_for_selected_node(
        &state.config.remote_nodes,
        Some(remote_node_id),
    )
    .map_err(|e| e.to_string())?
    .ok_or_else(|| "remote node placement unexpectedly returned local".to_string())?
    .clone();
    let job_id = Uuid::new_v4();
    match ensure_remote_job_lease(control.mission_store.as_ref(), mission.id, job_id, &node.id)
        .await
    {
        Ok(Some(_)) => {}
        Ok(None) => {
            let owner = control
                .mission_store
                .get_active_mission_run(mission.id)
                .await
                .ok()
                .flatten()
                .map(|run| run.owner_actor_id);
            return Err(format!(
                "remote job run lease for mission {} could not be taken before dispatch (execution already owned by {}); refusing to start a second execution",
                mission.id,
                owner.as_deref().unwrap_or("an unavailable mission state")
            ));
        }
        Err(error) => {
            return Err(format!(
                "remote job run lease could not be acquired before dispatch: {error}"
            ));
        }
    }
    let dispatched = async {
        if let Some((user, id)) = queue_delivery {
            remote_queue::bind_job(&state.projects, user, id, Some(job_id))?;
        }
        if let Some((message, previous_job)) = scheduled_origin {
            control
                .mission_store
                .bind_scheduled_remote_job(mission.id, message, previous_job, job_id)
                .await?;
        }
        submit_leased_remote_job(state, control, mission, node, job_id, plan).await
    }
    .await;
    if dispatched.is_err() {
        // No recovery handle means preflight/definitive rejection, before a
        // possible node acceptance. Ambiguous submits retain their binding.
        if let Some((user, id)) = queue_delivery {
            if matches!(crate::remote_node::job_ledger::load(&state.config.working_dir).await,Ok(handles) if handles.iter().all(|handle|handle.job_id!=job_id))
            {
                if let Err(error) = remote_queue::bind_job(&state.projects, user, id, None) {
                    tracing::warn!(%error,"Could not clear rejected queue job binding");
                }
            }
        }
    }
    if dispatched.is_err() {
        if let Err(error) = finish_remote_job_lease(
            control.mission_store.as_ref(),
            mission.id,
            job_id,
            REMOTE_DISPATCH_FAILED,
        )
        .await
        {
            tracing::warn!(
                mission_id = %mission.id,
                %job_id,
                %error,
                "remote job run lease could not be settled after a failed dispatch"
            );
        }
    }
    dispatched
}

/// The submit half of `dispatch_remote_job`; `job_id` already owns the
/// mission's run lease.
// The persisted identity must be passed to the initial CLI invocation. Otherwise
// Claude creates a different UUID and the next --resume can never find it.
pub(super) fn bind_remote_claude_session(execution: &mut RemoteExecution, session_id: &str) {
    execution.command = execution.command.replacen(
        "claude -p ",
        &format!("claude -p --session-id {} ", shell_single_quote(session_id)),
        1,
    );
}

/// Skill preparation run in the final remote cwd before the harness:
/// (a) Library cleanup of its owned copies, (b) strict project skills,
/// (c) best-effort Library install that never overrides an existing name.
pub(super) fn remote_skill_prefix(
    project_skill_source: &str,
    backend: &str,
    library_archive: Option<&(String, String)>,
) -> String {
    let library_sh = shell_single_quote(include_str!("../../../shared/prepare_library_skills.sh"));
    let mut prefix = format!(
        "sandboxed_library_py={}; sh -c {library_sh} sandboxed-library-skills cleanup {} '' '' \"$sandboxed_library_py\"; ",
        shell_single_quote(include_str!("../../../shared/prepare_library_skills.py")),
        shell_single_quote(backend),
    );
    prefix.push_str(&format!(
        "sh -c {} orb-project-skills {} {} {} || exit 78; ",
        shell_single_quote(include_str!("../../../shared/prepare_project_skills.sh")),
        shell_single_quote(project_skill_source),
        shell_single_quote(backend),
        shell_single_quote(include_str!("../../../shared/prepare_project_skills.py")),
    ));
    if let Some((path, sha)) = library_archive {
        prefix.push_str(&format!(
            "sh -c {library_sh} sandboxed-library-skills install {} {} {} \"$sandboxed_library_py\"; ",
            shell_single_quote(backend),
            shell_single_quote(path),
            shell_single_quote(sha),
        ));
    }
    prefix
}

/// Node uploads already holding a given Library skill archive, keyed by
/// (node id, sha256) → absolute path on the node.
pub(super) static REMOTE_LIBRARY_SKILL_UPLOADS: std::sync::LazyLock<
    std::sync::Mutex<HashMap<(String, String), String>>,
> = std::sync::LazyLock::new(Default::default);

/// Resolve, package and upload this mission's Library skills to the node.
/// Best-effort: any failure is logged and the mission launches without them.
pub(super) async fn remote_library_skills(
    state: &Arc<AppState>,
    mission: &Mission,
    node: &crate::remote_node::RemoteNodeConfig,
) -> Option<(String, String)> {
    // Managed machines are untrusted: no Library material beyond the prompt.
    if crate::managed::is_managed_node(&node.id) {
        return None;
    }
    let library = state.library.read().await.clone()?;
    let (workspace_skills, default_host) = match state.workspaces.get(mission.workspace_id).await {
        Some(ws) => (
            ws.skills.clone(),
            crate::workspace::skill_delivery::is_default_host(&ws),
        ),
        None => (Vec::new(), false),
    };
    let project_skills = mission
        .project
        .project
        .as_deref()
        .and_then(|slug| state.projects.get_project(slug).ok().flatten())
        .map(|record| record.skills)
        .unwrap_or_default();
    let plan = match crate::workspace::skill_delivery::resolve_for_workspace(
        &workspace_skills,
        default_host,
        &library,
        &project_skills,
    )
    .await
    {
        Ok(plan) if !plan.skills.is_empty() => plan,
        Ok(_) => return None,
        Err(error) => {
            tracing::warn!(mission_id = %mission.id, %error, "Library skill resolution failed; launching without Library skills");
            return None;
        }
    };
    let contents = crate::workspace::skill_delivery::load_skill_contents(
        &plan,
        &format!("mission-{}", mission.id),
        &library,
    )
    .await;
    let (archive, sha) = match crate::workspace::skill_delivery::build_skill_tarball(&contents) {
        Ok(built) => built,
        Err(error) => {
            tracing::warn!(mission_id = %mission.id, %error, "Library skill archive failed; launching without Library skills");
            return None;
        }
    };
    let key = (node.id.clone(), sha.clone());
    if let Some(path) = REMOTE_LIBRARY_SKILL_UPLOADS
        .lock()
        .ok()
        .and_then(|cache| cache.get(&key).cloned())
    {
        return Some((path, sha));
    }
    let upload = async {
        if archive.len() > crate::uploads::MAX_BYTES {
            return Err(format!("archive is {} bytes", archive.len()));
        }
        let token = crate::remote_node::node_token(&node.token_env)
            .ok()
            .filter(|t| !t.trim().is_empty())
            .ok_or("node token unavailable")?;
        use base64::Engine as _;
        let body = crate::uploads::Upload {
            name: format!("library-skills-{}.tar.gz", &sha[..12]),
            data_base64: base64::engine::general_purpose::STANDARD.encode(&archive),
        };
        let response = state
            .http_client
            .post(format!("{}/uploads", node.base_url.trim_end_matches('/')))
            .bearer_auth(token)
            .timeout(std::time::Duration::from_secs(60))
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if !response.status().is_success() {
            return Err(format!("node answered {}", response.status()));
        }
        let receipt: crate::uploads::Receipt = response.json().await.map_err(|e| e.to_string())?;
        if receipt.sha256 != sha {
            return Err("node stored a different archive".to_string());
        }
        Ok(receipt.path)
    };
    match upload.await {
        Ok(path) => {
            tracing::info!(
                mission_id = %mission.id,
                node = %node.id,
                skills = ?plan.names(),
                %sha,
                "Uploaded Library skills to remote node"
            );
            if let Ok(mut cache) = REMOTE_LIBRARY_SKILL_UPLOADS.lock() {
                cache.insert(key, path.clone());
            }
            Some((path, sha))
        }
        Err(error) => {
            tracing::warn!(mission_id = %mission.id, node = %node.id, %error, "Library skill upload failed; launching without Library skills");
            None
        }
    }
}
