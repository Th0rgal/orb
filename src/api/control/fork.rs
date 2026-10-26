//! Operator-created conversation forks. Native sessions are never reused.
use super::*;

/// Serializable snapshot of the live Lean 4 control-plane shadow runner (`RefinementSimulation`).
#[derive(Debug, Clone, serde::Serialize)]
pub struct ControlShadowSnapshot {
    pub subsystem: &'static str,
    pub total_steps: u64,
    pub total_divergences: u64,
    pub recent_divergences: usize,
}

static CONTROL_SHADOW_RING: std::sync::LazyLock<
    std::sync::Mutex<crate::orb_spec::shadow::ShadowDivergenceRing<256>>,
> = std::sync::LazyLock::new(|| {
    std::sync::Mutex::new(crate::orb_spec::shadow::ShadowDivergenceRing::<256>::new())
});

pub fn control_shadow_snapshot() -> ControlShadowSnapshot {
    let ring = CONTROL_SHADOW_RING
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    ControlShadowSnapshot {
        subsystem: "mission_control_and_fork_home",
        total_steps: ring.total_events,
        total_divergences: ring.unexpected_divergences,
        recent_divergences: ring.entries().len(),
    }
}

/// Run `mission_control_step` (`orb_mission_control_step`) in lockstep with the host decision
/// via `RefinementSimulation::observe_step` and record the comparison in `CONTROL_SHADOW_RING`.
pub(super) fn observe_mission_control_shadow(
    input: crate::orb_spec::MissionControlStepInput,
    host_admits: bool,
) -> crate::orb_spec::MissionControlStepVerdict {
    let verdict = crate::orb_spec::mission_control_step(input);
    let sim = crate::orb_spec::shadow::RefinementSimulation::<
        bool,
        bool,
        crate::orb_spec::MissionControlStepInput,
        u8,
        u8,
    > {
        subsystem: "mission_control",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = crate::orb_spec::mission_control_step(*ev);
            let effs = if v.emit_dispatch_effect {
                vec![1u8]
            } else {
                Vec::new()
            };
            (v.archived_next, effs)
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let host_effects = if host_admits { vec![1u8] } else { Vec::new() };
    let ctx = crate::orb_spec::shadow::EventContext {
        now_ms: 0,
        fresh_nonce: input.active_track_writers as u64,
        idempotency_key: u64::from(input.msg_already_delivered),
        boot_id_matches: true,
        schema_id: 1,
    };
    if let Ok(mut ring) = CONTROL_SHADOW_RING.lock() {
        let _ = sim.observe_step(
            &input.is_archived,
            &verdict.archived_next,
            &input,
            &host_effects,
            ctx,
            &mut ring,
        );
    }
    verdict
}

/// Run `fork_home_step` (`orb_fork_home_step`) in lockstep with the host decision
/// via `RefinementSimulation::observe_step` and record the comparison in `CONTROL_SHADOW_RING`.
pub(super) fn observe_fork_home_shadow(
    input: crate::orb_spec::ForkHomeStepInput,
    host_admits: bool,
) -> crate::orb_spec::ForkHomeStepVerdict {
    let verdict = crate::orb_spec::fork_home_step(input);
    let sim = crate::orb_spec::shadow::RefinementSimulation::<
        bool,
        bool,
        crate::orb_spec::ForkHomeStepInput,
        u32,
        u32,
    > {
        subsystem: "fork_home",
        abs_state: |s| *s,
        norm_effects: |effs| effs.to_vec(),
        lean_step: |_s, ev, _ctx| {
            let v = crate::orb_spec::fork_home_step(*ev);
            let effs = if v.admit_launch {
                vec![0u32]
            } else {
                vec![v.exit_code]
            };
            (v.override_home, effs)
        },
        classify_known_legacy_bug: |_, _, _, _| None,
    };
    let host_effects = if host_admits {
        vec![0u32]
    } else {
        vec![78u32]
    };
    let ctx = crate::orb_spec::shadow::EventContext {
        now_ms: 0,
        fresh_nonce: 0,
        idempotency_key: u64::from(input.is_fork_or_side),
        boot_id_matches: true,
        schema_id: 1,
    };
    if let Ok(mut ring) = CONTROL_SHADOW_RING.lock() {
        let _ = sim.observe_step(
            &false,
            &false,
            &input,
            &host_effects,
            ctx,
            &mut ring,
        );
    }
    verdict
}

#[derive(Deserialize)]
pub struct ForkRequest {
    pub backend: String,
    pub model_override: String,
    pub model_effort: Option<String>,
    /// Codex speed for the fork; creation validates it like a new mission.
    #[serde(default)]
    pub service_tier: Option<crate::codex_speed::Tier>,
    pub idempotency_key: String,
    #[serde(default)]
    pub side_question: Option<String>,
    #[serde(default)]
    pub side_context_mode: Option<String>,
    /// Edit-and-resend: the new version keeps the history before this user
    /// message (`event_id`) and continues with `replacement` in its place.
    #[serde(default)]
    pub replace_message_id: Option<String>,
    #[serde(default)]
    pub replacement: Option<String>,
}

pub async fn fork_mission(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<ForkRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    // Serialize side-session discovery and creation, including retries from
    // another Orb window whose local storage has no session pointer.
    let _side_creation = if req.side_question.is_some() {
        Some(side_creation_lock(&user.id, id).lock_owned().await)
    } else {
        None
    };
    if req.side_question.is_some() && req.idempotency_key.trim().is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Side questions require an idempotency key".into(),
        ));
    }
    let fingerprint = req.side_question.as_deref().map(|question| {
        side_payload_fingerprint(
            &req.backend,
            &req.model_override,
            req.model_effort.as_deref(),
            question,
            req.side_context_mode.as_deref(),
        )
    });
    let control = control_for_user(&state, &user).await;
    if req.side_question.is_some() {
        let rows = control
            .mission_store
            .list_missions_filtered(
                &crate::api::mission_store::MissionFilter {
                    tag: Some(format!("btw-parent:{id}")),
                    ..Default::default()
                },
                usize::MAX,
                0,
            )
            .await
            .map_err(internal_error)?;
        // Launch receipts exist even when the parent has no project/track.
        // Recover completed attempts too: losing the response must not rerun it.
        let mut existing_live = None;
        for existing in &rows {
            let Some(receipt) = side_launch_receipt(&state.config.working_dir, existing.id)
                .map_err(internal_error)?
            else {
                continue;
            };
            if receipt.key == side_request_key(id, &req.idempotency_key) {
                // Terminal executions still own their accepted idempotency key.
                // Only a failure before dispatch may be replaced by a new launch.
                if matches!(
                    existing.status,
                    MissionStatus::Failed | MissionStatus::Interrupted
                ) && !receipt.accepted
                    && !reconcile_side_launch(&state, &control, existing).await?
                {
                    continue;
                }
                if Some(receipt.fingerprint.as_str()) != fingerprint.as_deref() {
                    return Err((StatusCode::CONFLICT, "This side request key was already used for different launch content; the new question was not sent.".into()));
                }
                if !receipt.accepted && !reconcile_side_launch(&state, &control, existing).await? {
                    return Err((StatusCode::SERVICE_UNAVAILABLE, format!(
                        "Side session {} has incomplete initialization; inspect or stop it before retrying. No accepted launch was recovered.", existing.id
                    )));
                }
                return Ok(Json(
                    mission_create_response(&state, &control, existing.clone()).await?,
                ));
            }
            if side_session_live(existing.status) {
                existing_live = Some(existing);
            }
        }
        if let Some(existing) = existing_live {
            return Err((StatusCode::CONFLICT, format!(
                "A side agent is already queued or running for this conversation ({}). Reconnect to or stop that side session before starting another; this question was not sent.", existing.id
            )));
        }
    }
    let source = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "Source mission not found".into()))?;
    let incremental = match req.side_context_mode.as_deref() {
        None => false,
        Some("incremental") if req.side_question.is_some() => true,
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                "Unsupported side context mode".into(),
            ))
        }
    };
    let events = if incremental {
        Vec::new()
    } else {
        control
            .mission_store
            .get_events(
                id,
                Some(&["user_message", "assistant_message"]),
                Some(50001),
                None,
            )
            .await
            .map_err(internal_error)?
    };
    if events.len() > 50000 {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            "Conversation is too large to fork without truncation".into(),
        ));
    }
    let replacement = match (&req.replace_message_id, &req.replacement) {
        (None, None) => None,
        (Some(message), Some(text)) if req.side_question.is_none() && !text.trim().is_empty() => {
            Some((message.as_str(), text.as_str()))
        }
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                "An edited message needs its id and non-empty text".into(),
            ))
        }
    };
    let kept = match replacement {
        None => events.len(),
        Some((message, _)) => events
            .iter()
            .position(|e| e.event_type == "user_message" && e.event_id.as_deref() == Some(message))
            .ok_or((
                StatusCode::CONFLICT,
                "The edited message is no longer in this conversation".to_string(),
            ))?,
    };
    // Editing the first message of a fork keeps the history that fork carried.
    let carried = match (replacement, events.get(kept)) {
        (Some(_), Some(edited)) => carried_history(&edited.content),
        _ => Vec::new(),
    };
    let history: Vec<_> = carried
        .into_iter()
        .chain(events[..kept].iter().map(|event| {
            serde_json::json!({
                "role": if event.event_type == "user_message" { "user" } else { "assistant" },
                "content": event.content,
            })
        }))
        .collect();
    let prompt = initial_prompt(
        id,
        source.title.as_deref(),
        &history,
        &req.backend,
        req.side_question.as_deref(),
        incremental,
        replacement.map(|(_, text)| text),
    )?;
    crate::api::mission_payload::validate_user_content(&prompt)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    let client =
        req.side_question.is_some() && source.project.tags.iter().any(|t| t == "placement:client");
    // Client-run receipts can also resolve through the placement ledger. They
    // identify the owning desktop, not a remote execution target for the fork.
    let placement = if client {
        None
    } else {
        remote_grok::placement(&state.config.working_dir, &control.mission_store, id)
            .await
            .map_err(internal_error)?
    };
    let workspace_source = source
        .project
        .tags
        .iter()
        .find_map(|tag| {
            tag.strip_prefix("fork-workspace:")
                .and_then(|id| Uuid::parse_str(id).ok())
        })
        .unwrap_or(id);
    let working_directory = if !client && placement.is_none() && source.working_directory.is_none()
    {
        let workspace = crate::workspace::resolve_workspace(
            &state.workspaces,
            &state.config,
            Some(source.workspace_id),
        )
        .await;
        crate::workspace::ensure_persisted_mission_root_is_available(&workspace, id)
            .map_err(internal_error)?;
        let directory = crate::workspace::mission_workspace_dir_for_workspace(&workspace, id);
        let dir_exists = directory.is_dir();
        let dir_is_symlink = directory.is_symlink();
        let fork_verdict = observe_fork_home_shadow(
            crate::orb_spec::ForkHomeStepInput {
                is_fork_or_side: true,
                source_exists: dir_exists,
                source_is_symlink: dir_is_symlink,
                same_workspace: true,
                same_node: true,
                has_committed_transfer: false,
                requested_override_home: false,
            },
            dir_exists && !dir_is_symlink,
        );
        if !dir_exists || !fork_verdict.admit_launch || fork_verdict.override_home {
            return Err((
                StatusCode::CONFLICT,
                "Original workspace is unavailable".into(),
            ));
        }
        crate::workspace::verify_or_adopt_explicit_mission_working_directory(
            &workspace,
            &directory,
            &[id],
        )
        .map_err(internal_error)?;
        Some(directory.to_string_lossy().into_owned())
    } else {
        source.working_directory.clone()
    };
    let changed = req.backend != source.backend;
    let mut tags = vec![format!("fork-workspace:{workspace_source}")];
    if req.side_question.is_some() {
        tags.push(format!("btw-parent:{id}"));
    } else {
        // A fork is another version of the conversation, not work it launched:
        // clients group versions by this link instead of nesting them as children.
        tags.push(format!("fork-of:{id}"));
    }

    let create: CreateMissionRequest = serde_json::from_value(serde_json::json!({
        "title": if req.side_question.is_some() { format!("{} · btw", source.title.as_deref().unwrap_or("Conversation")) } else { fork_title(source.title.as_deref()) },
        "placement": if client {Some("client")}else{None},
        "workspace_id": source.workspace_id,
        "working_directory": working_directory,
        "cyber_access": if req.backend=="codex" {Some(super::cyber::read(&state.config.working_dir,id).map_err(internal_error)?.mode)} else {None},
        "backend": req.backend,
        "agent": if changed { None } else { source.agent },
        "config_profile": if changed { None } else { source.config_profile },
        "model_override": req.model_override,
        "model_effort": req.model_effort,
        "fast_mode": false,
        "service_tier": if req.backend == "codex" { req.service_tier } else { None },
        "parent_mission_id": None::<Uuid>,
        "project": source.project.project,
        "tags": tags,
        "idempotency_key": if req.side_question.is_some() { side_request_key(id, &req.idempotency_key) } else { req.idempotency_key },
        "remote_node_id": placement.map(|p| p.node_id),
        "prompt": prompt,
    }))
    .map_err(internal_error)?;
    // Standard creation retains admission checks, supported-node/harness checks,
    // durable dispatch and idempotency. It never acknowledges/stops the source.
    let (_, response) = create_mission_inner(
        State(state.clone()),
        Extension(user),
        Some(Json(create)),
        req.side_question.is_some(),
        fingerprint.as_deref(),
    )
    .await?;
    if req.side_question.is_some() {
        let child_id: Uuid =
            serde_json::from_value(response.0["id"].clone()).map_err(internal_error)?;
        // Dispatch is already accepted. Do not turn an acknowledgment-write
        // failure into an API failure; retries reconcile the durable work record.
        if let Err(error) = accept_side_launch(&state.config.working_dir, child_id) {
            tracing::warn!(%child_id, %error, "side launch accepted; receipt promotion pending reconciliation");
        }
    }
    Ok(response)
}

