//! HTTP handlers for posting messages, tool results, cancel and queue management.

use super::*;

/// Enqueue a user message for the global control session.
/// If mission_id is provided and differs from the currently running mission,
/// the backend will automatically start it in parallel (if capacity allows).
pub async fn post_message(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(mut req): Json<ControlMessageRequest>,
) -> Result<Json<ControlMessageResponse>, (StatusCode, String)> {
    let content = req.content.trim().to_string();
    if content.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "content is required".to_string()));
    }
    // Strip any `/api/uploads` receipt paths that older mobile builds duplicated
    // into `req.attachments` alongside `[Uploaded: <path>]` in `content`.
    if let Some(attachments) = req.attachments.as_mut() {
        attachments.retain(|item| {
            !(item.kind == crate::api::mission_payload::AttachmentKind::File
                && item
                    .path
                    .as_deref()
                    .map(|p| p.starts_with('/') && content.contains(&format!("[Uploaded: {p}]")))
                    .unwrap_or(false))
        });
    }
    crate::api::mission_payload::validate_user_content(&content)
        .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
    let admission_control = control_for_user(&state, &user).await;
    if let Some(id) = req.mission_id {
        cyber::validate_remote_mission(&state, &admission_control, id)
            .await
            .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    }
    let cloud_store = state.control.get_or_spawn(&user).await.mission_store;
    if let Some(response) = super::super::cloud_agents::http::follow_up(cloud_store, &req).await? {
        return Ok(response);
    }
    let id = req.client_message_id.unwrap_or_else(Uuid::new_v4);
    let agent = req.agent;
    let target_mission_id = req.mission_id;
    // Fail loud on unrecognized fields (see ControlMessageRequest::extra).
    let mut warnings: Vec<String> = Vec::new();
    if !req.extra.is_empty() {
        let ignored: Vec<&str> = req.extra.keys().map(String::as_str).collect();
        let joined = ignored.join(",");
        tracing::warn!(
            user_id = %user.id,
            ignored_fields = %joined,
            "control message request carried unrecognized fields (ignored)"
        );
        warnings.push(format!("unrecognized fields ignored: {joined}"));
    }
    if req.continue_identity.is_some() && target_mission_id.is_none() {
        return Err((
            StatusCode::BAD_REQUEST,
            "continue_identity requires an explicit mission_id".into(),
        ));
    }
    // A real user message means the operator is steering this mission — reset
    // its stall-guard budget so future genuine stalls get the full allowance.
    if let Some(mid) = target_mission_id {
        reset_stall_guard(mid);
    }
    let control = control_for_user(&state, &user).await;
    if let Some(mid) = target_mission_id {
        machine_transfer::guard(&control.mission_store, mid)
            .await
            .map_err(internal_error)?;
        if mission_is_client_placed(&control, mid)
            .await
            .map_err(internal_error)?
        {
            if req
                .attachments
                .as_ref()
                .is_some_and(|items| !items.is_empty())
            {
                return Err((
                    StatusCode::BAD_REQUEST,
                    "Attach files from the owning Orb computer".into(),
                ));
            }
            worker_location::enqueue(&control.mission_store, mid, id, content)
                .await
                .map_err(internal_error)?;
            return Ok(Json(ControlMessageResponse {
                id,
                queued: true,
                message_accepted: true,
                mission_id: Some(mid),
                previous_execution: None,
                warnings,
            }));
        }
        if let Some(placement) =
            remote_grok::placement(&state.config.working_dir, &control.mission_store, mid)
                .await
                .map_err(internal_error)?
        {
            if req.attachments.as_ref().is_some_and(|a| {
                a.iter().any(|item| {
                    !matches!(
                        item.kind,
                        crate::api::mission_payload::AttachmentKind::Context
                            | crate::api::mission_payload::AttachmentKind::Path
                    )
                })
            }) {
                return Err((
                    StatusCode::BAD_REQUEST,
                    "remote follow-up attachments are not supported".into(),
                ));
            }
            if agent.is_some()
                || req.github_pr.is_some()
                || req.track.is_some()
                || req.title.is_some()
            {
                return Err((StatusCode::CONFLICT, format!("{}: remote continuation supports content only; use a linked replacement for agent or writer identity changes", remote_grok::REMOTE_RESUME_REQUIRES_REPLACEMENT)));
            }
            let content =
                if let Some(attachments) = req.attachments.as_ref().filter(|a| !a.is_empty()) {
                    let mission = control
                        .mission_store
                        .get_mission(mid)
                        .await
                        .map_err(internal_error)?
                        .ok_or((StatusCode::NOT_FOUND, "mission not found".into()))?;
                    let payload = crate::api::mission_payload::MissionPayload {
                        attachments: attachments.clone(),
                        project: mission.project.project,
                        controller_md: None,
                    };
                    crate::api::mission_payload::stage_message(
                        &state.config.working_dir,
                        mid,
                        id,
                        &content,
                        &payload,
                    )
                    .map_err(|e| (StatusCode::BAD_REQUEST, format!("attachments: {e}")))?
                    .0
                } else {
                    content
                };
            let content = crate::api::uploads::forward_core_uploads_in_prompt(
                &state,
                &placement.node_id,
                &content,
            )
            .await?;
            remote_queue::enqueue(
                &state,
                &control,
                &user.id,
                mid,
                req.continue_identity.as_ref(),
                content,
                id,
            )
            .await?;
            // Idle continuations retain their immediate-delivery behavior.
            // A racing dispatch or temporary failure leaves the durable entry
            // queued for the same-node retry loop; permanent continuation
            // refusals withdraw the unsubmitted entry and surface immediately.
            if !placement.live {
                if let Err((status, error)) =
                    remote_grok::deliver_queued(&state, &control, &user.id, mid, placement, id)
                        .await
                {
                    if error.starts_with(remote_grok::REMOTE_RESUME_REQUIRES_REPLACEMENT)
                        || error.starts_with(remote_grok::REMOTE_AUTH_REQUIRED)
                    {
                        let _ = remote_queue::finish(&state.projects, &user.id, id, "cancelled");
                        return Err((status, error));
                    }
                }
            }
            let queued =
                remote_queue::is_waiting(&state.projects, &user.id, id).map_err(internal_error)?;
            return Ok(Json(ControlMessageResponse {
                id,
                queued,
                message_accepted: true,
                mission_id: Some(mid),
                previous_execution: None,
                warnings,
            }));
        }
    }
    let content = if let Some(attachments) = req.attachments.as_ref().filter(|a| !a.is_empty()) {
        let mid = target_mission_id.ok_or((
            StatusCode::BAD_REQUEST,
            "attachments require mission_id".into(),
        ))?;
        let mission = control
            .mission_store
            .get_mission(mid)
            .await
            .map_err(internal_error)?
            .ok_or((StatusCode::NOT_FOUND, "mission not found".into()))?;
        let mut payload = crate::api::mission_payload::MissionPayload {
            attachments: attachments.clone(),
            project: mission.project.project.clone(),
            controller_md: None,
        };
        if attachments
            .iter()
            .any(|a| a.kind == crate::api::mission_payload::AttachmentKind::Controller)
        {
            if let Some(project) = payload.project.as_deref() {
                payload.controller_md = Some(
                    super::super::projects_overview::controller_snapshot_markdown(&state, project)
                        .await,
                );
            }
        }
        let (content, report) = crate::api::mission_payload::stage_message(
            &state.config.working_dir,
            mid,
            id,
            &content,
            &payload,
        )
        .map_err(|e| (StatusCode::BAD_REQUEST, format!("attachments: {e}")))?;
        if !report.skipped.is_empty() || report.truncated {
            warnings.push(format!("Some attachments were skipped or capped; see .paloma/messages/{id}/.paloma/attach.md"));
        }
        content
    } else {
        content
    };
    let (queued_tx, queued_rx) = oneshot::channel();
    tracing::info!(
        user_id = %user.id,
        username = %user.username,
        message_id = %id,
        content_len = content.len(),
        agent = ?agent,
        target_mission_id = ?target_mission_id,
        "Received control message"
    );
    control
        .cmd_tx
        .send(ControlCommand::AdmitDispatch {
            admission: Box::new(DispatchAdmission {
                internal_work_hint: None,
                state: state.clone(),
                store: control.mission_store.clone(),
                patch: dispatch_identity_patch(
                    req.github_pr,
                    req.track,
                    req.title,
                    Some(content.clone()),
                    req.continue_identity,
                ),
            }),
            command: Box::new(ControlCommand::UserMessage {
                id,
                content,
                agent,
                target_mission_id,
                strict: false,
                source: Some(format!(
                    "{}api:{}",
                    if req.queue_followup {
                        "host-queue:"
                    } else {
                        ""
                    },
                    user.id
                )),
                respond: queued_tx,
            }),
        })
        .await
        .map_err(session_unavailable)?;
    #[cfg(test)]
    if let Some(mission_id) = target_mission_id {
        dispatch_admission_tests::notify_wait(mission_id, "enqueued");
    }
    let (queued, message_accepted, previous_execution) = match queued_rx.await {
        Ok(UserMessageAck::Queued) => (true, true, None),
        Ok(UserMessageAck::Delivered) => (false, true, None),
        Ok(UserMessageAck::Continued {
            queued,
            previous_execution,
        }) => (queued, true, Some(previous_execution)),
        Ok(UserMessageAck::Dropped) => (false, false, None),
        Ok(UserMessageAck::Rejected(reason)) => {
            return Err((StatusCode::CONFLICT, reason));
        }
        Err(error) => return Err(recv_failed(error)),
    };
    Ok(Json(ControlMessageResponse {
        id,
        queued,
        message_accepted,
        mission_id: target_mission_id,
        previous_execution,
        warnings,
    }))
}

