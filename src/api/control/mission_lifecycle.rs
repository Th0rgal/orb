//! Mission lifecycle handlers: parallel start, cancel, pause, clone, resume, delete and cleanup.

use super::*;

/// Request body for starting a mission in parallel.
#[derive(Debug, Deserialize)]
pub struct StartParallelRequest {
    pub content: String,
}

/// Start a mission in parallel (if capacity allows).
pub async fn start_mission_parallel(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
    Json(req): Json<StartParallelRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let (tx, rx) = oneshot::channel();

    let control = control_for_user(&state, &user).await;
    control
        .cmd_tx
        .send(ControlCommand::StartParallel {
            mission_id,
            content: req.content,
            respond: tx,
        })
        .await
        .map_err(session_unavailable)?;

    rx.await
        .map_err(recv_failed)?
        .map(|_| Json(serde_json::json!({ "ok": true, "mission_id": mission_id })))
        .map_err(|e| (StatusCode::CONFLICT, e))
}

/// Cancel a specific mission.
pub async fn cancel_mission(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let (tx, rx) = oneshot::channel();

    let control = control_for_user(&state, &user).await;
    if control
        .mission_store
        .cloud_executions()
        .await
        .map_err(internal_error)?
        .iter()
        .any(|e| e.mission_id == mission_id)
    {
        return super::super::cloud_agents::http::cancel(
            State(state),
            Extension(user),
            Path(mission_id),
        )
        .await;
    }
    if mission_is_client_placed(&control, mission_id)
        .await
        .map_err(internal_error)?
    {
        return Err((
            StatusCode::CONFLICT,
            "Stop this mission on its Orb computer so termination can be confirmed".into(),
        ));
    }
    machine_transfer::guard(&control.mission_store, mission_id)
        .await
        .map_err(internal_error)?;
    // A job on a provably destroyed managed VM can never confirm its own
    // cancellation: settle it as lost so cancel actually releases the mission.
    super::remote_jobs::release_jobs_on_gone_nodes(
        &state.config.working_dir,
        control.mission_store.as_ref(),
        mission_id,
    )
    .await
    .map_err(internal_error)?;
    // Disarm before cancelling: Stop must end the goal loop even when no turn
    // is running (between two goal iterations), and the trailing `paused`
    // status of the cancelled turn no longer re-arms it.
    disarm_goal_on_user_stop(&control.mission_store, &control.events_tx, mission_id)
        .await
        .map_err(internal_error)?;
    control
        .cmd_tx
        .send(ControlCommand::CancelMission {
            mission_id,
            min_idle: None,
            keep_remote_queue: false,
            respond: tx,
        })
        .await
        .map_err(session_unavailable)?;

    rx.await
        .map_err(recv_failed)?
        .map(|_| Json(serde_json::json!({ "ok": true, "cancelled": mission_id })))
        .map_err(|e| (StatusCode::NOT_FOUND, e))
}

/// Settle a durable run after the control actor has proved that no live main
/// or parallel runner owns it. This covers parked remote waits left behind by
/// a completed harness turn. Returning an idempotent cancel response without
/// closing this row would permanently block the next generation.
pub(super) async fn finish_detached_run_for_cancel(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
) -> Result<bool, String> {
    let Some(run) = mission_store.get_active_mission_run(mission_id).await? else {
        return Ok(false);
    };
    if run.owner_actor_id.starts_with("orb-client:") {
        return Err("Orb must confirm native termination before releasing this run".into());
    }
    mission_store
        .heartbeat_mission_run(
            run.run_id,
            run.generation,
            MissionExecutionState::Stopping,
            None,
        )
        .await?;
    mission_store
        .finish_mission_run(
            run.run_id,
            run.generation,
            Some("operator_cancelled_detached_run"),
        )
        .await?;
    Ok(true)
}

/// Optional body for the pause endpoint (FLEET-004). Carries attribution only.
#[derive(Debug, Default, Deserialize)]
pub struct PauseMissionRequest {
    /// Optional attribution override (e.g. `"system:fleet-watcher"`).
    #[serde(default)]
    pub actor: Option<String>,
}

