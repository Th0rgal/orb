//! Control queue entries, parking/take/pop helpers and queue snapshot persistence.

use super::*;

/// The 15-minute registered-liveness interrupt is a second idle gate beside
/// the stuck-mission watchdog. #840 taught the watchdog to skip Hermes-tagged
/// writers; this gate still force-aborted Lido `04b0a5d8` after the watchdog
/// correctly logged NOT auto-killing. Same ownership rule applies here.
pub(super) fn skip_idle_registered_liveness_interrupt(
    origin: Option<&str>,
    origin_session_id: Option<&str>,
    tags: &[String],
) -> bool {
    watchdog_skips_control_owned_mission(origin, origin_session_id, tags)
}

pub(super) const REGISTERED_LIVENESS_IDLE_SECS: u64 = 15 * 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RegisteredLivenessIdleDecision {
    HealthyOrProtected,
    DeferForProxyStream,
    CheckOwnershipAndInterrupt,
}

/// Evaluate whether an active durable run has gone silent past the 15-minute
/// registered-liveness gate without user wait, remote job, live registered
/// tools, or bounded builtin-proxy grace (`< 30m`, matching OpenCode's
/// `PROXY_STREAM_INACTIVITY_CAP` so active reasoning streams or internal
/// subagent LLM calls are not killed at 15m while wedged CLIs still cap at 30m).
pub(super) fn evaluate_registered_liveness_idle(
    idle_secs: u64,
    state: MissionExecutionState,
    live_registered_tools: usize,
    mission_id: Uuid,
) -> RegisteredLivenessIdleDecision {
    if idle_secs < REGISTERED_LIVENESS_IDLE_SECS
        || state == MissionExecutionState::WaitingUser
        || state == MissionExecutionState::WaitingRemoteJob
        || live_registered_tools > 0
    {
        return RegisteredLivenessIdleDecision::HealthyOrProtected;
    }
    if crate::api::proxy_liveness::defers_idle_interrupt(
        mission_id,
        std::time::Duration::from_secs(idle_secs),
    ) {
        return RegisteredLivenessIdleDecision::DeferForProxyStream;
    }
    RegisteredLivenessIdleDecision::CheckOwnershipAndInterrupt
}

pub(super) fn parse_durable_job_result(result: &serde_json::Value) -> Option<serde_json::Value> {
    fn visit(value: &serde_json::Value, depth: u8) -> Option<serde_json::Value> {
        if depth > 4 {
            return None;
        }
        if value.get("id").and_then(|id| id.as_str()).is_some()
            && value
                .get("stdout_log")
                .and_then(|path| path.as_str())
                .is_some()
        {
            return Some(value.clone());
        }
        if let Some(inner) = value.get("result") {
            if let Some(job) = visit(inner, depth + 1) {
                return Some(job);
            }
        }
        if let Some(content) = value.get("content") {
            if let Some(job) = visit(content, depth + 1) {
                return Some(job);
            }
        }
        if let Some(items) = value.as_array() {
            for item in items {
                if let Some(job) = visit(item, depth + 1) {
                    return Some(job);
                }
                if let Some(text) = item.get("text") {
                    if let Some(job) = visit(text, depth + 1) {
                        return Some(job);
                    }
                }
            }
        }
        if let Some(raw) = value.as_str() {
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(raw) {
                return visit(&parsed, depth + 1);
            }
        }
        None
    }

    visit(result, 0)
}

pub(super) async fn acquire_execution_run(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Option<Uuid>,
    owner_actor_id: &str,
) -> Result<Option<MissionRun>, String> {
    let Some(mission_id) = mission_id else {
        return Ok(None);
    };
    let run = mission_store
        .begin_mission_run(mission_id, owner_actor_id, None)
        .await?;
    if !mission_store
        .heartbeat_mission_run(
            run.run_id,
            run.generation,
            MissionExecutionState::Running,
            None,
        )
        .await?
    {
        return Err(format!(
            "run {} generation {} was superseded before execution",
            run.run_id, run.generation
        ));
    }
    Ok(Some(run))
}

