//! Mission read handlers (get, digest, integrity) and cross-store projections.

use super::*;

#[derive(Debug, Clone, Copy, Deserialize)]
pub struct GetMissionQuery {
    /// When `false`, omit the embedded 200-entry `history` transcript array
    /// (`mission.history = []`) while keeping all status, run, placement,
    /// continuation, and terminal-evidence metadata. Defaults to `true` for
    /// backward compatibility with MCP, CLI, and continuation builders.
    #[serde(default = "default_include_mission_history")]
    pub include_history: bool,
}

impl Default for GetMissionQuery {
    fn default() -> Self {
        Self {
            include_history: true,
        }
    }
}

fn default_include_mission_history() -> bool {
    true
}

impl GetMissionQuery {
    pub const fn metadata_only() -> Self {
        Self {
            include_history: false,
        }
    }
}

/// Get a specific mission (default full history projection for internal Rust callers).
pub async fn get_mission(
    state: State<Arc<AppState>>,
    user: Extension<AuthUser>,
    path: Path<Uuid>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    get_mission_with_query(
        state,
        user,
        path,
        axum::extract::Query(GetMissionQuery::default()),
    )
    .await
}

/// Get a specific mission with optional query projection (`?include_history=false`).
pub async fn get_mission_with_query(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    axum::extract::Query(query): axum::extract::Query<GetMissionQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let loaded = if query.include_history {
        control.mission_store.get_mission(id).await
    } else {
        control
            .mission_store
            .get_mission_metadata(id)
            .await
            .map(|opt| {
                opt.map(|mut m| {
                    m.history.clear();
                    m
                })
            })
    };
    match loaded.map_err(internal_error)? {
        Some(mut mission) => {
            if mission.backend.starts_with("cloud_") {
                let (executions_res, continuations_res) = tokio::join!(
                    control.mission_store.cloud_executions(),
                    continuations::summaries(&control.mission_store),
                );
                let execution = executions_res
                    .map_err(internal_error)?
                    .into_iter()
                    .find(|e| e.mission_id == id)
                    .ok_or_else(|| {
                        (
                            StatusCode::CONFLICT,
                            "Hosted receipt missing; do not launch a replacement".into(),
                        )
                    })?;
                let mut value = serde_json::to_value(&mission).map_err(internal_error)?;
                value["execution_kind"] = serde_json::json!("hosted");
                value["cloud"] = serde_json::to_value(execution).map_err(internal_error)?;
                continuations::attach_capabilities(
                    &mut value,
                    state.config.automations_enabled && control.mission_store.is_persistent(),
                );
                value["continuation"] = continuations_res
                    .map_err(internal_error)?
                    .remove(&id)
                    .unwrap_or(serde_json::Value::Null);
                return Ok(Json(value));
            }

            let mission_id = mission.id;
            let workspace_id = mission.workspace_id;
            let ids = [mission_id];
            let run_info_fut = async {
                let active_run = control
                    .mission_store
                    .get_active_mission_run(mission_id)
                    .await
                    .map_err(internal_error)?;
                match active_run {
                    Some(run) => {
                        let wait_started_at =
                            user_wait_tool_started_at(control.mission_store.as_ref(), &run).await;
                        let placement_run = Some(run.clone());
                        Ok::<_, (StatusCode, String)>((Some(run), wait_started_at, placement_run))
                    }
                    None => {
                        let placement_run = control
                            .mission_store
                            .get_latest_mission_run(mission_id)
                            .await
                            .map_err(internal_error)?;
                        Ok((None, None, placement_run))
                    }
                }
            };
            let (
                workspace,
                activity_inputs,
                callback_parents,
                run_info_res,
                recovery,
                continuations_res,
                (handles, outcomes),
                committed_transfer_res,
            ) = tokio::join!(
                state.workspaces.get(workspace_id),
                load_activity_inputs(&control, &ids),
                callback_parent::links(std::slice::from_ref(&mission), &control.mission_store),
                run_info_fut,
                usage_limit_wait::remote_wait(&state.config.working_dir, id),
                continuations::summaries(&control.mission_store),
                remote_job_projection_inputs(&state),
                machine_transfer::committed(&control.mission_store, id),
            );

            // Populate workspace_name + spark_offload from the workspace (P#7).
            if let Some(ws) = workspace.as_ref() {
                mission.workspace_name = Some(ws.name.clone());
            }
            let mut one = [mission];
            apply_activity_inputs(&mut one, activity_inputs);
            let [mission] = one;

            // Serialize then attach the computed spark_offload block so Paloma
            // can route heavy builds without probing the host each time.
            let (active_run, wait_started_at, placement_run) = run_info_res?;
            let mut value = attach_execution_to_mission_value(
                serde_json::to_value(&mission).map_err(internal_error)?,
                &mission,
                active_run.as_ref(),
                wait_started_at.as_deref(),
            );
            usage_limit_wait::attach_recovery(&mut value, recovery.as_ref());
            if let Some(parent) = callback_parents.get(&id) {
                value["callback_parent_mission_id"] = serde_json::json!(parent);
            }
            continuations::attach_capabilities(
                &mut value,
                state.config.automations_enabled && control.mission_store.is_persistent(),
            );
            value["continuation"] = continuations_res
                .map_err(internal_error)?
                .remove(&id)
                .unwrap_or(serde_json::Value::Null);
            // Remote placement must be visible on the read model: the row's
            // workspace/backend describe a local harness that a raw remote
            // mission never runs.
            value = attach_remote_job_to_mission_value(
                value,
                remote_job_projection(
                    &handles,
                    &outcomes,
                    placement_run.as_ref(),
                    mission.id,
                    chrono::Utc::now(),
                ),
            );
            if let Some(t) = committed_transfer_res.map_err(internal_error)? {
                machine_transfer::project(&mut value, &t);
            }
            let host_configured =
                state.config.spark_arbiter_url.is_some() || state.config.spark_ssh_target.is_some();
            let enabled = workspace
                .as_ref()
                .map(|ws| ws.spark_offload_enabled())
                .unwrap_or(false);
            let env_injected = workspace
                .as_ref()
                .map(|ws| ws.spark_offload_env(mission.id).is_some())
                .unwrap_or(false);
            if let Some(obj) = value.as_object_mut() {
                obj.insert(
                    "spark_offload".to_string(),
                    serde_json::json!({
                        "enabled": enabled,
                        "env_injected": env_injected,
                        "host_configured": host_configured,
                    }),
                );
            }
            Ok(Json(value))
        }
        None => {
            // Cross-tenant read-only fallback. The PR-writer lease check is
            // deliberately GLOBAL across mission stores, so a lease refusal can
            // name a holder that lives in another tenant's store. Without this
            // fallback that holder reads as 404 — indistinguishable from a
            // ghost — and controllers deadlock instead of resuming/acking it
            // (observed 2026-08-01 on the Verity two-phase controller). Serve a
            // bounded projection: enough to see status/ownership, no transcript.
            if let Some(value) = find_mission_projection_in_any_store(&state.control, id)
                .await
                .map_err(internal_error)?
            {
                return Ok(Json(value));
            }
            Err((StatusCode::NOT_FOUND, format!("Mission {} not found", id)))
        }
    }
}