/// Submit a frontend tool result to resume the running agent.
pub async fn post_tool_result(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(req): Json<ControlToolResultRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if req.tool_call_id.trim().is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "tool_call_id is required".to_string(),
        ));
    }
    if req.name.trim().is_empty() {
        return Err((StatusCode::BAD_REQUEST, "name is required".to_string()));
    }

    let control = control_for_user(&state, &user).await;
    let (tx, rx) = oneshot::channel();
    control
        .cmd_tx
        .send(ControlCommand::ToolResult {
            tool_call_id: req.tool_call_id,
            name: req.name,
            result: req.result,
            respond: tx,
        })
        .await
        .map_err(session_unavailable)?;

    // Surface whether the answer reached a live, parked mission. When it did
    // not, the mission has already ended (e.g. interrupted by the watchdog)
    // and the answer was dropped — the UI uses this to stop claiming success
    // and offer a resume instead.
    let delivered = rx.await.unwrap_or(false);
    Ok(Json(
        serde_json::json!({ "ok": true, "delivered": delivered }),
    ))
}

/// Cancel the currently running control session task.
pub async fn post_cancel(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    control
        .cmd_tx
        .send(ControlCommand::Cancel)
        .await
        .map_err(session_unavailable)?;
    Ok(ok_json())
}

