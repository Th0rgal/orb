use crate::{context_replica::Replica, project_context_store::Store};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    process::{Command, Stdio},
};
#[derive(Clone, Serialize, Deserialize)]
pub struct Request {
    pub endpoint: String,
    pub token: String,
    pub project: String,
    #[serde(default)]
    pub paths: Vec<String>,
}
fn replica(request: &Request) -> Result<Replica, String> {
    if request.project.is_empty()
        || request.project.contains(['/', '\\'])
        || request.project.starts_with('.')
    {
        return Err("Invalid project".into());
    }
    let server =
        crate::project_context_store::digest(request.endpoint.trim_end_matches('/').as_bytes());
    use base64::Engine;
    let account = request
        .token
        .split('.')
        .nth(1)
        .and_then(|payload| {
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(payload)
                .ok()
        })
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|claims| {
            claims
                .get("sub")
                .and_then(|v| v.as_str())
                .map(str::to_owned)
        })
        .unwrap_or_else(|| crate::project_context_store::digest(request.token.as_bytes()));
    let account = crate::project_context_store::digest(account.as_bytes());
    let base = PathBuf::from(std::env::var("HOME").map_err(|_| "Missing home directory")?)
        .join(".orb/project-context")
        .join(server)
        .join(account)
        .join(&request.project);
    Ok(Replica {
        store: Store::new(base.join("files"), base.join("state")),
        endpoint: request.endpoint.clone(),
        token: request.token.clone(),
        project: request.project.clone(),
        source: "This computer".into(),
    })
}
#[tauri::command]
pub fn project_context_status(request: Request) -> Result<serde_json::Value, String> {
    let replica = replica(&request)?;
    let state = replica.status()?;
    // A cached error is not a running sync. Recover workers after app/machine restarts.
    if state.initialized
        && !state
            .error
            .as_ref()
            .is_some_and(|e| e.contains("HTTP 401") || e.contains("HTTP 403"))
    {
        ensure_worker(&request, &replica)?;
    }
    Ok(serde_json::json!({"root":replica.store.root,"state":state}))
}
#[tauri::command]
pub fn project_context_disconnect(request: Request) -> Result<(), String> {
    let replica = replica(&request)?;
    let account = replica
        .store
        .metadata
        .parent()
        .and_then(|p| p.parent())
        .ok_or("Invalid context root")?;
    if account.exists() {
        for item in std::fs::read_dir(account).map_err(|e| e.to_string())? {
            let item = item.map_err(|e| e.to_string())?;
            let config = item.path().join("state/connection.json");
            if std::fs::read(&config)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Request>(&bytes).ok())
                .is_some_and(|saved| saved.token == request.token)
            {
                std::fs::remove_file(config).map_err(|e| e.to_string())?;
            }
        }
    }
    Ok(())
}
#[tauri::command]
pub async fn project_context_prepare(request: Request) -> Result<serde_json::Value, String> {
    let replica = replica(&request)?;
    let state = replica.tick().await?;
    if state.initialized {
        ensure_worker(&request, &replica)?;
    }
    if !state.ready {
        return Err(state
            .error
            .unwrap_or("Context is not available on this computer".into()));
    }
    if state
        .error
        .as_ref()
        .is_some_and(|e| e.contains("HTTP 401") || e.contains("HTTP 403"))
    {
        return Err("Context access was revoked".into());
    }
    let manifest = replica.store.manifest()?;
    for path in &request.paths {
        let path = path.trim_start_matches('/');
        if !path.is_empty() {
            crate::project_context_store::valid_path(path)?;
            if !manifest.entries.contains_key(path) {
                return Err(format!("Context path does not exist: {path}"));
            }
        }
    }
    Ok(serde_json::json!({"root":replica.store.root,"state":state}))
}
fn ensure_worker(request: &Request, replica: &Replica) -> Result<(), String> {
    let config = replica.store.metadata.join("connection.json");
    let bytes = serde_json::to_vec(request).map_err(|e| e.to_string())?;
    if std::fs::read(&config).ok().as_deref() != Some(bytes.as_slice()) {
        std::fs::create_dir_all(&replica.store.metadata).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let temp = config.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
            let result = (|| {
                let mut file = std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&temp)
                    .map_err(|e| e.to_string())?;
                file.write_all(&bytes)
                    .and_then(|_| file.sync_all())
                    .map_err(|e| e.to_string())?;
                std::fs::rename(&temp, &config).map_err(|e| e.to_string())
            })();
            if result.is_err() {
                let _ = std::fs::remove_file(temp);
            }
            result?;
        }
        #[cfg(not(unix))]
        return Err("Persistent context credentials are not supported on this platform yet".into());
    }
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(replica.store.metadata.join("worker.lock"))
        .map_err(|e| e.to_string())?;
    if lock.try_lock_exclusive().is_err() {
        return Ok(());
    }
    drop(lock);
    let mut command = Command::new(std::env::current_exe().map_err(|e| e.to_string())?);
    command
        .arg("--orb-context-worker")
        .arg(&config)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}
