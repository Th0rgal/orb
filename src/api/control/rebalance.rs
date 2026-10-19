//! Queued-job rebalancing.
//!
//! Auto placement picks the least loaded node at creation time, but a node can
//! fill up between that choice and the job's start, and another node can free
//! up while the job waits in the first node's queue (incident 9304baf4: a
//! mission waited on a full babylon while old-agent sat idle).
//!
//! Every [`SCAN_SECS`] this loop looks at accepted mission jobs that are still
//! `queued` on their node with no `started_at` after [`QUEUED_THRESHOLD_SECS`].
//! When the mission was auto-placed (explicit nodes are never moved), is on its
//! first turn with no node-bound workspace, and another eligible node has a
//! free slot, the not-yet-started job is cancelled and re-dispatched there.
//! A job that started in the meantime is left alone. Every rebalance is logged.
use super::*;

pub(super) const QUEUED_THRESHOLD_SECS: i64 = 90;
const SCAN_SECS: u64 = 30;

fn auto_dir(working_dir: &std::path::Path) -> std::path::PathBuf {
    working_dir.join("remote_node").join("auto_placement")
}

fn superseded_dir(working_dir: &std::path::Path) -> std::path::PathBuf {
    working_dir.join("remote_node").join("rebalanced_jobs")
}

/// Remember that a mission was placed by `remote_node_id: "auto"` and with
/// which label requirements. Only such missions may be moved.
pub(super) fn record_auto(
    working_dir: &std::path::Path,
    mission_id: Uuid,
    requirements: &[String],
) -> std::io::Result<()> {
    let dir = auto_dir(working_dir);
    std::fs::create_dir_all(&dir)?;
    std::fs::write(
        dir.join(format!("{mission_id}.json")),
        serde_json::to_vec(requirements)?,
    )
}

pub(super) fn auto_requirements(
    working_dir: &std::path::Path,
    mission_id: Uuid,
) -> Option<Vec<String>> {
    let raw = std::fs::read(auto_dir(working_dir).join(format!("{mission_id}.json"))).ok()?;
    serde_json::from_slice(&raw).ok()
}

/// Mark a cancelled job as moved, so its poller retires it quietly instead of
/// finalizing the mission as failed.
fn mark_superseded(working_dir: &std::path::Path, job_id: Uuid) -> std::io::Result<()> {
    let dir = superseded_dir(working_dir);
    std::fs::create_dir_all(&dir)?;
    std::fs::write(dir.join(job_id.to_string()), b"")
}

pub(super) fn is_superseded(working_dir: &std::path::Path, job_id: Uuid) -> bool {
    superseded_dir(working_dir)
        .join(job_id.to_string())
        .exists()
}

fn node_load(heartbeat: &crate::remote_node::protocol::NodeHeartbeat) -> u32 {
    heartbeat.active_jobs + heartbeat.queued_jobs + heartbeat.active_leases
}

/// The node with a free slot (load below capacity) that satisfies the
/// mission's placement requirements, least loaded first. `None` when the
/// current node is itself not full or nothing better exists.
pub(super) fn pick_target(
    nodes: &[crate::remote_node::RemoteNodeConfig],
    status: &dyn Fn(&str) -> Option<crate::remote_node::CachedNodeStatus>,
    cordoned: &dyn Fn(&str) -> bool,
    current: &str,
    requirements: &[String],
) -> Option<String> {
    let usable = |node: &crate::remote_node::RemoteNodeConfig| {
        let cached = status(&node.id)?;
        if cached.status != crate::remote_node::RemoteNodeStatus::Online {
            return None;
        }
        let heartbeat = cached.last_heartbeat?;
        let labels: &[String] = if heartbeat.labels.is_empty() {
            node.labels.as_deref().unwrap_or(&[])
        } else {
            &heartbeat.labels
        };
        if !requirements.iter().all(|req| labels.contains(req)) {
            return None;
        }
        Some(heartbeat)
    };
    // Only rebalance away from a node that is actually full.
    if let Some(heartbeat) = nodes
        .iter()
        .find(|node| node.id == current)
        .and_then(|node| status(&node.id))
        .and_then(|cached| cached.last_heartbeat)
    {
        if node_load(&heartbeat) < heartbeat.capacity_total {
            return None;
        }
    }
    nodes
        .iter()
        .filter(|node| node.id != current && !cordoned(&node.id))
        .filter_map(|node| {
            let heartbeat = usable(node)?;
            let load = node_load(&heartbeat);
            (heartbeat.capacity_total > 0 && load < heartbeat.capacity_total).then(|| {
                (
                    load as f64 / heartbeat.capacity_total as f64,
                    node.id.clone(),
                )
            })
        })
        .min_by(|a, b| a.0.total_cmp(&b.0).then_with(|| a.1.cmp(&b.1)))
        .map(|(_, id)| id)
}

