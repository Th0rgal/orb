//! Native-owned initial runs: identity and outbox reach disk before spawning.
//! Existing missions never enter this path; resuming still requires Core.
use crate::local_origin_confirmed::{self as confirmed, Confirmation, Confirmed};
use crate::local_origin_wire::{Origin, Snapshot};
use crate::{local_agents, run_recovery::Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::OnceLock,
};
use tokio::sync::Mutex;
#[derive(Deserialize)]
pub struct Draft {
    pub key: String,
    pub title: String,
    pub project: String,
    pub prompt: String,
    #[serde(default)]
    pub tags: Vec<String>,
}
#[derive(Serialize, Deserialize)]
struct Record {
    snapshot: Snapshot,
    acked: u64,
    /// Native generation of the initial run; never adopt a follow-up.
    #[serde(default)]
    native_generation: Option<String>,
    error: Option<String>,
    /// Archive, restore and title changes confirmed by Core after synchronization.
    #[serde(default)]
    confirmed: Option<Confirmed>,
}
/// Local work Core has not accepted yet is the only truth about itself.
fn pending(r: &Record) -> bool {
    r.acked < r.snapshot.sequence || r.snapshot.status == "active"
}
fn account(c: &Connection) -> Result<PathBuf, String> {
    use base64::Engine;
    let sub = c
        .token
        .split('.')
        .nth(1)
        .and_then(|p| {
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(p)
                .ok()
        })
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v["sub"].as_str().map(str::to_owned))
        .ok_or("Reconnect to Core once before starting local missions")?;
    let key = crate::project_context_store::digest(
        format!("{}\n{sub}", c.api_url.trim_end_matches('/')).as_bytes(),
    );
    Ok(
        PathBuf::from(std::env::var("HOME").map_err(|e| e.to_string())?)
            .join(".orb/local-origins")
            .join(key),
    )
}
fn read(p: &Path) -> Result<Record, String> {
    serde_json::from_slice(&std::fs::read(p).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}
fn write(p: &Path, r: &Record) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let tmp = p.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| e.to_string())?;
    f.write_all(&serde_json::to_vec(r).map_err(|e| e.to_string())?)
        .and_then(|_| f.sync_all())
        .map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, p).map_err(|e| e.to_string())?;
    std::fs::File::open(p.parent().ok_or("Missing journal directory")?)
        .and_then(|d| d.sync_all())
        .map_err(|e| e.to_string())
}
fn view(r: &Record) -> Value {
    let s = &r.snapshot;
    let o = &s.origin;
    let objective = o
        .prompt
        .trim()
        .strip_prefix("/goal")
        .filter(|rest| rest.starts_with(char::is_whitespace))
        .map(str::trim)
        .filter(|rest| !rest.is_empty());
    let (status, title) = confirmed::shown(r.confirmed.as_ref(), pending(r), &s.status, &o.title);
    json!({"id":o.id,"title":title,"status":status,"project":o.project,"tags":o.tags.iter().cloned().chain(std::iter::once("placement:client".into())).collect::<Vec<_>>(),"backend":o.backend,"model_override":o.model,"working_directory":o.cwd,"created_at":o.created_at,"updated_at":o.created_at,"history":[{"role":"user","content":o.prompt},{"role":"assistant","content":s.text}],"goal_mode":objective.is_some(),"goal_objective":objective,"status_message":s.error,"local_sync_pending":r.acked<s.sequence,"local_run_active":s.status=="active","local_sync_error":r.error})
}
fn workers() -> &'static Mutex<HashSet<PathBuf>> {
    static W: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();
    W.get_or_init(|| Mutex::new(HashSet::new()))
}
fn connections() -> &'static Mutex<std::collections::HashMap<PathBuf, Connection>> {
    static C: OnceLock<Mutex<std::collections::HashMap<PathBuf, Connection>>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}
#[tauri::command]
pub async fn local_origin_disconnect(connection: Connection) -> Result<(), String> {
    let key = account(&connection)?;
    let mut active = connections().lock().await;
    if active
        .get(&key)
        .is_some_and(|saved| saved.token == connection.token)
    {
        active.remove(&key);
    }
    Ok(())
}