/// Pause a mission (FLEET-004). Sets the mission to `Paused`, a non-terminal
/// state the dispatcher deliberately skips when selecting the next runnable
/// mission. Resume via `POST /missions/:id/resume`, which transitions a
/// `Paused` mission back to `Pending` so the dispatcher re-queues it.
///
/// Rejects missions that are already terminal (nothing to pause) or already
/// paused (no-op kept explicit for the operator).
pub async fn pause_mission(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
    body: Option<Json<PauseMissionRequest>>,
) -> Result<Json<Mission>, (StatusCode, String)> {
    let actor = resolve_actor(body.and_then(|b| b.0.actor), &user);
    let control = control_for_user(&state, &user).await;
    if control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?
        .is_some_and(|m| m.backend.starts_with("cloud_"))
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "Cloud pause is unsupported; use capability-gated cancellation".into(),
        ));
    }
    if mission_is_client_placed(&control, mission_id)
        .await
        .map_err(internal_error)?
    {
        return Err((
            StatusCode::CONFLICT,
            "Stop this mission on its Orb computer".into(),
        ));
    }
    let mission = control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                format!("Mission {} not found", mission_id),
            )
        })?;

    if mission.status == MissionStatus::Paused {
        return Err((
            StatusCode::CONFLICT,
            "Mission is already paused".to_string(),
        ));
    }
    if mission_status_is_terminal(mission.status) {
        return Err((
            StatusCode::CONFLICT,
            format!(
                "Cannot pause a terminal mission (status: {})",
                mission.status
            ),
        ));
    }

    // Route through the control loop so any in-flight runner is actually
    // stopped before the mission is parked. A bare store update would leave the
    // active turn executing and let its completion overwrite `Paused`.
    let (tx, rx) = oneshot::channel();
    control
        .cmd_tx
        .send(ControlCommand::PauseMission {
            mission_id,
            respond: tx,
        })
        .await
        .map_err(session_unavailable)?;
    rx.await
        .map_err(recv_failed)?
        .map_err(|e| (StatusCode::CONFLICT, e))?;
    tracing::info!(mission_id = %mission_id, actor = %actor, "FLEET-004 mission paused");

    let updated = control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                format!("Mission {} not found", mission_id),
            )
        })?;
    Ok(Json(updated))
}

/// Resolve the acting principal for a FLEET control action. An explicit
/// `actor` override (e.g. `"system:fleet-watcher"`) wins; otherwise we attribute
/// it to the authenticated user. Recorded in structured logs so a post-mortem
/// can answer "who paused/cloned/resumed this mission?".
pub(super) fn resolve_actor(explicit: Option<String>, user: &AuthUser) -> String {
    explicit
        .map(|a| a.trim().to_string())
        .filter(|a| !a.is_empty())
        .unwrap_or_else(|| {
            let who = if user.username.is_empty() {
                &user.id
            } else {
                &user.username
            };
            format!("user:{}", who)
        })
}

/// Overrides accepted when cloning a mission (FLEET-002). Any field left unset
/// inherits from the source mission.
#[derive(Debug, Default, Deserialize)]
pub struct CloneMissionRequest {
    pub service_tier: Option<crate::codex_speed::Tier>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub backend: Option<String>,
    #[serde(default)]
    pub model_effort: Option<String>,
    #[serde(default)]
    pub model_override: Option<String>,
    /// When true, copy the source mission's conversation history into the clone
    /// (retry-with-context). Default false — the clone starts fresh.
    #[serde(default)]
    pub clone_messages: bool,
    /// Optional parent to record on the clone for lineage tracing in the UI.
    /// Left unset, the clone has no parent (independent mission).
    #[serde(default)]
    pub parent_mission_id: Option<Uuid>,
    /// Optional attribution override (e.g. `"system:fleet-watcher"`).
    #[serde(default)]
    pub actor: Option<String>,
}

/// Clone an existing mission's configuration into a fresh `Pending` mission
/// (FLEET-002). Copies title, workspace, agent, config profile, working
/// directory and model settings; the optional body overrides
/// title/backend/model_effort/model_override. Conversation history is **not**
/// copied — the clone starts fresh. Reuses the standard create path so all
/// backend/agent/model validation applies identically.
/// A clone keeps an explicit project track but not the source's own generated track
/// (`mission-<source id prefix>`): that one belongs to the source alone, and inheriting it
/// made the clone fail the remote queue's writer check (mission 27b29974).
/// True when `track` is a generated per-mission track inherited along a
/// replacement chain, which the replacement must not keep.
pub(super) fn replacement_drops_track(
    prior_id: Uuid,
    prior_track: Option<&str>,
    track: &str,
) -> bool {
    let generated = |t: &str| {
        t.strip_prefix("mission-")
            .is_some_and(|rest| rest.len() == 8 && rest.chars().all(|c| c.is_ascii_hexdigit()))
    };
    track == super::super::track_leases::generated_track_key(&prior_id.to_string())
        || (generated(track) && prior_track == Some(track))
}

pub(super) fn inherited_track(source_id: Uuid, track: Option<&str>) -> Option<String> {
    track
        .filter(|t| *t != super::super::track_leases::generated_track_key(&source_id.to_string()))
        .map(str::to_owned)
}