/// Locate a mission by id across every mission store (read-only) and return
/// the bounded cross-tenant projection. The PR-writer lease check is global
/// across stores, so lease holders must be inspectable across stores too —
/// but only as a projection: no transcript, no control surface.
pub(super) async fn find_mission_projection_in_any_store(
    control_hub: &ControlHub,
    id: Uuid,
) -> Result<Option<serde_json::Value>, String> {
    use futures::stream::{self, StreamExt};

    let inventory = control_hub.mission_store_inventory().await?;
    let live_results =
        futures::future::try_join_all(inventory.live.iter().map(|store| store.get_mission(id)))
            .await?;
    if let Some(mission) = live_results.into_iter().flatten().next() {
        return Ok(Some(cross_tenant_mission_projection(
            &mission.id.to_string(),
            &mission.status,
            mission.title.as_deref(),
            Some(&mission.workspace_id.to_string()),
            Some(&mission.backend),
            &mission.created_at,
            &mission.updated_at,
        )));
    }

    if !inventory.offline_file_users.is_empty() {
        let base_dir = inventory.base_dir.clone();
        let file_results: Vec<Result<Option<Mission>, String>> =
            stream::iter(inventory.offline_file_users)
                .map(|user| {
                    let base_dir = base_dir.clone();
                    async move {
                        let store: Arc<dyn MissionStore> =
                            Arc::new(mission_store::FileMissionStore::new(base_dir, &user).await?);
                        store.get_mission(id).await
                    }
                })
                .buffered(8)
                .collect()
                .await;
        for res in file_results {
            if let Some(mission) = res? {
                return Ok(Some(cross_tenant_mission_projection(
                    &mission.id.to_string(),
                    &mission.status,
                    mission.title.as_deref(),
                    Some(&mission.workspace_id.to_string()),
                    Some(&mission.backend),
                    &mission.created_at,
                    &mission.updated_at,
                )));
            }
        }
    }

    if !inventory.offline_sqlite.is_empty() {
        let sqlite_results: Vec<Result<Option<serde_json::Value>, String>> =
            stream::iter(inventory.offline_sqlite)
                .map(|path| async move {
                    tokio::task::spawn_blocking(move || {
                        load_mission_projection_from_sqlite(&path, id)
                    })
                    .await
                    .map_err(|error| error.to_string())?
                })
                .buffered(8)
                .collect()
                .await;
        for res in sqlite_results {
            if let Some(found) = res? {
                return Ok(Some(found));
            }
        }
    }
    Ok(None)
}

