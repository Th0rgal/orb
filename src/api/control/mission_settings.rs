//! Mission project/origin/settings update handlers.

use super::*;

/// Request body for `POST /api/control/missions/:id/project`. Tri-state per
/// field: omit to leave unchanged, `null` to clear, a value to set. `tags`
/// replaces the whole list when present.
#[derive(Debug, Deserialize)]
pub struct UpdateMissionProjectRequest {
    #[serde(default, deserialize_with = "deserialize_string_patch")]
    pub project: Option<Option<String>>,
    #[serde(default, deserialize_with = "deserialize_string_patch")]
    pub track: Option<Option<String>>,
    #[serde(default, deserialize_with = "deserialize_string_patch")]
    pub intent: Option<Option<String>>,
    #[serde(default, deserialize_with = "deserialize_string_patch")]
    pub github_pr: Option<Option<String>>,
    /// Explicit PR branch capability. `true` acquires the writer lease;
    /// `false` marks the mission read-only.
    #[serde(default)]
    pub writer: Option<bool>,
    #[serde(default)]
    pub tags: Option<Vec<String>>,
    #[serde(default, deserialize_with = "deserialize_string_patch")]
    pub desired_state: Option<Option<String>>,
    #[serde(default, deserialize_with = "deserialize_string_patch")]
    pub next_check_at: Option<Option<String>>,
    /// When true and `project` assigns a destination slug, also move every
    /// launched descendant not yet in that project (clearing child
    /// `orb-folder:*` tags while preserving capability and hierarchy tags).
    #[serde(default)]
    pub include_descendants: bool,
    /// Optional client-known callback children (`callback_parent_mission_id`)
    /// to verify via `callback_parent::links` and include in the atomic
    /// subtree transfer alongside `parent_mission_id` descendants.
    #[serde(default)]
    pub descendant_ids: Vec<Uuid>,
}

fn is_fork_of_parent(mission: &Mission, parent_id: Uuid) -> bool {
    let expected_fork_tag = format!("fork-of:{parent_id}");
    if mission
        .project
        .tags
        .iter()
        .any(|tag| tag == &expected_fork_tag)
    {
        return true;
    }
    mission
        .title
        .as_deref()
        .is_some_and(|title| title.to_ascii_lowercase().ends_with(" · fork"))
}

async fn collect_launched_descendant_ids(
    mission_store: &Arc<dyn MissionStore>,
    root_id: Uuid,
    extra_candidates: &[Uuid],
) -> Result<Vec<Uuid>, (StatusCode, String)> {
    let mut visited = HashSet::from([root_id]);
    let mut stack = vec![root_id];
    let mut out = Vec::new();

    let mut candidate_missions = Vec::new();
    for &cid in extra_candidates {
        if cid == root_id {
            continue;
        }
        if let Some(m) = mission_store
            .get_mission(cid)
            .await
            .map_err(internal_error)?
        {
            if m.parent_mission_id
                .is_none_or(|pid| !is_fork_of_parent(&m, pid))
            {
                candidate_missions.push(m);
            }
        }
    }
    let callback_links = if candidate_missions.is_empty() {
        HashMap::new()
    } else {
        super::callback_parent::links(&candidate_missions, mission_store).await
    };

    loop {
        while let Some(cur) = stack.pop() {
            let children = mission_store
                .get_child_missions(cur)
                .await
                .map_err(internal_error)?;
            for summary in children {
                if visited.contains(&summary.id) {
                    continue;
                }
                // `SqliteMissionStore::get_child_missions` omits `project.tags`;
                // load the full mission so `fork-of:<cur>` tags are honored.
                let Some(child) = mission_store
                    .get_mission(summary.id)
                    .await
                    .map_err(internal_error)?
                else {
                    continue;
                };
                if is_fork_of_parent(&child, cur) {
                    continue;
                }
                if visited.insert(child.id) {
                    out.push(child.id);
                    stack.push(child.id);
                }
            }
        }

        let mut added_callback = false;
        for m in &candidate_missions {
            if visited.contains(&m.id) {
                continue;
            }
            let parent = m
                .parent_mission_id
                .or_else(|| callback_links.get(&m.id).copied());
            if parent.is_some_and(|p| visited.contains(&p)) && visited.insert(m.id) {
                out.push(m.id);
                stack.push(m.id);
                added_callback = true;
            }
        }
        if !added_callback {
            break;
        }
    }

    Ok(out)
}

fn folder_only_tag_diff(a: &[String], b: &[String]) -> bool {
    a.iter()
        .filter(|tag| !b.contains(tag))
        .chain(b.iter().filter(|tag| !a.contains(tag)))
        .all(|tag| tag.starts_with("orb-folder:"))
}

