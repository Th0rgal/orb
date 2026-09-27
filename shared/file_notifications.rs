//! One OS watcher per root, shared by subscribers. Notifications invalidate
//! cached state; consumers always reread the authoritative file/version.
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock, Weak,
    },
};
type Callback = Arc<dyn Fn() -> bool + Send + Sync>;
struct Hub {
    _watcher: Mutex<RecommendedWatcher>,
    listeners: Mutex<HashMap<u64, Callback>>,
}
fn registry() -> &'static Mutex<HashMap<PathBuf, Weak<Hub>>> {
    static ROOTS: OnceLock<Mutex<HashMap<PathBuf, Weak<Hub>>>> = OnceLock::new();
    ROOTS.get_or_init(Default::default)
}
pub struct Subscription {
    hub: Arc<Hub>,
    token: u64,
}
impl Drop for Subscription {
    fn drop(&mut self) {
        self.hub.listeners.lock().unwrap().remove(&self.token);
    }
}
pub fn watch(
    root: &Path,
    callback: impl Fn() -> bool + Send + Sync + 'static,
) -> Result<Subscription, String> {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    std::fs::create_dir_all(root).map_err(|e| e.to_string())?;
    if std::fs::symlink_metadata(root)
        .map_err(|e| e.to_string())?
        .file_type()
        .is_symlink()
    {
        return Err("Watcher root cannot be a symlink".into());
    }
    let root = root.canonicalize().map_err(|e| e.to_string())?;
    let mut roots = registry().lock().map_err(|e| e.to_string())?;
    roots.retain(|_, hub| hub.strong_count() > 0);
    let hub = if let Some(hub) = roots.get(&root).and_then(Weak::upgrade) {
        hub
    } else {
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        let mut watcher =
            notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                if !matches!(
                    event,
                    Ok(notify::Event {
                        kind: EventKind::Access(_),
                        ..
                    })
                ) {
                    let _ = tx.try_send(());
                }
            })
            .map_err(|e| e.to_string())?;
        watcher
            .watch(&root, RecursiveMode::Recursive)
            .map_err(|e| e.to_string())?;
        let hub = Arc::new(Hub {
            _watcher: Mutex::new(watcher),
            listeners: Mutex::new(HashMap::new()),
        });
        let weak = Arc::downgrade(&hub);
        std::thread::spawn(move || {
            while rx.recv().is_ok() {
                std::thread::sleep(std::time::Duration::from_millis(100));
                while rx.try_recv().is_ok() {}
                let Some(hub) = weak.upgrade() else { break };
                let callbacks: Vec<_> = hub
                    .listeners
                    .lock()
                    .unwrap()
                    .iter()
                    .map(|(id, f)| (*id, f.clone()))
                    .collect();
                for (id, callback) in callbacks {
                    if !callback() {
                        hub.listeners.lock().unwrap().remove(&id);
                    }
                }
            }
        });
        roots.insert(root, Arc::downgrade(&hub));
        hub
    };
    let token = NEXT.fetch_add(1, Ordering::Relaxed);
    hub.listeners
        .lock()
        .unwrap()
        .insert(token, Arc::new(callback));
    Ok(Subscription { hub, token })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn replacement_notifies_and_unsubscribe_releases() {
        let directory = std::env::temp_dir().join(format!(
            "orb-watch-{}-{}",
            std::process::id(),
            NEXT_TEST.fetch_add(1, Ordering::Relaxed)
        ));
        let (tx, rx) = std::sync::mpsc::channel();
        let subscription = watch(&directory, move || tx.send(()).is_ok()).unwrap();
        std::fs::write(directory.join("new"), "hello").unwrap();
        std::fs::rename(directory.join("new"), directory.join("file")).unwrap();
        rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        drop(subscription);
        std::fs::remove_dir_all(directory).unwrap();
    }
    static NEXT_TEST: AtomicU64 = AtomicU64::new(0);
}
