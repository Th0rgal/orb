//! Node-backed jobs reuse the durable-job record; no mission observer is added.
use super::*;
use crate::remote_node::{
    JobPayload, LeaseClaims, RemoteNodeClient, SubmitJobRequest, SCOPE_JOB_SUBMIT,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Placement {
    pub node_id: String,
    pub workspace_mission_id: Uuid,
}

type Error = (StatusCode, Json<ErrorResponse>);

fn node_auth<'a>(
    state: &'a AppState,
    placement: &Placement,
) -> Result<(&'a crate::remote_node::RemoteNodeConfig, String), Error> {
    let node = state
        .config
        .remote_nodes
        .node(&placement.node_id)
        .ok_or_else(|| err(StatusCode::CONFLICT, "Recorded job node unavailable"))?;
    let secret = std::env::var(&node.token_env)
        .ok()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            err(
                StatusCode::SERVICE_UNAVAILABLE,
                "Node authentication unavailable",
            )
        })?;
    Ok((node, secret))
}

fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub(super) async fn start(
    state: &Arc<AppState>,
    user: &AuthUser,
    req: StartDurableJobRequest,
    node_id: String,
) -> Result<DurableJob, Error> {
    let mission_id = req
        .started_by_mission_id
        .ok_or_else(|| err(StatusCode::BAD_REQUEST, "Mission required"))?;
    let _mutation =
        crate::api::control::machine_transfer::workspace_mutation_lock(mission_id).await;
    let control = control_for_user(state, user).await;
    crate::api::control::machine_transfer::guard(&control.mission_store, mission_id)
        .await
        .map_err(|e| err(StatusCode::CONFLICT, e))?;
    let current = crate::api::control::remote_grok::placement(
        &state.config.working_dir,
        &control.mission_store,
        mission_id,
    )
    .await
    .map_err(|e| err(StatusCode::CONFLICT, e))?;
    if current.as_ref().map(|p| p.node_id.as_str()) != Some(node_id.as_str()) {
        return Err(err(
            StatusCode::CONFLICT,
            "Mission placement changed; no command submitted",
        ));
    }
    let mission = control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?
        .ok_or_else(|| err(StatusCode::NOT_FOUND, "Mission unavailable"))?;
    let placement = Placement {
        node_id,
        workspace_mission_id: mission
            .project
            .tags
            .iter()
            .find_map(|s| {
                s.strip_prefix("fork-workspace:")
                    .and_then(|s| Uuid::parse_str(s).ok())
            })
            .unwrap_or(mission_id),
    };
    let (node, secret) = node_auth(state, &placement)?;
    let key = validated_idempotency_key(req.idempotency_key.as_deref())
        .map_err(|e| err(StatusCode::BAD_REQUEST, e))?;
    let id = durable_job_id(&user.id, mission_id, key.as_deref());
    let timeout = req
        .timeout_secs
        .unwrap_or(DEFAULT_JOB_TIMEOUT_SECS)
        .clamp(1, MAX_JOB_TIMEOUT_SECS);
    let root = crate::api::control::machine_transfer::committed(&control.mission_store, mission_id)
        .await
        .map_err(|e| err(StatusCode::CONFLICT, e))?
        .and_then(|t| t.destination_root);
    let cwd = req.cwd.as_deref().unwrap_or(".");
    let fingerprint = crate::project_context::digest(
        serde_json::to_string(&(
            durable_job_request_fingerprint(
                &req.command,
                Path::new(cwd),
                mission.workspace_id,
                &req.env,
                timeout,
                req.resource_class.as_deref(),
            ),
            &placement.node_id,
            placement.workspace_mission_id,
            &root,
        ))
        .unwrap()
        .as_bytes(),
    );
    let dir = job_dir(state, id);
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|_| err(StatusCode::INTERNAL_SERVER_ERROR, "Job store unavailable"))?;
    let _claim = try_acquire_submission_claim(&dir.join("submission.claim"))
        .map_err(|_| err(StatusCode::INTERNAL_SERVER_ERROR, "Job claim unavailable"))?
        .ok_or_else(|| {
            err(
                StatusCode::CONFLICT,
                "Job submission in progress; retry the same key",
            )
        })?;
    if tokio::fs::try_exists(job_file(state, id))
        .await
        .map_err(|_| {
            err(
                StatusCode::SERVICE_UNAVAILABLE,
                "Cannot inspect existing job receipt",
            )
        })?
    {
        let existing = read_job(state, id).await.map_err(|_| {
            err(
                StatusCode::SERVICE_UNAVAILABLE,
                "Existing job receipt is unreadable; do not resubmit",
            )
        })?;
        if existing.request_fingerprint.as_deref() != Some(&fingerprint) {
            return Err(err(
                StatusCode::CONFLICT,
                "Idempotency key belongs to a different job",
            ));
        }
        // This also covers a crash between journalling intent and submission.
        // Never replace the immutable node/job identity or blindly resubmit.
        return Ok(refresh(state, existing).await);
    }
    let now = Utc::now();
    let mut job = DurableJob {
        remote: Some(placement.clone()),
        id,
        command: req.command.clone(),
        cwd: cwd.into(),
        status: DurableJobStatus::Unknown,
        pid: None,
        exit_code: None,
        signal: None,
        created_at: now,
        updated_at: now,
        heartbeat_at: None,
        deadline_at: Some(now + chrono::Duration::seconds(timeout as i64)),
        started_by_mission_id: Some(mission_id),
        workspace_id: Some(mission.workspace_id),
        owner_user_id: Some(user.id.clone()),
        stdout_log: dir.join("stdout.log").to_string_lossy().into(),
        stderr_log: dir.join("stderr.log").to_string_lossy().into(),
        status_file: dir.join("exit.json").to_string_lossy().into(),
        spawn_accepted: false,
        scope_unit: None,
        resource_class: req.resource_class.clone(),
        idempotency_key: key,
        request_fingerprint: Some(fingerprint),
    };
    job = write_job(state, &job).await.map_err(|_| {
        err(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Could not persist job intent",
        )
    })?;
    // The node supplies the workspace root. Requested cwd can only narrow it;
    // an absolute Core path is never sent as a fallback.
    let launcher = "import json,os,pathlib,sys,time\nr=json.loads(sys.argv[1]); root=pathlib.Path(r['root'] or '.').resolve(); cwd=(root/r['cwd']).resolve()\nif not cwd.is_relative_to(root): raise SystemExit('cwd leaves mission workspace')\nremaining=r['deadline']-time.time()\nif remaining<=0: raise SystemExit('job deadline elapsed before launch')\nos.chdir(cwd); os.execvp('timeout',['timeout','--signal=TERM','--kill-after=5s',str(remaining),'bash','-lc',r['command']])";
    let launch = serde_json::json!({"root":root,"cwd":cwd,"command":req.command,"deadline":job.deadline_at.unwrap().timestamp()});
    let claims = LeaseClaims {
        mission_id: placement.workspace_mission_id,
        node_id: node.id.clone(),
        scope: SCOPE_JOB_SUBMIT.into(),
        expires_at: (now + chrono::Duration::minutes(5)).timestamp(),
        job_id: Some(id),
    };
    let lease_token = crate::remote_node::create_lease_token(&claims, &secret)
        .map_err(|_| err(StatusCode::INTERNAL_SERVER_ERROR, "Cannot issue node lease"))?;
    let request = SubmitJobRequest {
        job_id: id,
        mission_id: placement.workspace_mission_id,
        lease_token,
        payload: JobPayload::RawCommand {
            long_running: false,
            command: format!(
                "exec python3 -c {} {}",
                quote(launcher),
                quote(&launch.to_string())
            ),
            timeout_secs: Some(timeout),
            env: Some(req.env),
            managed_auth: vec![],
        },
    };
    if let Ok(accepted) = RemoteNodeClient::default()
        .submit_job(node, &secret, &request)
        .await
    {
        if accepted.job_id == id {
            job.spawn_accepted = true;
            job.status = DurableJobStatus::Running;
            job.updated_at = Utc::now();
        }
    }
    // A lost response remains Unknown and can only be resolved by reading this
    // same node/job. It is never treated as permission for Core/local fallback.
    write_job(state, &job).await.map_err(|_| {
        err(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Node outcome must be reconciled using the existing job ID",
        )
    })
}