/// Whether this patch could change the mission's PR-writer status.
///
/// `becomes_writer` is derived entirely from `github_pr`, `writer`, `intent`
/// and non-folder `tags`. A patch carrying none of them (or only changing
/// `orb-folder:*` sidebar tags) leaves writer status exactly as it was, so
/// there is no transition to arbitrate — and re-running the lease check anyway
/// can only reject an edit over a state the mission was already in.
///
/// That is not hypothetical: retagging a mission's project returned 409 forever
/// whenever some *other* mission held the writer lease for the PR this one
/// happens to reference, which made 32 missions permanently unmaintainable.
fn writer_status_inputs_changed(
    non_tag_writer_inputs_changed: bool,
    effective_tags: &[String],
    current_tags: &[String],
) -> bool {
    non_tag_writer_inputs_changed || !folder_only_tag_diff(effective_tags, current_tags)
}

#[cfg(test)]
pub(super) fn patch_can_change_writer_status(
    req: &UpdateMissionProjectRequest,
    current_tags: &[String],
) -> bool {
    let normalized_tags: Option<Vec<String>> = req.tags.as_ref().map(|tags| {
        tags.iter()
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
            .collect()
    });
    let effective = normalized_tags.as_deref().unwrap_or(current_tags);
    writer_status_inputs_changed(
        req.github_pr.is_some() || req.writer.is_some() || req.intent.is_some(),
        effective,
        current_tags,
    )
}

/// Set or update project tagging metadata for a mission.
#[derive(Debug, Deserialize)]
pub struct UpdateMissionOriginRequest {
    /// Creating system, e.g. "hermes".
    #[serde(default)]
    pub origin: Option<String>,
    /// Conversation the mission belongs to.
    #[serde(default)]
    pub origin_session_id: Option<String>,
}

/// Attach an existing mission to a conversation.
///
/// Origin was write-once at creation, so every mission created before the
/// column existed — or by a caller that did not declare one — was
/// permanently unattributable. This is what makes that history recoverable.
pub async fn update_mission_origin(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateMissionOriginRequest>,
) -> Result<Json<Mission>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let origin = req
        .origin
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("hermes");
    let session = req
        .origin_session_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    if let Some(session) = session {
        // Same shape the assistant MCP validates, so a value that would be
        // rejected at creation cannot be smuggled in through the patch.
        if session.len() > 128
            || !session
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'))
        {
            return Err((
                StatusCode::BAD_REQUEST,
                "origin_session_id must be 1-128 chars of [A-Za-z0-9._:-]".to_string(),
            ));
        }
    }
    // Existence first: the memory and file stores answer a missing mission
    // with a plain Err, which `internal_error` would surface as a 500 — a
    // caller backfilling origins in bulk needs "this one is gone" to read as
    // 404, not as a server fault it should retry.
    if control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .is_none()
    {
        return Err((StatusCode::NOT_FOUND, format!("mission {id} not found")));
    }
    control
        .mission_store
        .set_mission_origin(id, origin, session)
        .await
        .map_err(internal_error)?;
    let mission = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .ok_or((StatusCode::NOT_FOUND, format!("mission {id} not found")))?;
    Ok(Json(mission))
}

struct MovedMissionSnapshot {
    id: Uuid,
    title: Option<String>,
    before: crate::api::mission_store::MissionProject,
    prior_track_lease: Option<super::super::projects_store::TrackLease>,
}

impl MovedMissionSnapshot {
    fn capture(state: &Arc<AppState>, mission: &Mission) -> Result<Self, (StatusCode, String)> {
        let attempt = mission.id.to_string();
        let prior_track_lease = state
            .projects
            .live_leases(None)
            .map_err(internal_error)?
            .into_iter()
            .rfind(|l| l.attempt_id == attempt && l.mutation_domain == "track");
        Ok(Self {
            id: mission.id,
            title: mission.title.clone(),
            before: mission.project.clone(),
            prior_track_lease,
        })
    }
}

async fn rollback_moved_missions(
    state: &Arc<AppState>,
    store: &Arc<dyn MissionStore>,
    moved: Vec<MovedMissionSnapshot>,
) {
    for snap in moved.into_iter().rev() {
        let attempt = snap.id.to_string();
        if let Some(prior) = &snap.prior_track_lease {
            let still_matches = state
                .projects
                .live_leases(None)
                .ok()
                .and_then(|leases| {
                    leases
                        .into_iter()
                        .rfind(|l| l.attempt_id == attempt && l.mutation_domain == "track")
                })
                .is_some_and(|l| {
                    l.slug == prior.slug && l.track == prior.track && l.mode == prior.mode
                });
            if !still_matches {
                let pr = super::super::track_leases::pr_number(snap.before.github_pr.as_deref());
                if let Err(rollback_err) = state.projects.move_track_lease(
                    None,
                    &prior.slug,
                    &prior.track,
                    &attempt,
                    &prior.mode,
                    snap.title.as_deref(),
                    pr,
                ) {
                    tracing::error!(
                        mission_id = %snap.id,
                        %rollback_err,
                        "Subtree project transfer lease rollback failed"
                    );
                }
            }
        } else if let Err(rollback_err) = state.projects.release_leases_for_attempt(&attempt) {
            tracing::error!(
                mission_id = %snap.id,
                %rollback_err,
                "Subtree project transfer lease release rollback failed"
            );
        }

        match store.get_mission(snap.id).await {
            Ok(Some(cur)) if cur.project != snap.before => {
                let patch = crate::api::mission_store::MissionProjectPatch {
                    preserve_updated_at: true,
                    title: None,
                    project: Some(snap.before.project.clone()),
                    track: Some(snap.before.track.clone()),
                    intent: Some(snap.before.intent.clone()),
                    github_pr: Some(snap.before.github_pr.clone()),
                    tags: None,
                    tag_patch: Some(crate::api::mission_store::MissionTagPatch::between(
                        &cur.project.tags,
                        &snap.before.tags,
                    )),
                    desired_state: Some(snap.before.desired_state.clone()),
                    next_check_at: Some(snap.before.next_check_at.clone()),
                };
                if let Err(rollback_err) = store.update_mission_project(snap.id, patch).await {
                    tracing::error!(
                        mission_id = %snap.id,
                        %rollback_err,
                        "Subtree project transfer metadata rollback failed"
                    );
                }
            }
            Ok(_) => {}
            Err(rollback_err) => {
                tracing::error!(
                    mission_id = %snap.id,
                    %rollback_err,
                    "Subtree project transfer rollback mission read failed"
                );
            }
        }
    }
}

