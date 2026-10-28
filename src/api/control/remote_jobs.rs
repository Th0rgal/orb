//! Remote job submission, reconciliation, usage-limit replay and polling.

use super::*;

static SSH_IDENTITY_SHADOW_COUNTER: std::sync::OnceLock<crate::orb_spec::ShadowCounter> =
    std::sync::OnceLock::new();

pub fn ssh_identity_shadow_counter() -> &'static crate::orb_spec::ShadowCounter {
    SSH_IDENTITY_SHADOW_COUNTER.get_or_init(crate::orb_spec::ShadowCounter::new)
}

#[allow(clippy::too_many_arguments)]
pub fn evaluate_remote_ssh_and_codex_confinement(
    is_worker_or_container_target: bool,
    env: Option<&HashMap<String, String>>,
    working_directory: Option<&str>,
    pub_key: Option<&str>,
    proxy_jump_valid: bool,
    cyber_program: Option<&str>,
    codex_tokens_used: u64,
    codex_token_budget: Option<u64>,
) -> crate::orb_spec::SshIdentityVerdict {
    let bundle_has_control_plane_key = env.is_some_and(|m| {
        m.contains_key("PALOMA_SSH_PRIVATE_KEY")
            || m.contains_key("PALOMA_SSH_PUBLIC_KEY")
            || m.contains_key("ORB_HOST_KEYS_JSON")
    });
    let parent_dir_is_symlink = working_directory.is_some_and(|dir| {
        let p = std::path::Path::new(dir.trim());
        p.parent()
            .and_then(|parent| std::fs::symlink_metadata(parent).ok())
            .is_some_and(|meta| meta.file_type().is_symlink())
    });
    let pub_key_is_ed25519_without_private = match pub_key {
        Some(pk) => pk.starts_with("ssh-ed25519 ") && !pk.contains("PRIVATE KEY"),
        None => true,
    };
    let codex_cyber_program_valid = match cyber_program {
        Some(prog) => matches!(prog, "standard" | "daybreak_blue" | "daybreak_red"),
        None => true,
    };
    let codex_goal_budget_exhausted =
        codex_token_budget.is_some_and(|budget| budget > 0 && codex_tokens_used >= budget);
    let host_admits = !parent_dir_is_symlink
        && pub_key_is_ed25519_without_private
        && proxy_jump_valid
        && codex_cyber_program_valid
        && !codex_goal_budget_exhausted
        && !(is_worker_or_container_target && bundle_has_control_plane_key);
    crate::orb_spec::observe_ssh_identity_shadow(
        crate::orb_spec::SshIdentityStepInput {
            is_worker_or_container_target,
            bundle_has_control_plane_key,
            parent_dir_is_symlink,
            pub_key_is_ed25519_without_private,
            proxy_jump_valid,
            codex_cyber_program_valid,
            codex_goal_budget_exhausted,
        },
        host_admits,
        ssh_identity_shadow_counter(),
    )
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn evaluate_mission_control_gate(
    working_dir: &std::path::Path,
    mission_store: &dyn MissionStore,
    mission: &Mission,
    expected_lease_owner: &str,
    resume_session_id: Option<&str>,
    events: &[crate::api::mission_store::StoredEvent],
    fallback_prompt: Option<&str>,
    host_admits: bool,
) -> Result<crate::orb_spec::MissionControlStepVerdict, String> {
    let stored_mission = mission_store.get_mission(mission.id).await?;
    let effective_status = stored_mission
        .as_ref()
        .map(|m| m.status)
        .unwrap_or(mission.status);
    // An explicit dispatch (follow-up, resume, transfer) may continue a
    // Completed mission: only Acknowledged (archived) or superseded ones are
    // closed. The automatic usage-limit replay also treats Completed as done.
    let is_archived = mission.status == MissionStatus::Acknowledged
        || effective_status == MissionStatus::Acknowledged
        || crate::api::mission_horizon::superseded_by(mission).is_some()
        || mission
            .project
            .tags
            .iter()
            .any(|t| t == crate::api::mission_store::SUPERSEDED_TAG);
    let active_run = mission_store.get_active_mission_run(mission.id).await?;
    let has_lease = active_run
        .as_ref()
        .is_some_and(|run| run.owner_actor_id == expected_lease_owner);
    let active_track_writers = match &active_run {
        Some(run)
            if !run.owner_actor_id.is_empty() && run.owner_actor_id != expected_lease_owner =>
        {
            1
        }
        _ => 0,
    };
    let msg_already_delivered = resume_session_id.is_none()
        && fork::side_launch_receipt(working_dir, mission.id)
            .ok()
            .flatten()
            .is_some_and(|receipt| receipt.accepted);
    let is_resume = resume_session_id.is_some();
    let stored_sid = stored_mission
        .as_ref()
        .and_then(|m| m.session_id.as_deref())
        .or(mission.session_id.as_deref());
    let session_created = stored_sid.is_some_and(|sid| !sid.trim().is_empty());
    let lineage_verified = match (resume_session_id, stored_sid) {
        (Some(req_sid), Some(sid)) => {
            req_sid == sid || (mission.backend == "opencode" && req_sid.starts_with("ses_"))
        }
        (None, _) => session_created,
        (Some(_), None) => false,
    };
    let rollout_exists = events.iter().any(|event| {
        event.event_type == "assistant_message"
            && !event.content.trim().is_empty()
            && event.metadata["success"] != serde_json::json!(false)
    });
    let has_fallback_prompt =
        (!is_resume || lineage_verified) && fallback_prompt.is_some_and(|p| !p.trim().is_empty());
    Ok(fork::observe_mission_control_shadow(
        crate::orb_spec::MissionControlStepInput {
            is_archived,
            active_track_writers,
            has_lease,
            msg_already_delivered,
            is_resume,
            session_created,
            lineage_verified,
            rollout_exists,
            has_fallback_prompt,
        },
        host_admits,
    ))
}

pub(super) async fn evaluate_usage_limit_replay_gate(
    working_dir: &std::path::Path,
    mission_store: &dyn MissionStore,
    mission: &Mission,
    wait_limit: &str,
    replay_prompt: Option<&str>,
) -> Result<crate::orb_spec::MissionControlStepVerdict, String> {
    // Nothing replays a finished mission on its own: Completed counts as
    // archived here, unlike an explicit follow-up.
    let is_archived = matches!(
        mission.status,
        MissionStatus::Acknowledged | MissionStatus::Completed
    ) || crate::api::mission_horizon::superseded_by(mission).is_some()
        || mission
            .project
            .tags
            .iter()
            .any(|t| t == crate::api::mission_store::SUPERSEDED_TAG);
    let active_run = mission_store.get_active_mission_run(mission.id).await?;
    let has_lease = active_run.is_none();
    let active_track_writers = if active_run.is_some() { 1 } else { 0 };
    let msg_already_delivered = mission.session_id.is_none()
        && fork::side_launch_receipt(working_dir, mission.id)
            .ok()
            .flatten()
            .is_some_and(|receipt| receipt.accepted);
    let session_created = mission
        .session_id
        .as_deref()
        .is_some_and(|sid| !sid.trim().is_empty());
    let lineage_verified = session_created;
    let events = mission_store
        .get_events(
            mission.id,
            Some(&["user_message", "assistant_message"]),
            None,
            None,
        )
        .await?;
    let rollout_exists = wait_limit != usage_limit_wait::FRESH_SESSION_FALLBACK
        && events.iter().any(|event| {
            event.event_type == "assistant_message"
                && !event.content.trim().is_empty()
                && event.metadata["success"] != serde_json::json!(false)
        });
    let has_fallback_prompt = replay_prompt.is_some_and(|p| !p.trim().is_empty());
    let host_admits = !is_archived
        && has_lease
        && active_track_writers == 0
        && !msg_already_delivered
        && ((session_created && lineage_verified && rollout_exists) || has_fallback_prompt);
    Ok(fork::observe_mission_control_shadow(
        crate::orb_spec::MissionControlStepInput {
            is_archived,
            active_track_writers,
            has_lease,
            msg_already_delivered,
            is_resume: true,
            session_created,
            lineage_verified,
            rollout_exists,
            has_fallback_prompt,
        },
        host_admits,
    ))
}

pub(super) async fn submit_leased_remote_job(
    state: &Arc<AppState>,
    control: &ControlState,
    mission: &Mission,
    node: crate::remote_node::RemoteNodeConfig,
    job_id: Uuid,
    plan: &RemoteHarnessPlan,
) -> Result<Mission, String> {
    validate_remote_vibe_auth(&state.config.working_dir, plan).await?;
    let mut resolved_plan = plan.clone();
    if let RemoteHarnessPlan::Codex {
        service_tier,
        model,
        ..
    } = &mut resolved_plan
    {
        *service_tier = mission.service_tier;
        speed::validate(
            &state.config.working_dir,
            "codex",
            Some(model),
            crate::codex_speed::Tier::from_legacy(mission.service_tier, mission.fast_mode),
            None,
        )
        .await?;
    }

    if let RemoteHarnessPlan::Vibe { plan, prompt, .. } = &mut resolved_plan {
        *plan = *plan || crate::vibe::plan_mode(mission.agent.as_deref(), prompt);
    }
    let cyber_selection = if let RemoteHarnessPlan::Codex { model, .. } = plan {
        cyber::promote_remote(state, mission.id, Some(model)).await?
    } else {
        cyber::Selection::default()
    };
    let mut project_skill_source = String::new();
    let prompt = match &mut resolved_plan {
        RemoteHarnessPlan::Codex { prompt, .. }
        | RemoteHarnessPlan::Grok { prompt, .. }
        | RemoteHarnessPlan::ClaudeCode { prompt, .. }
        | RemoteHarnessPlan::Antigravity { prompt, .. }
        | RemoteHarnessPlan::Vibe { prompt, .. }
        | RemoteHarnessPlan::OpenCode { prompt, .. } => Some(prompt),
        RemoteHarnessPlan::Raw { .. } => None,
    };
    if let Some(prompt) = prompt {
        *prompt = super::super::mission_payload::prepare_remote_turn(
            &state.config.working_dir,
            mission.id,
            prompt,
        )?;
        if let Some(project) = mission.project.project.as_deref() {
            let (resolved, source) =
                super::super::context_execution::remote(state, project, &node, prompt).await?;
            *prompt = resolved;
            project_skill_source = source;
        } else if super::super::context_execution::has_mentions(prompt) {
            return Err("Context references require a project".into());
        }
        *prompt = crate::util::with_task_list_guidance(prompt);
    }

    if let RemoteHarnessPlan::Codex {
        prompt,
        resume_session_id: Some(_),
        fallback_prompt,
        ..
    } = &mut resolved_plan
    {
        // A saved thread may have no rollout on the node: its first launch
        // died before Codex started, or its Codex home was lost. The driver
        // then continues on a fresh thread seeded with this history.
        let events = control
            .mission_store
            .get_events(
                mission.id,
                Some(&["user_message", "assistant_message"]),
                None,
                None,
            )
            .await?;
        *fallback_prompt =
            fork::recovery_prompt(mission.id, mission.title.as_deref(), &events, prompt)
                .or_else(|| Some(prompt.clone()));
    }
    let (resume_sid_opt, fallback_prompt_opt) = match &resolved_plan {
        RemoteHarnessPlan::Codex {
            resume_session_id,
            fallback_prompt,
            ..
        } => (resume_session_id.as_deref(), fallback_prompt.as_deref()),
        RemoteHarnessPlan::ClaudeCode {
            resume_session_id,
            prompt,
            ..
        }
        | RemoteHarnessPlan::OpenCode {
            resume_session_id,
            prompt,
            ..
        }
        | RemoteHarnessPlan::Grok {
            resume_session_id,
            prompt,
            ..
        }
        | RemoteHarnessPlan::Antigravity {
            resume_session_id,
            prompt,
            ..
        }
        | RemoteHarnessPlan::Vibe {
            resume_session_id,
            prompt,
            ..
        } => (resume_session_id.as_deref(), Some(prompt.as_str())),
        RemoteHarnessPlan::Raw { .. } => (None, None),
    };
    let resume_events = if resume_sid_opt.is_some() {
        control
            .mission_store
            .get_events(
                mission.id,
                Some(&["user_message", "assistant_message"]),
                None,
                None,
            )
            .await?
    } else {
        Vec::new()
    };
    let expected_owner = remote_job_lease_owner(job_id);
    let active_run = control
        .mission_store
        .get_active_mission_run(mission.id)
        .await?;
    let stored_mission = control.mission_store.get_mission(mission.id).await?;
    let effective_status = stored_mission
        .as_ref()
        .map(|m| m.status)
        .unwrap_or(mission.status);
    let stored_sid = stored_mission
        .as_ref()
        .and_then(|m| m.session_id.as_deref())
        .or(mission.session_id.as_deref());
    let host_admits_submission = mission.status != MissionStatus::Acknowledged
        && effective_status != MissionStatus::Acknowledged
        && crate::api::mission_horizon::superseded_by(mission).is_none()
        && !mission
            .project
            .tags
            .iter()
            .any(|t| t == crate::api::mission_store::SUPERSEDED_TAG)
        && active_run
            .as_ref()
            .is_some_and(|run| run.owner_actor_id == expected_owner)
        && !(resume_sid_opt.is_none()
            && fork::side_launch_receipt(&state.config.working_dir, mission.id)
                .ok()
                .flatten()
                .is_some_and(|r| r.accepted))
        && match resume_sid_opt {
            Some(req_sid) => {
                let lineage_ok = stored_sid.is_some_and(|sid| {
                    req_sid == sid || (mission.backend == "opencode" && req_sid.starts_with("ses_"))
                });
                let rollout_ok = resume_events.iter().any(|event| {
                    event.event_type == "assistant_message"
                        && !event.content.trim().is_empty()
                        && event.metadata["success"] != serde_json::json!(false)
                });
                lineage_ok
                    && (rollout_ok || fallback_prompt_opt.is_some_and(|p| !p.trim().is_empty()))
            }
            None => true,
        };
    let submission_verdict = evaluate_mission_control_gate(
        &state.config.working_dir,
        control.mission_store.as_ref(),
        mission,
        &expected_owner,
        resume_sid_opt,
        &resume_events,
        fallback_prompt_opt,
        host_admits_submission,
    )
    .await?;
    if !submission_verdict.emit_dispatch_effect || submission_verdict.archived_next {
        return Err(format!(
            "Remote job submission rejected by mission control kernel gate ({:?})",
            submission_verdict.action
        ));
    }
    let plan = &resolved_plan;
    let mut workspace_prefix =
        if let Some(t) = machine_transfer::committed(&control.mission_store, mission.id).await? {
            let root = t.destination_root.ok_or("Transferred workspace missing")?;
            format!("cd -- {} || exit 78; ", shell_single_quote(&root))
        } else if let Some(directory) = mission.working_directory.as_deref() {
            if !std::path::Path::new(directory).is_absolute() {
                return Err("Remote working_directory must be absolute".into());
            }
            format!("cd -- {} || exit 78; ", shell_single_quote(directory))
        } else {
            fork::workspace_prefix(
                &control.mission_store,
                mission,
                &node.id,
                &state.config.working_dir,
            )
            .await?
        };
    // Run in the final execution cwd, before any harness command. A failed
    // preparation exits the job clearly rather than starting without skills.
    if !matches!(plan, RemoteHarnessPlan::Raw { .. }) {
        let library_archive = remote_library_skills(state, mission, &node).await;
        workspace_prefix.push_str(&remote_skill_prefix(
            &project_skill_source,
            &mission.backend,
            library_archive.as_ref(),
        ));
    }
    let context_prompt = match plan {
        RemoteHarnessPlan::Codex { prompt, .. }
        | RemoteHarnessPlan::Grok { prompt, .. }
        | RemoteHarnessPlan::ClaudeCode { prompt, .. }
        | RemoteHarnessPlan::Antigravity { prompt, .. }
        | RemoteHarnessPlan::Vibe { prompt, .. }
        | RemoteHarnessPlan::OpenCode { prompt, .. } => prompt.as_str(),
        _ => "",
    };
    let context_prefix = btw_context::remote_prefix(mission, context_prompt);
    if !context_prefix.is_empty() {
        workspace_prefix = format!(
            r#"btw_upload_root="$(dirname -- "$PWD")/uploads"; {workspace_prefix}{context_prefix}"#
        );
    }
    let claude_session = if let RemoteHarnessPlan::ClaudeCode {
        resume_session_id: None,
        ..
    } = plan
    {
        let session_id = Uuid::new_v4().to_string();
        let run = control
            .mission_store
            .get_active_mission_run(mission.id)
            .await?
            .filter(|run| run.owner_actor_id == remote_job_lease_owner(job_id))
            .ok_or("native Claude session allocation lost its run lease")?;
        let fence = crate::api::mission_store::SessionUpdateRun::from(&run);
        // Missions are created with a placeholder identity. A launch that fails
        // before submission must not leave it behind for `--resume`.
        if let Some(placeholder) = mission.session_id.as_deref() {
            control
                .mission_store
                .clear_unsubmitted_session_id(mission.id, placeholder, "claudecode", &fence)
                .await?;
        }
        Some((session_id, fence))
    } else {
        None
    };
    if let RemoteHarnessPlan::Grok {
        new_session_id: Some(session_id),
        resume_session_id: None,
        ..
    } = plan
    {
        let run = control
            .mission_store
            .get_active_mission_run(mission.id)
            .await?
            .filter(|run| run.owner_actor_id == remote_job_lease_owner(job_id))
            .ok_or("native Grok session allocation lost its run lease")?;
        let fence = crate::api::mission_store::SessionUpdateRun::from(&run);
        if !control
            .mission_store
            .update_mission_session_id(mission.id, session_id, "grok", Some(&fence))
            .await?
        {
            return Err("native Grok session allocation rejected by run generation fence".into());
        }
    }
    let cyber_program = match plan {
        RemoteHarnessPlan::Codex { model, .. } => cyber_selection.mode.program(model)?,
        _ => None,
    };
    let shared_token = crate::remote_node::node_token(&node.token_env)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| {
            format!(
                "remote node '{}' has no token in {}",
                node.id, node.token_env
            )
        })?;
    let long_running = !matches!(plan, RemoteHarnessPlan::Raw { .. });
    if long_running {
        let heartbeat = match state
            .fleet
            .get(&node.id)
            .and_then(|cached| cached.last_heartbeat)
        {
            Some(heartbeat) => heartbeat,
            None => crate::remote_node::RemoteNodeClient::default()
                .heartbeat(&node, &shared_token)
                .await
                .map_err(|error| format!("Cannot verify native goal lifetime support: {error}"))?,
        };
        if heartbeat.protocol_version < 5 {
            return Err(format!("Node '{}' requires protocol 5 for native goals; upgrade sandboxed-node before resuming", node.id));
        }
    }
    let claims = crate::remote_node::LeaseClaims {
        mission_id: mission.id,
        node_id: node.id.clone(),
        scope: crate::remote_node::SCOPE_JOB_SUBMIT.to_string(),
        expires_at: (chrono::Utc::now() + chrono::Duration::minutes(15)).timestamp(),
        job_id: Some(job_id),
    };
    let lease_token = crate::remote_node::create_lease_token(&claims, &shared_token)
        .map_err(|e| e.to_string())?;
    // A harness launch talks back to this core through the model proxy with
    // a key minted for this mission only; the key travels in the job env,
    // never in the logged command line. Raw commands carry their own auth.
    // Minted last, after every other fallible pre-submit step, so each path
    // below that can fail after this point retires it explicitly.
    let mcp_session = if matches!(plan, RemoteHarnessPlan::Raw { .. }) {
        None
    } else {
        let owner = state
            .control
            .identity_for_store(&control.mission_store)
            .await
            .ok_or("Remote mission owner identity is unavailable")?;
        let url = super::super::mission_runner::public_api_base_url_from_env()
            .ok_or("Remote MCP requires SANDBOXED_PUBLIC_URL")?;
        let grant = crate::control_mcp::gateway::session(
            State(state.clone()),
            Extension(owner),
            Json(crate::control_mcp::gateway::SessionRequest {
                project: None,
                role: crate::control_mcp::Role::Executor,
                mission_id: Some(mission.id),
            }),
        )
        .await
        .map_err(|(_, message)| message)?
        .0;
        Some((
            url,
            grant["token"]
                .as_str()
                .ok_or("Missing scoped MCP credential")?
                .to_string(),
        ))
    };
    if let RemoteHarnessPlan::Antigravity { prompt, .. } = plan {
        crate::antigravity::validate_prompt(prompt)?;
    }
    let (mut execution, proxy_key_id) = if plan.uses_core_proxy() {
        let api_base_url = super::super::mission_runner::public_api_base_url_from_env()
            .ok_or_else(|| {
                "SANDBOXED_PUBLIC_URL is not configured; a remote harness launch needs a core URL the node can reach".to_string()
            })?;
        let key = state
            .proxy_api_keys
            .create(remote_launch_key_name(mission.id))
            .await
            .map_err(|error| format!("remote launch proxy key could not be minted: {error}"))?;
        if let RemoteHarnessPlan::Codex { model, .. } = plan {
            if let Err(error) = cyber::bind_proxy(
                &state.config.working_dir,
                mission.id,
                cyber_selection.revision,
                key.id,
                model,
            ) {
                let _ = state.proxy_api_keys.delete(key.id).await;
                return Err(error);
            }
        }
        (
            remote_execution_for_plan(plan, &api_base_url, &key.key),
            Some(key.id),
        )
    } else {
        (remote_execution_for_plan(plan, "", ""), None)
    };
    if let Some(program) = cyber_program {
        execution
            .env
            .get_or_insert_with(HashMap::new)
            .insert("SANDBOXED_CYBER_PROGRAM".into(), program.into());
    }
    let ssh_codex_verdict = evaluate_remote_ssh_and_codex_confinement(
        node.id != "agent-core",
        execution.env.as_ref(),
        mission.working_directory.as_deref(),
        None,
        true,
        execution
            .env
            .as_ref()
            .and_then(|e| e.get("SANDBOXED_CYBER_PROGRAM"))
            .map(String::as_str),
        0,
        None,
    );
    if !ssh_codex_verdict.admit || !ssh_codex_verdict.no_secret_leak {
        if let Some(id) = proxy_key_id {
            let _ = state.proxy_api_keys.delete(id).await;
        }
        return Err(format!(
            "Remote job rejected by orb_ssh_identity_step confinement gate ({:?}, exit={})",
            ssh_codex_verdict.action, ssh_codex_verdict.exit_code_on_reject
        ));
    }

    if let Some((session_id, _)) = &claude_session {
        bind_remote_claude_session(&mut execution, session_id);
    }
    if let Some((url, token)) = mcp_session {
        let harness = match plan {
            RemoteHarnessPlan::Codex { .. } => "codex",
            RemoteHarnessPlan::ClaudeCode { .. } => "claudecode",
            RemoteHarnessPlan::OpenCode { .. } => "opencode",
            RemoteHarnessPlan::Grok { .. } => "grok",
            RemoteHarnessPlan::Antigravity { .. } => "antigravity",
            RemoteHarnessPlan::Vibe { .. } => "vibe",
            RemoteHarnessPlan::Raw { .. } => unreachable!(),
        };
        let env = execution.env.get_or_insert_with(HashMap::new);
        env.insert("SANDBOXED_MCP_API_URL".into(), url);
        env.insert("SANDBOXED_MCP_TOKEN".into(), token);
        env.insert("SANDBOXED_SH_MISSION_ID".into(), mission.id.to_string());
        if harness == "vibe" {
            if let Some(transfer) =
                machine_transfer::committed(&control.mission_store, mission.id).await?
            {
                env.insert("SANDBOXED_VIBE_TRANSFER_ID".into(), transfer.id.to_string());
            }
        }
        env.insert(
            "SANDBOXED_MCP_WRAPPER".into(),
            "/usr/local/bin/sandboxed-mcp".into(),
        );
        // Codex's embedded app-server driver applies the wrapper to codex,
        // not to the Python driver. Other plans execute their CLI directly.
        execution.command = match harness {
            "claudecode" => execution.command.replacen(
                "claude -p ",
                "/usr/local/bin/sandboxed-mcp launch --harness claudecode -- claude -p ",
                1,
            ),
            "opencode" => execution.command.replacen(
                "opencode run ",
                "/usr/local/bin/sandboxed-mcp launch --harness opencode -- opencode run ",
                1,
            ),
            "antigravity" => execution.command.replacen(
                "exec agy ",
                "exec /usr/local/bin/sandboxed-mcp launch --harness antigravity -- agy ",
                1,
            ),
            "grok" => execution.command.replacen(
                "exec grok ",
                "exec /usr/local/bin/sandboxed-mcp launch --harness grok -- grok ",
                1,
            ),
            _ => execution.command,
        };
    }
    let side_question = fork::side_launch_receipt(&state.config.working_dir, mission.id)?.is_some();
    let request = crate::remote_node::SubmitJobRequest {
        job_id,
        mission_id: mission.id,
        lease_token,
        payload: crate::remote_node::JobPayload::RawCommand {
            side_question,
            // An ordinary turn may run beside its own workspace's background
            // jobs instead of queueing behind them on a full node.
            companion_of: (!side_question).then(|| {
                crate::api::durable_jobs::workspace_mission_id(&mission.project.tags, mission.id)
            }),
            long_running,
            command: format!("{workspace_prefix}{}", execution.command),
            timeout_secs: None,
            env: execution.env.clone(),
            managed_auth: execution.managed_auth.clone(),
        },
    };
    let proxy_keys = Arc::clone(&state.proxy_api_keys);
    // Key retirement: on every early failure below and when this process's
    // observer finishes. A re-attached observer after restart retires by
    // name (`retire_remote_launch_keys`), and the reconciler's first pass
    // sweeps keys whose mission holds no ledger handle, so nothing relies on
    // the periodic `cleanup_keys`.
    let retire_proxy_key = {
        let proxy_keys = Arc::clone(&proxy_keys);
        let mission_id = mission.id;
        move || async move {
            if proxy_key_id.is_some() {
                retire_remote_launch_keys(&proxy_keys, mission_id).await;
            }
        }
    };

    let client = crate::remote_node::RemoteNodeClient::default();
    let submit_started_at = chrono::Utc::now();
    let ledger_dir = state.config.working_dir.clone();
    // Record the generated id before the POST. If the process dies after the
    // node accepts but before the HTTP result is observed, restart recovery
    // still has enough information to cancel the maybe-accepted job.
    let tentative_recorded = crate::remote_node::job_ledger::record(
        &ledger_dir,
        crate::remote_node::job_ledger::JobHandle {
            mission_id: mission.id,
            node_id: node.id.clone(),
            job_id,
            started_at: submit_started_at,
            submission_sequence: 0,
            accepted_at: None,
            heartbeat_at: None,
            disk_reservation_bytes: 0,
            kind: crate::remote_node::job_ledger::JobHandleKind::Tentative,
            identity: None,
            wait_for_completion: None,
            wake_on_terminal: false,
        },
    )
    .await;
    if let Err(error) = tentative_recorded {
        retire_proxy_key().await;
        return Err(format!(
            "remote job recovery handle could not be prepared: {error}"
        ));
    }
    // All preflight work and the recovery journal succeeded. Publish the native
    // identity immediately before submission; definitive rejection rolls it back.
    // An ambiguous response retains it because Claude may already have started.
    if let Some((session_id, fence)) = &claude_session {
        let persisted = control
            .mission_store
            .update_mission_session_id(mission.id, session_id, "claudecode", Some(fence))
            .await;
        if !matches!(persisted, Ok(true)) {
            crate::remote_node::job_ledger::remove(&ledger_dir, job_id).await;
            retire_proxy_key().await;
            return Err(persisted.err().unwrap_or_else(|| {
                "native Claude session allocation rejected by run generation fence".into()
            }));
        }
        remote_grok::note_allocated_claude_session(job_id);
    }
    let antigravity_claim = if matches!(
        plan,
        RemoteHarnessPlan::Antigravity {
            resume_session_id: None,
            ..
        } | RemoteHarnessPlan::Vibe {
            resume_session_id: None,
            ..
        }
    ) {
        let claim = async {
            let run = control.mission_store.get_active_mission_run(mission.id).await?
                .filter(|run| run.owner_actor_id == remote_job_lease_owner(job_id))
                .ok_or("Antigravity launch lost its run lease")?;
            let fence = crate::api::mission_store::SessionUpdateRun::from(&run);
            if !control.mission_store.claim_native_prompt(mission.id, &mission.backend, None, Some(&fence), job_id).await? {
                return Err("Prior Antigravity launch has no recorded conversation identity; reconcile it before retrying".to_string());
            }
            Ok::<_, String>(fence)
        }.await;
        match claim {
            Ok(fence) => Some(fence),
            Err(error) => {
                crate::remote_node::job_ledger::remove(&ledger_dir, job_id).await;
                retire_proxy_key().await;
                return Err(error);
            }
        }
    } else {
        None
    };
    let accepted = match client.submit_job(&node, &shared_token, &request).await {
        Ok(accepted) => accepted,
        Err(crate::remote_node::RemoteNodeError::Request(message)) => {
            // A transport/response failure is ambiguous: the node may have
            // durably queued this exact job id before the response was lost.
            // Keep the cancellation-only handle while returning failure so
            // restart recovery cannot orphan the possible remote process.
            spawn_untracked_remote_job_cancellation(
                Arc::clone(&state.fleet),
                node,
                shared_token,
                mission.id,
                job_id,
                submit_started_at,
                ledger_dir,
            );
            retire_proxy_key().await;
            return Err(format!(
                "remote job submit outcome is ambiguous; cancellation is being reconciled: {message}"
            ));
        }
        Err(error) => {
            // A node HTTP rejection is definitive: the handler did not queue
            // the job, so this pre-submit handle can be discarded.
            if let Some(fence) = &antigravity_claim {
                if let Err(error) = control
                    .mission_store
                    .release_native_prompt_no_launch(
                        mission.id,
                        &mission.backend,
                        Some(fence),
                        job_id,
                    )
                    .await
                {
                    tracing::error!(mission_id = %mission.id, %error, "Could not release rejected Antigravity launch claim");
                }
            }
            if let Some((session_id, fence)) = &claude_session {
                if let Err(rollback) = control
                    .mission_store
                    .clear_unsubmitted_session_id(mission.id, session_id, "claudecode", fence)
                    .await
                {
                    tracing::error!(mission_id = %mission.id, %rollback, "could not clear rejected Claude session identity");
                }
            }
            crate::remote_node::job_ledger::remove(&ledger_dir, job_id).await;
            retire_proxy_key().await;
            return Err(error.to_string());
        }
    };

    // Persist the job handle BEFORE marking the mission Active: if the API
    // restarts from here on, the startup reconciler can re-attach a poll
    // loop instead of leaving an Active mission orphaned.
    if let Err(err) = crate::remote_node::job_ledger::record(
        &state.config.working_dir,
        crate::remote_node::job_ledger::JobHandle {
            mission_id: mission.id,
            node_id: node.id.clone(),
            job_id,
            started_at: submit_started_at,
            submission_sequence: 0,
            accepted_at: Some(chrono::Utc::now()),
            heartbeat_at: Some(chrono::Utc::now()),
            disk_reservation_bytes: 0,
            kind: crate::remote_node::job_ledger::JobHandleKind::Mission,
            identity: None,
            wait_for_completion: None,
            wake_on_terminal: false,
        },
    )
    .await
    {
        // Never expose an Active mission without a durable accepted handle.
        // The pre-submit tentative entry remains the restart fallback; also
        // start cancellation immediately rather than letting the job run.
        spawn_untracked_remote_job_cancellation(
            Arc::clone(&state.fleet),
            node,
            shared_token,
            mission.id,
            job_id,
            submit_started_at,
            state.config.working_dir.clone(),
        );
        retire_proxy_key().await;
        return Err(format!(
            "remote job accepted but recovery handle could not be persisted: {err}"
        ));
    }

    // Durable execution truth BEFORE the presentation status flips to Active.
    // A raw remote mission has no local runner, so this lease (refreshed by
    // the poll loop) and the ledger handle above are what the stuck-mission
    // watchdog and startup recovery consult instead of the runner list. The
    // ledger handle alone already fences liveness, so a lease failure is
    // logged rather than treated as a dispatch failure.
    let lease = match ensure_remote_job_lease(
        control.mission_store.as_ref(),
        mission.id,
        job_id,
        &node.id,
    )
    .await
    {
        Ok(lease) => lease,
        Err(error) => {
            tracing::warn!(
                mission_id = %mission.id,
                job_id = %job_id,
                %error,
                "remote job run lease could not be acquired; the ledger handle remains the liveness proof"
            );
            None
        }
    };

    if let Err(err) = control
        .mission_store
        .update_mission_status(mission.id, MissionStatus::Active)
        .await
    {
        // The node already accepted the job and its handle is durable. Ask
        // for cancellation immediately, then keep polling until terminal so
        // a failed mission activation cannot leak node capacity.
        if let Err(cancel_err) = client.cancel_job(&node, &shared_token, job_id).await {
            tracing::warn!(
                mission_id = %mission.id,
                job_id = %job_id,
                ?cancel_err,
                "remote job cancellation after activation failure will be retried by poller"
            );
        }
        let poll_owner = RemoteMissionOwner::live(control);
        let fleet = Arc::clone(&state.fleet);
        let ledger_dir = state.config.working_dir.clone();
        let mission_id = mission.id;
        let started_at = chrono::Utc::now();
        tokio::spawn(async move {
            poll_remote_job(
                &ledger_dir,
                poll_owner,
                fleet,
                client,
                node,
                shared_token,
                mission_id,
                job_id,
                started_at,
            )
            .await;
            retire_proxy_key().await;
        });
        return Err(err);
    }
    let _ = control.events_tx.send(AgentEvent::MissionStatusChanged {
        completion: None,
        execution: lease,
        mission_id: mission.id,
        status: MissionStatus::Active,
        summary: Some(format!(
            "Dispatched job {} to remote node '{}' ({}; node state: {})",
            job_id, node.id, execution.label, accepted.state
        )),
    });

    let started_at = chrono::Utc::now();
    state
        .fleet
        .record_outcome(crate::remote_node::DispatchOutcome {
            mission_id: mission.id,
            node_id: node.id.clone(),
            job_id: Some(job_id),
            state: accepted.state.clone(),
            exit_code: None,
            error: None,
            started_at,
            finished_at: None,
        });

    let poll_owner = RemoteMissionOwner::live(control);
    let fleet = Arc::clone(&state.fleet);
    let mission_id = mission.id;
    let ledger_dir = state.config.working_dir.clone();
    let updated = read_dispatched_mission_after_observer_start(
        &control.mission_store,
        mission.id,
        move || {
            tokio::spawn(async move {
                poll_remote_job(
                    &ledger_dir,
                    poll_owner,
                    fleet,
                    client,
                    node,
                    shared_token,
                    mission_id,
                    job_id,
                    started_at,
                )
                .await;
                retire_proxy_key().await;
            });
        },
    )
    .await?;

    Ok(updated)
}