pub async fn clone_mission(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
    body: Option<Json<CloneMissionRequest>>,
) -> Result<Json<Mission>, (StatusCode, String)> {
    let _workspace = machine_transfer::workspace_mutation_lock(mission_id).await;
    {
        let _admission = DISPATCH_ADMISSION.lock().await;
        let _durable = dispatch_admission::durable_lock(&state.config)
            .await
            .map_err(internal_error)?;
        workspace_purge::revoke_owned_locked(&state, mission_id, &user.id)
            .map_err(|e| (StatusCode::CONFLICT, e))?;
    }
    let overrides = body.map(|b| b.0).unwrap_or_default();
    let actor = resolve_actor(overrides.actor.clone(), &user);
    let clone_messages = overrides.clone_messages;
    let parent_mission_id = overrides.parent_mission_id;

    let control = control_for_user(&state, &user).await;
    let source = control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                format!("Mission {} not found", mission_id),
            )
        })?;

    let req = CreateMissionRequest {
        cyber_access: if overrides.backend.as_deref().unwrap_or(&source.backend) == "codex" {
            Some(
                cyber::read(&state.config.working_dir, source.id)
                    .map_err(internal_error)?
                    .mode,
            )
        } else {
            None
        },
        title: overrides.title.or_else(|| source.title.clone()),
        workspace_id: Some(source.workspace_id),
        agent: source.agent.clone(),
        model_override: overrides
            .model_override
            .or_else(|| source.model_override.clone()),
        model_effort: overrides
            .model_effort
            .or_else(|| source.model_effort.clone()),
        fast_mode: source.fast_mode
            && overrides.backend.as_deref().unwrap_or(&source.backend) == "codex",
        service_tier: if overrides.backend.as_deref().unwrap_or(&source.backend) == "codex" {
            overrides.service_tier.or(source.service_tier)
        } else {
            None
        },
        config_profile: source.config_profile.clone(),
        backend: overrides.backend.or_else(|| Some(source.backend.clone())),
        parent_mission_id,
        supersedes_mission_id: None,
        working_directory: source.working_directory.clone(),
        priority: None,
        not_before: None,
        deadline: None,
        // Inherit project tagging from the source mission so clones stay
        // grouped under the same project/track/intent.
        project: source.project.project.clone(),
        // A generated track belongs to the source mission alone; the clone gets its own at
        // create. Inheriting it made the clone fail the remote queue's writer check
        // (REMOTE_JOB_STILL_RUNNING instead of queueing, mission 27b29974).
        track: inherited_track(source.id, source.project.track.as_deref()),
        idempotency_key: None,
        intent: source.project.intent.clone(),
        github_pr: source.project.github_pr.clone(),
        writer: None,
        acceptance_criteria: Vec::new(),
        tags: if source.project.tags.is_empty() {
            None
        } else {
            Some(source.project.tags.clone())
        },
        desired_state: source.project.desired_state.clone(),
        next_check_at: source.project.next_check_at.clone(),
        prompt: None,
        remote_node_id: parent_mission_id.map(|_| worker_location::SAME_NODE.to_string()),
        remote_requirements: None,
        remote_command: None,
        remote_async: None,
        estimated_disk_gib: None,
        // A clone is the same work retried, so it belongs to the same
        // conversation. Dropping the origin here orphaned the retry: it
        // vanished from the worker strip of the session that asked for it.
        origin: source.origin.clone(),
        origin_session_id: source.origin_session_id.clone(),
        attachments: None,
        placement: None,
        claim_managed_machine_id: None,
        managed_ttl_minutes: None,
        managed_from_snapshot: None,
        managed_allow_24h_commitment: None,
        budget_usd: None,
        validate_only: None,
        extra: Default::default(),
    };

    let (_headers, Json(cloned)) =
        create_mission(State(state), Extension(user), Some(Json(req))).await?;
    let cloned: Mission = serde_json::from_value(cloned).map_err(internal_error)?;
    let clone_id = cloned.id;

    // Optionally seed the clone with the source's conversation history
    // (retry-with-context). `control` still holds the store handle after the
    // create above moved `state`.
    if clone_messages && !source.history.is_empty() {
        control
            .mission_store
            .update_mission_history(clone_id, &source.history)
            .await
            .map_err(internal_error)?;
    }

    tracing::info!(
        source_mission = %mission_id,
        clone_mission = %clone_id,
        actor = %actor,
        clone_messages,
        parent = ?parent_mission_id,
        "FLEET-002 mission cloned"
    );

    Ok(Json(cloned))
}

/// Request body for resuming a mission
#[derive(Debug, Deserialize, Default)]
pub struct ResumeMissionRequest {
    /// Explicit same-work assertion, checked against stored identity before dispatch.
    #[serde(default)]
    pub continue_identity: Option<crate::api::writer_recycle::WriterContinuation>,

    /// If true, clean the mission's work directory before resuming
    #[serde(default)]
    pub clean_workspace: bool,
    /// If true, do not send the automatic resume message.
    /// Useful when the user is about to send their own custom message.
    #[serde(default)]
    pub skip_message: bool,
    /// Optional attribution override (e.g. `"system:fleet-watcher"`).
    #[serde(default)]
    pub actor: Option<String>,
    /// Required when the resume retasks the writer onto different work.
    #[serde(default)]
    pub github_pr: Option<String>,
    #[serde(default)]
    pub track: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    /// Optional objective for the resumed turn; used to detect silent recycle.
    #[serde(default)]
    pub content: Option<String>,
}