pub async fn update_mission_project(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateMissionProjectRequest>,
) -> Result<Json<Mission>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let (respond, result) = oneshot::channel();
    control
        .cmd_tx
        .send(ControlCommand::UpdateProject {
            mission_id: id,
            user,
            request: req,
            respond,
        })
        .await
        .map_err(session_unavailable)?;
    #[cfg(test)]
    dispatch_admission_tests::notify_wait(id, "project");
    let updated = result.await.map_err(recv_failed)??;
    Ok(Json(updated))
}

pub(super) async fn update_mission_project_subtree_locked<F>(
    is_actor_busy: &F,
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(mut req): Json<UpdateMissionProjectRequest>,
) -> Result<Json<Mission>, (StatusCode, String)>
where
    F: Fn(Uuid) -> bool,
{
    let include_descendants = std::mem::take(&mut req.include_descendants);
    let extra_descendants = std::mem::take(&mut req.descendant_ids);
    if !include_descendants {
        return update_mission_project_locked(
            is_actor_busy(id),
            State(state),
            Extension(user),
            Path(id),
            Json(req),
        )
        .await;
    }

    let explicit_project_patch = req.project.is_some();
    let control = control_for_user(&state, &user).await;
    let root_current = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Mission {} not found", id)))?;
    let root_snap = MovedMissionSnapshot::capture(&state, &root_current)?;

    let Json(updated) = update_mission_project_locked(
        is_actor_busy(id),
        State(state.clone()),
        Extension(user.clone()),
        Path(id),
        Json(req),
    )
    .await?;

    if updated.project.project.is_some() || explicit_project_patch {
        let target_project = updated.project.project.clone();
        let mut moved = vec![root_snap];
        let descendants =
            match collect_launched_descendant_ids(&control.mission_store, id, &extra_descendants)
                .await
            {
                Ok(ids) => ids,
                Err(err) => {
                    rollback_moved_missions(&state, &control.mission_store, moved).await;
                    return Err(err);
                }
            };
        for child_id in descendants {
            let child = match control.mission_store.get_mission(child_id).await {
                Ok(Some(child)) => child,
                Ok(None) => continue,
                Err(err) => {
                    rollback_moved_missions(&state, &control.mission_store, moved).await;
                    return Err(internal_error(err));
                }
            };
            if child.project.project == target_project {
                continue;
            }
            let child_snap = match MovedMissionSnapshot::capture(&state, &child) {
                Ok(snap) => snap,
                Err(err) => {
                    rollback_moved_missions(&state, &control.mission_store, moved).await;
                    return Err(err);
                }
            };
            let child_tags: Vec<String> = child
                .project
                .tags
                .iter()
                .filter(|t| !t.starts_with("orb-folder:"))
                .cloned()
                .collect();
            match update_mission_project_locked(
                is_actor_busy(child_id),
                State(state.clone()),
                Extension(user.clone()),
                Path(child_id),
                Json(UpdateMissionProjectRequest {
                    project: Some(target_project.clone()),
                    track: None,
                    intent: None,
                    github_pr: None,
                    writer: None,
                    tags: Some(child_tags),
                    desired_state: None,
                    next_check_at: None,
                    include_descendants: false,
                    descendant_ids: Vec::new(),
                }),
            )
            .await
            {
                Ok(_) => moved.push(child_snap),
                Err(err) => {
                    rollback_moved_missions(&state, &control.mission_store, moved).await;
                    return Err(err);
                }
            }
        }
    }

    Ok(Json(updated))
}

