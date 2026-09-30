//! Scheduled continuations share the automation store and the normal message queue.
//! A durable pending execution is the outbox: it is retired only after admission ACK.
use super::*;
use crate::api::mission_store::{
    Automation, AutomationDriver, AutomationExecution, ExecutionStatus, TriggerType,
};
use chrono::{DateTime, Utc};

/// Bind all constituents to the executing turn before settlement or recovery.
/// The stored alias is independent of the scheduler's outer admission identity.
pub async fn bind_turn(
    store: &Arc<dyn MissionStore>,
    mission: Option<Uuid>,
    message: Option<Uuid>,
    ids: Vec<Uuid>,
) {
    let (Some(mission), Some(message)) = (mission, message) else {
        return;
    };
    if ids.is_empty() || ids == [message] {
        return;
    }
    if let Err(error) = store
        .handoff_scheduled_executions(mission, ids, message)
        .await
    {
        tracing::error!(%mission, %message, %error, "Failed to bind scheduled batch to its executing turn");
    }
}

pub fn lock(mission: Uuid) -> Arc<tokio::sync::Mutex<()>> {
    worker_location::dispatch_lock(&format!("continuation:{mission}"))
}

pub fn next_at(a: &Automation) -> Option<DateTime<Utc>> {
    let base =
        DateTime::parse_from_rfc3339(a.last_triggered_at.as_deref().unwrap_or(&a.created_at))
            .ok()?
            .with_timezone(&Utc);
    match &a.trigger {
        TriggerType::Interval { seconds } => base.checked_add_signed(
            chrono::Duration::try_seconds(i64::try_from(*seconds).ok()?)?,
        ),
        TriggerType::Cron {
            expression,
            timezone,
        } => {
            let cron = croner::Cron::new(expression).parse().ok()?;
            if let Some(tz) = resolve_tz(timezone) {
                cron.find_next_occurrence(&base.with_timezone(&tz), false)
                    .ok()
                    .map(|d| d.with_timezone(&Utc))
            } else {
                let tz = timezone.parse::<chrono::FixedOffset>().ok()?;
                cron.find_next_occurrence(&base.with_timezone(&tz), false)
                    .ok()
                    .map(|d| d.with_timezone(&Utc))
            }
        }
        _ => None,
    }
}

fn entry(a: &Automation) -> serde_json::Value {
    serde_json::json!({
        "id": a.id, "state": "scheduled", "next_at": next_at(a),
        "trigger": if matches!(a.trigger, TriggerType::DurableJobTerminal { .. }) { "job" } else { "time" },
        "reason": a.variables.get("__wakeup_reason"),
        "source": a.variables.get("__wakeup_source"),
    })
}

pub async fn summaries(
    store: &Arc<dyn MissionStore>,
) -> Result<HashMap<Uuid, serde_json::Value>, String> {
    let client_pending: std::collections::HashSet<_> = store
        .list_pending_board_outbox(10000)
        .await?
        .into_iter()
        .filter(|r| r.delivery_kind == "client_message")
        .map(|r| r.id)
        .collect();
    let mut groups: HashMap<Uuid, Vec<serde_json::Value>> = HashMap::new();
    for a in store.list_active_automations().await? {
        if a.variables.contains_key("__wakeup_source")
            && a.driver == AutomationDriver::Scheduler
            && matches!(
                a.trigger,
                TriggerType::Interval { .. }
                    | TriggerType::Cron { .. }
                    | TriggerType::DurableJobTerminal { .. }
            )
        {
            groups.entry(a.mission_id).or_default().push(entry(&a));
        }
    }
    for e in store.list_scheduled_deliveries().await? {
        if e.variables_used
            .get("__delivery_accepted")
            .is_some_and(|v| v == "true")
            && !client_pending.contains(&e.id)
        {
            continue;
        }
        let rows = groups.entry(e.mission_id).or_default();
        rows.retain(|v| v["id"].as_str() != Some(&e.automation_id.to_string()));
        rows.push(serde_json::json!({"id":e.automation_id,"state": if e.error.is_some() {"error"} else if client_pending.contains(&e.id) {"waiting_for_client"} else {"queued"}, "next_at":e.triggered_at,
            "reason":e.variables_used.get("__wakeup_reason"),"error":e.error,"trigger":"delivery"}));
    }
    Ok(groups
        .into_iter()
        .map(|(id, mut items)| {
            items.sort_by_key(|v| v["next_at"].as_str().unwrap_or("9999").to_string());
            (id, serde_json::json!({"count":items.len(),"items":items}))
        })
        .collect())
}

