//! Resolve worker execution where the parent actually runs, not on the API host.
use super::*;
use crate::api::mission_store::{now_string, BoardOutboxItem};

/// Only competing retries of the same dispatch wait for one another.
pub fn dispatch_lock(key: &str) -> Arc<tokio::sync::Mutex<()>> {
    use std::sync::{Mutex, OnceLock, Weak};
    static LOCKS: OnceLock<Mutex<std::collections::HashMap<String, Weak<tokio::sync::Mutex<()>>>>> =
        OnceLock::new();
    let mut locks = LOCKS
        .get_or_init(Default::default)
        .lock()
        .expect("dispatch locks");
    locks.retain(|_, lock| lock.strong_count() > 0);
    if let Some(lock) = locks.get(key).and_then(Weak::upgrade) {
        return lock;
    }
    let lock = Arc::new(tokio::sync::Mutex::new(()));
    locks.insert(key.into(), Arc::downgrade(&lock));
    lock
}

pub fn initial_delivery_id(mission: Uuid) -> Uuid {
    Uuid::new_v5(&mission, b"initial-worker-message")
}

pub const INITIALIZED_TAG: &str = "worker-initialized-v1";

/// A persisted identity alone is not a completed create. Never acknowledge or
/// replay a partial initialization; expose the orphan's ID for reconciliation.
pub fn require_initialized(mission: &Mission) -> Result<(), (StatusCode, String)> {
    if mission
        .project
        .tags
        .iter()
        .any(|tag| tag == INITIALIZED_TAG)
    {
        return Ok(());
    }
    Err((StatusCode::CONFLICT, serde_json::json!({
        "error": "worker_initialization_incomplete",
        "mission_id": mission.id,
        "message": "worker creation was interrupted before initialization completed; inspect and reconcile this mission before retrying with a new dispatch key"
    }).to_string()))
}

pub async fn mark_initialized(
    store: &Arc<dyn MissionStore>,
    mission: &mut Mission,
) -> Result<(), String> {
    if !mission
        .project
        .tags
        .iter()
        .any(|tag| tag.starts_with("worker-dispatch:"))
    {
        return Ok(());
    }
    store
        .update_mission_project(
            mission.id,
            crate::api::mission_store::MissionProjectPatch {
                tag_patch: Some(crate::api::mission_store::MissionTagPatch {
                    add: vec![INITIALIZED_TAG.into()],
                    ..Default::default()
                }),
                ..Default::default()
            },
        )
        .await?;
    mission.project.tags.push(INITIALIZED_TAG.into());
    Ok(())
}

pub const CLIENT_TAG: &str = "worker-client:";
pub const CLIENT_DELIVERY: &str = "client_message";

pub fn client_owner(mission: &Mission) -> Option<&str> {
    mission
        .project
        .tags
        .iter()
        .find_map(|tag| tag.strip_prefix(CLIENT_TAG))
}

/// External board creation is asynchronous. Do not deliver or start a client
/// worker until the board has adopted it; cancellation before adoption wins.
pub async fn board_allows_client_run(
    store: &Arc<dyn MissionStore>,
    mission: &Mission,
) -> Result<bool, String> {
    let Some(task_id) = mission
        .project
        .tags
        .iter()
        .find_map(|tag| tag.strip_prefix("board-task:"))
    else {
        return Ok(true);
    };
    let task_id = Uuid::parse_str(task_id).map_err(|e| e.to_string())?;
    Ok(store.get_board_task(task_id).await?.is_some_and(|task| {
        task.worker_mission_id == Some(mission.id) && task.status == BoardTaskStatus::Running
    }))
}

