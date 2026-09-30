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

pub const CLIENT_TAG: &str = "worker-client:";
pub const CLIENT_DELIVERY: &str = "client_message";

pub fn client_owner(mission: &Mission) -> Option<&str> {
    mission
        .project
        .tags
        .iter()
        .find_map(|tag| tag.strip_prefix(CLIENT_TAG))
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
    if req.workspace_id.is_some_and(|id| id != parent.workspace_id) {
        return Err(
            "Changing a worker workspace requires an explicit execution destination".into(),
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
        req.working_directory = req
            .working_directory
            .take()
            .or(parent.working_directory.clone());
        if req.working_directory.is_none() {
            let workspace = workspace::resolve_workspace(
                &state.workspaces,
                &state.config,
                Some(parent.workspace_id),
            )
            .await;
            req.working_directory = Some(
                workspace::configured_project_dir(
                    &workspace,
                    &workspace::mission_workspace_dir_for_workspace(&workspace, id),
                )
                .to_string_lossy()
                .into_owned(),
            );
        }
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