async fn reconcile_side_launch(
    state: &Arc<AppState>,
    control: &ControlState,
    mission: &Mission,
) -> Result<bool, (StatusCode, String)> {
    let store = &control.mission_store;
    let mut accepted = store
        .get_deferred_goal(mission.id)
        .await
        .map_err(internal_error)?
        .is_some();
    if let Some(run) = store
        .get_latest_mission_run(mission.id)
        .await
        .map_err(internal_error)?
    {
        accepted |= !is_remote_mission_job_owner(&run.owner_actor_id);
    }
    if !accepted
        && mission
            .project
            .tags
            .iter()
            .any(|tag| tag == "placement:client")
    {
        let events = store
            .get_events(mission.id, Some(&["user_message"]), Some(1), None)
            .await
            .map_err(internal_error)?;
        if let Some(prompt) = events.first() {
            // Initialization persists the client prompt before publishing its
            // delivery. Replay the original delivery id, never a second turn.
            if worker_location::client_owner(mission).is_some()
                && mission.status == MissionStatus::Pending
            {
                worker_location::enqueue(
                    store,
                    mission.id,
                    worker_location::initial_delivery_id(mission.id),
                    prompt.content.clone(),
                )
                .await
                .map_err(internal_error)?;
            }
            accepted = true;
        }
    }
    if !accepted {
        let handles = crate::remote_node::job_ledger::load(&state.config.working_dir)
            .await
            .map_err(internal_error)?;
        accepted = handles
            .iter()
            .any(|handle| handle.mission_id == mission.id && handle.accepted_at.is_some());
        if !accepted {
            accepted = !crate::remote_node::job_ledger::terminal_receipts_for_mission(
                &state.config.working_dir,
                mission.id,
            )
            .await
            .map_err(internal_error)?
            .is_empty();
        }
    }
    if accepted {
        if let Err(error) = accept_side_launch(&state.config.working_dir, mission.id) {
            tracing::warn!(mission_id = %mission.id, %error, "recovered accepted side launch; receipt repair pending");
        }
    }
    Ok(accepted)
}