// ==================== Queue Management Endpoints ====================

#[derive(Deserialize, Default)]
pub struct QueueQuery {
    pub mission_id: Option<Uuid>,
}

/// Get the current message queue, including durable scheduled/capacity deferrals
/// when requesting a mission. The control store is scoped to the authenticated user.
pub(super) const QUEUE_ACTOR_WAIT: std::time::Duration = std::time::Duration::from_millis(1500);

pub(super) fn queue_unavailable() -> (StatusCode, String) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        "failed to get queue".to_string(),
    )
}

pub async fn get_queue(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Query(query): Query<QueueQuery>,
) -> Result<Json<Vec<QueuedMessage>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let (tx, rx) = oneshot::channel();
    control
        .cmd_tx
        .send(ControlCommand::GetQueue { respond: tx })
        .await
        .map_err(session_unavailable)?;
    // A busy actor can hold this read for longer than clients wait (Orb aborts
    // at 30 s). A mission-scoped read is answered from the durable snapshot
    // below, which the actor persists after every change; the live queue only
    // adds entries enqueued since its last persist, so a short wait suffices.
    let mut queue = if query.mission_id.is_some() {
        match tokio::time::timeout(QUEUE_ACTOR_WAIT, rx).await {
            Ok(Ok(queue)) => queue,
            Ok(Err(_)) => return Err(queue_unavailable()),
            Err(_) => {
                tracing::debug!("control actor busy; answering queue read from durable snapshot");
                Vec::new()
            }
        }
    } else {
        rx.await.map_err(|_| queue_unavailable())?
    };
    queue.extend(
        remote_queue::waiting(&state.projects, Some(&user.id))
            .map_err(internal_error)?
            .into_iter()
            .map(|row| row.message),
    );
    if let Some(mid) = query.mission_id {
        let mission = control
            .mission_store
            .get_mission(mid)
            .await
            .map_err(internal_error)?
            .ok_or((StatusCode::NOT_FOUND, "mission not found".into()))?;
        queue.retain(|entry| entry.mission_id == Some(mid));
        // The asynchronous transcript logger can lag dispatch. The durable
        // snapshot retains `inflight=true` only after a run lease was acquired,
        // so a fresh reader can reconcile that ID even before history catches up.
        // Keep the unscoped queue's existing pending-only contract unchanged.
        let durable = control
            .mission_store
            .load_control_queue(&user.id)
            .await
            .map_err(internal_error)?;
        if !durable.is_empty() {
            let persisted: Vec<QueuedMessage> =
                serde_json::from_str(&durable).map_err(internal_error)?;
            let mut snapshot = Vec::new();
            for entry in persisted
                .into_iter()
                .filter(|entry| entry.mission_id == Some(mid))
            {
                let parts = if entry.source.as_deref() == Some("scheduler") {
                    deferred_messages::decode(&entry.content).1
                } else {
                    Vec::new()
                };
                if parts.is_empty() {
                    snapshot.push(entry);
                } else {
                    for (id, content) in parts {
                        snapshot.push(QueuedMessage {
                            id,
                            content,
                            agent: entry.agent.clone(),
                            mission_id: entry.mission_id,
                            source: entry.source.clone(),
                            inflight: entry.inflight,
                            queue_error: None,
                        });
                    }
                }
            }
            let ids: HashSet<Uuid> = snapshot.iter().map(|entry| entry.id).collect();
            snapshot.extend(queue.into_iter().filter(|entry| !ids.contains(&entry.id)));
            queue = snapshot;
        }
        if mission.status == MissionStatus::Pending {
            if let Some(goal) = control
                .mission_store
                .get_deferred_goal(mid)
                .await
                .map_err(internal_error)?
            {
                let mut deferred: Vec<QueuedMessage> = deferred_messages::decode(&goal)
                    .1
                    .into_iter()
                    .map(|(id, content)| QueuedMessage {
                        id,
                        content,
                        agent: None,
                        mission_id: Some(mid),
                        source: Some("scheduler".into()),
                        inflight: false,
                        queue_error: None,
                    })
                    .collect();
                let delivered: HashSet<Uuid> = queue
                    .iter()
                    .filter(|entry| entry.inflight)
                    .map(|entry| entry.id)
                    .collect();
                deferred.retain(|entry| !delivered.contains(&entry.id));
                let ids: HashSet<Uuid> = deferred.iter().map(|entry| entry.id).collect();
                deferred.extend(queue.into_iter().filter(|entry| !ids.contains(&entry.id)));
                queue = deferred;
            }
        }
    }
    let mut blockers = HashMap::new();
    for entry in &mut queue {
        if !host_followup_source(entry.source.as_deref()) || entry.inflight {
            continue;
        }
        if let Some(mid) = entry.mission_id {
            let mission = control
                .mission_store
                .get_mission(mid)
                .await
                .map_err(internal_error)?;
            if let Some(mission) = mission.as_ref() {
                if !mission_is_pr_writer_in_store(&control.mission_store, mission)
                    .await
                    .map_err(internal_error)?
                    && !message_requests_pr_writer(mission, &entry.content)
                {
                    entry.queue_error = None;
                    continue;
                }
            }
            if let std::collections::hash_map::Entry::Vacant(slot) = blockers.entry(mid) {
                let error = if let Some(mission) = mission {
                    if let Some(pr) = mission.project.github_pr.as_deref() {
                        find_existing_pr_writer_global(&state.control, pr, Some(mid))
                            .await
                            .map_err(internal_error)?
                            .map(|owner| format!("Waiting for PR writer {}", owner.id))
                    } else {
                        None
                    }
                } else {
                    Some("Mission no longer exists".into())
                };
                slot.insert(error);
            }
            entry.queue_error = blockers.get(&mid).cloned().flatten();
        }
    }
    Ok(Json(queue))
}