/// One entry in the main control queue: (message id, content, optional per-message
/// agent override, target mission id, source). Aliased to keep signatures under
/// clippy's `type_complexity` threshold.
pub(super) type ControlQueueEntry = (Uuid, String, Option<String>, Option<Uuid>, Option<String>);

pub(super) fn enqueue_control_message(
    queue: &mut VecDeque<ControlQueueEntry>,
    entry: ControlQueueEntry,
) {
    if entry.4.as_deref() == Some("remote-build-terminal") {
        queue.push_front(entry);
    } else {
        queue.push_back(entry);
    }
}

/// Pop the first queued delivery whose target is not explicitly paused or
/// still owned by a detached durable wait. Parked deliveries remain durable
/// and rotate behind runnable work; when all entries are parked the queue
/// returns to its original order and nothing is dequeued, avoiding both
/// head-of-line blocking and a retry spin on the active run constraint.
/// Where the next message queued for a mission sits.
pub(super) enum QueuedAt {
    Main(usize),
    Runner(usize),
}

/// Take the earliest message queued for `mission_id` when a parked Claude
/// session can answer it. Agent overrides, scheduler batches and slash
/// commands need a fresh turn: they stay queued, and so does everything
/// queued behind them.
pub(super) fn take_for_parked_session(
    mission_id: Uuid,
    is_main: bool,
    queue: &mut VecDeque<ControlQueueEntry>,
    parallel_runners: &mut std::collections::HashMap<
        Uuid,
        super::super::mission_runner::MissionRunner,
    >,
) -> Option<(QueuedAt, super::super::mission_runner::QueuedMessage)> {
    fn plain(content: &str, agent: &Option<String>, source: &Option<String>) -> bool {
        agent.is_none()
            && !matches!(
                source.as_deref(),
                Some("scheduler" | "scheduled-continuation")
            )
            && !content.trim_start().starts_with('/')
    }
    if let Some(position) = queue
        .iter()
        .position(|entry| entry.3 == Some(mission_id) || (entry.3.is_none() && is_main))
    {
        let entry = &queue[position];
        if !plain(&entry.1, &entry.2, &entry.4) {
            return None;
        }
        let (id, content, agent, _, source) = queue.remove(position)?;
        return Some((
            QueuedAt::Main(position),
            super::super::mission_runner::QueuedMessage {
                id,
                content,
                agent,
                source,
            },
        ));
    }
    let runner = parallel_runners.get_mut(&mission_id)?;
    let first = runner.queue.front()?;
    if !plain(&first.content, &first.agent, &first.source) {
        return None;
    }
    Some((QueuedAt::Runner(0), runner.queue.pop_front()?))
}

pub(super) fn take_queued_by_id(
    message_id: Uuid,
    running_mission_id: Option<Uuid>,
    queue: &mut VecDeque<ControlQueueEntry>,
    parallel_runners: &mut std::collections::HashMap<
        Uuid,
        super::super::mission_runner::MissionRunner,
    >,
) -> Option<(Uuid, QueuedAt, super::super::mission_runner::QueuedMessage)> {
    fn plain(content: &str, agent: &Option<String>, source: &Option<String>) -> bool {
        agent.is_none()
            && !matches!(
                source.as_deref(),
                Some("scheduler" | "scheduled-continuation")
            )
            && !content.trim_start().starts_with('/')
    }
    if let Some(position) = queue.iter().position(|entry| entry.0 == message_id) {
        let entry = &queue[position];
        let mid = entry.3.or(running_mission_id)?;
        if !plain(&entry.1, &entry.2, &entry.4)
            || !super::super::runners::live_session::can_deliver_now(mid)
        {
            return None;
        }
        let (id, content, agent, _, source) = queue.remove(position)?;
        return Some((
            mid,
            QueuedAt::Main(position),
            super::super::mission_runner::QueuedMessage {
                id,
                content,
                agent,
                source,
            },
        ));
    }
    for (mid, runner) in parallel_runners.iter_mut() {
        if let Some(position) = runner.queue.iter().position(|qm| qm.id == message_id) {
            let entry = &runner.queue[position];
            if !plain(&entry.content, &entry.agent, &entry.source)
                || !super::super::runners::live_session::can_deliver_now(*mid)
            {
                return None;
            }
            let message = runner.queue.remove(position)?;
            return Some((*mid, QueuedAt::Runner(position), message));
        }
    }
    None
}