pub(super) async fn update_mission_project_locked(
    actor_busy: bool,
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateMissionProjectRequest>,
) -> Result<Json<Mission>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    dispatch_admission::recover_dispatch(&state, &control.mission_store, id)
        .await
        .map_err(|error| {
            if error.contains("dispatch_recovery_required") {
                (StatusCode::CONFLICT, error)
            } else {
                internal_error(error)
            }
        })?;
    let current = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Mission {} not found", id)))?;

    let non_tag_writer_inputs_changed =
        req.github_pr.is_some() || req.writer.is_some() || req.intent.is_some();

    // Normalize: blank string patches clear the field; tags are trimmed.
    let normalize = |patch: Option<Option<String>>| -> Option<Option<String>> {
        patch.map(|inner| {
            inner.and_then(|s| {
                let t = s.trim().to_string();
                if t.is_empty() {
                    None
                } else {
                    Some(t)
                }
            })
        })
    };
    let project = normalize(req.project).map(|inner| {
        inner.map(|raw| {
            let canonical = crate::api::projects_overview::canonicalize_project_slug(&raw);
            if canonical != raw {
                tracing::info!(
                    from = %raw,
                    to = %canonical,
                    "canonicalized mission project patch via routes.json alias"
                );
            }
            canonical
        })
    });
    let track = normalize(req.track);
    let intent = normalize(req.intent);
    let github_pr = normalize(req.github_pr);
    let desired_state = normalize(req.desired_state);
    let next_check_at = normalize(req.next_check_at);
    let mut tags: Option<Vec<String>> = req.tags.map(|tags| {
        tags.into_iter()
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
            .collect()
    });
    if tags
        .as_deref()
        .is_some_and(contains_internal_disk_reservation_tag)
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "disk-reservation-v1 tags are reserved internal admission state".to_string(),
        ));
    }

    let effective_string = |patch: &Option<Option<String>>, current: &Option<String>| {
        patch.clone().unwrap_or_else(|| current.clone())
    };
    let effective_github_pr = effective_string(&github_pr, &current.project.github_pr);
    let effective_intent = effective_string(&intent, &current.project.intent);
    let mut effective_tags = tags.clone().unwrap_or_else(|| current.project.tags.clone());
    // Compatibility: old releases persisted leases in project tags.  A
    // project edit may not drop or replace one of those records while the
    // migration reader still reconstructs it.
    let durable_reservation_tags: Vec<String> = current
        .project
        .tags
        .iter()
        .filter(|tag| tag.starts_with(DISK_RESERVATION_TAG_PREFIX))
        .cloned()
        .collect();
    for reservation in &durable_reservation_tags {
        if !effective_tags.iter().any(|tag| tag == reservation) {
            effective_tags.push(reservation.clone());
        }
    }
    if tags.is_some() {
        tags = Some(effective_tags.clone());
    }
    // Pure sidebar folder edits (`orb-folder:*` only) do not alter writer
    // capability, so they must not inject `"pr-writer"` or re-arbitrate foreign
    // PR writer leases.
    let could_change_writer_status = writer_status_inputs_changed(
        non_tag_writer_inputs_changed,
        &effective_tags,
        &current.project.tags,
    );
    let deferred_goal = control
        .mission_store
        .get_deferred_goal(id)
        .await
        .map_err(internal_error)?;
    let initial_prompt = control
        .mission_store
        .get_initial_user_message(id)
        .await
        .map_err(internal_error)?;
    let initial_prompt_requests_writer = requested_pr_writer(
        req.writer,
        Some(&effective_tags),
        effective_intent.as_deref(),
        initial_prompt.as_deref(),
    );
    let deferred_goal_requests_writer = deferred_goal.as_deref().is_some_and(|goal| {
        requested_pr_writer(
            req.writer,
            Some(&effective_tags),
            effective_intent.as_deref(),
            Some(goal),
        )
    });
    // Writer capability governs tracks even when PR metadata is absent.
    // Explicit promotion must replace a read-only tag before lease_mode sees it,
    // while pure project/folder moves keep capability tags untouched.
    let becomes_writer = initial_prompt_requests_writer || deferred_goal_requests_writer;
    if could_change_writer_status {
        if becomes_writer {
            effective_tags.retain(|tag| tag != "pr-readonly" && tag != "pr-writer");
            effective_tags.push("pr-writer".to_string());
            tags = Some(effective_tags.clone());
        } else if req.writer == Some(false) {
            effective_tags.retain(|tag| tag != "pr-readonly" && tag != "pr-writer");
            effective_tags.push("pr-readonly".to_string());
            tags = Some(effective_tags.clone());
        }
    }

    let writer_guard = if becomes_writer && could_change_writer_status {
        Some(
            acquire_durable_pr_writer_lock(&state.control)
                .await
                .map_err(internal_error)?,
        )
    } else {
        None
    };
    if let (Some(github_pr), Some(_guard)) = (effective_github_pr.as_deref(), writer_guard.as_ref())
    {
        if let Some(existing) = find_existing_pr_writer_global(&state.control, github_pr, Some(id))
            .await
            .map_err(internal_error)?
        {
            return Err((
                StatusCode::CONFLICT,
                format!(
                    "PR writer lease is already held by mission {} (status={}); cannot assign mission {} as another writer for {}",
                    existing.id,
                    existing.status,
                    id,
                    canonical_github_pr(github_pr)
                ),
            ));
        }
    }

    // Track move: resolve/absorb the new key, take its lease, release the
    // old ones. A held writer lease is a 409 and the patch is not applied.
    let effective_project = effective_string(&project, &current.project.project);
    let effective_track = effective_string(&track, &current.project.track);
    let project_changed = effective_project != current.project.project;
    // A pure project move (generated per-mission tracks and Orb folder tags
    // follow the mission) keeps the holder, mode, PR and real track. Leases
    // are only revalidated at turn start, so a running mission can move as
    // long as the lease moves atomically; its run, queue and deferred goal
    // stay untouched and the next turn starts under the new project.
    if project_changed && effective_project.is_some() {
        let generated = super::super::track_leases::generated_track_key(&id.to_string());
        let generated_shape = |t: &str| {
            t.strip_prefix("mission-")
                .is_some_and(|rest| rest.len() == 8 && rest.chars().all(|c| c.is_ascii_hexdigit()))
        };
        let track_follows = effective_track == current.project.track
            || (effective_track.as_deref() == Some(generated.as_str())
                && current.project.track.as_deref().is_none_or(generated_shape));
        let move_only = track_follows
            && effective_github_pr == current.project.github_pr
            && effective_intent == current.project.intent
            && folder_only_tag_diff(&effective_tags, &current.project.tags)
            && state
                .projects
                .dispatch_admission(&id.to_string())
                .map_err(internal_error)?
                .is_none();
        let busy = if move_only {
            dispatch_admission::busy_reason(&state, &control.mission_store, &current, actor_busy)
                .await
                .map_err(internal_error)?
        } else {
            None
        };
        if busy.is_some() {
            if let Some(moved) = move_running_mission_project(
                &state,
                &control.mission_store,
                &current,
                MoveTarget {
                    project: effective_project.clone().unwrap_or_default(),
                    track: effective_track.clone(),
                    mode: if becomes_writer {
                        "writer"
                    } else {
                        super::super::track_leases::lease_mode(
                            req.writer,
                            &effective_tags,
                            effective_intent.as_deref(),
                        )
                    },
                    pr: super::super::track_leases::pr_number(effective_github_pr.as_deref()),
                    tags: tags.clone(),
                    desired_state: desired_state.clone(),
                    next_check_at: next_check_at.clone(),
                },
            )
            .await?
            {
                return Ok(Json(moved));
            }
        }
    }
    if project_changed
        || effective_track != current.project.track
        || effective_github_pr != current.project.github_pr
        || !folder_only_tag_diff(&effective_tags, &current.project.tags)
        || effective_intent != current.project.intent
    {
        dispatch_admission::require_quiescent(&state, &control.mission_store, &current, actor_busy)
            .await
            .map_err(|error| (StatusCode::CONFLICT, error))?;
    }
    let track_changed = track.is_some() || project_changed || could_change_writer_status;
    let mut lease_request = None;
    let track = if let (true, Some(slug), Some(key)) = (
        track_changed,
        effective_project.as_deref(),
        effective_track.as_deref(),
    ) {
        let pr = super::super::track_leases::pr_number(effective_github_pr.as_deref());
        let outcome = state
            .projects
            .absorb_track(slug, key, current.title.as_deref(), pr)
            .map_err(internal_error)?;
        let holds_lease = execution_ownership::snapshot(&state.control)
            .await
            .map_err(internal_error)?
            .holds_track(id)
            != Some(false);
        if holds_lease {
            let mode = if becomes_writer {
                "writer"
            } else {
                super::super::track_leases::lease_mode(
                    req.writer,
                    &effective_tags,
                    effective_intent.as_deref(),
                )
            };
            let request = super::super::track_leases::lease_request(
                slug,
                &outcome.key,
                &id.to_string(),
                mode,
                Some(&format!("project-edit:{}", Uuid::new_v4())),
            );
            lease_request = Some(request);
        }
        Some(Some(outcome.key))
    } else {
        track
    };

    let patch = crate::api::mission_store::MissionProjectPatch {
        preserve_updated_at: false,
        title: None,
        project,
        track,
        intent,
        github_pr,
        tags: None,
        tag_patch: tags.as_ref().map(|tags| {
            crate::api::mission_store::MissionTagPatch::between(&current.project.tags, tags)
        }),
        desired_state,
        next_check_at,
    };
    let mut after = current.project.clone();
    if let Some(value) = &patch.project {
        after.project = value.clone();
    }
    if let Some(value) = &patch.track {
        after.track = value.clone();
    }
    if let Some(value) = &patch.intent {
        after.intent = value.clone();
    }
    if let Some(value) = &patch.github_pr {
        after.github_pr = value.clone();
    }
    if let Some(value) = &patch.desired_state {
        after.desired_state = value.clone();
    }
    if let Some(value) = &patch.next_check_at {
        after.next_check_at = value.clone();
    }
    if let Some(delta) = &patch.tag_patch {
        delta.apply(&mut after.tags);
    }
    if track_changed {
        // Recovery compares only fields owned by this edit. The metadata write
        // is atomic; after a crash it either committed or still names `before`.
        // Unrelated tag additions must not prevent that decision.
        let journal = serde_json::json!({"phase": "project-edit",
            "before": {"project": current.project}, "after": {"project": after}});
        state
            .projects
            .begin_dispatch_admission(&id.to_string(), &journal, lease_request.as_ref())
            .map_err(|error| match (&lease_request, &error) {
                (Some(request), super::super::projects_store::LeaseError::Owned { .. }) => (
                    StatusCode::CONFLICT,
                    super::super::track_leases::owned_body(&request.slug, &request.track, &error)
                        .to_string(),
                ),
                _ => internal_error(error.to_string()),
            })?;
    }
    let persisted = control
        .mission_store
        .update_mission_project(id, patch)
        .await;
    if let Err(error) = persisted {
        if track_changed {
            // Keep the receipt when compensation itself fails, so sweep or
            // restart retries the exact provisional claim instead of renewing it.
            dispatch_admission::finish_project_edit(&state, &control.mission_store, id, false)
                .await
                .map_err(internal_error)?;
        }
        return Err(internal_error(error));
    }
    #[cfg(test)]
    dispatch_admission_tests::crash_checkpoint("project_edit_after_metadata");
    if track_changed {
        if let Err(error) =
            dispatch_admission::finish_project_edit(&state, &control.mission_store, id, true).await
        {
            tracing::error!(mission_id = %id, %error, "Committed project edit cleanup is journaled for retry");
        }
    }

    let updated = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Mission {} not found", id)))?;
    Ok(Json(updated))
}

