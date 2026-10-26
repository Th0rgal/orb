//! Mission listing, execution projections, fleet health and track summaries.

use super::*;

// ==================== Mission Endpoints ====================

/// List all missions.
#[derive(Debug, Default, Deserialize)]
pub struct ListMissionsQuery {
    #[serde(default)]
    pub limit: Option<usize>,
    #[serde(default)]
    pub offset: Option<usize>,
    /// Optional filter: exact mission status (e.g. "awaiting_user").
    #[serde(default)]
    pub status: Option<String>,
    /// Optional filter: exact project identifier.
    #[serde(default)]
    pub project: Option<String>,
    /// Optional filter: project FAMILY — matches `X` and `X-*`. Use this to
    /// span a project whose missions are still split across per-phase slugs
    /// (`verity`, `verity-core`, `verity-phase1d`, …). `project` stays exact
    /// so existing callers keep their current results.
    #[serde(default)]
    pub project_prefix: Option<String>,
    /// Optional filter: exact track within a project.
    #[serde(default)]
    pub track: Option<String>,
    /// Optional filter: missions carrying this tag.
    #[serde(default)]
    pub tag: Option<String>,
    /// Optional filter: the conversation a mission was launched from.
    #[serde(default)]
    pub origin_session_id: Option<String>,
    /// Optional filter: workspace by id or (case-insensitive) name.
    #[serde(default)]
    pub workspace: Option<String>,
    /// Include acknowledged/completed/absorbed missions that default listings
    /// hide (e.g. a project's full history view). Ignored when `status` is set.
    #[serde(default)]
    pub all: Option<bool>,
}

pub(super) fn mission_execution_projection(
    run: &MissionRun,
    status: MissionStatus,
) -> serde_json::Value {
    let heartbeat_age = chrono::DateTime::parse_from_rfc3339(&run.heartbeat_at)
        .ok()
        .map(|timestamp| {
            (chrono::Utc::now() - timestamp.with_timezone(&chrono::Utc))
                .num_seconds()
                .max(0) as u64
        })
        .unwrap_or(u64::MAX);
    let conflict = if run.execution_state.is_terminal() {
        None
    } else if status == MissionStatus::Acknowledged || status.is_terminal() {
        Some(format!("status_{status}_with_non_terminal_run"))
    } else if heartbeat_age > 60 && run.execution_state != MissionExecutionState::WaitingUser {
        Some(format!("run_heartbeat_stale_{heartbeat_age}s"))
    } else {
        None
    };
    serde_json::json!({
        "run_id": run.run_id,
        "generation": run.generation,
        "state": run.execution_state,
        "health": if conflict.is_some() { "reconciling" } else { "healthy" },
        "heartbeat_at": run.heartbeat_at,
        "scope_unit": run.scope_unit,
        "ended_at": run.ended_at,
        "terminal_reason": run.terminal_reason,
        "status_conflict": conflict,
    })
}

pub(super) fn attach_execution_to_mission_value(
    mut value: serde_json::Value,
    mission: &Mission,
    run: Option<&MissionRun>,
    wait_started_at: Option<&str>,
) -> serde_json::Value {
    if let Some(object) = value.as_object_mut() {
        object.insert(
            "execution".to_string(),
            run.map(|run| mission_execution_projection(run, mission.status))
                .unwrap_or(serde_json::Value::Null),
        );
        object.insert(
            "acknowledged_at".to_string(),
            if mission.status == MissionStatus::Acknowledged {
                serde_json::Value::String(mission.updated_at.clone())
            } else {
                serde_json::Value::Null
            },
        );
        let waiting_for_user_tool =
            run.is_some_and(|run| run.execution_state == MissionExecutionState::WaitingUser);
        object.insert(
            "needs_operator".to_string(),
            serde_json::Value::Bool(super::super::operator_attention::mission_needs_operator(
                mission,
                waiting_for_user_tool,
                wait_started_at,
                chrono::Utc::now(),
            )),
        );
    }
    value
}

pub(super) fn is_user_wait_tool(tool_kind: &str) -> bool {
    matches!(tool_kind, "request_user_input" | "frontend_tool") || is_interactive_ui_tool(tool_kind)
}

/// Grace clock for a `WaitingUser` run. `Ok(None)` means the user-wait tool
/// row is not registered yet (treated as just started); `Err` means the tool
/// scan itself failed, which callers must not confuse with "just started".
pub(crate) async fn user_wait_tool_started_at_checked(
    store: &dyn MissionStore,
    run: &MissionRun,
) -> Result<Option<String>, String> {
    if run.execution_state != MissionExecutionState::WaitingUser {
        return Ok(None);
    }
    let tools = store.list_active_tool_executions(run.run_id).await?;
    Ok(tools
        .into_iter()
        .filter(|tool| is_user_wait_tool(&tool.tool_kind))
        .map(|tool| tool.started_at)
        .min())
}

/// Best-effort variant for surfaces that only render the clock.
pub(crate) async fn user_wait_tool_started_at(
    store: &dyn MissionStore,
    run: &MissionRun,
) -> Option<String> {
    user_wait_tool_started_at_checked(store, run)
        .await
        .ok()
        .flatten()
}