/// First turn with no node-bound workspace: nothing exists on the old node
/// that the new one would lack.
pub(super) fn mission_is_movable(mission: &Mission, user_turns: usize) -> bool {
    user_turns <= 1
        && mission.working_directory.is_none()
        && !mission
            .project
            .tags
            .iter()
            .any(|tag| tag.starts_with("fork-workspace:"))
        && matches!(
            mission.status,
            MissionStatus::Active | MissionStatus::Pending
        )
}

pub fn spawn_queued_job_rebalancer(state: Arc<AppState>) {
    if !state.config.remote_nodes.enabled || state.config.remote_nodes.nodes.len() < 2 {
        return;
    }
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(SCAN_SECS)).await;
            if super::super::routes::is_shutdown_initiated() {
                return;
            }
            if let Err(error) = scan(&state).await {
                tracing::warn!(%error, "queued-job rebalance scan failed");
            }
        }
    });
}

async fn scan(state: &Arc<AppState>) -> Result<(), String> {
    let working_dir = state.config.working_dir.clone();
    let handles = crate::remote_node::job_ledger::load(&working_dir)
        .await
        .map_err(|e| e.to_string())?;
    let now = chrono::Utc::now();
    for handle in handles {
        if handle.kind != crate::remote_node::job_ledger::JobHandleKind::Mission
            || handle.accepted_at.is_none()
            || (now - handle.started_at).num_seconds() < QUEUED_THRESHOLD_SECS
        {
            continue;
        }
        let Some(requirements) = auto_requirements(&working_dir, handle.mission_id) else {
            continue;
        };
        if let Err(error) = try_rebalance(state, &handle, &requirements).await {
            tracing::debug!(mission_id = %handle.mission_id, job_id = %handle.job_id, %error, "queued job not rebalanced");
        }
    }
    Ok(())
}

