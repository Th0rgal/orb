//! Durable ingest cursors for events streamed by an Orb client over the
//! client link. One row per (mission, client): the last contiguous sequence
//! core has persisted. The event and its cursor commit in one transaction,
//! so a reconnecting client replays exactly the rest, with no duplicates.
use super::*;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS client_event_cursors (
    mission_id TEXT NOT NULL,
    client_id TEXT NOT NULL,
    last_seq INTEGER NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (mission_id, client_id)
)";

fn read(conn: &rusqlite::Connection, mid: &str, cid: &str) -> Result<u64, String> {
    conn.execute_batch(SCHEMA).map_err(err)?;
    let seq: Option<i64> = conn
        .query_row(
            "SELECT last_seq FROM client_event_cursors WHERE mission_id=?1 AND client_id=?2",
            params![mid, cid],
            |r| r.get(0),
        )
        .optional()
        .map_err(err)?;
    Ok(seq.unwrap_or(0).max(0) as u64)
}

pub(super) async fn cursor(
    store: &SqliteMissionStore,
    mission_id: Uuid,
    client_id: &str,
) -> Result<u64, String> {
    let conn = store.conn.clone();
    let (mid, cid) = (mission_id.to_string(), client_id.to_string());
    tokio::task::spawn_blocking(move || read(&conn.blocking_lock(), &mid, &cid))
        .await
        .map_err(err)?
}

pub(super) async fn log(
    store: &SqliteMissionStore,
    mission_id: Uuid,
    client_id: &str,
    seq: u64,
    event: Option<AgentEvent>,
) -> Result<ClientIngest, String> {
    let conn = store.conn.clone();
    let content_dir = store.content_dir.clone();
    let (mid, cid) = (mission_id.to_string(), client_id.to_string());
    tokio::task::spawn_blocking(move || {
        let mut c = conn.blocking_lock();
        let tx = c.transaction().map_err(err)?;
        let last = read(&tx, &mid, &cid)?;
        if seq <= last {
            return Ok(ClientIngest::Duplicate);
        }
        if seq != last + 1 {
            return Ok(ClientIngest::Gap { expected: last + 1 });
        }
        if let Some(event) = &event {
            log_event_sync(&tx, &content_dir, mission_id, event)?;
        }
        tx.execute(
            "INSERT INTO client_event_cursors (mission_id,client_id,last_seq,updated_at) VALUES (?1,?2,?3,?4)
             ON CONFLICT(mission_id,client_id) DO UPDATE SET last_seq=excluded.last_seq, updated_at=excluded.updated_at",
            params![mid, cid, seq as i64, now_string()],
        )
        .map_err(err)?;
        tx.commit().map_err(err)?;
        Ok(ClientIngest::Stored)
    })
    .await
    .map_err(err)?
}

#[cfg(test)]
mod tests {
    use super::*;

    fn error(n: u64) -> AgentEvent {
        AgentEvent::Error {
            message: format!("e{n}"),
            mission_id: None,
            resumable: false,
        }
    }

    #[tokio::test]
    async fn event_and_cursor_commit_together() {
        let temp = tempfile::tempdir().unwrap();
        let store = SqliteMissionStore::new(temp.path().to_path_buf(), "client-link")
            .await
            .unwrap();
        let m = Uuid::new_v4();
        store
            .sync_local_origin(crate::local_origin::Snapshot {
                origin: crate::local_origin::Origin {
                    service_tier: None,
                    cyber_access: None,
                    id: m,
                    run_id: Uuid::new_v4(),
                    client_id: Uuid::new_v4(),
                    title: "Local task".into(),
                    project: "test".into(),
                    backend: "claudecode".into(),
                    model: None,
                    effort: None,
                    cwd: "/local/work".into(),
                    prompt: "Work locally".into(),
                    created_at: now_string(),
                    tags: vec![],
                },
                sequence: 1,
                text: String::new(),
                status: "active".into(),
                error: None,
            })
            .await
            .unwrap();
        let count = move |s: &SqliteMissionStore| {
            let c = s.conn.blocking_lock();
            c.query_row(
                "SELECT COUNT(*) FROM mission_events WHERE mission_id=?1",
                [m.to_string()],
                |r| r.get::<_, i64>(0),
            )
            .unwrap()
        };
        let store = std::sync::Arc::new(store);
        let s = store.clone();
        let before = tokio::task::spawn_blocking(move || count(&s))
            .await
            .unwrap();
        assert_eq!(
            log(&store, m, "a", 1, Some(error(1))).await.unwrap(),
            ClientIngest::Stored
        );
        assert_eq!(
            log(&store, m, "a", 1, Some(error(1))).await.unwrap(),
            ClientIngest::Duplicate
        );
        assert_eq!(
            log(&store, m, "a", 3, Some(error(3))).await.unwrap(),
            ClientIngest::Gap { expected: 2 }
        );
        assert_eq!(
            log(&store, m, "b", 1, Some(error(1))).await.unwrap(),
            ClientIngest::Stored
        );
        assert_eq!(cursor(&store, m, "a").await.unwrap(), 1);
        let s = store.clone();
        let after = tokio::task::spawn_blocking(move || count(&s))
            .await
            .unwrap();
        assert_eq!(after - before, 2, "only the two stored events were written");
    }
}