/// Returns `(waits, complete)`. `complete` is false when any tool scan
/// failed: the run still appears in the map (it *is* waiting), but its
/// clock is unknown, so the map must not be used as negative evidence.
pub(crate) async fn user_wait_starts_for_runs_checked(
    store: &dyn MissionStore,
    runs: impl IntoIterator<Item = &MissionRun>,
) -> (HashMap<Uuid, Option<String>>, bool) {
    let mut waits = HashMap::new();
    let mut complete = true;
    for run in runs {
        if run.execution_state != MissionExecutionState::WaitingUser {
            continue;
        }
        let started = match user_wait_tool_started_at_checked(store, run).await {
            Ok(started) => started,
            Err(error) => {
                tracing::warn!(
                    mission_id = %run.mission_id,
                    run_id = %run.run_id,
                    %error,
                    "user-wait tool scan failed; wait inventory is incomplete"
                );
                complete = false;
                None
            }
        };
        waits.insert(run.mission_id, started);
    }
    (waits, complete)
}

pub(crate) async fn user_wait_starts_for_runs(
    store: &dyn MissionStore,
    runs: impl IntoIterator<Item = &MissionRun>,
) -> HashMap<Uuid, Option<String>> {
    user_wait_starts_for_runs_checked(store, runs).await.0
}

pub(super) const PROVISIONAL_TOOL_DEADLINE_SECS: i64 = 120;
pub(super) const MANAGED_SHELL_TOOL_DEADLINE_SECS: i64 = 10 * 60;
pub(super) const LONG_BUILD_TOOL_DEADLINE_SECS: i64 = 2 * 60 * 60;