/// Resume an interrupted mission.
/// This reconstructs context from history and work directory, then restarts execution.
pub async fn resume_mission(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
    body: Option<Json<ResumeMissionRequest>>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let store = control.mission_store.clone();
    let mission = match resume_cloud(&store, mission_id, body.as_ref().map(|b| &b.0)).await? {
        Some(mission) => mission,
        None => {
            resume_mission_row(State(state), Extension(user), Path(mission_id), body)
                .await?
                .0
        }
    };
    // Same shape as GET /missions/:id: the derived callback lineage included.
    super::callback_parent::with_lineage(&mission, &store)
        .await
        .map(Json)
        .map_err(internal_error)
}

/// The text a cloud conversation receives when it is resumed without one.
pub(crate) const CLOUD_RESUME_PROMPT: &str = "Continue where you left off.";

/// Cloud conversations run on their provider account: resuming one is a
/// follow-up turn on that conversation, not a local harness restart (which
/// the machine guard refuses). `None` when the mission is not a cloud one.
async fn resume_cloud(
    store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    request: Option<&ResumeMissionRequest>,
) -> Result<Option<Mission>, (StatusCode, String)> {
    let Some(mission) = store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?
    else {
        return Ok(None);
    };
    if !mission.backend.starts_with("cloud_") {
        return Ok(None);
    }
    if request.is_some_and(|r| {
        r.clean_workspace
            || r.github_pr.is_some()
            || r.track.is_some()
            || r.title.is_some()
            || r.continue_identity.is_some()
    }) {
        return Err((
            StatusCode::CONFLICT,
            "Cloud conversations resume with content only".into(),
        ));
    }
    if request.is_some_and(|r| r.skip_message) {
        return Err((
            StatusCode::CONFLICT,
            "Cloud conversations resume by sending a message; skip_message is not supported".into(),
        ));
    }
    let content = request
        .and_then(|r| r.content.clone())
        .filter(|c| !c.trim().is_empty())
        .unwrap_or_else(|| CLOUD_RESUME_PROMPT.to_string());
    let message: ControlMessageRequest = serde_json::from_value(serde_json::json!({
        "content": content,
        "client_message_id": Uuid::new_v4(),
        "mission_id": mission_id,
    }))
    .map_err(internal_error)?;
    match super::super::cloud_agents::http::follow_up(store.clone(), &message).await? {
        Some(_) => Ok(Some(
            store
                .get_mission(mission_id)
                .await
                .map_err(internal_error)?
                .unwrap_or(mission),
        )),
        None => Err((
            StatusCode::CONFLICT,
            "This cloud conversation has no provider execution to continue".into(),
        )),
    }
}

async fn resume_mission_row(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
    body: Option<Json<ResumeMissionRequest>>,
) -> Result<Json<Mission>, (StatusCode, String)> {
    let request = body.map(|b| b.0).unwrap_or_default();
    if let Some(content) = request.content.as_deref() {
        crate::api::mission_payload::validate_user_content(content)
            .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
    }
    let clean_workspace = request.clean_workspace;
    let skip_message = request.skip_message;
    let actor = resolve_actor(request.actor.clone(), &user);

    let control = control_for_user(&state, &user).await;
    machine_transfer::guard(&control.mission_store, mission_id)
        .await
        .map_err(internal_error)?;
    cyber::validate_remote_mission(&state, &control, mission_id)
        .await
        .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    if mission_is_client_placed(&control, mission_id)
        .await
        .map_err(internal_error)?
    {
        return Err((
            StatusCode::CONFLICT,
            "this mission runs on the Orb client; resume it there".into(),
        ));
    }
    tracing::info!(mission_id = %mission_id, actor = %actor, "FLEET-004 mission resume requested");

    if let Some(placement) = remote_grok::placement(
        &state.config.working_dir,
        &control.mission_store,
        mission_id,
    )
    .await
    .map_err(internal_error)?
    {
        if request.clean_workspace
            || request.skip_message
            || request.github_pr.is_some()
            || request.track.is_some()
            || request.title.is_some()
            || request.continue_identity.is_some()
        {
            return Err((StatusCode::CONFLICT, format!("{}: remote continuation supports content only; use a linked replacement for workspace or writer identity changes", remote_grok::REMOTE_RESUME_REQUIRES_REPLACEMENT)));
        }
        return remote_grok::continue_on_node(
            &state,
            &control,
            &actor,
            mission_id,
            placement,
            request.content,
            None,
        )
        .await
        .map(Json);
    }

    let outcome: Result<Mission, (StatusCode, String)> = async {
        let (tx, rx) = oneshot::channel();
        control
            .cmd_tx
            .send(ControlCommand::AdmitDispatch {
                admission: Box::new(DispatchAdmission {
                    internal_work_hint: None,
                    state: state.clone(),
                    store: control.mission_store.clone(),
                    patch: dispatch_identity_patch(
                        request.github_pr,
                        request.track,
                        request.title,
                        request.content,
                        request.continue_identity,
                    ),
                }),
                command: Box::new(ControlCommand::ResumeMission {
                    content: None,
                    mission_id,
                    clean_workspace,
                    skip_message,
                    respond: tx,
                }),
            })
            .await
            .map_err(session_unavailable)?;
        #[cfg(test)]
        dispatch_admission_tests::notify_wait(mission_id, "enqueued");
        rx.await.map_err(recv_failed)?.map_err(|e| {
            let conflict = e.contains("writer_identity_stale")
                || e.contains("continue_identity")
                || e.contains("assignment_busy")
                || e.contains("writer lease")
                || e.contains("track_owned")
                || e.contains("dispatch_recovery_required")
                || e.contains("writer_reuse_requires_retag");
            (
                if conflict {
                    StatusCode::CONFLICT
                } else {
                    StatusCode::BAD_REQUEST
                },
                e,
            )
        })
    }
    .await;

    outcome.map(Json)
}