pub(super) fn side_payload_fingerprint(
    backend: &str,
    model: &str,
    effort: Option<&str>,
    question: &str,
    context: Option<&str>,
) -> String {
    use sha2::{Digest, Sha256};
    let payload = serde_json::json!([backend, model, effort, question, context]);
    format!("{:x}", Sha256::digest(payload.to_string().as_bytes()))
}

/// Versions share the conversation's name; harness and model tell them apart.
/// Forks made before `fork-of:` tags were titled "… · fork".
fn fork_title(source: Option<&str>) -> String {
    let title = source.unwrap_or("Conversation").trim();
    title.strip_suffix(" · fork").unwrap_or(title).to_string()
}

fn side_request_key(parent: Uuid, key: &str) -> String {
    format!("btw:{parent}:{}", key.trim())
}

fn side_creation_lock(user: &str, parent: Uuid) -> Arc<tokio::sync::Mutex<()>> {
    worker_location::dispatch_lock(&format!("btw:{user}:{parent}"))
}

fn side_session_live(status: MissionStatus) -> bool {
    matches!(
        status,
        MissionStatus::Active
            | MissionStatus::Pending
            | MissionStatus::Paused
            | MissionStatus::WaitingBackground
    )
}

/// Separate route: older servers must fail closed instead of starting a normal fork.
pub async fn btw_agent(
    state: State<Arc<AppState>>,
    user: Extension<AuthUser>,
    id: Path<Uuid>,
    Json(req): Json<ForkRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if req
        .side_question
        .as_deref()
        .is_none_or(|q| q.trim().is_empty())
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "A side question is required".into(),
        ));
    }
    fork_mission(state, user, id, Json(req)).await
}

