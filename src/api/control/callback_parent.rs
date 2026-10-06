//! Presentation lineage for legacy reviews launched by isolated Hermes callbacks.
//! This is derived evidence, never a replacement for persisted execution ownership.
use crate::api::mission_store::Mission;
use rusqlite::{Connection, OpenFlags};
use std::collections::HashMap;
use uuid::Uuid;

const MARKER: &str = "A sandboxed.sh mission changed status. Mission: ";
fn source_mission(content: &str) -> Option<Uuid> {
    let mut found = None;
    for (start, _) in content.match_indices(MARKER) {
        let callback = content[start + MARKER.len()..].lines().next()?;
        for (start, _) in callback.match_indices(" (id: ") {
            let tail = &callback[start + " (id: ".len()..];
            let Some(text) = tail.get(..36) else {
                continue;
            };
            if !tail
                .get(36..)
                .is_some_and(|rest| rest.starts_with(", status: "))
            {
                continue;
            }
            let Ok(id) = Uuid::parse_str(text) else {
                continue;
            };
            if found.is_some_and(|previous| previous != id) {
                return None;
            }
            found = Some(id);
        }
    }
    found
}

fn parent(connection: &Connection, session: &str) -> Option<Uuid> {
    // Ordinary conversations may discuss many missions; they are not parents.
    let isolated: bool = connection.query_row(
        "SELECT source = 'webhook' AND json_extract(origin_json, '$.chat_id') LIKE 'webhook:mission-complete:%' FROM sessions WHERE id = ?1",
        [session], |row| row.get(0),
    ).ok()?;
    if !isolated {
        return None;
    }
    let mut statement = connection
        .prepare("SELECT content FROM messages WHERE session_id = ?1 AND role = 'user'")
        .ok()?;
    let rows = statement
        .query_map([session], |row| row.get::<_, String>(0))
        .ok()?;
    let mut found = None;
    for row in rows {
        if let Some(id) = source_mission(&row.ok()?) {
            if found.is_some_and(|previous| previous != id) {
                return None;
            }
            found = Some(id);
        }
    }
    found
}

pub(super) async fn links(
    missions: &[Mission],
    store: &std::sync::Arc<dyn crate::api::mission_store::MissionStore>,
) -> HashMap<Uuid, Uuid> {
    let Some(path) = super::super::projects_overview::hermes_state_db_path() else {
        return HashMap::new();
    };
    let sessions: Vec<_> = missions
        .iter()
        .filter(|m| m.parent_mission_id.is_none() && m.origin.as_deref() == Some("hermes"))
        .filter_map(|m| {
            m.origin_session_id
                .as_ref()
                .map(|session| (m.id, session.clone()))
        })
        .collect();
    if sessions.is_empty() {
        return HashMap::new();
    }
    let candidates = tokio::task::spawn_blocking(move || {
        let Ok(connection) = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        else {
            return Vec::new();
        };
        sessions
            .into_iter()
            .filter_map(|(id, session)| {
                parent(&connection, &session)
                    .filter(|parent| *parent != id)
                    .map(|parent| (id, parent))
            })
            .collect::<Vec<_>>()
    })
    .await
    .unwrap_or_default();
    let mut result = HashMap::new();
    for (id, parent) in candidates {
        if store.get_mission(parent).await.ok().flatten().is_some() {
            result.insert(id, parent);
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_unambiguous_isolated_callback_sessions_have_parents() {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch("CREATE TABLE sessions(id TEXT, source TEXT, origin_json TEXT); CREATE TABLE messages(session_id TEXT, role TEXT, content TEXT);
        INSERT INTO sessions VALUES('callback','webhook','{\"chat_id\":\"webhook:mission-complete:x\"}'),('chat','api_server','{}');").unwrap();
        let id = Uuid::new_v4();
        let content = format!("{MARKER}Source (id: {id}, status: failed).");
        for session in ["callback", "chat"] {
            c.execute(
                "INSERT INTO messages VALUES(?1,'user',?2)",
                [session, &content],
            )
            .unwrap();
        }
        assert_eq!(parent(&c, "callback"), Some(id));
        assert_eq!(parent(&c, "chat"), None);
        let other = format!("{MARKER}Other (id: {}, status: completed).", Uuid::new_v4());
        c.execute(
            "INSERT INTO messages VALUES('callback','user',?1)",
            [&other],
        )
        .unwrap();
        assert_eq!(parent(&c, "callback"), None);
        assert_eq!(source_mission("random mission mention"), None);
        assert_eq!(
            source_mission(&format!(
                "{MARKER}Title (id: {}, status: failed) (id: {id}, status: failed).",
                Uuid::new_v4()
            )),
            None
        );
        assert_eq!(
            source_mission(&format!(
                "{MARKER}Title (id: not-an-id) (id: {id}, status: failed)."
            )),
            Some(id)
        );
    }
}