pub async fn stage(
    store: &Arc<dyn MissionStore>,
    a: &Automation,
    prompt: String,
) -> Result<bool, String> {
    let key = a.last_triggered_at.as_deref().unwrap_or(&a.created_at);
    let mut variables = a.variables.clone();
    variables.insert("__delivery_prompt".into(), prompt);
    store
        .stage_scheduled_delivery(
            a,
            AutomationExecution {
                id: Uuid::new_v5(&a.id, key.as_bytes()),
                automation_id: a.id,
                mission_id: a.mission_id,
                triggered_at: mission_store::now_string(),
                trigger_source: "durable_schedule".into(),
                status: ExecutionStatus::Pending,
                webhook_payload: None,
                variables_used: variables,
                completed_at: None,
                error: None,
                retry_count: 0,
            },
        )
        .await
}

enum DeliveryFailure {
    Rejected(String),
    Uncertain(String),
}

pub async fn deliver(
    store: &Arc<dyn MissionStore>,
    tx: &mpsc::Sender<ControlCommand>,
    events: &broadcast::Sender<AgentEvent>,
    telegram: Option<&super::super::telegram::SharedTelegramBridge>,
) -> Result<(), String> {
    for mut e in store.list_scheduled_deliveries().await? {
        if e.variables_used
            .get("__delivery_accepted")
            .is_some_and(|v| v == "true")
        {
            continue;
        }
        if e.variables_used
            .get("__delivery_retry_at")
            .and_then(|v| v.parse::<i64>().ok())
            .is_some_and(|at| at > Utc::now().timestamp())
        {
            continue;
        }
        let mutex = lock(e.mission_id);
        let _guard = mutex.lock().await;
        // Cancellation/replacement may have won after the initial snapshot.
        if !store
            .get_automation_executions(e.automation_id, None)
            .await?
            .iter()
            .any(|r| {
                r.id == e.id
                    && !matches!(
                        r.status,
                        ExecutionStatus::Cancelled | ExecutionStatus::Skipped
                    )
                    && r.variables_used
                        .get("__delivery_accepted")
                        .is_none_or(|v| v != "true")
            })
        {
            continue;
        }
        let Some(m) = store.get_mission(e.mission_id).await? else {
            continue;
        };
        if matches!(m.status, MissionStatus::Paused | MissionStatus::Interrupted)
            && !e.variables_used.contains_key("__delivery_manual")
        {
            continue;
        }
        if store
            .get_active_mission_run(m.id)
            .await?
            .is_some_and(|r| r.execution_state != MissionExecutionState::WaitingRemoteJob)
        {
            continue;
        }
        let Some(prompt) = e.variables_used.get("__delivery_prompt").cloned() else {
            continue;
        };
        // Mark running before admission so a very fast completion cannot be
        // missed. An unacknowledged running row remains retryable after restart.
        e.status = ExecutionStatus::Running;
        store.update_automation_execution(e.clone()).await?;
        let events_rx = events.subscribe();
        let (respond, response) = oneshot::channel();
        let attempt = async {
            tx.send(ControlCommand::UserMessage {
                id: e.id,
                content: prompt,
                agent: None,
                target_mission_id: Some(m.id),
                strict: true,
                source: Some("scheduled-continuation".into()),
                respond,
            })
            .await
            .map_err(|_| DeliveryFailure::Rejected("Control queue unavailable".into()))?;
            match response.await {
                Ok(
                    UserMessageAck::Queued
                    | UserMessageAck::Delivered
                    | UserMessageAck::Continued { .. },
                ) => Ok(()),
                Ok(UserMessageAck::Rejected(error)) => Err(DeliveryFailure::Rejected(error)),
                _ => Err(DeliveryFailure::Uncertain(
                    "Delivery acknowledgement was lost".into(),
                )),
            }
        };
        let result = tokio::time::timeout(std::time::Duration::from_secs(10), attempt)
            .await
            .unwrap_or_else(|_| {
                Err(DeliveryFailure::Uncertain(
                    "Awaiting delivery acknowledgement; retrying the same message".into(),
                ))
            });
        if result.is_ok() {
            if let Some(bridge) = telegram {
                let bridge = Arc::clone(bridge);
                let store = Arc::clone(store);
                tokio::spawn(async move {
                    if let Ok(Some(mapping)) =
                        store.get_telegram_chat_mission_by_mission_id(m.id).await
                    {
                        if let Some(ctx) = bridge.get_channel_context(mapping.channel_id).await {
                            if let Err(error) = super::super::telegram::stream_response(
                                events_rx,
                                bridge.http(),
                                &ctx.channel.bot_token,
                                mapping.chat_id,
                                0,
                                None,
                                m.id,
                                Some(Arc::clone(&bridge)),
                                Some(mapping.channel_id),
                                Some(store),
                            )
                            .await
                            {
                                tracing::warn!(%error,"Could not stream wake-up response to Telegram");
                            }
                        }
                    }
                });
            }
        }
        match result {
            Ok(()) => {
                e.variables_used
                    .insert("__delivery_accepted".into(), "true".into());
                e.error = None;
            }
            Err(failure) => {
                e.error = Some(match failure {
                    DeliveryFailure::Rejected(error) => {
                        // Admission definitely did not happen. Backoff is cancellable;
                        // an uncertain/lost ACK remains running to avoid claiming that.
                        e.status = ExecutionStatus::Pending;
                        error
                    }
                    DeliveryFailure::Uncertain(error) => error,
                });
                e.retry_count = e.retry_count.saturating_add(1);
                e.variables_used.insert(
                    "__delivery_retry_at".into(),
                    (Utc::now().timestamp() + (5_i64 * (1_i64 << e.retry_count.min(6))).min(300))
                        .to_string(),
                );
            }
        }
        store.update_automation_execution(e).await?;
    }
    Ok(())
}