/// Start ownership of an accepted remote job before any fallible final read.
/// The observer must survive both a store error and a row that disappeared
/// after dispatch, otherwise the durable node job remains unpolled until the
/// API process restarts.
pub(super) async fn read_dispatched_mission_after_observer_start(
    mission_store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    start_observer: impl FnOnce(),
) -> Result<Mission, String> {
    start_observer();
    mission_store
        .get_mission(mission_id)
        .await?
        .ok_or_else(|| format!("Mission {mission_id} disappeared after remote dispatch"))
}

/// Retry cancellation without treating a missing job record or node restart
/// as terminal proof. An accepted request may outlive the observer or the
/// node's current job database; retain its fence until execution is confirmed
/// terminal and durable cleanup succeeds.
pub(super) fn spawn_untracked_remote_job_cancellation(
    fleet: Arc<crate::remote_node::FleetMonitor>,
    node: crate::remote_node::RemoteNodeConfig,
    shared_token: String,
    mission_id: Uuid,
    job_id: Uuid,
    started_at: chrono::DateTime<chrono::Utc>,
    ledger_dir: std::path::PathBuf,
) {
    tokio::spawn(observe_untracked_remote_job_cancellation(
        fleet,
        node,
        shared_token,
        mission_id,
        job_id,
        started_at,
        ledger_dir,
    ));
}