/// Return the absolute liveness window for a harness tool call.
///
/// Unknown protocol calls remain provisional for at most two minutes. Native
/// harness shell tools are different: the harness emits the ToolResult only
/// after its managed subprocess exits, so expiring their lease after two
/// minutes would make a healthy synchronous command indistinguishable from an
/// orphan. Keep ordinary shell work within the generic ten-minute ceiling and
/// allow known build/verification commands the same two-hour ceiling as a
/// durable workspace job.
pub(super) fn tool_execution_deadline_secs(tool_kind: &str, args: &serde_json::Value) -> i64 {
    if !matches!(tool_kind, "Bash" | "bash" | "shell" | "Shell") {
        return PROVISIONAL_TOOL_DEADLINE_SECS;
    }

    let command = args
        .get("command")
        .or_else(|| args.get("cmd"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();
    let normalized = command
        .split_whitespace()
        .map(|part| part.to_ascii_lowercase())
        .collect::<Vec<_>>()
        .join(" ");
    let is_long_build = [
        "remote-lean-build",
        "lake build",
        "lake test",
        "lake env lean",
        "cargo build --release",
        "cargo test --all",
        "npm run build",
        "bun run build",
        "next build",
    ]
    .iter()
    .any(|needle| normalized.contains(needle));

    if is_long_build {
        LONG_BUILD_TOOL_DEADLINE_SECS
    } else {
        MANAGED_SHELL_TOOL_DEADLINE_SECS
    }
}

pub(super) fn mission_heartbeat_state(
    active_tool_calls: usize,
    has_registered_user_wait: bool,
    has_durable_remote_job: bool,
) -> MissionExecutionState {
    if has_durable_remote_job {
        MissionExecutionState::WaitingRemoteJob
    } else if has_registered_user_wait {
        MissionExecutionState::WaitingUser
    } else if active_tool_calls > 0 {
        MissionExecutionState::WaitingTool
    } else {
        MissionExecutionState::Running
    }
}

pub(super) fn remote_build_handle_proves_liveness(
    handle: &crate::remote_node::job_ledger::JobHandle,
    now: chrono::DateTime<chrono::Utc>,
) -> bool {
    if handle.kind != crate::remote_node::job_ledger::JobHandleKind::RemoteBuild
        || handle.accepted_at.is_none()
        || !handle.expects_mission_continuation()
    {
        return false;
    }
    let last_proof = handle
        .heartbeat_at
        .or(handle.accepted_at)
        .unwrap_or(handle.started_at);
    now.signed_duration_since(last_proof) <= chrono::Duration::seconds(60)
}

pub(super) async fn mission_has_unresolved_remote_build(
    working_dir: &std::path::Path,
    mission_id: Uuid,
) -> bool {
    let Ok(Some(current_handle)) =
        crate::remote_node::job_ledger::current_remote_build_wait_handle(working_dir, mission_id)
            .await
    else {
        return false;
    };
    current_handle.expects_mission_continuation()
}

pub(super) async fn recoverable_inherited_remote_wait(
    working_dir: &std::path::Path,
    mission_id: Uuid,
    execution_state: MissionExecutionState,
    mission_status: MissionStatus,
) -> anyhow::Result<Option<Uuid>> {
    if execution_state != MissionExecutionState::WaitingRemoteJob
        || mission_status != MissionStatus::Active
    {
        return Ok(None);
    }
    recoverable_remote_continuation(working_dir, mission_id).await
}

/// Resolve the durable job that still owns a mission continuation.
///
/// This deliberately does not inspect the persisted run state. Node
/// acceptance and the following mission heartbeat are separate writes, so a
/// graceful shutdown can observe `running` or `waiting_tool` while the ledger
/// already proves that a remote job owns the continuation.
pub(super) async fn recoverable_remote_continuation(
    working_dir: &std::path::Path,
    mission_id: Uuid,
) -> anyhow::Result<Option<Uuid>> {
    // A remote harness owns the entire mission, unlike a delegated build.
    // The build-only resolver intentionally excludes Mission handles; excluding
    // them here turns a healthy remote run into an operator cancellation on boot.
    if let Some(handle) = crate::remote_node::job_ledger::load(working_dir)
        .await?
        .into_iter()
        .filter(|handle| {
            handle.mission_id == mission_id
                && handle.kind == crate::remote_node::job_ledger::JobHandleKind::Mission
                && handle.accepted_at.is_some()
        })
        .max_by_key(|handle| (handle.submission_sequence, handle.started_at))
    {
        return Ok(Some(handle.job_id));
    }
    if let Some(handle) =
        crate::remote_node::job_ledger::current_remote_build_wait_handle(working_dir, mission_id)
            .await?
    {
        return Ok(handle
            .expects_mission_continuation()
            .then_some(handle.job_id));
    }

    // `finalize` atomically moves a terminal job from the active ledger to
    // the receipt outbox. A crash after that move but before delivery leaves
    // no handle, yet the pending receipt still owns the mission continuation.
    let receipt =
        crate::remote_node::job_ledger::recoverable_terminal_continuations(working_dir, mission_id)
            .await?
            .into_iter()
            .max_by_key(|receipt| {
                crate::remote_node::job_ledger::validation_order(
                    receipt.submission_sequence,
                    receipt.started_at,
                )
            });
    let Some(receipt) = receipt else {
        return Ok(None);
    };
    if crate::remote_node::job_ledger::require_terminal_receipt_wake(
        working_dir,
        receipt.job_id,
        receipt.mission_id,
    )
    .await?
    {
        Ok(Some(receipt.job_id))
    } else {
        Ok(None)
    }
}

/// Decide whether graceful server shutdown must leave a mission's durable run
/// open for the remote-job reconciler.
///
/// A live harness may still be polling a synchronous remote build when
/// systemd asks the API to stop. Interrupting that harness is expected, but
/// interrupting the mission/run is not: the accepted node job survives the
/// process and owns the continuation. Fail closed on store/ledger read errors
/// so a transient shutdown race cannot turn a recoverable wait into a duplicate
/// submission after restart.
pub(super) async fn preserve_remote_wait_during_shutdown(
    mission_store: &Arc<dyn MissionStore>,
    working_dir: &std::path::Path,
    mission_id: Uuid,
) -> bool {
    let run = match mission_store.get_active_mission_run(mission_id).await {
        Ok(Some(run)) => run,
        Ok(None) => return false,
        Err(error) => {
            tracing::warn!(
                %mission_id,
                %error,
                "Graceful shutdown: active run unavailable; preserving mission fail-closed"
            );
            return true;
        }
    };
    let mission_status = match mission_store.get_mission(mission_id).await {
        Ok(Some(mission)) => mission.status,
        Ok(None) => return false,
        Err(error) => {
            tracing::warn!(
                %mission_id,
                %error,
                "Graceful shutdown: mission status unavailable; preserving remote wait fail-closed"
            );
            return true;
        }
    };
    if mission_status != MissionStatus::Active {
        return false;
    }

    match recoverable_remote_continuation(working_dir, mission_id).await {
        Ok(Some(job_id)) => {
            tracing::info!(
                %mission_id,
                run_id = %run.run_id,
                run_generation = run.generation,
                %job_id,
                "Graceful shutdown: preserving accepted remote-job continuation"
            );
            true
        }
        Ok(None) => false,
        Err(error) => {
            tracing::warn!(
                %mission_id,
                run_id = %run.run_id,
                %error,
                "Graceful shutdown: remote ledger unavailable; preserving wait fail-closed"
            );
            true
        }
    }
}

pub(super) async fn arm_unresolved_remote_build_wake(
    working_dir: &std::path::Path,
    mission_id: Uuid,
) -> Option<Uuid> {
    let job_id = match crate::remote_node::job_ledger::current_remote_build_wait_handle(
        working_dir,
        mission_id,
    )
    .await
    {
        Ok(Some(handle)) => handle.job_id,
        Ok(None) => return None,
        Err(error) => {
            tracing::warn!(%mission_id, ?error, "remote-build handles could not be loaded before turn parking");
            return None;
        }
    };

    match crate::remote_node::job_ledger::require_terminal_wake(working_dir, job_id, mission_id)
        .await
    {
        Ok(true) => Some(job_id),
        Ok(false) => None,
        Err(error) => {
            tracing::warn!(%mission_id, %job_id, ?error, "remote-build terminal wake could not be armed before turn parking");
            None
        }
    }
}

pub(super) fn remote_build_terminal_delivery_id(job: Uuid) -> Uuid {
    Uuid::new_v5(
        &Uuid::NAMESPACE_URL,
        format!("sandboxed:remote-build-terminal:{job}").as_bytes(),
    )
}

pub(super) async fn park_scheduled_remote_execution(
    store: &Arc<dyn MissionStore>,
    mission: Uuid,
    message: Option<Uuid>,
    job: Uuid,
) {
    let Some(message) = message else {
        return;
    };
    if let Err(error) = store
        .handoff_scheduled_executions(
            mission,
            vec![message],
            remote_build_terminal_delivery_id(job),
        )
        .await
    {
        tracing::error!(%mission, %error, "Failed to preserve scheduled remote continuation identity");
    }
}

pub(super) async fn mission_should_park_on_remote_build(
    mission_store: &Arc<dyn MissionStore>,
    working_dir: &std::path::Path,
    mission_id: Uuid,
) -> Option<Uuid> {
    let job = arm_unresolved_remote_build_wake(working_dir, mission_id).await?;
    if !mission_has_unresolved_remote_build(working_dir, mission_id).await {
        return None;
    }
    let Ok(Some(mission)) = mission_store.get_mission(mission_id).await else {
        return None;
    };
    if matches!(
        mission.status,
        MissionStatus::Interrupted
            | MissionStatus::Paused
            | MissionStatus::Blocked
            | MissionStatus::NotFeasible
    ) {
        return None;
    }
    mission_store
        .get_active_mission_run(mission_id)
        .await
        .ok()
        .flatten()
        .filter(|run| run.execution_state != MissionExecutionState::Stopping)
        .map(|_| job)
}

pub async fn list_missions(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Query(query): Query<ListMissionsQuery>,
) -> Result<Json<Vec<serde_json::Value>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    // Default to the most recent 50; honor an explicit limit so callers (e.g.
    // the assistant MCP) can request more, capped to keep the response bounded.
    let project = query.project.as_deref().map(|raw| {
        let canonical = super::super::projects_overview::canonicalize_project_slug(raw);
        if canonical.is_empty() {
            raw.to_string()
        } else {
            canonical
        }
    });
    let filter = crate::api::mission_store::MissionFilter {
        status: query.status.clone(),
        project,
        project_prefix: query.project_prefix.clone(),
        track: query.track.clone(),
        tag: query.tag.clone(),
        origin_session_id: query.origin_session_id.clone(),
        // Default listings (no explicit status) hide acknowledged / completed /
        // absorbed attempts. An explicit status is a precise query; `all=true`
        // opts out for callers that want full history (project views).
        attention_only: query.status.is_none() && query.all != Some(true),
    };
    // Workspace is the one predicate the store cannot answer: matching by
    // name needs `populate_workspace_names`, and the persisted
    // `workspace_name` column is not authoritative. It is applied in memory —
    // but over STORE-FILTERED candidates, so combining it with
    // origin_session_id/project/track keeps the pushdown and its unlimited
    // depth instead of falling back to scanning raw rows.
    let needs_workspace_scan = query.workspace.is_some();
    let limit = query.limit.unwrap_or(50).clamp(1, 200);
    let offset = query.offset.unwrap_or(0);

    let mut missions = if !needs_workspace_scan {
        // The store owns the predicate — sqlite pushes it into SQL, so a match
        // is found however deep it sits in the fleet.
        let mut page = control
            .mission_store
            .list_missions_filtered(&filter, limit, offset)
            .await
            .map_err(internal_error)?;
        populate_workspace_names(&state, &mut page).await;
        if filter.attention_only {
            crate::api::mission_store::reconcile_sidebar_missions_page(&[], &page, false)
        } else {
            page
        }
    } else {
        const PAGE: usize = 200;
        // Bounds how many STORE-FILTERED candidates we resolve workspace names
        // for, not how deep we read into the fleet: with a selective filter
        // the store already skipped everything irrelevant.
        const MAX_CANDIDATES: usize = 5_000;
        let workspace_lower = query.workspace.as_deref().map(|w| w.to_lowercase());
        let workspace_raw = query.workspace.as_deref();
        let want = offset.saturating_add(limit);

        let mut matched: Vec<Mission> = Vec::new();
        let mut scan_offset = 0usize;
        let mut scanned = 0usize;
        loop {
            let mut page = control
                .mission_store
                .list_missions_filtered(&filter, PAGE, scan_offset)
                .await
                .map_err(internal_error)?;
            let page_len = page.len();
            populate_workspace_names(&state, &mut page).await;
            let mut page_matches = Vec::new();
            for m in page {
                let keep = match (workspace_raw, workspace_lower.as_deref()) {
                    (Some(raw), Some(lower)) => {
                        m.workspace_id.to_string() == raw
                            || m.workspace_name
                                .as_deref()
                                .is_some_and(|name| name.to_lowercase() == lower)
                    }
                    _ => true,
                };
                if keep {
                    page_matches.push(m);
                }
            }
            if filter.attention_only {
                matched = crate::api::mission_store::reconcile_sidebar_missions_page(
                    &matched,
                    &page_matches,
                    true,
                );
            } else {
                for m in page_matches {
                    matched.push(m);
                    if matched.len() >= want {
                        break;
                    }
                }
            }
            scanned += page_len;
            if matched.len() >= want || page_len < PAGE || scanned >= MAX_CANDIDATES {
                if scanned >= MAX_CANDIDATES && matched.len() < want {
                    tracing::warn!(
                        "list_missions workspace scan hit candidate cap ({}); results may be incomplete",
                        MAX_CANDIDATES
                    );
                }
                break;
            }
            scan_offset += PAGE;
        }
        // Apply the offset to matches (not raw rows) and cap at limit.
        matched.into_iter().skip(offset).take(limit).collect()
    };

    populate_activity(&control, &mut missions).await;
    let callback_parents = callback_parent::links(&missions, &control.mission_store).await;
    let active_runs: HashMap<Uuid, MissionRun> = control
        .mission_store
        .list_active_mission_runs()
        .await
        .map_err(internal_error)?
        .into_iter()
        .map(|run| (run.mission_id, run))
        .collect();
    let wait_starts =
        user_wait_starts_for_runs(control.mission_store.as_ref(), active_runs.values()).await;
    let (remote_handles, remote_outcomes) = remote_job_projection_inputs(&state).await;
    let now = chrono::Utc::now();
    let continuation_summaries = continuations::summaries(&control.mission_store)
        .await
        .map_err(internal_error)?;
    let recoveries = usage_limit_wait::remote_recoveries(&state.config.working_dir).await;
    let mut values: Vec<serde_json::Value> = missions
        .into_iter()
        .map(|mission| {
            let value = serde_json::to_value(&mission).unwrap_or(serde_json::Value::Null);
            let value = attach_execution_to_mission_value(
                value,
                &mission,
                active_runs.get(&mission.id),
                wait_starts
                    .get(&mission.id)
                    .and_then(|started| started.as_deref()),
            );
            attach_remote_job_to_mission_value(
                value,
                remote_job_projection(
                    &remote_handles,
                    &remote_outcomes,
                    active_runs.get(&mission.id),
                    mission.id,
                    now,
                ),
            )
        })
        .collect();
    let mission_ids: Vec<Uuid> = values
        .iter()
        .filter_map(|v| v["id"].as_str().and_then(|s| Uuid::parse_str(s).ok()))
        .collect();
    let committed_transfers = control
        .mission_store
        .committed_machine_transfers(&mission_ids)
        .await
        .map_err(internal_error)?;
    for value in &mut values {
        if let Some(id) = value["id"].as_str().and_then(|s| Uuid::parse_str(s).ok()) {
            usage_limit_wait::attach_recovery(value, recoveries.get(&id));
            if let Some(parent) = callback_parents.get(&id) {
                value["callback_parent_mission_id"] = serde_json::json!(parent);
            }
            continuations::attach_capabilities(
                value,
                state.config.automations_enabled && control.mission_store.is_persistent(),
            );
            value["continuation"] = continuation_summaries
                .get(&id)
                .cloned()
                .unwrap_or(serde_json::Value::Null);
            if let Some(t) = committed_transfers.get(&id) {
                machine_transfer::project(value, t);
            }
        }
    }
    Ok(Json(values))
}

/// Targeted post-deploy/observability health for the mission fleet (P#8). One
/// authenticated GET confirms the critical loop is alive after a restart:
/// the control actor responds (scheduler heartbeat), the webhook forwarder and
/// offload are configured, and the current queue/running/status counts.
#[derive(Debug, Serialize)]
pub struct FleetHealth {
    pub status: &'static str,
    pub version: String,
    /// True iff the control actor answered our ListRunning/GetQueue probes —
    /// i.e. the scheduler/dispatch loop is not wedged.
    pub control_responsive: bool,
    pub running: usize,
    pub queue_depth: usize,
    pub missions: crate::api::mission_store::MissionStatusCounts,
    pub webhook_forwarder_configured: bool,
    pub offload_configured: bool,
    /// Root-filesystem usage so fleet controllers can preflight capacity
    /// instead of discovering a full disk through worker failures.
    pub disk_used: u64,
    pub disk_total: u64,
    pub disk_percent: f32,
    pub disk_level: crate::api::monitoring::DiskHealthLevel,
    /// Canonical path whose backing filesystem is measured for local missions.
    pub disk_path: String,
    /// Non-secret filesystem identifier returned by statvfs.
    pub disk_filesystem: String,
    pub disk_free_gib: u64,
    pub disk_required_gib: u64,
}

/// Admission preflight: `Some(reason)` when new missions must be refused
/// because the selected mission-workspace filesystem is critically full, or is at warn level while
/// `DISK_ADMISSION_AT_WARN=1`. `DISK_ADMISSION_ENABLED=0` is the escape hatch.
pub(super) fn disk_admission_refusal(path: &std::path::Path) -> Option<String> {
    let enabled = std::env::var("DISK_ADMISSION_ENABLED")
        .map(|v| v.trim() != "0" && !v.trim().eq_ignore_ascii_case("false"))
        .unwrap_or(true);
    if !enabled {
        return None;
    }
    let usage = match crate::api::monitoring::disk_usage_for_path(path) {
        Ok(usage) => usage,
        Err(error) => {
            return Some(format!(
                "mission creation refused: cannot measure workspace filesystem at {}: {error}",
                path.display()
            ));
        }
    };
    let used = usage.used;
    let total = usage.total;
    let percent = if total == 0 {
        100.0
    } else {
        used as f32 / total as f32 * 100.0
    };
    match crate::api::monitoring::DiskHealthLevel::from_percent(percent) {
        crate::api::monitoring::DiskHealthLevel::Critical => Some(format!(
            "mission creation refused: disk critically full at {} (filesystem {}, \
             {percent:.1}% used, {} GiB free). Free space or raise DISK_CRITICAL_PCT, then retry.",
            usage.measured_path.display(), usage.filesystem, usage.available / (1 << 30)
        )),
        crate::api::monitoring::DiskHealthLevel::Warn
            if std::env::var("DISK_ADMISSION_AT_WARN")
                .map(|value| value.trim() == "1" || value.trim().eq_ignore_ascii_case("true"))
                .unwrap_or(false) =>
        {
            Some(format!(
                "mission creation refused: disk above the admission warning threshold \
                 at {} (filesystem {}, {percent:.1}% used, {} GiB free). Wait for workspace GC, select a remote \
                 node, or free space.",
                usage.measured_path.display(), usage.filesystem, usage.available / (1 << 30)
            ))
        }
        crate::api::monitoring::DiskHealthLevel::Warn => {
            tracing::warn!(
                disk_percent = percent,
                "disk usage above warn threshold; admitting mission anyway"
            );
            None
        }
        crate::api::monitoring::DiskHealthLevel::Ok => None,
    }
}

pub(super) fn mission_disk_reserve_gib() -> u64 {
    std::env::var("MISSION_DISK_EMERGENCY_RESERVE_GB")
        .ok()
        .and_then(|raw| raw.trim().parse::<u64>().ok())
        .unwrap_or(150)
}

pub(super) fn mission_disk_default_estimate_gib() -> u64 {
    std::env::var("MISSION_DISK_DEFAULT_ESTIMATE_GIB")
        .ok()
        .and_then(|raw| raw.trim().parse::<u64>().ok())
        .filter(|estimate| (1..=512).contains(estimate))
        .unwrap_or(64)
}

pub(super) fn disk_estimate_refusal(
    usage: &crate::api::monitoring::DiskUsage,
    estimated_gib: u64,
    reserve_gib: u64,
) -> Option<String> {
    let required_gib = estimated_gib.saturating_add(reserve_gib);
    (usage.available < required_gib.saturating_mul(1 << 30)).then(|| {
        format!(
            "mission needs an estimated {estimated_gib} GiB scratch plus a {reserve_gib} GiB \
             emergency floor ({required_gib} GiB required), but only {} GiB is free at {} \
             (filesystem {}); select a remote node or free space",
            usage.available / (1 << 30),
            usage.measured_path.display(),
            usage.filesystem
        )
    })
}

pub async fn fleet_health(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<FleetHealth>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;

    // Probe the control actor; a wedged scheduler surfaces as a failed probe.
    let running = get_running_missions(&control).await.map(|r| r.len());
    let (tx, rx) = oneshot::channel();
    let queue_depth = if control
        .cmd_tx
        .send(ControlCommand::GetQueue { respond: tx })
        .await
        .is_ok()
    {
        rx.await.ok().map(|q| q.len())
    } else {
        None
    };
    let control_responsive = running.is_ok() && queue_depth.is_some();

    let missions = control
        .mission_store
        .count_missions_by_status()
        .await
        .map_err(internal_error)?;

    let cfg = &state.config;
    let workspace_root = crate::workspace::configured_mission_workspace_root(&cfg.working_dir);
    let disk =
        crate::api::monitoring::disk_usage_for_path(&workspace_root).map_err(internal_error)?;
    let disk_percent = if disk.total == 0 {
        100.0
    } else {
        disk.used as f32 / disk.total as f32 * 100.0
    };
    let reserve_gib = mission_disk_reserve_gib();
    let required_gib = mission_disk_default_estimate_gib().saturating_add(reserve_gib);
    Ok(Json(FleetHealth {
        status: if control_responsive { "ok" } else { "degraded" },
        version: env!("CARGO_PKG_VERSION").to_string(),
        control_responsive,
        running: running.unwrap_or(0),
        queue_depth: queue_depth.unwrap_or(0),
        missions,
        webhook_forwarder_configured: cfg.paloma_webhook_forward_url.is_some(),
        offload_configured: cfg.spark_arbiter_url.is_some() || cfg.spark_ssh_target.is_some(),
        disk_used: disk.used,
        disk_total: disk.total,
        disk_percent,
        disk_level: crate::api::monitoring::DiskHealthLevel::from_percent(disk_percent),
        disk_path: disk.measured_path.to_string_lossy().to_string(),
        disk_filesystem: disk.filesystem,
        disk_free_gib: disk.available / (1 << 30),
        disk_required_gib: required_gib,
    }))
}

/// Per project/track rollup so Paloma can reason about a track in one call
/// instead of scanning the fleet and parsing titles. Keyed by (project, track).
#[derive(Debug, Clone, Serialize)]
pub struct TrackSummary {
    pub project: Option<String>,
    pub track: Option<String>,
    pub total: usize,
    pub active: usize,
    pub pending: usize,
    pub awaiting_user: usize,
    /// `updated_at` of the most recently updated mission in the track.
    pub last_activity_at: Option<String>,
    /// `updated_at` of the most recent terminal (completed/failed/…) mission.
    pub latest_terminal_at: Option<String>,
    /// Operator-declared state / PR / next-check, taken from the most recently
    /// updated mission in the track that has each set.
    pub desired_state: Option<String>,
    pub github_pr: Option<String>,
    pub next_check_at: Option<String>,
    /// The plan's derived state for this track (`ready` / `executing` /
    /// `waiting` / `blocked` / `satisfied` / `claim_only` / `cancelled`),
    /// from the situation builder. `None` when the track is mission-only and
    /// the project has no plan row for it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub derived_state: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct TracksQuery {
    /// Optional: restrict to one project.
    #[serde(default)]
    pub project: Option<String>,
}

/// GET /api/control/tracks — roll missions up by (project, track). Untagged
/// missions (no project and no track) are omitted. Scans newest-first up to a
/// bounded ceiling.
pub async fn list_tracks(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Query(query): Query<TracksQuery>,
) -> Result<Json<Vec<TrackSummary>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    const PAGE: usize = 200;
    const MAX_SCAN: usize = 5_000;

    // Preserve newest-first arrival order of groups, and let the first (most
    // recent) mission seed each track's desired_state/github_pr/next_check_at.
    let mut order: Vec<(String, String)> = Vec::new();
    let mut groups: std::collections::HashMap<(String, String), TrackSummary> =
        std::collections::HashMap::new();

    let mut offset = 0usize;
    while offset < MAX_SCAN {
        let page = control
            .mission_store
            .list_missions(PAGE, offset)
            .await
            .map_err(internal_error)?;
        let page_len = page.len();
        for m in page {
            let proj = m.project.project.clone();
            let track = m.project.track.clone();
            if proj.is_none() && track.is_none() {
                continue; // untagged — not part of any track
            }
            if let Some(want) = query.project.as_deref() {
                if proj.as_deref() != Some(want) {
                    continue;
                }
            }
            let key = (
                proj.clone().unwrap_or_default(),
                track.clone().unwrap_or_default(),
            );
            let entry = groups.entry(key.clone()).or_insert_with(|| {
                order.push(key.clone());
                TrackSummary {
                    project: proj.clone(),
                    track: track.clone(),
                    total: 0,
                    active: 0,
                    pending: 0,
                    awaiting_user: 0,
                    last_activity_at: None,
                    latest_terminal_at: None,
                    desired_state: None,
                    github_pr: None,
                    next_check_at: None,
                    derived_state: None,
                }
            });
            entry.total += 1;
            match m.status {
                MissionStatus::Active => entry.active += 1,
                MissionStatus::Pending => entry.pending += 1,
                MissionStatus::AwaitingUser => entry.awaiting_user += 1,
                _ => {}
            }
            // Missions arrive newest-first, so the first non-None value wins
            // (most recent). last_activity_at is the first (max) updated_at.
            if entry.last_activity_at.is_none() {
                entry.last_activity_at = Some(m.updated_at.clone());
            }
            if entry.latest_terminal_at.is_none() && m.status.is_terminal() {
                entry.latest_terminal_at = Some(m.updated_at.clone());
            }
            if entry.desired_state.is_none() {
                entry.desired_state = m.project.desired_state.clone();
            }
            if entry.github_pr.is_none() {
                entry.github_pr = m.project.github_pr.clone();
            }
            if entry.next_check_at.is_none() {
                entry.next_check_at = m.project.next_check_at.clone();
            }
        }
        if page_len < PAGE {
            break;
        }
        offset += PAGE;
    }

    let mut tracks = order
        .into_iter()
        .filter_map(|k| groups.remove(&k))
        .collect::<Vec<_>>();

    // Projection of the situation builder: the same derived state every
    // other surface renders, looked up once per project.
    let mut situations: std::collections::HashMap<
        String,
        std::collections::HashMap<String, String>,
    > = std::collections::HashMap::new();
    for summary in &mut tracks {
        let (Some(project), Some(track)) = (summary.project.as_deref(), summary.track.as_deref())
        else {
            continue;
        };
        if !situations.contains_key(project) {
            let situation =
                crate::api::projects_overview::load_project_situation(&state, project).await;
            situations.insert(
                project.to_string(),
                situation
                    .items
                    .into_iter()
                    .map(|item| (item.key, item.derived_state.as_str().to_string()))
                    .collect(),
            );
        }
        summary.derived_state = situations
            .get(project)
            .and_then(|states| states.get(track))
            .cloned();
    }
    Ok(Json(tracks))
}