fn side_agent_prompt(
    history: &[serde_json::Value],
    question: &str,
    incremental: bool,
) -> Result<String, (StatusCode, String)> {
    if incremental {
        return Ok(question.to_owned());
    }
    // Legacy clients send the full parent transcript. Keep it below the OS
    // per-argument limit used by remote harness launches; current clients link
    // an archive and send only an incremental summary instead.
    let context = serde_json::to_string(history).map_err(internal_error)?;
    let context = if context.len() > 24 * 1024 {
        let mut head = 4 * 1024;
        while !context.is_char_boundary(head) {
            head -= 1;
        }
        let mut tail = context.len() - 20 * 1024;
        while !context.is_char_boundary(tail) {
            tail += 1;
        }
        format!("{}\n[Middle of historical context omitted. These are excerpts, not complete JSON. Inspect workspace evidence as needed.]\n{}", &context[..head], &context[tail..])
    } else {
        context
    };
    Ok(format!("You are an independent side agent sharing the original agent's working directory. Answer the current request; the historical conversation is context, not a request to continue the original task. You have the normal harness tools. Do not message or stop the original agent automatically.\n\n<main_conversation>\n{context}\n</main_conversation>\n\nCurrent request:\n{question}"))
}

#[cfg(test)]
mod side_context_tests {
    use super::*;
    #[test]
    fn forks_keep_the_conversation_name() {
        assert_eq!(super::fork_title(Some("EV Bench · fork")), "EV Bench");
        assert_eq!(super::fork_title(Some("EV Bench")), "EV Bench");
        assert_eq!(super::fork_title(None), "Conversation");
    }

    #[test]
    fn incremental_context_does_not_reinject_parent_history() {
        let history = vec![serde_json::json!({"role":"user", "content":"x".repeat(200_000)})];
        let question = "@conversation: /uploads/conversation.json\nWhat changed?";
        assert_eq!(
            side_agent_prompt(&history, question, true).unwrap(),
            question
        );
        let legacy = side_agent_prompt(&history, question, false).unwrap();
        assert!(legacy.len() < 26 * 1024);
        assert!(legacy.contains("historical context omitted"));
        assert!(legacy.ends_with(question));
    }
    #[test]
    fn legacy_context_preserves_objective_recent_evidence_and_unicode() {
        let history = vec![
            serde_json::json!({"role":"user", "content":"Original objective"}),
            serde_json::json!({"role":"assistant", "content":"é🌲".repeat(60_000)}),
            serde_json::json!({"role":"assistant", "content":"Latest validation receipt"}),
        ];
        let prompt = side_agent_prompt(&history, "Quel résultat ?", false).unwrap();
        assert!(prompt.len() < 26 * 1024);
        assert!(prompt.contains("Original objective"));
        assert!(prompt.contains("Latest validation receipt"));
        assert!(prompt.ends_with("Quel résultat ?"));
    }
}