#[derive(Debug, Default, Deserialize)]
pub struct DeleteMissionQuery {
    /// Required to delete a mission that has descendants: the delete removes
    /// them too, with their history. Without it such a delete is refused, so a
    /// caller cannot wipe launched sessions by accident.
    #[serde(default)]
    pub include_descendants: Option<bool>,
}

/// Refuse (409) a delete that would also remove `descendants` unless the
/// caller opted in with `include_descendants=true`.
pub(super) fn require_descendant_opt_in(
    mission_id: Uuid,
    include_descendants: Option<bool>,
    descendants: &[Mission],
) -> Result<(), (StatusCode, String)> {
    if descendants.is_empty() || include_descendants == Some(true) {
        return Ok(());
    }
    Err((
        StatusCode::CONFLICT,
        descendants_refusal(mission_id, descendants),
    ))
}

/// The 409 body for a delete that would also remove descendants.
fn descendants_refusal(mission_id: Uuid, descendants: &[Mission]) -> String {
    let titles: Vec<String> = descendants
        .iter()
        .take(10)
        .map(|m| {
            let title = m.title.clone().unwrap_or_else(|| m.id.to_string());
            if matches!(
                m.status,
                MissionStatus::Active | MissionStatus::WaitingBackground
            ) {
                format!("{title} (running)")
            } else {
                title
            }
        })
        .collect();
    let more = descendants.len().saturating_sub(titles.len());
    format!(
        "Mission {mission_id} has {} descendant session{}: {}{}. Deleting it would delete them too; pass include_descendants=true to confirm.",
        descendants.len(),
        if descendants.len() == 1 { "" } else { "s" },
        titles.join(", "),
        if more > 0 { format!(", and {more} more") } else { String::new() },
    )
}