pub(super) async fn observe_untracked_remote_job_cancellation(
    fleet: Arc<crate::remote_node::FleetMonitor>,
    node: crate::remote_node::RemoteNodeConfig,
    shared_token: String,
    mission_id: Uuid,
    job_id: Uuid,
    started_at: chrono::DateTime<chrono::Utc>,
    ledger_dir: std::path::PathBuf,
) {
    let client = crate::remote_node::RemoteNodeClient::default();
    let mut terminal: Option<crate::remote_node::NodeJobStatus> = None;
    let mut consecutive_missing: u8 = 0;
    loop {
        if terminal.is_none() {
            if let Err(error) = client
                .cancel_job_with_reason(
                    &node,
                    &shared_token,
                    job_id,
                    "core",
                    "Mission left Active; preserve its requested stop",
                )
                .await
            {
                tracing::warn!(%mission_id, %job_id, node_id = %node.id, ?error,
                    "untracked remote job cancellation failed; retaining fence and retrying");
            }
            match client.get_job(&node, &shared_token, job_id).await {
                Ok(status) if crate::remote_node::job_state_confirms_termination(&status.state) => {
                    consecutive_missing = 0;
                    terminal = Some(status);
                }
                Err(error) if error.is_not_found() => {
                    consecutive_missing = consecutive_missing.saturating_add(1);
                    if consecutive_missing >= 10 {
                        terminal = Some(crate::remote_node::missing_job_cancelled(
                            mission_id, job_id,
                        ));
                    }
                }
                Ok(_) => consecutive_missing = 0,
                Err(_) => {}
            }
        }
        if let Some(status) = &terminal {
            match crate::remote_node::job_ledger::finalize_with_artifacts(
                &ledger_dir,
                job_id,
                &status.state,
                status.exit_code,
                status.artifacts.clone(),
            )
            .await
            {
                Ok(_) => {
                    fleet.record_outcome(crate::remote_node::DispatchOutcome {
                        mission_id,
                        node_id: node.id,
                        job_id: Some(job_id),
                        state: status.state.clone(),
                        exit_code: status.exit_code,
                        error: status.error.clone(),
                        started_at,
                        finished_at: Some(chrono::Utc::now()),
                    });
                    return;
                }
                Err(error) => {
                    tracing::warn!(%job_id, ?error, "remote cancellation cleanup failed; retaining terminal proof and retrying")
                }
            }
        }
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    }
}