/// Atomic action with respect to the scheduler and other API actions.
#[derive(Deserialize)]
pub struct Action {
    pub action: String,
}
pub async fn action(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<Action>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let a = control
        .mission_store
        .get_automation(id)
        .await
        .map_err(internal_error)?
        .ok_or((StatusCode::NOT_FOUND, "Wake-up not found".into()))?;
    if !a.variables.contains_key("__wakeup_source")
        || !matches!(a.stop_policy, mission_store::StopPolicy::AfterFirstFire)
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "This action requires a one-shot wake-up".into(),
        ));
    }
    let mutex = lock(a.mission_id);
    let _guard = mutex.lock().await;
    match req.action.as_str() {
        "cancel" => {
            if control
                .mission_store
                .get_automation_executions(id, None)
                .await
                .map_err(internal_error)?
                .iter()
                .any(|e| {
                    e.trigger_source == "durable_schedule" && e.status == ExecutionStatus::Running
                })
            {
                return Err((
                    StatusCode::CONFLICT,
                    "Wake-up delivery has started; stop the mission instead".into(),
                ));
            }
            control
                .mission_store
                .cancel_scheduled_delivery(id)
                .await
                .map_err(internal_error)?;
        }
        "resume" => {
            let a = control
                .mission_store
                .get_automation(id)
                .await
                .map_err(internal_error)?
                .ok_or((StatusCode::NOT_FOUND, "Wake-up not found".into()))?;
            if !a.active {
                return Err((
                    StatusCode::CONFLICT,
                    "Wake-up already queued or cancelled".into(),
                ));
            }
            let prompt =
                resolve_automation_command(&a, a.mission_id, &state, &control.mission_store)
                    .await
                    .ok_or((StatusCode::CONFLICT, "Cannot resolve wake-up prompt".into()))?;
            let mut a = a;
            a.variables
                .insert("__delivery_manual".into(), "true".into());
            if !stage(&control.mission_store, &a, prompt)
                .await
                .map_err(internal_error)?
            {
                return Err((StatusCode::CONFLICT, "Wake-up already queued".into()));
            }
        }
        _ => return Err((StatusCode::BAD_REQUEST, "Expected cancel or resume".into())),
    }
    Ok(Json(serde_json::json!({"ok":true})))
}

