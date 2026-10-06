//! Read only the CLI's displayed thought summaries, never opaque signatures.
//! The headless JSON protocol omits these; native CLI stores them in steps.
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    time::Duration,
};

pub struct Reader {
    root: PathBuf,
    session: Option<String>,
    floor: Option<u64>,
    seen: HashMap<u64, (String, bool)>,
}
impl Reader {
    pub fn new(home: &Path) -> Self {
        Self {
            root: home.join(".gemini/antigravity-cli/conversations"),
            session: None,
            floor: None,
            seen: HashMap::new(),
        }
    }
    /// Bind only to the current process's reported identity and step indices.
    pub fn observe(&mut self, event: &Value) {
        let body = match event["event"].as_str() {
            Some("init") => event,
            Some("step_update") => &event["step_update"],
            _ => return,
        };
        if let Some(id) = body["conversation_id"]
            .as_str()
            .filter(|id| uuid::Uuid::parse_str(id).is_ok())
        {
            if self.session.as_deref().is_some_and(|old| old != id) {
                return;
            }
            self.session = Some(id.into());
        }
        if self.session.is_some() && self.floor.is_none() {
            self.floor = body["step_index"].as_u64();
        }
    }
    pub fn poll(&mut self) -> Vec<Value> {
        let (Some(session), Some(floor)) = (&self.session, self.floor) else {
            return vec![];
        };
        let path = self.root.join(format!("{session}.db"));
        let Ok(db) = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        ) else {
            return vec![];
        };
        let _ = db.busy_timeout(Duration::from_millis(50));
        let Ok(mut stmt) = db.prepare("SELECT idx,status,step_payload FROM steps WHERE step_type=15 AND idx>=?1 AND length(step_payload)<=4194304 ORDER BY idx DESC LIMIT 256") else { return vec![]; };
        let Ok(rows) = stmt.query_map([floor], |r| {
            Ok((
                r.get::<_, u64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, Vec<u8>>(2)?,
            ))
        }) else {
            return vec![];
        };
        let mut events = vec![];
        for (idx, status, payload) in rows.flatten() {
            let Some(text) = displayed_thought(&payload) else {
                continue;
            };
            if text.is_empty() {
                continue;
            }
            let done = status == 3 || status == 4;
            if self.seen.get(&idx) == Some(&(text.clone(), done)) {
                continue;
            }
            self.seen.insert(idx, (text.clone(), done));
            events.push(json!({"event":"thought_update","conversation_id":session,"step_index":idx,"text":text,"done":done}));
        }
        events.reverse();
        events
    }
}

// Native CascadeStep.agent_response (20), displayed thought summary (3).
// Field 14 carries opaque signatures; it is deliberately never decoded.
pub fn displayed_thought(payload: &[u8]) -> Option<String> {
    if payload.len() > 4 * 1024 * 1024 {
        return None;
    }
    let response = bytes_field(payload, 20)?;
    let text = std::str::from_utf8(bytes_field(response, 3)?).ok()?;
    if text.len() > 256 * 1024 {
        return None;
    }
    Some(text.to_string())
}
fn varint(data: &[u8], p: &mut usize) -> Option<u64> {
    let mut value = 0u64;
    for shift in (0..70).step_by(7) {
        let byte = *data.get(*p)?;
        *p += 1;
        if shift == 63 && byte > 1 {
            return None;
        }
        value |= u64::from(byte & 127) << shift;
        if byte < 128 {
            return Some(value);
        }
    }
    None
}
fn bytes_field(data: &[u8], wanted: u64) -> Option<&[u8]> {
    let mut p = 0;
    while p < data.len() {
        let key = varint(data, &mut p)?;
        let length = match key & 7 {
            0 => {
                varint(data, &mut p)?;
                continue;
            }
            1 => 8,
            2 => usize::try_from(varint(data, &mut p)?).ok()?,
            5 => 4,
            _ => return None,
        };
        let end = p.checked_add(length)?;
        let field = data.get(p..end)?;
        if key >> 3 == wanted && key & 7 == 2 {
            return Some(field);
        }
        p = end;
    }
    None
}
#[cfg(test)]
mod tests {
    use super::*;
    fn payload(text: &str) -> Vec<u8> {
        let mut inner = vec![26, text.len() as u8];
        inner.extend(text.as_bytes());
        let mut out = vec![162, 1, inner.len() as u8];
        out.extend(inner);
        out
    }
    #[test]
    fn only_displayed_summary_is_decoded() {
        assert_eq!(
            displayed_thought(&payload("Checking the build.")),
            Some("Checking the build.".into())
        );
        assert_eq!(displayed_thought(&[162, 1, 4, 114, 2, 255, 254]), None);
        assert_eq!(displayed_thought(&[162, 1, 255]), None);
        assert_eq!(displayed_thought(&[255; 20]), None);
    }
    #[test]
    #[ignore = "requires a native conversation with displayed thoughts"]
    fn live_native_database_is_readable_without_writes() {
        let sid = std::env::var("ORB_ANTIGRAVITY_THOUGHT_PROBE").unwrap();
        let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
        let mut r = Reader::new(&home);
        r.observe(
            &json!({"event":"step_update","step_update":{"conversation_id":sid,"step_index":0}}),
        );
        assert!(!r.poll().is_empty());
    }
    #[test]
    fn current_turn_only_replay_and_completion_are_idempotent() {
        let home = tempfile::tempdir().unwrap();
        let sid = uuid::Uuid::new_v4().to_string();
        let dir = home.path().join(".gemini/antigravity-cli/conversations");
        std::fs::create_dir_all(&dir).unwrap();
        let db = Connection::open(dir.join(format!("{sid}.db"))).unwrap();
        db.execute_batch(
            "CREATE TABLE steps(idx INTEGER,step_type INTEGER,status INTEGER,step_payload BLOB)",
        )
        .unwrap();
        for idx in [1, 10] {
            db.execute(
                "INSERT INTO steps VALUES(?1,15,2,?2)",
                rusqlite::params![idx, payload("Visible thought")],
            )
            .unwrap();
        }
        let mut r = Reader::new(home.path());
        r.observe(&json!({"event":"init","conversation_id":sid}));
        assert!(r.poll().is_empty());
        r.observe(
            &json!({"event":"step_update","step_update":{"conversation_id":sid,"step_index":9}}),
        );
        let events = r.poll();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["step_index"], 10);
        assert!(r.poll().is_empty());
        db.execute("UPDATE steps SET status=3 WHERE idx=10", [])
            .unwrap();
        assert_eq!(r.poll()[0]["done"], true);
        assert!(r.poll().is_empty());
    }
}
