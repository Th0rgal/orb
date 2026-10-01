//! Local requests are persisted without credentials. Core is the only timer.
use crate::{local_agents::StartRequest, run_recovery::Connection};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Mutex, OnceLock},
};

static SYNC_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn contexts() -> &'static Mutex<HashMap<String, PathBuf>> {
    static MAP: OnceLock<Mutex<HashMap<String, PathBuf>>> = OnceLock::new();
    MAP.get_or_init(Default::default)
}
fn account(c: &Connection) -> Result<PathBuf, String> {
    use base64::Engine;
    let sub = c
        .token
        .split('.')
        .nth(1)
        .and_then(|s| {
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(s)
                .ok()
        })
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v["sub"].as_str().map(str::to_owned))
        .ok_or("Reconnect to Core before scheduling wake-ups")?;
    let key = crate::project_context_store::digest(
        format!("{}\n{sub}", c.api_url.trim_end_matches('/')).as_bytes(),
    );
    Ok(
        PathBuf::from(std::env::var("HOME").map_err(|e| e.to_string())?)
            .join(".orb/wakeups")
            .join(key),
    )
}
fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
pub fn prepare(request: &mut StartRequest, c: &Connection) -> Result<(), String> {
    uuid::Uuid::parse_str(&request.id).map_err(|_| "Invalid mission ID")?;
    let root = account(c)?.join(&request.id);
    std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    let script = root.join("wakeup_mcp.py");
    std::fs::write(&script, include_str!("wakeup_mcp.py")).map_err(|e| e.to_string())?;
    contexts()
        .lock()
        .unwrap()
        .insert(request.id.clone(), root.clone());
    // Grok's installed CLI may not expose an injectable MCP transport. The
    // credential-free command is the same durable transport as the MCP tools.
    request.prompt.push_str(&format!("\n\n[Orb scheduling] Core owns durable wake-ups. Use orb-wakeups MCP schedule_wakeup / schedule_job_wakeup. If MCP is unavailable, invoke python3 {} {} {} schedule_wakeup '<JSON with request_id, delay_seconds, prompt, reason>'. A pending_sync receipt is saved locally, not yet scheduled on Core. Never also start a native timer for the same request.", quote(&script.to_string_lossy()), quote(&root.to_string_lossy()), quote(&request.id)));
    Ok(())
}
pub fn command(mission: &str) -> Option<Vec<String>> {
    let root = contexts().lock().ok()?.get(mission)?.clone();
    Some(vec![
        "python3".into(),
        root.join("wakeup_mcp.py").to_string_lossy().into_owned(),
        root.to_string_lossy().into_owned(),
        mission.into(),
    ])
}

#[tauri::command]
pub async fn local_wakeups_sync(connection: Connection) -> Result<Value, String> {
    let _guard = SYNC_LOCK.lock().await;
    let root = account(&connection)?;
    let mut pending = Vec::new();
    let mut changed = false;
    let mut files = Vec::new();
    if root.exists() {
        for dir in std::fs::read_dir(&root)
            .map_err(|e| e.to_string())?
            .flatten()
        {
            if !dir.path().is_dir() {
                continue;
            }
            for file in std::fs::read_dir(dir.path())
                .map_err(|e| e.to_string())?
                .flatten()
            {
                if file.path().extension().is_some_and(|e| e == "json") {
                    let v: Value = serde_json::from_slice(
                        &std::fs::read(file.path()).map_err(|e| e.to_string())?,
                    )
                    .map_err(|e| e.to_string())?;
                    files.push((file.path(), v));
                }
            }
        }
    }
    files.sort_by_key(|(_, v)| v["created_ns"].as_u64().unwrap_or(0));
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .map_err(|e| e.to_string())?;
    let mut blocked: HashMap<String, String> = HashMap::new();
    let mut offline = false;
    let mut attempts = 0;
    for (path, v) in files {
        let mission = v["mission"].as_str().ok_or("Invalid wake-up mission")?;
        uuid::Uuid::parse_str(mission).map_err(|_| "Invalid wake-up mission")?;
        let endpoint = if v["cancel"] == true {
            "continuations/cancel"
        } else {
            "automations"
        };
        let error = if offline || blocked.contains_key(mission) || attempts >= 10 {
            "Waiting for earlier wake-up requests to sync".to_string()
        } else {
            attempts += 1;
            match http
                .post(format!(
                    "{}/api/control/missions/{mission}/{endpoint}",
                    connection.api_url.trim_end_matches('/')
                ))
                .bearer_auth(&connection.token)
                .json(&v["body"])
                .send()
                .await
            {
                Ok(r) if r.status().is_success() => {
                    std::fs::rename(&path, path.with_extension("acked"))
                        .map_err(|e| e.to_string())?;
                    changed = true;
                    continue;
                }
                Ok(r) => {
                    let message = format!("Core refused wake-up ({})", r.status());
                    blocked.insert(mission.into(), message.clone());
                    message
                }
                Err(_) => {
                    offline = true;
                    "Waiting for a connection to Core".to_owned()
                }
            }
        };
        let request_id = v["body"]["variables"]["__wakeup_request_id"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| {
                path.file_stem()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned()
            });
        pending.push(json!({"mission":mission, "id":request_id,
            "state":"pending_sync", "trigger":"time", "reason":if v["cancel"] == true { json!("Cancellation waiting to sync") } else {v["body"]["variables"]["__wakeup_reason"].clone()},
            "next_at":v["body"]["variables"]["__wakeup_due_at"], "error":error}));
        // Keep creation order when disconnected; an older request must never
        // arrive after and replace a newer request.
    }
    Ok(json!({"pending": pending, "changed":changed}))
}

/// Persist native print-mode ScheduleWakeup through exactly the same outbox.
pub fn capture(mission: &str, args: Value) -> Result<(), String> {
    let Some(command) = command(mission) else {
        return Err("No durable scheduling context for this native wake-up".into());
    };
    let result = std::process::Command::new(&command[0])
        .args(&command[1..])
        .arg("schedule_wakeup")
        .arg(args.to_string())
        .output()
        .map_err(|e| format!("Could not save wake-up: {e}"))?;
    if !result.status.success() {
        return Err("Could not persist native wake-up; no wake-up is confirmed".into());
    }
    Ok(())
}

#[tauri::command]
pub async fn local_wakeups_cancel(connection: Connection, mission: String) -> Result<(), String> {
    use std::io::Write;
    let _guard = SYNC_LOCK.lock().await;
    uuid::Uuid::parse_str(&mission).map_err(|_| "Invalid mission ID")?;
    let root = account(&connection)?.join(&mission);
    std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    for file in std::fs::read_dir(&root)
        .map_err(|e| e.to_string())?
        .flatten()
    {
        if file.path().extension().is_some_and(|e| e == "json") {
            std::fs::rename(file.path(), file.path().with_extension("cancelled"))
                .map_err(|e| e.to_string())?;
        }
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos() as u64;
    let value = json!({"mission":mission,"created_ns":now,"cancel":true,"body":{}});
    let path = root.join(format!("cancel-{now}.tmp"));
    let mut file = std::fs::File::create(&path).map_err(|e| e.to_string())?;
    file.write_all(value.to_string().as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|e| e.to_string())?;
    std::fs::rename(&path, path.with_extension("json")).map_err(|e| e.to_string())?;
    Ok(())
}