/// Enrich missions with computed activity timestamps (P#5): the most recent
/// event and assistant output from the event log, plus a `last_activity_at`
/// convenience = max(updated_at, last_agent_event_at). Best-effort: a store
/// without an event log (or a failed query) leaves the computed fields unset.
pub(super) async fn populate_activity(control: &ControlState, missions: &mut [Mission]) {
    if missions.is_empty() {
        return;
    }
    let ids: Vec<Uuid> = missions.iter().map(|m| m.id).collect();
    let activity = match control.mission_store.get_mission_activity(&ids).await {
        Ok(map) => map,
        Err(e) => {
            tracing::warn!("Failed to load mission activity: {}", e);
            return;
        }
    };
    let now = chrono::Utc::now();
    let capacity = control.dispatch_capacity.read().await.clone();
    for mission in missions.iter_mut() {
        if let Some((last_event, last_output)) = activity.get(&mission.id) {
            mission.activity.last_agent_event_at = last_event.clone();
            mission.activity.last_output_at = last_output.clone();
        }
        // last_activity_at = the most recent of updated_at and the newest event.
        let last_activity = [
            Some(mission.updated_at.clone()),
            mission.activity.last_agent_event_at.clone(),
        ]
        .into_iter()
        .flatten()
        .max();
        mission.activity.last_activity_at = last_activity;

        // Staleness is server-computed so consumers (LLM orchestrators
        // especially) read a verdict word instead of doing timestamp math —
        // in practice they don't, and idle workers go unnoticed for hours.
        let idle_seconds = mission
            .activity
            .last_activity_at
            .as_deref()
            .and_then(|ts| chrono::DateTime::parse_from_rfc3339(ts).ok())
            .map(|ts| (now - ts.with_timezone(&chrono::Utc)).num_seconds().max(0) as u64);
        mission.activity.idle_seconds = idle_seconds;
        mission.activity.idle_for = idle_seconds.map(humanize_idle);
        mission.activity.queue_wait =
            super::dispatch_capacity::queue_wait_for(mission, capacity.as_ref(), now);
        mission.activity.health_verdict = idle_seconds
            .and_then(|idle| {
                activity_verdict(mission.status, idle, mission.activity.queue_wait.as_ref())
            })
            .map(str::to_string);
    }
}

