use super::*;
use crate::api::cloud_agents::Execution;
pub(super) const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS cloud_executions (mission_id TEXT PRIMARY KEY REFERENCES missions(id) ON DELETE CASCADE, request_key TEXT NOT NULL UNIQUE, revision INTEGER NOT NULL, data TEXT NOT NULL); CREATE TABLE IF NOT EXISTS cloud_events (mission_id TEXT NOT NULL REFERENCES missions(id) ON DELETE CASCADE, run_id TEXT NOT NULL, event_id TEXT NOT NULL, kind TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(mission_id,run_id,event_id,kind));";
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
pub(super) async fn list(store: &SqliteMissionStore) -> Result<Vec<Execution>, String> {
    let conn = store.conn.clone();
    tokio::task::spawn_blocking(move || {
        let c = conn.blocking_lock();
        let mut q = c
            .prepare("SELECT data FROM cloud_executions")
            .map_err(err)?;
        let result = q
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(err)?
            .map(|v| serde_json::from_str(&v.map_err(err)?).map_err(err))
            .collect();
        result
    })
    .await
    .map_err(err)?
}
pub(super) async fn save(
    store: &SqliteMissionStore,
    mut execution: Execution,
    expected: Option<u64>,
    title: Option<String>,
    project: Option<String>,
    tags: Vec<String>,
) -> Result<Execution, String> {
    let conn = store.conn.clone();
    tokio::task::spawn_blocking(move || {
        let mut c = conn.blocking_lock(); let tx = c.transaction().map_err(err)?;
        let old: Option<String> = tx.query_row("SELECT data FROM cloud_executions WHERE request_key=?1", [&execution.request_key], |r| r.get(0)).optional().map_err(err)?;
        if let Some(old) = old {
            let old: Execution = serde_json::from_str(&old).map_err(err)?;
            if expected.is_none() {
                if old.request_signature != execution.request_signature || old.selection != execution.selection || old.turns.first().map(|t| &t.prompt) != execution.turns.first().map(|t| &t.prompt) { return Err("Idempotency key already used for another cloud launch".into()); }
                return Ok(old);
            }
            if expected != Some(old.revision) || execution.mission_id != old.mission_id || execution.selection != old.selection { return Err("Cloud execution revision changed".into()); }
            execution.revision = old.revision + 1;
        } else {
            if expected.is_some() { return Err("Cloud execution not found".into()); }
            let now = now_string();
            tx.execute("INSERT INTO missions(id,status,title,workspace_id,backend,created_at,updated_at,project,tags,requires_local_disk,resumable) VALUES(?1,'active',?2,?3,?4,?5,?5,?6,?7,0,1)", params![execution.mission_id.to_string(),title,Uuid::nil().to_string(),execution.selection.provider.backend(),now,project,serde_json::to_string(&tags).map_err(err)?]).map_err(err)?;
        }
        tx.execute("INSERT INTO cloud_executions(mission_id,request_key,revision,data) VALUES(?1,?2,?3,?4) ON CONFLICT(mission_id) DO UPDATE SET revision=excluded.revision,data=excluded.data",params![execution.mission_id.to_string(),execution.request_key,execution.revision,serde_json::to_string(&execution).map_err(err)?]).map_err(err)?;
        if let Some(turn) = execution.turns.iter().find(|t| !t.phase.terminal()).or_else(|| execution.turns.last()) {
            tx.execute("UPDATE missions SET status=?2,updated_at=?3 WHERE id=?1 AND status<>'acknowledged'",params![execution.mission_id.to_string(),turn.phase.mission_status(),now_string()]).map_err(err)?;
        }
        tx.commit().map_err(err)?; Ok(execution)
    }).await.map_err(err)?
}
pub(super) async fn event(
    store: &SqliteMissionStore,
    mission: Uuid,
    event: crate::api::cloud_agents::Event,
) -> Result<(), String> {
    let conn = store.conn.clone();
    tokio::task::spawn_blocking(move || {
        let c = conn.blocking_lock();
        c.execute("INSERT OR IGNORE INTO cloud_events(mission_id,run_id,event_id,kind,data) VALUES(?1,?2,?3,?4,?5)",params![mission.to_string(),event.run_id,event.id,event.kind,serde_json::to_string(&event.data).map_err(err)?]).map_err(err)?;
        Ok(())
    }).await.map_err(err)?
}
pub(super) async fn events(
    store: &SqliteMissionStore,
    mission: Uuid,
) -> Result<Vec<crate::api::cloud_agents::Event>, String> {
    let conn = store.conn.clone();
    tokio::task::spawn_blocking(move || {
        let c = conn.blocking_lock();
        let mut q = c.prepare("SELECT run_id,event_id,kind,data FROM (SELECT rowid,run_id,event_id,kind,data FROM cloud_events WHERE mission_id=?1 ORDER BY rowid DESC LIMIT 500) ORDER BY rowid").map_err(err)?;
        let result = q.query_map([mission.to_string()], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?))).map_err(err)?.map(|r| { let (run_id,id,kind,data) = r.map_err(err)?; Ok(crate::api::cloud_agents::Event{run_id,id,kind,data:serde_json::from_str(&data).map_err(err)?}) }).collect(); result
    }).await.map_err(err)?
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::cloud_agents::{Event, Phase, Provider, Selection, Turn};
    fn execution() -> Execution {
        Execution {
            mission_id: Uuid::new_v4(),
            request_key: "launch-1".into(),
            request_signature: "same-project-and-prompt".into(),
            revision: 0,
            selection: Selection {
                provider: Provider::CursorCloud,
                account: "cursor-default".into(),
                repository: None,
                git_ref: None,
                model_params: vec![],
                model: None,
            },
            external_id: None,
            external_url: None,
            turns: vec![Turn::new("first".into(), "Say hello".into())],
        }
    }
    #[tokio::test]
    async fn launch_receipt_is_atomic_idempotent_and_survives_restart() {
        let dir = tempfile::tempdir().unwrap();
        let store = SqliteMissionStore::new(dir.path().into(), "cloud-test")
            .await
            .unwrap();
        let one = execution();
        let (a, b) = tokio::join!(
            store.save_cloud_execution(
                one.clone(),
                None,
                Some("Test".into()),
                Some("project".into()),
                vec!["orb-folder:notes".into()]
            ),
            store.save_cloud_execution(
                one.clone(),
                None,
                Some("Test".into()),
                Some("project".into()),
                vec!["orb-folder:notes".into()]
            )
        );
        assert_eq!(a.unwrap().mission_id, b.unwrap().mission_id);
        assert_eq!(store.list_missions(20, 0).await.unwrap().len(), 1);
        let mut incompatible = one.clone();
        incompatible.request_signature = "different-project".into();
        assert!(store
            .save_cloud_execution(incompatible, None, None, None, vec![])
            .await
            .is_err());
        let mut claimed = one.clone();
        claimed.turns[0].phase = Phase::Submitting;
        let claimed = store
            .save_cloud_execution(claimed, Some(0), None, None, vec![])
            .await
            .unwrap();
        assert!(store
            .save_cloud_execution(one, Some(0), None, None, vec![])
            .await
            .is_err());
        drop(store);
        let reopened = SqliteMissionStore::new(dir.path().into(), "cloud-test")
            .await
            .unwrap();
        let rows = reopened.cloud_executions().await.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].turns[0].phase, Phase::Submitting);
        assert_eq!(rows[0].revision, claimed.revision);
        let mission = reopened
            .get_mission(claimed.mission_id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(mission.project.project.as_deref(), Some("project"));
        assert!(!mission.requires_local_disk);
        assert_eq!(mission.history[0].content, "Say hello");
    }
    #[tokio::test]
    async fn replayed_events_are_deduplicated_per_run_and_type() {
        let dir = tempfile::tempdir().unwrap();
        let store = SqliteMissionStore::new(dir.path().into(), "cloud-events")
            .await
            .unwrap();
        let e = store
            .save_cloud_execution(execution(), None, None, None, vec![])
            .await
            .unwrap();
        let event = Event {
            run_id: "run-1".into(),
            id: "opaque".into(),
            kind: "assistant".into(),
            data: serde_json::json!({"text":"hello"}),
        };
        store
            .append_cloud_event(e.mission_id, event.clone())
            .await
            .unwrap();
        store
            .append_cloud_event(e.mission_id, event.clone())
            .await
            .unwrap();
        let mut next = event;
        next.run_id = "run-2".into();
        store.append_cloud_event(e.mission_id, next).await.unwrap();
        assert_eq!(store.cloud_events(e.mission_id).await.unwrap().len(), 2);
    }
}