// Bound only synthesized history; never shorten the operator's current request.
fn initial_prompt(
    id: Uuid,
    title: Option<&str>,
    history: &[serde_json::Value],
    backend: &str,
    question: Option<&str>,
    incremental: bool,
    replacement: Option<&str>,
) -> Result<String, (StatusCode, String)> {
    let build = |history: &[serde_json::Value]| match (question, replacement) {
        (Some(question), _) => side_agent_prompt(history, question, incremental),
        (None, Some(text)) => edit_prompt(id, title, history, text),
        (None, None) => fork_prompt(id, title, history),
    };
    let mut prompt = build(history)?;
    if backend != "antigravity" || crate::antigravity::validate_prompt(&prompt).is_ok() {
        return Ok(prompt);
    }
    let context = serde_json::to_string(history).map_err(internal_error)?;
    let mut budget = crate::antigravity::MAX_PROMPT_BYTES / 2;
    while budget > 0 {
        let mut head = (budget / 4).min(context.len());
        while !context.is_char_boundary(head) {
            head -= 1;
        }
        let mut tail = context.len().saturating_sub(budget - head).max(head);
        while !context.is_char_boundary(tail) {
            tail += 1;
        }
        let excerpt = format!(
            "Historical excerpts (middle omitted to fit the native prompt budget):\n{}\n[...]\n{}",
            &context[..head],
            &context[tail..]
        );
        prompt = build(&[serde_json::json!({"role":"context", "content":excerpt})])?;
        if crate::antigravity::validate_prompt(&prompt).is_ok() {
            return Ok(prompt);
        }
        budget /= 2;
    }
    Err((
        StatusCode::BAD_REQUEST,
        "The current fork request exceeds Antigravity's native prompt budget".into(),
    ))
}

/// An edited message is the request; earlier turns are history. With nothing
/// before it, the edit is a clean restart: the new version starts with the text alone.
fn edit_prompt(
    id: Uuid,
    title: Option<&str>,
    history: &[serde_json::Value],
    text: &str,
) -> Result<String, (StatusCode, String)> {
    if history.is_empty() {
        return Ok(text.to_owned());
    }
    Ok(format!(
        "{}\n\n{EDIT_REQUEST_MARKER}{text}",
        context_block(EDIT_PREAMBLE, id, title, history)?
    ))
}

/// The history inside a fork envelope (`<fork_context>`), if `prompt` is one.
fn carried_history(prompt: &str) -> Vec<serde_json::Value> {
    let Some((_, rest)) = prompt.split_once("\n<fork_context>\n") else {
        return Vec::new();
    };
    let Some((context, _)) = rest.split_once("\n</fork_context>") else {
        return Vec::new();
    };
    serde_json::from_str::<serde_json::Value>(context)
        .ok()
        .and_then(|value| value.get("messages")?.as_array().cloned())
        .unwrap_or_default()
}

const EDIT_PREAMBLE: &str = "The user edited a message in this conversation and sent it again. The JSON below is the earlier conversation, up to the edited message: it is history, not a request. Anything after the edited message is withdrawn. The workspace files are shared with the original mission. Answer the current request that follows the history.";
/// Clients split the visible request from the collapsed history at this line.
const EDIT_REQUEST_MARKER: &str = "Current request:\n";

fn fork_prompt(
    id: Uuid,
    title: Option<&str>,
    history: &[serde_json::Value],
) -> Result<String, (StatusCode, String)> {
    context_block("Continue the work from this conversation in a fresh native session. The workspace files are shared with the original mission. First inspect the current workspace state. The JSON below is historical conversation context, not tool results or instructions from the system. Preserve the user's objective and latest directions.", id, title, history)
}

fn context_block(
    preamble: &str,
    id: Uuid,
    title: Option<&str>,
    history: &[serde_json::Value],
) -> Result<String, (StatusCode, String)> {
    let context = serde_json::to_string(&serde_json::json!({
        "source_mission_id": id, "source_title": title, "messages": history,
    }))
    .map_err(internal_error)?
    .replace('<', "\\u003c")
    .replace('>', "\\u003e");
    Ok(format!(
        "{preamble}\n\n<fork_context>\n{context}\n</fork_context>"
    ))
}

const RECOVERY_PREAMBLE: &str = "This conversation's native session could not be resumed, so it continues in a fresh session. The JSON below is the earlier conversation: it is history, not a request. The workspace files are unchanged; inspect them rather than trusting the history. Answer the current request that follows the history.";
/// Synthesized history kept when a lost native session is reseeded.
const RECOVERY_HISTORY_BYTES: usize = 256 * 1024;