pub(super) async fn refresh(state: &AppState, mut job: DurableJob) -> DurableJob {
    let Some(placement) = job.remote.as_ref() else {
        return job;
    };
    let Ok((node, secret)) = node_auth(state, placement) else {
        return job;
    };
    let Ok(observed) = RemoteNodeClient::default()
        .get_job(node, &secret, job.id)
        .await
    else {
        return job;
    };
    if observed.job_id != job.id || observed.mission_id != placement.workspace_mission_id {
        return job;
    }
    job.status = match observed.state.as_str() {
        "queued" | "running" => DurableJobStatus::Running,
        "succeeded" => DurableJobStatus::Completed,
        "failed" => DurableJobStatus::Failed,
        "cancelled" => DurableJobStatus::Cancelled,
        _ => DurableJobStatus::Unknown,
    };
    job.spawn_accepted = true;
    job.exit_code = observed.exit_code;
    job.heartbeat_at = Some(Utc::now());
    job.updated_at = Utc::now();
    if let Some(log) = observed.log_tail {
        let bytes = log.as_bytes();
        let start = bytes.len().saturating_sub(64 * 1024);
        let _ = tokio::fs::write(&job.stdout_log, &bytes[start..]).await;
    }
    write_job(state, &job).await.unwrap_or(job)
}

pub(super) async fn cancel(state: &AppState, job: DurableJob) -> Result<DurableJob, Error> {
    let job = refresh(state, job).await;
    if !job_is_cancellable(&job.status) {
        return Ok(job);
    }
    let placement = job
        .remote
        .as_ref()
        .ok_or_else(|| err(StatusCode::CONFLICT, "Not a remote job"))?;
    let (node, secret) = node_auth(state, placement)?;
    RemoteNodeClient::default()
        .cancel_job(node, &secret, job.id)
        .await
        .map_err(|_| {
            err(
                StatusCode::SERVICE_UNAVAILABLE,
                "Cancellation outcome unconfirmed; inspect the existing job",
            )
        })?;
    // Cancellation accepted does not prove the process stopped. Only a node
    // terminal receipt may turn Running into Cancelled.
    Ok(refresh(state, job).await)
}