// Park the whole mission together so a blocked writer does not starve unrelated
// missions, and later messages for that writer cannot overtake its first one.
pub(super) fn park_followup(queue: &mut VecDeque<ControlQueueEntry>, first: ControlQueueEntry) {
    let target = first.3;
    let mut parked = VecDeque::from([first]);
    let mut remaining = VecDeque::new();
    while let Some(entry) = queue.pop_front() {
        if entry.3 == target {
            parked.push_back(entry);
        } else {
            remaining.push_back(entry);
        }
    }
    remaining.append(&mut parked);
    *queue = remaining;
}

pub(super) fn host_followup_source(source: Option<&str>) -> bool {
    source.is_some_and(|source| source.starts_with("host-queue:api:"))
}

pub(super) async fn pop_next_runnable_control_queue(
    queue: &mut VecDeque<ControlQueueEntry>,
    store: &Arc<dyn MissionStore>,
) -> Option<ControlQueueEntry> {
    let queued = queue.len();
    for _ in 0..queued {
        let entry = queue.pop_front()?;
        if entry.4.as_deref() == Some("scheduled-continuation") {
            let Some(mission_id) = entry.3 else { continue };
            match store
                .can_admit_scheduled_delivery(mission_id, entry.0)
                .await
            {
                Ok(true) => {}
                Ok(false) => continue,
                Err(error) => {
                    // Preserve work on transient store failures, but never launch
                    // a scheduled message whose revocation cannot be checked.
                    tracing::warn!(%mission_id, %error, "Scheduled dequeue validation failed");
                    queue.push_back(entry);
                    continue;
                }
            }
        }
        let parked = match entry.3 {
            Some(mission_id) => {
                let paused = store
                    .get_mission(mission_id)
                    .await
                    .ok()
                    .flatten()
                    .is_some_and(|mission| {
                        mission.status == MissionStatus::Paused
                            || (mission.status == MissionStatus::Pending
                                && !mission.is_dispatchable_at(chrono::Utc::now()))
                    });
                let detached_wait = store
                    .get_active_mission_run(mission_id)
                    .await
                    .ok()
                    .flatten()
                    .is_some_and(|run| {
                        matches!(
                            run.execution_state,
                            MissionExecutionState::WaitingRemoteJob
                                | MissionExecutionState::Stopping
                        )
                    });
                let running = host_followup_source(entry.4.as_deref())
                    && store
                        .get_active_mission_run(mission_id)
                        .await
                        .ok()
                        .flatten()
                        .is_some();
                paused || detached_wait || running
            }
            None => false,
        };
        if parked {
            queue.push_back(entry);
            continue;
        }
        return Some(entry);
    }
    None
}

/// Silence threshold before declaring a mission stuck. Conservative so
/// legitimately long codex turns (Lean compiles, CI polls) don't trigger
/// false positives. Shared between the watchdog loop and the actor's
/// CancelMission re-check to keep the two views of "stalled" consistent.
pub(crate) const STUCK_SECONDS: u64 = 900;