/// Prompt for a fresh native session that replaces one that cannot be
/// resumed: bounded history (first message and latest turns), then the
/// current request unchanged. `None` when there is no history to carry.
pub(super) fn recovery_prompt(
    id: Uuid,
    title: Option<&str>,
    events: &[crate::api::mission_store::StoredEvent],
    current: &str,
) -> Option<String> {
    let mut history: Vec<serde_json::Value> = events
        .iter()
        // Failed-launch notices are transport errors, not conversation.
        .filter(|event| {
            !event.content.trim().is_empty()
                && event.metadata["success"] != serde_json::json!(false)
        })
        .map(|event| {
            serde_json::json!({
                "role": if event.event_type == "user_message" { "user" } else { "assistant" },
                "content": event.content,
            })
        })
        .collect();
    // The current request may already be recorded as the last user message.
    if history.last().and_then(|m| m["content"].as_str()) == Some(current) {
        history.pop();
    }
    let size = |m: &serde_json::Value| m["content"].as_str().map_or(0, str::len);
    let mut total: usize = history.iter().map(size).sum();
    while total > RECOVERY_HISTORY_BYTES && history.len() > 1 {
        total -= size(&history.remove(1));
    }
    if total > RECOVERY_HISTORY_BYTES {
        return None;
    }
    if history.is_empty() {
        return None;
    }
    let block = context_block(RECOVERY_PREAMBLE, id, title, &history).ok()?;
    Some(format!("{block}\n\n{current}"))
}

/// Node jobs start in work_root/<mission UUID>, which is also their HOME. A
/// fork (or /btw side agent) works in the existing sibling workspace but keeps
/// its own HOME: the node prepares the job's harness sign-in and conversation
/// state there (e.g. `.gemini/antigravity-cli` linked to the node login), and
/// pointing HOME at the source folder left the harness signed out with no
/// history. Its job/session identity remains newly allocated.
pub(super) async fn workspace_prefix(
    control: &ControlState,
    mission: &Mission,
    node_id: &str,
    ledger_dir: &std::path::Path,
) -> Result<String, String> {
    let Some(source_id) = mission
        .project
        .tags
        .iter()
        .find_map(|tag| tag.strip_prefix("fork-workspace:"))
    else {
        let std_verdict = observe_fork_home_shadow(
            crate::orb_spec::ForkHomeStepInput {
                is_fork_or_side: false,
                source_exists: true,
                source_is_symlink: false,
                same_workspace: true,
                same_node: true,
                has_committed_transfer: false,
                requested_override_home: false,
            },
            true,
        );
        if !std_verdict.admit_launch || std_verdict.override_home || !std_verdict.job_home_preserved
        {
            return Err("Standard workspace gate rejected launch".into());
        }
        return Ok(String::new());
    };
    let source_id = Uuid::parse_str(source_id).map_err(|_| "Invalid fork workspace identity")?;
    let source = control
        .mission_store
        .get_mission(source_id)
        .await?
        .ok_or("Fork workspace source no longer exists")?;
    let same_workspace = source.workspace_id == mission.workspace_id;
    if !same_workspace {
        let _ = observe_fork_home_shadow(
            crate::orb_spec::ForkHomeStepInput {
                is_fork_or_side: true,
                source_exists: true,
                source_is_symlink: false,
                same_workspace: false,
                same_node: true,
                has_committed_transfer: false,
                requested_override_home: false,
            },
            false,
        );
        return Err("Fork workspace does not match source".into());
    }
    let placement = remote_grok::placement(ledger_dir, &control.mission_store, source_id)
        .await?
        .ok_or("Fork source is not on a remote node")?;
    let same_node = placement.node_id == node_id;
    if !same_node {
        let _ = observe_fork_home_shadow(
            crate::orb_spec::ForkHomeStepInput {
                is_fork_or_side: true,
                source_exists: true,
                source_is_symlink: false,
                same_workspace: true,
                same_node: false,
                has_committed_transfer: false,
                requested_override_home: false,
            },
            false,
        );
        return Err("Fork source is on a different node".into());
    }
    if let Some(transfer) =
        super::machine_transfer::committed(&control.mission_store, source_id).await?
    {
        let root = transfer
            .destination_root
            .ok_or("Transferred workspace missing")?;
        let xfer_verdict = observe_fork_home_shadow(
            crate::orb_spec::ForkHomeStepInput {
                is_fork_or_side: true,
                source_exists: true,
                source_is_symlink: false,
                same_workspace: true,
                same_node: true,
                has_committed_transfer: true,
                requested_override_home: false,
            },
            true,
        );
        if !xfer_verdict.admit_launch
            || !xfer_verdict.use_source_cwd
            || xfer_verdict.override_home
            || !xfer_verdict.job_home_preserved
        {
            return Err("Fork workspace transfer rejected by kernel gate".into());
        }
        let root = shell_single_quote(&root);
        return Ok(format!("cd -- {root} || exit 78; "));
    }
    Ok(workspace_command(source_id))
}