/// Remove a message from the queue.
pub async fn remove_from_queue(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(message_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    {
        let _guard = DISPATCH_ADMISSION.lock().await;
        let _file = dispatch_admission::durable_lock(&state.config)
            .await
            .map_err(internal_error)?;
        if remote_queue::finish(&state.projects, &user.id, message_id, "cancelled")
            .map_err(internal_error)?
        {
            return Ok(ok_json());
        }
        if remote_queue::is_waiting(&state.projects, &user.id, message_id)
            .map_err(internal_error)?
        {
            return Err((StatusCode::CONFLICT,"Delivery has already started; this message can no longer be removed from the queue".into()));
        }
    }
    let (tx, rx) = oneshot::channel();
    control
        .cmd_tx
        .send(ControlCommand::RemoveFromQueue {
            message_id,
            respond: tx,
        })
        .await
        .map_err(session_unavailable)?;
    let removed = rx.await.map_err(|_| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            "failed to remove from queue".to_string(),
        )
    })?;
    if removed {
        Ok(ok_json())
    } else {
        Err((StatusCode::NOT_FOUND, "message not in queue".to_string()))
    }
}

/// Body of `PATCH /api/control/queue/:id`.
#[derive(Debug, Deserialize)]
pub struct EditQueuedMessage {
    pub content: String,
}