pub(super) struct MoveTarget {
    pub(super) project: String,
    pub(super) track: Option<String>,
    pub(super) mode: &'static str,
    pub(super) pr: Option<i64>,
    pub(super) tags: Option<Vec<String>>,
    pub(super) desired_state: Option<Option<String>>,
    pub(super) next_check_at: Option<Option<String>>,
}

/// Move a running mission to another project: transfer its track lease in
/// one transaction, then persist the metadata. Returns `Ok(None)` when the
/// move would change the held lease mode (writer status), so the caller
/// falls back to the quiescence-guarded identity change.
pub(super) async fn move_running_mission_project(
    state: &Arc<AppState>,
    store: &Arc<dyn MissionStore>,
    current: &Mission,
    target: MoveTarget,
) -> Result<Option<Mission>, (StatusCode, String)> {
    use super::super::projects_store::MoveLeaseError;
    let id = current.id;
    let attempt = id.to_string();
    let source = current
        .project
        .project
        .as_deref()
        .zip(current.project.track.as_deref());
    let mut new_track = None;
    if let Some(key) = target.track.as_deref() {
        match state.projects.move_track_lease(
            source,
            &target.project,
            key,
            &attempt,
            target.mode,
            current.title.as_deref(),
            target.pr,
        ) {
            Ok((outcome, _)) => new_track = Some(outcome.key),
            Err(MoveLeaseError::ModeChange { .. }) => return Ok(None),
            Err(error @ MoveLeaseError::Conflict { .. }) => {
                let MoveLeaseError::Conflict {
                    ref project,
                    ref track,
                    pr_number,
                    ref holder_mission_id,
                } = error
                else {
                    unreachable!()
                };
                return Err((
                    StatusCode::CONFLICT,
                    serde_json::json!({
                        "error": "writer_conflict",
                        "project": project,
                        "track": track,
                        "pr_number": pr_number,
                        "holder_mission_id": holder_mission_id,
                        "message": error.to_string(),
                    })
                    .to_string(),
                ));
            }
            Err(MoveLeaseError::Store(error)) => return Err(internal_error(error)),
        }
    }
    let patch = crate::api::mission_store::MissionProjectPatch {
        preserve_updated_at: false,
        title: None,
        project: Some(Some(target.project.clone())),
        track: new_track
            .clone()
            .filter(|key| current.project.track.as_deref() != Some(key.as_str()))
            .map(Some),
        intent: None,
        github_pr: None,
        tags: None,
        tag_patch: target.tags.as_ref().map(|tags| {
            crate::api::mission_store::MissionTagPatch::between(&current.project.tags, tags)
        }),
        desired_state: target.desired_state,
        next_check_at: target.next_check_at,
    };
    if let Err(error) = store.update_mission_project(id, patch).await {
        // Compensate: hand the lease back to the source project.
        if let (Some(key), Some((slug, old_key))) = (new_track.as_deref(), source) {
            if let Err(rollback) = state.projects.move_track_lease(
                Some((&target.project, key)),
                slug,
                old_key,
                &attempt,
                target.mode,
                current.title.as_deref(),
                target.pr,
            ) {
                tracing::error!(mission_id = %id, %rollback, "Project move lease rollback failed");
            }
        } else if new_track.is_some() {
            let _ = state.projects.release_leases_for_attempt(&attempt);
        }
        return Err(internal_error(error));
    }
    tracing::info!(
        mission_id = %id,
        from = ?current.project.project,
        to = %target.project,
        "Moved running mission between projects; next turn uses the new project"
    );
    store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Mission {id} not found")))
        .map(Some)
}

