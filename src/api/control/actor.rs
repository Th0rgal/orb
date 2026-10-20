//! Control session spawning, the control actor loop and single-turn execution.

use super::*;

/// Spawn the global control session actor.
#[allow(clippy::too_many_arguments)]
pub(super) fn spawn_control_session(
    control_hub: ControlHub,
    config: Config,
    root_agent: AgentRef,
    mcp: Arc<McpRegistry>,
    workspaces: workspace::SharedWorkspaceStore,
    library: SharedLibrary,
    mission_store: Arc<dyn MissionStore>,
    secrets: Option<Arc<SecretsStore>>,
    telegram_bridge: Option<super::super::telegram::SharedTelegramBridge>,
    user_id: String,
) -> ControlState {
    let (cmd_tx, cmd_rx) = mpsc::channel::<ControlCommand>(256);
    // 8 192 slots ≈ ~8 s of headroom even for chatty missions (text_delta
    // bursts during long completions push ~1 k events / sec). The previous
    // 1 024 cap regularly overflowed for any tab whose JS event handler
    // momentarily slowed (large React reducer work, tab backgrounded by
    // Chrome). Per-receiver cursor + Arc<AgentEvent> internal layout keeps
    // the memory cost bounded.
    let (events_tx, events_rx) = broadcast::channel::<AgentEvent>(8192);
    let tool_hub = Arc::new(FrontendToolHub::new());
    let status = Arc::new(RwLock::new(ControlStatus {
        state: ControlRunState::Idle,
        queue_len: 0,
        mission_id: None,
    }));
    let current_mission = Arc::new(RwLock::new(None));

    // Channel for agent-initiated mission control commands
    let (mission_cmd_tx, mission_cmd_rx) =
        mpsc::channel::<crate::tools::mission::MissionControlCommand>(64);

    let current_tree = Arc::new(RwLock::new(None));
    let progress = Arc::new(RwLock::new(ExecutionProgress::default()));
    let running_missions = Arc::new(RwLock::new(Vec::new()));
    let mission_search_cache = Arc::new(RwLock::new(HashMap::new()));
    let max_parallel =
        crate::settings::max_parallel_missions_cached_or(config.max_parallel_missions);

    let mission_channels: Arc<
        RwLock<std::collections::HashMap<Uuid, broadcast::Sender<AgentEvent>>>,
    > = Arc::new(RwLock::new(std::collections::HashMap::new()));

    // P3-#20 fan-out task: subscribe to the global channel and mirror
    // every event into its per-mission channel. Lives for the process
    // lifetime; closes cleanly when the channel ends. Keeps the cost
    // out of every send-site so existing `events_tx.send()` calls
    // don't need to know about the per-mission split.
    {
        let mut rx = events_tx.subscribe();
        let mission_channels = Arc::clone(&mission_channels);
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(ev) => {
                        let Some(mid) = ev.mission_id() else { continue };
                        let sender = {
                            let map = mission_channels.read().await;
                            map.get(&mid).cloned()
                        };
                        if let Some(sender) = sender {
                            let _ = sender.send(ev);
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    let state = ControlState {
        cmd_tx,
        events_tx: events_tx.clone(),
        mission_channels,
        tool_hub: Arc::clone(&tool_hub),
        status: Arc::clone(&status),
        current_mission: Arc::clone(&current_mission),
        current_tree: Arc::clone(&current_tree),
        progress: Arc::clone(&progress),
        running_missions: Arc::clone(&running_missions),
        assignment_owners: Arc::new(RwLock::new(HashSet::new())),
        max_parallel,
        mission_store: Arc::clone(&mission_store),
        mission_search_cache,
    };

    // Mission-status alerts are event-driven for low latency. The existing
    // Paloma scheduler poll still runs as a restart/missed-event backstop and
    // continues to own the other periodic Paloma jobs.
    if let Some(bridge) = telegram_bridge.as_ref() {
        bridge.start_event_alert_loop(events_tx.subscribe());
    }

    if let Some(url) = config
        .paloma_webhook_forward_url
        .as_ref()
        .filter(|url| !url.is_empty())
    {
        tokio::spawn(paloma_webhook_forwarder_loop(
            control_hub.admission_state.clone(),
            events_tx.subscribe(),
            Arc::clone(&state.mission_store),
            workspaces.clone(),
            config.working_dir.clone(),
            url.clone(),
            config.paloma_webhook_secret.clone(),
            reqwest::Client::builder()
                .connect_timeout(std::time::Duration::from_secs(5))
                .timeout(std::time::Duration::from_secs(10))
                .build()
                .unwrap_or_else(|_| reqwest::Client::new()),
        ));
    }

    // Event-driven scope teardown: stop a mission's exec scopes as soon as
    // its status stops needing a live harness. The periodic scope reaper
    // (scope_reaper::spawn) backstops events missed across restarts.
    super::super::scope_reaper::spawn_status_listener(
        events_tx.subscribe(),
        Arc::clone(&state.mission_store),
    );

    // Shared registry of in-flight Claude Code background shell tasks. Written
    // by the control actor's ToolResult arm; read by the auto-resume watcher.
    let background_tasks: super::super::mission_runner::BackgroundTaskRegistry =
        Arc::new(RwLock::new(std::collections::HashMap::new()));

    // Spawn the main control actor
    tokio::spawn(control_actor_loop(
        control_hub.clone(),
        config.clone(),
        root_agent,
        mcp,
        workspaces.clone(),
        library.clone(),
        cmd_rx,
        mission_cmd_rx,
        mission_cmd_tx,
        state.cmd_tx.clone(),
        events_tx.clone(),
        events_rx,
        tool_hub.clone(),
        status,
        current_mission,
        current_tree,
        progress,
        mission_store,
        secrets,
        user_id,
        Arc::clone(&background_tasks),
        Arc::clone(&state.assignment_owners),
    ));

    // Recover missions stopped by the previous backend process. Graceful
    // shutdown marks live runners as `interrupted/server_shutdown`; a hard
    // stop can leave task-mode missions as `active`.
    if state.mission_store.is_persistent() {
        let store = Arc::clone(&state.mission_store);
        let tx = events_tx.clone();
        let cmd = state.cmd_tx.clone();
        let startup_at = chrono::Utc::now();
        tokio::spawn(async move {
            recover_server_shutdown_missions(store, tx, cmd, control_hub, startup_at).await;
        });
    }

    // Spawn background stale mission cleanup task (if enabled)
    if config.stale_mission_hours > 0 && state.mission_store.is_persistent() {
        tokio::spawn(stale_mission_cleanup_loop(
            Arc::clone(&state.mission_store),
            config.stale_mission_hours,
            state.cmd_tx.clone(),
            events_tx.clone(),
        ));
    }

    // Spawn in-process orphan detector. Every 60 s it asks the control
    // actor for the live running list and marks any mission whose
    // `seconds_since_activity` exceeds the silence threshold as
    // interrupted. This covers two failure modes the existing recovery
    // didn't:
    //  1. mission_runner task died mid-flight (backend alive, codex
    //     orphaned in its container). Boot-time recovery only catches
    //     this across a full restart.
    //  2. codex hung — process alive in `futex_wait_queue` with no
    //     events flowing. Stale-mission cleanup eventually catches this
    //     after `stale_hours` (default 24 h); 10 min is a much closer
    //     match for "agent may be stuck" UX.
    if state.mission_store.is_persistent() {
        tokio::spawn(stuck_mission_watchdog_loop(
            Arc::clone(&state.mission_store),
            state.cmd_tx.clone(),
            events_tx.clone(),
            Arc::clone(&tool_hub),
            workspaces.clone(),
            config.working_dir.clone(),
        ));
        tokio::spawn(ack_promotion_loop(
            Arc::clone(&state.mission_store),
            events_tx.clone(),
        ));
    }

    // Spawn the background-task auto-resume watcher. When a mission agent
    // launches a `Bash` job with `run_in_background: true` and then ends its
    // turn, the mission parks in `AwaitingUser` with nothing to wake it when the
    // job finishes. This watcher polls captured background tasks, detects
    // completion inside the workspace, and resumes the agent with the output.
    // Uses an in-memory registry (no persistent store required). Gated by
    // `BACKGROUND_TASK_AUTORESUME` (default enabled).
    // Settle any mission left in `WaitingBackground` by a previous process:
    // the in-memory background-task registry is empty at boot, so those jobs are
    // no longer tracked and the mission would be stranded outside every terminal
    // path. Runs regardless of whether the watcher below is enabled.
    if state.mission_store.is_persistent() {
        let store = Arc::clone(&state.mission_store);
        let tx = events_tx.clone();
        tokio::spawn(async move {
            reset_waiting_background_on_boot(store, tx).await;
        });
    }

    if super::super::mission_runner::background_task_autoresume_enabled() {
        tokio::spawn(background_task_autoresume_loop(
            Arc::clone(&state.mission_store),
            state.cmd_tx.clone(),
            events_tx.clone(),
            workspaces.clone(),
            Arc::clone(&background_tasks),
        ));
    } else {
        tracing::info!(
            "Background-task auto-resume watcher not started (BACKGROUND_TASK_AUTORESUME disabled)"
        );
    }

    // Spawn event logger task (logs all events to SQLite for debugging/replay)
    if state.mission_store.is_persistent() {
        let store = Arc::clone(&state.mission_store);
        let mut event_rx = events_tx.subscribe();
        tokio::spawn(async move {
            // Per-mission lag counter so we can spot a single noisy mission
            // dragging the global SQLite write path. Without this, the
            // generic "Event logger lagged by N events" warning can't tell
            // us which mission's event stream is the culprit — critical
            // when investigating incidents like the ab260b2e 50-minute
            // "Yielding." turn where 396 events streamed to the SSE but
            // never landed in the database.
            let mut lag_total: u64 = 0;
            let lag_per_mission: std::collections::HashMap<Uuid, u64> =
                std::collections::HashMap::new();
            let mut processed_total: u64 = 0;
            let mut processed_per_type: std::collections::HashMap<&'static str, u64> =
                std::collections::HashMap::new();
            let mut last_stats_at = std::time::Instant::now();
            let stats_interval = std::time::Duration::from_secs(60);
            loop {
                match event_rx.recv().await {
                    Ok(first) => {
                        // Drain what is already queued and write it in one
                        // transaction: one commit per event could not keep up
                        // with busy remote jobs, and the broadcast channel then
                        // dropped events before they were saved.
                        let mut received = vec![first];
                        while received.len() < EVENT_LOG_BATCH {
                            match event_rx.try_recv() {
                                Ok(event) => received.push(event),
                                Err(broadcast::error::TryRecvError::Lagged(n)) => {
                                    lag_total = lag_total.saturating_add(n);
                                    tracing::warn!(
                                        dropped = n,
                                        lag_total = lag_total,
                                        processed_total = processed_total,
                                        "Event logger lagged by {} events (next recv() resumes after the gap)",
                                        n
                                    );
                                }
                                Err(_) => break,
                            }
                        }
                        let mut batch = Vec::with_capacity(received.len());
                        for event in received {
                            let ev_name = event.event_name();
                            *processed_per_type.entry(ev_name).or_insert(0) += 1;
                            let Some(mid) = event.mission_id() else {
                                continue;
                            };
                            // Client-link events were persisted with their
                            // ingest cursor before being broadcast.
                            if client_link::take_prepersisted(mid, &event) {
                                continue;
                            }
                            if should_persist_event(&event) {
                                processed_total += 1;
                                batch.push((mid, event));
                            }
                        }
                        if !batch.is_empty() {
                            let meta: Vec<(Uuid, &'static str)> =
                                batch.iter().map(|(m, e)| (*m, e.event_name())).collect();
                            for ((mid, ev_name), result) in
                                meta.into_iter().zip(store.log_events(batch).await)
                            {
                                if let Err(e) = result {
                                    tracing::warn!(
                                        mission_id = %mid,
                                        event_type = ev_name,
                                        "Failed to log event: {}",
                                        e
                                    );
                                }
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        lag_total = lag_total.saturating_add(n);
                        tracing::warn!(
                            dropped = n,
                            lag_total = lag_total,
                            processed_total = processed_total,
                            "Event logger lagged by {} events (next recv() resumes after the gap)",
                            n
                        );
                        // Best-effort: record the lag against any missions
                        // that emitted events immediately after the gap. We
                        // don't know which mission the missed events belonged
                        // to, but the next successful recv() tells us who
                        // was active when we caught up. The Map is cleared
                        // on every status snapshot to bound memory.
                        let _ = lag_per_mission; // keep the field alive for the stats block
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }

                // Periodic stats: even on the happy path we want a heartbeat
                // confirming the logger is keeping up. If the gap between
                // processed and broadcast grows, the next Lagged warning
                // gets actionable context.
                if last_stats_at.elapsed() >= stats_interval {
                    if processed_total > 0 || lag_total > 0 {
                        tracing::debug!(
                            processed_total,
                            lag_total,
                            by_type = ?processed_per_type,
                            "Event logger heartbeat"
                        );
                    }
                    last_stats_at = std::time::Instant::now();
                }
            }
            // Drain stats on shutdown so the next restart can see whether
            // the previous process lost events.
            if lag_total > 0 || processed_total > 0 {
                tracing::info!(
                    processed_total,
                    lag_total,
                    by_type = ?processed_per_type,
                    "Event logger task stopped"
                );
            } else {
                tracing::info!("Event logger task stopped");
            }
        });
    }

    // Spawn native-loop observer: turns harness goal events into
    // Automation rows + AutomationExecution iterations so the
    // automations panel shows /goal alongside scheduled automations.
    if state.mission_store.is_persistent() && config.automations_enabled {
        let store = Arc::clone(&state.mission_store);
        let tx = state.events_tx.clone();
        tokio::spawn(async move {
            super::super::native_loop_observer::run(store, tx).await;
        });
    }

    // Spawn automation scheduler task
    if state.mission_store.is_persistent() && config.automations_enabled {
        tokio::spawn(automation_scheduler_loop(
            Arc::clone(&state.mission_store),
            library.clone(),
            state.cmd_tx.clone(),
            workspaces.clone(),
            state.events_tx.clone(),
            telegram_bridge.clone(),
            config.working_dir.clone(),
        ));
    } else if state.mission_store.is_persistent() {
        tracing::info!("Automation scheduler disabled by config");
    }

    state
}

#[allow(
    clippy::too_many_arguments,
    clippy::collapsible_match,
    clippy::collapsible_else_if
)]
pub(super) async fn control_actor_loop(
    control_hub: ControlHub,
    config: Config,
    root_agent: AgentRef,
    mcp: Arc<McpRegistry>,
    workspaces: workspace::SharedWorkspaceStore,
    library: SharedLibrary,
    mut cmd_rx: mpsc::Receiver<ControlCommand>,
    mut mission_cmd_rx: mpsc::Receiver<crate::tools::mission::MissionControlCommand>,
    mission_cmd_tx: mpsc::Sender<crate::tools::mission::MissionControlCommand>,
    // Clone of the actor's own command sender, used by the task-board
    // scheduler to spawn workers and deliver digests through the normal
    // message-routing path (always try_send, never await — see board.rs).
    self_cmd_tx: mpsc::Sender<ControlCommand>,
    events_tx: broadcast::Sender<AgentEvent>,
    mut events_rx: broadcast::Receiver<AgentEvent>,
    tool_hub: Arc<FrontendToolHub>,
    status: Arc<RwLock<ControlStatus>>,
    current_mission: Arc<RwLock<Option<Uuid>>>,
    current_tree: Arc<RwLock<Option<AgentTreeNode>>>,
    progress: Arc<RwLock<ExecutionProgress>>,
    mission_store: Arc<dyn MissionStore>,
    secrets: Option<Arc<SecretsStore>>,
    session_user_id: String,
    // Shared registry of in-flight Claude Code background shell tasks. Written
    // here from the `ToolResult` event arm; read by the auto-resume watcher.
    background_tasks: super::super::mission_runner::BackgroundTaskRegistry,
    assignment_owners: Arc<RwLock<HashSet<Uuid>>>,
) {
    // A process-local actor cannot reattach a harness JoinHandle after restart.
    // Close any inherited execution lease before accepting new work; durable
    // workspace/remote jobs remain independently recoverable by job id. Use
    // the established server_shutdown reason so the startup recovery task
    // below re-drives task-mode missions (assistant-mode missions remain idle).
    if let Ok(inherited_runs) = mission_store.list_active_mission_runs().await {
        for run in inherited_runs {
            // Orb owns this native process. A Core restart cannot prove it
            // stopped; retain its fence until the computer confirms termination.
            if run.owner_actor_id.starts_with("orb-client:") {
                continue;
            }
            if run.execution_state == MissionExecutionState::WaitingRemoteJob {
                let mission_status = match mission_store.get_mission(run.mission_id).await {
                    Ok(Some(mission)) => mission.status,
                    Ok(None) => MissionStatus::Interrupted,
                    Err(error) => {
                        // Do not destroy detached work while its presentation
                        // status cannot be read. The remote reconciler will
                        // retry once the store is available.
                        tracing::warn!(
                            mission_id = %run.mission_id,
                            run_id = %run.run_id,
                            %error,
                            "Control actor startup: mission status unavailable; preserving wait lease"
                        );
                        continue;
                    }
                };
                match recoverable_inherited_remote_wait(
                    &config.working_dir,
                    run.mission_id,
                    run.execution_state,
                    mission_status,
                )
                .await
                {
                    Ok(Some(job_id)) => {
                        tracing::info!(
                            mission_id = %run.mission_id,
                            run_id = %run.run_id,
                            generation = run.generation,
                            %job_id,
                            "Control actor startup: preserving recoverable remote-build wait lease"
                        );
                        continue;
                    }
                    Ok(None) => {
                        tracing::warn!(
                            mission_id = %run.mission_id,
                            run_id = %run.run_id,
                            "Control actor startup: remote wait has no accepted ledger handle; interrupting stale lease"
                        );
                    }
                    Err(error) => {
                        // The ledger is execution truth for detached remote
                        // work. Fail closed and let its reconciler retry rather
                        // than destroying a possibly-live lease on a transient
                        // read failure.
                        tracing::warn!(
                            mission_id = %run.mission_id,
                            run_id = %run.run_id,
                            %error,
                            "Control actor startup: remote job ledger unavailable; preserving wait lease"
                        );
                        continue;
                    }
                }
            }
            let _ = mission_store
                .finish_mission_run(run.run_id, run.generation, Some("server_shutdown"))
                .await;
            if let Ok(Some(mission)) = mission_store.get_mission(run.mission_id).await {
                if mission.status == MissionStatus::Active {
                    let _ = mission_store
                        .update_mission_status_with_reason(
                            run.mission_id,
                            MissionStatus::Interrupted,
                            Some("server_shutdown"),
                        )
                        .await;
                }
            }
        }
    }
    // Queue stores (id, content, agent, target_mission_id) for the current/primary mission
    // The target_mission_id tracks which mission each queued message is intended for
    let mut queue: VecDeque<ControlQueueEntry> = VecDeque::new();
    // Re-drive any messages that were queued before the last restart. They are
    // persisted as a JSON snapshot (see `persist_control_queue_if_changed`) so a
    // restart doesn't lose pending work. We re-inject them through the normal
    // command channel rather than pushing straight onto `queue`: an idle actor
    // never dequeues a pre-filled `queue` on its own, so the work would
    // otherwise sit forever for legacy entries. Accepted host follow-ups now
    // have an idle retry interval and are restored directly so paused work is
    // retained. Routing legacy entries as commands also de-duplicates against
    // a client retry of the same id via `accept_user_message_id` (whichever
    // arrives first runs; the other is dropped), so nothing executes twice.
    let mut restored_db_snapshot = String::new();
    let mut recovered_consumed_user_messages: HashMap<Uuid, QueuedMessage> = HashMap::new();
    if let Ok(payload) = mission_store.load_control_queue(&session_user_id).await {
        if !payload.trim().is_empty() {
            match serde_json::from_str::<Vec<QueuedMessage>>(&payload) {
                Ok(items) => {
                    let count = items.len();
                    let (pending, consumed) = partition_restored_control_messages(items);
                    let interrupted = consumed.len();
                    recovered_consumed_user_messages
                        .extend(consumed.into_iter().map(|message| (message.id, message)));
                    let mut replayed = 0usize;
                    for it in pending {
                        if host_followup_source(it.source.as_deref()) {
                            // These messages already passed queued admission. Restore
                            // the durable queue itself, retaining paused/blocked work;
                            // the idle retry interval will dispatch it when runnable.
                            enqueue_control_message(
                                &mut queue,
                                (it.id, it.content, it.agent, it.mission_id, it.source),
                            );
                            replayed += 1;
                            continue;
                        }
                        let (ack_tx, _ack_rx) = tokio::sync::oneshot::channel();
                        if let Err(e) = self_cmd_tx.try_send(ControlCommand::UserMessage {
                            id: it.id,
                            content: it.content,
                            agent: it.agent,
                            target_mission_id: it.mission_id,
                            strict: false,
                            source: it.source,
                            respond: ack_tx,
                        }) {
                            tracing::warn!("Failed to re-queue restored control message: {e}");
                        } else {
                            replayed += 1;
                        }
                    }
                    if count > 0 {
                        // Remember the stale on-disk snapshot so the first
                        // loop-top persist below rewrites the DB to the real
                        // (re-injected) state instead of leaving it stale.
                        restored_db_snapshot = payload;
                        tracing::info!(
                            replayed,
                            interrupted,
                            total = count,
                            "Recovered durable control messages from the previous session"
                        );
                    }
                }
                Err(e) => tracing::warn!("Failed to parse persisted control queue: {e}"),
            }
        }
    }
    // Parallel mission runners - each runs independently. Their pending
    // messages share the durable session queue snapshot with the main queue.
    let mut parallel_runners: std::collections::HashMap<
        Uuid,
        super::super::mission_runner::MissionRunner,
    > = std::collections::HashMap::new();

    // Snapshot of the queue as last written to the store; used to debounce
    // persistence so we only write to the DB when the queue actually changes.
    // When messages were restored, seed it with the stale on-disk snapshot so
    // the first loop-top persist overwrites it with the live queue.
    let mut last_persisted_queue: String = if restored_db_snapshot.is_empty() {
        serialize_queue_snapshot(&queue, &parallel_runners, &recovered_consumed_user_messages)
    } else {
        restored_db_snapshot
    };
    let mut history: Vec<(String, String)> = Vec::new(); // (role, content) pairs (user/assistant)
    let mut running: Option<tokio::task::JoinHandle<(Uuid, String, crate::agents::AgentResult)>> =
        None;
    let mut running_cancel: Option<CancellationToken> = None;
    // Track which mission the main `running` task is actually working on.
    // This is different from `current_mission` which can change when user creates a new mission.
    let mut running_mission_id: Option<Uuid> = None;
    let mut running_message_id: Option<Uuid> = None;
    let mut running_execution_ids = Vec::new();
    // Backend captured for the currently executing primary turn. Updating a
    // mission's settings while it runs must not change watchdog semantics for
    // that in-flight process.
    let mut running_backend_id: Option<String> = None;
    let mut running_run: Option<MissionRun> = None;
    let mut parallel_followup_retry = std::time::Instant::now();
    let mut parallel_poll = tokio::time::interval(std::time::Duration::from_millis(100));
    let mut queued_delivery_retry = tokio::time::interval(std::time::Duration::from_secs(1));
    let mut execution_heartbeat = tokio::time::interval(std::time::Duration::from_secs(15));
    execution_heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    // Track last activity for the main runner (for stall detection)
    let mut main_runner_last_activity: std::time::Instant = std::time::Instant::now();
    // Track current activity label for the main runner
    let mut main_runner_activity: Option<String> = None;
    // Idempotency guard for user sends. The dashboard may retry a POST if a
    // weak connection drops after the command reached this actor but before the
    // HTTP response got back; since the client provides the UUID, repeated
    // commands with the same id are ignored instead of running twice. Restored
    // messages (re-injected as commands above) rely on this same guard: the
    // first occurrence runs, any later duplicate is dropped.
    let mut accepted_user_message_ids: HashSet<Uuid> = HashSet::new();
    // Alias membership follows the outer acceptance bit. Rejection/release
    // removes that bit, so constituent IDs cannot suppress a legitimate retry.
    let mut accepted_user_message_batches: HashMap<Uuid, Vec<Uuid>> = HashMap::new();
    // One bounded same-mission retry for structured transport failures. Auth,
    // quota/capacity, source failures, stalls, and loops are deliberately not
    // eligible. Writer leases are re-acquired by the normal start path.
    let mut transport_auto_resumed_missions: HashMap<Uuid, u8> = HashMap::new();
    // Track subtasks for the main runner
    let mut main_runner_subtasks: Vec<super::super::mission_runner::SubtaskInfo> = Vec::new();
    // Track number of in-flight tool calls on the main runner so the stall
    // classifier can distinguish "model is hung" from "tool is honestly
    // running" (e.g. a 12-minute `lake build`). See stall_severity().
    let main_runner_active_tool_calls: std::sync::Arc<std::sync::atomic::AtomicUsize> =
        std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    // Deadline for force-reaping a runner whose cancel token was fired
    // but whose JoinHandle never resolved. This handles the "zombie
    // runner" case: the underlying CLI subprocess died (or never reacts
    // to the cancel because it's blocked on a closed pipe / dead
    // child), so the spawned task never returns, `running` stays
    // `Some`, the in-memory running list keeps reporting the mission,
    // and `Stop` becomes a no-op. After this deadline we force-abort
    // the JoinHandle and clean up the in-memory state.
    let mut runner_force_clear_deadline: Option<tokio::time::Instant> = None;
    let mut runner_force_abort_requested = false;
    const RUNNER_FORCE_CLEAR_GRACE: std::time::Duration = std::time::Duration::from_secs(30);

    // Correlate Bash `tool_call_id` -> command string so that when the matching
    // `Bash` ToolResult carries a background-start marker we can record the
    // launched command in the background-task registry. Capped to avoid
    // unbounded growth if a result is ever dropped; entries are removed when
    // the matching result arrives. Only `Bash` calls are tracked.
    let mut pending_bash_commands: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    const MAX_PENDING_BASH_COMMANDS: usize = 256;
    let background_autoresume_enabled =
        super::super::mission_runner::background_task_autoresume_enabled();

    // Task-board scheduler cadence: the 100ms tick is far too hot for store
    // scans, so passes run every few seconds. Each pass spawns ready workers,
    // sweeps zombies, and wakes idle bosses whose board needs a decision.
    const BOARD_PASS_INTERVAL: std::time::Duration = std::time::Duration::from_secs(3);
    let mut last_board_pass = tokio::time::Instant::now();
    // FLEET-001 scheduling dispatch cadence: same throttling rationale as the
    // board pass — a store scan on every 100ms tick is wasteful. Each pass
    // expires past-deadline scheduled missions and, when the main session is
    // idle, dispatches the highest-priority dispatchable one.
    const SCHEDULER_PASS_INTERVAL: std::time::Duration = std::time::Duration::from_secs(5);
    let mut last_scheduler_pass = tokio::time::Instant::now();
    // Guards against double-dispatch: a scheduled mission stays Pending (with its
    // goal) until the dispatched message is processed and flips it to Active. If
    // the actor is slow or the start is dropped, that window can exceed one pass,
    // so we record each dispatch and skip re-dispatching the same mission until
    // this cooldown elapses (after which a still-Pending mission is retried).
    const SCHEDULER_DISPATCH_COOLDOWN: std::time::Duration = std::time::Duration::from_secs(60);
    let mut scheduler_inflight: std::collections::HashMap<Uuid, tokio::time::Instant> =
        std::collections::HashMap::new();
    // Per-boss "wake outstanding" flags, coalescing board wakes across passes.
    let mut board_wake_state: std::collections::HashMap<Uuid, bool> =
        std::collections::HashMap::new();
    let board_outbox_inflight: board::BoardOutboxInflight =
        Arc::new(std::sync::Mutex::new(std::collections::HashSet::new()));

    // Helper to extract file paths from text (for mission summaries)
    fn extract_file_paths(text: &str) -> Vec<String> {
        let mut paths = Vec::new();
        // Match common file path patterns
        for word in text.split_whitespace() {
            let word =
                word.trim_matches(|c| c == '`' || c == '\'' || c == '"' || c == ',' || c == ':');
            if (word.starts_with('/') || word.starts_with("./"))
                && word.len() > 3
                && !word.contains("http")
                && word.chars().filter(|c| *c == '/').count() >= 1
            {
                // Likely a file path
                paths.push(word.to_string());
            }
        }
        paths
    }

    // Helper to persist history to a specific mission ID
    async fn persist_mission_history_to(
        mission_store: &Arc<dyn MissionStore>,
        events_tx: &broadcast::Sender<AgentEvent>,
        mission_id: Option<Uuid>,
        history: &[(String, String)],
    ) {
        if let Some(mid) = mission_id {
            let entries: Vec<MissionHistoryEntry> = history
                .iter()
                .map(|(role, content)| MissionHistoryEntry {
                    role: role.clone(),
                    content: content.clone(),
                })
                .collect();
            persist_mission_history_and_schedule_metadata_refresh(
                mission_store,
                events_tx,
                mid,
                &entries,
            )
            .await;
        }
    }

    // Helper to persist history to current mission (wrapper for backwards compatibility)
    async fn persist_mission_history(
        mission_store: &Arc<dyn MissionStore>,
        events_tx: &broadcast::Sender<AgentEvent>,
        current_mission: &Arc<RwLock<Option<Uuid>>>,
        history: &[(String, String)],
    ) {
        let mission_id = *current_mission.read().await;
        persist_mission_history_to(mission_store, events_tx, mission_id, history).await;
    }

    fn parse_tool_result_object(result: &serde_json::Value) -> Option<serde_json::Value> {
        if result.is_object() {
            return Some(result.clone());
        }
        if let Some(raw) = result.as_str() {
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(raw) {
                return Some(parsed);
            }
        }
        None
    }

    /// Extract the human-readable text from a tool result `Value`.
    ///
    /// The Claude Code runner emits either a plain string or an object of the
    /// form `{ "content": ..., "stdout": ..., "stderr": ..., "is_error": ... }`
    /// (see `runners::claudecode`). We prefer `content`, falling back to
    /// `stdout`, then the whole string. Returns `None` when no text is present.
    fn tool_result_text(result: &serde_json::Value) -> Option<String> {
        if let Some(s) = result.as_str() {
            return Some(s.to_string());
        }
        if let Some(obj) = result.as_object() {
            for key in ["content", "stdout"] {
                if let Some(s) = obj.get(key).and_then(|v| v.as_str()) {
                    if !s.is_empty() {
                        return Some(s.to_string());
                    }
                }
            }
        }
        None
    }

    // Helper to load a mission and return a Mission struct
    async fn load_mission_record(
        mission_store: &Arc<dyn MissionStore>,
        id: Uuid,
    ) -> Result<Mission, String> {
        mission_store
            .get_mission(id)
            .await?
            .ok_or_else(|| format!("Mission {} not found", id))
    }

    // Helper to create a new mission
    async fn create_new_mission(mission_store: &Arc<dyn MissionStore>) -> Result<Mission, String> {
        create_new_mission_with_title(
            mission_store,
            None,
            None,
            None,
            None,
            None,
            false,
            None,
            None,
            None,
            None,
            crate::api::mission_store::MissionScheduling::default(),
        )
        .await
    }

    // Helper to create a new mission with title
    #[allow(clippy::too_many_arguments)]
    async fn create_new_mission_with_title(
        mission_store: &Arc<dyn MissionStore>,
        title: Option<&str>,
        workspace_id: Option<Uuid>,
        agent: Option<&str>,
        model_override: Option<&str>,
        model_effort: Option<&str>,
        fast_mode: bool,
        backend: Option<&str>,
        config_profile: Option<&str>,
        parent_mission_id: Option<Uuid>,
        working_directory: Option<&str>,
        scheduling: crate::api::mission_store::MissionScheduling,
    ) -> Result<Mission, String> {
        create_new_mission_with_title_and_placement(
            mission_store,
            title,
            workspace_id,
            agent,
            model_override,
            model_effort,
            fast_mode,
            backend,
            config_profile,
            parent_mission_id,
            working_directory,
            true,
            scheduling,
            None,
        )
        .await
    }

    /// Persist placement authority with the Pending mission row.  The
    /// admission ledger is only a byte lease and must never decide whether a
    /// restarted mission is local or remote.
    #[allow(clippy::too_many_arguments)]
    async fn create_new_mission_with_title_and_placement(
        mission_store: &Arc<dyn MissionStore>,
        title: Option<&str>,
        workspace_id: Option<Uuid>,
        agent: Option<&str>,
        model_override: Option<&str>,
        model_effort: Option<&str>,
        fast_mode: bool,
        backend: Option<&str>,
        config_profile: Option<&str>,
        parent_mission_id: Option<Uuid>,
        working_directory: Option<&str>,
        requires_local_disk: bool,
        scheduling: crate::api::mission_store::MissionScheduling,
        assigned_id: Option<Uuid>,
    ) -> Result<Mission, String> {
        let mut mission = mission_store
            .create_mission_with_parent_and_placement(
                title,
                workspace_id,
                agent,
                model_override,
                model_effort,
                fast_mode,
                backend,
                config_profile,
                parent_mission_id,
                working_directory,
                requires_local_disk,
                assigned_id,
            )
            .await?;
        // FLEET-001: persist scheduling metadata as a focused follow-up write so
        // the wide `create_mission_with_parent` signature stays untouched.
        if scheduling != crate::api::mission_store::MissionScheduling::default() {
            mission_store
                .set_mission_scheduling(mission.id, &scheduling)
                .await?;
            mission.scheduling = scheduling;
        }
        Ok(mission)
    }

    // Helper to validate and prepare an interrupted or blocked mission for resume.
    async fn resume_mission_impl(
        mission_store: &Arc<dyn MissionStore>,
        config: &Config,
        mission_id: Uuid,
        clean_workspace: bool,
    ) -> Result<(Mission, String), String> {
        let mission = load_mission_record(mission_store, mission_id).await?;

        if let Some(placement) =
            remote_grok::placement(&config.working_dir, mission_store, mission_id).await?
        {
            return Err(remote_grok::local_resume_refusal(&mission, &placement));
        }

        // A mission waiting for a usage limit can be resumed before the
        // reset (another account was added, credits were bought): the
        // schedule is lifted and the stored resume prompt is used.
        if usage_limit_wait::is_waiting(&mission) {
            let prompt = usage_limit_wait::release(mission_store, &mission)
                .await?
                .unwrap_or_else(|| INTERRUPTED_RESUME_PROMPT.to_string());
            return Ok((mission, prompt));
        }

        // Check if mission can be resumed. Paused remains Paused until the
        // actor has acquired the durable writer lock and accepted the resume.
        // Failed missions can be resumed to retry after transient errors (e.g., 529 overloaded)
        if !matches!(
            mission.status,
            MissionStatus::Interrupted
                | MissionStatus::Blocked
                | MissionStatus::Failed
                | MissionStatus::Paused
        ) {
            return Err(format!(
                "Mission {} cannot be resumed (status: {})",
                mission_id, mission.status
            ));
        }

        // Clean mission context if requested.
        // Missions share the workspace directory, so we avoid deleting project files.
        if clean_workspace {
            let context_root = config.working_dir.join(&config.context.context_dir_name);
            let mission_context_dir = context_root.join(mission_id.to_string());
            tracing::info!(
                mission_id = %mission_id,
                path = %mission_context_dir.display(),
                "Cleaning mission context directory (shared workspace mode)"
            );
            if mission_context_dir.exists() {
                if let Err(e) = std::fs::remove_dir_all(&mission_context_dir) {
                    tracing::warn!("Failed to clean mission context: {}", e);
                }
            }
            let _ = std::fs::create_dir_all(&mission_context_dir);

            let runtime_file =
                workspace::runtime_workspace_file_path(&config.working_dir, Some(mission_id));
            let _ = std::fs::remove_file(runtime_file);
        }

        let prompt = if mission.backend == "codex" && mission.goal_mode {
            mission
                .goal_objective
                .as_ref()
                .map(|objective| format!("/goal {objective}"))
        } else if mission.backend == "antigravity" && mission.goal_mode {
            mission
                .goal_objective
                .as_ref()
                .map(|objective| format!("/goal {objective}\n\n{INTERRUPTED_RESUME_PROMPT}"))
        } else {
            None
        }
        .unwrap_or_else(|| INTERRUPTED_RESUME_PROMPT.to_string());
        Ok((mission, prompt))
    }

    loop {
        let mut owners = HashSet::new();
        if running.is_some() {
            owners.extend(running_mission_id);
        }
        let current_id = *current_mission.read().await;
        owners.extend(
            queue
                .iter()
                .filter(|entry| !host_followup_source(entry.4.as_deref()))
                .filter_map(|entry| entry.3.or(running_mission_id).or(current_id)),
        );
        owners.extend(
            parallel_runners
                .iter()
                .filter(|(_, runner)| {
                    runner.is_running()
                        || runner
                            .queue
                            .iter()
                            .any(|m| !host_followup_source(m.source.as_deref()))
                        || runner.inflight_message().is_some_and(|m| {
                            runner.durable_run.is_some()
                                || !host_followup_source(m.source.as_deref())
                        })
                })
                .map(|(id, _)| *id),
        );
        owners.extend(
            background_tasks
                .read()
                .await
                .iter()
                .filter(|(_, tasks)| !tasks.is_empty())
                .map(|(id, _)| *id),
        );
        *assignment_owners.write().await = owners;
        // Persist the pending queue whenever it changes so a restart doesn't
        // lose queued messages. Debounced by snapshot comparison — the DB is
        // written only when the queue actually changed (no per-iteration churn
        // during streaming, where the queue is usually unchanged). Each dequeue
        // site below also persists immediately so a popped message can't be
        // re-run after a crash (see `persist_control_queue_if_changed`).
        let _ = persist_control_queue_if_changed(
            &mission_store,
            &session_user_id,
            &queue,
            &parallel_runners,
            &recovered_consumed_user_messages,
            &mut last_persisted_queue,
        )
        .await;
        tokio::select! {
                    _ = execution_heartbeat.tick() => {
                        let mut leases = Vec::new();
                        if let Some(run) = running_run.clone() {
                            leases.push((
                                run,
                                running_backend_id.clone(),
                                main_runner_active_tool_calls
                                    .load(std::sync::atomic::Ordering::Relaxed),
                                main_runner_last_activity.elapsed().as_secs(),
                            ));
                        }
                        leases.extend(parallel_runners.values().filter_map(|runner| {
                            runner.durable_run.clone().map(|run| {
                                (
                                    run,
                                    Some(runner.backend_id.clone()),
                                    runner
                                        .active_tool_calls
                                        .load(std::sync::atomic::Ordering::Relaxed),
                                    runner.last_activity.elapsed().as_secs(),
                                )
                            })
                        }));
                        let remote_jobs_by_mission = if leases.is_empty() {
                            HashSet::new()
                        } else {
                            match crate::remote_node::job_ledger::load(&config.working_dir).await {
                                Ok(handles) => {
                                    let now = chrono::Utc::now();
                                    handles
                                        .into_iter()
                                        .filter(|handle| remote_build_handle_proves_liveness(handle, now))
                                        .map(|handle| handle.mission_id)
                                        .collect()
                                }
                                Err(error) => {
                                    tracing::warn!(?error, "Failed to inspect durable remote jobs for execution heartbeat");
                                    HashSet::new()
                                }
                            }
                        };
                        for (run, backend_id, active_tool_calls, idle_secs) in leases {
                            let mut live_registered_tools = 0usize;
                            let mut has_registered_user_wait = false;
                            let has_durable_remote_job = remote_jobs_by_mission.contains(&run.mission_id);
                            if has_durable_remote_job {
                                live_registered_tools += 1;
                            }
                            if let Ok(tools) = mission_store
                                .list_active_tool_executions(run.run_id)
                                .await
                            {
                                for tool in tools {
                                    if is_user_wait_tool(&tool.tool_kind) {
                                        // User-input tools remain live until their
                                        // matching result arrives. The generic 120s
                                        // provisional deadline must never reap a
                                        // mission merely because a human took longer
                                        // than two minutes to answer.
                                        has_registered_user_wait = true;
                                        live_registered_tools += 1;
                                        continue;
                                    }
                                    let expired = chrono::DateTime::parse_from_rfc3339(
                                        &tool.deadline_at,
                                    )
                                    .map(|deadline| {
                                        deadline.with_timezone(&chrono::Utc) <= chrono::Utc::now()
                                    })
                                    .unwrap_or(true);
                                    if expired && tool.state == MissionToolExecutionState::Provisional {
                                        let _ = mission_store
                                            .finish_tool_execution(
                                                run.run_id,
                                                &tool.tool_call_id,
                                                MissionToolExecutionState::Stale,
                                                None,
                                                Some("unmatched_tool_call_deadline"),
                                            )
                                            .await;
                                    } else {
                                        live_registered_tools += 1;
                                    }
                                }
                            }
                            let state = mission_heartbeat_state(
                                active_tool_calls,
                                has_registered_user_wait,
                                has_durable_remote_job,
                            );
                            match mission_store
                                .heartbeat_mission_run(run.run_id, run.generation, state, None)
                                .await
                            {
                                Ok(true) => {}
                                Ok(false) => tracing::warn!(
                                    mission_id = %run.mission_id,
                                    run_id = %run.run_id,
                                    generation = run.generation,
                                    "Ignored heartbeat for stale mission run generation"
                                ),
                                Err(error) => tracing::warn!(
                                    mission_id = %run.mission_id,
                                    run_id = %run.run_id,
                                    "Failed to persist mission run heartbeat: {error}"
                                ),
                            }
                            if idle_secs >= 15 * 60
                                && state != MissionExecutionState::WaitingUser
                                && state != MissionExecutionState::WaitingRemoteJob
                                && live_registered_tools == 0
                            {
                                let owned = match mission_store.get_mission(run.mission_id).await {
                                    Ok(Some(mission)) => skip_idle_registered_liveness_interrupt(
                                        backend_id.as_deref(),
                                        mission.origin.as_deref(),
                                        mission.origin_session_id.as_deref(),
                                        &mission.project.tags,
                                    ),
                                    _ => skip_idle_registered_liveness_interrupt(
                                        backend_id.as_deref(),
                                        None,
                                        None,
                                        &[],
                                    ),
                                };
                                if owned {
                                    tracing::warn!(
                                        mission_id = %run.mission_id,
                                        run_id = %run.run_id,
                                        idle_secs,
                                        "Registered-liveness interrupt: control-owned mission idle — NOT interrupting"
                                    );
                                    continue;
                                }
                                tracing::warn!(
                                    mission_id = %run.mission_id,
                                    run_id = %run.run_id,
                                    idle_secs,
                                    "Interrupting mission after 15 minutes without registered liveness evidence"
                                );
                                let _ = mission_store
                                    .heartbeat_mission_run(
                                        run.run_id,
                                        run.generation,
                                        MissionExecutionState::Stopping,
                                        None,
                                    )
                                    .await;
                                if running_mission_id == Some(run.mission_id) {
                                    if let Some(token) = &running_cancel {
                                        token.cancel();
                                        runner_force_clear_deadline = Some(
                                            tokio::time::Instant::now() + RUNNER_FORCE_CLEAR_GRACE,
                                        );
                                    }
                                } else if let Some(runner) = parallel_runners.get_mut(&run.mission_id) {
                                    runner.cancel();
                                }
                            }
                        }
                    }
                    cmd = cmd_rx.recv() => {
                        let Some(cmd) = cmd else { break };
                        // Stop may revoke a delivery while its command is already in this
                        // channel. Reject it before client routing or admission can resume
                        // the interrupted mission. The actor serializes this with Stop.
                        let scheduled_target = match &cmd {
                            ControlCommand::UserMessage { id, target_mission_id: Some(mid), source, .. }
                                if source.as_deref() == Some("scheduled-continuation") => Some((*mid, *id)),
                            ControlCommand::AdmitDispatch { command, .. } => match command.as_ref() {
                                ControlCommand::UserMessage { id, target_mission_id: Some(mid), source, .. }
                                    if source.as_deref() == Some("scheduled-continuation") => Some((*mid, *id)),
                                _ => None,
                            },
                            _ => None,
                        };
                        if let Some((mid, id)) = scheduled_target {
                            let rejection = match mission_store.can_admit_scheduled_delivery(mid, id).await {
                                Ok(true) => None,
                                Ok(false) => Some("Scheduled continuation was revoked".to_string()),
                                Err(error) => Some(format!("Could not validate scheduled continuation: {error}")),
                            };
                            if let Some(error) = rejection {
                                let command = match cmd { ControlCommand::AdmitDispatch { command, .. } => *command, command => command };
                                if let ControlCommand::UserMessage { respond, .. } = command {
                                    let _ = respond.send(UserMessageAck::Rejected(error));
                                }
                                continue;
                            }
                        }
                        // Reject remote messages before admission can retag or reactivate
                        // the mission. The actual node continuation is the resume route.
                        let message_target = match &cmd {
                            ControlCommand::UserMessage { target_mission_id, .. } => *target_mission_id,
                            ControlCommand::AdmitDispatch { command, .. } => match command.as_ref() {
                                ControlCommand::UserMessage { target_mission_id, .. } => *target_mission_id,
                                _ => None,
                            },
                            _ => None,
                        };
                        if let Some(mid) = message_target {
                            if mission_store.get_mission(mid).await.ok().flatten().is_some_and(|m| client_placement::is_tagged(&m.project.tags)) {
                                let command = match cmd { ControlCommand::AdmitDispatch { command, .. } => *command, command => command };
                                if let ControlCommand::UserMessage { id, content, source, respond, .. } = command {
                                    let ack = match worker_location::enqueue_with_source(&mission_store, mid, id, content, source.as_deref() == Some("scheduled-continuation")).await {
                                        Ok(()) => UserMessageAck::Queued,
                                        Err(error) => UserMessageAck::Rejected(error),
                                    };
                                    let _ = respond.send(ack);
                                }
                                continue;
                            }
                        }
                        if let Some(mid) = message_target {
                            if let Err(error) = remote_grok::reject_local_followup(&config.working_dir, &mission_store, mid).await {
                                let rejected = match cmd {
                                    ControlCommand::AdmitDispatch { command, .. } => *command,
                                    command => command,
                                };
                                if let ControlCommand::UserMessage { id, content, source, respond, .. } = rejected {
                                    if matches!(source.as_deref(), Some("task-board" | "scheduled-continuation")) {
                                        if let Some(state) = control_hub.admission_state.get().and_then(std::sync::Weak::upgrade) {
                                            let user = AuthUser { id:session_user_id.clone(), username:session_user_id.clone() };
                                            tokio::spawn(async move {
                                                let control=control_for_user(&state,&user).await;
                                                let result=async {
                                                    let placement=remote_grok::placement(&state.config.working_dir,&control.mission_store,mid).await?
                                                        .ok_or("Remote placement disappeared")?;
                                                    remote_grok::continue_on_node(&state,&control,&user.id,mid,placement,Some(content),Some(id)).await
                                                        .map_err(|(_,message)|message)?;
                                                    Ok::<(),String>(())
                                                }.await;
                                                let _=respond.send(match result { Ok(())=>UserMessageAck::Delivered, Err(error)=>UserMessageAck::Rejected(error) });
                                            });
                                            continue;
                                        }
                                    }
                                    let _ = respond.send(UserMessageAck::Rejected(error));
                                }
                                continue;
                            }
                        }

                        // Internal wakes also need current track ownership. They carry
                        // no controller assertion or retag, but use the same admission
                        // and rollback boundary as HTTP dispatch.
                        let cmd = if matches!(&cmd, ControlCommand::UserMessage { target_mission_id: Some(_), .. } | ControlCommand::ResumeMission { .. }) {
                            if let Some(state) = control_hub.admission_state.get().and_then(std::sync::Weak::upgrade) {
                                let work_hint = match &cmd { ControlCommand::UserMessage { content, .. } => Some(content.clone()), _ => None };
                                ControlCommand::AdmitDispatch {
                                    admission: Box::new(DispatchAdmission {
                                        state,
                                        store: mission_store.clone(),
                                        // Internal control messages are not retasks;
                                        // do not run prose recycle inference on them.
                                        patch: Default::default(),
                                        internal_work_hint: work_hint,
                                    }),
                                    command: Box::new(cmd),
                                }
                            } else { cmd }
                        } else { cmd };
                        #[cfg(test)]
                        if let ControlCommand::AdmitDispatch { command, .. } = &cmd {
                            let id = match command.as_ref() {
                                ControlCommand::UserMessage { target_mission_id, .. } => *target_mission_id,
                                ControlCommand::ResumeMission { mission_id, .. } => Some(*mission_id),
                                _ => None,
                            };
                            if let Some(id) = id { dispatch_admission_tests::notify_wait(id, "actor"); }
                        }
                        let admission_guard = DISPATCH_ADMISSION.lock().await;
                        let (cmd, _admission_guard) = match cmd {
                            ControlCommand::AdmitDispatch { admission, command } => {
                                // Deduplication is an admission decision too: a retry
                                // cannot smuggle a new assignment into an accepted id.
                                if let ControlCommand::UserMessage { id, target_mission_id, .. } = command.as_ref() {
                                    let pending_in_queue = queue.iter().any(|entry| control_message_contains_id(entry.0, &entry.1, entry.4.as_deref(), *id))
                                        || parallel_runners.values().any(|runner| runner.queue.iter().any(|entry| control_message_contains_id(entry.id, &entry.content, entry.source.as_deref(), *id)));
                                    let consumed = recovered_consumed_user_messages.values().any(|entry| control_message_contains_id(entry.id, &entry.content, entry.source.as_deref(), *id))
                                        || parallel_runners.values().any(|runner| runner.inflight_message().is_some_and(|entry| control_message_contains_id(entry.id, &entry.content, entry.source.as_deref(), *id)));
                                    let pending_deferred = if let Some(mid) = target_mission_id {
                                        match mission_store.get_mission(*mid).await {
                                            Ok(Some(mission)) if mission.status == MissionStatus::Pending => {
                                                mission_store.get_deferred_goal(*mid).await.ok().flatten()
                                                    .is_some_and(|goal| deferred_messages::decode(&goal).1.iter().any(|(message_id, _)| message_id == id))
                                            }
                                            _ => false,
                                        }
                                    } else { false };
                                    let pending = pending_in_queue || pending_deferred;
                                    let accepted = accepted_user_message_ids.contains(id)
                                        || accepted_user_message_batches.iter().any(|(outer, ids)| accepted_user_message_ids.contains(outer) && ids.contains(id));
                                    // Completed runners leave the live snapshot. Their durable
                                    // transcript still owns both the outer ID and constituent
                                    // scheduler IDs across later control-session restarts.
                                    let delivered_history = if !pending && !consumed && !accepted {
                                        if let Some(mid) = target_mission_id {
                                            match mission_store.get_events(*mid, Some(&["user_message"]), None, None).await {
                                                Ok(events) => events.iter().filter(|event| event.metadata.get("queued").and_then(|value| value.as_bool()) != Some(true)).any(|event| {
                                                    event.event_id.as_deref().and_then(|value| Uuid::parse_str(value).ok()) == Some(*id)
                                                        || (event.metadata.get("source").and_then(|value| value.as_str()) == Some("scheduler")
                                                            && event.metadata.get("messages").and_then(|value| serde_json::from_value::<Vec<(Uuid, String)>>(value.clone()).ok())
                                                                .is_some_and(|messages| messages.iter().any(|(message_id, _)| message_id == id)))
                                                }),
                                                Err(error) => {
                                                    if let ControlCommand::UserMessage { respond, .. } = *command {
                                                        let _ = respond.send(UserMessageAck::Rejected(format!("failed to check prior message receipts: {error}")));
                                                    }
                                                    continue;
                                                }
                                            }
                                        } else { false }
                                    } else { false };
                                    if pending || consumed || delivered_history || accepted {
                                        if let ControlCommand::UserMessage { respond, .. } = *command {
                                            let _ = respond.send(if pending { UserMessageAck::Queued } else { UserMessageAck::Delivered });
                                        }
                                        continue;
                                    }
                                }
                                let queued_followup = matches!(command.as_ref(), ControlCommand::UserMessage {
                                    target_mission_id: Some(_), agent: None, strict: false, source: Some(source), content, ..
                                } if host_followup_source(Some(source)) && !content.trim_start().starts_with("/goal"))
                                    && admission.patch.title.is_none()
                                    && admission.patch.github_pr.is_none()
                                    && admission.patch.track.is_none();
                                let pending_followup = if queued_followup {
                                    match command.as_ref() {
                                        ControlCommand::UserMessage { target_mission_id: Some(id), .. } => mission_store.get_mission(*id).await.ok().flatten(),
                                        _ => None,
                                    }
                                        .filter(|mission| mission.status == MissionStatus::Pending)
                                } else { None };
                                let queued_followup = queued_followup && pending_followup.as_ref()
                                    .is_none_or(|mission| !mission.is_dispatchable_at(chrono::Utc::now()));
                                if queued_followup {
                                    if let ControlCommand::UserMessage { id, content, agent, target_mission_id: Some(mid), source, respond, .. } = *command {
                                        let _file = match dispatch_admission::durable_lock(&config).await {
                                            Ok(guard) => guard,
                                            Err(error) => { let _ = respond.send(UserMessageAck::Rejected(error)); continue; }
                                        };
                                        if let Err(error) = dispatch_admission::validate_followup(&admission, mid).await {
                                            let _ = respond.send(UserMessageAck::Rejected(error));
                                            continue;
                                        }
                                        if let Some(mission) = pending_followup {
                                            // Scheduled prompts own the first turn. Append durably
                                            // before resource admission, preserving their ordering.
                                            let saved = async {
                                                let previous = mission_store.get_deferred_goal(mid).await?;
                                                let combined = deferred_goal_for_incoming_message(
                                                    mission.status, previous.as_deref(),
                                                    &deferred_messages::encode(id, &content),
                                                );
                                                mission_store.set_deferred_goal(mid, Some(combined)).await
                                            }.await;
                                            if let Err(error) = saved {
                                                let _ = respond.send(UserMessageAck::Rejected(format!("failed to persist queued delivery: {error}")));
                                                continue;
                                            }
                                            accepted_user_message_ids.insert(id);
                                            let _ = events_tx.send(AgentEvent::UserMessage {
                                                id, content, queued: true, mission_id: Some(mid), source,
                                            });
                                            let _ = respond.send(UserMessageAck::Queued);
                                            continue;
                                        }
                                        if let Some(runner) = parallel_runners.get_mut(&mid) {
                                            if runner.cancellation_requested() {
                                                let _ = respond.send(UserMessageAck::Rejected("Mission is stopping".into()));
                                                continue;
                                            }
                                            runner.queue_message(id, content.clone(), agent, source.clone());
                                        } else {
                                            enqueue_control_message(&mut queue, (id, content.clone(), agent, Some(mid), source.clone()));
                                        }
                                        if let Err(error) = persist_control_queue_if_changed(
                                            &mission_store, &session_user_id, &queue, &parallel_runners,
                                            &recovered_consumed_user_messages, &mut last_persisted_queue,
                                        ).await {
                                            queue.retain(|entry| entry.0 != id);
                                            if let Some(runner) = parallel_runners.get_mut(&mid) { runner.remove_from_queue(id); }
                                            prune_empty_provisional_runners(&mut parallel_runners);
                                            let _ = respond.send(UserMessageAck::Rejected(format!("failed to persist queued delivery: {error}")));
                                            continue;
                                        }
                                        accepted_user_message_ids.insert(id);
                                        let _ = events_tx.send(AgentEvent::UserMessage {
                                            id, content, queued: true, mission_id: Some(mid), source,
                                        });
                                        let _ = respond.send(UserMessageAck::Queued);
                                        continue;
                                    }
                                    unreachable!();
                                }
                                let target = match command.as_ref() {
                                    ControlCommand::UserMessage { target_mission_id, .. } => *target_mission_id,
                                    ControlCommand::ResumeMission { mission_id, .. } => Some(*mission_id),
                                    _ => None,
                                };
                                let busy = target.is_some_and(|id| running_mission_id == Some(id)
                                    || parallel_runners.contains_key(&id)
                                    || queue_has_pending_target_mission(&queue, id)
                                    || queue.iter().any(|entry| entry.3.is_none()));
                                let busy = busy || if let Some(id) = target {
                                    background_tasks.read().await.get(&id).is_some_and(|tasks| !tasks.is_empty())
                                } else { false };
                                let actor_before = serde_json::json!({
                                    "user_id": session_user_id,
                                    "current_mission": *current_mission.read().await,
                                    "history": history,
                                });
                                match dispatch_admission::admit_dispatch_with_lifetime(*admission, *command, admission_guard, busy, Some(actor_before)).await {
                                    Some(cmd) => (cmd, None),
                                    None => continue,
                                }
                            }
                            cmd => (cmd, Some(admission_guard)),
                        };
                        match cmd {
                            ControlCommand::UpdateProject { mission_id, user, request, respond } => {
                                let busy = running_mission_id == Some(mission_id)
                                    || parallel_runners.contains_key(&mission_id)
                                    || queue_has_pending_target_mission(&queue, mission_id)
                                    || queue.iter().any(|entry| entry.3.is_none())
                                    || background_tasks.read().await.get(&mission_id).is_some_and(|tasks| !tasks.is_empty());
                                let result = if let Some(state) = control_hub.admission_state.get().and_then(std::sync::Weak::upgrade) {
                                    match dispatch_admission::durable_lock(&state.config).await {
                                        Ok(_file_guard) => update_mission_project_locked(busy, State(state), Extension(user), Path(mission_id), Json(request)).await.map(|Json(m)| m),
                                        Err(error) => Err(internal_error(error)),
                                    }
                                } else {
                                    Err((StatusCode::SERVICE_UNAVAILABLE, "Admission state unavailable".into()))
                                };
                                let _ = respond.send(result);
                            }
                            ControlCommand::AdmitDispatch { .. } => unreachable!("nested admission"),
                            ControlCommand::UserMessage { id, content, agent: msg_agent, target_mission_id, strict, source, respond } => {
                                if let Some(mid) = target_mission_id {
                                    if let Err(error) = remote_grok::reject_local_followup(&config.working_dir, &mission_store, mid).await {
                                        let _ = respond.send(UserMessageAck::Rejected(error));
                                        continue;
                                    }
                                }

                                if recovered_consumed_user_messages.values().any(|entry| control_message_contains_id(entry.id, &entry.content, entry.source.as_deref(), id)) {
                                    // The previous actor had already started this exact
                                    // deterministic delivery. Its run was interrupted
                                    // during startup recovery, so acknowledge the retry
                                    // without repeating side effects; the mission now
                                    // requires an explicit resume.
                                    let _ = respond.send(UserMessageAck::Delivered);
                                    continue;
                                }
                                if !accept_user_message_id(&mut accepted_user_message_ids, id) {
                                    let status_snapshot = status.read().await;
                                    let _ = respond.send(if status_snapshot.state != ControlRunState::Idle {
                                        UserMessageAck::Queued
                                    } else {
                                        UserMessageAck::Delivered
                                    });
                                    continue;
                                }

                                if source.as_deref() == Some("scheduler") {
                                    accepted_user_message_batches.insert(id, deferred_messages::decode(&content).1.into_iter().map(|(id, _)| id).collect());
                                }

                                // Smart routing: decide where to send this message based on target_mission_id
                                // and what's currently running.

                                let current_mission_id = *current_mission.read().await;
                                let running_mid = running_mission_id;
                                let main_mission_id = if running_mid.is_some() {
                                    running_mid
                                } else {
                                    current_mission_id
                                };
                                let main_is_running = running.is_some();

                                // If no explicit target but current_mission differs from the
                                // running mission (i.e., CreateMission switched the pointer),
                                // No inference: a message without an explicit mission_id used to be
                                // silently re-targeted to the actor's "current" mission when it
                                // differed from the running one. In practice every legitimate caller
                                // (dashboard, MCP) sends mission_id explicitly, and the fallback
                                // mis-delivered API messages twice in one night (a worker diagnosis
                                // and an oracle priming both landed in unrelated missions). Messages
                                // without a target now follow the plain default-mission path —
                                // and when even that is ambiguous (a runner busy on one mission
                                // while the session pointer is on another), the message is
                                // DROPPED LOUDLY instead of delivered somewhere surprising.
                                let effective_target = target_mission_id;
                                if effective_target.is_none() && main_is_running {
                                    if let Some(cid) = current_mission_id {
                                        if running_mid != Some(cid) {
                                            tracing::warn!(
                                                running = ?running_mid,
                                                current = %cid,
                                                "Untargeted message rejected: ambiguous target; pass mission_id explicitly"
                                            );
                                            let _ = events_tx.send(AgentEvent::Error {
                                                message: format!(
                                                    "Untargeted message rejected: running mission {:?} differs from current {}; pass mission_id explicitly",
                                                    running_mid, cid
                                                ),
                                                mission_id: Some(cid),
                                                resumable: false,
                                            });
                                            let _ = respond.send(UserMessageAck::Dropped);
                                            continue;
                                        }
                                    }
                                }

                                // Determine if target is already running somewhere
                                let target_in_parallel = effective_target
                                    .map(|tid| parallel_runners.contains_key(&tid))
                                    .unwrap_or(false);
                                let target_is_main = effective_target
                                    .map(|tid| main_mission_id == Some(tid))
                                    .unwrap_or(true); // No target = use main

                                // Grok `/goal <objective>` kickoff: rewrite the message
                                // to the wrapped first-turn prompt and create the
                                // AgentFinished automation row that will drive the
                                // loop. Non-grok backends and non-/goal messages fall
                                // through unchanged. See `api/grok_goal.rs`.
                                let goal_target_mission = effective_target.or(main_mission_id);
                                if target_mission_id.is_none() {
                                    if let Some(mid) = goal_target_mission {
                                        if let Err(error) = remote_grok::reject_local_followup(&config.working_dir, &mission_store, mid).await {
                                            accepted_user_message_ids.remove(&id);
                                            let _ = respond.send(UserMessageAck::Rejected(error));
                                            continue;
                                        }
                                    }
                                }

                                // Only scheduler-owned envelopes are transport metadata.
                                // Direct operator text that resembles one stays literal.
                                let (mut content, deferred_parts) = if source.as_deref() == Some("scheduler") {
                                    deferred_messages::decode(&content)
                                } else { (content, Vec::new()) };
                                // Canonicalise `/goal\n…` to the space form at the single
                                // entry point, so every downstream space-only parser (the
                                // grok kickoff below, the mission_runner dispatch paths,
                                // the codex/opencode goal drivers) sees the same goal
                                // command. Strict (control-plane) messages are never goal
                                // commands and stay byte-exact.
                                if !strict {
                                    if let Some(canonical) = canonical_goal_message(&content) {
                                        content = canonical;
                                    }
                                }
                                // Strict (control-plane) messages are system-generated and must
                                // never be reinterpreted as a `/goal` kickoff — skip the rewrite.
                                if !strict {
                                    match maybe_begin_grok_goal(
                                        &mission_store,
                                        &events_tx,
                                        goal_target_mission,
                                        &content,
                                    )
                                    .await
                                    {
                                        GrokGoalKickoff::Passthrough => {}
                                        GrokGoalKickoff::Rewritten { prompt } => {
                                            content = prompt;
                                        }
                                        GrokGoalKickoff::Rejected { reason } => {
                                            let _ = events_tx.send(AgentEvent::Error {
                                                message: reason,
                                                mission_id: goal_target_mission,
                                                resumable: true,
                                            });
                                            let _ = respond.send(UserMessageAck::Dropped);
                                            continue;
                                        }
                                    }
                                }
                                let content = deferred_messages::wrap(&content, deferred_parts);

                                // Reject paused targets before writer capability is
                                // acquired. Retagging a paused read-only audit for a
                                // message that cannot run would create a phantom lease.
                                if let Some(tid) = effective_target {
                                    if let Ok(Some(mission)) = mission_store.get_mission(tid).await {
                                        if mission.status == MissionStatus::Paused {
                                            let _ = events_tx.send(AgentEvent::Error {
                                                message: format!(
                                                    "Mission {} is paused; resume it before sending messages",
                                                    tid
                                                ),
                                                mission_id: Some(tid),
                                                resumable: true,
                                            });
                                            let _ = respond.send(UserMessageAck::Dropped);
                                            continue;
                                        }
                                    }
                                }

                                // FLEET-001 scheduled-mission deferral: if the target is a
                                // Pending mission whose `not_before` is still in the future
                                // and it isn't already running, stash the goal and leave it
                                // Pending. The scheduler tick re-injects it as a normal user
                                // message once the dispatch window opens. Strict control-plane
                                // messages are operational and never deferred.
                                if !strict {
                                    if let Some(tid) = effective_target {
                                        let target_running =
                                            target_in_parallel || running_mid == Some(tid);
                                        if !target_running {
                                            if let Ok(Some(m)) = mission_store.get_mission(tid).await {
                                                let now = chrono::Utc::now();
                                                if m.status == MissionStatus::Pending
                                                    && !m.is_dispatchable_at(now)
                                                {
                                                    let writer_lease = match acquire_pr_writer_lease_for_message(
                                                        &control_hub,
                                                        &mission_store,
                                                        &m,
                                                        &content,
                                                    )
                                                    .await
                                                    {
                                                        Ok(lease) => lease,
                                                        Err(error) => {
                                                            let _ = events_tx.send(AgentEvent::Error {
                                                                message: format!(
                                                                    "Cannot reserve writer lease for mission {}: {}",
                                                                    tid, error
                                                                ),
                                                                mission_id: Some(tid),
                                                                resumable: true,
                                                            });
                                                            let _ = respond.send(UserMessageAck::Rejected(error));
                                                            continue;
                                                        }
                                                    };
                                                    // Append to any previously-stashed goal so
                                                    // multiple pre-dispatch messages aren't lost.
                                                    let previous_goal = mission_store
                                                        .get_deferred_goal(tid)
                                                        .await
                                                        .ok()
                                                        .flatten();
                                                    let combined = match previous_goal.as_deref() {
                                                        // An automation that fires during a long
                                                        // wait repeats the same message every time.
                                                        Some(previous)
                                                            if usage_limit_wait::is_waiting(&m)
                                                                && usage_limit_wait::already_deferred(previous, source.as_deref(), &content) =>
                                                        {
                                                            previous.to_string()
                                                        }
                                                        _ => deferred_goal_for_incoming_message(
                                                            m.status,
                                                            previous_goal.as_deref(),
                                                            &if source.as_deref() == Some("scheduler") { content.clone() } else { deferred_messages::encode(id, &content) },
                                                        ),
                                                    };
                                                    if let Err(e) = mission_store
                                                        .set_deferred_goal(tid, Some(combined))
                                                        .await
                                                    {
                                                        rollback_message_writer_tag(
                                                            &mission_store,
                                                            &m,
                                                            &writer_lease,
                                                        )
                                                        .await;
                                                        tracing::warn!(
                                                            mission_id = %tid,
                                                            "Failed to stash deferred goal: {e}"
                                                        );
                                                        let _ = respond.send(UserMessageAck::Dropped);
                                                        continue;
                                                    }
                                                    // Surface the queued goal so the UI shows it
                                                    // as pending until dispatch.
                                                    let _ = events_tx.send(AgentEvent::UserMessage {
                                                        id,
                                                        content: content.clone(),
                                                        queued: true,
                                                        mission_id: Some(tid),
                                                        source: source.clone(),
                                                    });
                                                    tracing::info!(
                                                        mission_id = %tid,
                                                        not_before = ?m.scheduling.not_before,
                                                        "Deferred scheduled mission: goal stashed until dispatch window"
                                                    );
                                                    let _ = respond.send(UserMessageAck::Queued);
                                                    continue;
                                                }
                                            }
                                        }
                                    }
                                }

                                // Case 1: Target is already running in parallel_runners - queue to it
                                if let Some(tid) = effective_target {
                                    if target_in_parallel {
                                        if let Ok(Some(mission)) = mission_store.get_mission(tid).await {
                                            if let Err(error) = activate_mission_for_message(
                                                &control_hub,
                                                &mission_store,
                                                &events_tx,
                                                &mission,
                                                &content,
                                            )
                                            .await
                                            {
                                                let _ = events_tx.send(AgentEvent::Error {
                                                    message: format!(
                                                        "Cannot apply writer lease for mission {}: {}",
                                                        tid, error
                                                    ),
                                                    mission_id: Some(tid),
                                                    resumable: true,
                                                });
                                                let _ = respond.send(UserMessageAck::Rejected(error));
                                                continue;
                                            }
                                        }
                                        let Some(runner) = parallel_runners.get_mut(&tid) else {
                                            accepted_user_message_ids.remove(&id);
                                            let _ = respond.send(UserMessageAck::Rejected(format!(
                                                "mission {tid} runner disappeared before queueing"
                                            )));
                                            continue;
                                        };
                                        if runner.cancellation_requested() {
                                            accepted_user_message_ids.remove(&id);
                                            let _ = respond.send(UserMessageAck::Rejected(format!(
                                                "mission {tid} is stopping"
                                            )));
                                            continue;
                                        }
                                        let was_running = runner.is_running();
                                        runner.queue_message(id, content.clone(), msg_agent, source.clone());
                                        // For an idle runner, reserve its prepared slot. Queue
                                        // serialization deliberately keeps this replayable until
                                        // acquire_durable_run succeeds.
                                        if !was_running && runner.take_next_message_for_start().is_none() {
                                            accepted_user_message_ids.remove(&id);
                                            let _ = respond.send(UserMessageAck::Rejected(format!(
                                                "mission {tid} delivery disappeared before persistence"
                                            )));
                                            continue;
                                        }
                                        let _ = events_tx.send(AgentEvent::UserMessage {
                                            id,
                                            content: content.clone(),
                                            queued: was_running,
                                            mission_id: Some(tid),
                                            source: source.clone(),
                                        });
                                        // Surface the parallel queue growth to all
                                        // clients (Status events otherwise only
                                        // carry the main queue length). Only when
                                        // the message actually stays queued —
                                        // otherwise start_next pops it right away.
                                        if was_running {
                                            let _ = events_tx.send(AgentEvent::Status {
                                                state: ControlRunState::Running,
                                                queue_len: runner.queue.len(),
                                                mission_id: Some(tid),
                                            });
                                        }
                                        // Persist queued and prepared parallel deliveries before
                                        // they can be acknowledged. Prepared work remains marked
                                        // pending until its durable run lease exists.
                                        if let Err(error) = persist_control_queue_if_changed(
                                            &mission_store,
                                            &session_user_id,
                                            &queue,
                                            &parallel_runners,
                                            &recovered_consumed_user_messages,
                                            &mut last_persisted_queue,
                                        )
                                        .await
                                        {
                                            if let Some(runner) = parallel_runners.get_mut(&tid) {
                                                runner.remove_from_queue(id);
                                                runner.remove_inflight_message(id);
                                            }
                                            accepted_user_message_ids.remove(&id);
                                            let _ = respond.send(UserMessageAck::Rejected(format!(
                                                "failed to persist parallel delivery: {error}"
                                            )));
                                            continue;
                                        }
                                        if !was_running {
                                            let Some(runner) = parallel_runners.get_mut(&tid) else {
                                                accepted_user_message_ids.remove(&id);
                                                let _ = respond.send(UserMessageAck::Rejected(format!(
                                                    "mission {tid} runner disappeared before start"
                                                )));
                                                continue;
                                            };
                                            if let Err(error) = runner
                                                .acquire_durable_run(
                                                    &mission_store,
                                                    &format!("control:{session_user_id}"),
                                                )
                                                .await
                                            {
                                                let _ = events_tx.send(AgentEvent::Error {
                                                    message: format!("Mission run lease rejected: {error}"),
                                                    mission_id: Some(tid),
                                                    resumable: true,
                                                });
                                                runner.remove_from_queue(id);
                                                runner.remove_inflight_message(id);
                                                let _ = persist_control_queue_if_changed(
                                                    &mission_store,
                                                    &session_user_id,
                                                    &queue,
                                                    &parallel_runners,
                                                    &recovered_consumed_user_messages,
                                                    &mut last_persisted_queue,
                                                )
                                                .await;
                                                accepted_user_message_ids.remove(&id);
                                                let _ = respond.send(UserMessageAck::Rejected(error));
                                                continue;
                                            }
                                            if let Err(error) = persist_control_queue_if_changed(
                                                &mission_store,
                                                &session_user_id,
                                                &queue,
                                                &parallel_runners,
                                                &recovered_consumed_user_messages,
                                                &mut last_persisted_queue,
                                            )
                                            .await
                                            {
                                                if let Some(runner) = parallel_runners.get_mut(&tid) {
                                                    runner
                                                        .finish_durable_run(
                                                            &mission_store,
                                                            Some("consumed_snapshot_persist_failed"),
                                                        )
                                                        .await;
                                                    runner.remove_inflight_message(id);
                                                }
                                                accepted_user_message_ids.remove(&id);
                                                let _ = respond.send(UserMessageAck::Rejected(format!(
                                                    "failed to persist consumed parallel delivery: {error}"
                                                )));
                                                continue;
                                            }
                                            let Some(runner) = parallel_runners.get_mut(&tid) else {
                                                accepted_user_message_ids.remove(&id);
                                                let _ = respond.send(UserMessageAck::Rejected(format!(
                                                    "mission {tid} runner disappeared before start"
                                                )));
                                                continue;
                                            };
                                            runner.start_next(
                                                config.clone(),
                                                Arc::clone(&root_agent),
                                                Arc::clone(&mcp),
                                                Arc::clone(&workspaces),
                                                library.clone(),
                                                events_tx.clone(),
                                                Arc::clone(&tool_hub),
                                                Arc::clone(&status),
                                                mission_cmd_tx.clone(),
                                                Arc::new(RwLock::new(Some(tid))),
                                                secrets.clone(),
                                            );
                                        }
                                        // The durable snapshot, not process creation,
                                        // is the acceptance boundary. Report Queued even
                                        // when execution started immediately so outbox
                                        // retirement never depends on a volatile handle.
                                        let _ = respond.send(UserMessageAck::Queued);
                                        continue;
                                    }
                                }

                                // Case 2: Target differs from main → start parallel
                                // When target_mission_id is explicitly set (e.g. from Telegram),
                                // always use parallel execution to avoid hijacking the main session.
                                // When the target is merely inferred (current differs from running),
                                // only start parallel when main is busy.
                                let force_parallel = target_mission_id.is_some(); // explicit target (e.g. Telegram)
                                if let Some(tid) = effective_target {
                                    if !target_is_main && (main_is_running || force_parallel) {
                                        // Check capacity
                                        let parallel_running = parallel_runners.values().filter(|r| r.is_running()).count();
                                        let total_running = parallel_running + if main_is_running { 1 } else { 0 };
                                        let max_parallel = crate::settings::max_parallel_missions_cached_or(config.max_parallel_missions);

                                        if total_running >= max_parallel {
                                            // At capacity, dropping the message would orphan the
                                            // mission: it stays Pending with no deferred_goal, so
                                            // the FLEET-001 scheduler never dispatches it and the
                                            // HTTP response (`queued: false`) is indistinguishable
                                            // from a successful delivery. Stash the content as the
                                            // deferred goal instead — the scheduler pass re-injects
                                            // it as a normal targeted message once a slot frees.
                                            let mission = match mission_store.get_mission(tid).await {
                                                Ok(Some(mission)) => mission,
                                                Ok(None) => {
                                                    let _ = respond.send(UserMessageAck::Dropped);
                                                    continue;
                                                }
                                                Err(error) => {
                                                    let _ = events_tx.send(AgentEvent::Error {
                                                        message: format!(
                                                            "Cannot load mission {} before deferral: {}",
                                                            tid, error
                                                        ),
                                                        mission_id: Some(tid),
                                                        resumable: true,
                                                    });
                                                    let _ = respond.send(UserMessageAck::Dropped);
                                                    continue;
                                                }
                                            };
                                            let writer_lease = match acquire_pr_writer_lease_for_message(
                                                &control_hub,
                                                &mission_store,
                                                &mission,
                                                &content,
                                            )
                                            .await
                                            {
                                                Ok(lease) => lease,
                                                Err(error) => {
                                                    let _ = events_tx.send(AgentEvent::Error {
                                                        message: format!(
                                                            "Cannot reserve writer lease for mission {}: {}",
                                                            tid, error
                                                        ),
                                                        mission_id: Some(tid),
                                                        resumable: true,
                                                    });
                                                    let _ = respond.send(UserMessageAck::Rejected(error));
                                                    continue;
                                                }
                                            };
                                            let previous_goal = mission_store
                                                .get_deferred_goal(tid)
                                                .await
                                                .ok()
                                                .flatten();
                                            let combined = deferred_goal_for_incoming_message(
                                                mission.status,
                                                previous_goal.as_deref(),
                                                &if source.as_deref() == Some("scheduler") { content.clone() } else { deferred_messages::encode(id, &content) },
                                            );
                                            match mission_store.set_deferred_goal(tid, Some(combined)).await
                                            {
                                                Ok(()) => {
                                                    if follow_up_should_requeue_as_pending(mission.status) {
                                                        if let Err(error) = mission_store
                                                            .update_mission_status(
                                                                tid,
                                                                MissionStatus::Pending,
                                                            )
                                                            .await
                                                        {
                                                            tracing::warn!(
                                                                mission_id = %tid,
                                                                "At capacity: stashed follow-up but could not requeue as pending: {error}"
                                                            );
                                                        } else {
                                                            let _ = events_tx.send(
                                                                AgentEvent::MissionStatusChanged {
                                                                    completion: None,
                                                                    execution: None,
                                                                    mission_id: tid,
                                                                    status: MissionStatus::Pending,
                                                                    summary: Some(
                                                                        "Operator follow-up queued until a runner slot is free"
                                                                            .to_string(),
                                                                    ),
                                                                },
                                                            );
                                                        }
                                                    }
                                                    tracing::info!(
                                                        mission_id = %tid,
                                                        max_parallel,
                                                        "At capacity: deferring targeted message as scheduled goal"
                                                    );
                                                    let _ = events_tx.send(AgentEvent::UserMessage {
                                                        id,
                                                        content: content.clone(),
                                                        queued: true,
                                                        mission_id: Some(tid),
                                                        source: source.clone(),
                                                    });
                                                    let _ = respond.send(UserMessageAck::Queued);
                                                }
                                                Err(e) => {
                                                    rollback_message_writer_tag(
                                                        &mission_store,
                                                        &mission,
                                                        &writer_lease,
                                                    )
                                                    .await;
                                                    tracing::warn!(
                                                        mission_id = %tid,
                                                        "Cannot start parallel mission (max {} reached) and \
                                                         failed to stash deferred goal: {e}",
                                                        max_parallel
                                                    );
                                                    let _ = events_tx.send(AgentEvent::Error {
                                                        message: format!(
                                                            "Cannot start mission {}: max parallel missions ({}) reached",
                                                            tid, max_parallel
                                                        ),
                                                        mission_id: Some(tid),
                                                        resumable: true,
                                                    });
                                                    let _ = respond.send(UserMessageAck::Dropped);
                                                }
                                            }
                                            continue;
                                        } else {
                                            // Load mission and start in parallel
                                            match load_mission_record(&mission_store, tid).await {
                                                Ok(mission) => {
                                                    // A paused mission must not be auto-started by an
                                                    // incoming message — respect the pause. The user
                                                    // resumes it explicitly via the resume API.
                                                    if mission.status == MissionStatus::Paused {
                                                        let _ = events_tx.send(AgentEvent::Error {
                                                            message: format!(
                                                                "Mission {} is paused; resume it before sending messages",
                                                                tid
                                                            ),
                                                            mission_id: Some(tid),
                                                            resumable: true,
                                                        });
                                                        let _ = respond.send(UserMessageAck::Dropped);
                                                        continue;
                                                    }
                                                    if let Err(error) = activate_mission_for_message(
                                                        &control_hub,
                                                        &mission_store,
                                                        &events_tx,
                                                        &mission,
                                                        &content,
                                                    )
                                                    .await
                                                    {
                                                        let _ = events_tx.send(AgentEvent::Error {
                                                            message: format!(
                                                                "Cannot activate mission {}: {}",
                                                                tid, error
                                                            ),
                                                            mission_id: Some(tid),
                                                            resumable: true,
                                                        });
                                                        let _ = respond.send(UserMessageAck::Rejected(error));
                                                        continue;
                                                    }
                                                    let mut runner = super::super::mission_runner::MissionRunner::new(
                                                        tid,
                                                        mission.workspace_id,
                                                        mission.agent.clone(),
                                                        Some(mission.backend.clone()),
                                                        mission.session_id.clone(),
                                                        mission.config_profile.clone(),
                                                        model_for_dispatch(&mission_store, &mission).await,
                                                        mission.model_effort.clone(),
                                                        mission.fast_mode,
                                                        mission.service_tier,
                                                    );
                                                    runner.pr_readonly = mission.project.tags.iter().any(|tag| tag == "pr-readonly");
                                                    runner.working_directory = mission.working_directory.clone();
                                                    runner.user = control_hub.identities.read().await.get(&session_user_id).cloned();
                                                    // Load existing history
                                                    for entry in &mission.history {
                                                        runner.history.push((entry.role.clone(), entry.content.clone()));
                                                    }
                                                    // Queue the message
                                                    runner.queue_message(id, content.clone(), msg_agent, source.clone());
                                                    // Reserve the prepared slot before its first
                                                    // snapshot. Serialization keeps it replayable until
                                                    // a durable run exists; start_next consumes this slot.
                                                    if runner.take_next_message_for_start().is_none() {
                                                        accepted_user_message_ids.remove(&id);
                                                        let _ = respond.send(UserMessageAck::Rejected(
                                                            format!(
                                                                "mission {tid} delivery disappeared before persistence"
                                                            ),
                                                        ));
                                                        continue;
                                                    }
                                                    // Emit user message event
                                                    let _ = events_tx.send(AgentEvent::UserMessage {
                                                        id,
                                                        content: content.clone(),
                                                        queued: false,
                                                        mission_id: Some(tid),
                                                        source: source.clone(),
                                                    });
                                                    // Journal the prepared delivery as replayable pending
                                                    // before acquiring the run or starting a process.
                                                    parallel_runners.insert(tid, runner);
                                                    if let Err(error) = persist_control_queue_if_changed(
                                                        &mission_store,
                                                        &session_user_id,
                                                        &queue,
                                                        &parallel_runners,
                                                        &recovered_consumed_user_messages,
                                                        &mut last_persisted_queue,
                                                    )
                                                    .await
                                                    {
                                                        parallel_runners.remove(&tid);
                                                        accepted_user_message_ids.remove(&id);
                                                        let _ = respond.send(UserMessageAck::Rejected(
                                                            format!(
                                                                "failed to persist parallel delivery: {error}"
                                                            ),
                                                        ));
                                                        continue;
                                                    }
                                                    let runner = parallel_runners
                                                        .get_mut(&tid)
                                                        .expect("parallel runner inserted above");
                                                    if let Err(error) = runner
                                                        .acquire_durable_run(
                                                            &mission_store,
                                                            &format!("control:{session_user_id}"),
                                                        )
                                                        .await
                                                    {
                                                        let _ = events_tx.send(AgentEvent::Error {
                                                            message: format!("Mission run lease rejected: {error}"),
                                                            mission_id: Some(tid),
                                                            resumable: true,
                                                        });
                                                        parallel_runners.remove(&tid);
                                                        let _ = persist_control_queue_if_changed(
                                                            &mission_store,
                                                            &session_user_id,
                                                            &queue,
                                                            &parallel_runners,
                                                            &recovered_consumed_user_messages,
                                                            &mut last_persisted_queue,
                                                        )
                                                        .await;
                                                        accepted_user_message_ids.remove(&id);
                                                        let _ = respond.send(UserMessageAck::Rejected(error));
                                                        continue;
                                                    }
                                                    if let Err(error) = persist_control_queue_if_changed(
                                                        &mission_store,
                                                        &session_user_id,
                                                        &queue,
                                                        &parallel_runners,
                                                        &recovered_consumed_user_messages,
                                                        &mut last_persisted_queue,
                                                    )
                                                    .await
                                                    {
                                                        if let Some(runner) = parallel_runners.get_mut(&tid) {
                                                            runner
                                                                .finish_durable_run(
                                                                    &mission_store,
                                                                    Some("consumed_snapshot_persist_failed"),
                                                                )
                                                                .await;
                                                        }
                                                        parallel_runners.remove(&tid);
                                                        accepted_user_message_ids.remove(&id);
                                                        let _ = respond.send(UserMessageAck::Rejected(
                                                            format!(
                                                                "failed to persist consumed parallel delivery: {error}"
                                                            ),
                                                        ));
                                                        continue;
                                                    }
                                                    let runner = parallel_runners
                                                        .get_mut(&tid)
                                                        .expect("parallel runner persisted above");
                                                    runner.start_next(
                                                        config.clone(),
                                                        Arc::clone(&root_agent),
                                                        Arc::clone(&mcp),
                                                        Arc::clone(&workspaces),
                                                        library.clone(),
                                                        events_tx.clone(),
                                                        Arc::clone(&tool_hub),
                                                        Arc::clone(&status),
                                                        mission_cmd_tx.clone(),
                                                        Arc::new(RwLock::new(Some(tid))),
                                                        secrets.clone(),
                                                    );
                                                    tracing::info!("Auto-started mission {} in parallel", tid);
                                                    let _ = respond.send(UserMessageAck::Queued);
                                                    continue;
                                                }
                                                Err(e) => {
                                                    tracing::error!(
                                                        "Failed to load mission {} for parallel: {}. \
                                                         Dropping targeted message to avoid sending to wrong mission.",
                                                        tid, e
                                                    );
                                                    let _ = events_tx.send(AgentEvent::Error {
                                                        message: format!(
                                                            "Failed to load mission {}: {}",
                                                            tid, e
                                                        ),
                                                        mission_id: Some(tid),
                                                        resumable: true,
                                                    });
                                                    let _ = respond.send(UserMessageAck::Dropped);
                                                    continue;
                                                }
                                            }
                                        }
                                    }
                                }

                                // Strict (control-plane) messages must never leak into an
                                // *unrelated* mission. If the target is some OTHER mission
                                // than the main session's and we got here, Case 1/2 (queue
                                // to / start a parallel runner) didn't fire — drop rather
                                // than fall through to the main session, which would land a
                                // board wake / bg-autoresume / worker dispatch in the wrong
                                // mission. The scheduler re-issues on its next pass.
                                //
                                // When the target IS the main session's mission, there is
                                // no leak: Case 3 below is exactly where we want it — it
                                // activates an idle/AwaitingUser main mission and starts a
                                // fresh turn (e.g. the bg-task auto-resume waking a mission
                                // that parked on the user while a background job ran).
                                if strict && !target_is_main {
                                    tracing::warn!(
                                        target = ?effective_target,
                                        "Dropping strict control-plane message: non-main target not deliverable this pass"
                                    );
                                    let _ = respond.send(UserMessageAck::Dropped);
                                    continue;
                                }

                                // Case 3: Queue to main session (default behavior)
                                // Auto-create mission on first message if none exists
                                {
                                    let mission_id = *current_mission.read().await;
                                    if mission_id.is_none() {
                                        // Use effective_target if available, otherwise create new
                                        if let Some(tid) = effective_target {
                                            // Load mission history from DB so continuation detection
                                            // works correctly (e.g., after server restart when
                                            // current_mission is None but the mission has prior turns).
                                            if let Ok(mission) = load_mission_record(&mission_store, tid).await {
                                                if !mission.history.is_empty() {
                                                    history.clear();
                                                    for entry in &mission.history {
                                                        history.push((entry.role.clone(), entry.content.clone()));
                                                    }
                                                    tracing::info!(
                                                        "Loaded {} history entries for target mission {} (first message after session start)",
                                                        mission.history.len(), tid
                                                    );
                                                }
                                                if let Err(error) = activate_mission_for_message(
                                                    &control_hub,
                                                    &mission_store,
                                                    &events_tx,
                                                    &mission,
                                                    &content,
                                                )
                                                .await
                                                {
                                                    let _ = events_tx.send(AgentEvent::Error {
                                                        message: format!(
                                                            "Cannot activate mission {}: {}",
                                                            tid, error
                                                        ),
                                                        mission_id: Some(tid),
                                                        resumable: true,
                                                    });
                                                    let _ = respond.send(UserMessageAck::Rejected(error));
                                                    continue;
                                                }
                                            }
                                            *current_mission.write().await = Some(tid);
                                            tracing::info!("Set current mission to target: {}", tid);
                                        } else if let Ok(new_mission) = create_new_mission(&mission_store).await {
                                            *current_mission.write().await = Some(new_mission.id);
                                            tracing::info!("Auto-created mission: {}", new_mission.id);
                                        }
                                    } else if let Some(tid) = effective_target {
                                        if !main_is_running {
                                            if mission_id != Some(tid) {
                                                // Switch main session to target mission
                                                persist_mission_history(
                                                    &mission_store,
                                                    &events_tx,
                                                    &current_mission,
                                                    &history,
                                                )
                                                .await;
                                                if let Ok(mission) = load_mission_record(&mission_store, tid).await {
                                                    history.clear();
                                                    for entry in &mission.history {
                                                        history.push((entry.role.clone(), entry.content.clone()));
                                                    }
                                                    if let Err(error) = activate_mission_for_message(
                                                        &control_hub,
                                                        &mission_store,
                                                        &events_tx,
                                                        &mission,
                                                        &content,
                                                    )
                                                    .await
                                                    {
                                                        let _ = events_tx.send(AgentEvent::Error {
                                                            message: format!(
                                                                "Cannot activate mission {}: {}",
                                                                tid, error
                                                            ),
                                                            mission_id: Some(tid),
                                                            resumable: true,
                                                        });
                                                        let _ = respond.send(UserMessageAck::Rejected(error));
                                                        continue;
                                                    }
                                                }
                                                *current_mission.write().await = Some(tid);
                                                tracing::info!("Switched main session to mission: {}", tid);
                                            } else if !history.iter().any(|(role, _)| role == "assistant") {
                                                // Same mission but no assistant history in memory
                                                // (e.g., after server restart). Reload from database
                                                // so Claude Code continuation detection works correctly.
                                                if let Ok(mission) = load_mission_record(&mission_store, tid).await {
                                                    if !mission.history.is_empty() {
                                                        history.clear();
                                                        for entry in &mission.history {
                                                            history.push((entry.role.clone(), entry.content.clone()));
                                                        }
                                                        tracing::info!(
                                                            "Reloaded {} history entries for mission {} (session continuity)",
                                                            mission.history.len(), tid
                                                        );
                                                    }
                                                    if let Err(error) = activate_mission_for_message(
                                                        &control_hub,
                                                        &mission_store,
                                                        &events_tx,
                                                        &mission,
                                                        &content,
                                                    )
                                                    .await
                                                    {
                                                        let _ = events_tx.send(AgentEvent::Error {
                                                            message: format!(
                                                                "Cannot activate mission {}: {}",
                                                                tid, error
                                                            ),
                                                            mission_id: Some(tid),
                                                            resumable: true,
                                                        });
                                                        let _ = respond.send(UserMessageAck::Rejected(error));
                                                        continue;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                let was_running = running.is_some();
                                let content_clone = content.clone();
                                // Capture the target mission ID once, before queuing.
                                // This ensures we use the same mission_id for events and execution.
                                //
                                // Honor the message's EXPLICIT target; fall back to the session
                                // `current_mission` pointer only for untargeted messages. We only
                                // reach Case 3 when the target is absent or equals the main mission
                                // (`target_is_main`), so an explicit `effective_target` here is the
                                // main mission the runner is on — and its history is already what
                                // the next turn will use. Previously this read `*current_mission`
                                // unconditionally: when the runner was busy on one mission
                                // (`running_mission_id`) while the session pointer had drifted to
                                // another (e.g. the dashboard/MCP moved it), an explicitly-targeted
                                // follow-up got silently re-pinned to the drifted mission and
                                // executed there. (Prod 2026-06-23: a Hermes follow-up for mission
                                // 91f7… ran in the unrelated 4f3f… instead.)
                                let target_mission_id = match effective_target {
                                    Some(tid) => Some(tid),
                                    None => *current_mission.read().await,
                                };
                                if was_running {
                                    if let Some(tid) = target_mission_id {
                                        if let Ok(Some(mission)) = mission_store.get_mission(tid).await {
                                            if let Err(error) = activate_mission_for_message(
                                                &control_hub,
                                                &mission_store,
                                                &events_tx,
                                                &mission,
                                                &content,
                                            )
                                            .await
                                            {
                                                let _ = events_tx.send(AgentEvent::Error {
                                                    message: format!(
                                                        "Cannot apply writer lease for mission {}: {}",
                                                        tid, error
                                                    ),
                                                    mission_id: Some(tid),
                                                    resumable: true,
                                                });
                                                let _ = respond.send(UserMessageAck::Rejected(error));
                                                continue;
                                            }
                                        }
                                    }
                                }
                                enqueue_control_message(
                                    &mut queue,
                                    (id, content, msg_agent, target_mission_id, source.clone()),
                                );
                                // `Queued` is an acceptance acknowledgement. Persist the
                                // message before sending it so a crash cannot lose an
                                // outbox delivery that its producer has already retired.
                                if let Err(error) = persist_control_queue_if_changed(
                                    &mission_store,
                                    &session_user_id,
                                    &queue,
                                    &parallel_runners,
                                    &recovered_consumed_user_messages,
                                    &mut last_persisted_queue,
                                )
                                .await
                                {
                                    queue.retain(|(queued_id, ..)| *queued_id != id);
                                    accepted_user_message_ids.remove(&id);
                                    let _ = respond.send(UserMessageAck::Rejected(format!(
                                        "failed to persist queued delivery: {error}"
                                    )));
                                    continue;
                                }
                                let status_mission_id = if running.is_some() {
                                    running_mission_id
                                } else {
                                    target_mission_id
                                };
                                set_and_emit_status(
                                    &status,
                                    &events_tx,
                                    if running.is_some() { ControlRunState::Running } else { ControlRunState::Idle },
                                    queue.len(),
                                    status_mission_id,
                                ).await;
                                if was_running {
                                    let _ = events_tx.send(AgentEvent::UserMessage {
                                        id,
                                        content: content_clone,
                                        queued: true,
                                        mission_id: target_mission_id,
                                        source: source.clone(),
                                    });
                                }
                                if running.is_none() {
                                    if let Some((mid, msg, per_msg_agent, msg_target_mid, msg_source)) = pop_next_runnable_control_queue(&mut queue, &mission_store).await {
                                        // Persist the dequeue before the awaits that start
                                        // the run, so a crash here can't restore + re-run it.
                                        if let Err(error) = persist_control_queue_if_changed(
                                            &mission_store,
                                            &session_user_id,
                                            &queue,
                                            &parallel_runners,
                                            &recovered_consumed_user_messages,
                                            &mut last_persisted_queue,
                                        )
                                        .await
                                        {
                                            queue.push_front((
                                                mid,
                                                msg,
                                                per_msg_agent,
                                                msg_target_mid,
                                                msg_source,
                                            ));
                                            let _ = respond.send(UserMessageAck::Queued);
                                            tracing::warn!(
                                                "Queued delivery retained because dequeue persistence failed: {error}"
                                            );
                                            continue;
                                        }
                                        set_and_emit_status(
                                            &status,
                                            &events_tx,
                                            ControlRunState::Running,
                                            queue.len(),
                                            msg_target_mid,
                                        ).await;
                                        let _ = events_tx.send(AgentEvent::UserMessage { id: mid, content: msg.clone(), queued: false, mission_id: msg_target_mid, source: msg_source.clone() });

                                        // Immediately persist user message so it's visible when loading mission
                                        history.push(("user".to_string(), msg.clone()));
                                        persist_mission_history_to(
                                            &mission_store,
                                            &events_tx,
                                            msg_target_mid,
                                            &history,
                                        )
                                            .await;

                                        let cfg = config.clone();
                                        let agent = Arc::clone(&root_agent);
                                        let mcp_ref = Arc::clone(&mcp);
                                        let workspaces_ref = Arc::clone(&workspaces);
                                        let library_ref = Arc::clone(&library);
                                        let events = events_tx.clone();
                                        let tools_hub = Arc::clone(&tool_hub);
                                        let status_ref = Arc::clone(&status);
                                        let cancel = CancellationToken::new();
                                        let hist_snapshot = history.clone();
                                        let mission_ctrl = crate::tools::mission::MissionControl {
                                            current_mission_id: Arc::clone(&current_mission),
                                            cmd_tx: mission_cmd_tx.clone(),
                                        };
                                        let tree_ref = Arc::clone(&current_tree);
                                        let progress_ref = Arc::clone(&progress);
                                        // Use the mission ID that was captured when message was queued
                                        // This prevents race conditions where current_mission changes between queueing and execution
                                        let mission_id = msg_target_mid;
                                        let (workspace_id, model_override, model_effort, fast_mode, service_tier, mission_agent, backend_id, session_id, mission_config_profile, pr_readonly) = if let Some(mid) = mission_id {
                                            match mission_store.get_mission(mid).await {
                                                Ok(Some(mission)) => {
                                                    if let Err(error) = activate_mission_for_message(
                                                        &control_hub,
                                                        &mission_store,
                                                        &events_tx,
                                                        &mission,
                                                        &msg,
                                                    )
                                                    .await
                                                    {
                                                        let _ = events_tx.send(AgentEvent::Error {
                                                            message: format!(
                                                                "Cannot activate mission {}: {}",
                                                                mid, error
                                                            ),
                                                            mission_id: Some(mid),
                                                            resumable: true,
                                                        });
                                                        let _ = respond.send(UserMessageAck::Rejected(error));
                                                        continue;
                                                    }
                                                    (
                                                        Some(mission.workspace_id),
                                                        model_for_dispatch(&mission_store, &mission).await,
                                                        mission.model_effort.clone(),
                                                        mission.fast_mode,
                                                        mission.service_tier,
                                                        mission.agent.clone(),
                                                        Some(mission.backend.clone()),
                                                        mission.session_id.clone(),
                                                        mission.config_profile.clone(),
                                                        mission.project.tags.iter().any(|tag| tag == "pr-readonly"),
                                                    )
                                                }
                                                Ok(None) => {
                                                    tracing::warn!(
                                                        "Mission {} not found while resolving workspace",
                                                        mid
                                                    );
                                                    (None, None, None, false, None, None, None, None, None, false)
                                                }
                                                Err(e) => {
                                                    tracing::warn!(
                                                        "Failed to load mission {} for workspace: {}",
                                                        mid,
                                                        e
                                                    );
                                                    (None, None, None, false, None, None, None, None, None, false)
                                                }
                                            }
                                        } else {
                                            (None, None, None, false, None, None, None, None, None, false)
                                        };
                                        // Per-message agent overrides mission agent
                                        let agent_override = per_msg_agent.or(mission_agent);
                                        running_cancel = Some(cancel.clone());
                                        running_mission_id = mission_id;
                                        running_backend_id = backend_id.clone();
                                        // Reset activity tracking when new task starts
                                        main_runner_last_activity = std::time::Instant::now();
                                        main_runner_activity = None;
                                        main_runner_subtasks.clear();
                                        main_runner_active_tool_calls
                                            .store(0, std::sync::atomic::Ordering::Relaxed);
                                        let user_id_for_turn = control_hub.identities.read().await.get(&session_user_id).cloned();
                                        running_run = match acquire_execution_run(
                                            &mission_store,
                                            mission_id,
                                            &format!("control:{session_user_id}"),
                                        )
                                        .await
                                        {
                                            Ok(run) => run,
                                            Err(error) => {
                                                running_cancel = None;
                                                running_mission_id = None;
                                                running_backend_id = None;
                                                // The queue dequeue was already persisted, but no
                                                // run owns this delivery. Roll back the just-appended
                                                // history entry and release the deterministic message
                                                // id so the caller/outbox can retry it safely.
                                                if history.last().is_some_and(|entry| {
                                                    entry.0 == "user" && entry.1 == msg
                                                }) {
                                                    history.pop();
                                                    persist_mission_history_to(
                                                        &mission_store,
                                                        &events_tx,
                                                        msg_target_mid,
                                                        &history,
                                                    )
                                                    .await;
                                                }
                                                accepted_user_message_ids.remove(&mid);
                                                set_and_emit_status(
                                                    &status,
                                                    &events_tx,
                                                    ControlRunState::Idle,
                                                    queue.len(),
                                                    msg_target_mid,
                                                )
                                                .await;
                                                let _ = respond.send(UserMessageAck::Rejected(error.clone()));
                                                let _ = events_tx.send(AgentEvent::Error {
                                                    message: format!("Mission run lease rejected: {error}"),
                                                    mission_id,
                                                    resumable: true,
                                                });
                                                continue;
                                            }
                                        };
                                        let turn_mission_store = mission_store.clone();
                                        let session_update_run = running_run.as_ref().map(crate::api::mission_store::SessionUpdateRun::from);
                                        running_message_id = Some(mid);
                                        running_execution_ids = deferred_messages::execution_ids(mid, &msg, msg_source.as_deref());
                                        running = Some(tokio::spawn(async move {
                                            let result = crate::api::runners::SESSION_UPDATE_RUN.scope(session_update_run, run_single_control_turn(
                                                turn_mission_store,
                                                cfg,
                                                agent,
                                                mcp_ref,
                                                workspaces_ref,
                                                library_ref,
                                                events,
                                                tools_hub,
                                                status_ref,
                                                cancel,
                                                hist_snapshot,
                                                if msg_source.as_deref() == Some("scheduler") { deferred_messages::strip(&msg) } else { msg.clone() },
                                                Some(mission_ctrl),
                                                tree_ref,
                                                progress_ref,
                                                mission_id,
                                                workspace_id,
                                                backend_id,
                                                model_override,
                                                model_effort,
                                                fast_mode,
                                                service_tier,
                                                agent_override,
                                                session_id,
                                                false, // force_session_resume: regular message, not a resume
                                                mission_config_profile,
                                                user_id_for_turn,
                                                pr_readonly,
                                            ))
                                            .await;
                                            (mid, msg, result)
                                        }));
                                    } else {
                                        set_and_emit_status(&status, &events_tx, ControlRunState::Idle, 0, None).await;
                                    }
                                }
                                let _ = respond.send(if was_running { UserMessageAck::Queued } else { UserMessageAck::Delivered });
                            }
                            ControlCommand::ReleaseUserMessageId { id } => {
                                accepted_user_message_ids.remove(&id);
                            }
                            ControlCommand::ToolResult { tool_call_id, name, result, respond } => {
                                // Deliver to the tool hub. resolve() caches the result if
                                // no one has registered yet (resolve-before-register), and
                                // reports whether a live waiter actually received it. It
                                // may wait out a short grace window for an imminent
                                // registration, so run it off the control loop to keep
                                // command processing responsive.
                                let hub = Arc::clone(&tool_hub);
                                tokio::spawn(async move {
                                    let delivered = hub.resolve(&tool_call_id, result).await;
                                    let _ = respond.send(delivered);
                                    tracing::debug!(tool_call_id = %tool_call_id, name = %name, delivered, "ToolResult delivered to hub");
                                });
                            }
                            ControlCommand::Cancel => {
                                if let Some(token) = &running_cancel {
                                    token.cancel();
                                    if let Some(run) = running_run.as_ref() {
                                        let _ = mission_store
                                            .heartbeat_mission_run(
                                                run.run_id,
                                                run.generation,
                                                MissionExecutionState::Stopping,
                                                None,
                                            )
                                            .await;
                                    }
                                    // Don't send Error event here - the task will complete and send
                                    // an AssistantMessage with the cancellation result when it finishes.
                                    // Sending both causes duplicate UI messages.
                                } else {
                                    let _ = events_tx.send(AgentEvent::Error { message: "No running task to cancel".to_string(), mission_id: None, resumable: false });
                                }
                            }
                            ControlCommand::LoadMission { id, respond } => {
                                // First persist current mission history
                                persist_mission_history(
                                    &mission_store,
                                    &events_tx,
                                    &current_mission,
                                    &history,
                                )
                                .await;

                                // Load the new mission
                                match load_mission_record(
                                    &mission_store,
                                    id,
                                )
                                .await {
                                    Ok(mission) => {
                                        // Update history from loaded mission
                                        history = mission.history.iter()
                                            .map(|e| (e.role.clone(), e.content.clone()))
                                            .collect();
                                        *current_mission.write().await = Some(id);

                                        // Write runtime workspace state so file uploads work immediately
                                        // (without needing to send a message first)
                                        let ws = workspace::resolve_workspace(
                                            &workspaces,
                                            &config,
                                            Some(mission.workspace_id),
                                        ).await;
                                        if let Err(e) = workspace::write_runtime_workspace_state(
                                            &config.working_dir,
                                            &ws,
                                            &ws.path,
                                            Some(id),
                                            &config.context.context_dir_name,
                                        ).await {
                                            tracing::warn!("Failed to write runtime workspace state on load: {}", e);
                                        }

                                        let _ = respond.send(Ok(mission));
                                    }
                                    Err(e) => {
                                        let _ = respond.send(Err(e));
                                    }
                                }
                            }
                            ControlCommand::CreateMission { title, workspace_id, agent, model_override, model_effort, fast_mode, service_tier, backend, config_profile, parent_mission_id, working_directory, scheduling, requires_local_disk, estimated_disk_gib, admission_tags, respond } => {
                                // Resolve once for both admission and the durable lease record.
                                // Keeping this value outside the conditional is important: the
                                // lease must name the exact workspace that was admitted, rather
                                // than reconstructing a possibly different default later.
                                let workspace = workspaces
                                    .get(workspace_id.unwrap_or(workspace::DEFAULT_WORKSPACE_ID))
                                    .await
                                    .unwrap_or_else(|| workspace::Workspace::default_host(config.working_dir.clone()));
                                // Disk preflight: refuse new missions when the root
                                // filesystem is critically full instead of letting
                                // workers die mid-flight on ENOSPC. Actor-level so
                                // the HTTP, Ask and Telegram entrypoints are all
                                // covered by this single gate.
                                let mut reservation_guard = None;
                                let mut reservation = None;
                                if requires_local_disk {
                                    match reserve_local_mission_disk(
                                        &control_hub,
                                        &config,
                                        &workspace,
                                        estimated_disk_gib.unwrap_or_else(mission_disk_default_estimate_gib),
                                    ).await {
                                        Ok((guard, candidate)) => {
                                            reservation_guard = Some(guard);
                                            reservation = Some(candidate);
                                        }
                                        Err(error) => {
                                            let _ = respond.send(Err(error));
                                            continue;
                                        }
                                    }
                                }
                                // First persist current mission history
                                persist_mission_history(
                                    &mission_store,
                                    &events_tx,
                                    &current_mission,
                                    &history,
                                )
                                .await;

                                // Publish the lease before the mission row so a crash
                                // cannot reconstruct a custom estimate as the default.
                                let assigned_id = Uuid::new_v4();
                                if reservation_guard.is_none() {
                                    match acquire_durable_disk_admission_lock(&config).await {
                                        Ok(guard) => reservation_guard = Some(guard),
                                        Err(error) => {
                                            let _ = respond.send(Err(format!(
                                                "mission creation rolled back: acquire placement ledger lock: {error}"
                                            )));
                                            continue;
                                        }
                                    }
                                }
                                let mut ledger = match read_disk_reservation_ledger(&config) {
                                    Ok(ledger) => ledger,
                                    Err(error) => {
                                        let _ = respond.send(Err(format!(
                                            "mission creation rolled back: read disk admission ledger: {error}"
                                        )));
                                        continue;
                                    }
                                };
                                if let Some(mut candidate) = reservation.take() {
                                    candidate.mission_id = assigned_id;
                                    candidate.workspace_dir = Some(
                                        workspace::mission_workspace_dir_for_workspace(&workspace, assigned_id),
                                    );
                                    ledger.reservations.insert(assigned_id, candidate);
                                    if let Err(error) = write_disk_reservation_ledger(&config, &ledger) {
                                        let _ = respond.send(Err(format!(
                                            "mission creation rolled back: persist disk placement ledger: {error}"
                                        )));
                                        continue;
                                    }
                                }

                                // Create a new mission with optional title, workspace, agent, and backend
                                match create_new_mission_with_title_and_placement(
                                    &mission_store,
                                    title.as_deref(),
                                    workspace_id,
                                    agent.as_deref(),
                                    model_override.as_deref(),
                                    model_effort.as_deref(),
                                    fast_mode,
                                    backend.as_deref(),
                                    config_profile.as_deref(),
                                    parent_mission_id,
                                    working_directory.as_deref(),
                                    requires_local_disk,
                                    scheduling,
                                    Some(assigned_id),
                                )
                                .await {
                                    Ok(mut mission) => {
                                        if let Some(tier)=service_tier {
                                            match mission_store.update_mission_run_settings(mission.id,None,None,None,None,None,Some(tier),None,mission.session_id.as_deref().unwrap_or("")).await {
                                                Ok(updated)=>mission=updated,Err(error)=>{let _=respond.send(Err(error));continue;}
                                            }
                                        }

                                        // Project tags are user-editable and are not admission
                                        // state.  Persist any ordinary tags independently.
                                        let tags = admission_tags;
                                        if !tags.is_empty() {
                                            if let Err(error) = mission_store.update_mission_project(
                                                mission.id,
                                                crate::api::mission_store::MissionProjectPatch {
                                                    tags: Some(tags),
                                                    ..Default::default()
                                                },
                                            ).await {
                                                let _ = mission_store.update_mission_status(
                                                    mission.id,
                                                    MissionStatus::Failed,
                                                ).await;
                                                let _ = respond.send(Err(format!(
                                                    "mission creation rolled back: persist mission project metadata: {error}"
                                                )));
                                                continue;
                                            }
                                            match mission_store.get_mission(mission.id).await {
                                                Ok(Some(updated)) => mission = updated,
                                                Ok(None) => {
                                                    let _ = respond.send(Err("mission creation rolled back: mission disappeared while persisting disk admission reservation".to_string()));
                                                    continue;
                                                }
                                                Err(error) => {
                                                    let _ = respond.send(Err(format!("mission creation rolled back: reload mission metadata: {error}")));
                                                    continue;
                                                }
                                            }
                                        }
                                        // Explicitly drop after durable write, rather than relying on
                                        // scope order if this branch grows a later await.
                                        drop(reservation_guard.take());
                                        history.clear();
                                        *current_mission.write().await = Some(mission.id);

                                        // Write runtime workspace state so file uploads work immediately
                                        let ws = workspace::resolve_workspace(
                                            &workspaces,
                                            &config,
                                            Some(mission.workspace_id),
                                        ).await;
                                        if let Err(e) = workspace::write_runtime_workspace_state(
                                            &config.working_dir,
                                            &ws,
                                            &ws.path,
                                            Some(mission.id),
                                            &config.context.context_dir_name,
                                        ).await {
                                            tracing::warn!("Failed to write runtime workspace state on create: {}", e);
                                        }

                                        let _ = respond.send(Ok(mission));
                                    }
                                    Err(e) => {
                                        let _ = respond.send(Err(e));
                                    }
                                }
                            }
                            ControlCommand::SetMissionStatus { id, status: new_status, respond } => {
                                // A completion callback can race the 10s background-task
                                // reconciler. Controllers often acknowledge immediately;
                                // without this guard they can archive the mission before
                                // AwaitingUser is promoted to WaitingBackground, then a
                                // follow-up starts a second harness in the same scope and
                                // kills the still-running build tree. Fail closed while
                                // the in-memory registry has any live task for this mission.
                                let background_task_count = background_tasks
                                    .read()
                                    .await
                                    .get(&id)
                                    .map_or(0, std::collections::HashMap::len);
                                if background_tasks_block_ack(new_status, background_task_count) {
                                    let _ = respond.send(Err(format!(
                                        "mission {id} cannot be acknowledged while background tasks are live"
                                    )));
                                    continue;
                                }
                                let current_id = *current_mission.read().await;
                                if current_id == Some(id) {
                                    if let Some(tree) = current_tree.read().await.clone() {
                                        if let Err(e) = mission_store.update_mission_tree(id, &tree).await
                                        {
                                            tracing::warn!("Failed to save mission tree: {}", e);
                                        }
                                    }
                                }

                                let result = mission_store
                                    .update_mission_status(id, new_status)
                                    .await;
                                if result.is_ok() {
                                    let runner_active = running_mission_id == Some(id)
                                        || parallel_runners
                                            .get(&id)
                                            .is_some_and(|runner| runner.is_running());
                                    if !mission_holds_disk_reservation(new_status) && !runner_active {
                                        if let Err(error) = release_local_mission_disk(&config, id).await {
                                            tracing::error!(mission = %id, %error,
                                                "terminal mission lease cleanup failed; retaining conservative admission state");
                                        }
                                    }
                                    maybe_schedule_mission_metadata_refresh_for_status(
                                        &mission_store,
                                        &events_tx,
                                        id,
                                        new_status,
                                    );
                                    let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                                        completion: None,
                                        execution: None,
                                        mission_id: id,
                                        status: new_status,
                                        summary: None,
                                    });
                                    // Broadcast delivery is best-effort. Also schedule
                                    // the same guarded cleanup directly so an
                                    // acknowledged mission cannot leave a forked
                                    // dbus/MCP child pinning its transient scope.
                                    super::super::scope_reaper::schedule_mission_scope_teardown(
                                        Arc::clone(&mission_store),
                                        id,
                                        new_status,
                                    );
                                    if new_status == MissionStatus::Acknowledged {
                                        if let Ok(child_ids) =
                                            collect_child_mission_ids(&mission_store, id).await
                                        {
                                            for child_id in child_ids {
                                                let child_bg = background_tasks
                                                    .read()
                                                    .await
                                                    .get(&child_id)
                                                    .map_or(0, std::collections::HashMap::len);
                                                let child_runner_active = running_mission_id
                                                    == Some(child_id)
                                                    || parallel_runners
                                                        .get(&child_id)
                                                        .is_some_and(|runner| runner.is_running());
                                                if child_bg > 0 || child_runner_active {
                                                    continue;
                                                }
                                                let Ok(Some(child)) =
                                                    mission_store.get_mission(child_id).await
                                                else {
                                                    continue;
                                                };
                                                if matches!(
                                                    child.status,
                                                    MissionStatus::Active
                                                        | MissionStatus::Pending
                                                        | MissionStatus::WaitingBackground
                                                        | MissionStatus::Acknowledged
                                                ) {
                                                    continue;
                                                }
                                                if mission_store
                                                    .update_mission_status(
                                                        child_id,
                                                        MissionStatus::Acknowledged,
                                                    )
                                                    .await
                                                    .is_ok()
                                                {
                                                    if let Err(error) =
                                                        release_local_mission_disk(&config, child_id).await
                                                    {
                                                        tracing::error!(mission = %child_id, %error,
                                                            "terminal mission lease cleanup failed; retaining conservative admission state");
                                                    }
                                                    maybe_schedule_mission_metadata_refresh_for_status(
                                                        &mission_store,
                                                        &events_tx,
                                                        child_id,
                                                        MissionStatus::Acknowledged,
                                                    );
                                                    let _ = events_tx.send(
                                                        AgentEvent::MissionStatusChanged {
                                                            completion: None,
                                                            execution: None,
                                                            mission_id: child_id,
                                                            status: MissionStatus::Acknowledged,
                                                            summary: None,
                                                        },
                                                    );
                                                    super::super::scope_reaper::schedule_mission_scope_teardown(
                                                        Arc::clone(&mission_store),
                                                        child_id,
                                                        MissionStatus::Acknowledged,
                                                    );
                                                }
                                            }
                                        }
                                    }
                                }
                                let _ = respond.send(result);
                            }
                            ControlCommand::SetMissionTitle { id, title, respond } => {
                                let result = async {
                                    let _file_guard = dispatch_admission::durable_lock(&config).await?;
                                    if let Some(state) = control_hub.admission_state.get().and_then(std::sync::Weak::upgrade) {
                                        dispatch_admission::recover_dispatch(&state, &mission_store, id).await?;
                                    }
                                    mission_store.update_mission_title(id, &title).await
                                }.await;
                                if result.is_ok() {
                                    let _ = events_tx.send(AgentEvent::MissionTitleChanged {
                                        mission_id: id,
                                        title: title.clone(),
                                    });
                                    match mission_store.get_mission(id).await {
                                        Ok(Some(updated)) => {
                                            record_metadata_refresh_baseline_from_mission(id, &updated);
                                            emit_mission_metadata_updated_event(&events_tx, id, &updated);
                                        }
                                        Ok(None) => {
                                            tracing::warn!(
                                                "Mission {} disappeared after title update",
                                                id
                                            );
                                        }
                                        Err(err) => {
                                            tracing::warn!(
                                                "Failed to reload mission {} after title update: {}",
                                                id,
                                                err
                                            );
                                        }
                                    }
                                }
                                let _ = respond.send(result);
                            }
                            ControlCommand::UpdateMissionSettings { id, backend, agent, model_override, model_effort, fast_mode, service_tier, config_profile, session_id, respond } => {
                                let main_running = running.is_some() && running_mission_id == Some(id);
                                let parallel_running = parallel_runners
                                    .get(&id)
                                    .is_some_and(|runner| runner.is_running());
                                // Run-settings (backend/model/agent/profile) are read
                                // per turn, so changing them on a RUNNING mission is
                                // safe: the in-flight turn keeps what it loaded and the
                                // next turn picks up the new row (with the backend
                                // handoff context below when the backend changed).
                                // Long-lived missions (orchestrators, /goal loops)
                                // rarely stop, so the previous hard refusal made them
                                // effectively unswitchable. Session identities are
                                // retained per backend; failed native resume requires
                                // recovery rather than silently creating a new session.
                                if main_running || parallel_running {
                                    tracing::info!(
                                        mission_id = %id,
                                        "Updating run settings while mission is running; they apply from the next turn"
                                    );
                                }

                                // Capture the backend before the update so we can detect
                                // a switch and carry reasoning across (see below).
                                let before = match load_mission_record(&mission_store, id).await {
                                    Ok(mission) => mission,
                                    Err(error) => { let _ = respond.send(Err(error)); continue; }
                                };
                                // The actor holds DISPATCH_ADMISSION, also used by cyber
                                // updates and client-run admission. Validate the pair
                                // against the current saved selection before writing.
                                let next_backend = backend.as_deref().unwrap_or(&before.backend);
                                if next_backend == "codex" {
                                    let next_model = match &model_override {
                                        Some(value) => value.as_deref(),
                                        None => before.model_override.as_deref(),
                                    };
                                    let validation = async {
                                        let selection = cyber::read(&config.working_dir, id)?;
                                        cyber::program_for_model(selection.mode, next_model)?;
                                        if !client_placement::is_tagged(&before.project.tags)
                                            && remote_grok::placement(&config.working_dir, &mission_store, id).await?.is_some()
                                        {
                                            let state = control_hub.admission_state.get()
                                                .and_then(std::sync::Weak::upgrade)
                                                .ok_or("Admission state unavailable")?;
                                            cyber::validate_remote(&state, selection.mode, next_model).await?;
                                        }
                                        Ok::<(), String>(())
                                    }.await.map_err(|error| format!("invalid_access_program: {error}"));
                                    if let Err(error) = validation { let _ = respond.send(Err(error)); continue; }
                                }
                                let old_backend = Some(before.backend);

                                let result = mission_store
                                    .update_mission_run_settings(
                                        id,
                                        backend.as_deref(),
                                        agent.as_ref().map(|value| value.as_deref()),
                                        model_override.as_ref().map(|value| value.as_deref()),
                                        model_effort.as_ref().map(|value| value.as_deref()),
                                        fast_mode,
                                        service_tier,
                                        config_profile.as_ref().map(|value| value.as_deref()),
                                        &session_id,
                                    )
                                    .await;

                                if let Ok(updated) = result.as_ref() {
                                    if let Some(runner)=parallel_runners.get_mut(&id){runner.service_tier=updated.service_tier;runner.fast_mode=updated.fast_mode;}

                                    // A running Claude session takes the new effort
                                    // now; any other mission reads it at its next turn.
                                    if model_effort.is_some()
                                        && updated.backend == "claudecode"
                                        && old_backend.as_deref() == Some("claudecode")
                                    {
                                        crate::api::runners::live_session::set_effort(
                                            id,
                                            updated.model_effort.clone(),
                                        );
                                    }
                                    let _ = events_tx.send(AgentEvent::MissionSettingsUpdated {
                                        mission_id: id,
                                        backend: updated.backend.clone(),
                                        agent: updated.agent.clone(),
                                        model_override: updated.model_override.clone(),
                                        model_effort: updated.model_effort.clone(),
                                        fast_mode: updated.fast_mode,
                                        service_tier: updated.service_tier,
                                        config_profile: updated.config_profile.clone(),
                                        session_id: updated.session_id.clone(),
                                        updated_at: updated.updated_at.clone(),
                                    });

                                    // Backend switch handoff: the new backend starts a
                                    // fresh session and can't replay the old backend's
                                    // reasoning format, so carry the recent reasoning
                                    // forward as a plain-text context message. It lands
                                    // in the conversation history and is picked up by
                                    // the next turn (resume or message) on either
                                    // backend. Workspace + transcript carry over already.
                                    let backend_switched = old_backend
                                        .as_deref()
                                        .map(|prev| prev != updated.backend.as_str())
                                        .unwrap_or(false);
                                    if backend_switched {
                                        let prev = old_backend.as_deref().unwrap_or("the previous backend");
                                        if let Some(handoff) = build_backend_handoff_context(
                                            &mission_store,
                                            id,
                                            prev,
                                            &updated.backend,
                                        )
                                        .await
                                        {
                                            let event = AgentEvent::UserMessage {
                                                id: Uuid::new_v4(),
                                                content: handoff,
                                                queued: false,
                                                mission_id: Some(id),
                                                source: None,
                                            };
                                            if let Err(e) = mission_store.log_event(id, &event).await {
                                                tracing::warn!(
                                                    mission_id = %id,
                                                    error = %e,
                                                    "Failed to persist backend handoff context"
                                                );
                                            }
                                            let _ = events_tx.send(event);
                                            tracing::info!(
                                                mission_id = %id,
                                                old_backend = ?old_backend,
                                                new_backend = %updated.backend,
                                                "Injected backend-switch handoff context to preserve reasoning"
                                            );
                                        }
                                    }
                                }

                                let _ = respond.send(result);
                            }
                            ControlCommand::StartParallel { mission_id, content, respond } => {
                                tracing::info!("StartParallel requested for mission {}", mission_id);

                                // Count currently running parallel missions
                                let parallel_running = parallel_runners.values().filter(|r| r.is_running()).count();
                                let main_running = if running.is_some() { 1 } else { 0 };
                                let total_running = parallel_running + main_running;
                                let max_parallel = crate::settings::max_parallel_missions_cached_or(config.max_parallel_missions);

                                if total_running >= max_parallel {
                                    let _ = respond.send(Err(format!(
                                        "Maximum parallel missions ({}) reached. {} running.",
                                        max_parallel, total_running
                                    )));
                                } else if let std::collections::hash_map::Entry::Vacant(entry) =
                                    parallel_runners.entry(mission_id)
                                {
                                    // Load mission to get existing history
                                    let mission = match load_mission_record(&mission_store, mission_id).await {
                                        Ok(m) => m,
                                        Err(e) => {
                                            let _ = respond.send(Err(format!("Failed to load mission: {}", e)));
                                            continue;
                                        }
                                    };

                                    // Don't start a paused mission — resume it explicitly first.
                                    if mission.status == MissionStatus::Paused {
                                        let _ = respond.send(Err(format!(
                                            "Mission {} is paused; resume it before starting",
                                            mission_id
                                        )));
                                        continue;
                                    }

                                    if let Err(error) = activate_mission_for_message(
                                        &control_hub,
                                        &mission_store,
                                        &events_tx,
                                        &mission,
                                        &content,
                                    )
                                    .await
                                    {
                                        let _ = respond.send(Err(format!(
                                            "Failed to activate mission before starting: {error}"
                                        )));
                                        continue;
                                    }

                                    // Create a new MissionRunner
                                    let mut runner = super::super::mission_runner::MissionRunner::new(
                                        mission_id,
                                        mission.workspace_id,
                                        mission.agent.clone(),
                                        Some(mission.backend.clone()),
                                        mission.session_id.clone(),
                                        mission.config_profile.clone(),
                                        model_for_dispatch(&mission_store, &mission).await,
                                        mission.model_effort.clone(),
                                        mission.fast_mode,
                                        mission.service_tier,
                                    );
                                    runner.pr_readonly = mission.project.tags.iter().any(|tag| tag == "pr-readonly");
                                    runner.working_directory = mission.working_directory.clone();
                                    runner.user = control_hub.identities.read().await.get(&session_user_id).cloned();

                                    // Load existing history into runner to preserve conversation context
                                    for entry in &mission.history {
                                        runner.history.push((entry.role.clone(), entry.content.clone()));
                                    }

                                    // Queue the initial message (no per-message agent override for parallel start)
                                    runner.queue_message(Uuid::new_v4(), content, None, None);

                                    // Start execution
                                    if let Err(error) = runner
                                        .acquire_durable_run(
                                            &mission_store,
                                            &format!("control:{session_user_id}"),
                                        )
                                        .await
                                    {
                                        let rollback = restore_mission_after_failed_run_acquisition(
                                            &mission_store,
                                            &events_tx,
                                            &mission,
                                        )
                                        .await;
                                        let _ = respond.send(Err(format!(
                                            "Failed to acquire mission run lease: {error}{}",
                                            rollback
                                                .err()
                                                .map(|rollback_error| format!(
                                                    "; failed to restore {} status: {rollback_error}",
                                                    mission.status
                                                ))
                                                .unwrap_or_default()
                                        )));
                                        continue;
                                    }
                                    let started = runner.start_next(
                                        config.clone(),
                                        Arc::clone(&root_agent),
                                        Arc::clone(&mcp),
                                        Arc::clone(&workspaces),
                                        library.clone(),
                                        events_tx.clone(),
                                        Arc::clone(&tool_hub),
                                        Arc::clone(&status),
                                        mission_cmd_tx.clone(),
                                        Arc::new(RwLock::new(Some(mission_id))), // Each runner tracks its own mission
                                        secrets.clone(),
                                    );

                                    if started {
                                        tracing::info!("Mission {} started in parallel", mission_id);
                                        entry.insert(runner);
                                        let _ = respond.send(Ok(()));
                                    } else {
                                        let _ = respond.send(Err("Failed to start mission execution".to_string()));
                                    }
                                } else {
                                    let _ = respond.send(Err(format!(
                                        "Mission {} is already running in parallel",
                                        mission_id
                                    )));
                                }
                            }
                            ControlCommand::CancelMission { mission_id, min_idle, keep_remote_queue, respond } => {
                                // Race-protect background cancels (watchdog, stale-cleanup):
                                // if the caller asked us to only cancel when truly idle and the
                                // mission has touched activity in the meantime, skip the cancel.
                                // This catches the case where the watchdog observed N seconds of
                                // silence, sent CancelMission, and a streaming response arrived
                                // before the actor got around to processing the command.
                                if let Some(min_idle) = min_idle {
                                    let idle = if let Some(runner) = parallel_runners.get(&mission_id) {
                                        Some(runner.last_activity.elapsed())
                                    } else if running_mission_id == Some(mission_id) {
                                        Some(main_runner_last_activity.elapsed())
                                    } else {
                                        None
                                    };
                                    if let Some(idle) = idle {
                                        if idle < min_idle {
                                            tracing::info!(
                                                mission_id = %mission_id,
                                                idle_secs = idle.as_secs(),
                                                threshold_secs = min_idle.as_secs(),
                                                "Skipping watchdog/cleanup cancel: mission resumed activity before cancel was processed"
                                            );
                                            let _ = respond.send(Ok(
                                                CancelMissionOutcome::SkippedRecentlyActive,
                                            ));
                                            continue;
                                        }
                                    }
                                }
                                // The actor already holds DISPATCH_ADMISSION. Fence
                                // durable follow-ups before stopping the current run,
                                // so a timer snapshot cannot restart an explicit Stop.
                                if let Some(state) = control_hub.admission_state.get().and_then(std::sync::Weak::upgrade).filter(|_| !keep_remote_queue) {
                                    let cleared = async {
                                        let _file = dispatch_admission::durable_lock(&config).await?;
                                        remote_queue::cancel_tree(&state.projects, &mission_store, &session_user_id, mission_id).await
                                    }.await;
                                    if let Err(error) = cleared {
                                        let _ = respond.send(Err(format!("Failed to cancel remote follow-ups: {error}")));
                                        continue;
                                    }
                                }
                                if let Err(error) = continuations::stop_for_mission(&mission_store, mission_id).await {
                                    let _ = respond.send(Err(format!("Failed to fence mission wake-ups: {error}")));
                                    continue;
                                }
                                // Helper: cascade-cancel all child missions of the given parent.
                                async fn cancel_child_missions(
                                    parent_id: Uuid,
                                    mission_store: &Arc<dyn MissionStore>,
                                    parallel_runners: &mut HashMap<Uuid, super::super::mission_runner::MissionRunner>,
                                    events_tx: &tokio::sync::broadcast::Sender<AgentEvent>,
                                    working_dir: &std::path::Path,
                                ) {
                                    let children = match mission_store.get_child_missions(parent_id).await {
                                        Ok(c) => c,
                                        Err(e) => {
                                            tracing::warn!("Failed to fetch child missions for cascade cancel: {}", e);
                                            return;
                                        }
                                    };
                                    for child in children {
                                        if matches!(child.status, MissionStatus::Completed | MissionStatus::Failed | MissionStatus::Interrupted | MissionStatus::NotFeasible) {
                                            continue;
                                        }
                                        if let Err(error) = continuations::stop_for_mission(mission_store, child.id).await {
                                            tracing::error!(mission_id = %child.id, %error, "Failed to revoke child wake-ups during cascade cancellation");
                                        }
                                        // Cancel runner if running
                                        if let Some(runner) = parallel_runners.get_mut(&child.id) {
                                            runner.cancel();
                                            if let Some(run) = runner.durable_run.as_ref() {
                                                let _ = mission_store
                                                    .heartbeat_mission_run(
                                                        run.run_id,
                                                        run.generation,
                                                        MissionExecutionState::Stopping,
                                                        None,
                                                    )
                                                    .await;
                                            }
                                            // Keep the runner registered until its task
                                            // actually exits; dropping the JoinHandle
                                            // here would detach live work.
                                            continue;
                                        }
                                        if let Err(e) = mission_store
                                            .update_mission_status(child.id, MissionStatus::Interrupted)
                                            .await
                                        {
                                            tracing::warn!("Failed to cancel child mission {}: {}", child.id, e);
                                        } else {
                                            let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                                                completion: None,
                                                execution: None,
                                                mission_id: child.id,
                                                status: MissionStatus::Interrupted,
                                                summary: None,
                                            });
                                        }
                                        close_mission_desktop_sessions(mission_store, child.id, working_dir).await;
                                    }
                                }

                                // First check parallel runners
                                if let Some(runner) = parallel_runners.get_mut(&mission_id) {
                                    runner.cancel();
                                    if let Some(run) = runner.durable_run.as_ref() {
                                        let _ = mission_store
                                            .heartbeat_mission_run(
                                                run.run_id,
                                                run.generation,
                                                MissionExecutionState::Stopping,
                                                None,
                                            )
                                            .await;
                                    }
                                    let _ = events_tx.send(AgentEvent::Error {
                                        message: format!("Parallel mission {} cancellation requested", mission_id),
                                        mission_id: Some(mission_id),
                                        resumable: true, // Cancelled missions can be resumed
                                    });
                                    // Cascade cancel child missions
                                    cancel_child_missions(mission_id, &mission_store, &mut parallel_runners, &events_tx, &config.working_dir).await;
                                    if let Err(error) = persist_control_queue_if_changed(
                                        &mission_store,
                                        &session_user_id,
                                        &queue,
                                        &parallel_runners,
                                        &recovered_consumed_user_messages,
                                        &mut last_persisted_queue,
                                    )
                                    .await
                                    {
                                        tracing::warn!(mission_id = %mission_id,
                                            "Failed to persist cleared queues after cancellation: {error}");
                                    }
                                    let _ = respond.send(Ok(CancelMissionOutcome::Cancelled));
                                } else {
                                    // Check if this is the currently executing mission
                                    // Use running_mission_id (the actual mission being executed)
                                    // instead of current_mission (which can change when user creates a new mission)
                                    if running_mission_id == Some(mission_id) {
                                        // Cancel the current execution
                                        if let Some(token) = &running_cancel {
                                            token.cancel();
                                            if let Some(run) = running_run.as_ref() {
                                                let _ = mission_store
                                                    .heartbeat_mission_run(
                                                        run.run_id,
                                                        run.generation,
                                                        MissionExecutionState::Stopping,
                                                        None,
                                                    )
                                                    .await;
                                            }
                                            // Arm the force-clear deadline. Most cancels
                                            // wind down within a few seconds via the
                                            // task's own observation of the cancel
                                            // token; the deadline catches the zombie
                                            // case where the underlying CLI subprocess
                                            // is dead/blocked and the JoinHandle never
                                            // resolves on its own.
                                            runner_force_clear_deadline = Some(
                                                tokio::time::Instant::now()
                                                    + RUNNER_FORCE_CLEAR_GRACE,
                                            );
                                            close_mission_desktop_sessions(
                                                &mission_store,
                                                mission_id,
                                                &config.working_dir,
                                            )
                                            .await;
                                            // Don't send Error event here - the task will complete and send
                                            // an AssistantMessage with resumable=true when it finishes.
                                            // Sending both causes duplicate UI messages.
                                            // Cascade cancel child missions
                                            cancel_child_missions(mission_id, &mission_store, &mut parallel_runners, &events_tx, &config.working_dir).await;
                                            let _ = respond.send(Ok(CancelMissionOutcome::Cancelled));
                                        } else {
                                            let _ = respond.send(Err("Mission not currently executing".to_string()));
                                        }
                                    } else {
                                        // A mission can exist durably without owning a
                                        // runner yet (for example a scheduled/deferred
                                        // Pending mission). Cancellation must still
                                        // release it, otherwise deferred work and PR
                                        // writer leases can become impossible to clear.
                                        // Existing terminal rows are an idempotent
                                        // success so cleanup loops do not trip their
                                        // circuit breaker by cancelling twice.
                                        match mission_store.get_mission(mission_id).await {
                                            // Blocked is terminal for scheduling, but a
                                            // parked native goal still owns its track.
                                            // Explicit cancellation must transition it
                                            // through the no-runner cancellation path.
                                            Ok(Some(mission)) if matches!(mission.status,
                                                MissionStatus::Completed | MissionStatus::Failed
                                                | MissionStatus::Interrupted | MissionStatus::NotFeasible
                                                | MissionStatus::Acknowledged) =>
                                            {
                                                if let Err(error) = finish_detached_run_for_cancel(
                                                    &mission_store,
                                                    mission_id,
                                                )
                                                .await
                                                {
                                                    let _ = respond.send(Err(format!(
                                                        "Failed to settle detached mission run: {error}"
                                                    )));
                                                    continue;
                                                }
                                                let _ = respond.send(Ok(CancelMissionOutcome::Cancelled));
                                            }
                                            Ok(Some(_)) => {
                                                if let Err(error) = finish_detached_run_for_cancel(
                                                    &mission_store,
                                                    mission_id,
                                                )
                                                .await
                                                {
                                                    let _ = respond.send(Err(format!(
                                                        "Failed to settle detached mission run: {error}"
                                                    )));
                                                    continue;
                                                }
                                                let update = mission_store
                                                    .update_mission_status(
                                                        mission_id,
                                                        MissionStatus::Interrupted,
                                                    )
                                                    .await;
                                                if let Err(error) = update {
                                                    let _ = respond.send(Err(error));
                                                    continue;
                                                }
                                                let _ = mission_store
                                                    .set_deferred_goal(mission_id, None)
                                                    .await;
                                                let _ = events_tx.send(
                                                    AgentEvent::MissionStatusChanged {
                                                        completion: None,
                                                        execution: None,
                                                        mission_id,
                                                        status: MissionStatus::Interrupted,
                                                        summary: None,
                                                    },
                                                );
                                                close_mission_desktop_sessions(
                                                    &mission_store,
                                                    mission_id,
                                                    &config.working_dir,
                                                )
                                                .await;
                                                cancel_child_missions(
                                                    mission_id,
                                                    &mission_store,
                                                    &mut parallel_runners,
                                                    &events_tx,
                                                    &config.working_dir,
                                                )
                                                .await;
                                                let _ = respond.send(Ok(CancelMissionOutcome::Cancelled));
                                            }
                                            Ok(None) => {
                                                let _ = respond.send(Err(format!(
                                                    "Mission {} not found",
                                                    mission_id
                                                )));
                                            }
                                            Err(error) => {
                                                let _ = respond.send(Err(error));
                                            }
                                        }
                                    }
                                }
                            }
                            ControlCommand::PauseMission { mission_id, respond } => {
                                // Stop any in-flight runner before parking the mission so
                                // the agent turn can't keep executing (and overwrite the
                                // paused status on completion). Mirrors CancelMission's
                                // stop logic but lands on `Paused` instead of `Interrupted`.
                                if let Some(runner) = parallel_runners.get_mut(&mission_id) {
                                    runner.cancel();
                                    if let Some(run) = runner.durable_run.as_ref() {
                                        let _ = mission_store
                                            .heartbeat_mission_run(
                                                run.run_id,
                                                run.generation,
                                                MissionExecutionState::Stopping,
                                                None,
                                            )
                                            .await;
                                    }
                                    close_mission_desktop_sessions(
                                        &mission_store,
                                        mission_id,
                                        &config.working_dir,
                                    )
                                    .await;
                                } else if running_mission_id == Some(mission_id) {
                                    if let Some(token) = &running_cancel {
                                        token.cancel();
                                        if let Some(run) = running_run.as_ref() {
                                            let _ = mission_store
                                                .heartbeat_mission_run(
                                                    run.run_id,
                                                    run.generation,
                                                    MissionExecutionState::Stopping,
                                                    None,
                                                )
                                                .await;
                                        }
                                        // Arm the force-clear deadline so a zombie runner
                                        // that never observes the cancel still gets torn
                                        // down (matches CancelMission).
                                        runner_force_clear_deadline = Some(
                                            tokio::time::Instant::now() + RUNNER_FORCE_CLEAR_GRACE,
                                        );
                                    }
                                    close_mission_desktop_sessions(
                                        &mission_store,
                                        mission_id,
                                        &config.working_dir,
                                    )
                                    .await;
                                }

                                // Set Paused last so it survives the runner teardown above.
                                // maybe_finalize_terminal_mission skips non-Active/Pending/
                                // Interrupted statuses, so the cancelled turn's completion
                                // won't promote this back out of Paused.
                                match mission_store
                                    .update_mission_status(mission_id, MissionStatus::Paused)
                                    .await
                                {
                                    Ok(()) => {
                                        // FLEET-004: stamp the pause time for UI pause-age.
                                        let _ = mission_store
                                            .set_mission_paused_at(
                                                mission_id,
                                                Some(chrono::Utc::now().to_rfc3339()),
                                            )
                                            .await;
                                        let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                                            completion: None,
                                            execution: None,
                                            mission_id,
                                            status: MissionStatus::Paused,
                                            summary: None,
                                        });
                                        let _ = respond.send(Ok(()));
                                    }
                                    Err(e) => {
                                        let _ = respond.send(Err(format!(
                                            "Failed to pause mission {}: {}",
                                            mission_id, e
                                        )));
                                    }
                                }
                            }
                            #[cfg(test)]
                            ControlCommand::InspectActorContext { respond } => {
                                let _ = respond.send((*current_mission.read().await, history.clone()));
                            }
                            ControlCommand::ListRunning { respond } => {
                                // Return info about currently running missions
                                let mut running_list = Vec::new();
                                let remote_job_missions = crate::remote_node::job_ledger::load(
                                    &config.working_dir,
                                )
                                .await
                                .unwrap_or_default()
                                .into_iter()
                                .filter(|handle| {
                                    remote_build_handle_proves_liveness(handle, chrono::Utc::now())
                                })
                                .map(|handle| handle.mission_id)
                                .collect::<HashSet<_>>();

                                // Add main mission if running - use running_mission_id (the actual mission being executed)
                                // instead of current_mission (which can change when user creates a new mission)
                                if running.is_some() {
                                    if let Some(mission_id) = running_mission_id {
                                        let waiting_remote_job =
                                            remote_job_missions.contains(&mission_id);
                                        let seconds_since_activity =
                                            main_runner_last_activity.elapsed().as_secs();
                                        let state_label = {
                                            let status_guard = status.read().await;
                                            if waiting_remote_job {
                                                "waiting_remote_job"
                                            } else if status_guard.mission_id == Some(mission_id)
                                                && status_guard.state == ControlRunState::WaitingForTool
                                            {
                                                "waiting_for_tool"
                                            } else {
                                                "running"
                                            }
                                        };
                                        let mission_state = if state_label == "waiting_for_tool" {
                                            super::super::mission_runner::MissionRunState::WaitingForTool
                                        } else {
                                            super::super::mission_runner::MissionRunState::Running
                                        };
                                        let tool_call_in_flight = waiting_remote_job
                                            || main_runner_active_tool_calls
                                                .load(std::sync::atomic::Ordering::Relaxed)
                                                > 0;
                                        running_list.push(super::super::mission_runner::RunningMissionInfo {
                                            mission_id,
                                            backend_id: running_backend_id.clone(),
                                            state: state_label.to_string(),
                                            queue_len: queue.len(),
                                            history_len: history.len(),
                                            seconds_since_activity,
                                            tool_call_in_flight,
                                            health: projected_running_health(
                                                mission_state,
                                                seconds_since_activity,
                                                tool_call_in_flight,
                                                waiting_remote_job,
                                                running_backend_id.as_deref(),
                                            ),
                                            expected_deliverables: 0,
                                            current_activity: main_runner_activity.clone(),
                                            subtask_total: main_runner_subtasks.len(),
                                            subtask_completed: main_runner_subtasks.iter().filter(|s| s.completed).count(),
                                            run_id: running_run.as_ref().map(|run| run.run_id),
                                            generation: running_run.as_ref().map(|run| run.generation),
                                            heartbeat_at: running_run.as_ref().map(|run| run.heartbeat_at.clone()),
                                            scope_unit: running_run.as_ref().and_then(|run| run.scope_unit.clone()),
                                            status_conflict: running_run
                                                .is_none()
                                                .then(|| "actor_without_durable_run".to_string()),
                                        });
                                    }
                                }

                                // Add all parallel runners
                                for runner in parallel_runners.values() {
                                    let mut info = super::super::mission_runner::RunningMissionInfo::from(runner);
                                    if remote_job_missions.contains(&info.mission_id) {
                                        info.state = "waiting_remote_job".to_string();
                                        info.tool_call_in_flight = true;
                                        info.health = super::super::mission_runner::MissionHealth::Healthy;
                                    }
                                    running_list.push(info);
                                }

                                let _ = respond.send(running_list);
                            }
                            ControlCommand::GetActorRunLease { mission_id, respond } => {
                                let parallel_runner = parallel_runners.get(&mission_id);
                                let actor_run = select_actor_run_lease(
                                    mission_id,
                                    running.is_some(),
                                    running_mission_id,
                                    running_run
                                        .as_ref()
                                        .map(|run| (run.run_id, run.generation)),
                                    parallel_runner.is_some_and(|runner| runner.is_running()),
                                    parallel_runner
                                        .and_then(|runner| runner.durable_run.as_ref())
                                        .map(|run| (run.run_id, run.generation)),
                                );
                                let _ = respond.send(actor_run);
                            }
                            ControlCommand::ResumeMission { mission_id, clean_workspace, skip_message, content, respond } => {
                                // Resumable terminal writers do not hold a lease, so a replacement
                                // writer may have been created since this mission stopped. Serialize
                                // the availability check with create/project updates and keep the
                                // guard until the resumed mission has been made Active (or the
                                // resume has failed). Otherwise a create can race between the check
                                // and the status transition and start a second branch-changing
                                // runner for the same PR.
                                let _pr_writer_guard = match acquire_durable_pr_writer_lock(&control_hub).await {
                                    Ok(guard) => guard,
                                    Err(error) => {
                                        let _ = respond.send(Err(error));
                                        continue;
                                    }
                                };
                                // Resume an interrupted mission by building resume context
                                match resume_mission_impl(
                                    &mission_store,
                                    &config,
                                    mission_id,
                                    clean_workspace,
                                )
                                .await {
                                    Ok((mission, default_resume_prompt)) => {
                                        let resume_prompt = content.unwrap_or(default_resume_prompt);
                                        if let Err(error) = ensure_pr_writer_resume_is_exclusive(
                                            &control_hub,
                                            &mission_store,
                                            &mission,
                                        )
                                        .await
                                        {
                                            let _ = respond.send(Err(error));
                                            continue;
                                        }
                                        let already_running_main =
                                            running.is_some() && running_mission_id == Some(mission_id);
                                        let already_running_parallel = parallel_runners
                                            .get(&mission_id)
                                            .is_some_and(|runner| runner.is_running());
                                        if already_running_main || already_running_parallel {
                                            let _ = respond.send(Err(format!(
                                                "Mission {} is already running",
                                                mission_id
                                            )));
                                            continue;
                                        }

                                        // If another main mission is running, resume this one in a
                                        // parallel runner so its history stays isolated. This is
                                        // important for startup recovery when several missions were
                                        // interrupted by the same service restart.
                                        if running.is_some() {
                                            if skip_message {
                                                if mission.status == MissionStatus::Paused {
                                                    if let Err(error) = mission_store
                                                        .update_mission_status(
                                                            mission_id,
                                                            MissionStatus::Interrupted,
                                                        )
                                                        .await
                                                    {
                                                        let _ = respond.send(Err(error));
                                                        continue;
                                                    }
                                                    let _ = mission_store
                                                        .set_mission_paused_at(mission_id, None)
                                                        .await;
                                                    let _ = events_tx.send(
                                                        AgentEvent::MissionStatusChanged {
                                                            completion: None,
                                                            execution: None,
                                                            mission_id,
                                                            status: MissionStatus::Interrupted,
                                                            summary: None,
                                                        },
                                                    );
                                                }
                                                tracing::info!(
                                                    mission_id = %mission_id,
                                                    "Deferring parallel resume until the caller sends a custom message"
                                                );
                                                let mut updated_mission = mission;
                                                if updated_mission.status == MissionStatus::Paused {
                                                    updated_mission.status = MissionStatus::Interrupted;
                                                    updated_mission.paused_at = None;
                                                }
                                                let _ = respond.send(Ok(updated_mission));
                                                continue;
                                            }

                                            let parallel_running = parallel_runners
                                                .values()
                                                .filter(|runner| runner.is_running())
                                                .count();
                                            let total_running = parallel_running + 1;
                                            let max_parallel =
                                                crate::settings::max_parallel_missions_cached_or(
                                                    config.max_parallel_missions,
                                                );

                                            if total_running >= max_parallel {
                                                let _ = respond.send(Err(format!(
                                                    "Maximum parallel missions ({}) reached. {} running.",
                                                    max_parallel, total_running
                                                )));
                                                continue;
                                            }

                                            // Explicit resume is the authority to clear
                                            // a paused/interrupted presentation row.
                                            // Persist it before acquiring the run so the
                                            // store can reject any stale-state race.
                                            if let Err(error) = mission_store
                                                .update_mission_status(mission_id, MissionStatus::Active)
                                                .await
                                            {
                                                let _ = respond.send(Err(format!(
                                                    "Failed to activate mission before resume: {error}"
                                                )));
                                                continue;
                                            }
                                            let mut runner = super::super::mission_runner::MissionRunner::new(
                                                mission_id,
                                                mission.workspace_id,
                                                mission.agent.clone(),
                                                Some(mission.backend.clone()),
                                                mission.session_id.clone(),
                                                mission.config_profile.clone(),
                                                model_for_dispatch(&mission_store, &mission).await,
                                                mission.model_effort.clone(),
                                                mission.fast_mode,
                                                mission.service_tier,
                                            );
                                            runner.pr_readonly = mission.project.tags.iter().any(|tag| tag == "pr-readonly");
                                            runner.working_directory = mission.working_directory.clone();
                                            runner.user = control_hub.identities.read().await.get(&session_user_id).cloned();
                                            for entry in &mission.history {
                                                runner
                                                    .history
                                                    .push((entry.role.clone(), entry.content.clone()));
                                            }
                                            runner.queue_message(Uuid::new_v4(), resume_prompt, None, None);

                                            if let Err(error) = runner
                                                .acquire_durable_run(
                                                    &mission_store,
                                                    &format!("control:{session_user_id}"),
                                                )
                                                .await
                                            {
                                                let rollback =
                                                    restore_mission_after_failed_run_acquisition(
                                                        &mission_store,
                                                        &events_tx,
                                                        &mission,
                                                    )
                                                    .await;
                                                let _ = respond.send(Err(format!(
                                                    "Failed to acquire mission run lease: {error}{}",
                                                    rollback
                                                        .err()
                                                        .map(|rollback_error| format!(
                                                            "; failed to restore {} status: {rollback_error}",
                                                            mission.status
                                                        ))
                                                        .unwrap_or_default()
                                                )));
                                                continue;
                                            }
                                            if mission.status == MissionStatus::Paused {
                                                let _ = mission_store
                                                    .set_mission_paused_at(mission_id, None)
                                                    .await;
                                            }
                                            maybe_schedule_mission_metadata_refresh_for_status(
                                                &mission_store,
                                                &events_tx,
                                                mission_id,
                                                MissionStatus::Active,
                                            );
                                            let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                                                completion: None,
                                                execution: None,
                                                mission_id,
                                                status: MissionStatus::Active,
                                                summary: None,
                                            });
                                            let started = runner.start_next(
                                                config.clone(),
                                                Arc::clone(&root_agent),
                                                Arc::clone(&mcp),
                                                Arc::clone(&workspaces),
                                                library.clone(),
                                                events_tx.clone(),
                                                Arc::clone(&tool_hub),
                                                Arc::clone(&status),
                                                mission_cmd_tx.clone(),
                                                Arc::new(RwLock::new(Some(mission_id))),
                                                secrets.clone(),
                                            );

                                            if !started {
                                                let _ = respond.send(Err(
                                                    "Failed to start mission execution".to_string(),
                                                ));
                                                continue;
                                            }

                                            parallel_runners.insert(mission_id, runner);
                                            let mut updated_mission = mission;
                                            updated_mission.status = MissionStatus::Active;
                                            updated_mission.resumable = false;
                                            updated_mission.interrupted_at = None;
                                            let _ = respond.send(Ok(updated_mission));
                                            continue;
                                        }

                                        // First persist current mission history (if any)
                                        persist_mission_history(
                                            &mission_store,
                                            &events_tx,
                                            &current_mission,
                                            &history,
                                        )
                                        .await;

                                        let previous_mission = *current_mission.read().await;
                                        let previous_history = history.clone();

                                        // Load the mission's history into current state
                                        history = mission.history.iter()
                                            .map(|e| (e.role.clone(), e.content.clone()))
                                            .collect();
                                        *current_mission.write().await = Some(mission_id);

                                        // Update mission status back to active
                                        if let Err(e) = mission_store
                                            .update_mission_status(mission_id, MissionStatus::Active)
                                            .await
                                        {
                                            history = previous_history;
                                            *current_mission.write().await = previous_mission;
                                            let _ = respond.send(Err(format!("Failed to resume mission {mission_id}: {e}")));
                                            continue;
                                        } else {
                                            if mission.status == MissionStatus::Paused {
                                                let _ = mission_store
                                                    .set_mission_paused_at(mission_id, None)
                                                    .await;
                                            }
                                            maybe_schedule_mission_metadata_refresh_for_status(
                                                &mission_store,
                                                &events_tx,
                                                mission_id,
                                                MissionStatus::Active,
                                            );
                                            // Send status changed event so UI updates
                                            let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                                                completion: None,
                                                execution: None,
                                                mission_id,
                                                status: MissionStatus::Active,
                                                summary: None,
                                            });
                                        }

                                        // Queue the resume prompt as a message (no per-message agent override)
                                        // Skip if the caller just wants to update the status (e.g., before sending a custom message)
                                        let resume_message_id = Uuid::new_v4();
                                        if !skip_message {
                                            let msg_id = resume_message_id;
                                            queue.push_back((
                                                msg_id,
                                                resume_prompt,
                                                None,
                                                Some(mission_id),
                                                Some("system:resume".to_string()),
                                            ));
                                        }

                                        // Persist acceptance before a dequeue can erase
                                        // the only durable copy of the custom prompt.
                                        if !skip_message {
                                            if let Err(error) = persist_control_queue_if_changed(
                                                &mission_store, &session_user_id, &queue, &parallel_runners,
                                                &recovered_consumed_user_messages, &mut last_persisted_queue,
                                            ).await {
                                                queue.retain(|(queued_id, ..)| *queued_id != resume_message_id);
                                                history = previous_history;
                                                *current_mission.write().await = previous_mission;
                                                let rollback = restore_mission_after_failed_run_acquisition(&mission_store, &events_tx, &mission).await;
                                                let error = match rollback {
                                                    Ok(()) => error,
                                                    Err(rollback) => format!("{error}; status recovery required: {rollback}"),
                                                };
                                                let _ = respond.send(Err(format!("Failed to persist resumed mission queue: {error}")));
                                                continue;
                                            }
                                        }

                                        // Start execution if not already running
                                        if running.is_none() {
                                            if let Some((mid, msg, per_msg_agent, msg_target_mid, msg_source)) = pop_next_runnable_control_queue(&mut queue, &mission_store).await {
                                                // Persist the dequeue before the awaits that
                                                // start the run, so a crash here can't
                                                // restore + re-run it.
                                                if let Err(error) = persist_control_queue_if_changed(
                                                    &mission_store,
                                                    &session_user_id,
                                                    &queue,
                                                    &parallel_runners,
                                                    &recovered_consumed_user_messages,
                                                    &mut last_persisted_queue,
                                                )
                                                .await
                                                {
                                                    queue.push_front((
                                                        mid,
                                                        msg,
                                                        per_msg_agent,
                                                        msg_target_mid,
                                                        msg_source,
                                                    ));
                                                    // Enqueue already committed. Keep the
                                                    // accepted prompt and its new identity;
                                                    // this is queued work, not a rejection.
                                                    tracing::warn!(%error, "Resumed prompt remains durably queued after dequeue failure");
                                                    let mut accepted = mission.clone();
                                                    accepted.status = MissionStatus::Active;
                                                    let _ = respond.send(Ok(accepted));
                                                    continue;
                                                }
                                                let target_mid = msg_target_mid.unwrap_or(mission_id);
                                                set_and_emit_status(
                                                    &status,
                                                    &events_tx,
                                                    ControlRunState::Running,
                                                    queue.len(),
                                                    Some(target_mid),
                                                ).await;
                                                let _ = events_tx.send(AgentEvent::UserMessage { id: mid, content: msg.clone(), queued: false, mission_id: Some(target_mid), source: msg_source.clone() });
                                                let cfg = config.clone();
                                                let agent = Arc::clone(&root_agent);
                                                let mcp_ref = Arc::clone(&mcp);
                                                let workspaces_ref = Arc::clone(&workspaces);
                                                let library_ref = Arc::clone(&library);
                                                let events = events_tx.clone();
                                                let tools_hub = Arc::clone(&tool_hub);
                                                let status_ref = Arc::clone(&status);
                                                let cancel = CancellationToken::new();
                                                let hist_snapshot = history.clone();
                                                let mission_ctrl = crate::tools::mission::MissionControl {
                                                    current_mission_id: Arc::clone(&current_mission),
                                                    cmd_tx: mission_cmd_tx.clone(),
                                                };
                                                let tree_ref = Arc::clone(&current_tree);
                                                let progress_ref = Arc::clone(&progress);
                                                let workspace_id = Some(mission.workspace_id);
                                                let backend_id = Some(mission.backend.clone());
                                                let model_override = model_for_dispatch(&mission_store, &mission).await;
                                                let model_effort = mission.model_effort.clone();
                                                let fast_mode = mission.fast_mode;
                                                let service_tier=mission.service_tier;
                                                // Resume uses mission agent (no per-message override for resumes)
                                                let agent_override = mission.agent.clone();
                                                let session_id = mission.session_id.clone();
                                                let mission_config_profile = mission.config_profile.clone();
                                                let pr_readonly = mission.project.tags.iter().any(|tag| tag == "pr-readonly");
                                                running_cancel = Some(cancel.clone());
                                                // Capture which mission this task is working on (the resumed mission)
                                                running_mission_id = Some(mission_id);
                                                running_backend_id = backend_id.clone();
                                                // Reset activity tracking so stall detection starts fresh
                                                main_runner_last_activity = std::time::Instant::now();
                                                main_runner_activity = None;
                                                main_runner_subtasks.clear();
                                                main_runner_active_tool_calls
                                                    .store(0, std::sync::atomic::Ordering::Relaxed);
                                                let user_id_for_turn = control_hub.identities.read().await.get(&session_user_id).cloned();
                                                running_run = match acquire_execution_run(
                                                    &mission_store,
                                                    Some(mission_id),
                                                    &format!("control:{session_user_id}"),
                                                )
                                                .await
                                                {
                                                    Ok(run) => run,
                                                    Err(error) => {
                                                        running_cancel = None;
                                                        running_mission_id = None;
                                                        running_backend_id = None;
                                                        history = previous_history;
                                                        *current_mission.write().await = previous_mission;
                                                        let error = match restore_mission_after_failed_run_acquisition(
                                                            &mission_store, &events_tx, &mission,
                                                        ).await {
                                                            Ok(()) => error,
                                                            Err(rollback) => format!("{error}; status recovery required: {rollback}"),
                                                        };
                                                        // No runner was started. Compensate the shared
                                                        // Running presentation before returning rejection.
                                                        set_and_emit_status(
                                                            &status,
                                                            &events_tx,
                                                            ControlRunState::Idle,
                                                            queue.len(),
                                                            None,
                                                        ).await;
                                                        let _ = respond.send(Err(format!(
                                                            "Failed to acquire mission run lease: {error}"
                                                        )));
                                                        continue;
                                                    }
                                                };
                                                let turn_mission_store = mission_store.clone();
                                                let session_update_run = running_run.as_ref().map(crate::api::mission_store::SessionUpdateRun::from);
                                                running_message_id = Some(mid);
                                                running_execution_ids = deferred_messages::execution_ids(mid, &msg, msg_source.as_deref());
                                                running = Some(tokio::spawn(async move {
                                                    let result = crate::api::runners::SESSION_UPDATE_RUN.scope(session_update_run, run_single_control_turn(
                                                        turn_mission_store,
                                                        cfg,
                                                        agent,
                                                        mcp_ref,
                                                        workspaces_ref,
                                                        library_ref,
                                                        events,
                                                        tools_hub,
                                                        status_ref,
                                                        cancel,
                                                        hist_snapshot,
                                                        if msg_source.as_deref() == Some("scheduler") { deferred_messages::strip(&msg) } else { msg.clone() },
                                                        Some(mission_ctrl),
                                                        tree_ref,
                                                        progress_ref,
                                                        Some(mission_id),
                                                        workspace_id,
                                                        backend_id,
                                                        model_override,
                                                        model_effort,
                                                        fast_mode,
                                                        service_tier,
                                                        agent_override,
                                                        session_id,
                                                        true, // force_session_resume: this is a resume operation
                                                        mission_config_profile,
                                                        user_id_for_turn,
                                                        pr_readonly,
                                                    ))
                                                    .await;
                                                    (mid, msg, result)
                                                }));
                                            }
                                        }

                                        // Return the updated mission
                                        let mut updated_mission = mission;
                                        updated_mission.status = MissionStatus::Active;
                                        updated_mission.resumable = false;
                                        updated_mission.interrupted_at = None;
                                        let _ = respond.send(Ok(updated_mission));
                                    }
                                    Err(e) => {
                                        let _ = respond.send(Err(e));
                                    }
                                }
                            }
                            ControlCommand::GracefulShutdown { respond } => {
                                // Mark all running missions as interrupted
                                let mut interrupted_ids = Vec::new();

                                // Handle main mission - use running_mission_id (the actual mission being executed)
                                // Note: We DON'T persist history here because:
                                // 1. If current_mission == running_mission_id, history is correct
                                // 2. If current_mission != running_mission_id (user created new mission),
                                //    history was cleared and doesn't belong to running_mission_id
                                // The running mission's history is already in DB from previous exchanges,
                                // and any in-progress exchange will be lost (acceptable for shutdown).
                                if running.is_some() {
                                    if let Some(mission_id) = running_mission_id {
                                        // Only persist if the running mission is still current mission
                                        // (i.e., user didn't create a new mission while this one was running)
                                        let current_mid = *current_mission.read().await;
                                        if current_mid == Some(mission_id) {
                                            persist_mission_history(
                                                &mission_store,
                                                &events_tx,
                                                &current_mission,
                                                &history,
                                            )
                                            .await;
                                        }
                                        // Note: If missions differ, don't persist - the local history
                                        // belongs to current_mission, not running_mission_id

                                        let preserve_remote_wait =
                                            preserve_remote_wait_during_shutdown(
                                                &mission_store,
                                                &config.working_dir,
                                                mission_id,
                                            )
                                            .await;
                                        if !preserve_remote_wait
                                            && mission_store
                                                .update_mission_status_with_reason(
                                                    mission_id,
                                                    MissionStatus::Interrupted,
                                                    Some("server_shutdown"),
                                                )
                                                .await
                                                .is_ok()
                                        {
                                            maybe_schedule_mission_metadata_refresh_for_status(
                                                &mission_store,
                                                &events_tx,
                                                mission_id,
                                                MissionStatus::Interrupted,
                                            );
                                            interrupted_ids.push(mission_id);
                                            tracing::info!("Marked mission {} as interrupted", mission_id);
                                        }

                                        // Cancel execution
                                        if let Some(token) = &running_cancel {
                                            token.cancel();
                                        }
                                    }
                                }

                                // Handle parallel missions
                                for (mission_id, runner) in parallel_runners.iter_mut() {
                                    // Persist history for parallel mission
                                    let entries: Vec<MissionHistoryEntry> = runner
                                        .history
                                        .iter()
                                        .map(|(role, content)| MissionHistoryEntry {
                                            role: role.clone(),
                                            content: content.clone(),
                                        })
                                        .collect();
                                    persist_mission_history_and_schedule_metadata_refresh(
                                        &mission_store,
                                        &events_tx,
                                        *mission_id,
                                        &entries,
                                    )
                                    .await;
                                    let preserve_remote_wait =
                                        preserve_remote_wait_during_shutdown(
                                            &mission_store,
                                            &config.working_dir,
                                            *mission_id,
                                        )
                                        .await;
                                    if !preserve_remote_wait
                                        && mission_store
                                            .update_mission_status_with_reason(
                                                *mission_id,
                                                MissionStatus::Interrupted,
                                                Some("server_shutdown"),
                                            )
                                            .await
                                            .is_ok()
                                    {
                                        maybe_schedule_mission_metadata_refresh_for_status(
                                            &mission_store,
                                            &events_tx,
                                            *mission_id,
                                            MissionStatus::Interrupted,
                                        );
                                        interrupted_ids.push(*mission_id);
                                        tracing::info!("Marked parallel mission {} as interrupted", mission_id);
                                    }

                                    runner.cancel();
                                }

                                let _ = respond.send(interrupted_ids);
                            }
                            ControlCommand::GetQueue { respond } => {
                                // Collect queued messages from main runner with their target mission IDs
                                let mut queued: Vec<QueuedMessage> = queue
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
                                // Also collect queued messages from parallel runners
                                for (mid, runner) in parallel_runners.iter() {
                                    for qm in runner.queue.iter() {
                                        queued.push(QueuedMessage {
                                            id: qm.id,
                                            content: qm.content.clone(),
                                            agent: qm.agent.clone(),
                                            mission_id: Some(*mid),
                                            source: qm.source.clone(),
                                            inflight: false,
                                            queue_error: None,
                                        });
                                    }
                                }
                                let _ = respond.send(queued);
                            }
                            ControlCommand::RemoveFromQueue { message_id, respond } => {
                                let mut removed = false;

                                // Try to remove from main queue
                                let before_len = queue.len();
                                queue.retain(|(id, _, _, _, _)| *id != message_id);
                                if queue.len() < before_len {
                                    removed = true;
                                    // Emit event for main queue change
                                    let _ = events_tx.send(AgentEvent::Status {
                                        state: if running.is_some() {
                                            ControlRunState::Running
                                        } else {
                                            ControlRunState::Idle
                                        },
                                        queue_len: queue.len(),
                                        mission_id: if running.is_some() {
                                            running_mission_id
                                        } else {
                                            *current_mission.read().await
                                        },
                                    });
                                }

                                // Also try to remove from parallel runner queues.
                                // Emit a Status event for each affected mission so
                                // every client (other tabs, iOS) learns the queue
                                // changed — without this, only the deleting client
                                // ever updates its UI.
                                for (mid, runner) in parallel_runners.iter_mut() {
                                    if runner.remove_from_queue(message_id) {
                                        removed = true;
                                        tracing::info!("Removed message {} from parallel mission {}", message_id, mid);
                                        let _ = events_tx.send(AgentEvent::Status {
                                            state: if runner.is_running() {
                                                ControlRunState::Running
                                            } else {
                                                ControlRunState::Idle
                                            },
                                            queue_len: runner.queue.len(),
                                            mission_id: Some(*mid),
                                        });
                                    }
                                }

                                prune_empty_provisional_runners(&mut parallel_runners);
                                let _ = respond.send(removed);
                            }
                            ControlCommand::SendQueuedNow { message_id, respond } => {
                                let exists_in_queue = queue.iter().any(|(id, _, _, _, _)| *id == message_id)
                                    || parallel_runners
                                        .values()
                                        .any(|r| r.queue.iter().any(|qm| qm.id == message_id));
                                if !exists_in_queue {
                                    let _ = respond.send(Err("message not in queue".to_string()));
                                    continue;
                                }
                                let Some((mid, position, message)) = take_queued_by_id(
                                    message_id,
                                    running_mission_id,
                                    &mut queue,
                                    &mut parallel_runners,
                                ) else {
                                    let _ = respond.send(Ok(false));
                                    continue;
                                };
                                if host_followup_source(message.source.as_deref()) {
                                    if let Err(error) = dispatch_admission::admit_followup_locked(
                                        &control_hub,
                                        &mission_store,
                                        mid,
                                        &message.content,
                                    )
                                    .await
                                    {
                                        match position {
                                            QueuedAt::Main(index) => queue.insert(
                                                index.min(queue.len()),
                                                (
                                                    message.id,
                                                    message.content,
                                                    message.agent,
                                                    Some(mid),
                                                    message.source,
                                                ),
                                            ),
                                            QueuedAt::Runner(index) => {
                                                if let Some(runner) = parallel_runners.get_mut(&mid) {
                                                    runner
                                                        .queue
                                                        .insert(index.min(runner.queue.len()), message);
                                                }
                                            }
                                        }
                                        let _ = respond.send(Err(error));
                                        continue;
                                    }
                                }
                                let persisted = persist_control_queue_if_changed(
                                    &mission_store,
                                    &session_user_id,
                                    &queue,
                                    &parallel_runners,
                                    &recovered_consumed_user_messages,
                                    &mut last_persisted_queue,
                                )
                                .await;
                                if persisted.is_ok()
                                    && super::super::runners::live_session::deliver_now(
                                        mid,
                                        message.content.clone(),
                                    )
                                    .is_ok()
                                {
                                    let _ = events_tx.send(AgentEvent::UserMessage {
                                        id: message.id,
                                        content: message.content,
                                        queued: false,
                                        mission_id: Some(mid),
                                        source: message.source,
                                    });
                                    match position {
                                        QueuedAt::Main(_) => {
                                            let _ = events_tx.send(AgentEvent::Status {
                                                state: if running.is_some() {
                                                    ControlRunState::Running
                                                } else {
                                                    ControlRunState::Idle
                                                },
                                                queue_len: queue.len(),
                                                mission_id: Some(mid),
                                            });
                                        }
                                        QueuedAt::Runner(_) => {
                                            if let Some(runner) = parallel_runners.get(&mid) {
                                                let _ = events_tx.send(AgentEvent::Status {
                                                    state: if runner.is_running() {
                                                        ControlRunState::Running
                                                    } else {
                                                        ControlRunState::Idle
                                                    },
                                                    queue_len: runner.queue.len(),
                                                    mission_id: Some(mid),
                                                });
                                            }
                                        }
                                    }
                                    prune_empty_provisional_runners(&mut parallel_runners);
                                    let _ = respond.send(Ok(true));
                                    continue;
                                }
                                if let Err(error) = &persisted {
                                    tracing::warn!(
                                        mission_id = %mid,
                                        "Immediate mid-turn delivery skipped, queue could not be persisted: {error}"
                                    );
                                }
                                match position {
                                    QueuedAt::Main(index) => queue.insert(
                                        index.min(queue.len()),
                                        (
                                            message.id,
                                            message.content,
                                            message.agent,
                                            Some(mid),
                                            message.source,
                                        ),
                                    ),
                                    QueuedAt::Runner(index) => {
                                        if let Some(runner) = parallel_runners.get_mut(&mid) {
                                            runner.queue.insert(index.min(runner.queue.len()), message);
                                        }
                                    }
                                }
                                let _ = persist_control_queue_if_changed(
                                    &mission_store,
                                    &session_user_id,
                                    &queue,
                                    &parallel_runners,
                                    &recovered_consumed_user_messages,
                                    &mut last_persisted_queue,
                                )
                                .await;
                                let _ = respond.send(Ok(false));
                            }
                            ControlCommand::ClearQueue { mission_id, respond } => {
                                let main_mission_id = if running.is_some() {
                                    running_mission_id
                                } else {
                                    *current_mission.read().await
                                };

                                let mut cleared = 0usize;
                                match mission_id {
                                    Some(target) => {
                                        // Scoped clear: only drop messages targeting
                                        // this mission (main queue entries + that
                                        // mission's parallel-runner queue). Clearing
                                        // from one mission's view must not wipe other
                                        // missions' queues.
                                        let before_len = queue.len();
                                        queue.retain(|(_, _, _, target_mid, _)| *target_mid != Some(target));
                                        let main_removed = before_len - queue.len();
                                        cleared += main_removed;
                                        if main_removed > 0 {
                                            let _ = events_tx.send(AgentEvent::Status {
                                                state: if running.is_some() {
                                                    ControlRunState::Running
                                                } else {
                                                    ControlRunState::Idle
                                                },
                                                queue_len: queue.len(),
                                                mission_id: main_mission_id,
                                            });
                                        }
                                        // Clients filter Status events by the mission
                                        // they are viewing, so the main-queue event
                                        // above is invisible to a client focused on
                                        // `target` (unless target IS the main
                                        // mission). Emit a target-scoped Status
                                        // whenever anything was cleared for it.
                                        let mut target_status_sent = false;
                                        if let Some(runner) = parallel_runners.get_mut(&target) {
                                            let runner_cleared = runner.clear_queue();
                                            cleared += runner_cleared;
                                            if runner_cleared > 0 || main_removed > 0 {
                                                let _ = events_tx.send(AgentEvent::Status {
                                                    state: if runner.is_running() {
                                                        ControlRunState::Running
                                                    } else {
                                                        ControlRunState::Idle
                                                    },
                                                    queue_len: runner.queue.len(),
                                                    mission_id: Some(target),
                                                });
                                                target_status_sent = true;
                                            }
                                        }
                                        if main_removed > 0
                                            && !target_status_sent
                                            && main_mission_id != Some(target)
                                        {
                                            // No parallel runner for `target` and it
                                            // is not the main mission: it cannot be
                                            // running, but its viewers still need a
                                            // scoped event to refresh their queue.
                                            let _ = events_tx.send(AgentEvent::Status {
                                                state: ControlRunState::Idle,
                                                queue_len: 0,
                                                mission_id: Some(target),
                                            });
                                        }
                                        tracing::info!(
                                            "Cleared {} queued messages for mission {}",
                                            cleared, target
                                        );
                                    }
                                    None => {
                                        cleared = queue.len();
                                        queue.clear();

                                        // Also clear parallel runner queues, notifying
                                        // each affected mission's viewers.
                                        for (mid, runner) in parallel_runners.iter_mut() {
                                            let runner_cleared = runner.clear_queue();
                                            if runner_cleared > 0 {
                                                cleared += runner_cleared;
                                                let _ = events_tx.send(AgentEvent::Status {
                                                    state: if runner.is_running() {
                                                        ControlRunState::Running
                                                    } else {
                                                        ControlRunState::Idle
                                                    },
                                                    queue_len: 0,
                                                    mission_id: Some(*mid),
                                                });
                                            }
                                        }

                                        // Emit event to notify frontend (main queue)
                                        let _ = events_tx.send(AgentEvent::Status {
                                            state: if running.is_some() {
                                                ControlRunState::Running
                                            } else {
                                                ControlRunState::Idle
                                            },
                                            queue_len: 0,
                                            mission_id: main_mission_id,
                                        });

                                        tracing::info!("Cleared {} total queued messages (main + parallel)", cleared);
                                    }
                                }
                                prune_empty_provisional_runners(&mut parallel_runners);
                                let _ = respond.send(cleared);
                            }
                        }
                    }
                    // Handle agent-initiated mission status changes (from complete_mission tool)
                    mission_cmd = mission_cmd_rx.recv() => {
                        if let Some(cmd) = mission_cmd {
                            match cmd {
                                crate::tools::mission::MissionControlCommand::SetStatus { mission_id: id, status, summary } => {
                                    let new_status = match status {
                                        crate::tools::mission::MissionStatusValue::Completed => MissionStatus::Completed,
                                        crate::tools::mission::MissionStatusValue::Failed => MissionStatus::Failed,
                                        crate::tools::mission::MissionStatusValue::Blocked => MissionStatus::Blocked,
                                        crate::tools::mission::MissionStatusValue::NotFeasible => MissionStatus::NotFeasible,
                                    };
                                    let success = matches!(status, crate::tools::mission::MissionStatusValue::Completed);
                                    if new_status == MissionStatus::Completed
                                        && mission_has_active_automation(&mission_store, id).await
                                    {
                                        tracing::info!(
                                            "Skipping completion for mission {} because active automations are enabled",
                                            id
                                        );
                                        continue;
                                    }
                                    // Save the final tree before updating status
                                    if let Some(tree) = current_tree.read().await.clone() {
                                        if let Err(e) = mission_store.update_mission_tree(id, &tree).await {
                                            tracing::warn!("Failed to save mission tree: {}", e);
                                        } else {
                                            tracing::info!("Saved final tree for mission {}", id);
                                        }
                                    }

                                    // Capture the actor-owned generation before any status-write await.
                                    let execution = running_run.as_ref().filter(|run| run.mission_id == id).cloned()
                                        .or_else(|| parallel_runners.get(&id).and_then(|runner| runner.durable_run.clone()));
                                    if mission_store
                                        .update_mission_status(id, new_status)
                                        .await
                                        .is_ok()
                                    {
                                        maybe_schedule_mission_metadata_refresh_for_status(
                                            &mission_store,
                                            &events_tx,
                                            id,
                                            new_status,
                                        );
                                        // Generate and store mission summary
                                        if let Some(ref summary_text) = summary {
                                            // Extract key files from conversation (look for paths in assistant messages)
                                            let key_files: Vec<String> = history
                                                .iter()
                                                .filter(|(role, _)| role == "assistant")
                                                .flat_map(|(_, content)| extract_file_paths(content))
                                                .take(10)
                                                .collect();

                                            if let Err(e) = mission_store
                                                .insert_mission_summary(id, summary_text, &key_files, success)
                                                .await
                                            {
                                                tracing::warn!("Failed to store mission summary: {}", e);
                                            } else {
                                                tracing::info!("Stored mission summary for {}", id);
                                            }
                                        }

                                        let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                                            completion: Some(MissionCompletionSnapshot {
                                                result_summary: summary.clone(),
                                                terminal_reason: None,
                                                terminal_evidence: None,
                                            }),
                                            execution,
                                            mission_id: id,
                                            status: new_status,
                                            summary,
                                        });
                                        tracing::info!("Mission {} marked as {} by agent", id, new_status);
                                    }
                                }
                            }
                        }
                    }
                    finished = async {
                        match &mut running {
                            Some(handle) => Some(handle.await),
                            None => { queued_delivery_retry.tick().await; None }
                        }
                    }, if (running.is_some() || !queue.is_empty()) && !runner_force_abort_requested => {
                        if let Some(res) = finished {
                            // Save the running mission ID before clearing it - we need it for persist and auto-complete
                            // (current_mission can change if user clicks "New Mission" while task was running)
                            let completed_mission_id = running_mission_id;
                            let completed_message_id = running_message_id.take();
                            continuations::bind_turn(&mission_store, completed_mission_id, completed_message_id, std::mem::take(&mut running_execution_ids)).await;
                            let completed_cancellation_requested = running_cancel
                                .as_ref()
                                .is_some_and(CancellationToken::is_cancelled);
                            running = None;
                            running_cancel = None;
                            if let Some(mid) = running_mission_id {
                                release_local_mission_disk_if_not_holding(&mission_store, &config, mid)
                                    .await;
                            }
                            running_mission_id = None;
                            running_backend_id = None;
                            main_runner_activity = None;
                            main_runner_active_tool_calls
                                .store(0, std::sync::atomic::Ordering::Relaxed);
                            // Runner cleared itself; cancel the force-clear watchdog.
                            runner_force_clear_deadline = None;
                            let mut completed_terminal_reason = None;
                            let mut completed_terminal_evidence = None;
                            let mut completed_completion_confidence = None;
                            let mut completed_transport_failure = false;
                            let mut completed_grok_acp_transport_failure = false;
                            let mut completed_waiting_remote_job = false;
                            // Captured for the post-turn `grok_goal` sentinel hook (see
                            // `post_turn_handle_grok_goal`), which runs after this
                            // `match` closes — `agent_result` itself is out of scope
                            // by then. Empty string when the join errored.
                            let mut completed_agent_output = String::new();
                            let mut completed_execution_outcome = None;
                            // Set when the mission was parked until a usage limit
                            // resets: it must not be finalized as failed afterwards.
                            let mut completed_usage_limit_wait = false;
                            match res {
                                Ok((_mid, user_msg, mut agent_result)) => {
                                    maybe_recover_soft_llm_error(&mut agent_result);
                                    // Every account is at its usage limit: the mission
                                    // waits for the reset instead of failing, and the
                                    // turn's message says so.
                                    let usage_limit_wait = match completed_mission_id {
                                        Some(mission_id) => {
                                            usage_limit_wait::plan(&mission_store, mission_id, &agent_result)
                                                .await
                                        }
                                        None => None,
                                    };
                                    if let Some((_, wait)) = &usage_limit_wait {
                                        agent_result.output =
                                            usage_limit_wait::annotate_output(&agent_result.output, wait);
                                    }
                                    let completion_evidence =
                                        completion_evidence_for_agent_result(&agent_result);
                                    completed_terminal_reason = agent_result.terminal_reason;
                                    completed_terminal_evidence = agent_result.terminal_evidence.clone();
                                    completed_completion_confidence =
                                        Some(completion_evidence.completion_confidence);
                                    completed_transport_failure =
                                        is_transport_failure_evidence(&completion_evidence);
                                    completed_grok_acp_transport_failure =
                                        is_grok_acp_transport_failure(&agent_result);
                                    completed_agent_output = agent_result.output.clone();
                                    if let Some(run) = running_run.take() {
                                        let parked_job = mission_should_park_on_remote_build(
                                                &mission_store,
                                                &config.working_dir,
                                                run.mission_id,
                                            )
                                            .await;
                                        completed_waiting_remote_job = parked_job.is_some();
                                        let run_update = if let Some(job) = parked_job {
                                            park_scheduled_remote_execution(&mission_store, run.mission_id, completed_message_id, job).await;
                                            mission_store
                                                .heartbeat_mission_run(
                                                    run.run_id,
                                                    run.generation,
                                                    MissionExecutionState::WaitingRemoteJob,
                                                    None,
                                                )
                                                .await
                                        } else {
                                            let reason = agent_result
                                                .terminal_reason
                                                .map(|value| format!("{value:?}"));
                                            mission_store
                                                .finish_mission_run(
                                                run.run_id,
                                                run.generation,
                                                reason.as_deref(),
                                            )
                                                .await
                                        };
                                        if let Err(error) = run_update {
                                            tracing::warn!(
                                                mission_id = %run.mission_id,
                                                run_id = %run.run_id,
                                                waiting_remote_job = completed_waiting_remote_job,
                                                "Failed to settle main mission run: {error}"
                                            );
                                        }
                                        if completed_waiting_remote_job {
                                            if let Err(error) = mission_store
                                                .update_mission_status(run.mission_id, MissionStatus::Active)
                                                .await
                                            {
                                                tracing::warn!(mission_id = %run.mission_id, %error, "Failed to keep remote-wait mission active");
                                            } else {
                                                let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                                                    completion: None,
                                                    execution: None,
                                                    mission_id: run.mission_id,
                                                    status: MissionStatus::Active,
                                                    summary: Some("Waiting for durable remote validation".to_string()),
                                                });
                                            }
                                        }
                                    }
                                    // Only append assistant to local history if this mission is still the current mission.
                                    // Note: User message was already added before execution started.
                                    // If the user created a new mission mid-execution, history was cleared for that new mission,
                                    // and we don't want to contaminate it with the old mission's exchange.
                                    let current_mid = *current_mission.read().await;
                                    if completed_mission_id == current_mid {
                                        history.push(("assistant".to_string(), agent_result.output.clone()));
                                    }

                                    // Persist to mission using the actual completed mission ID
                                    // (not current_mission, which could have changed)
                                    //
                                    // IMPORTANT: We fetch existing history from DB and append, rather than
                                    // using the local `history` variable, because CreateMission may have
                                    // cleared `history` while this task was running. This prevents data loss.
                                    // Note: User message was already persisted before execution started.
                                    if let Some(mid) = completed_mission_id {
                                        match mission_store.get_mission(mid).await {
                                            Ok(Some(mission)) => {
                                                let mut entries = mission.history.clone();
                                                entries.push(MissionHistoryEntry {
                                                    role: "assistant".to_string(),
                                                    content: agent_result.output.clone(),
                                                });
                                                if let Err(e) =
                                                    mission_store.update_mission_history(mid, &entries).await
                                                {
                                                    tracing::warn!("Failed to persist mission history: {}", e);
                                                } else {
                                                    schedule_mission_metadata_refresh(
                                                        &mission_store,
                                                        &events_tx,
                                                        mid,
                                                        false,
                                                    );
                                                }
                                            }
                                            Ok(None) => {
                                                tracing::warn!("Mission {} not found for history append", mid);
                                            }
                                            Err(e) => {
                                                tracing::warn!(
                                                    "Failed to load mission {} for history append: {}",
                                                    mid,
                                                    e
                                                );
                                            }
                                        }
                                    }

                                    // P1 FIX: Auto-complete mission if agent execution ended in a terminal state
                                    // without an explicit complete_mission call.
                                    // This prevents missions from staying "active" forever after max iterations, stalls, etc.
                                    //
                                    // We use terminal_reason (structured enum) instead of substring matching to avoid
                                    // false positives when agent output legitimately contains words like "infinite loop".
                                    // We also check the current mission status from DB to handle:
                                    // - Explicit complete_mission calls (which update DB status)
                                    // - Parallel missions (each has its own DB status)
                                    if !completed_waiting_remote_job {
                                        if let Some((mission, wait)) = &usage_limit_wait {
                                            completed_usage_limit_wait = usage_limit_wait::park(
                                                &mission_store,
                                                &events_tx,
                                                mission,
                                                wait,
                                                &deferred_messages::strip(&user_msg),
                                            )
                                            .await;
                                        }
                                    }
                                    if !completed_waiting_remote_job && !completed_usage_limit_wait {
                                        if let Some(mission_id) = completed_mission_id {
                                        maybe_finalize_terminal_mission(
                                            &mission_store,
                                            &events_tx,
                                            mission_id,
                                            background_tasks
                                                .read()
                                                .await
                                                .get(&mission_id)
                                                .map_or(0, std::collections::HashMap::len),
                                            agent_result.terminal_reason,
                                            agent_result.terminal_evidence.as_deref(),
                                            Some(completion_evidence.completion_confidence),
                                            false,
                                            Some(agent_result.output.as_str()),
                                            "turn finished before follow-up enqueue",
                                        )
                                        .await;
                                        }
                                    }

                                    // Parse rich tags and validate referenced files
                                    let rich_tags = parse_rich_tags(&agent_result.output);
                                    let shared_files = if rich_tags.is_empty() {
                                        None
                                    } else {
                                        // Get workspace_id from mission for download URLs
                                        let ws_id = if let Some(mid) = completed_mission_id {
                                            mission_store
                                                .get_mission(mid)
                                                .await
                                                .ok()
                                                .flatten()
                                                .map(|m| m.workspace_id)
                                        } else {
                                            None
                                        };
                                        // Validate against the per-mission workspace directory, not the global
                                        // server working_dir. Agent-relative paths (./foo.png) should resolve
                                        // to the mission workspace.
                                        let validate_root = if let (Some(mid), Some(wsid)) =
                                            (completed_mission_id, ws_id)
                                        {
                                            workspaces
                                                .get(wsid)
                                                .await
                                                .map(|w| crate::workspace::mission_workspace_dir_for_workspace(&w, mid))
                                                .unwrap_or_else(|| config.working_dir.clone())
                                        } else {
                                            config.working_dir.clone()
                                        };
                                        let files = validate_rich_tags(
                                            &rich_tags,
                                            &validate_root,
                                            ws_id,
                                            completed_mission_id,
                                        )
                                        .await;
                                        if files.is_empty() { None } else { Some(files) }
                                    };

                                    // Mark failures as resumable so UI can show a resume button
                                    let resumable = !agent_result.success && completed_mission_id.is_some();
                                    let model_used = agent_result.model_used.clone();
                                    let _ = events_tx.send(AgentEvent::AssistantMessage {
                                        id: Uuid::new_v4(),
                                        content: agent_result.output.clone(),
                                        success: agent_result.success,
                                        cost_cents: agent_result.cost_cents,
                                        cost_source: agent_result.cost_source,
                                        usage: agent_result.usage.clone(),
                                        model: model_used.clone(),
                                        model_normalized: model_used
                                            .as_deref()
                                            .map(crate::cost::normalized_model),
                                        mission_id: completed_mission_id,
                                        shared_files,
                                        resumable,
                                        completion_evidence: Some(completion_evidence),
                                    });
                                    if !completed_waiting_remote_job {
                                        if let Some(mission_id) = completed_mission_id {
                                        completed_execution_outcome = Some((agent_result.success, if agent_result.success { None } else { Some(agent_result.terminal_reason.map(|r| format!("{:?}", r)).unwrap_or_else(|| "Agent execution failed".to_string())) }));

                                        close_mission_desktop_sessions(
                                            &mission_store,
                                            mission_id,
                                            &config.working_dir,
                                        )
                                        .await;
                                        }
                                    }
                                }
                                Err(e) => {
                                    if let Some(run) = running_run.take() {
                                        let _ = mission_store
                                            .finish_mission_run(
                                                run.run_id,
                                                run.generation,
                                                Some("runner_join_failed"),
                                            )
                                            .await;
                                    }
                                    let _ = events_tx.send(AgentEvent::Error {
                                        message: format!("Control session task join failed: {}", e),
                                        mission_id: completed_mission_id,
                                        resumable: completed_mission_id.is_some(), // Can resume if mission exists
                                    });
                                    if let Some(mission_id) = completed_mission_id {
                                        // Mark running automation executions as failed
                                        if let Err(e2) = mission_store
                                            .complete_turn_executions_for_mission(
                                                mission_id,
                                                completed_message_id,
                                                false,
                                                Some(format!("Task join failed: {}", e)),
                                            )
                                            .await
                                        {
                                            tracing::warn!(
                                                "Failed to complete running executions for mission {}: {}",
                                                mission_id,
                                                e2
                                            );
                                        }

                                        // Update mission status so it doesn't stay Active forever.
                                        // Mark as Failed (resumable) so the user can retry.
                                        if let Err(e) = mission_store
                                            .update_mission_status(mission_id, MissionStatus::Failed)
                                            .await
                                        {
                                            tracing::warn!("Failed to update mission status after join error: {}", e);
                                        } else {
                                            maybe_schedule_mission_metadata_refresh_for_status(
                                                &mission_store,
                                                &events_tx,
                                                mission_id,
                                                MissionStatus::Failed,
                                            );
                                            let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                                                completion: None,
                                                execution: None,
                                                mission_id,
                                                status: MissionStatus::Failed,
                                                summary: Some("Task execution failed unexpectedly".to_string()),
                                            });
                                        }
                                        close_mission_desktop_sessions(
                                            &mission_store,
                                            mission_id,
                                            &config.working_dir,
                                        )
                                        .await;
                                    }
                                }
                            }

                            // If the mission is idle now, enqueue any agent_finished automations after a short delay.
                            // Skip automations for transient infrastructure failures (auth errors,
                            // rate limits, capacity limits) — these aren't "the agent finished work",
                            // they're transient failures that the retry/recovery logic handles.
                            // Firing automations on these creates noisy retry loops.
                            if !completed_waiting_remote_job {
                                if let Some(mission_id) = completed_mission_id {
                                let mut transport_requeued = false;
                                if completed_transport_failure
                                    && !queue_has_pending_target_mission(&queue, mission_id)
                                    && reserve_transport_auto_resume(
                                        mission_store.as_ref(),
                                        &mut transport_auto_resumed_missions,
                                        mission_id,
                                        completed_grok_acp_transport_failure,
                                        completed_cancellation_requested,
                                    ).await
                                {
                                    let resume_message = transport_auto_resume_message_for_mission(
                                        mission_store.as_ref(),
                                        mission_id,
                                    )
                                    .await;
                                    let activation = activate_mission_id_for_message(
                                        &control_hub,
                                        &mission_store,
                                        &events_tx,
                                        mission_id,
                                        &resume_message,
                                    )
                                    .await;
                                    match activation {
                                        Ok(()) => {
                                            tracing::info!(
                                                %mission_id,
                                                "Auto-resuming mission after structured transport failure"
                                            );
                                            transport_requeued = true;
                                            queue.push_back((
                                                completed_message_id.unwrap_or_else(Uuid::new_v4),
                                                resume_message,
                                                None,
                                                Some(mission_id),
                                                Some("transport_auto_resume".to_string()),
                                            ));
                                        }
                                        Err(error) => {
                                            tracing::warn!(
                                                %mission_id,
                                                "Structured transport auto-resume could not reactivate mission: {error}"
                                            );
                                            let _ = events_tx.send(AgentEvent::Error {
                                                message: format!(
                                                    "Transport recovery could not reactivate mission {mission_id}: {error}"
                                                ),
                                                mission_id: Some(mission_id),
                                                resumable: true,
                                            });
                                        }
                                    }
                                }
                                if !transport_requeued {
                                    if let Some((success, error)) = completed_execution_outcome {
                                        if let Err(error) = mission_store.complete_turn_executions_for_mission(mission_id, completed_message_id, success, error).await {
                                            tracing::warn!(%mission_id, %error, "Failed to settle completed turn");
                                        }
                                    }
                                }
                                let suppress_finished_automation = matches!(
                                    completed_terminal_reason,
                                    Some(TerminalReason::NativeGoalStopped | TerminalReason::CodexContinuityRequired | TerminalReason::NativeContinuityRequired)
                                        | Some(TerminalReason::AuthError)
                                        | Some(TerminalReason::RateLimited)
                                        | Some(TerminalReason::CapacityLimited)
                                ) || completed_transport_failure;
                                let already_queued_for_mission = queue
                                    .iter()
                                    .any(|(_id, _msg, _agent, target_mid, _source)| *target_mid == Some(mission_id));

                                // Grok `/goal` post-turn: parse the sentinel from the
                                // assistant's last text and either disable the goal
                                // automation (terminal sentinel / budget exhausted /
                                // sentinel-missing streak) or bump the iteration
                                // counter. Must run BEFORE
                                // `agent_finished_automation_messages` so a Complete /
                                // Aborted disable takes effect on this very turn —
                                // otherwise the existing hook would still fire the
                                // continuation. Skipped on transient infra failures
                                // for the same reason regular automations are.
                                if !suppress_finished_automation {
                                    post_turn_handle_grok_goal(
                                        &mission_store,
                                        &events_tx,
                                        mission_id,
                                        &completed_agent_output,
                                        completed_terminal_reason,
                                    )
                                    .await;
                                }
                                if !already_queued_for_mission && !suppress_finished_automation {
                                    // Small delay so the UI can display the completion before restarting.
                                    tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
                                    let messages = agent_finished_automation_messages(
                                        &mission_store,
                                        mission_id,
                                        &library,
                                        &workspaces,
                                    )
                                    .await;
                                    enqueue_agent_finished_messages(&mut queue, messages);
                                }

                                if !completed_usage_limit_wait
                                    && !queue_has_pending_target_mission(&queue, mission_id)
                                {
                                    maybe_finalize_terminal_mission(
                                        &mission_store,
                                        &events_tx,
                                        mission_id,
                                        background_tasks
                                            .read()
                                            .await
                                            .get(&mission_id)
                                            .map_or(0, std::collections::HashMap::len),
                                        completed_terminal_reason,
                                        completed_terminal_evidence.as_deref(),
                                        completed_completion_confidence,
                                        true,
                                        Some(completed_agent_output.as_str()),
                                        "turn finished with no same-mission follow-up queued",
                                    )
                                    .await;
                                }
                                }
                            }
                        }

                        // Start next queued message, if any.
                        if let Some((mid, msg, per_msg_agent, msg_target_mid, msg_source)) = pop_next_runnable_control_queue(&mut queue, &mission_store).await {
                            if host_followup_source(msg_source.as_deref()) {
                                // The parallel delivery pump owns admission, capacity,
                                // run acquisition and rollback for every host follow-up.
                                queue.push_front((mid, msg, per_msg_agent, msg_target_mid, msg_source));
                                continue;
                            }
                            // Persist the dequeue before the awaits that start the run, so
                            // a crash here can't restore + re-run it.
                            if let Err(error) = persist_control_queue_if_changed(
                                &mission_store,
                                &session_user_id,
                                &queue,
                                &parallel_runners,
                                &recovered_consumed_user_messages,
                                &mut last_persisted_queue,
                            )
                            .await
                            {
                                queue.push_front((
                                    mid,
                                    msg,
                                    per_msg_agent,
                                    msg_target_mid,
                                    msg_source,
                                ));
                                tracing::warn!(
                                    "Queued delivery retained because dequeue persistence failed: {error}"
                                );
                                continue;
                            }
                            // Re-assert activation for every targeted delivery at
                            // dequeue. A message may have waited behind another turn
                            // while cancellation, acknowledgement, a background wait,
                            // or a controller restart changed the presentation row.
                            // Acquiring a new run without this check can produce an
                            // interrupted/acknowledged mission with a live run lease.
                            if queued_delivery_requires_activation(
                                msg_target_mid,
                                msg_source.as_deref(),
                            ) {
                                let activation = match msg_target_mid {
                                    Some(mission_id) => {
                                        activate_mission_id_for_message(
                                            &control_hub,
                                            &mission_store,
                                            &events_tx,
                                            mission_id,
                                            &msg,
                                        )
                                        .await
                                    }
                                    None => Err("transport auto-resume is missing mission_id".to_string()),
                                };
                                if let Err(error) = activation {
                                    queue.push_front((
                                        mid,
                                        msg,
                                        per_msg_agent,
                                        msg_target_mid,
                                        msg_source,
                                    ));
                                    if let Err(persist_error) = persist_control_queue_if_changed(
                                        &mission_store,
                                        &session_user_id,
                                        &queue,
                                        &parallel_runners,
                                        &recovered_consumed_user_messages,
                                        &mut last_persisted_queue,
                                    )
                                    .await
                                    {
                                        tracing::warn!(
                                            "Failed to restore queued delivery after activation rejection: {persist_error}"
                                        );
                                    }
                                    let _ = events_tx.send(AgentEvent::Error {
                                        message: format!(
                                            "Queued delivery could not activate its mission: {error}"
                                        ),
                                        mission_id: msg_target_mid,
                                        resumable: true,
                                    });
                                    tokio::time::sleep(tokio::time::Duration::from_millis(250)).await;
                                    continue;
                                }
                            }
                            // Acquire the durable run before publishing the message as
                            // started or appending it to history. If a stale run lease
                            // rejects acquisition, retain the exact queued delivery so
                            // an idempotent retry cannot be acknowledged without ever
                            // executing its turn.
                            let mission_id = msg_target_mid;
                            running_run = match acquire_execution_run(
                                &mission_store,
                                mission_id,
                                &format!("control:{session_user_id}"),
                            )
                            .await
                            {
                                Ok(run) => run,
                                Err(error) => {
                                    queue.push_front((
                                        mid,
                                        msg,
                                        per_msg_agent,
                                        msg_target_mid,
                                        msg_source,
                                    ));
                                    if let Err(persist_error) = persist_control_queue_if_changed(
                                        &mission_store,
                                        &session_user_id,
                                        &queue,
                                        &parallel_runners,
                                        &recovered_consumed_user_messages,
                                        &mut last_persisted_queue,
                                    )
                                    .await
                                    {
                                        tracing::warn!(
                                            "Failed to persist queued delivery after run lease rejection: {persist_error}"
                                        );
                                    }
                                    let _ = events_tx.send(AgentEvent::Error {
                                        message: format!("Mission run lease rejected: {error}"),
                                        mission_id,
                                        resumable: true,
                                    });
                                    set_and_emit_status(
                                        &status,
                                        &events_tx,
                                        ControlRunState::Idle,
                                        queue.len(),
                                        mission_id,
                                    )
                                    .await;
                                    tokio::time::sleep(tokio::time::Duration::from_millis(250)).await;
                                    continue;
                                }
                            };
                            set_and_emit_status(
                                &status,
                                &events_tx,
                                ControlRunState::Running,
                                queue.len(),
                                msg_target_mid,
                            ).await;
                            let _ = events_tx.send(AgentEvent::UserMessage { id: mid, content: msg.clone(), queued: false, mission_id: msg_target_mid, source: msg_source.clone() });

                            // Immediately persist user message so it's visible when loading mission
                            history.push(("user".to_string(), msg.clone()));
                            persist_mission_history_to(
                                &mission_store,
                                &events_tx,
                                msg_target_mid,
                                &history,
                            )
                                .await;

                            let cfg = config.clone();
                            let agent = Arc::clone(&root_agent);
                            let mcp_ref = Arc::clone(&mcp);
                            let workspaces_ref = Arc::clone(&workspaces);
                            let library_ref = Arc::clone(&library);
                            let events = events_tx.clone();
                            let tools_hub = Arc::clone(&tool_hub);
                            let status_ref = Arc::clone(&status);
                            let cancel = CancellationToken::new();
                            let hist_snapshot = history.clone();
                            let mission_ctrl = crate::tools::mission::MissionControl {
                                current_mission_id: Arc::clone(&current_mission),
                                cmd_tx: mission_cmd_tx.clone(),
                            };
                            let tree_ref = Arc::clone(&current_tree);
                            let progress_ref = Arc::clone(&progress);
                            running_cancel = Some(cancel.clone());
                            // Use the mission ID that was captured when message was queued.
                            // This prevents races where current_mission changes between
                            // queueing and execution.
                            let (workspace_id, model_override, model_effort, fast_mode, service_tier, mission_agent, backend_id, session_id, mission_config_profile, pr_readonly) = if let Some(mid) = mission_id {
                                match mission_store.get_mission(mid).await {
                                    Ok(Some(mission)) => (
                                        Some(mission.workspace_id),
                                        model_for_dispatch(&mission_store, &mission).await,
                                        mission.model_effort.clone(),
                                        mission.fast_mode,
                                        mission.service_tier,
                                        mission.agent.clone(),
                                        Some(mission.backend.clone()),
                                        mission.session_id.clone(),
                                        mission.config_profile.clone(),
                                        mission.project.tags.iter().any(|tag| tag == "pr-readonly"),
                                    ),
                                    Ok(None) => {
                                        tracing::warn!(
                                            "Mission {} not found while resolving workspace",
                                            mid
                                        );
                                        (None, None, None, false, None, None, None, None, None, false)
                                    }
                                    Err(e) => {
                                        tracing::warn!(
                                            "Failed to load mission {} for workspace: {}",
                                            mid,
                                            e
                                        );
                                        (None, None, None, false, None, None, None, None, None, false)
                                    }
                                }
                            } else {
                                (None, None, None, false, None, None, None, None, None, false)
                            };
                            // Per-message agent overrides mission agent
                            let agent_override = per_msg_agent.or(mission_agent);
                            running_mission_id = mission_id;
                            running_backend_id = backend_id.clone();
                            // Reset activity tracking when new task starts
                            main_runner_last_activity = std::time::Instant::now();
                            main_runner_activity = None;
                            main_runner_subtasks.clear();
                            main_runner_active_tool_calls
                                .store(0, std::sync::atomic::Ordering::Relaxed);
                            let user_id_for_turn = control_hub.identities.read().await.get(&session_user_id).cloned();
                            let turn_mission_store = mission_store.clone();
                            let session_update_run = running_run.as_ref().map(crate::api::mission_store::SessionUpdateRun::from);
                            running_message_id = Some(mid);
                            running_execution_ids = deferred_messages::execution_ids(mid, &msg, msg_source.as_deref());
                            running = Some(tokio::spawn(async move {
                                let result = crate::api::runners::SESSION_UPDATE_RUN.scope(session_update_run, run_single_control_turn(
                                    turn_mission_store,
                                    cfg,
                                    agent,
                                    mcp_ref,
                                    workspaces_ref,
                                    library_ref,
                                    events,
                                    tools_hub,
                                    status_ref,
                                    cancel,
                                    hist_snapshot,
                                    if msg_source.as_deref() == Some("scheduler") { deferred_messages::strip(&msg) } else { msg.clone() },
                                    Some(mission_ctrl),
                                    tree_ref,
                                    progress_ref,
                                    mission_id,
                                    workspace_id,
                                    backend_id,
                                    model_override,
                                    model_effort,
                                    fast_mode,
                                    service_tier,
                                    agent_override,
                                    session_id,
                                    false, // force_session_resume: continuation turn, not a resume
                                    mission_config_profile,
                                    user_id_for_turn,
                                    pr_readonly,
                                ))
                                .await;
                                (mid, msg, result)
                            }));
                        } else {
                            set_and_emit_status(&status, &events_tx, ControlRunState::Idle, 0, None).await;
                        }
                    }
                    // Poll parallel runners for completion
                    _ = parallel_poll.tick() => {
                        // A parked Claude session takes the next message queued for its
                        // mission on its stdin: starting another process would stop the
                        // background tasks it is waiting for. The message went through
                        // the usual admission, lease checks and persistence when queued.
                        for mid in super::super::runners::live_session::parked_missions() {
                            let is_main = running_mission_id == Some(mid);
                            let Some((position, message)) =
                                take_for_parked_session(mid, is_main, &mut queue, &mut parallel_runners)
                            else {
                                continue;
                            };
                            if host_followup_source(message.source.as_deref()) {
                                if let Err(error) = dispatch_admission::admit_followup(&control_hub, &mission_store, mid, &message.content).await {
                                    match position {
                                        QueuedAt::Main(index) => queue.insert(index, (message.id, message.content, message.agent, Some(mid), message.source)),
                                        QueuedAt::Runner(_) => { if let Some(runner) = parallel_runners.get_mut(&mid) { runner.queue.push_front(message); } }
                                    }
                                    tracing::debug!(%mid, %error, "Parked follow-up remains queued");
                                    continue;
                                }
                            }
                            // The dequeue is durable before the session reads the
                            // message, so a crash cannot replay it.
                            let persisted = persist_control_queue_if_changed(
                                &mission_store,
                                &session_user_id,
                                &queue,
                                &parallel_runners,
                                &recovered_consumed_user_messages,
                                &mut last_persisted_queue,
                            )
                            .await;
                            if persisted.is_ok()
                                && super::super::runners::live_session::deliver(mid, message.content.clone())
                                    .is_ok()
                            {
                                let _ = events_tx.send(AgentEvent::UserMessage {
                                    id: message.id,
                                    content: message.content,
                                    queued: false,
                                    mission_id: Some(mid),
                                    source: message.source,
                                });
                                continue;
                            }
                            if let Err(error) = &persisted {
                                tracing::warn!(mission_id = %mid, "Parked delivery skipped, the queue could not be persisted: {error}");
                            }
                            match position {
                                QueuedAt::Main(position) => queue.insert(
                                    position.min(queue.len()),
                                    (
                                        message.id,
                                        message.content,
                                        message.agent,
                                        Some(mid),
                                        message.source,
                                    ),
                                ),
                                QueuedAt::Runner(_) => {
                                    if let Some(runner) = parallel_runners.get_mut(&mid) {
                                        runner.queue.push_front(message);
                                    }
                                }
                            }
                            let _ = persist_control_queue_if_changed(
                                &mission_store,
                                &session_user_id,
                                &queue,
                                &parallel_runners,
                                &recovered_consumed_user_messages,
                                &mut last_persisted_queue,
                            )
                            .await;
                        }
                        if parallel_followup_retry.elapsed() >= std::time::Duration::from_secs(1) {
                            parallel_followup_retry = std::time::Instant::now();
                            // Promote durable host queues even while an unrelated main
                            // turn runs. Preserve each mission's FIFO and leave work on
                            // the main queue if its current turn or legacy entries own it.
                            let targets: HashSet<_> = queue.iter().filter(|entry| host_followup_source(entry.4.as_deref())).filter_map(|entry| entry.3).collect();
                            for mid in targets {
                                if (running.is_some() && running_mission_id == Some(mid))
                                    || queue.iter().find(|entry| entry.3 == Some(mid)).is_some_and(|entry| !host_followup_source(entry.4.as_deref())) { continue; }
                                if let std::collections::hash_map::Entry::Vacant(slot) = parallel_runners.entry(mid) {
                                    let Ok(Some(mission)) = mission_store.get_mission(mid).await else { continue; };
                                    let mut runner = super::super::mission_runner::MissionRunner::new(
                                        mid, mission.workspace_id, mission.agent.clone(), Some(mission.backend.clone()),
                                        mission.session_id.clone(), mission.config_profile.clone(),
                                        model_for_dispatch(&mission_store, &mission).await,
                                        mission.model_effort.clone(), mission.fast_mode,
        None,
        );
                                    runner.pr_readonly = mission.project.tags.iter().any(|tag| tag == "pr-readonly");
                                    runner.working_directory = mission.working_directory.clone();
                                    runner.user = control_hub.identities.read().await.get(&session_user_id).cloned();
                                    runner.history.extend(mission.history.iter().map(|entry| (entry.role.clone(), entry.content.clone())));
                                    slot.insert(runner);
                                }
                                let runner = parallel_runners.get_mut(&mid).unwrap();
                                if runner.cancellation_requested() { continue; }
                                let mut legacy_precedes = false;
                                queue.retain(|entry| {
                                    if entry.3 == Some(mid) && !host_followup_source(entry.4.as_deref()) { legacy_precedes = true; }
                                    if entry.3 == Some(mid) && !legacy_precedes {
                                        runner.queue_message(entry.0, entry.1.clone(), entry.2.clone(), entry.4.clone());
                                        false
                                    } else { true }
                                });
                            }

                            let mut ready = Vec::new();
                            let max_parallel = crate::settings::max_parallel_missions_cached_or(config.max_parallel_missions);
                            let occupied = parallel_runners.values().filter(|runner| runner.is_running()).count() + usize::from(running.is_some());
                            let available = max_parallel.saturating_sub(occupied);
                            for (mid, runner) in parallel_runners.iter_mut() {
                                if ready.len() >= available { break; }
                                match prepare_host_parallel_followup(&control_hub, &mission_store, &events_tx, runner, &format!("control:{session_user_id}")).await {
                                    Ok(Some(previous)) => ready.push((*mid, previous)),
                                    Ok(None) => {},
                                    Err(error) => tracing::warn!(mission_id = %mid, "Queued parallel delivery deferred: {error}"),
                                }
                            }
                            if !ready.is_empty() {
                                let persisted = persist_control_queue_if_changed(&mission_store, &session_user_id, &queue, &parallel_runners, &recovered_consumed_user_messages, &mut last_persisted_queue).await.is_ok();
                                for (mid, (previous, deferred_goal)) in ready {
                                    let runner = parallel_runners.get_mut(&mid).unwrap();
                                    if persisted {
                                        runner.start_next(config.clone(), Arc::clone(&root_agent), Arc::clone(&mcp), Arc::clone(&workspaces), library.clone(), events_tx.clone(), Arc::clone(&tool_hub), Arc::clone(&status), mission_cmd_tx.clone(), Arc::new(RwLock::new(Some(mid))), secrets.clone());
                                    } else {
                                        runner.finish_durable_run(&mission_store, Some("queued_snapshot_persist_failed")).await;
                                        if let Err(error) = rollback_host_parallel_followup(&mission_store, &events_tx, runner, &previous, deferred_goal).await {
                                            tracing::warn!(mission_id = %mid, "Failed to restore queued parallel delivery: {error}");
                                        }
                                    }
                                }
                            }
                        }
                        let mut completed_missions = Vec::new();

                        for (mission_id, runner) in parallel_runners.iter_mut() {
                            let completed_message_id = runner.inflight_message().map(|message| message.id);
                            let completed_execution_ids = runner.inflight_message().map(|message| deferred_messages::execution_ids(message.id, &message.content, message.source.as_deref())).unwrap_or_default();
                            if runner.force_clear_cancelled_if_due() {
                                continuations::bind_turn(&mission_store, Some(*mission_id), completed_message_id, completed_execution_ids).await;
                                tracing::warn!(
                                    mission_id = %mission_id,
                                    "Force-aborting stuck parallel runner after cancellation grace period"
                                );
                                let kill_reason = cancel_timeout_interrupt_reason();
                                runner
                                    .finish_durable_run(
                                        &mission_store,
                                        Some(kill_reason),
                                    )
                                    .await;
                                if let Err(error) = mission_store
                                    .update_mission_status_with_reason(
                                        *mission_id,
                                        MissionStatus::Interrupted,
                                        Some(kill_reason),
                                    )
                                    .await
                                {
                                    tracing::warn!(
                                        mission_id = %mission_id,
                                        "Failed to mark force-cleared parallel mission interrupted: {error}"
                                    );
                                } else {
                                    maybe_schedule_mission_metadata_refresh_for_status(
                                        &mission_store,
                                        &events_tx,
                                        *mission_id,
                                        MissionStatus::Interrupted,
                                    );
                                    let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                                        completion: None,
                                        execution: None,
                                        mission_id: *mission_id,
                                        status: MissionStatus::Interrupted,
                                        summary: Some(
                                            "Cancel timed out; force-aborted stuck parallel runner."
                                                .to_string(),
                                        ),
                                    });
                                }
                                if let Err(error) = mission_store
                                    .complete_turn_executions_for_mission(
                                        *mission_id,
                                        completed_message_id,
                                        false,
                                        Some(
                                            "Force-aborted stuck parallel runner after cancel timed out"
                                                .to_string(),
                                        ),
                                    )
                                    .await
                                {
                                    tracing::warn!(
                                        mission_id = %mission_id,
                                        "Failed to complete parallel executions on force-clear: {error}"
                                    );
                                }
                                completed_missions.push(*mission_id);
                                continue;
                            }
                            if runner.check_finished() {
                                continuations::bind_turn(&mission_store, Some(*mission_id), completed_message_id, completed_execution_ids).await;
                                if let Some((_msg_id, user_msg, mut result)) = runner.poll_completion().await {
                                    maybe_recover_soft_llm_error(&mut result);
                                    // Same as the main runner: a usage limit on every
                                    // account makes the mission wait for the reset.
                                    let usage_limit_wait =
                                        usage_limit_wait::plan(&mission_store, *mission_id, &result).await;
                                    if let Some((_, wait)) = &usage_limit_wait {
                                        result.output =
                                            usage_limit_wait::annotate_output(&result.output, wait);
                                    }
                                    let durable_terminal_reason = result
                                        .terminal_reason
                                        .map(|reason| format!("{reason:?}"));
                                    let parked_job = mission_should_park_on_remote_build(
                                        &mission_store,
                                        &config.working_dir,
                                        *mission_id,
                                    )
                                    .await;
                                    let waiting_remote_job = parked_job.is_some();
                                    if let Some(job) = parked_job {
                                        park_scheduled_remote_execution(&mission_store, *mission_id, completed_message_id, job).await;
                                        if let Some(run) = runner.durable_run.as_ref() {
                                            if let Err(error) = mission_store
                                                .heartbeat_mission_run(
                                                    run.run_id,
                                                    run.generation,
                                                    MissionExecutionState::WaitingRemoteJob,
                                                    None,
                                                )
                                                .await
                                            {
                                                tracing::warn!(mission_id = %mission_id, run_id = %run.run_id, %error, "Failed to park parallel mission on remote build");
                                            }
                                        }
                                        if let Err(error) = mission_store
                                            .update_mission_status(*mission_id, MissionStatus::Active)
                                            .await
                                        {
                                            tracing::warn!(mission_id = %mission_id, %error, "Failed to keep parallel remote-wait mission active");
                                        } else {
                                            let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                                                completion: None,
                                                execution: None,
                                                mission_id: *mission_id,
                                                status: MissionStatus::Active,
                                                summary: Some("Waiting for durable remote validation".to_string()),
                                            });
                                        }
                                    } else {
                                        runner
                                            .finish_durable_run(
                                                &mission_store,
                                                durable_terminal_reason.as_deref(),
                                            )
                                            .await;
                                    }
                                    let completion_evidence = completion_evidence_for_agent_result(&result);
                                    tracing::info!(
                                        "Parallel mission {} completed (success: {}, cost: {} cents)",
                                        mission_id, result.success, result.cost_cents
                                    );

                                    // Parse rich tags and validate referenced files
                                    let rich_tags = parse_rich_tags(&result.output);
                                    let shared_files = if rich_tags.is_empty() {
                                        None
                                    } else {
                                        let ws_id = mission_store
                                            .get_mission(*mission_id)
                                            .await
                                            .ok()
                                            .flatten()
                                            .map(|m| m.workspace_id);
                                        let validate_root = if let Some(wsid) = ws_id {
                                            workspaces
                                                .get(wsid)
                                                .await
                                                .map(|w| crate::workspace::mission_workspace_dir_for_workspace(&w, *mission_id))
                                                .unwrap_or_else(|| config.working_dir.clone())
                                        } else {
                                            config.working_dir.clone()
                                        };
                                        let files = validate_rich_tags(
                                            &rich_tags,
                                            &validate_root,
                                            ws_id,
                                            Some(*mission_id),
                                        )
                                        .await;
                                        if files.is_empty() { None } else { Some(files) }
                                    };

                                    // Emit completion event with mission_id
                                    // Mark failures as resumable
                                    let resumable = !result.success;
                                    let _ = events_tx.send(AgentEvent::AssistantMessage {
                                        // Use a unique id so we don't overwrite the user_message event
                                        // (event_id is used for de-dupe in the SQLite event logger).
                                        id: Uuid::new_v4(),
                                        content: result.output.clone(),
                                        success: result.success,
                                        cost_cents: result.cost_cents,
                                        cost_source: result.cost_source,
                                        usage: result.usage.clone(),
                                        model: result.model_used.clone(),
                                        model_normalized: result
                                            .model_used
                                            .as_deref()
                                            .map(crate::cost::normalized_model),
                                        mission_id: Some(*mission_id),
                                        shared_files,
                                        resumable,
                                        completion_evidence: Some(completion_evidence.clone()),
                                    });

                                    // Persist history for this mission
                                    let entries: Vec<MissionHistoryEntry> = runner
                                        .history
                                        .iter()
                                        .map(|(role, content)| MissionHistoryEntry {
                                            role: role.clone(),
                                            content: content.clone(),
                                        })
                                        .collect();
                                    persist_mission_history_and_schedule_metadata_refresh(
                                        &mission_store,
                                        &events_tx,
                                        *mission_id,
                                        &entries,
                                    )
                                    .await;

                                    if waiting_remote_job {
                                        tracing::info!(
                                            mission_id = %mission_id,
                                            "Parallel mission turn parked on durable remote validation"
                                        );
                                        continue;
                                    }

                                    // Check if we should enqueue agent_finished automations.
                                    // Skip for transient infrastructure failures (auth, rate limit,
                                    // capacity) to avoid noisy retry loops.
                                    let suppress_finished_automation = matches!(
                                        result.terminal_reason,
                                        Some(TerminalReason::NativeGoalStopped | TerminalReason::CodexContinuityRequired | TerminalReason::NativeContinuityRequired)
                                            | Some(TerminalReason::AuthError)
                                            | Some(TerminalReason::RateLimited)
                                            | Some(TerminalReason::CapacityLimited)
                                    ) || is_transport_failure_evidence(&completion_evidence);
                                    let cancellation_requested = runner.cancellation_requested();
                                    let was_queue_empty = runner.queue.is_empty();
                                    let mut transport_requeued = false;
                                    if suppress_finished_automation
                                        && is_transport_failure_evidence(&completion_evidence)
                                        && !cancellation_requested
                                        && was_queue_empty
                                        && reserve_transport_auto_resume(
                                            mission_store.as_ref(),
                                            &mut transport_auto_resumed_missions,
                                            *mission_id,
                                            is_grok_acp_transport_failure(&result),
                                            cancellation_requested,
                                        ).await
                                    {
                                        tracing::info!(
                                            mission_id = %mission_id,
                                            "Auto-resuming parallel mission after structured transport failure"
                                        );
                                        let resume_message = transport_auto_resume_message_for_mission(
                                            mission_store.as_ref(),
                                            *mission_id,
                                        )
                                        .await;
                                        transport_requeued = true;
                                        runner.queue_message(
                                            completed_message_id.unwrap_or_else(Uuid::new_v4),
                                            resume_message,
                                            None,
                                            Some("transport_auto_resume".to_string()),
                                        );
                                    }
                                    // Update automation executions based on agent outcome
                                    if !transport_requeued {
                                        let error_msg = if result.success {
                                            None
                                        } else {
                                            Some(
                                                result.terminal_reason
                                                    .map(|r| format!("{:?}", r))
                                                    .unwrap_or_else(|| "Agent execution failed".to_string()),
                                            )
                                        };
                                        if let Err(e) = mission_store
                                            .complete_turn_executions_for_mission(
                                                *mission_id,
                                                completed_message_id,
                                                result.success,
                                                error_msg,
                                            )
                                            .await
                                        {
                                            tracing::warn!(
                                                "Failed to complete running executions for parallel mission {}: {}",
                                                mission_id,
                                                e
                                            );
                                        }
                                    }

                                    // Grok /goal sentinel hook for the parallel-runner
                                    // path. Same contract as the main-session hook
                                    // above: runs before the AgentFinished automations
                                    // so a terminal sentinel disables the loop on this
                                    // turn rather than after one extra continuation
                                    // fire. (See `post_turn_handle_grok_goal`.)
                                    if !suppress_finished_automation {
                                        post_turn_handle_grok_goal(
                                            &mission_store,
                                            &events_tx,
                                            *mission_id,
                                            &result.output,
                                            result.terminal_reason,
                                        )
                                        .await;
                                    }
                                    if was_queue_empty
                                        && !suppress_finished_automation
                                        && !cancellation_requested
                                    {
                                        // Small delay so the UI can display the completion before restarting.
                                        tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
                                        let messages = agent_finished_automation_messages(
                                            &mission_store,
                                            *mission_id,
                                            &library,
                                            &workspaces,
                                        )
                                        .await;
                                        for message in messages {
                                            if message.target_mission_id == *mission_id {
                                                runner.queue_message(Uuid::new_v4(), message.content, None, None);
                                                continue;
                                            }

                                            // Queue for targeted mission on the main runner if it is not
                                            // the current parallel mission.
                                            queue.push_back((
                                                Uuid::new_v4(),
                                                message.content,
                                                None,
                                                Some(message.target_mission_id),
                                                Some("automation".to_string()),
                                            ));
                                        }
                                    }

                                    // New inbox deliveries acquire their claims in the retry path above.
                                    if runner.queue.front().is_some_and(|message| host_followup_source(message.source.as_deref())) {
                                        continue;
                                    }
                                    // Always try to start next queued message (if any)
                                    if !runner.is_running() {
                                        // Refresh settings together with their backend-specific
                                        // session identity before the next turn. The in-flight
                                        // turn retains its original settings.
                                        if let Ok(Some(m)) = mission_store.get_mission(*mission_id).await {
                                            runner.backend_id = m.backend;
                                            runner.agent_override = m.agent;
                                            runner.model_override = m.model_override;
                                            runner.model_effort = m.model_effort;
                                            runner.fast_mode = m.fast_mode;
                                            runner.service_tier=m.service_tier;
                                            runner.config_profile = m.config_profile;
                                            if m.session_id != runner.session_id {
                                                tracing::debug!(
                                                    mission_id = %mission_id,
                                                    old = ?runner.session_id,
                                                    new = ?m.session_id,
                                                    "Refreshed runner session_id from store"
                                                );
                                                runner.session_id = m.session_id;
                                            }
                                        }
                                        let next_content = runner
                                            .inflight_message()
                                            .or_else(|| runner.queue.front())
                                            .map(|message| message.content.clone());
                                        if let Some(next_content) = next_content {
                                            if let Err(error) = activate_mission_id_for_message(
                                                &control_hub,
                                                &mission_store,
                                                &events_tx,
                                                *mission_id,
                                                &next_content,
                                            )
                                            .await
                                            {
                                                tracing::warn!(
                                                    mission_id = %mission_id,
                                                    "Failed to activate mission for its next queued turn: {error}"
                                                );
                                                let _ = events_tx.send(AgentEvent::Error {
                                                    message: format!(
                                                        "Queued delivery could not activate its mission: {error}"
                                                    ),
                                                    mission_id: Some(*mission_id),
                                                    resumable: true,
                                                });
                                                continue;
                                            }
                                        }
                                        if let Err(error) = runner
                                            .acquire_durable_run(
                                                &mission_store,
                                                &format!("control:{session_user_id}"),
                                            )
                                            .await
                                        {
                                            tracing::warn!(
                                                mission_id = %mission_id,
                                                "Failed to acquire next mission run lease: {error}"
                                            );
                                            let _ = events_tx.send(AgentEvent::Error {
                                                message: format!("Mission run lease rejected: {error}"),
                                                mission_id: Some(*mission_id),
                                                resumable: true,
                                            });
                                            completed_missions.push(*mission_id);
                                            continue;
                                        }
                                        let started = runner.start_next(
                                            config.clone(),
                                            Arc::clone(&root_agent),
                                            Arc::clone(&mcp),
                                            Arc::clone(&workspaces),
                                            library.clone(),
                                            events_tx.clone(),
                                            Arc::clone(&tool_hub),
                                            Arc::clone(&status),
                                            mission_cmd_tx.clone(),
                                            Arc::new(RwLock::new(Some(*mission_id))),
                                            secrets.clone(),
                                        );

                                        // If no queued messages, update status and mark for cleanup
                                        let parked = match &usage_limit_wait {
                                            Some((mission, wait)) if !started && !waiting_remote_job => {
                                                usage_limit_wait::park(
                                                    &mission_store,
                                                    &events_tx,
                                                    mission,
                                                    wait,
                                                    &deferred_messages::strip(&user_msg),
                                                )
                                                .await
                                            }
                                            _ => false,
                                        };
                                        if parked {
                                            completed_missions.push(*mission_id);
                                        } else if !started {
                                            maybe_finalize_terminal_mission(
                                                &mission_store,
                                                &events_tx,
                                                *mission_id,
                                                background_tasks
                                                    .read()
                                                    .await
                                                    .get(mission_id)
                                                    .map_or(0, std::collections::HashMap::len),
                                                result.terminal_reason,
                                                result.terminal_evidence.as_deref(),
                                                Some(completion_evidence.completion_confidence),
                                                true,
                                                Some(result.output.as_str()),
                                                "parallel turn finished with no follow-up queued",
                                            )
                                            .await;
                                            // Task-board settle hook: if this mission is a
                                            // board worker, persist the outcome and notify
                                            // the boss. No-op otherwise.
                                            board::on_worker_settled(
                                                &mission_store,
                                                *mission_id,
                                                &result.output,
                                                result.terminal_reason,
                                                result.success,
                                            )
                                            .await;
                                            completed_missions.push(*mission_id);
                                        }
                                    }
                                }
                            }
                        }

                        // Remove completed runners and clean up their desktop sessions
                        for mid in completed_missions {
                            parallel_runners.remove(&mid);
                            release_local_mission_disk_if_not_holding(&mission_store, &config, mid).await;
                            close_mission_desktop_sessions(
                                &mission_store,
                                mid,
                                &config.working_dir,
                            )
                            .await;
                            tracing::info!("Parallel mission {} removed from runners", mid);
                        }

                        // Task-board scheduler: spawn workers for ready tasks and
                        // sweep zombies. Throttled — store scans on every 100ms tick
                        // would hammer sqlite for nothing.
                        if last_board_pass.elapsed() >= BOARD_PASS_INTERVAL {
                            last_board_pass = tokio::time::Instant::now();
                            // Missions actively executing a turn (parallel runners +
                            // the main session), so the scheduler won't wake a busy boss.
                            let mut running_ids: std::collections::HashSet<Uuid> = parallel_runners
                                .iter()
                                .filter(|(_, r)| r.is_running())
                                .map(|(id, _)| *id)
                                .collect();
                            if running.is_some() {
                                if let Some(mid) = running_mission_id {
                                    running_ids.insert(mid);
                                }
                            }
                            let snapshot = board::RunnerSnapshot {
                                present: parallel_runners.keys().copied().collect(),
                                running_ids,
                                running_count: parallel_runners
                                    .values()
                                    .filter(|r| r.is_running())
                                    .count(),
                                main_running: running.is_some(),
                            };
                            let max_parallel = crate::settings::max_parallel_missions_cached_or(
                                config.max_parallel_missions,
                            );
                            board::scheduler_pass(
                                Some(&control_hub),
                                &mission_store,
                                &self_cmd_tx,
                                &snapshot,
                                max_parallel,
                                &mut board_wake_state,
                                &board_outbox_inflight,
                            )
                            .await;
                        }

                        // FLEET-001 scheduling dispatch: expire past-deadline scheduled
                        // missions, then start the highest-priority dispatchable one when
                        // the main session is idle. Throttled like the board pass.
                        if last_scheduler_pass.elapsed() >= SCHEDULER_PASS_INTERVAL {
                            last_scheduler_pass = tokio::time::Instant::now();
                            // Drop cooldown records that have aged out so a still-Pending
                            // (dropped) mission becomes eligible for retry.
                            scheduler_inflight
                                .retain(|_, at| at.elapsed() < SCHEDULER_DISPATCH_COOLDOWN);
                            match mission_store.get_scheduled_pending_missions().await {
                                Ok(pending) => {
                                    let now = chrono::Utc::now();
                                    // 1. Expire any scheduled mission whose deadline elapsed
                                    //    before it ever dispatched. Missions still within the
                                    //    dispatch cooldown are skipped (not added to `live`) so
                                    //    a slow/lost start can't trigger a duplicate dispatch.
                                    let mut live: Vec<Mission> = Vec::with_capacity(pending.len());
                                    for m in pending {
                                        if m.is_past_deadline(now) {
                                            tracing::info!(
                                                mission_id = %m.id,
                                                deadline = ?m.scheduling.deadline,
                                                "Scheduler: expiring scheduled mission past deadline"
                                            );
                                            let _ = mission_store.set_deferred_goal(m.id, None).await;
                                            if let Err(e) = mission_store
                                                .update_mission_status_with_reason(
                                                    m.id,
                                                    MissionStatus::Failed,
                                                    Some("deadline_exceeded"),
                                                )
                                                .await
                                            {
                                                tracing::warn!(
                                                    mission_id = %m.id,
                                                    "Scheduler: failed to expire mission: {e}"
                                                );
                                            } else {
                                                maybe_schedule_mission_metadata_refresh_for_status(
                                                    &mission_store,
                                                    &events_tx,
                                                    m.id,
                                                    MissionStatus::Failed,
                                                );
                                                let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                                                    completion: None,
                                                    execution: None,
                                                    mission_id: m.id,
                                                    status: MissionStatus::Failed,
                                                    summary: Some(
                                                        "Scheduled mission expired: deadline passed before dispatch"
                                                            .to_string(),
                                                    ),
                                                });
                                            }
                                        } else if scheduler_inflight.contains_key(&m.id) {
                                            // A dispatch for this mission is still settling;
                                            // skip until the cooldown record ages out.
                                        } else {
                                            live.push(m);
                                        }
                                    }
                                    // 2. Dispatch the next runnable mission when there is spare
                                    //    concurrency. The targeted scheduler message starts a
                                    //    parallel runner (Case 2, explicit target => force
                                    //    parallel), which DROPS at capacity — so mirror its check
                                    //    (main + parallel < max_parallel) rather than requiring the
                                    //    main session to be idle, otherwise eligible scheduled
                                    //    missions stall behind a busy main runner.
                                    let parallel_running = parallel_runners
                                        .values()
                                        .filter(|r| r.is_running())
                                        .count();
                                    let total_running =
                                        parallel_running + if running.is_some() { 1 } else { 0 };
                                    let max_parallel = crate::settings::max_parallel_missions_cached_or(
                                        config.max_parallel_missions,
                                    );
                                    if total_running < max_parallel {
                                        if let Some(next) =
                                            super::super::mission_store::select_next_runnable_mission(&live, now)
                                        {
                                            let mission_id = next.id;
                                            let priority = next.scheduling.priority;
                                            // A non-terminal run means another owner
                                            // (a remote job observer, a runner that has
                                            // not settled yet) already executes this
                                            // mission. Dispatching a local runner on
                                            // top of it would either be rejected by
                                            // the run lease or, worse, duplicate the
                                            // prompt. Fail closed on a store error too.
                                            let execution_unowned = match mission_store
                                                .get_active_mission_run(mission_id)
                                                .await
                                            {
                                                Ok(None) => true,
                                                Ok(Some(run)) => {
                                                    tracing::warn!(
                                                        mission_id = %mission_id,
                                                        owner = %run.owner_actor_id,
                                                        state = ?run.execution_state,
                                                        "Scheduler: mission execution is already owned; not starting a local runner"
                                                    );
                                                    scheduler_inflight.insert(
                                                        mission_id,
                                                        tokio::time::Instant::now(),
                                                    );
                                                    false
                                                }
                                                Err(e) => {
                                                    tracing::warn!(
                                                        mission_id = %mission_id,
                                                        "Scheduler: run ownership unreadable; deferring dispatch: {e}"
                                                    );
                                                    false
                                                }
                                            };
                                            if !execution_unowned {
                                                // Skip this pass; the cooldown record
                                                // (or the next pass) re-evaluates.
                                            } else if let Ok(Some(goal)) =
                                                mission_store.get_deferred_goal(mission_id).await
                                            {
                                                // Deliberately do NOT clear the goal here. The
                                                // Pending->Active transition that the dispatched
                                                // message triggers is what removes the mission from
                                                // `get_scheduled_pending_missions` (status filter),
                                                // so it can't be re-dispatched. Leaving the goal in
                                                // place means a rare dispatch drop (capacity race)
                                                // simply retries on the next pass instead of losing
                                                // the scheduled work.
                                                let (ack_tx, _ack_rx) = tokio::sync::oneshot::channel();
                                                match self_cmd_tx.try_send(ControlCommand::UserMessage {
                                                    id: Uuid::new_v4(),
                                                    content: goal,
                                                    agent: None,
                                                    target_mission_id: Some(mission_id),
                                                    strict: false,
                                                    source: Some("scheduler".to_string()),
                                                    respond: ack_tx,
                                                }) {
                                                    Ok(()) => {
                                                        // Record the dispatch so the next passes
                                                        // skip this mission until it flips to
                                                        // Active (or the cooldown lets a dropped
                                                        // start retry).
                                                        scheduler_inflight.insert(
                                                            mission_id,
                                                            tokio::time::Instant::now(),
                                                        );
                                                        tracing::info!(
                                                            mission_id = %mission_id,
                                                            priority,
                                                            "Scheduler: dispatching scheduled mission"
                                                        );
                                                    }
                                                    Err(e) => tracing::warn!(
                                                        mission_id = %mission_id,
                                                        "Scheduler: dispatch enqueue failed; will retry: {e}"
                                                    ),
                                                }
                                            }
                                        }
                                    }
                                }
                                Err(e) => {
                                    tracing::warn!(
                                        "Scheduler: failed to list scheduled pending missions: {e}"
                                    );
                                }
                            }
                        }
                    }
                    // Force-reap a runner whose cancel was fired but whose
                    // JoinHandle never resolved within the grace window. See
                    // `runner_force_clear_deadline` for context.
                    _ = async {
                        match runner_force_clear_deadline {
                            Some(t) => tokio::time::sleep_until(t).await,
                            None => std::future::pending::<()>().await,
                        }
                    }, if runner_force_clear_deadline.is_some() && running.is_some() => {
                        let stuck_mid = running_mission_id;
                        let still_progressing = !runner_force_abort_requested && (main_runner_active_tool_calls
                            .load(std::sync::atomic::Ordering::Relaxed)
                            > 0
                            || main_runner_last_activity.elapsed()
                                < super::super::controller_honesty::CANCEL_TIMEOUT_FRESH_PROGRESS);
                        if still_progressing {
                            tracing::info!(
                                mission_id = ?stuck_mid,
                                "Deferring cancel-timeout force-clear: runner still has fresh progress"
                            );
                            runner_force_clear_deadline = Some(
                                tokio::time::Instant::now() + RUNNER_FORCE_CLEAR_GRACE,
                            );
                        } else {
                        tracing::warn!(
                            mission_id = ?stuck_mid,
                            "Force-aborting stuck runner: cancel fired but JoinHandle never resolved within {}s",
                            RUNNER_FORCE_CLEAR_GRACE.as_secs()
                        );
                        if let Some(handle) = running.as_ref() {
                            if !handle.is_finished() {
                                handle.abort();
                                runner_force_abort_requested = true;
                                runner_force_clear_deadline = Some(tokio::time::Instant::now() + std::time::Duration::from_millis(100));
                                // Preserve the runner and its durable ownership until
                                // the abort finishes; continue servicing refusals.
                                continue;
                            }
                        }
                        continuations::bind_turn(&mission_store, stuck_mid, running_message_id, std::mem::take(&mut running_execution_ids)).await;
                        running = None;
                        runner_force_abort_requested = false;
                        running_cancel = None;
                        running_mission_id = None;
                        running_backend_id = None;
                        main_runner_activity = None;
                        main_runner_active_tool_calls
                            .store(0, std::sync::atomic::Ordering::Relaxed);
                        runner_force_clear_deadline = None;
                        if let Some(run) = running_run.take() {
                            let _ = mission_store
                                .finish_mission_run(
                                    run.run_id,
                                    run.generation,
                                    Some(cancel_timeout_interrupt_reason()),
                                )
                                .await;
                        }
                        if let Some(mid) = stuck_mid {
                            // Mark mission as Interrupted so it stays resumable.
                            // During a deploy drain this must stay `server_shutdown`
                            // — overwriting it with force_killed strands the writer
                            // (startup recovery and reconcile only resume restart
                            // reasons).
                            if let Err(e) = mission_store
                                .update_mission_status_with_reason(
                                    mid,
                                    MissionStatus::Interrupted,
                                    Some(cancel_timeout_interrupt_reason()),
                                )
                                .await
                            {
                                tracing::warn!(
                                    mission_id = %mid,
                                    "Failed to mark force-cleared mission as Interrupted: {}",
                                    e
                                );
                            } else {
                                maybe_schedule_mission_metadata_refresh_for_status(
                                    &mission_store,
                                    &events_tx,
                                    mid,
                                    MissionStatus::Interrupted,
                                );
                                let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                                    completion: None,
                                    execution: None,
                                    mission_id: mid,
                                    status: MissionStatus::Interrupted,
                                    summary: Some(
                                        "Cancel timed out; force-aborted stuck runner.".to_string(),
                                    ),
                                });
                            }
                            if let Err(e) = mission_store
                                .complete_turn_executions_for_mission(
                                    mid,
                                    running_message_id.take(),
                                    false,
                                    Some("Force-aborted stuck runner after cancel timed out".to_string()),
                                )
                                .await
                            {
                                tracing::warn!(
                                    mission_id = %mid,
                                    "Failed to complete running executions on force-clear: {}",
                                    e
                                );
                            }
                            close_mission_desktop_sessions(
                                &mission_store,
                                mid,
                                &config.working_dir,
                            )
                            .await;
                        }
                        }
                    }
                    // Update last_activity for runners when we receive events for them
                    event = events_rx.recv() => {
                        if let Ok(event) = event {
                            // Extract mission_id from event if present
                            let mission_id = match &event {
                                AgentEvent::ToolCall { mission_id, .. } => *mission_id,
                                AgentEvent::ToolResult { mission_id, .. } => *mission_id,
                                AgentEvent::Thinking { mission_id, .. } => *mission_id,
                                AgentEvent::TextDelta { mission_id, .. } => *mission_id,
                                AgentEvent::UserMessage { mission_id, .. } => *mission_id,
                                AgentEvent::AssistantMessage { mission_id, .. } => *mission_id,
                                AgentEvent::Error { mission_id, .. } => *mission_id,
                                AgentEvent::MissionStatusChanged { mission_id, .. } => Some(*mission_id),
                                AgentEvent::AgentPhase { mission_id, .. } => *mission_id,
                                AgentEvent::AgentTree { mission_id, .. } => *mission_id,
                                AgentEvent::Progress { mission_id, .. } => *mission_id,
                                AgentEvent::MissionActivity { mission_id, .. } => *mission_id,
                                AgentEvent::SessionIdUpdate { mission_id, .. } => Some(*mission_id),
                                AgentEvent::GoalIteration { mission_id, .. } => *mission_id,
                                AgentEvent::GoalStatus { mission_id, .. } => *mission_id,
                                _ => None,
                            };
                            // Update last_activity for matching runner (main or parallel)
                            if let Some(mid) = mission_id {
                                if running_mission_id == Some(mid) {
                                    // Update main runner activity
                                    main_runner_last_activity = std::time::Instant::now();
                                } else if let Some(runner) = parallel_runners.get_mut(&mid) {
                                    // Update parallel runner activity
                                    runner.touch();
                                }
                            }

                            // --- Activity tracking & subtask detection ---
                            match &event {
                                AgentEvent::ToolCall { name, args, tool_call_id, mission_id } => {
                                    if let Some(mid) = mission_id {
                                        let label = activity_label_from_tool_call(name, args);

                                        // Update activity on runner
                                        if running_mission_id == Some(*mid) {
                                            main_runner_activity = Some(label.clone());
                                            main_runner_active_tool_calls
                                                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                        } else if let Some(runner) = parallel_runners.get_mut(mid) {
                                            runner.current_activity = Some(label.clone());
                                            runner
                                                .active_tool_calls
                                                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                        }

                                        let durable_run = if running_mission_id == Some(*mid) {
                                            running_run.clone()
                                        } else {
                                            parallel_runners
                                                .get(mid)
                                                .and_then(|runner| runner.durable_run.clone())
                                        };
                                        if let Some(run) = durable_run {
                                            let now = chrono::Utc::now();
                                            let waiting_state = if is_user_wait_tool(name) {
                                                MissionExecutionState::WaitingUser
                                            } else {
                                                MissionExecutionState::WaitingTool
                                            };
                                            let _ = mission_store
                                                .heartbeat_mission_run(
                                                    run.run_id,
                                                    run.generation,
                                                    waiting_state,
                                                    None,
                                                )
                                                .await;
                                            let execution = MissionToolExecution {
                                                tool_call_id: tool_call_id.clone(),
                                                run_id: run.run_id,
                                                tool_kind: name.clone(),
                                                state: MissionToolExecutionState::Provisional,
                                                started_at: now.to_rfc3339(),
                                                heartbeat_at: now.to_rfc3339(),
                                                deadline_at: (now
                                                    + chrono::Duration::seconds(
                                                        tool_execution_deadline_secs(name, args),
                                                    ))
                                                .to_rfc3339(),
                                                process_pid: None,
                                                durable_job_id: None,
                                                completed_at: None,
                                                exit_status: None,
                                                failure_class: None,
                                            };
                                            if let Err(error) = mission_store
                                                .register_tool_execution(&execution)
                                                .await
                                            {
                                                tracing::warn!(
                                                    mission_id = %mid,
                                                    tool_call_id = %tool_call_id,
                                                    "Failed to register tool execution: {error}"
                                                );
                                            }
                                        }

                                        // Background-task auto-resume: stash the command
                                        // for any `Bash` call so the matching ToolResult
                                        // can attach it to a captured background task.
                                        if background_autoresume_enabled
                                            && name == "Bash"
                                            && pending_bash_commands.len() < MAX_PENDING_BASH_COMMANDS
                                        {
                                            if let Some(cmd) =
                                                args.get("command").and_then(|v| v.as_str())
                                            {
                                                pending_bash_commands
                                                    .insert(tool_call_id.clone(), cmd.to_string());
                                            }
                                        }

                                        // Emit activity event for real-time SSE
                                        let _ = events_tx.send(AgentEvent::MissionActivity {
                                            label,
                                            tool_name: name.clone(),
                                            mission_id: Some(*mid),
                                        });

                                        // Subtask detection
                                        let is_subtask = matches!(name.as_str(),
                                            "Task" | "delegate_task" | "TaskCreate" | "Skill"
                                        );
                                        if is_subtask {
                                            let desc: String = args.get("description")
                                                .or_else(|| args.get("subject"))
                                                .or_else(|| args.get("prompt"))
                                                .and_then(|v| v.as_str())
                                                .unwrap_or("Subtask")
                                                .chars().take(120).collect();
                                            let info = super::super::mission_runner::SubtaskInfo {
                                                tool_call_id: tool_call_id.clone(),
                                                description: desc,
                                                completed: false,
                                            };
                                            let (total, completed) = if running_mission_id == Some(*mid) {
                                                main_runner_subtasks.push(info);
                                                (main_runner_subtasks.len(), main_runner_subtasks.iter().filter(|s| s.completed).count())
                                            } else if let Some(runner) = parallel_runners.get_mut(mid) {
                                                runner.subtasks.push(info);
                                                (runner.subtasks.len(), runner.subtasks.iter().filter(|s| s.completed).count())
                                            } else {
                                                (0, 0)
                                            };
                                            if total > 0 {
                                                let _ = events_tx.send(AgentEvent::Progress {
                                                    total_subtasks: total,
                                                    completed_subtasks: completed,
                                                    current_subtask: None,
                                                    depth: 0,
                                                    mission_id: Some(*mid),
                                                });
                                            }
                                        }

                                        // Desktop session detection from ToolCall.
                                        // Claude Code does not emit ToolResult for MCP tools,
                                        // so we detect the session start from the ToolCall and
                                        // spawn a background task to attribute Wayland compositor processes.
                                        let is_desktop_start = matches!(
                                            name.as_str(),
                                            "desktop_start_session"
                                                | "desktop_desktop_start_session"
                                                | "mcp__desktop__desktop_start_session"
                                        );
                                        if is_desktop_start {
                                            let store = mission_store.clone();
                                            let mid = *mid;
                                            let working_dir = config.working_dir.clone();
                                            tokio::spawn(async move {
                                                // Wait for the compositor to start.
                                                tokio::time::sleep(std::time::Duration::from_secs(4)).await;

                                                let displays =
                                                    super::super::desktop::get_running_wayland_displays(&working_dir).await;
                                                if displays.is_empty() {
                                                    tracing::debug!(
                                                        "No Wayland displays found for desktop attribution"
                                                    );
                                                    return;
                                                }

                                                // Load current mission sessions
                                                let Ok(Some(mission)) = store.get_mission(mid).await
                                                else {
                                                    return;
                                                };
                                                let mut sessions = mission.desktop_sessions.clone();
                                                let tracked: std::collections::HashSet<String> =
                                                    sessions.iter().map(|s| s.display.clone()).collect();

                                                let mut changed = false;
                                                for disp in displays {
                                                    if !tracked.contains(&disp) {
                                                        sessions.push(DesktopSessionInfo {
                                                            display: disp.clone(),
                                                            resolution: None,
                                                            display_server: Some("wayland".to_string()),
                                                            compositor: Some("sway-headless".to_string()),
                                                            started_at: now_string(),
                                                            stopped_at: None,
                                                            screenshots_dir: None,
                                                            browser: None,
                                                            url: None,
                                                            mission_id: Some(mid),
                                                            keep_alive_until: None,
                                                        });
                                                        changed = true;
                                                        tracing::info!(
                                                            display_id = %disp,
                                                            mission_id = %mid,
                                                            "Desktop session attributed from ToolCall"
                                                        );
                                                    }
                                                }

                                                if changed {
                                                    if let Err(err) = store
                                                        .update_mission_desktop_sessions(mid, &sessions)
                                                        .await
                                                    {
                                                        tracing::warn!(
                                                            "Failed to persist desktop session from ToolCall for mission {}: {}",
                                                            mid,
                                                            err
                                                        );
                                                    }
                                                }
                                            });
                                        }
                                    }
                                }
                                AgentEvent::ToolResult { tool_call_id, mission_id, .. } => {
                                    if let Some(mid) = mission_id {
                                        // Clear activity label (tool finished)
                                        if running_mission_id == Some(*mid) {
                                            main_runner_activity = None;
                                            // Saturating decrement: never go below 0
                                            // if we somehow see a stray ToolResult.
                                            let _ = main_runner_active_tool_calls
                                                .fetch_update(
                                                    std::sync::atomic::Ordering::Relaxed,
                                                    std::sync::atomic::Ordering::Relaxed,
                                                    |c| if c > 0 { Some(c - 1) } else { None },
                                                );
                                        } else if let Some(runner) = parallel_runners.get_mut(mid) {
                                            runner.current_activity = None;
                                            let _ = runner.active_tool_calls.fetch_update(
                                                std::sync::atomic::Ordering::Relaxed,
                                                std::sync::atomic::Ordering::Relaxed,
                                                |c| if c > 0 { Some(c - 1) } else { None },
                                            );
                                        }

                                        let durable_run = if running_mission_id == Some(*mid) {
                                            running_run.clone()
                                        } else {
                                            parallel_runners
                                                .get(mid)
                                                .and_then(|runner| runner.durable_run.clone())
                                        };
                                        if let Some(run) = durable_run {
                                            match mission_store
                                                .finish_tool_execution(
                                                    run.run_id,
                                                    tool_call_id,
                                                    MissionToolExecutionState::Completed,
                                                    Some(0),
                                                    None,
                                                )
                                                .await
                                            {
                                                Ok(true) => {
                                                    let _ = mission_store
                                                        .heartbeat_mission_run(
                                                            run.run_id,
                                                            run.generation,
                                                            MissionExecutionState::Running,
                                                            None,
                                                        )
                                                        .await;
                                                }
                                                Ok(false) => tracing::debug!(
                                                    mission_id = %mid,
                                                    tool_call_id = %tool_call_id,
                                                    "Stored late or unmatched tool result without mutating current run"
                                                ),
                                                Err(error) => tracing::warn!(
                                                    mission_id = %mid,
                                                    tool_call_id = %tool_call_id,
                                                    "Failed to finish tool execution: {error}"
                                                ),
                                            }
                                        }

                                        // Mark subtask complete if applicable
                                        let subtasks: Option<&mut Vec<super::super::mission_runner::SubtaskInfo>> =
                                            if running_mission_id == Some(*mid) {
                                                Some(&mut main_runner_subtasks)
                                            } else {
                                                parallel_runners.get_mut(mid).map(|r| &mut r.subtasks)
                                            };
                                        if let Some(subtasks) = subtasks {
                                            let mut changed = false;
                                            for s in subtasks.iter_mut() {
                                                if s.tool_call_id == *tool_call_id && !s.completed {
                                                    s.completed = true;
                                                    changed = true;
                                                    break;
                                                }
                                            }
                                            if changed {
                                                let total = subtasks.len();
                                                let completed = subtasks.iter().filter(|s| s.completed).count();
                                                let _ = events_tx.send(AgentEvent::Progress {
                                                    total_subtasks: total,
                                                    completed_subtasks: completed,
                                                    current_subtask: None,
                                                    depth: 0,
                                                    mission_id: Some(*mid),
                                                });
                                            }
                                        }
                                    }
                                }
                                AgentEvent::Thinking { done, mission_id, .. } => {
                                    if let Some(mid) = mission_id {
                                        let label = if *done { None } else { Some("Thinking…".to_string()) };
                                        if running_mission_id == Some(*mid) {
                                            main_runner_activity = label;
                                        } else if let Some(runner) = parallel_runners.get_mut(mid) {
                                            runner.current_activity = label;
                                        }
                                    }
                                }
                                _ => {}
                            }

                            // Background-task auto-resume capture: when a `Bash` tool
                            // result is the CLI's background-launch confirmation, record
                            // the task so the watcher can wake the agent once it finishes.
                            // (Must run before the desktop block below, which `continue`s
                            // past non-desktop tool results.)
                            if background_autoresume_enabled {
                                if let AgentEvent::ToolResult {
                                    tool_call_id,
                                    name,
                                    result,
                                    mission_id,
                                } = &event
                                {
                                    // Always reclaim the correlated command, even if this
                                    // isn't a background start, so the map can't leak.
                                    let command = pending_bash_commands.remove(tool_call_id);
                                    // A session that outlives its turns reports its own
                                    // background tasks and wakes itself.
                                    if name == "Bash"
                                        && !mission_id.is_some_and(
                                            super::super::runners::live_session::is_attached,
                                        )
                                    {
                                        if let (Some(mid), Some(text)) =
                                            (mission_id, tool_result_text(result))
                                        {
                                            if let Some((task_id, output_path)) =
                                                super::super::runners::claudecode::parse_background_task_start(
                                                    &text,
                                                )
                                            {
                                                let task = super::super::mission_runner::BackgroundTask {
                                                    id: task_id.clone(),
                                                    output_path: output_path.clone(),
                                                    command: command.unwrap_or_default(),
                                                    started_at: std::time::Instant::now(),
                                                };
                                                tracing::info!(
                                                    mission_id = %mid,
                                                    background_task_id = %task_id,
                                                    output_path = %output_path,
                                                    "Captured Claude Code background task; \
                                                     scheduling auto-resume on completion"
                                                );
                                                // Mirror onto the runner (informational).
                                                if let Some(runner) = parallel_runners.get_mut(mid) {
                                                    runner
                                                        .background_tasks
                                                        .insert(task_id.clone(), task.clone());
                                                }
                                                // Source of truth: the shared registry.
                                                background_tasks
                                                    .write()
                                                    .await
                                                    .entry(*mid)
                                                    .or_default()
                                                    .insert(task_id, task);
                                            }
                                        }
                                    } else if name.ends_with("durable_job_start") {
                                        if let (Some(mid), Some(job)) =
                                            (mission_id, parse_durable_job_result(result))
                                        {
                                            let Some(job_id) =
                                                job.get("id").and_then(|value| value.as_str())
                                            else {
                                                continue;
                                            };
                                            let command = job
                                                .get("command")
                                                .and_then(|value| value.as_str())
                                                .unwrap_or_default()
                                                .to_string();
                                            let mut output_path = job
                                                .get("stdout_log")
                                                .and_then(|value| value.as_str())
                                                .unwrap_or_default()
                                                .to_string();
                                            if let Ok(Some(mission)) = mission_store.get_mission(*mid).await {
                                                if let Some(workspace) =
                                                    workspaces.get(mission.workspace_id).await
                                                {
                                                    output_path = WorkspaceExec::new(workspace)
                                                        .translate_path_for_container(
                                                            std::path::Path::new(&output_path),
                                                        );
                                                }
                                            }
                                            let task = super::super::mission_runner::BackgroundTask {
                                                id: format!("durable:{job_id}"),
                                                output_path,
                                                command,
                                                started_at: std::time::Instant::now(),
                                            };
                                            tracing::info!(
                                                mission_id = %mid,
                                                durable_job_id = %job_id,
                                                "Captured durable background job; scheduling auto-resume on completion"
                                            );
                                            if let Some(runner) = parallel_runners.get_mut(mid) {
                                                runner
                                                    .background_tasks
                                                    .insert(task.id.clone(), task.clone());
                                            }
                                            background_tasks
                                                .write()
                                                .await
                                                .entry(*mid)
                                                .or_default()
                                                .insert(task.id.clone(), task);
                                        }
                                    }
                                }
                            }

                            // Track desktop sessions for mission reconnect/resume.
                            if let AgentEvent::ToolResult { name, result, mission_id, .. } = &event {
                                let Some(mid) = mission_id else {
                                    continue;
                                };

                                let tool_name = name.as_str();
                                let is_start = matches!(
                                    tool_name,
                                    "desktop_start_session"
                                        | "desktop_desktop_start_session"
                                        | "mcp__desktop__desktop_start_session"
                                );
                                let is_stop = matches!(
                                    tool_name,
                                    "desktop_stop_session"
                                        | "desktop_close_session"
                                        | "desktop_desktop_stop_session"
                                        | "desktop_desktop_close_session"
                                        | "mcp__desktop__desktop_stop_session"
                                        | "mcp__desktop__desktop_close_session"
                                );

                                if !is_start && !is_stop {
                                    continue;
                                }

                                let Some(obj) = parse_tool_result_object(result) else {
                                    continue;
                                };

                                let Some(display) = obj
                                    .get("display")
                                    .and_then(|v| v.as_str())
                                    .map(|v| v.to_string())
                                else {
                                    continue;
                                };

                                let Ok(Some(mission)) = mission_store.get_mission(*mid).await else {
                                    continue;
                                };

                                let mut sessions = mission.desktop_sessions.clone();
                                let now = now_string();

                                if is_start {
                                    let resolution = obj
                                        .get("resolution")
                                        .and_then(|v| v.as_str())
                                        .map(|v| v.to_string());
                                    let screenshots_dir = obj
                                        .get("screenshots_dir")
                                        .and_then(|v| v.as_str())
                                        .map(|v| v.to_string());
                                    let display_server = obj
                                        .get("display_server")
                                        .and_then(|v| v.as_str())
                                        .map(|v| v.to_string())
                                        .or_else(|| Some("wayland".to_string()));
                                    let compositor = obj
                                        .get("compositor")
                                        .and_then(|v| v.as_str())
                                        .map(|v| v.to_string())
                                        .or_else(|| Some("sway-headless".to_string()));
                                    let browser = obj
                                        .get("browser")
                                        .and_then(|v| v.as_str())
                                        .map(|v| v.to_string());
                                    let url = obj
                                        .get("url")
                                        .and_then(|v| v.as_str())
                                        .map(|v| v.to_string());

                                    if let Some(existing) = sessions
                                        .iter_mut()
                                        .rev()
                                        .find(|session| session.display == display && session.stopped_at.is_none())
                                    {
                                        existing.resolution = resolution;
                                        existing.display_server = display_server;
                                        existing.compositor = compositor;
                                        existing.screenshots_dir = screenshots_dir;
                                        existing.browser = browser;
                                        existing.url = url;
                                        existing.started_at = now.clone();
                                    } else {
                                        sessions.push(DesktopSessionInfo {
                                            display,
                                            resolution,
                                            display_server,
                                            compositor,
                                            started_at: now.clone(),
                                            stopped_at: None,
                                            screenshots_dir,
                                            browser,
                                            url,
                                            mission_id: Some(*mid),
                                            keep_alive_until: None,
                                        });
                                    }
                                } else if let Some(existing) = sessions
                                    .iter_mut()
                                    .rev()
                                    .find(|session| session.display == display && session.stopped_at.is_none())
                                {
                                    existing.stopped_at = Some(now.clone());
                                }

                                if let Err(err) = mission_store
                                    .update_mission_desktop_sessions(*mid, &sessions)
                                    .await
                                {
                                    tracing::warn!(
                                        "Failed to persist desktop session info for mission {}: {}",
                                        mid,
                                        err
                                    );
                                }
                            }

                            // Only an update from the latest acquired generation may
                            // mutate durable identity or the parallel runner cache.
                            if let AgentEvent::SessionIdUpdate { mission_id, session_id, backend, run } = &event {
                                match mission_store.update_mission_session_id(*mission_id, session_id, backend, run.as_ref()).await {
                                    Ok(true) => {
                                        if let Some(runner) = parallel_runners.get_mut(mission_id) {
                                            let cached_run = runner.durable_run.as_ref().map(crate::api::mission_store::SessionUpdateRun::from);
                                            if runner.backend_id == *backend && cached_run == *run {
                                                runner.session_id = Some(session_id.clone());
                                            }
                                        }
                                    }
                                    Ok(false) => tracing::debug!(mission_id = %mission_id, "Ignored stale or unattributed native session update"),
                                    Err(err) => tracing::warn!(mission_id = %mission_id, %err, "Failed to persist native session update"),
                                }
                            }

                            // Persist `/goal` metadata so refreshes and restart recovery
                            // can continue through codex goal mode instead of a plain turn.
                            if let AgentEvent::UserMessage {
                                content,
                                mission_id: Some(mid),
                                source,
                                ..
                            } = &event
                            {
                                let prompt = if source.as_deref() == Some("scheduler") { deferred_messages::strip(content) } else { content.clone() };
                                if let Some(objective) = parse_goal_objective(&prompt) {
                                    if let Err(err) = mission_store
                                        .update_mission_goal(*mid, true, Some(&objective))
                                        .await
                                    {
                                        tracing::warn!(
                                            mission_id = %mid,
                                            "Failed to persist goal metadata from user message: {}",
                                            err
                                        );
                                    }
                                }
                            }

                            if let AgentEvent::GoalStatus {
                                status,
                                objective,
                                mission_id: Some(mid),
                            } = &event
                            {
                                // Only an active loop arms goal mode; a finished
                                // loop disarms it (keeping the objective for
                                // display). Paused/blocked keep the current state
                                // so a user Stop, which disarmed it, is not undone
                                // by the runner's trailing `paused` event.
                                let update = match goal_mode_after_status(status) {
                                    Some(goal_mode) => {
                                        let objective = (status != "cleared")
                                            .then_some(objective.as_str());
                                        Some(
                                            mission_store
                                                .update_mission_goal(*mid, goal_mode, objective)
                                                .await,
                                        )
                                    }
                                    None => None,
                                };
                                if let Some(Err(err)) = update {
                                    tracing::warn!(
                                        mission_id = %mid,
                                        status = %status,
                                        "Failed to persist goal metadata from goal status: {}",
                                        err
                                    );
                                }
                            }
                        }
                    }
                }
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn run_single_control_turn(
    mission_store: Arc<dyn MissionStore>,
    mut config: Config,
    _root_agent: AgentRef,
    mcp: Arc<McpRegistry>,
    workspaces: workspace::SharedWorkspaceStore,
    library: SharedLibrary,
    events_tx: broadcast::Sender<AgentEvent>,
    tool_hub: Arc<FrontendToolHub>,
    status: Arc<RwLock<ControlStatus>>,
    cancel: CancellationToken,
    history: Vec<(String, String)>,
    user_message: String,
    mission_control: Option<crate::tools::mission::MissionControl>,
    tree_snapshot: Arc<RwLock<Option<AgentTreeNode>>>,
    progress_snapshot: Arc<RwLock<ExecutionProgress>>,
    mission_id: Option<Uuid>,
    workspace_id: Option<Uuid>,
    backend_id: Option<String>,
    model_override: Option<String>,
    model_effort: Option<String>,
    fast_mode: bool,
    service_tier: Option<crate::codex_speed::Tier>,
    agent_override: Option<String>,
    session_id: Option<String>,
    force_session_resume: bool,
    mission_config_profile: Option<String>,
    boss_user_id: Option<AuthUser>,
    pr_readonly: bool,
) -> crate::agents::AgentResult {
    #[cfg(test)]
    if let Some(mid) = mission_id {
        if let Some(result) = dispatch_admission_tests::native_goal_fixture(
            &config,
            &workspaces,
            Some(&mission_store),
            mid,
            &user_message,
            events_tx.clone(),
            cancel.clone(),
        )
        .await
        {
            return result;
        }
    }
    // Vibe uses the same native prompt/session and transferred-workspace path
    // as parallel mission turns. The generic control dispatcher below has no
    // Vibe runner and frames resumed prompts differently.
    if backend_id.as_deref() == Some("vibe") {
        let mid = match require_mission_id(mission_id, "Mistral Vibe", &events_tx) {
            Ok(id) => id,
            Err(result) => return result,
        };
        let mission = match mission_store.get_mission(mid).await {
            Ok(Some(mission)) => mission,
            Ok(None) => return crate::agents::AgentResult::failure("Vibe mission not found", 0),
            Err(error) => return crate::agents::AgentResult::failure(error, 0),
        };
        // New/queued control turns append this delivery before dispatch;
        // explicit resume passes only prior history. Keep an identical prior
        // request on resume and strip scheduler metadata when matching a
        // newly appended delivery.
        let mut history = history;
        if !force_session_resume
            && history.last().is_some_and(|(role, content)| {
                role == "user" && deferred_messages::strip(content) == user_message
            })
        {
            history.pop();
        }
        return Box::pin(super::super::mission_runner::run_mission_turn(
            Some(mission_store),
            config,
            _root_agent,
            mcp,
            workspaces,
            library,
            events_tx,
            tool_hub,
            status,
            cancel,
            history,
            user_message,
            mission_control,
            tree_snapshot,
            progress_snapshot,
            mid,
            workspace_id,
            "vibe".into(),
            agent_override,
            model_override,
            model_effort,
            fast_mode,
            service_tier,
            None,
            session_id,
            mission_config_profile,
            mission.working_directory,
            boss_user_id,
            pr_readonly,
        ))
        .await;
    }
    let is_claudecode = backend_id.as_deref() == Some("claudecode");
    let is_codex = backend_id.as_deref() == Some("codex");
    // Get config profile: mission's config_profile takes priority over workspace's
    let workspace_config_profile = if let Some(ws_id) = workspace_id {
        workspaces.get(ws_id).await.and_then(|ws| ws.config_profile)
    } else {
        None
    };
    let effective_config_profile = mission_config_profile.or(workspace_config_profile);
    let requested_model = model_override;
    let requested_model_effort = model_effort;
    if let Some(ref model) = requested_model {
        config.default_model = Some(model.clone());
    } else if is_claudecode && config.default_model.is_some() {
        config.default_model = config
            .default_model
            .take()
            .map(|model| crate::library::normalize_claude_code_default_model(Some(model)));
    } else if is_claudecode && config.default_model.is_none() {
        if let Some(default_model) =
            resolve_claudecode_default_model(&library, effective_config_profile.as_deref()).await
        {
            config.default_model = Some(default_model);
        }
    } else if is_codex {
        // Pin Codex instead of inheriting the global DEFAULT_MODEL, which is
        // usually a Claude/OpenCode slug and invalid for the Codex CLI.
        config.default_model = Some(resolve_codex_default_model());
    } else if (backend_id.as_deref() == Some("opencode")
        && effective_config_profile.is_some()
        && requested_model.is_none())
        || (matches!(backend_id.as_deref(), Some("grok" | "antigravity" | "vibe"))
            && requested_model.is_none())
    {
        config.default_model = None;
    } else if backend_id.as_deref() == Some("chatgpt_ui") && requested_model.is_none() {
        // Web model labels are account-specific. Never invent or inherit a
        // CLI/API model slug for the browser harness.
        config.default_model =
            super::super::mission_runner::get_backend_string_setting("chatgpt_ui", "model");
    }
    if let Some(ref agent) = agent_override {
        config.opencode_agent = Some(agent.clone());
    }
    // Ensure a workspace directory for this mission (if applicable).
    let (working_dir_path, runtime_workspace) = if let Some(mid) = mission_id {
        if let Err(error) = crate::control_mcp::launch::require_runtime_owner(
            backend_id.as_deref().unwrap_or("opencode"),
            boss_user_id.as_ref(),
        ) {
            return crate::agents::AgentResult::failure(error, 0);
        }
        let mut ws = workspace::resolve_workspace(&workspaces, &config, workspace_id).await;
        // The project's Library skill selection joins this mission's delivery set.
        if let Ok(Some(mission)) = mission_store.get_mission(mid).await {
            ws.mission_project_skills = mission
                .project
                .project
                .as_deref()
                .filter(|p| super::super::projects_overview::is_plain_key(p))
                .map(|p| {
                    super::super::projects_store::read_project_skills(
                        &config.working_dir.join(".sandboxed-sh/projects.db"),
                        p,
                    )
                })
                .unwrap_or_default();
        }
        if let Err(e) =
            workspace::sync_workspace_mcp_binaries_for_workspace(&config.working_dir, &ws).await
        {
            tracing::warn!(
                workspace = %ws.name,
                error = %e,
                "Failed to sync MCP binaries into workspace"
            );
        }
        // Get library for skill syncing
        let lib_guard = library.read().await;
        let lib_ref = lib_guard.as_ref().map(|l| l.as_ref());
        let prepared = Box::pin(workspace::prepare_mission_workspace_with_skills_backend(
            &mut ws,
            &mcp,
            lib_ref,
            mid,
            backend_id.as_deref().unwrap_or("opencode"),
            None, // custom_providers: TODO integrate with provider store
            effective_config_profile.as_deref(),
            boss_user_id.as_ref(),
            Some(&config.working_dir),
            !pr_readonly,
        ))
        .await;
        let dir = match workspace::require_verified_mission_workspace(prepared) {
            Ok(dir) => dir,
            Err(e) => {
                // The persisted mission root is a placement capability, not
                // a hint. Do not run an Ask/control turn in the workspace
                // root if its selected filesystem cannot be verified.
                tracing::warn!(mission_id = %mid, error = %e, "refusing control turn without its verified mission workspace");
                return crate::agents::AgentResult::failure(e.to_string(), 0);
            }
        };
        (dir, Some(ws))
    } else {
        (
            config.working_dir.clone(),
            Some(workspace::Workspace::default_host(
                config.working_dir.clone(),
            )),
        )
    };

    let user_message = if let Some(mid) = mission_id {
        match crate::api::mission_payload::materialize_turn(
            &config.working_dir,
            &working_dir_path,
            mid,
            &user_message,
        ) {
            Ok(message) => message,
            Err(error) => {
                return crate::agents::AgentResult::failure(
                    format!("materialize attachments: {error}"),
                    0,
                )
            }
        }
    } else {
        user_message
    };

    if let Some(ws) = runtime_workspace.as_ref() {
        if let Err(e) = Box::pin(workspace::write_runtime_workspace_state(
            &config.working_dir,
            ws,
            &working_dir_path,
            mission_id,
            &config.context.context_dir_name,
        ))
        .await
        {
            tracing::warn!("Failed to write runtime workspace state: {}", e);
        }
    }

    // For Telegram missions, append channel instructions and memory awareness
    // to CLAUDE.md so the backend LLM adopts the bot persona.
    if user_message.contains("[Telegram from ") {
        let claude_md_path = working_dir_path.join("CLAUDE.md");
        tracing::info!(
            mission_id = ?mission_id,
            claude_md_path = %claude_md_path.display(),
            claude_md_exists = claude_md_path.exists(),
            "Telegram message detected in control path, attempting CLAUDE.md injection"
        );
        // Create the file if it doesn't exist so that non-Claude-Code
        // backends (e.g. opencode) also get the identity injection.
        if !claude_md_path.exists() {
            let _ = std::fs::write(&claude_md_path, "");
        }
        let actions_available = mission_id
            .and_then(crate::api::telegram::build_internal_telegram_action_token)
            .is_some()
            && super::super::mission_runner::localhost_api_base_url_from_env().is_some();
        super::super::mission_runner::inject_telegram_identity_into_claude_md(
            &claude_md_path,
            &user_message,
            actions_available,
        );
    }

    // Build a task prompt that includes conversation context with size limits.
    let history_for_prompt = match history.last() {
        Some((role, content)) if role == "user" && content == &user_message => {
            &history[..history.len() - 1]
        }
        _ => history.as_slice(),
    };
    let history_context =
        build_history_context(history_for_prompt, config.context.max_history_total_chars);
    let mut convo = String::new();
    convo.push_str(&crate::util::frame_turn_prompt(
        &history_context,
        &user_message,
    ));
    convo.push_str("\n\nInstructions:\n- Respond to the CURRENT user request. The conversation history is context only: do not resume or continue earlier tasks from it unless the current request asks you to.\n- Use available tools as needed.\n- For large data processing tasks (>10KB), prefer executing scripts rather than inline processing.\n");
    if pr_readonly {
        convo.push_str("\nPR READ-ONLY CAPABILITY (server-enforced): inspect and run verification only. Do not edit tracked files, commit, push, comment, resolve threads, approve, close, or merge. End with exactly one explicit terminal line: `VERDICT: CLEAN`, `VERDICT: BLOCKED`, or `VERDICT: INFRA_BLOCKED`. Git/gh mutation commands are disabled.\n");
    }
    let _task = match crate::task::Task::new(convo.clone(), Some(1000)) {
        Ok(t) => t,
        Err(e) => {
            let r = crate::agents::AgentResult::failure(format!("Failed to create task: {}", e), 0);
            return r;
        }
    };

    // Context for agent execution.
    let mut ctx = AgentContext::new(config.clone(), working_dir_path);
    ctx.mission_control = mission_control;
    ctx.control_events = Some(events_tx.clone());
    ctx.frontend_tool_hub = Some(tool_hub.clone());
    ctx.control_status = Some(status.clone());
    ctx.cancel_token = Some(cancel.clone());
    ctx.tree_snapshot = Some(tree_snapshot);
    ctx.progress_snapshot = Some(progress_snapshot);
    ctx.mission_id = mission_id;
    ctx.mcp = Some(mcp);

    let fallback_workspace = workspace::Workspace::default_host(config.working_dir.clone());
    let exec_workspace = runtime_workspace.as_ref().unwrap_or(&fallback_workspace);

    // Execute based on backend
    let result = match backend_id.as_deref() {
        Some("claudecode") => {
            let mid = match require_mission_id(mission_id, "Claude Code", &events_tx) {
                Ok(id) => id,
                Err(r) => return r,
            };
            // Continuation: prior assistant response in history, or an
            // explicit resume request (e.g. mission resume operations where
            // the session exists but history may not have assistant
            // messages yet).
            let is_continuation =
                force_session_resume || history.iter().any(|(role, _)| role == "assistant");
            // Full recovery orchestration (transport retries, SIGKILL OAuth
            // refresh, stale-credential retry, account rotation) is shared
            // with the mission dispatch via the runners layer. This arm
            // previously carried a near-duplicate copy that was missing the
            // SIGKILL refresh and the initial auth retry.
            use crate::api::runners::HarnessRunner as _;
            Box::pin(crate::api::runners::ClaudeCodeRunner.run_turn(
                crate::api::runners::TurnContext {
                    mission_store: Some(mission_store.clone()),
                    workspace: exec_workspace,
                    work_dir: &ctx.working_dir,
                    message: &user_message,
                    model: config.default_model.as_deref(),
                    model_effort: requested_model_effort.as_deref(),
                    fast_mode,
                    service_tier,
                    agent: config.opencode_agent.as_deref(),
                    mission_id: mid,
                    events_tx: events_tx.clone(),
                    cancel: cancel.clone(),
                    app_working_dir: &config.working_dir,
                    session_id: session_id.as_deref(),
                    is_continuation,
                    extras: crate::api::runners::TurnExtras::ClaudeCode {
                        owner: boss_user_id.clone(),
                        secrets: None, // not available in control context
                        tool_hub: Some(tool_hub.clone()),
                        status: Some(status.clone()),
                        history: &history,
                        max_history_total_chars: config.context.max_history_total_chars,
                    },
                },
            ))
            .await
        }
        Some("grok") => {
            let mid = match require_mission_id(mission_id, "Grok Build", &events_tx) {
                Ok(id) => id,
                Err(r) => return r,
            };
            let is_continuation =
                force_session_resume || history.iter().any(|(role, _)| role == "assistant");
            let grok_message_owned: String = match canonical_goal_message(&user_message) {
                Some(goal) => goal,
                None => convo.clone(),
            };
            use crate::api::runners::HarnessRunner as _;
            Box::pin(
                crate::api::runners::GrokRunner.run_turn(crate::api::runners::TurnContext {
                    mission_store: Some(mission_store.clone()),
                    workspace: exec_workspace,
                    work_dir: &ctx.working_dir,
                    message: &grok_message_owned,
                    model: requested_model
                        .as_deref()
                        .or(config.default_model.as_deref()),
                    model_effort: None,
                    fast_mode: false,
                    service_tier: None,
                    agent: None,
                    mission_id: mid,
                    events_tx: events_tx.clone(),
                    cancel,
                    app_working_dir: &config.working_dir,
                    session_id: session_id.as_deref(),
                    is_continuation,
                    extras: crate::api::runners::TurnExtras::None,
                }),
            )
            .await
        }
        Some("codex") => {
            let mid = match require_mission_id(mission_id, "Codex", &events_tx) {
                Ok(id) => id,
                Err(r) => return r,
            };
            let requested_codex_model = requested_model
                .as_deref()
                .or(config.default_model.as_deref());
            // Goal-mode missions need the raw `/goal <objective>` message to
            // reach the codex backend; the wrapped `convo` buries the prefix
            // and breaks `parse_goal_prefix`. Mirror the same routing the
            // mission_runner dispatch uses.
            let codex_message_owned: String = match canonical_goal_message(&user_message) {
                Some(goal) => goal,
                None => convo.clone(),
            };
            let codex_message: &str = codex_message_owned.as_str();
            // Shared rotation wrapper: identical account rotation + usage-cap
            // cooldown behaviour to the initial mission dispatch. Previously
            // this path ran a single bare run_codex_turn with no credential
            // override, so a follow-up/retry on a usage-capped ChatGPT
            // account kept re-hitting the same cap instead of rotating to
            // the next account. Fallback-model and tool-stall retries are
            // handled inside the wrapper per attempted credential.
            use crate::api::runners::HarnessRunner as _;
            Box::pin(
                crate::api::runners::CodexRunner.run_turn(crate::api::runners::TurnContext {
                    mission_store: Some(mission_store.clone()),
                    workspace: exec_workspace,
                    work_dir: &ctx.working_dir,
                    message: codex_message,
                    model: requested_codex_model,
                    model_effort: requested_model_effort.as_deref(),
                    fast_mode,
                    service_tier,
                    agent: config.opencode_agent.as_deref(),
                    mission_id: mid,
                    events_tx: events_tx.clone(),
                    cancel: cancel.clone(),
                    app_working_dir: &config.working_dir,
                    session_id: session_id.as_deref(),
                    is_continuation: false,
                    extras: crate::api::runners::TurnExtras::None,
                }),
            )
            .await
        }
        Some("antigravity") => {
            let mid = match require_mission_id(mission_id, "Antigravity", &events_tx) {
                Ok(id) => id,
                Err(r) => return r,
            };
            use crate::api::runners::HarnessRunner as _;
            let framed = crate::util::frame_turn_prompt(&history_context, &user_message);
            let handoff = super::super::mission_runner::antigravity_handoff_prompt(
                &history_context,
                &user_message,
                &convo[framed.len()..],
            );
            Box::pin(crate::api::runners::AntigravityRunner.run_turn(
                crate::api::runners::TurnContext {
                    mission_store: Some(mission_store.clone()),
                    workspace: exec_workspace,
                    work_dir: &ctx.working_dir,
                    message: if session_id.is_none() {
                        &handoff
                    } else {
                        &user_message
                    },
                    model: config.default_model.as_deref(),
                    model_effort: None,
                    fast_mode: false,
                    service_tier: None,
                    agent: config.opencode_agent.as_deref(),
                    mission_id: mid,
                    events_tx: events_tx.clone(),
                    cancel,
                    app_working_dir: &config.working_dir,
                    session_id: session_id.as_deref(),
                    is_continuation: force_session_resume
                        || history.iter().any(|(role, _)| role == "assistant"),
                    extras: crate::api::runners::TurnExtras::Antigravity {
                        current_message: &user_message,
                    },
                },
            ))
            .await
        }
        Some("chatgpt_ui") => {
            let mid = match require_mission_id(mission_id, "ChatGPT UI", &events_tx) {
                Ok(id) => id,
                Err(r) => return r,
            };
            use crate::api::runners::HarnessRunner as _;
            Box::pin(
                crate::api::runners::ChatGptUiRunner.run_turn(crate::api::runners::TurnContext {
                    mission_store: Some(mission_store.clone()),
                    workspace: exec_workspace,
                    work_dir: &ctx.working_dir,
                    // The browser always starts a fresh chat, so include the
                    // bounded conversation frame on follow-up turns.
                    message: &convo,
                    model: requested_model
                        .as_deref()
                        .or(config.default_model.as_deref()),
                    model_effort: None,
                    fast_mode: false,
                    service_tier: None,
                    agent: None,
                    mission_id: mid,
                    events_tx: events_tx.clone(),
                    cancel,
                    app_working_dir: &config.working_dir,
                    session_id: None,
                    is_continuation: false,
                    extras: crate::api::runners::TurnExtras::None,
                }),
            )
            .await
        }
        Some(backend) if backend != "opencode" => {
            let _ = events_tx.send(AgentEvent::Error {
                message: format!("Unsupported backend: {}", backend),
                mission_id,
                resumable: mission_id.is_some(),
            });
            crate::agents::AgentResult::failure(format!("Unsupported backend: {}", backend), 0)
                .with_terminal_reason(TerminalReason::LlmError)
        }
        _ => {
            // Default to opencode using per-workspace CLI execution
            let mid = mission_id.unwrap_or_else(Uuid::nil);
            // A stored OpenCode-format session_id (starts with `ses_`) is
            // itself a strong signal of a continuation even when the
            // in-memory history has no assistant message (e.g. server
            // restart, mission resume, history rebuild). The per-mission
            // XDG storage still has the prior session, and we want
            // --session/--continue to fire so we don't lose context. This
            // mirrors the `mission_runner` arm and fixes Bugbot e8dd69f8.
            //
            // Note: missions also carry a *Claude Code*-style UUID
            // session_id from mission creation, which the opencode CLI
            // does not understand. We ignore that here (treat as no
            // session) and let `is_opencode_session_id` in the runner
            // filter it out as well, so the CLI never receives an invalid
            // `--session <UUID>` and errors with "Session not found".
            let has_opencode_session = session_id
                .as_deref()
                .map(super::super::mission_runner::is_opencode_session_id)
                .unwrap_or(false);
            let opencode_is_continuation = force_session_resume
                || history.iter().any(|(role, _)| role == "assistant")
                || has_opencode_session;
            // Goal-mode missions drive a /goal <objective> loop and need the
            // raw message preserved verbatim. For normal continuations, when
            // we have a stored OpenCode session_id the opencode CLI will
            // load prior messages from its own storage, so we send the bare
            // user message instead of the history-framed `convo` (which
            // would duplicate the context the session already has). When we
            // don't have an OpenCode session_id (first turn of a brand-new
            // mission, a legacy mission that never persisted one, or a
            // mission that only has the Claude-Code UUID placeholder),
            // keep using `convo` so the model still gets a history-aware
            // prompt.
            let canonical_goal = canonical_goal_message(&user_message);
            let opencode_message_owned: String = if let Some(goal) = canonical_goal {
                goal
            } else if opencode_is_continuation && has_opencode_session {
                user_message.clone()
            } else {
                convo.clone()
            };
            use crate::api::runners::HarnessRunner as _;
            Box::pin(crate::api::runners::OpenCodeRunner.run_turn(
                crate::api::runners::TurnContext {
                    mission_store: Some(mission_store.clone()),
                    workspace: exec_workspace,
                    work_dir: &ctx.working_dir,
                    message: &opencode_message_owned,
                    model: config.default_model.as_deref(),
                    model_effort: requested_model_effort.as_deref(),
                    fast_mode: false,
                    service_tier: None,
                    agent: config.opencode_agent.as_deref(),
                    mission_id: mid,
                    events_tx: events_tx.clone(),
                    cancel,
                    app_working_dir: &config.working_dir,
                    session_id: session_id.as_deref(),
                    is_continuation: opencode_is_continuation,
                    extras: crate::api::runners::TurnExtras::None,
                },
            ))
            .await
        }
    };
    result
}