/// Edit a queued remote follow-up in place: same id, same FIFO position.
/// `409` when the message was already delivered (or a node job is bound to
/// it), `404` when no durable follow-up has this id, so older clients and
/// in-memory host-queue rows keep using delete + resend.
pub async fn edit_queued_message(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(message_id): Path<Uuid>,
    Json(body): Json<EditQueuedMessage>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let content = body.content.trim();
    if content.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "A queued message cannot be empty; remove it instead".into(),
        ));
    }
    // Delivery reads the content under dispatch admission: an edit either
    // lands before the pump binds a job or is refused, never half applied.
    let _guard = DISPATCH_ADMISSION.lock().await;
    let _file = dispatch_admission::durable_lock(&state.config)
        .await
        .map_err(internal_error)?;
    match remote_queue::edit(&state.projects, &user.id, message_id, content)
        .map_err(internal_error)?
    {
        remote_queue::EditOutcome::Edited => Ok(Json(
            serde_json::json!({ "ok": true, "id": message_id, "content": content }),
        )),
        remote_queue::EditOutcome::AlreadyDelivered => Err((
            StatusCode::CONFLICT,
            "This message was already sent; it can no longer be edited".into(),
        )),
        remote_queue::EditOutcome::NotFound => {
            Err((StatusCode::NOT_FOUND, "message not in queue".into()))
        }
    }
}

/// Deliver a queued message immediately to a running turn when the harness
/// supports live mid-turn user message injection, without cancelling the turn.
/// Returns `{"ok": true, "delivered": true}` when injected live, or
/// `{"ok": true, "delivered": false}` when live mid-turn injection is not
/// available so the caller can fall back to stop + restart.
/// Query for `repair_borrowed_tracks`.
#[derive(Debug, Default, Deserialize)]
pub struct RepairTracksQuery {
    /// Report what would change without writing (default true: applying
    /// requires an explicit `dry_run=false`).
    #[serde(default)]
    pub dry_run: Option<bool>,
}

/// `POST /api/control/repair/borrowed-tracks`: idempotent one-off repair that
/// moves each non-active mission off another mission's generated track key
/// onto its own, together with its live leases. See `track_repair`.
pub async fn repair_borrowed_tracks(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Query(query): Query<RepairTracksQuery>,
) -> Result<Json<super::super::track_repair::TrackRepairReport>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let dry_run = query.dry_run.unwrap_or(true);
    // Serialize with dispatch: admission reads and writes the same identity.
    let _guard = DISPATCH_ADMISSION.lock().await;
    let _file = dispatch_admission::durable_lock(&state.config)
        .await
        .map_err(internal_error)?;
    super::super::track_repair::repair_borrowed_generated_tracks(
        &state.projects,
        &control.mission_store,
        dry_run,
    )
    .await
    .map(Json)
    .map_err(internal_error)
}