/// Update mission run settings for future turns.
pub async fn update_mission_settings(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateMissionSettingsRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let current = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Mission {} not found", id)))?;
    if current.backend.starts_with("cloud_") {
        return Err((
            StatusCode::BAD_REQUEST,
            "Cloud service and account cannot be replaced by a local harness".into(),
        ));
    }
    let previous_status = current.status;

    let backend = req.backend.as_ref().and_then(|backend| {
        let trimmed = backend.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    });
    let backend_changed = backend
        .as_deref()
        .is_some_and(|backend| backend != current.backend);
    let effective_backend = backend.clone().unwrap_or_else(|| current.backend.clone());

    {
        if backend_changed {
            if let Some(message) = crate::backend::retired_backend_error(&effective_backend) {
                return Err((StatusCode::BAD_REQUEST, message.to_string()));
            }
        }
        let registry = state.backend_registry.read().await;
        if registry.get(&effective_backend).is_none() {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("Unknown backend: {}", effective_backend),
            ));
        }
    }

    let mut agent = normalize_string_patch(req.agent);
    // Agent names belong to a harness just as model IDs do. Do not carry an
    // OpenCode agent such as `build` into native Claude's --agent option.
    // Explicit agent choices (including custom native agents) remain intact.
    if backend_changed && agent.is_none() {
        agent = Some(None);
    }
    let mut model_override = normalize_string_patch(req.model_override);
    let mut model_effort = normalize_string_patch(req.model_effort);
    let mut fast_mode = req.fast_mode;
    let config_profile = normalize_string_patch(req.config_profile);

    if backend_changed && model_override.is_none() {
        model_override = Some(None);
    }
    if backend_changed && model_effort.is_none() {
        model_effort = Some(None);
    }
    if backend_changed && fast_mode.is_none() {
        fast_mode = Some(false);
    }
    if !matches!(
        effective_backend.as_str(),
        "codex" | "claudecode" | "antigravity"
    ) {
        model_effort = Some(None);
    }

    let workspace_config_profile = state
        .workspaces
        .get(current.workspace_id)
        .await
        .and_then(|ws| ws.config_profile);
    let effective_config_profile = match &config_profile {
        Some(Some(profile)) => Some(profile.clone()),
        Some(None) => workspace_config_profile.clone(),
        None => current
            .config_profile
            .clone()
            .or_else(|| workspace_config_profile.clone()),
    };

    let effective_agent = match &agent {
        Some(Some(agent)) => Some(agent.clone()),
        Some(None) => None,
        None => current.agent.clone(),
    };
    if let Some(ref agent_name) = effective_agent {
        let skip_validation = matches!(
            effective_backend.as_str(),
            "claudecode" | "codex" | "grok" | "antigravity" | "vibe"
        );
        if !skip_validation {
            super::super::library::validate_agent_exists(
                &state,
                agent_name,
                effective_config_profile.as_deref(),
            )
            .await
            .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
        }
    }

    if let Some(Some(raw_effort)) = model_effort.as_ref() {
        let normalized = normalize_model_effort_for_backend(Some(&effective_backend), raw_effort)
            .ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                format!(
                    "Invalid model_effort for backend '{}'. Supported values: {}",
                    effective_backend,
                    supported_model_efforts_for_backend(Some(&effective_backend))
                ),
            )
        })?;
        model_effort = Some(Some(normalized));
    }

    let mut effective_model = match &model_override {
        // Explicitly requested: validated below, and refused if retired.
        Some(Some(model)) => normalize_model_override_for_backend(Some(&effective_backend), model),
        Some(None) => None,
        // Carried forward from the mission. A mission stored before a model was
        // retired must not be stuck — blocking an unrelated settings change
        // (effort, agent, backend) because of an old stored model would be a
        // worse failure than the stale model itself. Migrate it to the current
        // model of its line for the next turn instead; the transcript and the
        // recorded history of what already ran are untouched.
        None => current
            .model_override
            .as_deref()
            .and_then(|model| normalize_model_override_for_backend(Some(&effective_backend), model))
            .map(|model| {
                if let Some(replacement) = crate::model_policy::retired_claude_model(&model) {
                    tracing::info!(
                        mission_id = %id,
                        from = %model,
                        to = %replacement,
                        "migrating retired Claude model for the next turn"
                    );
                    replacement.to_string()
                } else {
                    model
                }
            }),
    };
    if let Some(ref model) = effective_model {
        if model_override.as_ref().and_then(|value| value.as_ref()) != Some(model) {
            model_override = Some(Some(model.clone()));
        }
    }

    if let Some(tier) = req.service_tier {
        fast_mode = Some(tier == crate::codex_speed::Tier::Fast);
    }
    let effective_fast_mode = fast_mode.unwrap_or(current.fast_mode);
    validate_fast_mode(
        &effective_backend,
        effective_model.as_deref(),
        effective_fast_mode,
    )
    .map_err(|error| (StatusCode::BAD_REQUEST, error))?;

    if effective_backend == "claudecode" && effective_model.is_none() {
        if let Some(default_model) =
            resolve_claudecode_default_model(&state.library, effective_config_profile.as_deref())
                .await
        {
            effective_model = Some(default_model.clone());
            model_override = Some(Some(default_model));
        }
    }

    if let Some(ref model) = effective_model {
        if let Err(e) =
            super::super::providers::validate_model_override(&state, &effective_backend, model)
                .await
        {
            return Err((StatusCode::BAD_REQUEST, e));
        }
    }

    let service_tier = req
        .service_tier
        .or_else(|| backend_changed.then_some(crate::codex_speed::Tier::Standard))
        .or(fast_mode.map(|fast| crate::codex_speed::Tier::from_legacy(None, fast)));
    let effective_tier = crate::codex_speed::Tier::from_legacy(
        service_tier.or(current.service_tier),
        effective_fast_mode,
    );
    if !mission_is_client_placed(&control, id)
        .await
        .map_err(internal_error)?
    {
        speed::validate(
            &state.config.working_dir,
            &effective_backend,
            effective_model.as_deref(),
            effective_tier,
            Some(id),
        )
        .await
        .map_err(|error| (StatusCode::BAD_REQUEST, error))?;
    }
    let (tx, rx) = oneshot::channel();
    let session_id = Uuid::new_v4().to_string();
    control
        .cmd_tx
        .send(ControlCommand::UpdateMissionSettings {
            id,
            backend,
            agent,
            model_override,
            model_effort,
            fast_mode,
            service_tier,
            config_profile,
            session_id,
            respond: tx,
        })
        .await
        .map_err(session_unavailable)?;

    let mission = rx.await.map_err(recv_failed)?.map_err(|e| {
        if e.starts_with("invalid_access_program:") {
            (StatusCode::BAD_REQUEST, e)
        } else if e.contains("not found") {
            (StatusCode::NOT_FOUND, e)
        } else if e.contains("running") {
            (StatusCode::CONFLICT, e)
        } else {
            internal_error(e)
        }
    })?;

    // The settings write is durable at this point. A handoff on a dead
    // mission continues it on the new settings; the handoff user message
    // was logged by the command handler, so the resumed turn sees it. A
    // resume refusal is reported, never turned into an error.
    let mut body = serde_json::to_value(&mission).map_err(internal_error)?;
    if should_queue_resume(previous_status, req.resume) {
        let (tx, rx) = oneshot::channel();
        let queued = match control
            .cmd_tx
            .send(ControlCommand::ResumeMission {
                content: None,
                mission_id: id,
                clean_workspace: false,
                skip_message: false,
                respond: tx,
            })
            .await
        {
            Ok(()) => rx
                .await
                .map_err(|e| e.to_string())
                .and_then(|r| r.map(|_| ())),
            Err(e) => Err(e.to_string()),
        };
        match queued {
            Ok(()) => {
                tracing::info!(mission_id = %id, previous = ?previous_status, "settings handoff resumed the mission");
                body["resume_queued"] = serde_json::Value::Bool(true);
            }
            Err(error) => {
                tracing::warn!(mission_id = %id, %error, "settings handoff could not resume the mission");
                body["resume_queued"] = serde_json::Value::Bool(false);
                body["resume_warning"] = serde_json::Value::String(error);
            }
        }
    }
    Ok(Json(body))
}