/// A not-yet-adopted worker must remain deliverable. Only retire a board
/// delivery when its task is gone, settled, or assigned to a different run.
pub async fn board_client_delivery_obsolete(
    store: &Arc<dyn MissionStore>,
    mission: &Mission,
) -> Result<bool, String> {
    let Some(task_id) = mission
        .project
        .tags
        .iter()
        .find_map(|tag| tag.strip_prefix("board-task:"))
    else {
        return Ok(false);
    };
    let task_id = Uuid::parse_str(task_id).map_err(|e| e.to_string())?;
    let Some(task) = store.get_board_task(task_id).await? else {
        return Ok(true);
    };
    Ok(matches!(
        task.status,
        crate::api::mission_store::BoardTaskStatus::Settled
            | crate::api::mission_store::BoardTaskStatus::Accepted
            | crate::api::mission_store::BoardTaskStatus::Cancelled
    ) || (task.status == crate::api::mission_store::BoardTaskStatus::Running
        && task.worker_mission_id != Some(mission.id)))
}

pub async fn resolved_client_owner(
    store: &Arc<dyn MissionStore>,
    id: Uuid,
) -> Result<Option<String>, String> {
    let Some(mission) = store.get_mission(id).await? else {
        return Ok(None);
    };
    if !client_placement::is_tagged(&mission.project.tags) {
        return Ok(None);
    }
    if let Some(transfer) = machine_transfer::committed(store, id).await? {
        return Ok(match transfer.destination {
            crate::api::mission_store::transfer::Machine::Client { id } => Some(id),
            _ => None,
        });
    }
    if let Some(owner) = client_owner(&mission) {
        return Ok(Some(owner.into()));
    }
    Ok(store.get_latest_mission_run(id).await?.and_then(|run| {
        run.owner_actor_id
            .strip_prefix("orb-client:")
            .map(str::to_owned)
    }))
}

pub async fn inherit(
    state: &AppState,
    control: &ControlState,
    req: &mut CreateMissionRequest,
) -> Result<(), String> {
    let Some(id) = req.parent_mission_id else {
        return Ok(());
    };
    let parent = control
        .mission_store
        .get_mission(id)
        .await?
        .ok_or("Parent mission no longer exists")?;
    // Placement overrides do not change the worker's project or harness defaults.
    req.project = req.project.take().or(parent.project.project.clone());
    req.config_profile = req.config_profile.take().or(parent.config_profile.clone());
    req.backend = req.backend.take().or(Some(parent.backend.clone()));
    if req.remote_node_id.is_some() || req.placement.is_some() {
        return Ok(());
    }
    // Callers such as assistant-mcp always send their default workspace; a
    // child runs where its parent runs unless a destination says otherwise.
    if let Some(requested) = req.workspace_id.filter(|id| *id != parent.workspace_id) {
        tracing::info!(
            parent = %id,
            requested_workspace = %requested,
            inherited_workspace = %parent.workspace_id,
            "worker inherits its parent's workspace"
        );
    }
    req.workspace_id = Some(parent.workspace_id);
    let tags = req.tags.get_or_insert_with(Vec::new);
    machine_transfer::guard(&control.mission_store, id).await?;
    if let Some(transfer) = machine_transfer::committed(&control.mission_store, id).await? {
        use crate::api::mission_store::transfer::Machine;
        req.working_directory = req.working_directory.take().or(transfer.destination_root);
        match transfer.destination {
            Machine::Client { id } => {
                req.placement = Some("client".into());
                tags.push(format!("{CLIENT_TAG}{id}"));
            }
            Machine::Node { id } => {
                req.remote_node_id = Some(id);
            }
            Machine::Core => {
                req.placement = Some("core".into());
            }
        }
        return Ok(());
    }
    if client_placement::is_tagged(&parent.project.tags) {
        let latest = control.mission_store.get_latest_mission_run(id).await?;
        let owner = client_owner(&parent)
            .map(str::to_owned)
            .or_else(|| {
                latest
                    .as_ref()
                    .and_then(|run| run.owner_actor_id.strip_prefix("orb-client:"))
                    .map(str::to_owned)
            })
            .ok_or("Parent's computer is unknown; open it in Orb before delegating")?;
        req.placement = Some("client".into());
        tags.push(format!("{CLIENT_TAG}{owner}"));
        req.working_directory = req
            .working_directory
            .take()
            .or(parent.working_directory.clone())
            .or_else(|| {
                latest
                    .and_then(|run| run.scope_unit)
                    .and_then(|scope| scope.strip_prefix("orb-cwd:").map(str::to_owned))
            });
        if req.working_directory.is_none() {
            return Err("Parent's working directory is unknown".into());
        }
    } else if let Some(remote) =
        remote_grok::placement(&state.config.working_dir, &control.mission_store, id).await?
    {
        if remote.node_id == "unknown" {
            return Err("Parent's machine is unknown; specify a destination".into());
        }
        req.remote_node_id = Some(remote.node_id);
        req.working_directory = req
            .working_directory
            .take()
            .or(parent.working_directory.clone());
        if req.working_directory.is_none() {
            let source = parent
                .project
                .tags
                .iter()
                .find(|tag| tag.starts_with("fork-workspace:"))
                .cloned()
                .unwrap_or_else(|| format!("fork-workspace:{id}"));
            tags.push(source);
        }
    } else {
        // A parent in its own generated directory keeps it to itself: each
        // child gets its own, as before. Only a directory the parent was
        // given explicitly is shared, and the occupancy check then applies.
        req.working_directory = req
            .working_directory
            .take()
            .or(parent.working_directory.clone());
    }
    Ok(())
}