/// The effective stall threshold, overridable at runtime via
/// `MISSION_STUCK_SECONDS` (clamped to >= 30s so a typo can't make the
/// watchdog trigger-happy). An ops lever to widen the window for tracks that
/// legitimately go quiet between tool calls (long scans/builds) without a
/// redeploy.
pub(crate) fn stuck_seconds() -> u64 {
    std::env::var("MISSION_STUCK_SECONDS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|&v| v >= 30)
        .unwrap_or(STUCK_SECONDS)
}

/// Grace period after the user first opens an `AwaitingUser` mission before
/// the ack-promotion tick auto-archives it to `Acknowledged` (Finished).
/// Resets whenever the user sends a new message (status returns to Active and
/// `first_viewed_at` is cleared).
pub(crate) const ACK_GRACE_SECONDS: u64 = 3600;

/// How often the ack-promotion tick scans for stale `AwaitingUser` missions.
pub(crate) const ACK_PROMOTION_TICK_INTERVAL: std::time::Duration =
    std::time::Duration::from_secs(60);

/// Whether an incoming user message (a real one, or the background-task
/// auto-resume synthetic message) should re-activate `status` to `Active`.
///
/// Kept as one predicate so every message-dequeue site agrees. It deliberately
/// includes `WaitingBackground`: a resume delivered while background jobs were
/// still live must flip the mission to `Active` — which clears `first_viewed_at`
/// (see `MissionStore::update_mission_status`) — otherwise the stale timestamp
/// survives the later demotion back to `AwaitingUser` and the ack-promotion
/// sweep can archive a mission whose next turn just started.
/// Reason written when a cancel's JoinHandle never resolves. During a
/// deploy/SIGTERM drain this must stay `server_shutdown` so boot recovery
/// and reconcile resume the writer instead of leaving it stranded.
pub(super) fn cancel_timeout_interrupt_reason() -> &'static str {
    if super::super::routes::is_shutdown_initiated() {
        super::super::reconcile::SERVER_SHUTDOWN_REASON
    } else {
        super::super::reconcile::FORCE_KILLED_CANCEL_TIMEOUT_REASON
    }
}

pub(crate) fn message_activates_mission(status: MissionStatus) -> bool {
    matches!(
        status,
        MissionStatus::Pending
            | MissionStatus::Interrupted
            | MissionStatus::Blocked
            | MissionStatus::Completed
            | MissionStatus::Failed
            | MissionStatus::AwaitingUser
            | MissionStatus::WaitingBackground
            | MissionStatus::Acknowledged
    )
}

pub(super) fn background_tasks_block_ack(status: MissionStatus, task_count: usize) -> bool {
    status == MissionStatus::Acknowledged && task_count > 0
}

/// Stash a newly arrived operator message as the mission's deferred goal.
///
/// Pending missions have not run yet, so multiple pre-dispatch messages
/// concatenate. A Failed/Interrupted/… mission already executed its original
/// prompt (left in `deferred_goal` on purpose for a capacity-race retry).
/// Concatenating a follow-up onto that prompt buries the operator's message
/// and the scheduler never re-dispatches non-Pending rows, so the follow-up
/// is lost. Replace instead.
pub(crate) fn deferred_goal_for_incoming_message(
    status: MissionStatus,
    previous_goal: Option<&str>,
    content: &str,
) -> String {
    if status == MissionStatus::Pending {
        match previous_goal {
            Some(prev) if !prev.is_empty() => deferred_messages::join(prev, content),
            _ => content.to_string(),
        }
    } else {
        content.to_string()
    }
}

pub(super) fn follow_up_should_requeue_as_pending(status: MissionStatus) -> bool {
    message_activates_mission(status) && status != MissionStatus::Pending
}

pub(super) fn queued_delivery_requires_activation(
    target_mission_id: Option<Uuid>,
    source: Option<&str>,
) -> bool {
    target_mission_id.is_some() || source == Some("transport_auto_resume")
}

pub(super) fn projected_running_health(
    state: super::super::mission_runner::MissionRunState,
    seconds_since_activity: u64,
    tool_call_in_flight: bool,
    waiting_remote_job: bool,
) -> super::super::mission_runner::MissionHealth {
    if waiting_remote_job {
        // A fresh durable remote-job heartbeat is process-backed liveness, not
        // the provisional unmatched-tool hint that expires after ten minutes.
        return super::super::mission_runner::MissionHealth::Healthy;
    }
    super::super::mission_runner::running_health(state, seconds_since_activity, tool_call_in_flight)
}

pub(super) fn remote_node_needs_on_demand_probe(
    _status: Option<&crate::remote_node::RemoteNodeStatus>,
) -> bool {
    // Auto-placement has already rejected the cached fleet. Even an Online
    // heartbeat may carry stale load or resource figures, so refresh every
    // configured node once before returning 503.
    true
}

const ANTIGRAVITY_SCHEDULE_POOL: &str = "antigravity-schedule";
/// Active agent-created recurring schedules allowed per mission.
pub(crate) const MAX_NATIVE_SCHEDULES_PER_MISSION: usize = 3;