/// Load/switch to a mission.
pub async fn load_mission(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> Result<Json<Mission>, (StatusCode, String)> {
    let (tx, rx) = oneshot::channel();

    let control = control_for_user(&state, &user).await;
    control
        .cmd_tx
        .send(ControlCommand::LoadMission { id, respond: tx })
        .await
        .map_err(session_unavailable)?;

    rx.await.map_err(recv_failed)?.map(Json).map_err(|e| {
        // Return 404 if mission was not found
        if e.contains("not found") {
            (StatusCode::NOT_FOUND, e)
        } else {
            (StatusCode::INTERNAL_SERVER_ERROR, e)
        }
    })
}

/// Record that the user opened this mission for the first time since it last
/// entered `AwaitingUser`. Sets `first_viewed_at` to now (no-op if already set)
/// and broadcasts a `MissionStatusChanged` event so other clients can render
/// the "opened" dot. The dashboard and iOS clients call this from their
/// mission-detail entry points; the periodic ack-promotion tick uses the
/// timestamp to decide when to move the mission to `Acknowledged`.
pub async fn mark_mission_opened(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> Result<Json<Mission>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let now = chrono::Utc::now().to_rfc3339();
    let newly_set = control
        .mission_store
        .set_mission_first_viewed_at_if_unset(id, &now)
        .await
        .map_err(internal_error)?;
    let mission = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Mission {} not found", id)))?;
    if newly_set.is_some() {
        let _ = control.events_tx.send(AgentEvent::MissionStatusChanged {
            completion: None,
            execution: None,
            mission_id: id,
            status: mission.status,
            summary: None,
        });
    }
    Ok(Json(mission))
}

/// Set mission status (completed/failed).
pub(super) async fn mission_is_client_placed(
    control: &ControlState,
    id: Uuid,
) -> Result<bool, String> {
    let Some(mission) = control.mission_store.get_mission(id).await? else {
        return Ok(false);
    };
    Ok(client_placement::is_tagged(&mission.project.tags))
}
