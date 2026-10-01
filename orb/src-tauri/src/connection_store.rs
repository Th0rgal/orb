//! Shared desktop connection across the packaged and Vite web origins.
use serde::{Deserialize, Serialize};
use std::{io::Write, path::PathBuf};
#[derive(Deserialize, Serialize)]
pub struct SavedConnection {
    pub api_url: String,
    pub token: String,
}
fn path() -> Result<PathBuf, String> {
    Ok(
        PathBuf::from(std::env::var("HOME").map_err(|e| e.to_string())?)
            .join(".orb/connection.json"),
    )
}
#[tauri::command]
pub fn desktop_connection_load() -> Result<Option<SavedConnection>, String> {
    match std::fs::read(path()?) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|_| "Invalid saved connection".into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err("Cannot read saved connection".into()),
    }
}
#[tauri::command]
pub fn desktop_connection_save(connection: Option<SavedConnection>) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    let path = path()?;
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
    let temporary = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|e| e.to_string())?;
    let result = (|| {
        let bytes = serde_json::to_vec(&connection).map_err(|e| e.to_string())?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|e| e.to_string())?;
        std::fs::rename(&temporary, &path).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
}
