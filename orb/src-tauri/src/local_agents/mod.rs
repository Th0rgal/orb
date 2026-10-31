//! Local harnesses. Orb spawns the CLIs already installed on this machine.
//! It does not embed sandboxed.sh and does not read the backend's credentials.
//!
//! Claude Code: `claude --print --output-format stream-json`.
//! Codex: `codex app-server` (initialize, thread/start or thread/resume, turn/start).
//! OpenCode: `opencode run --format json`, `--session ses_*` or `--continue`.
//! Grok: `grok -p --output-format streaming-json`, with native `--resume`.
//!
//! Layout:
//! - `registry`: the run table, launch fences, `Slot` and `RunCtx`.
//! - `lifecycle`: start, exit watching, poll and stop.
//! - `orphans`: processes a previous Orb left behind.
//! - `groups`: the process groups Orb launched, persisted with start times.
//! - `command`: building and probing harness commands.
//! - `io`: bounded pipe readers shared by every harness.
//! - `paths`: workspace and attachment path rules.
//! - `harness::*`: one module per native protocol.

mod command;
mod groups;
pub(crate) mod harness;
mod io;
mod lifecycle;
mod orphans;
mod paths;
mod registry;

use crate::local_stream::{Event as OutputEvent, Output};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use command::*;
use io::*;
use lifecycle::*;
use orphans::*;
use paths::*;
use registry::*;

pub(crate) use lifecycle::{
    poll_generation, start_with_env, start_with_env_fenced, stop_generation, subscribe_native,
    wait_stopped, DIRECTORY_BUSY,
};
pub(crate) use orphans::{has_orphan_mission_processes, stop_orphan_mission_processes};
pub(crate) use registry::{
    active_pids, clear_subscriptions, launch_fence, native_generation, workspace_busy,
    workspace_busy_for, LAUNCH_CANCELLED,
};

#[tauri::command]
pub fn local_agents_cyber_capabilities() -> u32 {
    2
}

#[tauri::command]
pub async fn local_codex_speed_options(bin: String, model: String) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || harness::codex::probe_speed_options(&bin, &model))
        .await
        .map_err(|e| e.to_string())?
}

#[derive(Debug, Deserialize)]
pub struct ScanRequest {
    #[serde(default)]
    pub overrides: HashMap<String, String>,
}

#[derive(Debug, Serialize)]
pub struct ScanRow {
    pub models: Vec<(String, String)>,
    pub auth_error: Option<String>,
    pub id: String,
    pub bin: String,
    pub path: Option<String>,
    pub version: Option<String>,
    pub installed: bool,
    pub plan_supported: bool,
}

#[derive(Debug, Deserialize)]
pub struct WorkspaceRequest {
    pub slug: String,
}

#[derive(Debug, Deserialize)]
pub struct WriteFile {
    #[serde(default)]
    pub encoding: Option<String>,
    pub rel: String,
    pub content: String,
}

#[derive(Debug, Deserialize)]
pub struct WriteRequest {
    pub root: String,
    pub files: Vec<WriteFile>,
}

#[derive(Debug, Serialize)]
pub struct WriteReport {
    pub binary_supported: bool,
    pub written: Vec<String>,
    pub skipped: Vec<String>,
}

#[derive(Debug, Default, Clone, Deserialize)]
pub struct StartRequest {
    pub service_tier: Option<crate::codex_speed::Tier>,
    pub cyber_revision: Option<uuid::Uuid>,
    pub cyber_access: Option<crate::cyber_access::Mode>,
    #[serde(default)]
    pub image_paths: Vec<String>,
    pub id: String,
    pub harness: String,
    pub bin: String,
    pub cwd: String,
    pub prompt: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub session_id: Option<String>,
    #[serde(default)]
    pub shared_cwd_with: Option<String>,
}

#[derive(Debug, Serialize, Clone)]
pub struct PollState {
    pub activities: Vec<crate::local_stream::Activity>,
    pub text: String,
    pub done: bool,
    pub exit_code: Option<i32>,
    pub session_id: Option<String>,
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub retryable: bool,
    pub resumed: bool,
    /// Set while the turn has answered and only its background tasks remain.
    pub waiting_since: Option<u64>,
    /// Stop signalled the process group; `done` follows once it has exited.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub stopping: bool,
}