async fn start_worker(path: PathBuf, c: Connection) {
    if let Some(root) = path.parent() {
        connections().lock().await.insert(root.to_owned(), c);
    }
    if !workers().lock().await.insert(path.clone()) {
        return;
    }
    tauri::async_runtime::spawn(async move {
        use fs2::FileExt;
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path.with_extension("worker.lock"));
        let Ok(lock) = lock else {
            workers().lock().await.remove(&path);
            return;
        };
        if lock.try_lock_exclusive().is_err() {
            workers().lock().await.remove(&path);
            return;
        }
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(8))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap();
        let mut last_session = None;
        loop {
            let Ok(mut record) = read(&path) else { break };
            // A completed initial snapshot is immutable; subsequent turns have their own receipts.
            if record.acked == record.snapshot.sequence && record.snapshot.status != "active" {
                break;
            }
            let id = record.snapshot.origin.id.to_string();
            if let Some(p) = record
                .native_generation
                .as_deref()
                .and_then(|generation| local_agents::poll_generation(&id, Some(generation)).ok())
            {
                if p.session_id.is_some() && p.session_id != last_session {
                    if let Ok(bindings) = crate::local_bindings(None, None) {
                        let mut binding = bindings[&id].clone();
                        if binding.is_object() {
                            binding["sessionId"] = json!(p.session_id);
                            let _ = crate::local_bindings(Some(id.clone()), Some(binding));
                        }
                    }
                    last_session = p.session_id.clone();
                }
                let status = if !p.done {
                    "active"
                } else if p.exit_code.is_some_and(|code| code != 0) || p.error.is_some() {
                    "failed"
                } else {
                    "awaiting_user"
                };
                if record.snapshot.text != p.text
                    || record.snapshot.status != status
                    || record.snapshot.error != p.error
                {
                    record.snapshot.sequence += 1;
                    record.snapshot.text = p.text;
                    record.snapshot.status = status.into();
                    record.snapshot.error = p.error;
                    if write(&path, &record).is_err() {
                        break;
                    }
                }
            }
            if record.acked < record.snapshot.sequence || record.snapshot.status == "active" {
                let connection = connections()
                    .lock()
                    .await
                    .get(path.parent().unwrap())
                    .cloned();
                let Some(c) = connection else {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                    continue;
                };
                let generation = record.native_generation.clone();
                let response = client
                    .post(format!(
                        "{}/api/control/local-origins",
                        c.api_url.trim_end_matches('/')
                    ))
                    .bearer_auth(&c.token)
                    .json(&record.snapshot)
                    .send()
                    .await;
                match response {
                    Ok(r) if r.status().is_success() => {
                        record.acked = record.snapshot.sequence;
                        record.error = None;
                    }
                    Ok(r) => {
                        let status = r.status();
                        let detail = r.text().await.unwrap_or_default();
                        let detail: String = detail.chars().take(512).collect();
                        record.error =
                            Some(format!("Core synchronization refused ({status}): {detail}"));
                        if status.as_u16() == 409 {
                            // Never stop a successor or an unidentifiable legacy execution.
                            if let Some(generation) = generation.as_deref() {
                                let _ = local_agents::stop_generation(&id, Some(generation));
                            }
                        }
                        let _ = write(&path, &record);
                        if matches!(status.as_u16(), 401 | 403) {
                            let mut connections = connections().lock().await;
                            if connections
                                .get(path.parent().unwrap())
                                .is_some_and(|current| current.token == c.token)
                            {
                                connections.remove(path.parent().unwrap());
                            }
                        }
                        if status.as_u16() == 409 {
                            break;
                        }
                    }
                    Err(_) => record.error = Some("Offline · saved on this computer".into()),
                }
                if write(&path, &record).is_err() {
                    break;
                }
            }
            if record.acked == record.snapshot.sequence && record.snapshot.status != "active" {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
        workers().lock().await.remove(&path);
    });
}
#[tauri::command]
pub async fn local_origin_list(connection: Connection) -> Result<Vec<Value>, String> {
    let root = account(&connection)?;
    if !root.exists() {
        return Ok(vec![]);
    }
    let mut rows = vec![];
    for entry in std::fs::read_dir(root).map_err(|e| e.to_string())? {
        let path = entry.map_err(|e| e.to_string())?.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let record = read(&path)?;
        // Fully synchronized history is served by Core; retain the disk journal.
        rows.push(view(&record));
        if pending(&record) {
            start_worker(path, connection.clone()).await;
        }
    }
    Ok(rows)
}
/// Remember what Core confirmed, so a restart without Core shows the same list.
#[tauri::command]
pub async fn local_origin_confirm(
    connection: Connection,
    confirmations: Vec<Confirmation>,
) -> Result<(), String> {
    let root = account(&connection)?;
    if !root.exists() || confirmations.is_empty() {
        return Ok(());
    }
    for confirmation in &confirmations {
        confirmation.validate()?;
    }
    let now = chrono::Utc::now().timestamp_millis().max(0) as u64;
    for entry in std::fs::read_dir(root).map_err(|e| e.to_string())? {
        let path = entry.map_err(|e| e.to_string())?.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let mut record = read(&path)?;
        let id = record.snapshot.origin.id.to_string();
        let local_pending = pending(&record);
        let mut changed = false;
        for confirmation in confirmations.iter().filter(|c| c.id == id) {
            changed |= confirmed::merge(&mut record.confirmed, local_pending, confirmation, now);
        }
        if changed {
            write(&path, &record)?;
        }
    }
    Ok(())
}
#[tauri::command]
pub async fn local_origin_launch(
    mut request: local_agents::StartRequest,
    draft: Draft,
    connection: Connection,
) -> Result<Value, String> {
    // Ignore caller IDs and session IDs. This authority creates NEW runs only.
    let id = uuid::Uuid::new_v4();
    let run_id = uuid::Uuid::new_v4();
    request.id = id.to_string();
    request.session_id = None;
    request.cwd = local_agents::local_agents_directory(request.cwd)?;
    let root = account(&connection)?;
    std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    let key = uuid::Uuid::parse_str(&draft.key).map_err(|_| "Invalid draft identity")?;
    let path = root.join(format!("{key}.json"));
    use fs2::FileExt;
    let guard = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .read(true)
        .open(root.join(format!("{key}.launch.lock")))
        .map_err(|e| e.to_string())?;
    guard
        .try_lock_exclusive()
        .map_err(|_| "This draft is already starting")?;
    if path.exists() {
        let record = read(&path)?;
        if record.snapshot.origin.prompt != draft.prompt
            || record.snapshot.origin.project != draft.project
            || record.snapshot.origin.backend != request.harness
            || record.snapshot.origin.model != request.model
            || record.snapshot.origin.cwd != request.cwd
        {
            return Err("Draft identity already used".into());
        }
        let result = view(&record);
        start_worker(path, connection).await;
        return Ok(result);
    }

    // Serialize check-through-spawn for new origins. Same-draft replay above
    // remains idempotent; different drafts cannot reserve the same directory.
    static LAUNCH: OnceLock<Mutex<()>> = OnceLock::new();
    let _launch = LAUNCH.get_or_init(|| Mutex::new(())).lock().await;
    if local_agents::workspace_busy(Path::new(&request.cwd))? {
        return Err("This directory already has a running local mission. Choose a separate directory or worktree.".into());
    }

    // Execution stays in the chosen directory; the journal above remains private.
    let snapshot = Snapshot {
        origin: Origin {
            id,
            run_id,
            client_id: crate::transfers::local_machine_identity()?
                .parse()
                .map_err(|_| "Invalid computer identity")?,
            title: draft.title,
            project: draft.project,
            backend: request.harness.clone(),
            model: request.model.clone(),
            cwd: request.cwd.clone(),
            prompt: draft.prompt,
            created_at: chrono::Utc::now().to_rfc3339(),
            tags: draft.tags,
        },
        sequence: 1,
        text: String::new(),
        status: "active".into(),
        error: None,
    };
    snapshot.validate()?;
    let mut record = Record {
        snapshot,
        acked: 0,
        native_generation: None,
        error: None,
        confirmed: None,
    };
    write(&path, &record)?;
    crate::local_bindings(
        Some(id.to_string()),
        Some(
            json!({"harness":request.harness,"bin":request.bin,"cwd":request.cwd,"model":request.model}),
        ),
    )?;
    // Core must know the durable identity before it can issue this mission's
    // MCP grant. Registering the snapshot never dispatches a second harness.
    let started = async {
        let response = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(20))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| "Cannot initialize Core registration".to_string())?
            .post(format!(
                "{}/api/control/local-origins",
                connection.api_url.trim_end_matches('/')
            ))
            .bearer_auth(&connection.token)
            .json(&record.snapshot)
            .send()
            .await
            .map_err(|_| "Connect to Core before starting a mission with MCP access".to_string())?;
        if !response.status().is_success() {
            return Err(format!(
                "Core refused local mission registration ({})",
                response.status()
            ));
        }
        let receipt: Value = response
            .json()
            .await
            .map_err(|_| "Invalid Core registration receipt".to_string())?;
        if receipt["ok"] != true {
            return Err("Core did not acknowledge the local mission".into());
        }
        record.acked = record.snapshot.sequence;
        write(&path, &record)?;
        crate::routed_opencode::start(request, &connection.api_url, &connection.token).await
    }
    .await;
    if started.is_ok() {
        record.native_generation = local_agents::native_generation(&id.to_string());
        write(&path, &record)?;
    }
    if let Err(error) = started {
        record.snapshot.status = "failed".into();
        record.snapshot.sequence += 1;
        record.snapshot.error = Some(error);
        write(&path, &record)?;
    }
    let result = view(&record);
    start_worker(path, connection).await;
    Ok(result)
}