/// Reattach observation/cancellation for persisted remote jobs after restart.
/// Missing owners, configuration, credentials and stale observations are not
/// terminal evidence: retain the durable ownership fence and retry recovery.
pub fn spawn_remote_job_reconciler(state: Arc<AppState>) {
    // Captured synchronously, before any request can be served: only proxy
    // keys minted before this instant are boot leftovers. A launch minting
    // its key between the ledger snapshot and the key listing below is a
    // live launch of THIS process and must keep its key.
    let boot_cutoff = chrono::Utc::now();
    tokio::spawn(async move {
        // Let control sessions boot before touching their stores.
        tokio::time::sleep(std::time::Duration::from_secs(10)).await;
        let working_dir = state.config.working_dir.clone();
        // The leaked-key sweep runs once, after the first SUCCESSFUL ledger
        // read (an unreadable first pass must not skip it forever).
        let mut sweep_done = false;
        // Job ids a poll loop was already re-attached for (or that were
        // finalized), so retry passes never double-attach.
        let mut settled: std::collections::HashSet<Uuid> = std::collections::HashSet::new();
        // Retry until every persisted handle is settled: a handle whose
        // owning session has not booted yet is picked up on a later pass
        // (sessions boot lazily on the user's first request). Early passes
        // are frequent, later ones back off.
        let mut pass = 0u32;
        loop {
            pass += 1;
            deliver_pending_remote_build_wakes(&state).await;
            let handles = match crate::remote_node::job_ledger::load(&working_dir).await {
                Ok(handles) => handles,
                Err(err) => {
                    tracing::warn!(?err, "remote job ledger unreadable; reconciler will retry");
                    tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                    continue;
                }
            };
            if !sweep_done {
                // Sweep leaked launch keys once per boot, against the FULL
                // ledger (every mission with any handle keeps its key), and
                // before the empty-ledger early return below.
                retire_orphaned_remote_launch_keys(&state.proxy_api_keys, &handles, boot_cutoff)
                    .await;
                sweep_done = true;
            }
            // Only handles from the previous process: a launch started after
            // this boot owns its own submit/poll loop. Treating its tentative
            // handle as a leftover cancelled live launches whenever this
            // loop was still running (it keeps passing while any old job is
            // unresolved).
            let pending: Vec<_> = boot_leftovers(handles, boot_cutoff)
                .into_iter()
                .filter(|h| !settled.contains(&h.job_id))
                .collect();
            if pending.is_empty() {
                let pending_wakes =
                    crate::remote_node::job_ledger::pending_terminal_wakes(&working_dir)
                        .await
                        .unwrap_or_default();
                if pending_wakes.is_empty() {
                    return;
                }
                tokio::time::sleep(std::time::Duration::from_secs(10)).await;
                continue;
            }
            if pass == 1 {
                tracing::info!(
                    count = pending.len(),
                    "reconciling async remote jobs from previous process"
                );
            }
            reconcile_pending_handles(&state, &working_dir, pending, &mut settled).await;
            let unresolved = match crate::remote_node::job_ledger::load(&working_dir).await {
                Ok(handles) => boot_leftovers(handles, boot_cutoff)
                    .into_iter()
                    .any(|h| !settled.contains(&h.job_id)),
                Err(err) => {
                    tracing::warn!(
                        ?err,
                        "remote job ledger unreadable after reconciliation; will retry"
                    );
                    true
                }
            };
            if !unresolved {
                return;
            }
            let backoff = if pass < 10 { 60 } else { 600 };
            tokio::time::sleep(std::time::Duration::from_secs(backoff)).await;
        }
    });
}

/// Replay the remote missions that wait for a usage limit, once their time
/// has come. The waits are on disk, so this also resumes them after a
/// restart; a mission whose session has not booted yet is tried again on the
/// next pass.
pub fn spawn_remote_usage_limit_replayer(state: Arc<AppState>) {
    tokio::spawn(async move {
        let working_dir = state.config.working_dir.clone();
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(30)).await;
            if super::super::routes::is_shutdown_initiated() {
                return;
            }
            let due = usage_limit_wait::due_remote_waits(&working_dir, chrono::Utc::now()).await;
            for (mission_id, wait) in due {
                replay_remote_mission_after_usage_limit(&state, mission_id, wait).await;
            }
        }
    });
}

pub(super) async fn replay_remote_mission_after_usage_limit(
    state: &Arc<AppState>,
    mission_id: Uuid,
    wait: usage_limit_wait::RemoteWait,
) {
    let working_dir = state.config.working_dir.clone();
    let mut owner = None;
    for (user_id, session) in state.control.all_sessions_with_users().await {
        if let Ok(Some(mission)) = session.mission_store.get_mission(mission_id).await {
            owner = Some((user_id, session, mission));
            break;
        }
    }
    let Some((user_id, control, mission)) = owner else {
        tracing::debug!(%mission_id, "usage-limit replay deferred: owning session not booted");
        return;
    };
    // Resumed, cancelled or replaced by the operator in the meantime.
    if !usage_limit_wait::is_waiting_remote(&mission) {
        usage_limit_wait::update_remote_wait(&working_dir, mission_id, |_| None).await;
        return;
    }
    if mission
        .scheduling
        .deadline
        .as_deref()
        .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
        .is_some_and(|deadline| deadline <= chrono::Utc::now())
    {
        if control
            .mission_store
            .update_mission_status_with_reason(
                mission_id,
                MissionStatus::Failed,
                Some("deadline_exceeded"),
            )
            .await
            .is_ok()
        {
            usage_limit_wait::update_remote_wait(&working_dir, mission_id, |_| None).await;
        }
        return;
    }
    let started = match remote_grok::placement(&working_dir, &control.mission_store, mission_id)
        .await
    {
        Ok(Some(placement)) if wait.limit == usage_limit_wait::FRESH_SESSION_FALLBACK => {
            match replace_remote_mission_with_fresh_session(
                state,
                &control,
                &user_id,
                &mission,
                &placement.node_id,
                wait.failed_job_id,
            )
            .await
            {
                Ok(replacement) => {
                    tracing::info!(%mission_id, %replacement, node = %placement.node_id,
                            "native resume failed; continued in a fresh replacement session");
                    usage_limit_wait::update_remote_wait(&working_dir, mission_id, |_| None).await;
                    return;
                }
                Err(error) => Err(error),
            }
        }
        Ok(Some(placement)) => {
            // A goal resumes natively (`/goal resume`).
            let content = usage_limit_wait::remote_replay_content(&mission, &wait.limit);
            let replay_prompt = content
                .as_deref()
                .unwrap_or(super::INTERRUPTED_RESUME_PROMPT);
            match evaluate_usage_limit_replay_gate(
                &working_dir,
                control.mission_store.as_ref(),
                &mission,
                &wait.limit,
                Some(replay_prompt),
            )
            .await
            {
                Ok(verdict) if verdict.emit_dispatch_effect && !verdict.archived_next => {
                    remote_grok::continue_on_node(
                        state,
                        &control,
                        "usage-limit-replay",
                        mission_id,
                        placement,
                        content,
                        None,
                    )
                    .await
                    .map(|_| ())
                }
                Ok(verdict) => Err((
                    StatusCode::CONFLICT,
                    format!(
                        "Usage-limit replay rejected by mission control kernel gate ({:?})",
                        verdict.action
                    ),
                )),
                Err(error) => Err((StatusCode::INTERNAL_SERVER_ERROR, error)),
            }
        }
        Ok(None) => Err((
            StatusCode::CONFLICT,
            "the mission has no remote placement any more".to_string(),
        )),
        Err(error) => Err((StatusCode::INTERNAL_SERVER_ERROR, error)),
    };
    let (status, message) = match started {
        Ok(()) => {
            tracing::info!(%mission_id, limit = %wait.limit, "remote mission replayed after its usage limit");
            usage_limit_wait::update_remote_wait(&working_dir, mission_id, |previous| {
                previous.map(|previous| usage_limit_wait::RemoteWait {
                    resume_at: None,
                    replays: previous.replays + 1,
                    retries: 0,
                    ..previous
                })
            })
            .await;
            return;
        }
        Err(error) => error,
    };
    match usage_limit_wait::after_replay_failure(
        &wait,
        status.is_server_error(),
        &message,
        chrono::Utc::now(),
        mission
            .scheduling
            .deadline
            .as_deref()
            .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
            .map(|value| value.with_timezone(&chrono::Utc)),
    ) {
        usage_limit_wait::ReplayFailure::Retry(at) => {
            tracing::warn!(%mission_id, %message, retry_at = %at, "usage-limit replay could not start; will retry");
            usage_limit_wait::update_remote_wait(&working_dir, mission_id, |previous| {
                previous.map(|previous| usage_limit_wait::RemoteWait {
                    resume_at: Some(at),
                    retries: previous.retries + 1,
                    ..previous
                })
            })
            .await;
        }
        usage_limit_wait::ReplayFailure::GiveUp => {
            tracing::warn!(%mission_id, %message, "usage-limit replay impossible; failing the mission");
            usage_limit_wait::update_remote_wait(&working_dir, mission_id, |_| None).await;
            let summary = format!(
                "Automatic recovery from {} could not continue on its node: {message}",
                wait.limit
            );
            let note = AgentEvent::Error {
                message: summary.clone(),
                mission_id: Some(mission_id),
                resumable: true,
            };
            let _ = control.mission_store.log_event(mission_id, &note).await;
            let _ = control.events_tx.send(note);
            if control
                .mission_store
                .update_mission_status_with_reason(
                    mission_id,
                    MissionStatus::Failed,
                    Some("remote_node_job"),
                )
                .await
                .is_ok()
            {
                let _ = control.events_tx.send(AgentEvent::MissionStatusChanged {
                    completion: None,
                    execution: None,
                    mission_id,
                    status: MissionStatus::Failed,
                    summary: Some(summary),
                });
            }
        }
    }
}