/// Delete a mission by ID.
/// Only allows deleting missions that are not currently running. A mission
/// with descendants is deleted (with them) only with `include_descendants=true`.
pub async fn delete_mission(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
    Query(query): Query<DeleteMissionQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let _workspace_mutation = machine_transfer::workspace_mutation_lock(mission_id).await;
    let control = control_for_user(&state, &user).await;
    if control
        .mission_store
        .get_mission_metadata(mission_id)
        .await
        .map_err(internal_error)?
        .is_none()
    {
        return Err((StatusCode::NOT_FOUND, "Mission not found".to_string()));
    }
    let child_ids = collect_child_mission_ids(&control.mission_store, mission_id).await?;
    if !child_ids.is_empty() && query.include_descendants != Some(true) {
        let by_id: HashMap<Uuid, Mission> = control
            .mission_store
            .get_missions_metadata_by_ids(&child_ids)
            .await
            .map_err(internal_error)?
            .into_iter()
            .map(|m| (m.id, m))
            .collect();
        let descendants: Vec<Mission> = child_ids
            .iter()
            .filter_map(|id| by_id.get(id).cloned())
            .collect();
        require_descendant_opt_in(mission_id, query.include_descendants, &descendants)?;
    }
    let mut ids_to_delete = HashSet::with_capacity(child_ids.len() + 1);
    ids_to_delete.insert(mission_id);
    ids_to_delete.extend(child_ids);
    #[cfg(test)]
    dispatch_admission_tests::notify_wait(mission_id, "delete_admission");
    let _admission = DISPATCH_ADMISSION.lock().await;
    let _durable = dispatch_admission::durable_lock(&state.config)
        .await
        .map_err(internal_error)?;
    // Deleting a boss cascades to its board records. Preserve those receipts
    // too. Board-local keys are scoped by the action issuer, not compared
    // across boards (common keys such as "build" are unrelated).
    let mut board_task_ids = HashSet::new();
    for id in &ids_to_delete {
        for task in control
            .mission_store
            .list_board_tasks(*id)
            .await
            .map_err(internal_error)?
        {
            board_task_ids.insert(task.id.to_string());
        }
    }
    let replacements = {
        let conn = state.projects.connection.lock().map_err(internal_error)?;
        crate::control_mcp::actions::require_history_deletable(
            &conn,
            &user.id,
            &ids_to_delete,
            &board_task_ids,
        )
        .map_err(|e| (StatusCode::CONFLICT, e))?
    };
    for (action_id, prior_id) in replacements {
        let lineage = mission_create::replacement_parent_lineage(&control.mission_store, prior_id)
            .await
            .map_err(|e| (StatusCode::CONFLICT, e))?;
        if lineage.iter().any(|id| ids_to_delete.contains(id)) {
            return Err((StatusCode::CONFLICT, format!("Accepted MCP action {action_id} inherits this replacement parent; settle it before deleting")));
        }
    }
    // Descendant creation is admission-serialized. Recompute after acquiring
    // the fence and reject if the validated deletion set changed while waiting.
    let final_child_ids = collect_child_mission_ids(&control.mission_store, mission_id).await?;
    let initial_children: HashSet<Uuid> = ids_to_delete
        .iter()
        .copied()
        .filter(|id| *id != mission_id)
        .collect();
    if final_child_ids.iter().copied().collect::<HashSet<_>>() != initial_children {
        return Err((
            StatusCode::CONFLICT,
            "Mission descendants changed while deletion was waiting; retry".into(),
        ));
    }
    let mut ordered_ids = Vec::with_capacity(final_child_ids.len() + 1);
    ordered_ids.push(mission_id);
    ordered_ids.extend(final_child_ids.iter().copied());

    for id in &ordered_ids {
        machine_transfer::guard_active_transfer(&control.mission_store, *id)
            .await
            .map_err(|e| (StatusCode::CONFLICT, e))?;
        workspace_purge::require_history_deletable_locked(&state, *id)
            .map_err(|e| (StatusCode::CONFLICT, e))?;
        if state
            .projects
            .dispatch_admission(&id.to_string())
            .map_err(internal_error)?
            .is_some()
        {
            return Err((
                StatusCode::CONFLICT,
                format!(
                    "Mission ({id}) has an uncommitted dispatch admission; retry once settled."
                ),
            ));
        }
        if usage_limit_wait::remote_wait(&state.config.working_dir, *id)
            .await
            .is_some_and(|w| w.resume_at.is_some())
        {
            return Err((
                StatusCode::CONFLICT,
                format!("Mission ({id}) has a scheduled remote replay; cancel it before deleting."),
            ));
        }
    }
    // Durable jobs may outlive runners; fail closed before filesystem/history mutation.
    if crate::api::durable_jobs::has_unsettled_missions_jobs(&state, &user, &ids_to_delete)
        .await
        .map_err(|error| (StatusCode::CONFLICT, error))?
    {
        return Err((
            StatusCode::CONFLICT,
            "Workspace jobs are still running or uncertain; settle them before deleting".into(),
        ));
    }
    let missions_by_id: HashMap<Uuid, Mission> = control
        .mission_store
        .get_missions_metadata_by_ids(&ordered_ids)
        .await
        .map_err(internal_error)?
        .into_iter()
        .map(|m| (m.id, m))
        .collect();
    if !missions_by_id.contains_key(&mission_id) {
        return Err((StatusCode::NOT_FOUND, "Mission not found".to_string()));
    }
    if control
        .mission_store
        .cloud_executions()
        .await
        .map_err(internal_error)?
        .iter()
        .any(|e| {
            ids_to_delete.contains(&e.mission_id)
                && e.turns.iter().any(|t| {
                    !t.phase.terminal()
                        && t.phase != crate::api::cloud_agents::Phase::Incompatible
                        && (matches!(
                            t.phase,
                            crate::api::cloud_agents::Phase::Queued
                                | crate::api::cloud_agents::Phase::Submitting
                                | crate::api::cloud_agents::Phase::Running
                                | crate::api::cloud_agents::Phase::CancelRequested
                        ) || missions_by_id.get(&e.mission_id).map(|m| m.status)
                            != Some(MissionStatus::Acknowledged))
                })
        })
    {
        return Err((StatusCode::CONFLICT, "Cloud work is still active or unconfirmed; archive the conversation or confirm cancellation before deleting its receipts".into()));
    }
    // The actor also takes DISPATCH_ADMISSION. Never RPC into it while
    // holding that mutex: persisted runs, accepted queues and assignment owners
    // provide the authoritative final check under the same admission fence.
    let ownership = execution_ownership::snapshot_for_ids(&state.control, &ids_to_delete)
        .await
        .map_err(internal_error)?;
    for id in &ordered_ids {
        match ownership.delete_blocker(*id) {
            execution_ownership::DeleteBlocker::None => {}
            execution_ownership::DeleteBlocker::Missing => {
                if *id == mission_id {
                    return Err((StatusCode::NOT_FOUND, "Mission not found".to_string()));
                }
                return Err((
                    StatusCode::CONFLICT,
                    "Mission descendants changed while deletion was waiting; retry".into(),
                ));
            }
            execution_ownership::DeleteBlocker::Paused => {
                return Err((
                    StatusCode::CONFLICT,
                    format!("Cannot delete a paused mission ({id}). Resume or cancel it first."),
                ));
            }
            execution_ownership::DeleteBlocker::Running => {
                return Err((
                    StatusCode::CONFLICT,
                    format!("Cannot delete a running mission or worker ({id}). Cancel it first."),
                ));
            }
            execution_ownership::DeleteBlocker::ScheduledWork => {
                return Err((
                    StatusCode::CONFLICT,
                    format!(
                        "Mission ({id}) has queued or scheduled work; cancel it before deleting."
                    ),
                ));
            }
        }
    }
    let running = Vec::new();

    let deleted_workspace_dirs = cleanup_mission_workspace_dirs_for_ids(
        &control.mission_store,
        &state.workspaces,
        mission_id,
        final_child_ids.clone(),
        &running,
    )
    .await?;

    let deleted_ids = delete_mission_with_child_ids(
        &control.mission_store,
        mission_id,
        final_child_ids,
        &running,
    )
    .await?;

    for id in &deleted_ids {
        clear_mission_metadata_refresh_state(*id);
        usage_limit_wait::update_remote_wait(&state.config.working_dir, *id, |_| None).await;
        let _ = state.projects.release_leases_for_attempt(&id.to_string());
    }

    let deleted_workspace_dir_count = deleted_workspace_dirs.len();
    Ok(Json(serde_json::json!({
        "ok": true,
        "deleted": mission_id,
        "deleted_ids": deleted_ids,
        "deleted_count": deleted_ids.len(),
        "deleted_workspace_dirs": deleted_workspace_dirs,
        "deleted_workspace_dir_count": deleted_workspace_dir_count
    })))
}

