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
            input.write_all(&stdin.unwrap_or_default()).map_err(|e| e.to_string())?;
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
        return Ok(ApprovalKey { available: signer().is_ok(), public_key: None, platform: "macos" });
    }
    let v = run(vec!["public".into(), "--key".into(), path.display().to_string()], None).await?;
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
    let v = run(vec!["create".into(), "--key".into(), path.display().to_string()], None).await?;
    v["public_key"].as_str().map(str::to_string).ok_or_else(|| "No public key returned".into())
}

/// Sign an approval payload after Touch ID. Returns the base64 DER signature.
#[tauri::command]
pub async fn approval_sign(app: tauri::AppHandle, payload: String, reason: String) -> Result<String, String> {
    let path = key_path(&app)?;
    let v = run(
        vec!["sign".into(), "--key".into(), path.display().to_string(), "--reason".into(), reason],
        Some(payload.into_bytes()),
    )
    .await?;
    v["signature"].as_str().map(str::to_string).ok_or_else(|| "No signature returned".into())
}