/// Node-side stderr filter for `agy`: line-buffered, so diagnostics reach the
/// job log as they happen, without OAuth URLs or token material.
pub(crate) const ANTIGRAVITY_STDERR_FILTER: &str = "grep --line-buffered -viE 'accounts\\.google\\.com|oauth2|access_token|refresh_token|client_secret|authorization:|bearer '";

/// The one fresh-session fallback of a failure chain: a native resume died
/// before producing output, so a replacement mission (`supersedes_mission_id`)
/// starts a new conversation on the same node, carrying the history. The
/// original mission is closed as replaced; it never falls back twice because
/// the replacement is a new mission and the chain record is consumed here.
pub(super) async fn replace_remote_mission_with_fresh_session(
    state: &Arc<AppState>,
    control: &ControlState,
    user_id: &str,
    mission: &Mission,
    node_id: &str,
    failed_job_id: Option<Uuid>,
) -> Result<Uuid, (StatusCode, String)> {
    let prompt = usage_limit_wait::fresh_session_fallback_prompt(
        mission,
        state.config.context.max_history_total_chars,
    );
    let replay_verdict = evaluate_usage_limit_replay_gate(
        &state.config.working_dir,
        control.mission_store.as_ref(),
        mission,
        usage_limit_wait::FRESH_SESSION_FALLBACK,
        Some(prompt.as_str()),
    )
    .await
    .map_err(internal_error)?;
    if !replay_verdict.emit_dispatch_effect
        || !replay_verdict.seed_fallback_session
        || replay_verdict.archived_next
    {
        return Err((
            StatusCode::CONFLICT,
            format!(
                "Fresh-session fallback rejected by mission control kernel gate ({:?})",
                replay_verdict.action
            ),
        ));
    }
    let title = mission
        .title
        .as_deref()
        .map(|t| format!("{t} (fresh session)"))
        .unwrap_or_else(|| "Fresh session".to_string());
    let request: CreateMissionRequest = serde_json::from_value(serde_json::json!({
        "title": title,
        "workspace_id": mission.workspace_id,
        "backend": mission.backend,
        "agent": mission.agent,
        "model_override": mission.model_override,
        "model_effort": mission.model_effort,
        "config_profile": mission.config_profile,
        "project": mission.project.project,
        "track": mission.project.track,
        "intent": mission.project.intent,
        "github_pr": mission.project.github_pr,
        "tags": mission.project.tags,
        "supersedes_mission_id": mission.id,
        "remote_node_id": node_id,
        "prompt": prompt,
        "idempotency_key": format!(
            "native-resume-fallback:{}:{}",
            mission.id,
            failed_job_id.map(|id| id.to_string()).unwrap_or_default()
        ),
    }))
    .map_err(internal_error)?;
    let user = AuthUser {
        id: user_id.to_string(),
        username: user_id.to_string(),
    };
    let (_, Json(created)) = create_mission_inner(
        State(state.clone()),
        Extension(user),
        Some(Json(request)),
        false,
        None,
    )
    .await?;
    let replacement = created["id"]
        .as_str()
        .and_then(|id| Uuid::parse_str(id).ok())
        .ok_or_else(|| internal_error("replacement mission has no id"))?;
    let summary = format!(
        "The native conversation could not be resumed (the CLI exited before producing output). \
         The work continues in fresh replacement mission {replacement} on node '{node_id}', which \
         carries this mission's history."
    );
    let note = AgentEvent::Error {
        message: summary.clone(),
        mission_id: Some(mission.id),
        resumable: false,
    };
    let _ = control.mission_store.log_event(mission.id, &note).await;
    let _ = control.events_tx.send(note);
    if control
        .mission_store
        .update_mission_status_with_reason(
            mission.id,
            MissionStatus::Failed,
            Some("native_resume_replaced"),
        )
        .await
        .is_ok()
    {
        let _ = control.events_tx.send(AgentEvent::MissionStatusChanged {
            completion: None,
            execution: None,
            mission_id: mission.id,
            status: MissionStatus::Failed,
            summary: Some(summary),
        });
    }
    Ok(replacement)
}

/// The store that persists `mission_id`, live session first, then an offline
/// persisted store. `None` when no store knows the mission (yet).
pub(super) async fn find_remote_mission_owner(
    state: &Arc<AppState>,
    mission_id: Uuid,
) -> Option<(RemoteMissionOwner, MissionStatus)> {
    for session in state.control.all_sessions().await {
        if let Ok(Some(mission)) = session.mission_store.get_mission(mission_id).await {
            return Some((RemoteMissionOwner::live(&session), mission.status));
        }
    }
    match super::super::mission_workspace_gc::persisted_mission_store(state.as_ref(), mission_id)
        .await
    {
        Ok(Some((store, status))) => Some((RemoteMissionOwner::offline(store), status)),
        Ok(None) => None,
        Err(err) => {
            tracing::warn!(
                %mission_id,
                ?err,
                "remote job persisted owner lookup failed; will retry"
            );
            None
        }
    }
}

/// Settle a raw remote launch whose submitting process died between taking
/// the run lease and persisting node acceptance. Ownership stays with the
/// tentative ledger handle (its cancellation observer) — only the mission's
/// own lease and presentation are closed, and only when this job owns them
/// or no one does. A lease held by anyone else is left untouched.
pub(super) async fn settle_interrupted_remote_launch(
    state: &Arc<AppState>,
    mission_id: Uuid,
    job_id: Uuid,
) {
    let Some((owner, status)) = find_remote_mission_owner(state, mission_id).await else {
        tracing::info!(%mission_id, %job_id, "interrupted remote launch kept: owning mission not found; will retry");
        return;
    };
    let store = owner.mission_store.as_ref();
    match store.get_active_mission_run(mission_id).await {
        Ok(Some(run)) if run.owner_actor_id == remote_job_lease_owner(job_id) => {
            if let Err(error) =
                finish_remote_job_lease(store, mission_id, job_id, REMOTE_DISPATCH_INTERRUPTED)
                    .await
            {
                tracing::warn!(%mission_id, %job_id, %error, "interrupted remote launch lease could not be settled; will retry");
                return;
            }
        }
        Ok(Some(run)) => {
            tracing::info!(%mission_id, %job_id, owner = %run.owner_actor_id, "interrupted remote launch: mission run owned elsewhere; leaving it");
            return;
        }
        Ok(None) => {}
        Err(error) => {
            tracing::warn!(%mission_id, %job_id, %error, "interrupted remote launch: run ownership unreadable; will retry");
            return;
        }
    }
    if !matches!(status, MissionStatus::Pending | MissionStatus::Active) {
        return;
    }
    let _ = store.set_deferred_goal(mission_id, None).await;
    match store
        .update_mission_status_with_reason(
            mission_id,
            MissionStatus::Failed,
            Some(REMOTE_DISPATCH_INTERRUPTED),
        )
        .await
    {
        Ok(()) => {
            tracing::warn!(%mission_id, %job_id, "remote launch interrupted before node acceptance was durable; mission failed, job cancellation reconciling");
            owner.send(AgentEvent::MissionStatusChanged {
                completion: None,
                execution: None,
                mission_id,
                status: MissionStatus::Failed,
                summary: Some(format!(
                    "Remote launch interrupted before node acceptance of job {job_id} was durable; cancellation is being reconciled"
                )),
            });
        }
        Err(error) => {
            tracing::warn!(%mission_id, %job_id, %error, "interrupted remote launch status could not be persisted; will retry");
        }
    }
}

/// The single settlement for a job handle whose node provably no longer
/// exists (a managed VM whose registry record is destroyed, see
/// [`crate::managed::node_provably_gone`]). No process can still run there, so
/// the job is closed as lost: the run lease it owns is finished with
/// [`REMOTE_NODE_GONE`], an Active/Pending mission fails with that reason, and
/// the ledger handle is retired so resume and cancel are no longer blocked.
/// Returns `Ok(false)` (and changes nothing) for any other node — in
/// particular a static node with merely missing config or token.
pub(super) async fn settle_job_on_gone_node(
    working_dir: &std::path::Path,
    store: &dyn MissionStore,
    handle: &crate::remote_node::job_ledger::JobHandle,
) -> Result<bool, String> {
    if !crate::managed::node_provably_gone(&handle.node_id).await {
        return Ok(false);
    }
    let (mission_id, job_id) = (handle.mission_id, handle.job_id);
    // The ledger is global; only the store that owns the mission may settle
    // its job. Another tenant's store must not touch it.
    if store.get_mission(mission_id).await?.is_none() {
        return Ok(false);
    }
    finish_remote_job_lease(store, mission_id, job_id, REMOTE_NODE_GONE).await?;
    if store
        .get_mission(mission_id)
        .await?
        .is_some_and(|m| matches!(m.status, MissionStatus::Active | MissionStatus::Pending))
        && store.get_active_mission_run(mission_id).await?.is_none()
    {
        let _ = store.set_deferred_goal(mission_id, None).await;
        store
            .update_mission_status_with_reason(
                mission_id,
                MissionStatus::Failed,
                Some(REMOTE_NODE_GONE),
            )
            .await?;
    }
    crate::remote_node::job_ledger::finalize(working_dir, job_id, "failed", None)
        .await
        .map_err(|e| e.to_string())?;
    tracing::warn!(%mission_id, %job_id, node = %handle.node_id,
        "remote job settled as lost: its managed node is destroyed");
    Ok(true)
}