#[tauri::command]
pub async fn local_agents_scan(request: ScanRequest) -> Result<Vec<ScanRow>, String> {
    // CLI discovery launches subprocesses; never block the desktop event loop.
    tauri::async_runtime::spawn_blocking(move || scan_local_agents(request))
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub async fn local_antigravity_models(path: String) -> Result<Vec<(String, String)>, String> {
    tauri::async_runtime::spawn_blocking(move || crate::antigravity::models(Path::new(&path)))
        .await
        .map_err(|error| error.to_string())?
}

/// Models this computer's Claude Code offers; no inference request is sent.
#[tauri::command]
pub async fn local_claude_models(path: String) -> Result<Vec<(String, String)>, String> {
    tauri::async_runtime::spawn_blocking(move || harness::claude_models::models(&path))
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub fn local_agents_directory(path: String) -> Result<String, String> {
    let requested = Path::new(path.trim());
    if !requested.is_absolute() {
        return Err("Use an absolute working directory path".into());
    }
    let resolved = requested
        .canonicalize()
        .map_err(|e| format!("Working directory is unavailable: {e}"))?;
    if !resolved.is_dir() {
        return Err("Working directory is not a folder".into());
    }
    Ok(resolved.to_string_lossy().into_owned())
}

#[tauri::command]
pub fn local_agents_workspace(request: WorkspaceRequest) -> Result<String, String> {
    let slug = safe_slug(&request.slug)?;
    let root = workspace_root()?.join(slug);
    std::fs::create_dir_all(root.join(".paloma").join("attach")).map_err(|e| e.to_string())?;
    Ok(root.display().to_string())
}

#[tauri::command]
pub fn local_agents_write(request: WriteRequest) -> Result<WriteReport, String> {
    let root = PathBuf::from(&request.root);
    if !root.is_dir() {
        return Err("workspace root is not a directory".into());
    }
    let mut written = Vec::new();
    let mut skipped = Vec::new();
    for file in request.files {
        let rel = match safe_rel(&file.rel) {
            Ok(rel) => rel,
            Err(error) => {
                skipped.push(format!("{} ({error})", file.rel));
                continue;
            }
        };
        let rel_str = rel.to_string_lossy().replace('\\', "/");
        if is_secret_path(&rel_str) {
            skipped.push(format!("{rel_str} (secret)"));
            continue;
        }
        let limit = if file.encoding.as_deref() == Some("base64") {
            14 * 1024 * 1024
        } else {
            512 * 1024
        };
        if file.content.len() > limit {
            skipped.push(format!("{rel_str} (too large)"));
            continue;
        }
        let dest = root.join(&rel);
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let bytes = match file.encoding.as_deref() {
            Some("base64") => base64::engine::general_purpose::STANDARD
                .decode(&file.content)
                .map_err(|e| e.to_string())?,
            None => file.content.into_bytes(),
            Some(_) => return Err("Unsupported attachment encoding".into()),
        };
        std::fs::write(&dest, bytes).map_err(|e| e.to_string())?;
        written.push(rel_str);
    }
    Ok(WriteReport {
        written,
        skipped,
        binary_supported: true,
    })
}

/// Not registered with the webview: launches go through `local_run_launch`
/// (run_recovery), which fences and verifies them first.
#[cfg_attr(not(test), allow(dead_code))]
#[tauri::command]
pub fn local_agents_start(request: StartRequest) -> Result<(), String> {
    start_with_env(request, &[])
}

#[tauri::command]
pub fn local_agents_poll(id: String) -> Result<PollState, String> {
    poll_generation(&id, None)
}

/// Subscribe atomically with the snapshot so startup text cannot be missed.
#[tauri::command]
pub fn local_agents_subscribe(
    id: String,
    on_event: tauri::ipc::Channel<OutputEvent>,
) -> Result<u64, String> {
    if !has_run(&id) {
        reattach_if_orphaned(&id);
    }
    run_of(&id)?.ctx.output.subscribe(on_event)
}

#[tauri::command]
pub fn local_agents_unsubscribe(id: String, token: u64) -> Result<(), String> {
    if let Some(run) = crate::sync_util::lock(runs()).get(&id) {
        run.ctx.output.unsubscribe(token);
    }
    Ok(())
}

#[tauri::command]
pub fn local_agents_stop(id: String) -> Result<(), String> {
    let fence = launch_fence(&id);
    let mut generation = crate::sync_util::lock(&fence);
    *generation += 1;
    stop_generation(&id, None)
}

fn uuid_like() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos:032x}")
        .chars()
        .take(32)
        .collect::<String>()
        .chars()
        .enumerate()
        .fold(String::new(), |mut acc, (i, ch)| {
            if i == 8 || i == 12 || i == 16 || i == 20 {
                acc.push('-');
            }
            acc.push(ch);
            acc
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pasted_image_bytes_are_written_without_text_conversion() {
        let root = std::env::temp_dir().join(format!("orb-image-{}", uuid_like()));
        std::fs::create_dir_all(&root).unwrap();
        let bytes = [137, 80, 78, 71, 0, 255];
        let result = local_agents_write(WriteRequest {
            root: root.to_string_lossy().into_owned(),
            files: vec![WriteFile {
                rel: ".paloma/images/test.png".into(),
                content: base64::engine::general_purpose::STANDARD.encode(bytes),
                encoding: Some("base64".into()),
            }],
        })
        .unwrap();
        assert!(result.skipped.is_empty());
        assert_eq!(
            std::fs::read(root.join(".paloma/images/test.png")).unwrap(),
            bytes
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn unavailable_version_does_not_hide_installed_harness() {
        use std::os::unix::fs::PermissionsExt;
        let path = std::env::temp_dir().join(format!("orb-version-probe-{}", uuid::Uuid::new_v4()));
        std::fs::write(&path, "#!/bin/sh\nexit 1\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let rows = scan_local_agents(ScanRequest {
            overrides: HARNESSES
                .iter()
                .map(|(id, _)| (id.to_string(), path.display().to_string()))
                .collect(),
        });
        std::fs::remove_file(path).unwrap();
        assert_eq!(rows.len(), HARNESSES.len());
        assert!(rows
            .iter()
            .all(|row| row.installed && row.version.is_none()));
    }

    #[test]
    #[ignore = "requires locally installed OpenCode; run with desktop-style PATH"]
    fn desktop_path_discovers_homebrew_opencode() {
        let rows = scan_local_agents(ScanRequest {
            overrides: HashMap::new(),
        });
        let row = rows.iter().find(|row| row.id == "opencode").unwrap();
        assert!(row.installed, "OpenCode missing: {:?}", row.path);
    }

    #[test]
    fn native_plan_capability_requires_a_verified_protocol_version() {
        assert!(native_plan_supported("codex", "codex-cli 0.155.1"));
        assert!(native_plan_supported("claudecode", "2.1.278 (Claude Code)"));
        assert!(!native_plan_supported("codex", "codex-cli 0.120.0"));
        assert!(!native_plan_supported("claudecode", "unknown"));
        assert!(!native_plan_supported("grok", "1.0.40"));
        assert!(!native_plan_supported("opencode", "1.15.13"));
    }

    #[cfg(unix)]
    #[test]
    fn retired_gemini_cannot_be_launched_from_saved_requests() {
        assert!(!HARNESSES.iter().any(|(id, _)| *id == "gemini"));
        let request = StartRequest {
            service_tier: None,
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            id: "retired-harness".into(),
            harness: "gemini".into(),
            bin: "/not-executed".into(),
            cwd: "/".into(),
            prompt: "hello".into(),
            model: None,
            session_id: Some("old-native-session".into()),
            image_paths: vec![],
            shared_cwd_with: None,
        };
        let ctx = RunCtx::new(&request.id, &request.harness, None);
        let error = harness::spawn_harness(&request, &ctx, &[], &[]).unwrap_err();
        assert_eq!(error, "unknown local harness gemini");
    }
}

#[cfg(test)]
mod plan_smoke {
    use super::*;
    #[test]
    #[ignore = "real authenticated CLI smoke test; ORB_PLAN_HARNESS and ORB_PLAN_BIN required"]
    fn native_plan_roundtrip() {
        let harness = std::env::var("ORB_PLAN_HARNESS").unwrap();
        let id = format!("plan-smoke-{}", uuid_like());
        let cwd = std::env::temp_dir().join(&id);
        std::fs::create_dir_all(&cwd).unwrap();
        struct Cleanup(String);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = local_agents_stop(self.0.clone());
            }
        }
        let _cleanup = Cleanup(id.clone());
        local_agents_start(StartRequest { service_tier: None, effort: None, cyber_revision: None, cyber_access: None,id:id.clone(),harness,bin:std::env::var("ORB_PLAN_BIN").unwrap(),cwd:cwd.to_string_lossy().into(),model:None,session_id:None,image_paths:vec![],prompt:"/plan Plan creating hello.txt containing hello. First ask me one question using your native question tool: should it say hello or bonjour? Then present a short plan for approval. Do not delegate. After approval implement it.".into(), shared_cwd_with: None }).unwrap();
        let deadline = Instant::now() + Duration::from_secs(150);
        let mut approved = false;
        let mut revised = std::env::var_os("ORB_PLAN_REVISE").is_none();
        let mut questions = 0;
        while Instant::now() < deadline {
            if let Some(req) = crate::interactions::local_interaction(id.clone()).unwrap() {
                eprintln!("native request: {}", req.method);
                assert!(
                    approved || !cwd.join("hello.txt").exists(),
                    "write before plan approval"
                );
                let answer = if req.method == "plan" {
                    if !revised {
                        revised = true;
                        json!({"action":"revise","feedback":"Revise the plan to explicitly verify the file contents after writing. Keep the content hello and ask for approval again."})
                    } else {
                        approved = true;
                        json!({"action":"accept"})
                    }
                } else if req.method == "permission" {
                    assert!(approved, "unexpected permission before plan approval");
                    json!({"action":"accept"})
                } else {
                    questions += 1;
                    let mut answers = serde_json::Map::new();
                    for q in req.params["questions"].as_array().unwrap() {
                        if req.method == "claude_questions" {
                            answers.insert(q["question"].as_str().unwrap().into(), json!("hello"));
                        } else {
                            answers.insert(
                                q["id"].as_str().unwrap().into(),
                                json!({"answers":["hello"]}),
                            );
                        }
                    }
                    json!({"answers":answers})
                };
                crate::interactions::local_interaction_answer(id.clone(), req.id, answer).unwrap();
            }
            let state = local_agents_poll(id.clone()).unwrap();
            if state.done {
                assert!(state.error.is_none(), "{:?}", state.error);
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        assert!(approved, "no plan approval request");
        assert!(questions > 0, "no clarification request");
        assert!(
            cwd.join("hello.txt").exists(),
            "approved plan did not execute"
        );
    }
}

#[cfg(test)]
mod directory_tests {
    #[cfg(unix)]
    #[test]
    fn concurrent_local_runs_cannot_share_a_directory() {
        use super::*;
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let bin = root.path().join("grok-fixture");
        std::fs::write(
            &bin,
            "#!/bin/sh\n[ \"$1\" = --version ] && { echo '1.0.0'; exit 0; }\nexec sleep 30\n",
        )
        .unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
        let first = uuid::Uuid::new_v4().to_string();
        let request = StartRequest {
            service_tier: None,
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            id: first.clone(),
            harness: "grok".into(),
            bin: bin.to_string_lossy().into(),
            cwd: root.path().to_string_lossy().into(),
            prompt: "test".into(),
            model: None,
            session_id: None,
            shared_cwd_with: None,
            image_paths: vec![],
        };
        start_with_env(request.clone(), &[]).unwrap();
        let deferred = tauri::async_runtime::block_on(crate::run_recovery::local_run_launch(
            StartRequest {
                effort: None,
                cyber_revision: None,
                cyber_access: None,
                id: uuid::Uuid::new_v4().to_string(),
                ..request.clone()
            },
            crate::run_recovery::Connection {
                api_url: "http://127.0.0.1:1".into(),
                token: "unused".into(),
            },
        ))
        .unwrap_err();
        assert!(deferred.starts_with("Local launch deferred: directory busy"));
        let second = start_with_env(
            StartRequest {
                effort: None,
                cyber_revision: None,
                cyber_access: None,
                id: uuid::Uuid::new_v4().to_string(),
                cwd: root.path().join(".").to_string_lossy().into(),
                ..request.clone()
            },
            &[],
        );
        let side_id = uuid::Uuid::new_v4().to_string();
        start_with_env(
            StartRequest {
                id: side_id.clone(),
                shared_cwd_with: Some(first.clone()),
                ..request.clone()
            },
            &[],
        )
        .expect("side agent sharing parent cwd should launch while parent is running");
        assert!(
            !workspace_busy_for(root.path(), Some(&first), None).unwrap(),
            "side agent must not block parent mission from using its own directory"
        );
        assert!(
            workspace_busy_for(root.path(), Some(&uuid::Uuid::new_v4().to_string()), None).unwrap(),
            "unrelated mission must still see directory as busy"
        );
        local_agents_stop(side_id.clone()).unwrap();
        runs().lock().unwrap().remove(&side_id);
        local_agents_stop(first.clone()).unwrap();
        runs().lock().unwrap().remove(&first);
        assert!(second
            .unwrap_err()
            .contains("directory already has a running local mission"));
    }
    #[test]
    fn plain_directory_is_valid_without_git() {
        let root = std::env::temp_dir().join(format!("orb-directory-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        assert_eq!(
            super::local_agents_directory(root.to_string_lossy().into()).unwrap(),
            root.canonicalize().unwrap().to_string_lossy()
        );
        assert!(super::local_agents_directory("relative".into()).is_err());
        let file = root.join("file");
        std::fs::write(&file, "hello").unwrap();
        assert!(super::local_agents_directory(file.to_string_lossy().into()).is_err());
        assert!(
            super::local_agents_directory(root.join("absent").to_string_lossy().into()).is_err()
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}