pub(super) fn cross_tenant_mission_projection(
    id: &str,
    status: &MissionStatus,
    title: Option<&str>,
    workspace_id: Option<&str>,
    backend: Option<&str>,
    created_at: &str,
    updated_at: &str,
) -> serde_json::Value {
    serde_json::json!({
        "id": id,
        "status": status,
        "title": title,
        "workspace_id": workspace_id,
        "backend": backend,
        "created_at": created_at,
        "updated_at": updated_at,
        "cross_tenant": true,
        "read_only": true,
        "note": "mission belongs to another mission store; transcript and control operations are not exposed here",
    })
}

pub(super) fn collect_project_missions_from_sqlite(
    path: &std::path::Path,
    terminal_cutoff_rfc3339: &str,
) -> Result<Vec<Mission>, String> {
    let connection =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|error| format!("open {} read-only: {error}", path.display()))?;
    let _ = connection.busy_timeout(std::time::Duration::from_secs(10));
    let columns: std::collections::HashSet<String> = connection
        .prepare("SELECT name FROM pragma_table_info('missions')")
        .and_then(|mut st| {
            st.query_map([], |row| row.get::<_, String>(0))
                .map(|rows| rows.filter_map(Result::ok).collect())
        })
        .map_err(|error| error.to_string())?;
    if !columns.contains("project") {
        return Ok(Vec::new());
    }
    let mut statement = connection
        .prepare(
            "SELECT id, status, title, workspace_id, backend, created_at, updated_at, \
             project, track, intent, github_pr \
             FROM missions WHERE project IS NOT NULL",
        )
        .map_err(|error| error.to_string())?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, Option<String>>(8)?,
                row.get::<_, Option<String>>(9)?,
                row.get::<_, Option<String>>(10)?,
            ))
        })
        .map_err(|error| error.to_string())?;
    let mut collected = Vec::new();
    for row in rows {
        let (
            id,
            status,
            title,
            workspace_id,
            backend,
            created_at,
            updated_at,
            project,
            track,
            intent,
            github_pr,
        ) = row.map_err(|error| error.to_string())?;
        let Ok(id) = Uuid::parse_str(&id) else {
            continue;
        };
        let status = serde_json::from_value::<MissionStatus>(serde_json::Value::String(status))
            .unwrap_or(MissionStatus::Active);
        let updated_at = updated_at.unwrap_or_default();
        if (status.is_terminal() || status == MissionStatus::Acknowledged)
            && updated_at.as_str() < terminal_cutoff_rfc3339
        {
            continue;
        }
        let mut mission: Mission = serde_json::from_value(serde_json::json!({
            "id": id,
            "status": status,
            "workspace_id": workspace_id
                .as_deref()
                .and_then(|raw| Uuid::parse_str(raw).ok())
                .unwrap_or_else(Uuid::nil),
            "backend": backend.unwrap_or_default(),
            "history": [],
            "created_at": created_at.unwrap_or_default(),
            "updated_at": updated_at,
        }))
        .map_err(|error| error.to_string())?;
        mission.title = title;
        mission.project.project = project;
        mission.project.track = track;
        mission.project.intent = intent;
        mission.project.github_pr = github_pr;
        collected.push(mission);
    }
    Ok(collected)
}