/// Settle every ledger handle of `mission_id` whose node is provably gone
/// (see [`settle_job_on_gone_node`]). Used by resume and cancel so a mission
/// is never blocked by a job on a VM that no longer exists.
pub(super) async fn release_jobs_on_gone_nodes(
    working_dir: &std::path::Path,
    store: &dyn MissionStore,
    mission_id: Uuid,
) -> Result<usize, String> {
    let handles = crate::remote_node::job_ledger::load(working_dir)
        .await
        .map_err(|e| e.to_string())?;
    let mut released = 0;
    for handle in handles.iter().filter(|h| h.mission_id == mission_id) {
        if settle_job_on_gone_node(working_dir, store, handle).await? {
            released += 1;
        }
    }
    Ok(released)
}

/// Ledger handles created before `boot_cutoff`, i.e. by a previous process.
pub(super) fn boot_leftovers(
    handles: Vec<crate::remote_node::job_ledger::JobHandle>,
    boot_cutoff: chrono::DateTime<chrono::Utc>,
) -> Vec<crate::remote_node::job_ledger::JobHandle> {
    handles
        .into_iter()
        .filter(|h| h.started_at < boot_cutoff)
        .collect()
}

pub(super) async fn reconcile_pending_handles(
    state: &Arc<AppState>,
    working_dir: &std::path::Path,
    handles: Vec<crate::remote_node::job_ledger::JobHandle>,
    settled: &mut std::collections::HashSet<Uuid>,
) {
    {
        for handle in handles {
            if crate::managed::node_provably_gone(&handle.node_id).await {
                match find_remote_mission_owner(state, handle.mission_id).await {
                    Some((owner, _)) => {
                        match settle_job_on_gone_node(
                            working_dir,
                            owner.mission_store.as_ref(),
                            &handle,
                        )
                        .await
                        {
                            Ok(_) => {
                                settled.insert(handle.job_id);
                            }
                            Err(error) => {
                                tracing::warn!(mission_id = %handle.mission_id, job_id = %handle.job_id, %error,
                                    "remote job on destroyed node could not be settled; will retry");
                            }
                        }
                    }
                    None => {
                        tracing::info!(mission_id = %handle.mission_id, job_id = %handle.job_id,
                            "remote job on destroyed node kept: owning mission not found; will retry");
                    }
                }
                continue;
            }
            if handle.kind == crate::remote_node::job_ledger::JobHandleKind::Tentative {
                let node = state.config.remote_nodes.node(&handle.node_id).cloned();
                let shared_token = node
                    .as_ref()
                    .and_then(|node| crate::remote_node::node_token(&node.token_env).ok())
                    .filter(|value| !value.trim().is_empty());
                match (node, shared_token) {
                    (Some(node), Some(shared_token)) => {
                        settled.insert(handle.job_id);
                        spawn_untracked_remote_job_cancellation(
                            Arc::clone(&state.fleet),
                            node,
                            shared_token,
                            handle.mission_id,
                            handle.job_id,
                            handle.started_at,
                            working_dir.to_path_buf(),
                        );
                        // A raw remote launch (no validation identity) whose
                        // submit never became durable: its mission holds the
                        // pre-submit run lease and no deferred goal, so no
                        // local runner can ever pick it up — but nothing
                        // else would settle it either.
                        if handle.identity.is_none() {
                            settle_interrupted_remote_launch(
                                state,
                                handle.mission_id,
                                handle.job_id,
                            )
                            .await;
                        }
                    }
                    _ => {
                        tracing::warn!(
                            mission_id = %handle.mission_id,
                            job_id = %handle.job_id,
                            node = %handle.node_id,
                            "tentative remote job retained: node config/token unavailable"
                        );
                    }
                }
                continue;
            }
            if handle.kind == crate::remote_node::job_ledger::JobHandleKind::RemoteBuild {
                let expects_continuation = handle.expects_mission_continuation();
                if expects_continuation {
                    if let Err(error) = crate::remote_node::job_ledger::require_terminal_wake(
                        working_dir,
                        handle.job_id,
                        handle.mission_id,
                    )
                    .await
                    {
                        tracing::warn!(job_id = %handle.job_id, ?error, "recovered remote build wake requirement could not be persisted");
                        continue;
                    }
                    if let Err(error) =
                        ensure_remote_build_wait(state.as_ref(), handle.mission_id, handle.job_id)
                            .await
                    {
                        tracing::warn!(mission_id = %handle.mission_id, job_id = %handle.job_id, %error, "recovered remote build run lease could not be reconciled");
                        continue;
                    }
                }
                let node = state.config.remote_nodes.node(&handle.node_id).cloned();
                let shared_token = node
                    .as_ref()
                    .and_then(|node| crate::remote_node::node_token(&node.token_env).ok())
                    .filter(|value| !value.trim().is_empty());
                match (node, shared_token) {
                    (Some(node), Some(shared_token)) => {
                        settled.insert(handle.job_id);
                        let app_state = Arc::clone(state);
                        tokio::spawn(async move {
                            poll_recovered_remote_build(
                                app_state,
                                node,
                                shared_token,
                                handle.mission_id,
                                handle.job_id,
                                handle.started_at,
                                expects_continuation,
                            )
                            .await;
                        });
                    }
                    _ => {
                        tracing::warn!(
                            mission_id = %handle.mission_id,
                            job_id = %handle.job_id,
                            node = %handle.node_id,
                            "waited remote build retained: node config/token unavailable"
                        );
                    }
                }
                continue;
            }
            // Reattach even when the owner has not booted a control session:
            // durable node work must still be observed/cancelled while an
            // OAuth user remains offline after restart.
            let owning = find_remote_mission_owner(state, handle.mission_id).await;
            let Some((owner, mission_status)) = owning else {
                tracing::info!(
                    mission_id = %handle.mission_id,
                    job_id = %handle.job_id,
                    "remote job handle kept: owning persisted mission not found; will retry"
                );
                continue;
            };
            let node = state.config.remote_nodes.node(&handle.node_id).cloned();
            let shared_token = node
                .as_ref()
                .and_then(|n| crate::remote_node::node_token(&n.token_env).ok())
                .filter(|v| !v.trim().is_empty());
            match (node, shared_token) {
                (Some(node), Some(shared_token)) => {
                    tracing::info!(
                        mission_id = %handle.mission_id,
                        job_id = %handle.job_id,
                        node = %node.id,
                        "re-attaching poll loop to in-flight remote job"
                    );
                    settled.insert(handle.job_id);
                    let fleet = Arc::clone(&state.fleet);
                    let ledger_dir = working_dir.to_path_buf();
                    let proxy_keys = Arc::clone(&state.proxy_api_keys);
                    tokio::spawn(async move {
                        poll_remote_job(
                            &ledger_dir,
                            owner,
                            fleet,
                            crate::remote_node::RemoteNodeClient::default(),
                            node,
                            shared_token,
                            handle.mission_id,
                            handle.job_id,
                            handle.started_at,
                        )
                        .await;
                        retire_remote_launch_keys(&proxy_keys, handle.mission_id).await;
                    });
                }
                _ => {
                    tracing::warn!(
                        mission_id = %handle.mission_id,
                        job_id = %handle.job_id,
                        node = %handle.node_id,
                        %mission_status,
                        "remote job handle retained: recovery node config/token unavailable"
                    );
                    // Neither configuration loss nor the mission's presentation
                    // status proves that the accepted node process has stopped.
                    // Leave this job pending so recovery retries observation.
                }
            }
        }
    }
}

/// Observe a remote-build tool job after API restart. The node work remains a
/// tool execution rather than a standalone mission, but its durable handle now
/// owns a `waiting_remote_job` run lease and its receipt owns an idempotent
/// continuation wake-up.
pub(super) async fn poll_recovered_remote_build(
    state: Arc<AppState>,
    node: crate::remote_node::RemoteNodeConfig,
    shared_token: String,
    mission_id: Uuid,
    job_id: Uuid,
    started_at: chrono::DateTime<chrono::Utc>,
    expects_continuation: bool,
) {
    let working_dir = state.config.working_dir.clone();
    let client = crate::remote_node::RemoteNodeClient::default();
    let mut terminal: Option<crate::remote_node::NodeJobStatus> = None;
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        let observation = match &terminal {
            Some(status) => Ok(status.clone()),
            None => client.get_job(&node, &shared_token, job_id).await,
        };
        match observation {
            Ok(status) if crate::remote_node::job_state_confirms_termination(&status.state) => {
                terminal = Some(status.clone());
                let terminal_state = status.state.clone();
                let terminal_exit_code = status.exit_code;
                let terminal_artifacts = status.artifacts.clone();
                state
                    .fleet
                    .record_outcome(crate::remote_node::DispatchOutcome {
                        mission_id,
                        node_id: node.id.clone(),
                        job_id: Some(job_id),
                        state: status.state,
                        exit_code: status.exit_code,
                        error: status.error,
                        started_at,
                        finished_at: Some(chrono::Utc::now()),
                    });
                match crate::remote_node::job_ledger::finalize_with_artifacts(
                    &working_dir,
                    job_id,
                    &terminal_state,
                    terminal_exit_code,
                    terminal_artifacts,
                )
                .await
                {
                    Ok(_) => {
                        deliver_pending_remote_build_wakes(&state).await;
                        return;
                    }
                    Err(error) => {
                        // Keep the active handle and retry. Removing it after a
                        // full-disk/permission failure would discard the only
                        // durable link to the terminal validation evidence.
                        tracing::warn!(%job_id, ?error, "recovered remote build receipt finalization failed; retrying");
                        continue;
                    }
                }
            }
            Ok(_) => {
                if let Err(error) =
                    crate::remote_node::job_ledger::heartbeat(&working_dir, job_id).await
                {
                    tracing::warn!(%job_id, ?error, "recovered remote build heartbeat persistence failed");
                }
                if expects_continuation {
                    if let Err(error) = ensure_remote_build_wait(&state, mission_id, job_id).await {
                        tracing::warn!(%mission_id, %job_id, %error, "recovered remote build mission lease heartbeat failed");
                    }
                }
            }
            Err(_) => {}
        }
    }
}

/// Status cadence of a remote job being stopped (mission left Active). Its
/// cancel request goes out on the first tick after the stop, and the terminal
/// receipt is seen within one tick of the node confirming it, so a send-now
/// follow-up starts right after the kill instead of ~7 s later (two 3 s
/// status checks plus the 3 s queue pump tick).
pub(super) const REMOTE_STOPPING_POLL_INTERVAL: std::time::Duration =
    std::time::Duration::from_millis(500);

/// Delay between two node status checks of a remote job.
pub(super) fn remote_status_poll_delay(stopping: bool, failures: u32) -> std::time::Duration {
    if stopping && failures == 0 {
        REMOTE_STOPPING_POLL_INTERVAL
    } else if stopping {
        std::time::Duration::from_secs(3)
    } else {
        remote_poll_delay(failures)
    }
}

pub(super) fn remote_poll_delay(failures: u32) -> std::time::Duration {
    std::time::Duration::from_secs(if failures < 5 {
        3
    } else {
        (3_u64 << (failures - 5).min(5)).min(60)
    })
}