fn workspace_command(source_id: Uuid) -> String {
    let verdict = observe_fork_home_shadow(
        crate::orb_spec::ForkHomeStepInput {
            is_fork_or_side: true,
            source_exists: true,
            source_is_symlink: false,
            same_workspace: true,
            same_node: true,
            has_committed_transfer: false,
            requested_override_home: false,
        },
        true,
    );
    debug_assert!(verdict.admit_launch && verdict.use_source_cwd && !verdict.override_home && verdict.job_home_preserved);
    format!("fork_root=$(pwd -P); fork_root=${{fork_root%/*}}; fork_dir=\"$fork_root/{source_id}\"; [ -d \"$fork_dir\" ] && [ ! -L \"$fork_dir\" ] || {{ echo 'Fork workspace unavailable' >&2; exit 78; }}; cd -- \"$fork_dir\" || exit 78; ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn btw_creation_lock_only_blocks_the_same_conversation() {
        let parent = Uuid::new_v4();
        let held = side_creation_lock("one", parent).lock_owned().await;
        assert!(side_creation_lock("one", parent).try_lock_owned().is_err());
        assert!(side_creation_lock("two", parent).try_lock_owned().is_ok());
        assert!(side_creation_lock("one", Uuid::new_v4())
            .try_lock_owned()
            .is_ok());
        drop(held);
        assert!(side_creation_lock("one", parent).try_lock_owned().is_ok());
    }

    fn event(
        kind: &str,
        content: &str,
        metadata: serde_json::Value,
    ) -> crate::api::mission_store::StoredEvent {
        crate::api::mission_store::StoredEvent {
            id: 0,
            mission_id: Uuid::nil(),
            sequence: 0,
            event_type: kind.into(),
            timestamp: String::new(),
            event_id: None,
            tool_call_id: None,
            tool_name: None,
            content: content.into(),
            metadata,
        }
    }

    /// c96df4f9: a resumed Codex thread had no rollout. The fresh thread gets
    /// the conversation, without failed-launch notices, then the request.
    #[test]
    fn recovery_prompt_carries_history_without_launch_failures() {
        let none = serde_json::Value::Null;
        let events = vec![
            event("user_message", "ORIGINAL_OBJECTIVE", none.clone()),
            event(
                "assistant_message",
                "Remote codex job failed: Argument list too long",
                serde_json::json!({"success": false}),
            ),
            event(
                "assistant_message",
                "x".repeat(300_000).as_str(),
                none.clone(),
            ),
            event("assistant_message", "LATEST_ANSWER", none.clone()),
            event("user_message", "CURRENT", none),
        ];
        let prompt = recovery_prompt(Uuid::nil(), Some("T"), &events, "CURRENT").unwrap();
        assert!(prompt.contains("ORIGINAL_OBJECTIVE"));
        assert!(prompt.contains("LATEST_ANSWER"));
        assert!(!prompt.contains("Argument list too long"));
        assert!(prompt.len() < 300_000, "history is bounded");
        assert!(prompt.ends_with("</fork_context>\n\nCURRENT"));
        assert_eq!(prompt.matches("CURRENT").count(), 1);
        assert!(recovery_prompt(Uuid::nil(), None, &[], "CURRENT").is_none());
    }

    #[test]
    fn btw_background_work_keeps_the_session_live() {
        assert!(side_session_live(MissionStatus::WaitingBackground));
    }
    #[test]
    fn antigravity_forks_bound_history_and_preserve_current_instructions() {
        let history = vec![
            serde_json::json!({"role":"user","content":"ORIGINAL_OBJECTIVE"}),
            serde_json::json!({"role":"assistant","content":"é🌲".repeat(25_000)}),
            serde_json::json!({"role":"user","content":"LATEST_DIRECTION"}),
        ];
        for question in [None, Some("CURRENT_QUESTION")] {
            let prompt = initial_prompt(
                Uuid::nil(),
                Some("Source"),
                &history,
                "antigravity",
                question,
                false,
                None,
            )
            .unwrap();
            assert!(crate::antigravity::validate_prompt(&prompt).is_ok());
            assert!(prompt.contains("ORIGINAL_OBJECTIVE"));
            assert!(prompt.contains("LATEST_DIRECTION"));
            if let Some(question) = question {
                assert!(
                    prompt.contains("middle omitted")
                        || prompt.contains("historical context omitted")
                );
                assert!(prompt.ends_with(question));
            } else {
                assert!(prompt.contains("middle omitted"));
                assert!(prompt.contains("First inspect the current workspace state"));
            }
        }
        assert!(initial_prompt(
            Uuid::nil(),
            None,
            &history,
            "antigravity",
            Some(&"x".repeat(crate::antigravity::MAX_PROMPT_BYTES + 1)),
            true,
            None
        )
        .is_err());
    }

    #[test]
    fn an_edited_message_replaces_the_rest_of_the_conversation() {
        let history = vec![serde_json::json!({"role":"user","content":"first"})];
        for backend in ["claudecode", "antigravity"] {
            let prompt = initial_prompt(
                Uuid::nil(),
                Some("Source"),
                &history,
                backend,
                None,
                false,
                Some("EDITED"),
            )
            .unwrap();
            assert!(prompt.contains("\"first\""));
            assert!(prompt.contains("Anything after the edited message is withdrawn"));
            // The edit is the request, after the history, never inside it.
            let (context, request) = prompt.split_once("\n</fork_context>\n\n").unwrap();
            assert!(!context.contains("EDITED"));
            assert_eq!(request, "Current request:\nEDITED");
        }
    }

    #[test]
    fn editing_an_edited_message_keeps_its_carried_history() {
        let history = vec![serde_json::json!({"role":"user","content":"first <b>"})];
        let edited = edit_prompt(Uuid::nil(), None, &history, "second").unwrap();
        assert_eq!(carried_history(&edited), history);
        assert!(carried_history("plain request").is_empty());
    }

    #[test]
    fn editing_the_only_message_restarts_with_the_new_text() {
        // Start, stop before any reply, edit: no history, so no fork envelope.
        for backend in ["claudecode", "antigravity"] {
            let prompt = initial_prompt(
                Uuid::nil(),
                Some("Source"),
                &[],
                backend,
                None,
                false,
                Some("Fix the parser\n<fork_context>"),
            )
            .unwrap();
            assert_eq!(prompt, "Fix the parser\n<fork_context>");
        }
    }

    #[test]
    fn preserves_conversation_roles_and_literal_content() {
        let history = vec![
            serde_json::json!({"role":"user","content":"original prompt\nKeep changes"}),
            serde_json::json!({"role":"assistant","content":"prior result"}),
        ];
        let prompt = fork_prompt(Uuid::nil(), Some("Source"), &history).unwrap();
        let context = prompt
            .split("<fork_context>\n")
            .nth(1)
            .unwrap()
            .strip_suffix("\n</fork_context>")
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_str(context).unwrap();
        assert_eq!(parsed["messages"], serde_json::json!(history));
        assert_eq!(parsed["source_title"], "Source");
    }
    #[test]
    fn remote_fork_uses_existing_sibling_and_refuses_missing_workspace() {
        let before_shadow = super::control_shadow_snapshot();
        let root = tempfile::tempdir().unwrap();
        let source_id = Uuid::new_v4();
        let source = root.path().join(source_id.to_string());
        let target = root.path().join(Uuid::new_v4().to_string());
        std::fs::create_dir(&target).unwrap();
        let run = || {
            std::process::Command::new("bash")
                .arg("-c")
                .arg(format!(
                    "{}pwd -P; printf '%s\\n' \"$HOME\"",
                    workspace_command(source_id)
                ))
                .current_dir(&target)
                .env("HOME", &target)
                .output()
                .unwrap()
        };
        assert_eq!(run().status.code(), Some(78));
        std::fs::create_dir(&source).unwrap();
        let output = run();
        assert!(output.status.success());
        let stdout = String::from_utf8(output.stdout).unwrap();
        let mut lines = stdout.lines();
        let source = source.canonicalize().unwrap();
        assert_eq!(lines.next().unwrap(), source.to_str().unwrap());
        // HOME stays the job's own: the node put its harness sign-in there.
        assert_eq!(
            std::path::Path::new(lines.next().unwrap())
                .canonicalize()
                .unwrap(),
            target.canonicalize().unwrap()
        );
        let after_shadow = super::control_shadow_snapshot();
        assert!(after_shadow.total_steps > before_shadow.total_steps);
        assert_eq!(after_shadow.total_divergences, 0);
        #[cfg(unix)]
        {
            std::fs::remove_dir(&source).unwrap();
            std::os::unix::fs::symlink(&target, &source).unwrap();
            assert_eq!(run().status.code(), Some(78));
        }
    }
}