/// How many active wake-ups (including the newest) a supersession key keeps.
pub(crate) fn wakeup_supersession_keep(key: &str) -> usize {
    if key == ANTIGRAVITY_SCHEDULE_POOL {
        MAX_NATIVE_SCHEDULES_PER_MISSION
    } else {
        1
    }
}

pub(crate) fn wakeup_supersession_key(
    source: Option<&str>,
    trigger: &mission_store::TriggerType,
) -> Option<String> {
    match source? {
        // Wall-clock wakeups all represent the mission's next timer and may
        // supersede one another regardless of which helper created them.
        "claude-builtin" | "automation-manager" | "orb-local" => Some("wall-clock".to_string()),
        // Durable completions are independent. Only a replacement watcher for
        // the same job may supersede an older one.
        // Agent-created recurring schedules share one bounded pool per mission
        // (`wakeup_supersession_keep`): the oldest is replaced beyond the cap.
        crate::api::mission_runner::ANTIGRAVITY_SCHEDULE_SOURCE => match trigger {
            mission_store::TriggerType::Cron { .. } => Some(ANTIGRAVITY_SCHEDULE_POOL.to_string()),
            _ => None,
        },
        "durable-job-terminal" => match trigger {
            mission_store::TriggerType::DurableJobTerminal { job_id } => {
                Some(format!("durable-job:{job_id}"))
            }
            _ => None,
        },
        _ => None,
    }
}

pub(super) fn should_finalize_remote_job(current_status: Option<MissionStatus>) -> bool {
    matches!(
        current_status,
        None | Some(MissionStatus::Active | MissionStatus::Pending)
    )
}

/// A scheduler batch keeps one transport entry, but every original receipt ID
/// remains an admission identity. Never insert aliases into the persisted queue:
/// that would replay/display the same batch more than once.
pub(super) fn control_message_contains_id(
    outer_id: Uuid,
    content: &str,
    source: Option<&str>,
    candidate: Uuid,
) -> bool {
    outer_id == candidate
        || (source == Some("scheduler")
            && deferred_messages::decode(content)
                .1
                .iter()
                .any(|(id, _)| *id == candidate))
}

static OUTBOX_CRASH_RECONCILE_SHADOW_COUNTER: std::sync::OnceLock<crate::orb_spec::ShadowCounter> =
    std::sync::OnceLock::new();

pub fn outbox_crash_reconcile_shadow_counter() -> &'static crate::orb_spec::ShadowCounter {
    OUTBOX_CRASH_RECONCILE_SHADOW_COUNTER.get_or_init(crate::orb_spec::ShadowCounter::new)
}