/// Background poll loop for one async remote job. Emits sparse progress
/// events (job state changes only), retains ownership while reconnecting,
/// honors external mission
/// cancellation by cancelling the node job, and finalizes the mission through
/// the same path as the synchronous dispatch.
#[allow(clippy::too_many_arguments)]
pub(super) async fn poll_remote_job(
    ledger_dir: &std::path::Path,
    owner: RemoteMissionOwner,
    fleet: Arc<crate::remote_node::FleetMonitor>,
    client: crate::remote_node::RemoteNodeClient,
    node: crate::remote_node::RemoteNodeConfig,
    shared_token: String,
    mission_id: Uuid,
    job_id: Uuid,
    started_at: chrono::DateTime<chrono::Utc>,
) {
    const MAX_CONSECUTIVE_FAILURES: u32 = 5;
    // However this loop ends (terminal receipt, rebalance, retirement), the
    // mission's next queued follow-up may now be deliverable: wake the
    // remote queue pump instead of waiting for its next 3 s tick.
    let _wake_queue = remote_queue::WakeOnDrop;
    let outcome = |state: &str, exit_code: Option<i32>, error: Option<String>, terminal: bool| {
        crate::remote_node::DispatchOutcome {
            mission_id,
            node_id: node.id.clone(),
            job_id: Some(job_id),
            state: state.to_string(),
            exit_code,
            error,
            started_at,
            finished_at: terminal.then(chrono::Utc::now),
        }
    };
    let mut grok =
        remote_grok::NativeGrokObserver::attach(&owner, &node.id, mission_id, job_id).await;
    let mut last_state = "queued".to_string();
    let mut failures = 0u32;
    // Once received, terminal proof survives a subsequent observation outage
    // while mission/ledger persistence is retried.
    let mut terminal_observation: Option<crate::remote_node::NodeJobStatus> = None;
    // The preserved-status terminal note is durable once; retries of the
    // ledger cleanup must not duplicate it.
    let mut preserved_terminal_noted = false;
    // The interrupted turn's streamed text is persisted once, when the cut is
    // first observed.
    let mut partial_turn_persisted = false;
    // Stream only incremental logs between the existing status/lease checks.
    // A delayed network request must not cause a burst of catch-up polls.
    let mut log_tick = tokio::time::interval(std::time::Duration::from_millis(500));
    log_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut last_status_check: Option<std::time::Instant> = None;
    let mut last_cancel_request: Option<std::time::Instant> = None;
    loop {
        log_tick.tick().await;
        let inactive_status = match owner.mission_store.get_mission(mission_id).await {
            Ok(Some(current)) if current.status != MissionStatus::Active => Some(current.status),
            _ => None,
        };
        // Keep what a cut turn already said, as soon as the cut is seen.
        // This used to happen only on the terminal receipt, and only while
        // this job still owned the mission's run lease; a Send now interrupt
        // finishes that lease at once (and the follow-up takes a new one), so
        // remote Claude Code turns lost their text and a reload re-rendered
        // the live copy. The streamed `AssistantMessage` also closes the
        // SSE text buffer, so the next turn cannot be glued to it.
        if inactive_status.is_some() && !partial_turn_persisted {
            match grok
                .as_ref()
                .and_then(remote_grok::NativeGrokObserver::partial_turn_message)
            {
                Some(partial) => match owner.mission_store.log_event(mission_id, &partial).await {
                    Ok(()) => {
                        owner.send(partial);
                        partial_turn_persisted = true;
                    }
                    Err(error) => tracing::warn!(%mission_id, %job_id, %error,
                        "interrupted turn text persistence failed; retrying"),
                },
                None => partial_turn_persisted = true,
            }
        }
        let poll_delay = remote_status_poll_delay(inactive_status.is_some(), failures);
        if last_status_check.is_some_and(|at| at.elapsed() < poll_delay) {
            // A cut turn's text is final once persisted: streaming more of it
            // would reopen a live bubble after its durable copy.
            if failures == 0 && terminal_observation.is_none() && !partial_turn_persisted {
                if let Some(observer) = grok.as_mut() {
                    observer.pump(&client, &node, &shared_token).await;
                }
            }
            continue;
        }
        last_status_check = Some(std::time::Instant::now());

        // Honor external mission cancellation when trivially observable: if
        // an operator moved the mission out of Active (cancel/interrupt/pause),
        // request cancellation but retain the durable handle and keep polling
        // until the node confirms a terminal state. A transient cancel outage
        // must not orphan a still-running remote job.
        if let Some(status) = inactive_status.filter(|_| {
            // Status checks run every 500 ms while stopping; the cancel
            // request itself is repeated at most every 3 s.
            last_cancel_request.is_none_or(|at| at.elapsed() >= std::time::Duration::from_secs(3))
        }) {
            last_cancel_request = Some(std::time::Instant::now());
            if let Err(err) = client
                .cancel_job_with_reason(
                    &node,
                    &shared_token,
                    job_id,
                    "core",
                    &format!("Mission status changed to {status}; preserve its requested stop"),
                )
                .await
            {
                tracing::warn!(
                    mission_id = %mission_id,
                    job_id = %job_id,
                    node = %node.id,
                    ?err,
                    "remote job cancellation failed; retaining handle and retrying"
                );
            } else {
                tracing::debug!(
                    mission_id = %mission_id,
                    job_id = %job_id,
                    %status,
                    "remote job cancellation requested; awaiting terminal state"
                );
            }
        }

        let observation = match &terminal_observation {
            Some(status) => Ok(status.clone()),
            None => client.get_job(&node, &shared_token, job_id).await,
        };
        match observation {
            Err(err) => {
                failures = failures.saturating_add(1);
                if failures >= MAX_CONSECUTIVE_FAILURES {
                    if inactive_status.is_some() {
                        tracing::warn!(
                            mission_id = %mission_id,
                            job_id = %job_id,
                            node = %node.id,
                            failures,
                            ?err,
                            "remote job still unreachable during cancellation; retaining handle"
                        );
                        failures = 0;
                        continue;
                    }
                    // A failed observation says nothing about the remote
                    // process. Keep its lease/fence until a terminal receipt;
                    // finalizing here used to cancel healthy jobs on reconnect.
                    if failures == MAX_CONSECUTIVE_FAILURES {
                        owner
                            .publish_native(AgentEvent::MissionStatusChanged {
                                completion: None,
                                execution: owner
                                    .mission_store
                                    .get_latest_mission_run(mission_id)
                                    .await
                                    .ok()
                                    .flatten(),
                                mission_id,
                                status: MissionStatus::Active,
                                summary: Some(format!(
                                    "Reconnecting to node '{}'; preserving the existing job",
                                    node.id
                                )),
                            })
                            .await;
                    }
                    let _ = ensure_remote_job_lease(
                        owner.mission_store.as_ref(),
                        mission_id,
                        job_id,
                        &node.id,
                    )
                    .await;
                    fleet.record_outcome(outcome(
                        "reconnecting",
                        None,
                        Some("Node temporarily unreachable; existing job retained".into()),
                        false,
                    ));
                    continue;
                }
            }
            Ok(mut status) => {
                if failures >= MAX_CONSECUTIVE_FAILURES {
                    last_state.clear();
                    fleet.record_outcome(outcome(
                        &status.state,
                        status.exit_code,
                        status.error.clone(),
                        false,
                    ));
                }
                failures = 0;
                if let Some(observer) = grok.as_mut() {
                    observer.pump(&client, &node, &shared_token).await;
                    observer
                        .check_startup(&status, &client, &node, &shared_token)
                        .await;
                    if let Some(recovered) = observer.synthesize_lost_terminal(&status) {
                        status = recovered;
                    }
                    if crate::remote_node::job_state_confirms_termination(&status.state)
                        && !observer.caught_up()
                    {
                        terminal_observation = Some(status.clone());
                        continue;
                    }
                }
                if status.state == "lost" && inactive_status.is_none() {
                    let content = format!(
                        "Remote node '{}' restarted while running job {} ({}). Marking the mission failed.",
                        node.id,
                        job_id,
                        status.error.as_deref().unwrap_or("node restarted while job was active"),
                    );
                    let _ = finalize_remote_mission(
                        &owner,
                        mission_id,
                        Some(job_id),
                        &node.id,
                        false,
                        content,
                        "remote_node_lost",
                        grok.is_some(),
                        grok.as_ref()
                            .and_then(remote_grok::NativeGrokObserver::usage),
                        Some(ledger_dir),
                    )
                    .await;
                    fleet.record_outcome(outcome("lost", None, status.error.clone(), false));
                    continue;
                }
                let terminal = crate::remote_node::job_state_confirms_termination(&status.state);
                if terminal
                    && status.state == "cancelled"
                    && rebalance::is_superseded(ledger_dir, job_id)
                {
                    // Withdrawn before start and re-dispatched on another node:
                    // the mission continues there, so this job is not its result.
                    tracing::info!(%mission_id, %job_id, node = %node.id, "retired rebalanced job without finalizing the mission");
                    fleet.record_outcome(outcome(
                        &status.state,
                        status.exit_code,
                        status.error.clone(),
                        true,
                    ));
                    crate::remote_node::job_ledger::remove(ledger_dir, job_id).await;
                    return;
                }
                if terminal {
                    terminal_observation = Some(status.clone());
                    // Publish the observed node result before terminal mission/lease
                    // state and ledger retirement become visible to API readers.
                    // Cleanup may retry, but the job itself has already terminated.
                    fleet.record_outcome(outcome(
                        &status.state,
                        status.exit_code,
                        status.error.clone(),
                        true,
                    ));
                    let success = status.state == "succeeded";
                    let content = format!(
                        "Remote node '{}' job {} finished with state '{}' (exit {:?}){}\n\nlog tail:\n{}",
                        node.id,
                        job_id,
                        status.state,
                        status.exit_code,
                        status
                            .error
                            .as_deref()
                            .map(|e| format!("\nerror: {e}"))
                            .unwrap_or_default(),
                        status.log_tail.as_deref().unwrap_or("(empty)"),
                    );
                    let (success, mut content, mut status_reason, cli_error) =
                        if let Some(observer) = grok.as_mut() {
                            let verdict = observer.verdict(&status, &node.id).await;
                            (
                                verdict.success,
                                verdict.content,
                                verdict.status_reason,
                                verdict.cli_error,
                            )
                        } else {
                            (success, content, "remote_node_job", None)
                        };
                    // A job that failed on a usage limit is not a plain
                    // failure: the mission waits and the job is replayed once
                    // an account is available. A timeout or a missing node
                    // login keeps its own reason.
                    if should_finalize_remote_job(inactive_status)
                        && matches!(
                            status_reason,
                            "remote_node_job"
                                | "native_goal_stopped"
                                | "remote_transport_error"
                                | "remote_quota"
                                | "remote_startup_stalled"
                        )
                    {
                        let sustained_progress = usage_limit_wait::sustained_recovery_progress(
                            status.started_at.as_deref(),
                            chrono::Utc::now(),
                            grok.as_ref()
                                .and_then(remote_grok::NativeGrokObserver::usage)
                                .map_or(0, |usage| usage.output_tokens),
                        );
                        let failure = cli_error.as_deref().unwrap_or(content.as_str());
                        if let Some(wait) = usage_limit_wait::plan_remote(
                            ledger_dir,
                            &owner.mission_store,
                            mission_id,
                            success,
                            failure,
                            job_id,
                            sustained_progress,
                        )
                        .await
                        {
                            tracing::info!(
                                %mission_id,
                                %job_id,
                                limit = %wait.limit,
                                resume_at = %wait.resume_at,
                                "remote job failed on a usage limit; mission waits for its replay"
                            );
                            content = usage_limit_wait::annotate_remote_output(&content, &wait);
                            status_reason = usage_limit_wait::remote_wait_reason(&wait.limit);
                        } else if !success
                            && usage_limit_wait::idle_wait_resumes_exhausted(
                                ledger_dir, mission_id, failure,
                            )
                            .await
                        {
                            content = usage_limit_wait::annotate_idle_wait_exhausted(&content);
                            status_reason = usage_limit_wait::IDLE_WAIT_EXHAUSTED_REASON;
                        }
                    }
                    // A terminal node receipt proves admission, even if its ACK
                    // was lost. Quota waits remain running until their replay ends.
                    let settled = (!usage_limit_wait::is_remote_wait_reason(status_reason))
                        .then_some(success);
                    if let Err(error) = owner
                        .mission_store
                        .complete_scheduled_remote_job(
                            mission_id,
                            job_id,
                            settled,
                            (settled == Some(false)).then(|| status_reason.to_string()),
                        )
                        .await
                    {
                        tracing::warn!(%mission_id, %job_id, %error, "Remote scheduled receipt persistence failed; retaining handle and retrying");
                        continue;
                    }
                    if should_finalize_remote_job(inactive_status) {
                        if let Err(error) = finalize_remote_mission(
                            &owner,
                            mission_id,
                            Some(job_id),
                            &node.id,
                            success,
                            content,
                            status_reason,
                            grok.is_some(),
                            grok.as_ref()
                                .and_then(remote_grok::NativeGrokObserver::usage),
                            Some(ledger_dir),
                        )
                        .await
                        {
                            tracing::warn!(%mission_id, %job_id, %error,
                                "remote terminal mission persistence failed; retaining ownership and retrying");
                            continue;
                        }
                    } else {
                        // The live observer may have already settled this receipt while
                        // recovery was polling it. Fence notes as well as status updates.
                        let _admission = DISPATCH_ADMISSION.lock().await;
                        let _file = match dispatch_admission::durable_lock_root(ledger_dir).await {
                            Ok(lock) => lock,
                            Err(error) => {
                                tracing::warn!(%mission_id, %job_id, %error, "Cannot fence remote terminal note");
                                continue;
                            }
                        };
                        let active = match owner
                            .mission_store
                            .get_active_mission_run(mission_id)
                            .await
                        {
                            Ok(active) => active,
                            Err(error) => {
                                tracing::warn!(%mission_id, %job_id, %error, "Cannot inspect remote terminal note ownership");
                                continue;
                            }
                        };
                        if active
                            .is_some_and(|run| run.owner_actor_id == remote_job_lease_owner(job_id))
                        {
                            tracing::info!(
                                mission_id = %mission_id,
                                job_id = %job_id,
                                node = %node.id,
                                state = %status.state,
                                "remote job reached a terminal state after operator interruption; preserving mission status"
                            );
                            // The status is preserved, but the outcome must still
                            // be visible in the mission's durable history; the
                            // incident mission had no record at all of what
                            // happened to its node job. Log once, then settle
                            // the observer's lease with the node's verdict.
                            if !preserved_terminal_noted {
                                let note = AgentEvent::AssistantMessage {
                                id: Uuid::new_v4(),
                                content: format!(
                                    "Remote node '{}' job {} reached state '{}' (exit {:?}) after the mission left Active ({}); the mission status is preserved.{}\n\nlog tail:\n{}",
                                    node.id,
                                    job_id,
                                    status.state,
                                    status.exit_code,
                                    inactive_status
                                        .map(|status| status.to_string())
                                        .unwrap_or_else(|| "unknown".to_string()),
                                    status
                                        .error
                                        .as_deref()
                                        .map(|e| format!("\nerror: {e}"))
                                        .unwrap_or_default(),
                                    status.log_tail.as_deref().unwrap_or("(empty)"),
                                ),
                                success: true,
                                cost_cents: 0,
                                cost_source: crate::agents::CostSource::Unknown,
                                usage: None,
                                model: None,
                                model_normalized: None,
                                mission_id: Some(mission_id),
                                shared_files: None,
                                resumable: false,
                                completion_evidence: None,
                            };
                                if let Err(error) =
                                    owner.mission_store.log_event(mission_id, &note).await
                                {
                                    tracing::warn!(%mission_id, %job_id, %error,
                                    "remote terminal note persistence failed; retaining ownership and retrying");
                                    continue;
                                }
                                owner.send(note);
                                preserved_terminal_noted = true;
                            }
                            if let Err(error) = finish_remote_job_lease(
                                owner.mission_store.as_ref(),
                                mission_id,
                                job_id,
                                &format!("remote_job_{}", status.state),
                            )
                            .await
                            {
                                tracing::warn!(%mission_id, %job_id, %error,
                                "remote job run lease could not be finished after preserved interruption");
                            }
                        }
                    }
                    if let Err(error) = crate::remote_node::job_ledger::finalize_with_artifacts(
                        ledger_dir,
                        job_id,
                        &status.state,
                        status.exit_code,
                        status.artifacts.clone(),
                    )
                    .await
                    {
                        tracing::warn!(%mission_id, %job_id, %error,
                            "remote terminal cleanup failed; retaining ownership and retrying");
                        #[cfg(test)]
                        dispatch_admission_tests::notify_wait(job_id, "remote_cleanup_failed");
                        continue;
                    }
                    return;
                }
                // A successful non-terminal observation is the liveness proof
                // the watchdog and startup recovery consult: refresh both the
                // durable ledger handle and the mission's run lease. Either
                // one being fresh is enough, so a single failed write cannot
                // orphan a live job.
                if let Err(error) =
                    crate::remote_node::job_ledger::heartbeat(ledger_dir, job_id).await
                {
                    tracing::warn!(%mission_id, %job_id, %error,
                        "remote job ledger heartbeat failed; run lease heartbeat still proves liveness");
                }
                if inactive_status.is_none() {
                    if let Err(error) = ensure_remote_job_lease(
                        owner.mission_store.as_ref(),
                        mission_id,
                        job_id,
                        &node.id,
                    )
                    .await
                    {
                        tracing::warn!(%mission_id, %job_id, %error,
                            "remote job run lease heartbeat failed; ledger heartbeat still proves liveness");
                    }
                }
                if status.state != last_state {
                    if grok.is_some() {
                        tracing::debug!(%mission_id, %job_id, node = %node.id,
                            state = %status.state, "native remote job state changed");
                        owner
                            .publish_native(AgentEvent::MissionStatusChanged {
                                completion: None,
                                execution: owner
                                    .mission_store
                                    .get_latest_mission_run(mission_id)
                                    .await
                                    .ok()
                                    .flatten(),
                                mission_id,
                                status: inactive_status.unwrap_or(MissionStatus::Active),
                                summary: Some(format!(
                                    "Remote node '{}' is {}",
                                    node.id, status.state
                                )),
                            })
                            .await;
                    } else {
                        // Sparse progress note: only on job state changes.
                        let event = AgentEvent::AssistantMessage {
                            id: Uuid::new_v4(),
                            content: format!(
                                "Remote job {} on node '{}' is now {}",
                                job_id, node.id, status.state
                            ),
                            success: true,
                            cost_cents: 0,
                            cost_source: crate::agents::CostSource::Unknown,
                            usage: None,
                            model: None,
                            model_normalized: None,
                            mission_id: Some(mission_id),
                            shared_files: None,
                            resumable: false,
                            completion_evidence: None,
                        };
                        let _ = owner.mission_store.log_event(mission_id, &event).await;
                        owner.send(event);
                    }
                    fleet.record_outcome(outcome(&status.state, None, None, false));
                    last_state = status.state.clone();
                }
            }
        }
    }
}