/// Read-only attention-horizon slice of one project tag from an offline store.
pub(super) fn collect_attention_missions_from_sqlite(
    path: &std::path::Path,
    project: &str,
) -> Result<Vec<Mission>, String> {
    let connection =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|error| format!("open {} read-only: {error}", path.display()))?;
    let _ = connection.busy_timeout(std::time::Duration::from_secs(10));
    let columns: std::collections::HashSet<String> = connection
        .prepare("SELECT name FROM pragma_table_info('missions')")
        .and_then(|mut st| {
            st.query_map([], |row| row.get::<_, String>(0))
                .map(|rows| rows.filter_map(Result::ok).collect())
        })
        .map_err(|error| error.to_string())?;
    if !columns.contains("project") {
        return Ok(Vec::new());
    }
    let optional = |name: &str| {
        if columns.contains(name) {
            name.to_string()
        } else {
            "NULL".into()
        }
    };
    let sql = format!(
        "SELECT id, status, title, workspace_id, backend, created_at, updated_at, \
         project, track, intent, github_pr, {}, {}, {}, {} \
         FROM missions WHERE project = ?1 AND status NOT IN ('acknowledged', 'completed')",
        optional("tags"),
        optional("awaiting_kind"),
        optional("origin_session_id"),
        optional("last_status_change_at")
    );
    let mut statement = connection
        .prepare(&sql)
        .map_err(|error| error.to_string())?;
    let rows = statement
        .query_map([project], |row| {
            let mut fields = Vec::new();
            for index in 0..15 {
                fields.push(row.get::<_, Option<String>>(index)?);
            }
            Ok(fields)
        })
        .map_err(|error| error.to_string())?;
    let mut collected = Vec::new();
    for row in rows {
        let fields = row.map_err(|error| error.to_string())?;
        let mut fields = fields.into_iter();
        let id = fields.next().flatten().ok_or("missing mission id")?;
        let status_raw = fields.next().flatten().ok_or("missing mission status")?;
        let title = fields.next().flatten();
        let workspace_id = fields.next().flatten();
        let backend = fields.next().flatten();
        let created_at = fields.next().flatten();
        let updated_at = fields.next().flatten();
        let project = fields.next().flatten();
        let track = fields.next().flatten();
        let intent = fields.next().flatten();
        let github_pr = fields.next().flatten();
        let tags_raw = fields.next().flatten();
        let awaiting_kind_raw = fields.next().flatten();
        let origin_session_id = fields.next().flatten();
        let last_status_change_at = fields.next().flatten();
        let id = Uuid::parse_str(&id).map_err(|error| error.to_string())?;
        let status = serde_json::from_value::<MissionStatus>(serde_json::Value::String(status_raw))
            .map_err(|error| error.to_string())?;
        let awaiting_kind = awaiting_kind_raw
            .map(|raw| {
                serde_json::from_value::<AwaitingKind>(serde_json::Value::String(raw))
                    .map_err(|error| error.to_string())
            })
            .transpose()?;
        // A present-but-unparseable kind is a real inventory error (above).
        // A NULL kind is the legacy pre-`awaiting_kind` shape, which the live
        // store also carries as `None` and which operator attention treats as
        // an unqualified page. Erroring here would make the whole project's
        // evidence permanently unavailable for one old row.
        if status == MissionStatus::AwaitingUser && awaiting_kind.is_none() {
            tracing::debug!(
                mission_id = %id,
                "offline awaiting_user mission has no awaiting kind; treating as legacy"
            );
        }
        let tags: Vec<String> = tags_raw
            .as_deref()
            .and_then(|raw| serde_json::from_str(raw).ok())
            .unwrap_or_default();
        let mut mission: Mission = serde_json::from_value(serde_json::json!({
            "id": id,
            "status": status,
            "workspace_id": workspace_id
                .as_deref()
                .and_then(|raw| Uuid::parse_str(raw).ok())
                .unwrap_or_else(Uuid::nil),
            "backend": backend.unwrap_or_default(),
            "history": [],
            "created_at": created_at.unwrap_or_default(),
            "updated_at": updated_at.unwrap_or_default(),
        }))
        .map_err(|error| error.to_string())?;
        mission.title = title;
        mission.project.project = project;
        mission.project.track = track;
        mission.project.intent = intent;
        mission.project.github_pr = github_pr;
        mission.project.tags = tags;
        mission.awaiting_kind = awaiting_kind;
        mission.origin_session_id = origin_session_id;
        mission.activity.last_status_change_at = last_status_change_at;
        if crate::api::mission_store::default_attention_keeps(&mission) {
            collected.push(mission);
        }
    }
    Ok(collected)
}