pub fn evaluate_outbox_crash_reconcile_gate(
    durable_queued: u32,
    durable_acked: u32,
    volatile_in_flight: u32,
    lease_boot_epoch: u64,
    node_boot_epoch: u64,
    volatile_lease_owner: u32,
    req_owner: u32,
) -> crate::orb_spec::OutboxCrashReconcileVerdict {
    let input = crate::orb_spec::OutboxCrashReconcileInput {
        durable_queued,
        durable_acked,
        volatile_in_flight,
        lease_boot_epoch,
        node_boot_epoch,
        volatile_lease_owner,
        req_owner,
    };
    let verdict = crate::orb_spec::outbox_crash_reconcile_step(input);
    let valid_wal = durable_acked <= durable_queued;
    let host_unacked = if valid_wal {
        durable_queued - durable_acked
    } else {
        0
    };
    let crash_reset = lease_boot_epoch != node_boot_epoch;
    let eff_owner = if crash_reset { 0 } else { volatile_lease_owner };
    let eff_in_flight = if crash_reset { 0 } else { volatile_in_flight };
    let host_admitted = valid_wal
        && host_unacked > 0
        && req_owner != 0
        && (eff_owner == 0 || eff_owner == req_owner)
        && eff_in_flight < host_unacked;
    let host_action_code = if !valid_wal {
        0u8
    } else if host_admitted {
        1u8
    } else if host_unacked == 0 {
        2u8
    } else {
        3u8
    };
    let sim = crate::orb_spec::shadow::RefinementSimulation::<
        (bool, u32),
        (bool, u32),
        crate::orb_spec::OutboxCrashReconcileInput,
        u8,
        u8,
    > {
        subsystem: "orb_outbox_crash_reconcile_step",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = crate::orb_spec::outbox_crash_reconcile_step(*ev);
            ((v.admitted, v.unacked_depth), vec![v.action_code])
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let ctx = crate::orb_spec::shadow::EventContext {
        now_ms: node_boot_epoch,
        fresh_nonce: lease_boot_epoch,
        idempotency_key: u64::from(req_owner),
        boot_id_matches: !crash_reset,
        schema_id: 2,
    };
    outbox_crash_reconcile_shadow_counter().with_ring(|ring| {
        let _ = sim.observe_step(
            &(false, 0),
            &(host_admitted, host_unacked),
            &input,
            &[host_action_code],
            ctx,
            ring,
        );
    });
    verdict
}

pub(super) fn partition_restored_control_messages(
    items: Vec<QueuedMessage>,
) -> (Vec<QueuedMessage>, Vec<QueuedMessage>) {
    let total = items.len().min(u32::MAX as usize) as u32;
    let mut pending = Vec::with_capacity(items.len());
    let mut consumed = Vec::new();
    for item in items {
        if item.inflight {
            consumed.push(item);
        } else {
            pending.push(item);
        }
    }
    let acked = consumed.len().min(u32::MAX as usize) as u32;
    let _ = evaluate_outbox_crash_reconcile_gate(total, acked, acked, 0, 1, 1, 1);
    (pending, consumed)
}

/// Serialize the control session queue to a stable JSON snapshot for
/// persistence across restarts (see `MissionStore::save_control_queue`).
pub(super) fn prune_empty_provisional_runners(
    runners: &mut HashMap<Uuid, super::super::mission_runner::MissionRunner>,
) {
    runners.retain(|_, runner| {
        runner.state != super::super::mission_runner::MissionRunState::Queued
            || runner.durable_run.is_some()
            || runner.inflight_message().is_some()
            || !runner.queue.is_empty()
            || runner.cancellation_requested()
    });
}

pub(super) fn serialize_queue_snapshot(
    queue: &VecDeque<ControlQueueEntry>,
    parallel_runners: &std::collections::HashMap<Uuid, super::super::mission_runner::MissionRunner>,
    recovered_consumed: &HashMap<Uuid, QueuedMessage>,
) -> String {
    let mut items: Vec<QueuedMessage> = queue
        .iter()
        .map(|(id, content, agent, target_mid, source)| QueuedMessage {
            id: *id,
            content: content.clone(),
            agent: agent.clone(),
            mission_id: *target_mid,
            source: source.clone(),
            inflight: false,
            queue_error: None,
        })
        .collect();
    let mut runners: Vec<_> = parallel_runners.iter().collect();
    runners.sort_by_key(|(mission_id, _)| **mission_id);
    for (mission_id, runner) in runners {
        if let Some(message) = runner.inflight_message() {
            // `inflight_message` is also used as a prepared slot before
            // `begin_mission_run` succeeds. Only a durable run proves the
            // actor crossed the consumption boundary; a crash before that
            // must replay the message instead of treating it as completed.
            let durably_started = crate::orb_spec::queue_step(
                crate::orb_spec::QueueDeliveryOutcome::Acked,
                runner.durable_run.is_some(),
            )
            .mark_consumed;
            items.push(QueuedMessage {
                id: message.id,
                content: message.content.clone(),
                agent: message.agent.clone(),
                mission_id: Some(*mission_id),
                source: message.source.clone(),
                inflight: durably_started,
                queue_error: None,
            });
        }
        items.extend(runner.queue.iter().map(|message| QueuedMessage {
            id: message.id,
            content: message.content.clone(),
            agent: message.agent.clone(),
            mission_id: Some(*mission_id),
            source: message.source.clone(),
            inflight: false,
            queue_error: None,
        }));
    }
    let mut consumed: Vec<_> = recovered_consumed.values().cloned().collect();
    consumed.sort_by_key(|message| message.id);
    let acked = (items.iter().filter(|m| m.inflight).count() + consumed.len())
        .min(u32::MAX as usize) as u32;
    items.extend(consumed);
    let total = items.len().min(u32::MAX as usize) as u32;
    let inflight = parallel_runners
        .values()
        .filter(|r| r.inflight_message().is_some())
        .count()
        .min(u32::MAX as usize) as u32;
    let _ = evaluate_outbox_crash_reconcile_gate(total, acked, inflight, 1, 1, 1, 1);
    serde_json::to_string(&items).unwrap_or_else(|_| "[]".to_string())
}

/// Persist the control queue snapshot iff it changed since `last_persisted`
/// (debounced so unchanged iterations don't churn the DB).
///
/// Called both at the actor-loop top and immediately after every dequeue. The
/// post-dequeue call is what prevents stale double-execution: without it, a
/// popped message lingers in the persisted snapshot until the next loop pass, so
/// a crash after the pop (during the potentially-awaiting work that starts the
/// run) would restore and re-run a message that already started — bypassing the
/// in-memory idempotency guard.
pub(super) async fn persist_control_queue_if_changed(
    mission_store: &Arc<dyn MissionStore>,
    session_user_id: &str,
    queue: &VecDeque<ControlQueueEntry>,
    parallel_runners: &std::collections::HashMap<Uuid, super::super::mission_runner::MissionRunner>,
    recovered_consumed: &HashMap<Uuid, QueuedMessage>,
    last_persisted: &mut String,
) -> Result<(), String> {
    let snapshot = serialize_queue_snapshot(queue, parallel_runners, recovered_consumed);
    if snapshot != *last_persisted {
        if let Err(error) = mission_store
            .save_control_queue(session_user_id, &snapshot)
            .await
        {
            tracing::warn!("Failed to persist control queue: {error}");
            return Err(error);
        } else {
            *last_persisted = snapshot;
        }
    }
    Ok(())
}

#[cfg(test)]
mod native_schedule_pool_tests {
    use super::*;
    #[test]
    fn agent_schedules_share_one_pool_capped_per_mission() {
        let cron = |e: &str| mission_store::TriggerType::Cron {
            expression: e.into(),
            timezone: "UTC".into(),
        };
        let src = Some(crate::api::mission_runner::ANTIGRAVITY_SCHEDULE_SOURCE);
        let a = wakeup_supersession_key(src, &cron("*/30 * * * *")).unwrap();
        let b = wakeup_supersession_key(src, &cron("0 * * * *")).unwrap();
        assert_eq!(a, b, "different cadences count against the same cap");
        assert_eq!(
            wakeup_supersession_keep(&a),
            MAX_NATIVE_SCHEDULES_PER_MISSION
        );
        assert_eq!(wakeup_supersession_keep("wall-clock"), 1);
    }

    #[test]
    fn outbox_crash_reconcile_gate_requeues_unacked_with_single_writer_and_zero_divergences() {
        let msgs = vec![
            QueuedMessage {
                id: Uuid::new_v4(),
                content: "inflight-acked".into(),
                agent: None,
                mission_id: None,
                source: None,
                inflight: true,
                queue_error: None,
            },
            QueuedMessage {
                id: Uuid::new_v4(),
                content: "unacked-pending".into(),
                agent: None,
                mission_id: None,
                source: None,
                inflight: false,
                queue_error: None,
            },
        ];
        let (pending, consumed) = partition_restored_control_messages(msgs);
        assert_eq!(pending.len(), 1);
        assert_eq!(consumed.len(), 1);

        let crash_verdict = evaluate_outbox_crash_reconcile_gate(5, 2, 3, 10, 11, 9, 7);
        assert!(crash_verdict.admitted);
        assert!(crash_verdict.crash_reconciled);
        assert!(crash_verdict.has_single_writer);
        assert_eq!(crash_verdict.unacked_depth, 3);

        let corrupt_wal = evaluate_outbox_crash_reconcile_gate(2, 5, 0, 11, 11, 0, 7);
        assert!(!corrupt_wal.admitted);
        assert_eq!(corrupt_wal.action_code, 0);

        let snap =
            outbox_crash_reconcile_shadow_counter().snapshot("orb_outbox_crash_reconcile_step");
        assert!(snap.total_events >= 3);
        assert_eq!(snap.total_divergences, 0);
    }
}