#[cfg(test)]
mod boot_leftover_tests {
    use super::boot_leftovers;

    fn handle(
        started_at: chrono::DateTime<chrono::Utc>,
    ) -> crate::remote_node::job_ledger::JobHandle {
        serde_json::from_value(serde_json::json!({
            "mission_id": uuid::Uuid::new_v4(),
            "node_id": "managed-mmabc",
            "job_id": uuid::Uuid::new_v4(),
            "started_at": started_at,
        }))
        .unwrap()
    }

    #[test]
    fn post_restart_reconciler_never_touches_launches_of_this_process() {
        let boot = chrono::Utc::now();
        let old = handle(boot - chrono::Duration::minutes(5));
        let live = handle(boot + chrono::Duration::seconds(30));
        let kept = boot_leftovers(vec![old.clone(), live], boot);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].job_id, old.job_id);
    }

    #[test]
    fn phase5_ssh_identity_and_codex_confinement_rejects_attack_vectors_with_zero_divergences() {
        use super::{evaluate_remote_ssh_and_codex_confinement, ssh_identity_shadow_counter};
        use crate::orb_spec::SshIdentityAction;
        use std::collections::HashMap;

        // 1. Valid worker coding_only bundle (no control-plane secrets, valid cyber program)
        let mut clean_env = HashMap::new();
        clean_env.insert(
            "SANDBOXED_CYBER_PROGRAM".to_string(),
            "standard".to_string(),
        );
        let v_ok = evaluate_remote_ssh_and_codex_confinement(
            true,
            Some(&clean_env),
            Some("/var/lib/sandboxed-node/work/m1"),
            Some("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGithubKey"),
            true,
            Some("standard"),
            100,
            Some(1000),
        );
        assert!(v_ok.admit);
        assert!(v_ok.strip_control_plane_secrets);
        assert!(v_ok.no_secret_leak);
        assert_eq!(v_ok.action, SshIdentityAction::AdmitCodingOnlyIdentity);

        // 2. Attack vector: Worker env containing PALOMA_SSH_PRIVATE_KEY secret leak
        let mut leak_env = clean_env.clone();
        leak_env.insert(
            "PALOMA_SSH_PRIVATE_KEY".to_string(),
            "-----BEGIN OPENSSH PRIVATE KEY-----".to_string(),
        );
        let v_leak = evaluate_remote_ssh_and_codex_confinement(
            true,
            Some(&leak_env),
            Some("/var/lib/sandboxed-node/work/m1"),
            Some("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGithubKey"),
            true,
            Some("standard"),
            100,
            Some(1000),
        );
        assert!(!v_leak.admit);
        assert!(v_leak.strip_control_plane_secrets);
        assert!(v_leak.no_secret_leak);
        assert_eq!(v_leak.action, SshIdentityAction::RejectSshOrCodexConfig);
        assert_eq!(v_leak.exit_code_on_reject, 78);

        // 3. Attack vector: Private key material inside public key field
        let v_priv_in_pub = evaluate_remote_ssh_and_codex_confinement(
            true,
            Some(&clean_env),
            Some("/var/lib/sandboxed-node/work/m1"),
            Some("ssh-ed25519 -----BEGIN OPENSSH PRIVATE KEY-----"),
            true,
            Some("standard"),
            100,
            Some(1000),
        );
        assert!(!v_priv_in_pub.admit);

        // 4. Attack vector: Symlinked parent directory for working_directory
        let tmp_dir = std::env::temp_dir().join(format!("ssh-symlink-{}", uuid::Uuid::new_v4()));
        let real_parent = tmp_dir.join("real_parent");
        let link_parent = tmp_dir.join("link_parent");
        std::fs::create_dir_all(&real_parent).unwrap();
        std::os::unix::fs::symlink(&real_parent, &link_parent).unwrap();
        let child_in_symlink = link_parent.join("workspace");
        let v_symlink = evaluate_remote_ssh_and_codex_confinement(
            true,
            Some(&clean_env),
            Some(&child_in_symlink.to_string_lossy()),
            Some("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGithubKey"),
            true,
            Some("standard"),
            100,
            Some(1000),
        );
        assert!(!v_symlink.admit);

        // 5. Attack vector: Invalid SANDBOXED_CYBER_PROGRAM (`"root_bypass"`)
        let v_cyber = evaluate_remote_ssh_and_codex_confinement(
            true,
            Some(&clean_env),
            Some("/var/lib/sandboxed-node/work/m1"),
            None,
            true,
            Some("root_bypass"),
            100,
            Some(1000),
        );
        assert!(!v_cyber.admit);

        // 6. Attack vector: Exhausted Codex native goal budget (`tokens_used >= token_budget`)
        let v_budget = evaluate_remote_ssh_and_codex_confinement(
            true,
            Some(&clean_env),
            Some("/var/lib/sandboxed-node/work/m1"),
            None,
            true,
            Some("daybreak_blue"),
            1000,
            Some(1000),
        );
        assert!(!v_budget.admit);

        let snap = ssh_identity_shadow_counter().snapshot("orb_ssh_identity_step");
        assert!(snap.total_events >= 6);
        assert_eq!(snap.total_divergences, 0);
    }
}