async fn try_rebalance(
    state: &Arc<AppState>,
    handle: &crate::remote_node::job_ledger::JobHandle,
    requirements: &[String],
) -> Result<(), String> {
    let settings = &state.config.remote_nodes;
    let old = settings
        .node(&handle.node_id)
        .ok_or("old node is no longer configured")?
        .clone();
    let client = crate::remote_node::RemoteNodeClient::default();
    let old_token = std::env::var(&old.token_env).map_err(|e| e.to_string())?;
    let status = client
        .get_job(&old, &old_token, handle.job_id)
        .await
        .map_err(|e| e.to_string())?;
    if status.state != "queued" || status.started_at.is_some() {
        return Ok(());
    }
    let fleet = state.fleet.clone();
    let Some(target) = pick_target(
        &settings.nodes,
        &|id| fleet.get(id),
        &|id| fleet.is_cordoned(id),
        &old.id,
        requirements,
    ) else {
        return Ok(());
    };
    let mut owner = None;
    for (user_id, session) in state.control.all_sessions_with_users().await {
        if let Ok(Some(mission)) = session.mission_store.get_mission(handle.mission_id).await {
            owner = Some((user_id, session, mission));
            break;
        }
    }
    let (_user_id, control, mission) = owner.ok_or("owning session not booted")?;
    let prompts = control
        .mission_store
        .get_events(mission.id, Some(&["user_message"]), None, None)
        .await?;
    if !mission_is_movable(&mission, prompts.len()) {
        return Ok(());
    }
    let prompt = prompts
        .first()
        .map(|event| event.content.clone())
        .ok_or("first prompt is not persisted")?;
    let mut plan = plan_remote_harness(
        None,
        &mission.backend,
        mission.model_override.as_deref(),
        Some(&prompt),
    )?;
    if let RemoteHarnessPlan::Codex {
        effort, fast_mode, ..
    } = &mut plan
    {
        *effort = mission.model_effort.clone();
        *fast_mode = mission.fast_mode;
    }
    if let RemoteHarnessPlan::Antigravity { effort, .. } = &mut plan {
        *effort = mission.model_effort.clone();
    }
    remote_grok::require_node_managed_auth(state, &target, &plan).await?;

    {
        let _admission = DISPATCH_ADMISSION.lock().await;
        let _file = dispatch_admission::durable_lock(&state.config).await?;
        // Re-check under admission: the job may have been delivered,
        // cancelled or superseded since the scan observed it.
        let placement = remote_grok::placement(
            &state.config.working_dir,
            &control.mission_store,
            mission.id,
        )
        .await?
        .ok_or("placement disappeared")?;
        if placement.job_id != handle.job_id || placement.node_id != old.id {
            return Ok(());
        }
        mark_superseded(&state.config.working_dir, handle.job_id).map_err(|e| e.to_string())?;
        let cancelled = client
            .cancel_job_with_reason(
                &old,
                &old_token,
                handle.job_id,
                "core:rebalancer",
                "rebalanced to a node with free capacity before start",
            )
            .await
            .map_err(|e| e.to_string())?;
        let confirmed = client
            .get_job(&old, &old_token, handle.job_id)
            .await
            .map_err(|e| e.to_string())?;
        if cancelled.state != "cancelled"
            || confirmed.state != "cancelled"
            || confirmed.started_at.is_some()
        {
            // Started in between: the cancel token may have stopped it, but it
            // ran, so its workspace exists. Let the poller report it normally.
            let _ = std::fs::remove_file(
                superseded_dir(&state.config.working_dir).join(handle.job_id.to_string()),
            );
            tracing::warn!(mission_id = %mission.id, job_id = %handle.job_id, node = %old.id, state = %confirmed.state, "rebalance aborted: job started before it could be withdrawn");
            return Ok(());
        }
        finish_remote_job_lease(
            control.mission_store.as_ref(),
            mission.id,
            handle.job_id,
            "rebalanced_before_start",
        )
        .await?;
        crate::remote_node::job_ledger::remove(&state.config.working_dir, handle.job_id).await;
    }
    let waited = (chrono::Utc::now() - handle.started_at).num_seconds();
    let mission = control
        .mission_store
        .get_mission(mission.id)
        .await?
        .ok_or("mission disappeared")?;
    match dispatch_remote_job(state, &control, &mission, &target, &plan, None, None).await {
        Ok(_) => {
            tracing::info!(
                mission_id = %mission.id,
                old_job_id = %handle.job_id,
                from = %old.id,
                to = %target,
                waited_secs = waited,
                "rebalanced queued remote job to a node with free capacity"
            );
            Ok(())
        }
        Err(error) => {
            tracing::error!(mission_id = %mission.id, old_job_id = %handle.job_id, from = %old.id, to = %target, %error, "rebalance re-dispatch failed after withdrawing the queued job");
            Err(error)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote_node::{CachedNodeStatus, RemoteNodeConfig, RemoteNodeStatus};

    fn node(id: &str, labels: &[&str]) -> RemoteNodeConfig {
        serde_json::from_value(serde_json::json!({
            "id": id, "base_url": "http://127.0.0.1:9", "token_env": "X",
            "labels": labels,
        }))
        .unwrap()
    }

    fn cached(id: &str, total: u32, active: u32, queued: u32, labels: &[&str]) -> CachedNodeStatus {
        let heartbeat = serde_json::from_value(serde_json::json!({
            "node_id": id, "online": true, "capacity_total": total,
            "capacity_available": total.saturating_sub(active), "active_leases": 0,
            "version": "t", "active_jobs": active, "queued_jobs": queued, "labels": labels,
        }))
        .unwrap();
        CachedNodeStatus {
            node_id: id.to_string(),
            status: RemoteNodeStatus::Online,
            consecutive_misses: 0,
            resource_history: Default::default(),
            last_heartbeat: Some(heartbeat),
            last_seen: None,
            last_probe_started_at: None,
            last_error: None,
        }
    }

    #[test]
    fn moves_only_off_a_full_node_onto_an_eligible_free_one() {
        let nodes = vec![
            node("babylon", &["linux"]),
            node("old-agent", &["linux"]),
            node("gpu", &["linux", "gpu"]),
            node("macbox", &["mac"]),
        ];
        let statuses: HashMap<String, CachedNodeStatus> = [
            cached("babylon", 2, 2, 1, &[]),
            cached("old-agent", 2, 0, 0, &[]),
            cached("gpu", 4, 3, 0, &[]),
            cached("macbox", 4, 0, 0, &[]),
        ]
        .into_iter()
        .map(|c| (c.node_id.clone(), c))
        .collect();
        let status = |id: &str| statuses.get(id).cloned();
        let none = |_: &str| false;
        let linux = vec!["linux".to_string()];
        assert_eq!(
            pick_target(&nodes, &status, &none, "babylon", &linux).as_deref(),
            Some("old-agent")
        );
        // Cordoned nodes are never a target.
        let cordon = |id: &str| id == "old-agent";
        assert_eq!(
            pick_target(&nodes, &status, &cordon, "babylon", &linux).as_deref(),
            Some("gpu")
        );
        // Requirements are honored.
        let gpu = vec!["gpu".to_string()];
        assert_eq!(
            pick_target(&nodes, &status, &none, "babylon", &gpu).as_deref(),
            Some("gpu")
        );
        let impossible = vec!["mac".to_string(), "gpu".to_string()];
        assert_eq!(
            pick_target(&nodes, &status, &none, "babylon", &impossible),
            None
        );
        // A node that still has a free slot is not "full": leave the job.
        assert_eq!(
            pick_target(&nodes, &status, &none, "old-agent", &linux),
            None
        );
    }

    #[test]
    fn auto_record_and_supersession_marker_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let mission = Uuid::new_v4();
        assert!(auto_requirements(dir.path(), mission).is_none());
        record_auto(dir.path(), mission, &["linux".into()]).unwrap();
        assert_eq!(
            auto_requirements(dir.path(), mission),
            Some(vec!["linux".to_string()])
        );
        let job = Uuid::new_v4();
        assert!(!is_superseded(dir.path(), job));
        mark_superseded(dir.path(), job).unwrap();
        assert!(is_superseded(dir.path(), job));
    }

    #[tokio::test]
    async fn only_first_turn_missions_without_node_workspace_move() {
        let store = crate::api::mission_store::InMemoryMissionStore::new();
        let mut mission = store
            .create_mission(None, None, None, None, None, Some("codex"), None)
            .await
            .unwrap();
        mission.status = MissionStatus::Active;
        assert!(mission_is_movable(&mission, 1));
        assert!(
            !mission_is_movable(&mission, 2),
            "later turns resume node state"
        );
        let mut pinned = mission.clone();
        pinned.working_directory = Some("/srv/repo".into());
        assert!(!mission_is_movable(&pinned, 1));
        let mut fork = mission.clone();
        fork.project.tags = vec!["fork-workspace:abc".into()];
        assert!(!mission_is_movable(&fork, 1));
        let mut done = mission;
        done.status = MissionStatus::Interrupted;
        assert!(!mission_is_movable(&done, 1));
    }
}
