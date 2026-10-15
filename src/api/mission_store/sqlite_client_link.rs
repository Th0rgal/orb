//! Durable ingest cursors for events streamed by an Orb client over the
//! client link. One row per (mission, client): the last contiguous sequence
//! core has persisted, so a reconnecting client replays exactly the rest.
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

pub(super) async fn cursor(
    store: &SqliteMissionStore,
    mission_id: Uuid,
    client_id: &str,
) -> Result<u64, String> {
    let conn = store.conn.clone();
    let (mid, cid) = (mission_id.to_string(), client_id.to_string());
    tokio::task::spawn_blocking(move || {
        let c = conn.blocking_lock();
        c.execute_batch(SCHEMA).map_err(err)?;
        let seq: Option<i64> = c
            .query_row(
                "SELECT last_seq FROM client_event_cursors WHERE mission_id=?1 AND client_id=?2",
                params![mid, cid],
                |r| r.get(0),
            )
            .optional()
            .map_err(err)?;
        Ok(seq.unwrap_or(0).max(0) as u64)
    })
    .await
    .map_err(err)?
}

/// Compare-and-set: moves the cursor from `from` to `to` only if it still
/// reads `from`. Returns false when another writer advanced it first.
pub(super) async fn advance(
    store: &SqliteMissionStore,
    mission_id: Uuid,
    client_id: &str,
    from: u64,
    to: u64,
) -> Result<bool, String> {
    let conn = store.conn.clone();
    let (mid, cid) = (mission_id.to_string(), client_id.to_string());
    tokio::task::spawn_blocking(move || {
        let c = conn.blocking_lock();
        c.execute_batch(SCHEMA).map_err(err)?;
        let changed = if from == 0 {
            c.execute(
                "INSERT INTO client_event_cursors (mission_id,client_id,last_seq,updated_at) VALUES (?1,?2,?3,?4)
                 ON CONFLICT(mission_id,client_id) DO UPDATE SET last_seq=excluded.last_seq, updated_at=excluded.updated_at
                 WHERE client_event_cursors.last_seq=0",
                params![mid, cid, to as i64, now_string()],
            )
        } else {
            c.execute(
                "UPDATE client_event_cursors SET last_seq=?3, updated_at=?5 WHERE mission_id=?1 AND client_id=?2 AND last_seq=?4",
                params![mid, cid, to as i64, from as i64, now_string()],
            )
        }
        .map_err(err)?;
        Ok(changed == 1)
    })
    .await
    .map_err(err)?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn cursor_is_per_client_and_compare_and_set() {
        let temp = tempfile::tempdir().unwrap();
        let store = SqliteMissionStore::new(temp.path().to_path_buf(), "client-link")
            .await
            .unwrap();
        let m = Uuid::new_v4();
        assert_eq!(cursor(&store, m, "a").await.unwrap(), 0);
        assert!(advance(&store, m, "a", 0, 1).await.unwrap());
        assert!(!advance(&store, m, "a", 0, 5).await.unwrap(), "stale from");
        assert!(advance(&store, m, "a", 1, 2).await.unwrap());
        assert_eq!(cursor(&store, m, "a").await.unwrap(), 2);
        assert_eq!(cursor(&store, m, "b").await.unwrap(), 0);
    }
}