/// Query for `send_queued_now`.
#[derive(Debug, Default, Deserialize)]
pub struct SendQueuedNowQuery {
    /// For a durable remote follow-up (no live injection): stop the current
    /// turn and deliver THIS message next under its same id.
    #[serde(default)]
    pub interrupt: bool,
}

pub async fn send_queued_now(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(message_id): Path<Uuid>,
    query: Option<Query<SendQueuedNowQuery>>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let interrupt = query.is_some_and(|q| q.interrupt);
    let control = control_for_user(&state, &user).await;
    let promoted_mission = {
        let _guard = DISPATCH_ADMISSION.lock().await;
        let _file = dispatch_admission::durable_lock(&state.config)
            .await
            .map_err(internal_error)?;
        if remote_queue::is_waiting(&state.projects, &user.id, message_id)
            .map_err(internal_error)?
        {
            if !interrupt {
                return Ok(Json(serde_json::json!({ "ok": true, "delivered": false })));
            }
            let mission =
                remote_queue::promote(&state.projects, &user.id, message_id).map_err(|error| {
                    if error == "message not in queue" {
                        (StatusCode::NOT_FOUND, error)
                    } else {
                        (StatusCode::CONFLICT, error)
                    }
                })?;
            tracing::info!(mission_id = %mission, %message_id, "send-now promoted remote follow-up; interrupting current turn");
            Some(mission)
        } else {
            None
        }
    };
    if let Some(mission_id) = promoted_mission {
        // The actor takes dispatch admission itself, so the guard above is
        // released first. The promoted row stays waiting with its same id;
        // the remote queue pump delivers it once the stopped job is terminal.
        let (tx, rx) = oneshot::channel();
        control
            .cmd_tx
            .send(ControlCommand::CancelMission {
                mission_id,
                min_idle: None,
                keep_remote_queue: true,
                respond: tx,
            })
            .await
            .map_err(session_unavailable)?;
        // Nothing running (already between turns) is fine: the pump delivers.
        if let Err(error) = rx.await.map_err(recv_failed)? {
            tracing::debug!(%mission_id, %error, "send-now interrupt found no running turn");
        }
        // Between turns the promoted row is deliverable now; otherwise the
        // job's poll loop wakes the pump again once the node confirms the stop.
        remote_queue::wake();
        return Ok(Json(serde_json::json!({
            "ok": true,
            "delivered": false,
            "promoted": true,
        })));
    }
    let (tx, rx) = oneshot::channel();
    control
        .cmd_tx
        .send(ControlCommand::SendQueuedNow {
            message_id,
            respond: tx,
        })
        .await
        .map_err(session_unavailable)?;
    match rx.await.map_err(|_| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            "failed to send queued message now".to_string(),
        )
    })? {
        Ok(delivered) => Ok(Json(serde_json::json!({
            "ok": true,
            "delivered": delivered,
        }))),
        Err(err) if err == "message not in queue" => Err((StatusCode::NOT_FOUND, err)),
        Err(err) => Err((StatusCode::CONFLICT, err)),
    }
}

/// Query parameters for `clear_queue`.
#[derive(Debug, Default, Deserialize)]
pub struct ClearQueueQuery {
    /// When set, only clear messages targeting this mission instead of
    /// wiping every mission's queue.
    #[serde(default)]
    pub mission_id: Option<Uuid>,
}

/// Clear queued messages (optionally scoped to a single mission via
/// `?mission_id=`).
pub async fn clear_queue(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Query(query): Query<ClearQueueQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let remote_cleared = {
        let _guard = DISPATCH_ADMISSION.lock().await;
        let _file = dispatch_admission::durable_lock(&state.config)
            .await
            .map_err(internal_error)?;
        remote_queue::cancel_all(&state.projects, &user.id, query.mission_id)
            .map_err(internal_error)?
    };
    let (tx, rx) = oneshot::channel();
    control
        .cmd_tx
        .send(ControlCommand::ClearQueue {
            mission_id: query.mission_id,
            respond: tx,
        })
        .await
        .map_err(session_unavailable)?;
    let cleared = rx.await.map_err(|_| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            "failed to clear queue".to_string(),
        )
    })?;
    Ok(Json(
        serde_json::json!({ "ok": true, "cleared": cleared + remote_cleared }),
    ))
}