/// Reuse the durable delivery journal. The receiving Orb acknowledges only
/// after placing the message into its own persistent, idempotent launch queue.
pub async fn enqueue(
    store: &Arc<dyn MissionStore>,
    target: Uuid,
    id: Uuid,
    content: String,
) -> Result<(), String> {
    store
        .enqueue_board_outbox(BoardOutboxItem {
            id,
            boss_mission_id: target,
            task_id: None,
            delivery_kind: CLIENT_DELIVERY.into(),
            idempotency_key: format!("client:{target}:{id}"),
            payload: serde_json::json!({"target_mission_id":target,"id":id,"content":content}),
            state: "pending".into(),
            attempts: 0,
            created_at: now_string(),
            acknowledged_at: None,
        })
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn partial_worker_is_not_a_completed_dispatch_receipt() {
        let store: Arc<dyn MissionStore> =
            Arc::new(crate::api::mission_store::InMemoryMissionStore::new());
        let mut mission = store
            .create_mission(Some("partial worker"), None, None, None, None, None, None)
            .await
            .unwrap();
        mission.project.tags.push("worker-dispatch:test".into());
        store
            .update_mission_project(
                mission.id,
                crate::api::mission_store::MissionProjectPatch {
                    tags: Some(mission.project.tags.clone()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        let persisted = store.get_mission(mission.id).await.unwrap().unwrap();
        let error = require_initialized(&persisted).unwrap_err();
        assert_eq!(error.0, StatusCode::CONFLICT);
        assert!(error.1.contains("worker_initialization_incomplete"));
        assert!(error.1.contains(&mission.id.to_string()));
        assert!(store
            .list_pending_board_outbox(10)
            .await
            .unwrap()
            .is_empty());
        mark_initialized(&store, &mut mission).await.unwrap();
        let persisted = store.get_mission(mission.id).await.unwrap().unwrap();
        assert!(require_initialized(&persisted).is_ok());
        assert!(persisted
            .project
            .tags
            .contains(&"worker-dispatch:test".into()));
    }

    #[tokio::test]
    async fn delivery_receipt_survives_duplicate_enqueue() {
        let store: Arc<dyn MissionStore> =
            Arc::new(crate::api::mission_store::InMemoryMissionStore::new());
        let target = Uuid::new_v4();
        let id = Uuid::new_v4();
        enqueue(&store, target, id, "hello".into()).await.unwrap();
        enqueue(&store, target, id, "hello".into()).await.unwrap();
        let pending = store.list_pending_board_outbox(10).await.unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].payload["content"], "hello");
        store
            .acknowledge_board_outbox(&pending[0].idempotency_key)
            .await
            .unwrap();
        enqueue(&store, target, id, "hello".into()).await.unwrap();
        assert!(store
            .list_pending_board_outbox(10)
            .await
            .unwrap()
            .is_empty());
    }
}