/// Minimal read-only projection load from an offline sqlite store. Missing
/// columns degrade to null instead of failing the lookup.
pub(super) fn load_mission_projection_from_sqlite(
    path: &std::path::Path,
    id: Uuid,
) -> Result<Option<serde_json::Value>, String> {
    let connection =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|error| format!("open {} read-only: {error}", path.display()))?;
    let _ = connection.busy_timeout(std::time::Duration::from_secs(10));
    let mut statement = connection
        .prepare(
            "SELECT status, title, workspace_id, backend, created_at, updated_at \
             FROM missions WHERE id = ?1 LIMIT 1",
        )
        .map_err(|error| error.to_string())?;
    let mut rows = statement
        .query([id.to_string()])
        .map_err(|error| error.to_string())?;
    let Some(row) = rows.next().map_err(|error| error.to_string())? else {
        return Ok(None);
    };
    let status: String = row.get(0).map_err(|error| error.to_string())?;
    let status = serde_json::from_value::<MissionStatus>(serde_json::Value::String(status))
        .unwrap_or(MissionStatus::Active);
    let title: Option<String> = row.get(1).ok();
    let workspace_id: Option<String> = row.get(2).ok();
    let backend: Option<String> = row.get(3).ok();
    let created_at: String = row.get(4).unwrap_or_default();
    let updated_at: String = row.get(5).unwrap_or_default();
    Ok(Some(cross_tenant_mission_projection(
        &id.to_string(),
        &status,
        title.as_deref(),
        workspace_id.as_deref(),
        backend.as_deref(),
        &created_at,
        &updated_at,
    )))
}

pub(super) fn mission_goal_digest(mission: &Mission) -> serde_json::Value {
    let objective = mission.goal_objective.as_deref().map(|text| {
        let mut snippet: String = text.chars().take(1000).collect();
        if text.chars().count() > 1000 {
            snippet.push('…');
        }
        snippet
    });
    serde_json::json!({
        "mission_mode": mission.mission_mode,
        "goal_mode": mission.goal_mode,
        "goal_objective": objective,
    })
}

