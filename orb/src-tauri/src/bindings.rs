//! Native storage owns bindings; the webview receives an ordered projection.
use serde::Serialize;
use serde_json::{Map, Value};
use std::sync::{Mutex, OnceLock};
use tauri::ipc::Channel;
#[derive(Clone, Serialize)]
pub struct Snapshot {
    revision: u64,
    bindings: Map<String, Value>,
}
#[derive(Default)]
struct Store {
    snapshot: Option<Snapshot>,
    next: u64,
    subscribers: std::collections::HashMap<u64, Channel<Snapshot>>,
}
fn store() -> &'static Mutex<Store> {
    static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
    STORE.get_or_init(Default::default)
}
fn directory() -> Result<std::path::PathBuf, String> {
    Ok(std::path::PathBuf::from(std::env::var("HOME").map_err(|e| e.to_string())?).join(".orb"))
}
impl Store {
    fn load(&mut self) -> Result<&Snapshot, String> {
        if self.snapshot.is_none() {
            let bindings = match std::fs::read(directory()?.join("local-bindings.json")) {
                Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| e.to_string())?,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Map::new(),
                Err(e) => return Err(e.to_string()),
            };
            self.snapshot = Some(Snapshot {
                revision: 0,
                bindings,
            });
        }
        Ok(self.snapshot.as_ref().unwrap())
    }
}
pub fn local_bindings(id: Option<String>, binding: Option<Value>) -> Result<Value, String> {
    let mut store = store().lock().map_err(|e| e.to_string())?;
    store.load()?;
    if let (Some(id), Some(binding)) = (id, binding) {
        store.update(&directory()?, id, binding)?;
    }
    Ok(Value::Object(store.load()?.bindings.clone()))
}
impl Store {
    fn refresh(&mut self, dir: &std::path::Path) -> Result<Snapshot, String> {
        let bindings = match std::fs::read(dir.join("local-bindings.json")) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| e.to_string())?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Map::new(),
            Err(e) => return Err(e.to_string()),
        };
        if self
            .snapshot
            .as_ref()
            .is_none_or(|s| s.bindings != bindings)
        {
            let revision = self.snapshot.as_ref().map_or(0, |s| s.revision + 1);
            let next = Snapshot { revision, bindings };
            self.snapshot = Some(next.clone());
            self.subscribers
                .retain(|_, channel| channel.send(next.clone()).is_ok());
        }
        Ok(self.snapshot.as_ref().unwrap().clone())
    }

    fn update(&mut self, dir: &std::path::Path, id: String, binding: Value) -> Result<(), String> {
        if !["harness", "bin", "cwd"].iter().all(|key| {
            binding[*key]
                .as_str()
                .is_some_and(|value| !value.is_empty())
        }) {
            return Err("Binding must contain harness, bin and cwd".into());
        }
        let previous = self.snapshot.as_ref().ok_or("Bindings not initialized")?;
        if previous.bindings.get(&id) == Some(&binding) {
            return Ok(());
        }
        let mut next = previous.clone();
        next.bindings.insert(id, binding);
        next.revision += 1;
        crate::project_context_store::atomic(
            &dir.join("local-bindings.json"),
            &serde_json::to_vec(&next.bindings).map_err(|e| e.to_string())?,
        )?;
        self.snapshot = Some(next.clone());
        self.subscribers
            .retain(|_, channel| channel.send(next.clone()).is_ok());
        Ok(())
    }
}

/// Reconcile the on-disk owner record before deciding a session belongs elsewhere.
#[tauri::command]
pub fn local_bindings_refresh() -> Result<Snapshot, String> {
    store()
        .lock()
        .map_err(|e| e.to_string())?
        .refresh(&directory()?)
}

#[tauri::command]
pub fn local_bindings_subscribe(on_event: Channel<Snapshot>) -> Result<u64, String> {
    let mut store = store().lock().map_err(|e| e.to_string())?;
    on_event
        .send(store.load()?.clone())
        .map_err(|e| e.to_string())?;
    store.next += 1;
    let token = store.next;
    store.subscribers.insert(token, on_event);
    Ok(token)
}
#[tauri::command]
pub fn local_bindings_unsubscribe(token: u64) -> Result<(), String> {
    store()
        .lock()
        .map_err(|e| e.to_string())?
        .subscribers
        .remove(&token);
    Ok(())
}

#[tauri::command]
pub fn local_binding_set(
    id: String,
    binding: Value,
    if_absent: Option<bool>,
) -> Result<Snapshot, String> {
    let mut store = store().lock().map_err(|e| e.to_string())?;
    let exists = store.load()?.bindings.contains_key(&id);
    if if_absent != Some(true) || !exists {
        store.update(&directory()?, id, binding)?;
    }
    Ok(store.load()?.clone())
}

pub fn clear_subscriptions() {
    if let Ok(mut store) = store().lock() {
        store.subscribers.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn refresh_recovers_external_binding_and_removal_without_resetting_revision() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::default();
        assert!(store.refresh(dir.path()).unwrap().bindings.is_empty());
        let binding = serde_json::json!({"harness":"codex","bin":"/bin/codex","cwd":"/work","sessionId":"original"});
        std::fs::write(
            dir.path().join("local-bindings.json"),
            serde_json::to_vec(&serde_json::json!({"mission":binding})).unwrap(),
        )
        .unwrap();
        let snapshot = store.refresh(dir.path()).unwrap();
        assert_eq!(snapshot.bindings["mission"]["sessionId"], "original");
        assert_eq!(snapshot.revision, 1);
        assert_eq!(store.refresh(dir.path()).unwrap().revision, 1);
        std::fs::write(dir.path().join("local-bindings.json"), b"invalid").unwrap();
        assert!(store.refresh(dir.path()).is_err());
        assert_eq!(store.snapshot.as_ref().unwrap().revision, 1);
        std::fs::remove_file(dir.path().join("local-bindings.json")).unwrap();
        let removed = store.refresh(dir.path()).unwrap();
        assert!(removed.bindings.is_empty());
        assert_eq!(removed.revision, 2);
    }

    #[test]
    fn identical_binding_does_not_write_or_publish() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store {
            snapshot: Some(Snapshot {
                revision: 0,
                bindings: Map::new(),
            }),
            ..Default::default()
        };
        let (tx, rx) = std::sync::mpsc::channel();
        store.subscribers.insert(
            1,
            Channel::new(move |_| {
                tx.send(()).unwrap();
                Ok(())
            }),
        );
        let binding = serde_json::json!({"harness":"codex","bin":"codex","cwd":"/work"});
        store
            .update(dir.path(), "mission".into(), binding.clone())
            .unwrap();
        rx.recv().unwrap();
        std::fs::remove_file(dir.path().join("local-bindings.json")).unwrap();
        store.update(dir.path(), "mission".into(), binding).unwrap();
        assert!(!dir.path().join("local-bindings.json").exists());
        assert!(rx.try_recv().is_err());
        assert_eq!(store.snapshot.unwrap().revision, 1);
    }
    #[test]
    fn failed_persistence_does_not_publish_or_replace_state() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("not-a-dir"), "x").unwrap();
        let mut store = Store {
            snapshot: Some(Snapshot {
                revision: 0,
                bindings: Map::new(),
            }),
            ..Default::default()
        };
        assert!(store
            .update(
                &dir.path().join("not-a-dir"),
                "m".into(),
                serde_json::json!({"harness":"codex","bin":"codex","cwd":"/work"})
            )
            .is_err());
        assert_eq!(store.snapshot.unwrap().revision, 0);
    }
}