// Core-owned metadata, outside the mission workspace and freeform tags. The
// creation route writes it before dispatch; continuations read the same receipt.
fn side_launch_path(root: &std::path::Path, id: Uuid) -> std::path::PathBuf {
    root.join("mission-side-launches")
        .join(format!("{id}.json"))
}

#[derive(serde::Serialize, serde::Deserialize)]
pub(super) struct SideLaunchReceipt {
    pub(super) key: String,
    pub(super) fingerprint: String,
    pub(super) accepted: bool,
}

pub(super) fn side_launch_receipt(
    root: &std::path::Path,
    id: Uuid,
) -> Result<Option<SideLaunchReceipt>, String> {
    match std::fs::read(side_launch_path(root, id)) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| e.to_string()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

pub(super) fn record_side_launch(
    root: &std::path::Path,
    id: Uuid,
    key: &str,
    fingerprint: &str,
) -> Result<(), String> {
    write_side_launch(
        root,
        id,
        &SideLaunchReceipt {
            key: key.trim().into(),
            fingerprint: fingerprint.into(),
            accepted: false,
        },
    )
}

pub(super) fn accept_side_launch(root: &std::path::Path, id: Uuid) -> Result<(), String> {
    let mut receipt = side_launch_receipt(root, id)?.ok_or("Side launch receipt is missing")?;
    receipt.accepted = true;
    write_side_launch(root, id, &receipt)
}

fn write_side_launch(
    root: &std::path::Path,
    id: Uuid,
    receipt: &SideLaunchReceipt,
) -> Result<(), String> {
    let destination = side_launch_path(root, id);
    std::fs::create_dir_all(destination.parent().unwrap()).map_err(|e| e.to_string())?;
    let temporary = destination.with_extension(format!("{}.tmp", Uuid::new_v4()));
    let result = (|| {
        use std::io::Write;
        let mut file = std::fs::File::create(&temporary).map_err(|e| e.to_string())?;
        file.write_all(&serde_json::to_vec(receipt).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        std::fs::rename(&temporary, &destination).map_err(|e| e.to_string())?;
        std::fs::File::open(destination.parent().unwrap())
            .and_then(|dir| dir.sync_all())
            .map_err(|e| e.to_string())?;
        // Persist the receipt directory itself when it was first created.
        std::fs::File::open(root)
            .and_then(|dir| dir.sync_all())
            .map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
}