/// `mission_health_verdict`, except a mission waiting for a parallel slot
/// reads `waiting_for_slot`: waiting its turn is not stuck, however long.
pub(crate) fn activity_verdict(
    status: MissionStatus,
    idle_seconds: u64,
    queue_wait: Option<&super::super::mission_store::QueueWait>,
) -> Option<&'static str> {
    if queue_wait.is_some() {
        return Some("waiting_for_slot");
    }
    mission_health_verdict(status, idle_seconds)
}

/// Render a duration in seconds as a compact human string ("45s", "12m",
/// "2h30m", "16h", "3d"). Meant for LLM/UI consumption, not parsing.
pub(crate) fn humanize_idle(seconds: u64) -> String {
    if seconds < 60 {
        return format!("{}s", seconds);
    }
    let minutes = seconds / 60;
    if minutes < 60 {
        return format!("{}m", minutes);
    }
    let hours = minutes / 60;
    if hours < 24 {
        let rem_minutes = minutes % 60;
        if hours < 6 && rem_minutes > 0 {
            return format!("{}h{:02}m", hours, rem_minutes);
        }
        return format!("{}h", hours);
    }
    format!("{}d", hours / 24)
}

/// Server-side staleness verdict for a mission given its status and idle time.
/// Returns `None` for terminal statuses — a finished mission is not "stalled",
/// however old it is. Thresholds are deliberately coarse: the point is to make
/// "this worker has produced nothing for hours" jump out of a listing, not to
/// diagnose precisely why.
pub(crate) fn mission_health_verdict(
    status: MissionStatus,
    idle_seconds: u64,
) -> Option<&'static str> {
    const QUIET_AFTER: u64 = 300; // 5 min without events while active
    const STALLED_AFTER: u64 = 1800; // 30 min: something is wrong
    const QUEUE_STUCK_AFTER: u64 = 900; // pending that never dispatched
    const BACKGROUND_STALLED_AFTER: u64 = 21_600; // 6h of background work

    let verdict = match status {
        MissionStatus::Active => {
            if idle_seconds < QUIET_AFTER {
                "working"
            } else if idle_seconds < STALLED_AFTER {
                "quiet"
            } else {
                "stalled"
            }
        }
        MissionStatus::Pending => {
            if idle_seconds < QUEUE_STUCK_AFTER {
                "queued"
            } else {
                "stuck_queued"
            }
        }
        MissionStatus::AwaitingUser | MissionStatus::Acknowledged => {
            if idle_seconds < STALLED_AFTER {
                "parked"
            } else {
                "stalled_parked"
            }
        }
        MissionStatus::WaitingBackground => {
            if idle_seconds < BACKGROUND_STALLED_AFTER {
                "waiting_background"
            } else {
                "stalled_background"
            }
        }
        MissionStatus::Paused => "paused",
        MissionStatus::Completed
        | MissionStatus::Failed
        | MissionStatus::Interrupted
        | MissionStatus::Blocked
        | MissionStatus::NotFeasible => return None,
    };
    Some(verdict)
}

pub(super) async fn populate_workspace_names(state: &Arc<AppState>, missions: &mut [Mission]) {
    for mission in missions {
        if let Some(workspace) = state.workspaces.get(mission.workspace_id).await {
            mission.workspace_name = Some(workspace.name);
        }
    }
}