pub(super) async fn collect_child_mission_ids(
    mission_store: &Arc<dyn MissionStore>,
    parent_id: Uuid,
) -> Result<Vec<Uuid>, (StatusCode, String)> {
    let mut visited = HashSet::new();
    let mut stack = vec![parent_id];
    let mut child_ids = Vec::new();

    while let Some(id) = stack.pop() {
        let children = mission_store
            .get_child_missions(id)
            .await
            .map_err(internal_error)?;

        for child in children {
            if visited.insert(child.id) {
                child_ids.push(child.id);
                stack.push(child.id);
            }
        }
    }

    Ok(child_ids)
}

#[cfg(test)]
pub(super) async fn delete_mission_with_children(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    running: &[super::super::mission_runner::RunningMissionInfo],
) -> Result<Vec<Uuid>, (StatusCode, String)> {
    let child_ids = collect_child_mission_ids(mission_store, mission_id).await?;
    delete_mission_with_child_ids(mission_store, mission_id, child_ids, running).await
}

pub(super) async fn delete_mission_with_child_ids(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    child_ids: Vec<Uuid>,
    running: &[super::super::mission_runner::RunningMissionInfo],
) -> Result<Vec<Uuid>, (StatusCode, String)> {
    let mut ids_to_delete = Vec::with_capacity(child_ids.len() + 1);
    ids_to_delete.push(mission_id);
    ids_to_delete.extend(child_ids.iter().copied());

    let by_id: HashMap<Uuid, Mission> = mission_store
        .get_missions_metadata_by_ids(&ids_to_delete)
        .await
        .map_err(internal_error)?
        .into_iter()
        .map(|m| (m.id, m))
        .collect();
    let Some(target) = by_id.get(&mission_id) else {
        return Err((StatusCode::NOT_FOUND, "Mission not found".to_string()));
    };

    // FLEET-004: a Paused mission is deliberately parked for later resume —
    // deleting it would silently discard work the operator chose to keep. Require
    // an explicit resume-or-cancel first (mirrors the pause endpoint's 409s).
    if target.status == MissionStatus::Paused {
        return Err((
            StatusCode::CONFLICT,
            format!(
                "Cannot delete a paused mission ({}). Resume or cancel it first.",
                mission_id
            ),
        ));
    }
    if let Some(paused_child) = child_ids
        .iter()
        .find_map(|cid| by_id.get(cid).filter(|m| m.status == MissionStatus::Paused))
    {
        return Err((
            StatusCode::CONFLICT,
            format!(
                "Cannot delete a paused mission ({}). Resume or cancel it first.",
                paused_child.id
            ),
        ));
    }

    if let Some(running_mission) = running
        .iter()
        .find(|m| ids_to_delete.contains(&m.mission_id))
    {
        return Err((
            StatusCode::CONFLICT,
            format!(
                "Cannot delete a running mission or worker ({}). Cancel it first.",
                running_mission.mission_id
            ),
        ));
    }

    let mut delete_sequence = Vec::with_capacity(child_ids.len() + 1);
    delete_sequence.extend(child_ids.iter().rev().copied());
    delete_sequence.push(mission_id);

    let removed_count = mission_store
        .delete_missions(&delete_sequence)
        .await
        .map_err(internal_error)?;
    if removed_count == 0 {
        return Err((StatusCode::NOT_FOUND, "Mission not found".to_string()));
    }

    Ok(ids_to_delete)
}