/// Stop revokes future automatic work, including an unfired outbox item.
pub async fn cancel_for_mission(
    store: &Arc<dyn MissionStore>,
    mission: Uuid,
) -> Result<(), String> {
    let mutex = lock(mission);
    let _guard = mutex.lock().await;
    store.cancel_mission_continuations(mission).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::mission_store::{FreshSession, RetryConfig, SqliteMissionStore, StopPolicy};

    async fn fixture() -> (tempfile::TempDir, Arc<dyn MissionStore>, Automation) {
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().to_owned(), "test")
                .await
                .unwrap(),
        );
        let m = store
            .create_mission(Some("wake"), None, None, None, None, Some("codex"), None)
            .await
            .unwrap();
        let a = Automation {
            id: Uuid::new_v4(),
            mission_id: m.id,
            command_source: mission_store::CommandSource::Inline {
                content: "continue".into(),
            },
            trigger: TriggerType::Interval { seconds: 60 },
            variables: HashMap::from([("__wakeup_source".into(), "automation-manager".into())]),
            active: true,
            stop_policy: StopPolicy::AfterFirstFire,
            fresh_session: FreshSession::Keep,
            created_at: mission_store::now_string(),
            last_triggered_at: None,
            retry_config: RetryConfig::default(),
            consecutive_failures: 0,
            driver: AutomationDriver::Scheduler,
        };
        store.create_automation(a.clone()).await.unwrap();
        (dir, store, a)
    }

    #[tokio::test]
    async fn continuation_stage_is_atomic_and_survives_restart() {
        let (dir, store, a) = fixture().await;
        let (one, two) = tokio::join!(
            stage(&store, &a, "continue".into()),
            stage(&store, &a, "continue".into())
        );
        assert_ne!(one.unwrap(), two.unwrap());
        assert!(!store.get_automation(a.id).await.unwrap().unwrap().active);
        drop(store);
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().to_owned(), "test")
                .await
                .unwrap(),
        );
        assert_eq!(store.list_scheduled_deliveries().await.unwrap().len(), 1);
        store.cancel_scheduled_delivery(a.id).await.unwrap();
        assert!(store.list_scheduled_deliveries().await.unwrap().is_empty());
        assert!(!stage(&store, &a, "continue".into()).await.unwrap());
    }

    #[tokio::test]
    async fn continuation_replacement_cancels_pending_delivery() {
        let (_dir, store, a) = fixture().await;
        stage(&store, &a, "old".into()).await.unwrap();
        let mut replacement = a.clone();
        replacement.id = Uuid::new_v4();
        store.create_automation(replacement.clone()).await.unwrap();
        assert!(store.list_scheduled_deliveries().await.unwrap().is_empty());
        assert!(!store.get_automation(a.id).await.unwrap().unwrap().active);
        assert!(
            store
                .get_automation(replacement.id)
                .await
                .unwrap()
                .unwrap()
                .active
        );
    }

    #[tokio::test]
    async fn continuation_completion_does_not_lose_unacknowledged_delivery() {
        let (_dir, store, a) = fixture().await;
        stage(&store, &a, "continue".into()).await.unwrap();
        let mut e = store.list_scheduled_deliveries().await.unwrap().remove(0);
        e.status = ExecutionStatus::Running;
        store.update_automation_execution(e.clone()).await.unwrap();
        let mut completed = e.clone();
        completed.status = ExecutionStatus::Success;
        store.update_automation_execution(completed).await.unwrap();
        // Completion won the race with the admission ACK. Preserve it while
        // settling delivery; an old snapshot must not resurrect the execution.
        assert_eq!(store.list_scheduled_deliveries().await.unwrap().len(), 1);
        e.variables_used
            .insert("__delivery_accepted".into(), "true".into());
        store.update_automation_execution(e).await.unwrap();
        assert!(store.list_scheduled_deliveries().await.unwrap().is_empty());
        assert_eq!(
            store.get_automation_executions(a.id, None).await.unwrap()[0].status,
            ExecutionStatus::Success
        );
    }
    #[tokio::test]
    async fn continuation_replacement_cancels_rejected_running_delivery() {
        let (_dir, store, a) = fixture().await;
        stage(&store, &a, "obsolete".into()).await.unwrap();
        let mut stale = store.list_scheduled_deliveries().await.unwrap().remove(0);
        stale.status = ExecutionStatus::Running;
        stale.error = Some("Admission rejected".into());
        stale
            .variables_used
            .insert("__delivery_retry_at".into(), "9999999999".into());
        store
            .update_automation_execution(stale.clone())
            .await
            .unwrap();
        let mut replacement = a.clone();
        replacement.id = Uuid::new_v4();
        store.create_automation(replacement).await.unwrap();
        // A late delivery snapshot cannot resurrect the superseded occurrence.
        store.update_automation_execution(stale).await.unwrap();
        assert!(store.list_scheduled_deliveries().await.unwrap().is_empty());
        assert_eq!(
            store.get_automation_executions(a.id, None).await.unwrap()[0].status,
            ExecutionStatus::Cancelled
        );
    }

    #[tokio::test]
    async fn continuation_turn_predecessor_cannot_settle_successor() {
        let (_dir, store, a) = fixture().await;
        stage(&store, &a, "successor".into()).await.unwrap();
        let mut occurrence = store.list_scheduled_deliveries().await.unwrap().remove(0);
        occurrence.status = ExecutionStatus::Running;
        occurrence
            .variables_used
            .insert("__delivery_accepted".into(), "true".into());
        store
            .update_automation_execution(occurrence.clone())
            .await
            .unwrap();
        for predecessor in [None, Some(Uuid::new_v4())] {
            assert_eq!(
                store
                    .complete_turn_executions_for_mission(
                        a.mission_id,
                        predecessor,
                        false,
                        Some("predecessor interrupted".into())
                    )
                    .await
                    .unwrap(),
                0
            );
        }
        assert_eq!(
            store.get_automation_executions(a.id, None).await.unwrap()[0].status,
            ExecutionStatus::Running
        );
        assert_eq!(
            store
                .complete_turn_executions_for_mission(a.mission_id, Some(occurrence.id), true, None)
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            store.get_automation_executions(a.id, None).await.unwrap()[0].status,
            ExecutionStatus::Success
        );
    }

    #[tokio::test]
    async fn continuation_remote_handoff_survives_restart_and_late_admission() {
        let (dir, store, a) = fixture().await;
        stage(&store, &a, "validate remotely".into()).await.unwrap();
        let mut snapshot = store.list_scheduled_deliveries().await.unwrap().remove(0);
        snapshot.status = ExecutionStatus::Running;
        store
            .update_automation_execution(snapshot.clone())
            .await
            .unwrap();
        let job = Uuid::new_v4();
        crate::remote_node::job_ledger::record(
            dir.path(),
            crate::remote_node::job_ledger::JobHandle {
                mission_id: a.mission_id,
                node_id: "test".into(),
                job_id: job,
                started_at: Utc::now(),
                submission_sequence: 0,
                accepted_at: Some(Utc::now()),
                heartbeat_at: Some(Utc::now()),
                disk_reservation_bytes: 0,
                kind: crate::remote_node::job_ledger::JobHandleKind::RemoteBuild,
                identity: None,
                wait_for_completion: Some(true),
                wake_on_terminal: true,
            },
        )
        .await
        .unwrap();
        store
            .update_mission_status(a.mission_id, MissionStatus::Active)
            .await
            .unwrap();
        store
            .begin_mission_run(a.mission_id, "test", None)
            .await
            .unwrap();
        let parked = mission_should_park_on_remote_build(&store, dir.path(), a.mission_id).await;
        assert_eq!(parked, Some(job));
        park_scheduled_remote_execution(&store, a.mission_id, Some(snapshot.id), parked.unwrap())
            .await;
        // Admission can settle after the remote handoff; it must retain the alias.
        snapshot
            .variables_used
            .insert("__delivery_accepted".into(), "true".into());
        store
            .update_automation_execution(snapshot.clone())
            .await
            .unwrap();
        drop(store);
        let store = SqliteMissionStore::new(dir.path().to_owned(), "test")
            .await
            .unwrap();
        let next = remote_build_terminal_delivery_id(job);
        assert_eq!(
            store
                .complete_turn_executions_for_mission(a.mission_id, Some(snapshot.id), false, None)
                .await
                .unwrap(),
            0
        );
        assert_eq!(
            store
                .complete_turn_executions_for_mission(a.mission_id, Some(next), true, None)
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            store.get_automation_executions(a.id, None).await.unwrap()[0].status,
            ExecutionStatus::Success
        );
    }

    #[tokio::test]
    async fn continuation_deferred_batch_settles_all_constituents_and_survives_handoff() {
        let (_dir, store, a) = fixture().await;
        stage(&store, &a, "first".into()).await.unwrap();
        let mut first = store.list_scheduled_deliveries().await.unwrap().remove(0);
        first.status = ExecutionStatus::Running;
        first
            .variables_used
            .insert("__delivery_accepted".into(), "true".into());
        store
            .update_automation_execution(first.clone())
            .await
            .unwrap();
        let mut other = a.clone();
        other.id = Uuid::new_v4();
        store.create_automation(other.clone()).await.unwrap();
        stage(&store, &other, "second".into()).await.unwrap();
        let mut second = store
            .get_automation_executions(other.id, None)
            .await
            .unwrap()
            .remove(0);
        second.status = ExecutionStatus::Running;
        second
            .variables_used
            .insert("__delivery_accepted".into(), "true".into());
        store
            .update_automation_execution(second.clone())
            .await
            .unwrap();
        let content = deferred_messages::join(
            &deferred_messages::encode(first.id, "first"),
            &deferred_messages::encode(second.id, "second"),
        );
        let outer = Uuid::new_v4();
        let ids = deferred_messages::execution_ids(outer, &content, Some("scheduler"));
        assert_eq!(ids, vec![first.id, second.id]);
        bind_turn(&store, Some(a.mission_id), Some(outer), ids).await;
        // A remote-build continuation can move the whole batch again.
        let terminal = Uuid::new_v4();
        assert_eq!(
            store
                .handoff_scheduled_executions(a.mission_id, vec![outer], terminal)
                .await
                .unwrap(),
            2
        );
        store
            .update_automation_execution(first.clone())
            .await
            .unwrap();
        assert_eq!(
            store
                .complete_turn_executions_for_mission(a.mission_id, Some(outer), false, None)
                .await
                .unwrap(),
            0
        );
        assert_eq!(
            store
                .complete_turn_executions_for_mission(a.mission_id, Some(terminal), true, None)
                .await
                .unwrap(),
            2
        );
        for id in [a.id, other.id] {
            assert_eq!(
                store.get_automation_executions(id, None).await.unwrap()[0].status,
                ExecutionStatus::Success
            );
        }
    }

    #[tokio::test]
    async fn continuation_acknowledged_mission_still_receives_due_wakeup() {
        let (_dir, store, a) = fixture().await;
        store
            .update_mission_status(a.mission_id, MissionStatus::Acknowledged)
            .await
            .unwrap();
        stage(&store, &a, "resume after reading".into())
            .await
            .unwrap();
        let (tx, mut rx) = mpsc::channel(1);
        let (events, _) = broadcast::channel(8);
        let receive = tokio::spawn(async move {
            let Some(ControlCommand::UserMessage {
                respond, content, ..
            }) = rx.recv().await
            else {
                panic!("expected delivery")
            };
            assert_eq!(content, "resume after reading");
            respond.send(UserMessageAck::Queued).unwrap();
        });
        deliver(&store, &tx, &events, None).await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), receive)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            store.get_automation_executions(a.id, None).await.unwrap()[0].variables_used
                ["__delivery_accepted"],
            "true"
        );
    }

    #[tokio::test]
    async fn continuation_rejected_admission_can_be_cancelled_during_backoff() {
        let (_dir, store, a) = fixture().await;
        stage(&store, &a, "continue".into()).await.unwrap();
        let (tx, mut rx) = mpsc::channel(1);
        let (events, _) = broadcast::channel(8);
        let reject = tokio::spawn(async move {
            let Some(ControlCommand::UserMessage { respond, .. }) = rx.recv().await else {
                panic!("expected delivery")
            };
            respond
                .send(UserMessageAck::Rejected("No capacity".into()))
                .unwrap();
        });
        deliver(&store, &tx, &events, None).await.unwrap();
        reject.await.unwrap();
        let pending = store.list_scheduled_deliveries().await.unwrap().remove(0);
        assert_eq!(pending.status, ExecutionStatus::Pending);
        assert_eq!(pending.error.as_deref(), Some("No capacity"));
        assert!(pending.variables_used.contains_key("__delivery_retry_at"));
        store.cancel_scheduled_delivery(a.id).await.unwrap();
        assert!(store.list_scheduled_deliveries().await.unwrap().is_empty());
        assert_eq!(
            store.get_automation_executions(a.id, None).await.unwrap()[0].status,
            ExecutionStatus::Cancelled
        );
    }

    #[tokio::test]
    async fn continuation_ack_preserves_fast_failure_reason() {
        let (_dir, store, a) = fixture().await;
        stage(&store, &a, "continue".into()).await.unwrap();
        let mut stale = store.list_scheduled_deliveries().await.unwrap().remove(0);
        stale.status = ExecutionStatus::Running;
        store
            .update_automation_execution(stale.clone())
            .await
            .unwrap();
        let mut failed = stale.clone();
        failed.status = ExecutionStatus::Failed;
        failed.error = Some("Provider failed".into());
        failed.completed_at = Some(mission_store::now_string());
        store
            .update_automation_execution(failed.clone())
            .await
            .unwrap();
        stale
            .variables_used
            .insert("__delivery_accepted".into(), "true".into());
        store.update_automation_execution(stale).await.unwrap();
        let saved = store
            .get_automation_executions(a.id, None)
            .await
            .unwrap()
            .remove(0);
        assert_eq!(saved.status, ExecutionStatus::Failed);
        assert_eq!(saved.error, failed.error);
        assert_eq!(saved.completed_at, failed.completed_at);
        assert!(store.list_scheduled_deliveries().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn continuation_stop_cancels_outbox_and_rejects_late_ack() {
        let (_dir, store, a) = fixture().await;
        stage(&store, &a, "continue".into()).await.unwrap();
        let mut execution = store.list_scheduled_deliveries().await.unwrap().remove(0);
        execution.status = ExecutionStatus::Running;
        store
            .update_automation_execution(execution.clone())
            .await
            .unwrap();
        worker_location::enqueue_with_source(
            &store,
            a.mission_id,
            execution.id,
            "continue".into(),
            true,
        )
        .await
        .unwrap();
        cancel_for_mission(&store, a.mission_id).await.unwrap();
        assert!(store
            .list_pending_board_outbox(10)
            .await
            .unwrap()
            .is_empty());
        execution
            .variables_used
            .insert("__delivery_accepted".into(), "true".into());
        store.update_automation_execution(execution).await.unwrap();
        assert!(store.list_scheduled_deliveries().await.unwrap().is_empty());
        assert_eq!(
            store.get_automation_executions(a.id, None).await.unwrap()[0].status,
            ExecutionStatus::Cancelled
        );
    }
}

pub async fn cancel_all(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    if control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .is_none()
    {
        return Err((StatusCode::NOT_FOUND, "Mission not found".into()));
    }
    cancel_for_mission(&control.mission_store, id)
        .await
        .map_err(internal_error)?;
    Ok(Json(serde_json::json!({"ok":true})))
}

pub fn attach_capabilities(value: &mut serde_json::Value) {
    let backend = value["backend"].as_str().unwrap_or("");
    let local = value["tags"]
        .as_array()
        .is_some_and(|tags| tags.iter().any(|v| v.as_str() == Some("placement:client")));
    value["scheduling"] = serde_json::json!({
        "owner":"sandboxed", "durable":true,
        "native_schedule_wakeup":backend == "claudecode",
        "native_cron":false,
        "transport":match (backend, local) { ("grok",true)=>"local_command", ("grok",false)=>"acp_mcp", ("codex"|"opencode"|"claudecode",_)=>"mcp", _=>"unavailable" },
    });
}

pub async fn ensure_cancellable(
    store: &Arc<dyn MissionStore>,
    id: Uuid,
) -> Result<(), (StatusCode, String)> {
    if store
        .get_automation_executions(id, None)
        .await
        .map_err(internal_error)?
        .iter()
        .any(|e| e.trigger_source == "durable_schedule" && e.status == ExecutionStatus::Running)
    {
        return Err((
            StatusCode::CONFLICT,
            "Wake-up delivery has started; stop the mission instead".into(),
        ));
    }
    Ok(())
}