/// Compact, orchestrator-friendly view of a mission: status, last exchange,
/// and PR links — without the full transcript. Recap/orchestration sessions
/// previously pulled entire mission histories (multi-KB each) just to answer
/// "where is this mission at?"; this answers the same question in ~2 KB.
pub async fn get_mission_digest(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let Some(mut mission) = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
    else {
        return Err((StatusCode::NOT_FOUND, format!("Mission {} not found", id)));
    };
    let need_workspace = mission.workspace_name.is_none();
    let workspace_id = mission.workspace_id;
    let mission_id = mission.id;
    let run_fut = async {
        let latest_run = control
            .mission_store
            .get_latest_mission_run(mission_id)
            .await
            .map_err(internal_error)?;
        let wait_started_at = match latest_run.as_ref() {
            Some(run) => user_wait_tool_started_at(control.mission_store.as_ref(), run).await,
            None => None,
        };
        Ok::<_, (StatusCode, String)>((latest_run, wait_started_at))
    };
    let workspace_fut = async {
        if need_workspace {
            state.workspaces.get(workspace_id).await.map(|ws| ws.name)
        } else {
            None
        }
    };
    let (resolved_ws_name, run_res, capacity_guard) =
        tokio::join!(workspace_fut, run_fut, control.dispatch_capacity.read(),);
    if need_workspace {
        mission.workspace_name = resolved_ws_name;
    }

    fn truncate_chars(s: &str, max: usize) -> String {
        let total = s.chars().count();
        if total <= max {
            s.to_string()
        } else {
            let cut: String = s.chars().take(max).collect();
            format!("{cut}… [+{} chars truncated]", total - max)
        }
    }

    let last_assistant = mission
        .history
        .iter()
        .rev()
        .find(|e| e.role == "assistant" && !e.content.trim().is_empty())
        .map(|e| truncate_chars(&e.content, 2000));
    let terminal_verdict = mission
        .history
        .iter()
        .rev()
        .find(|entry| entry.role == "assistant" && !entry.content.trim().is_empty())
        .and_then(|entry| terminal_verdict_from_content(&entry.content));
    let last_user = mission
        .history
        .iter()
        .rev()
        .find(|e| e.role == "user")
        .map(|e| truncate_chars(&e.content, 500));

    // GitHub PR links mentioned near the end of the transcript (most recent
    // first, deduped) — the fact orchestrators most often dig transcripts for.
    let mut github_prs: Vec<String> = Vec::new();
    for entry in mission.history.iter().rev().take(10) {
        for word in entry.content.split_whitespace() {
            let word = word.trim_matches(|c: char| {
                !c.is_ascii_alphanumeric() && c != '/' && c != ':' && c != '.'
            });
            if word.starts_with("https://github.com/") && word.contains("/pull/") {
                let url = word.trim_end_matches(|c: char| !c.is_ascii_digit());
                if !url.is_empty() && !github_prs.iter().any(|u| u == url) {
                    github_prs.push(url.to_string());
                }
            }
        }
    }
    let (latest_run, wait_started_at) = run_res?;
    let waiting_for_user_tool = latest_run
        .as_ref()
        .is_some_and(|run| run.execution_state == MissionExecutionState::WaitingUser);
    let execution = latest_run
        .as_ref()
        .map(|run| mission_execution_projection(run, mission.status));

    let remote_placement = super::remote_grok::placement(
        &state.config.working_dir,
        &control.mission_store,
        mission.id,
    )
    .await
    .ok()
    .flatten();
    let remote_node_id = remote_placement
        .as_ref()
        .map(|p| p.node_id.clone())
        .or_else(|| {
            latest_run
                .as_ref()
                .and_then(|r| r.scope_unit.as_deref())
                .and_then(|s| s.strip_prefix("remote-node:"))
                .map(str::to_string)
        });
    let goal = mission_goal_digest(&mission);
    let queue_wait = super::dispatch_capacity::queue_wait_for(
        &mission,
        capacity_guard.as_ref(),
        chrono::Utc::now(),
    );
    Ok(Json(serde_json::json!({
        "id": mission.id,
        "title": mission.title,
        "status": mission.status,
        "awaiting_kind": mission.awaiting_kind.map(|k| k.as_str()),
        "needs_operator": super::super::operator_attention::mission_needs_operator(
            &mission,
            waiting_for_user_tool,
            wait_started_at.as_deref(),
            chrono::Utc::now(),
        ),
        "terminal_reason": mission.terminal_reason,
        "terminal_evidence": mission.terminal_evidence,
        "short_description": mission.short_description,
        "terminal_verdict": terminal_verdict,
        "backend": mission.backend,
        "model_override": mission.model_override,
        "model_effort": mission.model_effort,
        "workspace_id": mission.workspace_id,
        "workspace_name": mission.workspace_name,
        "remote_node_id": remote_node_id,
        "project": mission.project,
        "created_at": mission.created_at,
        "updated_at": mission.updated_at,
        "acknowledged_at": (mission.status == MissionStatus::Acknowledged).then_some(mission.updated_at.clone()),
        "execution": execution,
        "queue_wait": queue_wait,
        "mission_mode": goal["mission_mode"],
        "goal_mode": goal["goal_mode"],
        "goal_objective": goal["goal_objective"],
        "history_len": mission.history.len(),
        "last_user_message": last_user,
        "last_assistant_message": last_assistant,
        "github_prs": github_prs,
    })))
}