/// Legacy quarantine names do not carry discard permission. They are retained
/// for recovery; only workspace_purge receipts authorize deferred deletion.
#[cfg(test)]
pub(crate) fn start_deleted_workspace_cleanup(_workspaces: workspace::SharedWorkspaceStore) {}

#[cfg(test)]
pub(super) async fn cleanup_mission_workspace_dirs_for_delete(
    mission_store: &Arc<dyn MissionStore>,
    workspaces: &workspace::SharedWorkspaceStore,
    mission_id: Uuid,
    running: &[super::super::mission_runner::RunningMissionInfo],
) -> Result<Vec<String>, (StatusCode, String)> {
    let child_ids = collect_child_mission_ids(mission_store, mission_id).await?;
    cleanup_mission_workspace_dirs_for_ids(
        mission_store,
        workspaces,
        mission_id,
        child_ids,
        running,
    )
    .await
}

pub(super) async fn cleanup_mission_workspace_dirs_for_ids(
    mission_store: &Arc<dyn MissionStore>,
    workspaces: &workspace::SharedWorkspaceStore,
    mission_id: Uuid,
    child_ids: Vec<Uuid>,
    running: &[super::super::mission_runner::RunningMissionInfo],
) -> Result<Vec<String>, (StatusCode, String)> {
    let mut ids_to_delete = Vec::with_capacity(child_ids.len() + 1);
    ids_to_delete.push(mission_id);
    ids_to_delete.extend(child_ids.iter().copied());

    let by_id: HashMap<Uuid, Mission> = mission_store
        .get_missions_metadata_by_ids(&ids_to_delete)
        .await
        .map_err(internal_error)?
        .into_iter()
        .map(|m| (m.id, m))
        .collect();
    if !by_id.contains_key(&mission_id) {
        return Err((StatusCode::NOT_FOUND, "Mission not found".to_string()));
    }

    if let Some(running_mission) = running
        .iter()
        .find(|m| ids_to_delete.contains(&m.mission_id))
    {
        return Err((
            StatusCode::CONFLICT,
            format!(
                "Cannot delete a running mission or worker ({}). Cancel it first.",
                running_mission.mission_id
            ),
        ));
    }

    let missions: Vec<Mission> = ids_to_delete
        .iter()
        .filter_map(|id| by_id.get(id).cloned())
        .collect();

    // Check every descendant before touching any directory; paused children
    // must retain their workspace even when the parent is terminal.
    if let Some(mission) = missions.iter().find(|m| {
        matches!(
            m.status,
            MissionStatus::Paused | MissionStatus::Active | MissionStatus::WaitingBackground
        )
    }) {
        return Err((
            StatusCode::CONFLICT,
            format!(
                "Cannot delete mission {} while it is {:?}. Cancel it first.",
                mission.id, mission.status
            ),
        ));
    }
    let deleted_dirs = Vec::new();
    for mission in missions {
        if !mission.requires_local_disk || mission.backend.starts_with("cloud_") {
            continue;
        }
        let Some(ws) = workspaces.get(mission.workspace_id).await else {
            // Do not finalize the database deletion when the workspace that
            // owns a mission's persisted placement cannot be consulted.  A
            // relocated directory may still exist on a temporarily missing
            // volume, and treating that as an already-clean workspace would
            // orphan it permanently.
            return Err((
                StatusCode::CONFLICT,
                format!(
                    "Cannot verify workspace placement for mission {} because workspace {} is unavailable",
                    mission.id, mission.workspace_id
                ),
            ));
        };
        workspace::ensure_persisted_mission_root_is_available(&ws, mission.id).map_err(
            |error| {
                tracing::warn!(mission_id = %mission.id, %error, "refusing to delete workspace with unavailable persisted root");
                (
                    StatusCode::CONFLICT,
                    format!(
                        "Cannot delete mission {}: persisted mission workspace root is unavailable: {}",
                        mission.id, error
                    ),
                )
            },
        )?;
        let dir = workspace::mission_workspace_dir_for_workspace(&ws, mission.id);
        if !dir.exists() {
            continue;
        }
        // Conversation deletion preserves all filesystem work. Discarding it
        // requires a separate persisted workspace-purge authorization.
        tracing::info!(mission_id = %mission.id, path = %dir.display(),
            "retained mission workspace during history deletion");
    }

    Ok(deleted_dirs)
}

/// Delete all empty "Untitled" missions.
/// Returns the count of deleted missions.
/// Note: This excludes any currently running missions to prevent data loss.
pub async fn cleanup_empty_missions(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let running = get_running_missions(&control).await?;
    let running_ids: Vec<Uuid> = running.iter().map(|m| m.mission_id).collect();

    let count = control
        .mission_store
        .delete_empty_untitled_missions_excluding(&running_ids)
        .await
        .map_err(internal_error)?;

    if count > 0 {
        clear_stale_mission_metadata_refresh_state(&control.mission_store).await;
    }

    Ok(Json(serde_json::json!({
        "ok": true,
        "deleted_count": count
    })))
}