#[tauri::command]
pub async fn project_context_sync(request: Request) -> Result<serde_json::Value, String> {
    let replica = replica(&request)?;
    let state = replica.tick().await?;
    if state.initialized {
        ensure_worker(&request, &replica)?;
    }
    Ok(serde_json::json!({"root":replica.store.root,"state":state}))
}
#[derive(Default)]
struct SyncCadence {
    previous: Vec<u8>,
    unchanged: u32,
}
impl SyncCadence {
    fn observe(&mut self, state: Vec<u8>, urgent: bool) {
        self.unchanged = if !urgent && state == self.previous {
            self.unchanged.saturating_add(1)
        } else {
            0
        };
        self.previous = state;
    }
    fn reset(&mut self) {
        self.unchanged = 0;
    }
    fn seconds(&self) -> u64 {
        (2_u64 << self.unchanged.min(3)).min(15)
    }
}

pub fn worker_entry() -> bool {
    let args: Vec<_> = std::env::args_os().collect();
    if args.get(1).and_then(|s| s.to_str()) != Some("--orb-context-worker") {
        return false;
    }
    let Some(config) = args.get(2).map(PathBuf::from) else {
        return true;
    };
    let run = || -> Result<(), String> {
        let request: Request =
            serde_json::from_slice(&std::fs::read(&config).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
        let initial = replica(&request)?;
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(initial.store.metadata.join("worker.lock"))
            .map_err(|e| e.to_string())?;
        if lock.try_lock_exclusive().is_err() {
            return Ok(());
        }
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        // Notifications are hints. A bounded periodic reconciliation remains authoritative.
        use notify::Watcher;
        let wake = std::sync::Arc::new(tokio::sync::Notify::new());
        let root = initial.store.root.clone();
        let config_path = config.clone();
        let callback_wake = wake.clone();
        let mut watcher =
            notify::recommended_watcher(move |event: notify::Result<notify::Event>| match event {
                Ok(event)
                    if !matches!(event.kind, notify::EventKind::Access(_))
                        && event
                            .paths
                            .iter()
                            .any(|path| path.starts_with(&root) || path == &config_path) =>
                {
                    callback_wake.notify_one()
                }
                Err(_) => callback_wake.notify_one(),
                _ => {}
            })
            .ok();
        if let Some(watcher) = watcher.as_mut() {
            let _ = watcher.watch(&initial.store.root, notify::RecursiveMode::Recursive);
            let _ = watcher.watch(&initial.store.metadata, notify::RecursiveMode::NonRecursive);
        }
        runtime.block_on(async {
            let mut cadence = SyncCadence::default();
            loop {
                // Removing this connection file revokes the worker. Refresh credentials on each pass.
                let Ok(bytes) = std::fs::read(&config) else {
                    break;
                };
                if let Ok(request) = serde_json::from_slice::<Request>(&bytes) {
                    if let Ok(replica) = replica(&request) {
                        if let Ok(state) = replica.tick().await {
                            cadence.observe(
                                serde_json::to_vec(&state).unwrap_or_default(),
                                state.error.is_some() || !state.pending.is_empty(),
                            );
                            if state.error.as_ref().is_some_and(|error| {
                                error.contains("HTTP 401") || error.contains("HTTP 403")
                            }) {
                                if std::fs::read(&config)
                                    .ok()
                                    .and_then(|bytes| {
                                        serde_json::from_slice::<Request>(&bytes).ok()
                                    })
                                    .is_some_and(|saved| saved.token == request.token)
                                {
                                    let _ = std::fs::remove_file(&config);
                                }
                            }
                        }
                    }
                }
                if tokio::time::timeout(
                    std::time::Duration::from_secs(cadence.seconds()),
                    wake.notified(),
                )
                .await
                .is_ok()
                {
                    cadence.reset();
                    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                }
            }
        });
        Ok(())
    };
    let _ = run();
    true
}

/// Editing uses local revisions, then the replica publishes conditional writes.
#[tauri::command]
pub async fn project_context_file(
    request: Request,
    operation: String,
    path: String,
    content: Option<String>,
    revision: Option<u64>,
) -> Result<serde_json::Value, String> {
    use crate::project_context_store::Operation;
    let replica = replica(&request)?;
    if !replica.status()?.ready || !replica.store.metadata.join("connection.json").exists() {
        project_context_prepare(request).await?;
    }
    let store = replica.store.clone();
    let manifest = store.manifest()?;
    if operation == "list" {
        let prefix = if path.is_empty() {
            String::new()
        } else {
            crate::project_context_store::valid_path(&path)?;
            format!("{path}/")
        };
        let entries:Vec<_>=manifest.entries.iter().filter_map(|(p,e)|{let name=p.strip_prefix(&prefix)?;if name.contains('/'){return None;}Some(serde_json::json!({"name":name,"kind":if e.directory{"dir"}else{"file"},"size":e.size}))}).collect();
        return Ok(serde_json::json!({"entries":entries}));
    }
    crate::project_context_store::valid_path(&path)?;
    if operation == "read" {
        let entry = manifest
            .entries
            .get(&path)
            .ok_or("Context file not found")?;
        let bytes = store.blob(
            entry
                .hash
                .as_deref()
                .ok_or("Cannot read a folder as text")?,
        )?;
        if bytes.len() > 512 * 1024 {
            return Err("Preview limited to 512 KiB".into());
        }
        let content = String::from_utf8(bytes).map_err(|_| "This is a binary file")?;
        return Ok(serde_json::json!({"content":content,"revision":entry.revision}));
    }
    if matches!(operation.as_str(), "move" | "copy") {
        let destination = content.ok_or("Destination is required")?;
        store.transfer_file(&path, &destination, operation == "copy")?;
        tokio::spawn(async move {
            let _ = replica.tick().await;
        });
        return Ok(serde_json::json!({"path":destination}));
    }
    if !matches!(operation.as_str(), "write" | "mkdir" | "delete") {
        return Err("Unknown context operation".into());
    }
    if operation == "delete" {
        let prefix = format!("{path}/");
        let mut entries: Vec<_> = manifest
            .entries
            .iter()
            .filter(|(p, _)| *p == &path || p.starts_with(&prefix))
            .collect();
        entries.sort_by_key(|(p, _)| std::cmp::Reverse(p.len()));
        for (p, e) in entries {
            let result = store.apply(Operation {
                id: uuid::Uuid::new_v4().to_string(),
                path: p.clone(),
                base: Some(e.revision),
                hash: None,
                directory: false,
                delete: true,
                source: "Orb".into(),
            })?;
            if result.conflict {
                return Err("Context changed while deleting; refresh first".into());
            }
        }
        tokio::spawn(async move {
            let _ = replica.tick().await;
        });
        return Ok(serde_json::json!({}));
    }
    let hash = if operation == "write" {
        Some(store.put_blob(content.unwrap_or_default().as_bytes())?)
    } else {
        None
    };
    let base = revision.or_else(|| manifest.entries.get(&path).map(|e| e.revision));
    let receipt = store.apply(Operation {
        id: uuid::Uuid::new_v4().to_string(),
        path: path.clone(),
        base,
        hash: hash.clone(),
        directory: operation == "mkdir",
        delete: false,
        source: "Orb".into(),
    })?;
    if receipt.conflict {
        if operation == "write" {
            let variant = format!(
                "{path}.conflict-{}.md",
                &uuid::Uuid::new_v4().to_string()[..8]
            );
            store.apply(Operation {
                id: uuid::Uuid::new_v4().to_string(),
                path: variant.clone(),
                base: None,
                hash,
                directory: false,
                delete: false,
                source: "Orb edit conflict".into(),
            })?;
            return Err(format!(
                "Context changed while editing. Your variant is saved as {variant}"
            ));
        }
        return Err("Context changed; refresh first".into());
    }
    tokio::spawn(async move {
        let _ = replica.tick().await;
    });
    Ok(serde_json::json!({"revision":receipt.revision}))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn idle_sync_backs_off_but_changes_and_pending_writes_reset_it() {
        let mut cadence = SyncCadence::default();
        for _ in 0..10 {
            cadence.observe(vec![1], false);
        }
        assert_eq!(cadence.seconds(), 15);
        cadence.observe(vec![2], false);
        assert_eq!(cadence.seconds(), 2);
        for _ in 0..10 {
            cadence.observe(vec![2], true);
        }
        assert_eq!(cadence.seconds(), 2);
    }
    #[test]
    fn supervisor_refreshes_credentials_atomically_without_spawning_a_second_worker() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let replica = Replica {
            store: Store::new(dir.path().join("files"), dir.path().join("state")),
            endpoint: "https://example.test".into(),
            token: "old".into(),
            project: "test".into(),
            source: "test".into(),
        };
        std::fs::create_dir_all(&replica.store.metadata).unwrap();
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(replica.store.metadata.join("worker.lock"))
            .unwrap();
        lock.lock_exclusive().unwrap();
        let mut request = Request {
            endpoint: replica.endpoint.clone(),
            token: "old".into(),
            project: "test".into(),
            paths: vec![],
        };
        ensure_worker(&request, &replica).unwrap();
        request.token = "refreshed".into();
        ensure_worker(&request, &replica).unwrap();
        let config = replica.store.metadata.join("connection.json");
        let saved: Request = serde_json::from_slice(&std::fs::read(&config).unwrap()).unwrap();
        assert_eq!(saved.token, "refreshed");
        assert_eq!(
            std::fs::metadata(config).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::read_dir(&replica.store.metadata).unwrap().count(),
            2
        );
    }
}