/// Fleet integrity report: mission-store anomalies that otherwise fail
/// silently — pending missions nothing will ever dispatch, active missions
/// with no recent progress, and long-idle awaiting_user rows. Read-only;
/// intended for a daily sweep or an on-demand health check (178 orphaned
/// pending missions once accumulated unnoticed before this existed).
pub async fn missions_integrity(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let missions = control
        .mission_store
        .list_missions(5000, 0)
        .await
        .map_err(internal_error)?;
    let now = chrono::Utc::now();
    let age_minutes = |ts: &str| -> i64 {
        chrono::DateTime::parse_from_rfc3339(ts)
            .map(|t| (now - t.with_timezone(&chrono::Utc)).num_minutes())
            .unwrap_or(0)
    };
    let brief = |m: &Mission| {
        serde_json::json!({
            "id": m.id,
            "title": m.title,
            "status": m.status,
            "updated_age_minutes": age_minutes(&m.updated_at),
        })
    };

    // Pending missions: split into scheduler-visible (deferred goal set,
    // waiting on capacity/not_before) vs orphaned (nothing will dispatch them).
    let mut orphaned_pending: Vec<serde_json::Value> = Vec::new();
    let mut scheduled_waiting: Vec<serde_json::Value> = Vec::new();
    let aged_pending: Vec<&Mission> = missions
        .iter()
        .filter(|m| m.status == MissionStatus::Pending && age_minutes(&m.created_at) >= 15)
        .collect();
    let pending_goals: Vec<bool> = {
        use futures::stream::{self, StreamExt};
        let store = &control.mission_store;
        let goal_futs: Vec<_> = aged_pending
            .iter()
            .map(|m| {
                let id = m.id;
                async move { store.get_deferred_goal(id).await.ok().flatten().is_some() }
            })
            .collect();
        stream::iter(goal_futs).buffered(8).collect().await
    };
    for (m, has_goal) in aged_pending.into_iter().zip(pending_goals) {
        if has_goal {
            scheduled_waiting.push(brief(m));
        } else {
            orphaned_pending.push(brief(m));
        }
    }

    let stale_active: Vec<serde_json::Value> = missions
        .iter()
        .filter(|m| m.status == MissionStatus::Active && age_minutes(&m.updated_at) > 24 * 60)
        .map(brief)
        .collect();
    let stale_awaiting: Vec<serde_json::Value> = missions
        .iter()
        .filter(|m| m.status == MissionStatus::AwaitingUser && age_minutes(&m.updated_at) > 72 * 60)
        .map(brief)
        .collect();

    let truncate = |mut v: Vec<serde_json::Value>| -> (usize, Vec<serde_json::Value>) {
        let count = v.len();
        v.truncate(20);
        (count, v)
    };
    let (orphaned_count, orphaned_pending) = truncate(orphaned_pending);
    let (scheduled_count, scheduled_waiting) = truncate(scheduled_waiting);
    let (stale_active_count, stale_active) = truncate(stale_active);
    let (stale_awaiting_count, stale_awaiting) = truncate(stale_awaiting);

    Ok(Json(serde_json::json!({
        "generated_at": now.to_rfc3339(),
        "scanned": missions.len(),
        "healthy": orphaned_count == 0 && stale_active_count == 0,
        "orphaned_pending": { "count": orphaned_count, "missions": orphaned_pending },
        "scheduled_waiting": { "count": scheduled_count, "missions": scheduled_waiting },
        "stale_active": { "count": stale_active_count, "missions": stale_active },
        "stale_awaiting_user": { "count": stale_awaiting_count, "missions": stale_awaiting },
    })))
}
