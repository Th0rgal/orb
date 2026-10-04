//! Antigravity has a workspace MCP file, but no per-process MCP flag.
//! Hold an exclusive checkout lease and restore the original file on exit.
use fs2::FileExt;
use serde_json::{json, Value};
use std::{
    fs::{File, OpenOptions},
    path::{Path, PathBuf},
};

pub struct Overlay {
    path: PathBuf,
    original: Option<Vec<u8>>,
    installed: Vec<u8>,
    _lock: File,
}
impl Overlay {
    pub fn install(cwd: &Path, config: &Value) -> Result<Self, String> {
        let directory = cwd.join(".agents");
        if directory.is_symlink() {
            return Err("Antigravity .agents must not be a symlink".into());
        }
        std::fs::create_dir_all(&directory)
            .map_err(|_| "Cannot create Antigravity MCP directory")?;
        let lock_path = directory.join(".sandboxed-mcp.lock");
        if lock_path.is_symlink() {
            return Err("Antigravity MCP lock must not be a symlink".into());
        }
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(lock_path)
            .map_err(|_| "Cannot open Antigravity MCP lock")?;
        lock.try_lock_exclusive().map_err(|_| {
            "Another Antigravity run owns this checkout's MCP config; use a separate worktree"
        })?;
        let path = directory.join("mcp_config.json");
        if path.is_symlink() {
            return Err("Antigravity MCP config must not be a symlink".into());
        }
        let original = match std::fs::read(&path) {
            Ok(bytes) => Some(bytes),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => return Err("Cannot read Antigravity MCP config".into()),
        };
        let mut merged: Value = match &original {
            Some(bytes) => {
                serde_json::from_slice(bytes).map_err(|_| "Invalid Antigravity MCP config")?
            }
            None => json!({}),
        };
        if !merged.is_object() {
            return Err("Antigravity MCP config must be an object".into());
        }
        if merged.get("mcpServers").is_none() {
            merged["mcpServers"] = json!({});
        }
        let servers = merged["mcpServers"]
            .as_object_mut()
            .ok_or("Antigravity mcpServers must be an object")?;
        if servers.contains_key("sandboxed") {
            return Err("Antigravity workspace already defines sandboxed MCP; remove the stale runtime entry or rename the existing server".into());
        }
        servers.insert(
            "sandboxed".into(),
            config["mcpServers"]["sandboxed"].clone(),
        );
        let installed =
            serde_json::to_vec_pretty(&merged).map_err(|_| "Cannot encode MCP config")?;
        use std::io::Write;
        let mut staged = tempfile::NamedTempFile::new_in(&directory)
            .map_err(|_| "Cannot stage Antigravity MCP config")?;
        staged
            .write_all(&installed)
            .map_err(|_| "Cannot write Antigravity MCP config")?;
        staged
            .persist(&path)
            .map_err(|_| "Cannot install Antigravity MCP config")?;
        Ok(Self {
            path,
            original,
            installed,
            _lock: lock,
        })
    }
}
impl Drop for Overlay {
    fn drop(&mut self) {
        // Preserve edits made externally during the run.
        if self.path.is_symlink()
            || self.path.parent().is_some_and(|parent| parent.is_symlink())
            || std::fs::read(&self.path).ok().as_deref() != Some(self.installed.as_slice())
        {
            return;
        }
        match &self.original {
            Some(bytes) => {
                let _ = std::fs::write(&self.path, bytes);
            }
            None => {
                let _ = std::fs::remove_file(&self.path);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_existing_servers_and_serializes_workspace() {
        let temp = tempfile::tempdir().unwrap();
        let directory = temp.path().join(".agents");
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("mcp_config.json");
        let original = br#"{"mcpServers":{"user":{"command":"user-server"}}}"#;
        std::fs::write(&path, original).unwrap();
        let config = json!({"mcpServers":{"sandboxed":{"command":"scoped-server"}}});
        let overlay = Overlay::install(temp.path(), &config).unwrap();
        let merged: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(merged["mcpServers"]["user"]["command"], "user-server");
        assert!(Overlay::install(temp.path(), &config).is_err());
        drop(overlay);
        assert_eq!(std::fs::read(path).unwrap(), original);
    }
}
