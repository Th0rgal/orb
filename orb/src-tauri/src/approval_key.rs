//! Secure Enclave approval key (macOS). Core accepts sensitive operations only
//! with a signature from an enrolled device key; this module drives the
//! bundled `orb-signer` helper, which owns the key and asks for Touch ID.

use serde::Serialize;
use std::path::PathBuf;
use std::process::Stdio;
use tauri::Manager;

#[derive(Serialize)]
pub struct ApprovalKey {
    pub available: bool,
    pub public_key: Option<String>,
    pub platform: &'static str,
}

fn signer() -> Result<PathBuf, String> {
    let current = std::env::current_exe().map_err(|e| e.to_string())?;
    let path = current.with_file_name("orb-signer");
    if path.is_file() {
        Ok(path)
    } else {
        Err("The orb-signer helper is missing from this Orb build".into())
    }
}

fn key_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("approval-key.bin"))
}

async fn run(args: Vec<String>, stdin: Option<Vec<u8>>) -> Result<serde_json::Value, String> {
    let bin = signer()?;
    tauri::async_runtime::spawn_blocking(move || {
        let mut child = std::process::Command::new(bin)
            .args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| e.to_string())?;
        if let Some(mut input) = child.stdin.take() {
            use std::io::Write;
            input
                .write_all(&stdin.unwrap_or_default())
                .map_err(|e| e.to_string())?;
        }
        let out = child.wait_with_output().map_err(|e| e.to_string())?;
        if out.status.code() == Some(2) {
            return Err("cancelled".to_string());
        }
        if !out.status.success() {
            return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
        }
        serde_json::from_slice(&out.stdout).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// The approval key, if this Mac already has one.
#[tauri::command]
pub async fn approval_key_status(app: tauri::AppHandle) -> Result<ApprovalKey, String> {
    let path = key_path(&app)?;
    if !path.is_file() || signer().is_err() {
        return Ok(ApprovalKey {
            available: signer().is_ok(),
            public_key: None,
            platform: "macos",
        });
    }
    let v = run(
        vec!["public".into(), "--key".into(), path.display().to_string()],
        None,
    )
    .await?;
    Ok(ApprovalKey {
        available: true,
        public_key: v["public_key"].as_str().map(str::to_string),
        platform: "macos",
    })
}

/// Create (or replace) the Secure Enclave key; returns its public key.
#[tauri::command]
pub async fn approval_key_create(app: tauri::AppHandle) -> Result<String, String> {
    let path = key_path(&app)?;
    let v = run(
        vec!["create".into(), "--key".into(), path.display().to_string()],
        None,
    )
    .await?;
    v["public_key"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| "No public key returned".into())
}

/// A long-lived `orb-signer serve`: one Touch ID covers approvals for a short
/// grace period (held by the helper, not by this process).
struct Server {
    child: std::process::Child,
    stdin: std::process::ChildStdin,
    stdout: std::io::BufReader<std::process::ChildStdout>,
    key: PathBuf,
}

static SERVER: std::sync::Mutex<Option<Server>> = std::sync::Mutex::new(None);

/// Unix seconds until which the helper signs eligible approvals without
/// Touch ID; 0 when it holds no authenticated context.
static GRACE_UNTIL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// How long one Touch ID covers further secret-request decisions (seconds).
static GRACE_SECS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(300);

/// Changes the grace length; the running helper (and its held context) is
/// dropped so the next approval starts a helper with the new setting.
#[tauri::command]
pub fn set_approval_grace(secs: u64) {
    let secs = secs.min(3600);
    if GRACE_SECS.swap(secs, std::sync::atomic::Ordering::Relaxed) == secs {
        return;
    }
    if let Ok(mut guard) = SERVER.lock() {
        if let Some(mut old) = guard.take() {
            let _ = old.child.kill();
            let _ = old.child.wait();
        }
    }
    GRACE_UNTIL.store(0, std::sync::atomic::Ordering::Relaxed);
}

#[tauri::command]
pub fn approval_grace_until() -> u64 {
    GRACE_UNTIL.load(std::sync::atomic::Ordering::Relaxed)
}

fn spawn_server(key: &std::path::Path) -> Result<Server, String> {
    let mut child = std::process::Command::new(signer()?)
        .args(["serve", "--key", &key.display().to_string()])
        .args([
            "--grace",
            &GRACE_SECS
                .load(std::sync::atomic::Ordering::Relaxed)
                .to_string(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| e.to_string())?;
    let stdin = child.stdin.take().ok_or("signer stdin unavailable")?;
    let stdout = std::io::BufReader::new(child.stdout.take().ok_or("signer stdout unavailable")?);
    Ok(Server {
        child,
        stdin,
        stdout,
        key: key.to_path_buf(),
    })
}

fn request(server: &mut Server, payload: &str) -> std::io::Result<serde_json::Value> {
    use base64::Engine;
    use std::io::{BufRead, Write};
    let line = base64::engine::general_purpose::STANDARD.encode(payload.as_bytes());
    writeln!(server.stdin, "{line}")?;
    server.stdin.flush()?;
    let mut reply = String::new();
    if server.stdout.read_line(&mut reply)? == 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "signer exited",
        ));
    }
    serde_json::from_str(&reply)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
}

/// Sign an approval payload. Touch ID is asked unless one succeeded in the
/// last few minutes. Returns the base64 DER signature.
#[tauri::command]
pub async fn approval_sign(
    app: tauri::AppHandle,
    payload: String,
    reason: String,
) -> Result<String, String> {
    let _ = reason; // Touch ID shows the summary signed inside the payload.
    let key = key_path(&app)?;
    let v = tauri::async_runtime::spawn_blocking(move || {
        let mut guard = SERVER
            .lock()
            .map_err(|_| "signer lock poisoned".to_string())?;
        // A replaced key (re-enrolment) or a dead helper needs a fresh server.
        if guard
            .as_mut()
            .is_some_and(|s| s.key != key || !matches!(s.child.try_wait(), Ok(None)))
        {
            if let Some(mut old) = guard.take() {
                let _ = old.child.kill();
                let _ = old.child.wait();
            }
        }
        for attempt in 0..2 {
            if guard.is_none() {
                *guard = Some(spawn_server(&key)?);
            }
            match request(guard.as_mut().unwrap(), &payload) {
                Ok(v) => return Ok(v),
                Err(e) => {
                    if let Some(mut old) = guard.take() {
                        let _ = old.child.kill();
                        let _ = old.child.wait();
                    }
                    if attempt == 1 {
                        return Err(e.to_string());
                    }
                }
            }
        }
        unreachable!()
    })
    .await
    .map_err(|e| e.to_string())??;
    let until = v["grace_until"]
        .as_str()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    GRACE_UNTIL.store(until, std::sync::atomic::Ordering::Relaxed);
    if let Some(error) = v["error"].as_str() {
        return Err(if v["code"].as_str() == Some("2") {
            "cancelled".to_string()
        } else {
            error.to_string()
        });
    }
    v["signature"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| "No signature returned".into())
}
