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
    sync_at(&connection, account(&connection)?).await
}

async fn sync_at(connection: &Connection, root: PathBuf) -> Result<Value, String> {
    let mut pending = Vec::new();
    let mut cancelled = Vec::new();
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
                if file.path().extension().is_some_and(|e| {
                    e == "json"
                        || e == "rejected"
                        || (e == "acked"
                            && file.file_name().to_string_lossy().starts_with("cancel-"))
                }) {
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
        let confirmation = (v["cancel"] == true)
            .then(|| v["cancel_token"].as_str())
            .flatten()
            .map(|token| json!({"mission":mission,"token":token}));
        if path.extension().is_some_and(|e| e == "acked") {
            if let Some(confirmation) = confirmation {
                cancelled.push(confirmation);
            }
            continue;
        }
        let endpoint = if v["cancel"] == true {
            "continuations/cancel"
        } else {
            "automations"
        };
        let mut rejected = path.extension().is_some_and(|e| e == "rejected");
        let error = if rejected {
            "Core rejected this wake-up. Dismiss it and submit a corrected request.".to_string()
        } else if offline || blocked.contains_key(mission) || attempts >= 10 {
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
                    if let Some(confirmation) = confirmation {
                        cancelled.push(confirmation);
                    }
                    continue;
                }
                Ok(r) => {
                    let message = format!("Core refused wake-up ({})", r.status());
                    // 404 may mean the local-origin mission has not synced yet.
                    // Auth, conflicts, rate limits and network failures remain retryable.
                    if matches!(r.status().as_u16(), 400 | 413 | 422) && v["cancel"] != true {
                        std::fs::rename(&path, path.with_extension("rejected"))
                            .map_err(|e| e.to_string())?;
                        rejected = true;
                        changed = true;
                    } else {
                        blocked.insert(mission.into(), message.clone());
                    }
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
            "state":if rejected {"error"} else {"pending_sync"}, "source":if rejected {"orb-local-rejected"} else {"orb-local"}, "trigger":"time", "reason":if v["cancel"] == true { json!("Cancellation waiting to sync") } else {v["body"]["variables"]["__wakeup_reason"].clone()},
            "next_at":v["body"]["variables"]["__wakeup_due_at"], "error":error}));
        // Keep creation order when disconnected; an older request must never
        // arrive after and replace a newer request.
    }
    Ok(json!({"pending": pending, "changed":changed, "cancelled":cancelled}))
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
pub async fn local_wakeups_cancel(
    connection: Connection,
    mission: String,
    cancel_token: Option<String>,
) -> Result<(), String> {
    use std::io::Write;
    let _guard = SYNC_LOCK.lock().await;
    uuid::Uuid::parse_str(&mission).map_err(|_| "Invalid mission ID")?;
    let root = account(&connection)?.join(&mission);
    std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    for file in std::fs::read_dir(&root)
        .map_err(|e| e.to_string())?
        .flatten()
    {
        if file
            .path()
            .extension()
            .is_some_and(|e| e == "json" || e == "rejected")
        {
            std::fs::rename(file.path(), file.path().with_extension("cancelled"))
                .map_err(|e| e.to_string())?;
        }
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos() as u64;
    let token = cancel_token.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let value =
        json!({"mission":mission,"created_ns":now,"cancel":true,"cancel_token":token,"body":{}});
    let path = root.join(format!("cancel-{now}.tmp"));
    let mut file = std::fs::File::create(&path).map_err(|e| e.to_string())?;
    file.write_all(value.to_string().as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|e| e.to_string())?;
    std::fs::rename(&path, path.with_extension("json")).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub async fn local_wakeups_discard(
    connection: Connection,
    mission: String,
    request_id: String,
) -> Result<(), String> {
    let _guard = SYNC_LOCK.lock().await;
    uuid::Uuid::parse_str(&mission).map_err(|_| "Invalid mission ID")?;
    let root = account(&connection)?.join(mission);
    discard_rejected(&root, &request_id)
}

fn discard_rejected(root: &std::path::Path, request_id: &str) -> Result<(), String> {
    use sha2::{Digest, Sha256};
    let key = format!("{:x}", Sha256::digest(request_id.as_bytes()));
    let path = root.join(key).with_extension("rejected");
    if path.exists() {
        std::fs::rename(&path, path.with_extension("cancelled")).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    #[tokio::test]
    async fn cancellation_confirmation_survives_a_lost_frontend_response() {
        let dir = tempfile::tempdir().unwrap();
        let mission = uuid::Uuid::new_v4().to_string();
        let root = dir.path().join(&mission);
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("cancel-1.acked"), json!({"mission":mission,"created_ns":1,"cancel":true,"cancel_token":"stop-token","body":{}}).to_string()).unwrap();
        let connection = Connection {
            api_url: "http://127.0.0.1:1".into(),
            token: "test".into(),
        };
        for _ in 0..2 {
            let result = sync_at(&connection, dir.path().to_owned()).await.unwrap();
            assert_eq!(
                result["cancelled"],
                json!([{"mission":mission,"token":"stop-token"}])
            );
            assert_eq!(result["pending"], json!([]));
        }
    }

    #[tokio::test]
    async fn permanently_rejected_request_does_not_block_newer_wakeup() {
        let dir = tempfile::tempdir().unwrap();
        let mission = uuid::Uuid::new_v4().to_string();
        let root = dir.path().join(&mission);
        std::fs::create_dir(&root).unwrap();
        use sha2::{Digest, Sha256};
        for (i, key) in ["invalid-job", "valid-timer"].iter().enumerate() {
            let name = format!("{:x}.json", Sha256::digest(key.as_bytes()));
            std::fs::write(root.join(name), json!({"mission":mission,"created_ns":i,"body":{"variables":{"__wakeup_request_id":key}}}).to_string()).unwrap();
        }
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            for status in ["400 Bad Request", "200 OK"] {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                    .unwrap();
                let mut request = Vec::new();
                loop {
                    let mut bytes = [0; 4096];
                    let n = socket.read(&mut bytes).unwrap();
                    assert!(n > 0);
                    request.extend_from_slice(&bytes[..n]);
                    if let Some(end) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                        let headers = String::from_utf8_lossy(&request[..end]).to_lowercase();
                        let length: usize = headers
                            .lines()
                            .find_map(|line| line.strip_prefix("content-length:"))
                            .unwrap()
                            .trim()
                            .parse()
                            .unwrap();
                        if request.len() >= end + 4 + length {
                            break;
                        }
                    }
                }
                write!(
                    socket,
                    "HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                )
                .unwrap();
            }
        });
        let c = Connection {
            api_url: url,
            token: "test".into(),
        };
        let synced = sync_at(&c, dir.path().to_owned()).await.unwrap();
        assert_eq!(synced["pending"].as_array().unwrap().len(), 1);
        assert_eq!(synced["pending"][0]["source"], "orb-local-rejected");
        server.join().unwrap();
        // No server remains: another sync must not retry the rejected request.
        let again = sync_at(&c, dir.path().to_owned()).await.unwrap();
        assert_eq!(again["pending"][0]["state"], "error");
        discard_rejected(&root, "invalid-job").unwrap();
        assert_eq!(
            sync_at(&c, dir.path().to_owned()).await.unwrap()["pending"],
            json!([])
        );
        assert_eq!(
            std::fs::read_dir(&root)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|f| f.path().extension().is_some_and(|e| e == "acked"))
                .count(),
            1
        );
    }
}
