//! Local harnesses. Orb spawns the CLIs already installed on this machine.
//! It does not embed sandboxed.sh and does not read the backend's credentials.
//!
//! Claude Code: `claude --print --output-format stream-json`.
//! Codex: `codex app-server` (initialize, thread/start or thread/resume, turn/start).
//! OpenCode: `opencode run --format json`, `--session ses_*` or `--continue`.
//! Grok: `grok -p --output-format streaming-json`, with native `--resume`.

use crate::local_stream::{Event as OutputEvent, Output};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const HARNESSES: &[(&str, &str)] = &[
    ("claudecode", "claude"),
    ("codex", "codex"),
    ("grok", "grok"),
    ("opencode", "opencode"),
    ("antigravity", "agy"),
];

#[tauri::command]
pub fn local_agents_cyber_capabilities() -> u32 {
    2
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

#[derive(Debug, Clone, Deserialize)]
pub struct StartRequest {
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
}

#[derive(Clone)]
struct Run {
    mcp_wrapped: bool,
    generation: String,
    cwd: PathBuf,
    child: Arc<Mutex<Child>>,
    text: Arc<Output>,
    done: Arc<AtomicBool>,
    exit_code: Arc<Mutex<Option<i32>>>,
    session_id: Arc<Mutex<Option<String>>>,
    error: Arc<Mutex<Option<String>>>,
    resumed: bool,
}

fn runs() -> &'static Mutex<HashMap<String, Run>> {
    static RUNS: OnceLock<Mutex<HashMap<String, Run>>> = OnceLock::new();
    RUNS.get_or_init(|| Mutex::new(HashMap::new()))
}

// Serialize Stop with the synchronous spawn boundary, while network preparation
// holds only a captured generation. A stopped preparation must never spawn later.
pub(crate) fn launch_fence(id: &str) -> Arc<Mutex<u64>> {
    static FENCES: OnceLock<Mutex<HashMap<String, Arc<Mutex<u64>>>>> = OnceLock::new();
    FENCES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap()
        .entry(id.into())
        .or_insert_with(|| Arc::new(Mutex::new(0)))
        .clone()
}
pub(crate) const LAUNCH_CANCELLED: &str = "Local launch rejected: stopped before launch";

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

fn scan_local_agents(request: ScanRequest) -> Vec<ScanRow> {
    HARNESSES
        .iter()
        .map(|(id, bin)| {
            let override_path = request
                .overrides
                .get(*id)
                .map(|s| s.trim())
                .filter(|s| !s.is_empty());
            let path = override_path
                .map(|p| PathBuf::from(p))
                .filter(|p| p.is_file())
                .or_else(|| crate::agent_software::resolve(bin));
            let version = path.as_ref().and_then(|p| version_of(p));
            ScanRow {
                models: vec![],
                auth_error: None,
                id: (*id).to_string(),
                bin: (*bin).to_string(),
                // A slow version probe must not hide an installed CLI.
                installed: path.is_some(),
                plan_supported: version
                    .as_deref()
                    .is_some_and(|v| native_plan_supported(id, v)),
                path: path.map(|p| p.display().to_string()),
                version,
            }
        })
        .collect()
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

#[tauri::command]
pub fn local_agents_start(request: StartRequest) -> Result<(), String> {
    start_with_env(request, &[])
}

pub(crate) const DIRECTORY_BUSY: &str =
    "This directory already has a running local mission. Choose a separate directory or worktree.";

pub(crate) fn start_with_env(
    request: StartRequest,
    env: &[(String, String)],
) -> Result<(), String> {
    start_with_env_fenced(request, env, None)
}

pub(crate) fn start_with_env_fenced(
    request: StartRequest,
    env: &[(String, String)],
    expected_stop: Option<u64>,
) -> Result<(), String> {
    let fence = launch_fence(&request.id);
    let generation = fence.lock().map_err(|e| e.to_string())?;
    if expected_stop.is_some_and(|expected| expected != *generation) {
        return Err(LAUNCH_CANCELLED.into());
    }
    if request
        .prompt
        .trim()
        .strip_prefix("/plan")
        .is_some_and(|s| s.is_empty() || s.starts_with(char::is_whitespace))
        && !matches!(request.harness.as_str(), "codex" | "claudecode")
    {
        return Err("Native plan mode is not supported by this integration.".into());
    }
    if request.id.trim().is_empty() {
        return Err("run id is required".into());
    }
    let cwd = PathBuf::from(&request.cwd);
    if !cwd.is_dir() {
        return Err("working directory does not exist".into());
    }
    let bin = PathBuf::from(&request.bin);
    if !bin.is_file() {
        return Err(format!("CLI not found at {}", request.bin));
    }
    let software_execution =
        crate::agent_software::begin(&request.id, &request.harness, Some(&bin))?;
    let mut map = runs().lock().map_err(|e| e.to_string())?;
    if let Some(previous) = map.get(&request.id) {
        if !previous.done.load(Ordering::SeqCst) {
            return Err("This mission is still running locally. Wait for it to finish or stop it before sending another message.".into());
        }
    }
    let canonical_cwd = cwd.canonicalize().map_err(|e| e.to_string())?;
    if map.iter().any(|(id, run)| {
        id != &request.id
            && !run.done.load(Ordering::SeqCst)
            && run.cwd.canonicalize().ok().as_ref() == Some(&canonical_cwd)
    }) {
        return Err(DIRECTORY_BUSY.into());
    }
    // Completed handles are retained for reconnect snapshots until the next turn.
    // Retire the old app-server before resuming its thread in a fresh process.
    if let Some(previous) = map.remove(&request.id) {
        if let Ok(mut child) = previous.child.lock() {
            if child.try_wait().ok().flatten().is_none() {
                let _ = child.kill();
            }
            let _ = child.wait();
        }
    }
    let text = Arc::new(Output::default());
    let done = Arc::new(AtomicBool::new(false));
    let exit_code = Arc::new(Mutex::new(None));
    let session_id = Arc::new(Mutex::new(request.session_id.clone()));
    let error = Arc::new(Mutex::new(None));
    let resumed = request.session_id.as_deref().is_some_and(|s| !s.is_empty());
    let interaction = crate::interactions::begin(&request.id);
    let child = match spawn_harness(&request, &text, &session_id, &error, &done, env) {
        Ok(child) => child,
        Err(error) => {
            crate::interactions::finish(&interaction);
            return Err(error);
        }
    };
    let child = Arc::new(Mutex::new(child));
    let run = Run {
        mcp_wrapped: env.iter().any(|(key, _)| key == "SANDBOXED_MCP_WRAPPER"),
        generation: uuid::Uuid::new_v4().to_string(),
        cwd,
        child,
        text,
        done,
        exit_code,
        session_id,
        error,
        resumed,
    };
    watch_exit(
        software_execution,
        interaction,
        run.clone(),
        request.harness == "antigravity",
    );
    map.insert(request.id, run);
    Ok(())
}

fn watch_exit(
    software_execution: crate::agent_software::Execution,
    mission_id: crate::interactions::Session,
    run: Run,
    strict_terminal: bool,
) {
    let Run {
        child,
        done,
        exit_code,
        text: output,
        session_id,
        error,
        resumed,
        ..
    } = run;
    thread::spawn(move || {
        let _software_execution = software_execution;
        // waitid leaves the child unreaped. Stop and the waiter serialize reaping
        // through Child's mutex, so a recycled PID is never signalled.
        #[cfg(unix)]
        {
            let pid = child.lock().unwrap().id();
            loop {
                let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
                let result = unsafe {
                    libc::waitid(libc::P_PID, pid, &mut info, libc::WEXITED | libc::WNOWAIT)
                };
                if result == 0
                    || std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
                {
                    break;
                }
            }
        }
        #[cfg(windows)]
        {
            use std::os::windows::io::AsRawHandle;
            #[link(name = "kernel32")]
            unsafe extern "system" {
                fn WaitForSingleObject(handle: *mut std::ffi::c_void, milliseconds: u32) -> u32;
            }
            let handle = child.lock().unwrap().as_raw_handle();
            unsafe {
                WaitForSingleObject(handle, u32::MAX);
            }
        }
        let status = child.lock().ok().and_then(|mut child| child.wait().ok());
        crate::interactions::finish(&mission_id);
        if let Ok(mut slot) = exit_code.lock() {
            *slot = status.and_then(|status| status.code());
        }
        output.wait_drained(None);
        if strict_terminal && error.lock().is_ok_and(|error| error.is_some()) {
            if let Ok(mut slot) = exit_code.lock() {
                *slot = Some(1);
            }
        }
        done.store(true, Ordering::SeqCst);
        output.finish(PollState {
            text: output.snapshot(),
            activities: output.activities(),
            done: true,
            exit_code: *exit_code.lock().unwrap(),
            session_id: session_id.lock().unwrap().clone(),
            error: error.lock().unwrap().clone(),
            retryable: output.retryable(),
            resumed,
            waiting_since: None,
        });
    });
}

#[tauri::command]
pub fn local_agents_poll(id: String) -> Result<PollState, String> {
    poll_generation(&id, None)
}

/// Read only the execution owned by the caller, under the same registry lock.
pub fn poll_generation(id: &str, expected: Option<&str>) -> Result<PollState, String> {
    let map = runs().lock().map_err(|e| e.to_string())?;
    let run = map.get(id).ok_or_else(|| "no local run".to_string())?;
    if expected.is_some_and(|generation| generation != run.generation) {
        return Err("Local execution generation changed".into());
    }
    let snapshot = PollState {
        text: run.text.snapshot(),
        activities: run.text.activities(),
        done: run.done.load(Ordering::SeqCst),
        exit_code: *run.exit_code.lock().map_err(|e| e.to_string())?,
        session_id: run.session_id.lock().map_err(|e| e.to_string())?.clone(),
        error: run.error.lock().map_err(|e| e.to_string())?.clone(),
        retryable: run.text.retryable(),
        resumed: run.resumed,
        waiting_since: run.text.waiting_since(),
    };
    Ok(snapshot)
}

/// Subscribe atomically with the snapshot so startup text cannot be missed.
#[tauri::command]
pub fn local_agents_subscribe(
    id: String,
    on_event: tauri::ipc::Channel<OutputEvent>,
) -> Result<u64, String> {
    let run = runs()
        .lock()
        .map_err(|e| e.to_string())?
        .get(&id)
        .cloned()
        .ok_or("no local run")?;
    run.text.subscribe(on_event)
}

#[tauri::command]
pub fn local_agents_unsubscribe(id: String, token: u64) -> Result<(), String> {
    if let Some(run) = runs().lock().map_err(|e| e.to_string())?.get(&id) {
        run.text.unsubscribe(token);
    }
    Ok(())
}

#[tauri::command]
pub fn local_agents_stop(id: String) -> Result<(), String> {
    let fence = launch_fence(&id);
    let mut generation = fence.lock().map_err(|e| e.to_string())?;
    *generation += 1;
    stop_generation(&id, None)
}
pub fn stop_generation(id: &str, expected: Option<&str>) -> Result<(), String> {
    let run = runs().lock().map_err(|e| e.to_string())?.get(id).cloned();
    // Waiting for this run must not block polling or stopping other missions.
    if let Some(run) = run {
        if expected.is_some_and(|token| token != run.generation) {
            return Ok(());
        }
        crate::interactions::cancel(id);
        let mut child = run.child.lock().map_err(|e| e.to_string())?;
        // The trusted wrapper owns the CLI's child process group. Give it
        // time to forward termination and reap that group before escalation.
        #[cfg(unix)]
        if run.mcp_wrapped && !run.done.load(Ordering::SeqCst) {
            unsafe {
                libc::kill(child.id() as i32, libc::SIGTERM);
            }
            let deadline = Instant::now() + Duration::from_secs(6);
            while child.try_wait().map_err(|e| e.to_string())?.is_none()
                && Instant::now() < deadline
            {
                thread::sleep(Duration::from_millis(10));
            }
        }
        // Completed runs stay cached for their transcript. Their old process
        // group ID may have been reused, so never signal it after completion.
        #[cfg(unix)]
        if child.try_wait().map_err(|e| e.to_string())?.is_none() {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
        }
        if child.try_wait().map_err(|e| e.to_string())?.is_none() {
            child.kill().map_err(|e| e.to_string())?;
        }
        let status = child.wait().map_err(|e| e.to_string())?;
        *run.exit_code.lock().map_err(|e| e.to_string())? = status.code();
        drop(child);
        run.text.wait_drained(Some(Duration::from_secs(2)));
        if !run.text.drained() {
            return Err(
                "The local agent has not finished closing its output. Try Stop again.".into(),
            );
        }
        run.done.store(true, Ordering::SeqCst);
    }
    Ok(())
}

fn spawn_harness(
    request: &StartRequest,
    text: &Arc<Output>,
    session_id: &Arc<Mutex<Option<String>>>,
    error: &Arc<Mutex<Option<String>>>,
    done: &Arc<AtomicBool>,
    env: &[(String, String)],
) -> Result<Child, String> {
    match request.harness.as_str() {
        "antigravity" => spawn_antigravity(request, text, session_id, error, env),
        "claudecode" => spawn_claude(request, text, session_id, error, env),
        "codex" => spawn_codex(request, text, session_id, error, done, env),
        "grok" => spawn_piped(
            request,
            grok_args(request),
            text,
            error,
            true,
            session_id,
            env,
        ),
        "opencode" => spawn_piped(
            request,
            opencode_args(request),
            text,
            error,
            true,
            session_id,
            env,
        ),
        other => Err(format!("unknown local harness {other}")),
    }
}

// A durable create-new marker also fences retries after an Orb restart or lost stdout.
// Only a confirmed OS spawn failure may release it; a known native ID can resume.
fn claim_antigravity_attempt(
    root: &std::path::Path,
    id: &str,
    cwd: &std::path::Path,
    session: Option<&str>,
) -> Result<Option<PathBuf>, String> {
    if session.is_some_and(|id| !id.trim().is_empty()) {
        return Ok(None);
    }
    std::fs::create_dir_all(root).map_err(|e| e.to_string())?;
    use sha2::{Digest, Sha256};
    let mut key = Sha256::new();
    key.update(id.as_bytes());
    key.update([0]);
    key.update(
        cwd.canonicalize()
            .map_err(|e| e.to_string())?
            .as_os_str()
            .as_encoded_bytes(),
    );
    let name = format!("{:x}", key.finalize());
    let path = root.join(name);
    let file = std::fs::OpenOptions::new().write(true).create_new(true).open(&path)
        .map_err(|e| if e.kind() == std::io::ErrorKind::AlreadyExists {
            "Antigravity has an earlier launch without a recorded conversation ID. Reconcile that native conversation before retrying; automatic replay is blocked.".to_string()
        } else { e.to_string() })?;
    file.sync_all().map_err(|e| e.to_string())?;
    std::fs::File::open(root)
        .and_then(|dir| dir.sync_all())
        .map_err(|e| e.to_string())?;
    Ok(Some(path))
}

fn spawn_antigravity(
    request: &StartRequest,
    text: &Arc<Output>,
    session_id: &Arc<Mutex<Option<String>>>,
    error: &Arc<Mutex<Option<String>>>,
    env: &[(String, String)],
) -> Result<Child, String> {
    crate::antigravity::validate_prompt(&request.prompt)?;
    let home = std::env::var_os("HOME").ok_or("HOME is unavailable")?;
    let mut claim_root = PathBuf::from(&home).join(".orb/antigravity-attempts");
    if request
        .session_id
        .as_deref()
        .is_none_or(|id| id.trim().is_empty())
    {
        let bindings = crate::local_bindings(None, None)?;
        if let Some(transfer) = bindings[&request.id]["transferId"].as_str() {
            let transfer =
                uuid::Uuid::parse_str(transfer).map_err(|_| "Invalid transfer identity")?;
            claim_root = claim_root.join(transfer.to_string());
        }
    }
    let claim = claim_antigravity_attempt(
        &claim_root,
        &request.id,
        std::path::Path::new(&request.cwd),
        request.session_id.as_deref(),
    )?;
    let mut command = mission_command(request, env);
    let mut child = command
        .current_dir(&request.cwd)
        .args(crate::antigravity::args_with_effort(
            request.model.as_deref(),
            request.effort.as_deref(),
            request.session_id.as_deref(),
            &request.prompt,
        ))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| {
            if let Some(path) = &claim {
                let _ = std::fs::remove_file(path);
            }
            format!("Cannot start Antigravity: {e}")
        })?;
    let stdout = child
        .stdout
        .take()
        .ok_or("Antigravity stdout unavailable")?;
    let stderr = child
        .stderr
        .take()
        .ok_or("Antigravity stderr unavailable")?;
    let stderr_guard = text.reader();
    let stderr_reader = thread::spawn(move || {
        let _guard = stderr_guard;
        let mut marker = None;
        // Drain stderr without retaining OAuth URLs or unstructured account diagnostics.
        for line in BufReader::new(stderr).lines() {
            let Ok(line) = line else {
                break;
            };
            if let Some(parsed) = crate::antigravity::ErrorMarker::parse(&line) {
                marker = Some(parsed);
            }
        }
        marker
    });
    let thoughts = Arc::new(Mutex::new(crate::antigravity::thoughts::Reader::new(
        std::path::Path::new(&home),
    )));
    let thoughts_done = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let thought_reader = thoughts.clone();
    let thought_stop = thoughts_done.clone();
    let thought_output = Arc::clone(text);
    let thought_guard = text.reader();
    thread::spawn(move || {
        let _guard = thought_guard;
        loop {
            for event in thought_reader.lock().unwrap().poll() {
                thought_output.antigravity_thought(&event);
            }
            if thought_stop.load(std::sync::atomic::Ordering::Acquire) {
                break;
            }
            thread::sleep(std::time::Duration::from_millis(500));
        }
    });

    let output = Arc::clone(text);
    let slot = Arc::clone(session_id);
    let error = Arc::clone(error);
    let expected = request.session_id.clone();
    let pid = child.id();
    let guard = text.reader();
    thread::spawn(move || {
        let _guard = guard;
        let mut stream = crate::antigravity::Stream::default();
        stream.expected_session = expected.clone();
        output.antigravity_progress(&stream);
        output.publish_activities();
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else {
                break;
            };
            let Ok(value) = serde_json::from_str(&line) else {
                continue;
            };
            for tool in stream.feed(&value) {
                output.native_activity(&tool);
            }
            if stream.error.is_none() {
                thoughts.lock().unwrap().observe(&value);
            }
            if matches!(
                value["event"].as_str(),
                Some("init" | "step_update" | "result")
            ) {
                output.antigravity_progress(&stream);
            }
            output.publish_activities();
            if let Some(id) = &stream.session {
                if expected.as_deref().is_some_and(|old| old != id) {
                    stream.error = Some("Antigravity resumed a different conversation".into());
                } else if let Ok(mut slot) = slot.lock() {
                    *slot = Some(id.clone());
                }
            }
            output.replace(stream.text.clone());
            if stream.error.is_some() {
                #[cfg(unix)]
                unsafe {
                    libc::kill(pid as i32, libc::SIGTERM);
                }
                break;
            }
        }
        thoughts_done.store(true, std::sync::atomic::Ordering::Release);
        if let Ok(Some(marker)) = stderr_reader.join() {
            stream.error_marker = Some(marker);
        }
        output.set_retryable(stream.is_retryable());
        if let Err(message) = stream.finish() {
            if let Ok(mut error) = error.lock() {
                *error = Some(message);
            }
        }
    });
    Ok(child)
}

fn grok_args(request: &StartRequest) -> Vec<String> {
    let mut args = vec![
        "--always-approve".into(),
        "--no-plan".into(),
        "--output-format".into(),
        "streaming-json".into(),
    ];
    if let Some(model) = request.model.as_deref().filter(|s| !s.is_empty()) {
        args.extend(["--model".into(), model.into()]);
    }
    if let Some(session) = request.session_id.as_deref().filter(|s| !s.is_empty()) {
        args.extend(["--resume".into(), session.into()]);
    }
    args.extend(["-p".into(), request.prompt.clone()]);
    args
}

fn opencode_args(request: &StartRequest) -> Vec<String> {
    let mut args = vec![
        "run".into(),
        "--format".into(),
        "json".into(),
        "--dir".into(),
        request.cwd.clone(),
    ];
    if let Some(model) = request.model.as_deref().filter(|m| !m.is_empty()) {
        args.push("--model".into());
        // Backend aliases need their configured OpenCode provider namespace.
        args.push(if model.starts_with("builtin/") {
            format!("sandboxed-sh/{model}")
        } else {
            model.to_string()
        });
    }
    match request.session_id.as_deref().filter(|s| !s.is_empty()) {
        Some(sid) if sid.starts_with("ses_") => {
            args.push("--session".into());
            args.push(sid.to_string());
        }
        Some(_) => args.push("--continue".into()),
        None => {}
    }
    args.push(request.prompt.clone());
    for path in &request.image_paths {
        args.extend(["--file".into(), path.clone()]);
    }
    args
}

/// Launchers (notably Codex's Node shim) spawn another process. Stop must
/// address a dedicated group, never the desktop's inherited process group.
fn harness_command(bin: &str) -> Command {
    // Operator provisioning is outside project files. This also covers local
    // missions whose cwd is an existing checkout outside ~/.orb.
    let identity = std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(".config/sandboxed-sh/development-identity/launch"));
    harness_command_with_identity(bin, identity.as_deref())
}

fn harness_command_with_identity(bin: &str, identity: Option<&Path>) -> Command {
    let mut command = match identity.filter(|path| path.is_file()) {
        Some(launcher) => {
            let mut command = Command::new(launcher);
            command.arg(bin);
            command
        }
        None => Command::new(bin),
    };
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    command
}

#[cfg(test)]
mod development_identity_tests {
    use super::*;

    #[test]
    fn installed_identity_wraps_the_selected_harness_without_credentials_in_argv() {
        let dir = tempfile::tempdir().unwrap();
        let launcher = dir.path().join("launch");
        std::fs::write(&launcher, "#!/bin/sh\n").unwrap();
        let mut command = harness_command_with_identity("/opt/codex", Some(&launcher));
        command.args(["exec", "a task"]);
        assert_eq!(command.get_program(), launcher.as_os_str());
        assert_eq!(
            command.get_args().collect::<Vec<_>>(),
            ["/opt/codex", "exec", "a task"]
        );
        assert_eq!(command.get_envs().count(), 0);
    }

    #[test]
    fn unconfigured_identity_preserves_the_original_launcher() {
        let dir = tempfile::tempdir().unwrap();
        let command = harness_command_with_identity("codex", Some(&dir.path().join("absent")));
        assert_eq!(command.get_program(), "codex");
        assert_eq!(command.get_args().count(), 0);
    }
}

fn mission_command(request: &StartRequest, env: &[(String, String)]) -> Command {
    let wrapper = env
        .iter()
        .find(|(key, _)| key == "SANDBOXED_MCP_WRAPPER")
        .map(|(_, value)| value);
    let mut command = if let Some(wrapper) = wrapper {
        let mut command = harness_command(wrapper);
        command.args(["launch", "--harness", &request.harness, "--", &request.bin]);
        command
    } else {
        harness_command(&request.bin)
    };
    command.envs(env.iter().map(|(key, value)| (key, value)));
    command
}

fn spawn_claude(
    request: &StartRequest,
    text: &Arc<Output>,
    session_id: &Arc<Mutex<Option<String>>>,
    error: &Arc<Mutex<Option<String>>>,
    env: &[(String, String)],
) -> Result<Child, String> {
    let plan = request
        .prompt
        .trim()
        .strip_prefix("/plan")
        .filter(|s| s.is_empty() || s.starts_with(char::is_whitespace))
        .map(str::trim);
    let mut cmd = mission_command(request, env);
    if plan.is_some() {
        cmd.args([
            "--allow-dangerously-skip-permissions",
            "--permission-mode",
            "plan",
        ]);
    } else {
        cmd.arg("--dangerously-skip-permissions");
    }
    // Every turn needs a live permission channel, including resumed sessions.
    // Print mode otherwise denies tool requests that need user approval.
    cmd.args([
        "--input-format",
        "stream-json",
        "--permission-prompt-tool",
        "stdio",
    ]);
    cmd.current_dir(&request.cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .args([
            "--print",
            "--disallowedTools",
            "CronCreate,CronDelete,CronList",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]);
    if let Some(model) = request.model.as_deref().filter(|m| !m.is_empty()) {
        let bare = model.strip_prefix("anthropic/").unwrap_or(model);
        cmd.arg("--model").arg(bare);
    }
    if let Some(sid) = request.session_id.as_deref().filter(|s| !s.is_empty()) {
        cmd.arg("--resume").arg(sid);
    } else if let Ok(mut slot) = session_id.lock() {
        let fresh = uuid_like();
        cmd.arg("--session-id").arg(&fresh);
        *slot = Some(fresh);
    }
    if let Some(command) = crate::local_wakeups::command(&request.id) {
        cmd.arg("--mcp-config").arg(
            json!({"mcpServers":{"orb-wakeups":{"command":command[0],"args":command[1..]}}})
                .to_string(),
        );
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("failed to start Claude Code: {e}"))?;
    {
        let stdin = Arc::new(Mutex::new(
            child.stdin.take().ok_or("Claude stdin missing")?,
        ));
        let stdout = child.stdout.take().ok_or("Claude stdout missing")?;
        let recheck = Arc::new(Recheck::default());
        {
            let recheck = Arc::clone(&recheck);
            let stdin = Arc::clone(&stdin);
            let delays = recheck_delays(&request.id);
            thread::spawn(move || recheck.run(&stdin, &delays));
        }
        let mission_id = crate::interactions::session(&request.id);
        let resumed = request.session_id.as_deref().is_some_and(|s| !s.is_empty());
        let wakeup_command = crate::local_wakeups::command(&request.id);
        let prompt = plan.unwrap_or(&request.prompt).to_owned();
        let mut execution_approved = plan.is_none();
        let output = Arc::clone(text);
        let failures = Arc::clone(error);
        let guard = text.reader();
        thread::spawn(move || {
            let _guard = guard;
            let result = (|| -> Result<(), String> {
                let send = |line: Value| write_line(&mut *stdin.lock().unwrap(), &line.to_string());
                let say = |text: &str| {
                    send(json!({"type":"user","message":{"role":"user","content":text}}))
                };
                // The turn has answered and only waits for its background
                // tasks, or it works again.
                let waiting = |tasks: Option<&ClaudeBackground>| {
                    output.waiting_on_background(tasks.is_some());
                    recheck.waiting(tasks.map(ClaudeBackground::list));
                };
                send(
                    json!({"type":"control_request","request_id":"orb-init","request":{"subtype":"initialize"}}),
                )?;
                say(&prompt)?;
                let mut implement_after_result = false;
                let mut claude_text = ClaudeText::default();
                let mut background = ClaudeBackground::default();
                let mut request_started = false;
                let mut stale_result_skipped = false;
                // The turn gave its result and only background tasks remain.
                let mut answered = false;
                let mut wakeups: HashMap<String, Value> = HashMap::new();
                for line in BufReader::new(stdout).lines() {
                    let line = line.map_err(|e| e.to_string())?;
                    let Ok(event) = serde_json::from_str::<Value>(&line) else {
                        continue;
                    };
                    if let Some(blocks) = event["message"]["content"].as_array() {
                        for block in blocks {
                            if event["type"] == "assistant"
                                && block["type"] == "tool_use"
                                && block["name"] == "ScheduleWakeup"
                            {
                                if let Some(id) = block["id"].as_str() {
                                    wakeups.insert(id.into(), block["input"].clone());
                                }
                            } else if event["type"] == "user" && block["type"] == "tool_result" {
                                if let Some(id) = block["tool_use_id"].as_str() {
                                    if let Some(mut args) = wakeups.remove(id) {
                                        if block["is_error"] != true {
                                            args["request_id"] =
                                                json!(format!("claude-native:{id}"));
                                            crate::local_wakeups::capture(
                                                wakeup_command.as_deref(),
                                                args,
                                            )?;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    output.claude_activity(&event);
                    if matches!(event["type"].as_str(), Some("assistant" | "stream_event")) {
                        request_started = true;
                        answered = false;
                        waiting(None);
                    }
                    if event["type"] != "stream_event"
                        || matches!(
                            event["event"]["type"].as_str(),
                            Some("content_block_start" | "content_block_stop")
                        )
                    {
                        output.publish_activities();
                    }
                    background.consume(&event);
                    background.note_output(&event);
                    // Waiting ends with the last background task, or with a
                    // question: what follows is the agent's own turn.
                    if !background.running() || event["type"] == "control_request" {
                        waiting(None);
                    } else if event["type"] == "system" {
                        // Tasks end and start during the wait: the next question
                        // is about the ones that run then.
                        recheck.refresh(background.list());
                    }
                    if implement_after_result
                        && event["type"] == "assistant"
                        && event["message"]["content"]
                            .as_array()
                            .is_some_and(|blocks| {
                                blocks.iter().any(|b| {
                                    b["type"] == "tool_use"
                                        && b["name"] != "ExitPlanMode"
                                        && b["name"] != "AskUserQuestion"
                                })
                            })
                    {
                        implement_after_result = false;
                    }
                    if event["type"] == "control_response"
                        && event["response"]["subtype"] == "error"
                    {
                        return Err(format!(
                            "Claude control request failed: {}",
                            event["response"]["error"]
                        ));
                    }
                    if event["type"] == "control_request"
                        && event["request"]["subtype"] == "can_use_tool"
                    {
                        let tool = event["request"]["tool_name"].as_str().unwrap_or("");
                        let input = event["request"]["input"].clone();
                        let response = if tool == "AskUserQuestion" {
                            let answers = crate::interactions::ask(
                                &mission_id,
                                "claude_questions",
                                input.clone(),
                            )?;
                            let mut updated = input;
                            updated["answers"] = answers["answers"].clone();
                            json!({"behavior":"allow","updatedInput":updated})
                        } else if tool == "ExitPlanMode" {
                            let answer =
                                crate::interactions::ask(&mission_id, "plan", input.clone())?;
                            if answer["action"] == "accept" {
                                implement_after_result = true;
                                execution_approved = true;
                                json!({"behavior":"allow","updatedInput":input})
                            } else {
                                json!({"behavior":"deny","message":answer["feedback"].as_str().unwrap_or("Please revise the plan.")})
                            }
                        } else if execution_approved {
                            json!({"behavior":"allow","updatedInput":input})
                        } else {
                            {
                                let answer = crate::interactions::ask(
                                    &mission_id,
                                    "permission",
                                    json!({"tool":tool,"input":input}),
                                )?;
                                if answer["action"] == "accept" {
                                    json!({"behavior":"allow","updatedInput":input})
                                } else {
                                    json!({"behavior":"deny","message":"The user declined this action."})
                                }
                            }
                        };
                        send(
                            json!({"type":"control_response","response":{"subtype":"success","request_id":event["request_id"],"response":response}}),
                        )?;
                        // Answered, by the user or by itself: the wait goes on.
                        if answered && background.running() {
                            waiting(Some(&background));
                        }
                    } else if event["type"] == "result" {
                        // A resumed session first settles what the previous process
                        // left behind (a stopped background task) and reports it as
                        // an empty result of zero turns. The request has not run yet.
                        // Only that leading result is skipped: any later one ends the
                        // turn as usual, or the run would wait forever.
                        if resumed
                            && !request_started
                            && !stale_result_skipped
                            && event["num_turns"] == 0
                            && event["is_error"] != true
                            && event["result"]
                                .as_str()
                                .is_none_or(|text| text.trim().is_empty())
                        {
                            stale_result_skipped = true;
                            continue;
                        }
                        if let Some(piece) = claude_text.consume(&event) {
                            output.append(&piece);
                        }
                        if event["is_error"] == true {
                            return Err(event["result"]
                                .as_str()
                                .unwrap_or("Claude ended with an error")
                                .to_owned());
                        }
                        // A result ends one turn, not the session: background agents
                        // can trigger more turns and permission requests afterwards.
                        if background.running() {
                            answered = true;
                            waiting(Some(&background));
                            // Only the agent knows whether it still waits for a
                            // command it left running: it is asked once per command.
                            if let Some(question) = background.unchecked() {
                                recheck.restart();
                                say(&question)?;
                            }
                            continue;
                        }
                        if implement_after_result {
                            implement_after_result = false;
                            send(
                                json!({"type":"control_request","request_id":"orb-execute","request":{"subtype":"set_permission_mode","mode":"bypassPermissions"}}),
                            )?;
                            say("Implement the approved plan.")?;
                            continue;
                        }
                        break;
                    } else if let Some(piece) = claude_text.consume(&event) {
                        output.append(&piece);
                    }
                }
                Ok(())
            })();
            recheck.close();
            crate::interactions::finish(&mission_id);
            if let Err(e) = result {
                *failures.lock().unwrap() = Some(e);
            }
        });
        pipe_output(None, child.stderr.take(), text, error, true, None, None);
        return Ok(child);
    }
}

fn spawn_piped(
    request: &StartRequest,
    args: Vec<String>,
    text: &Arc<Output>,
    error: &Arc<Mutex<Option<String>>>,
    parse_json: bool,
    session_id: &Arc<Mutex<Option<String>>>,
    env: &[(String, String)],
) -> Result<Child, String> {
    let mut command = mission_command(request, env);
    // Share the user's provider credentials/config, but not a database whose
    // schema may belong to a different OpenCode build (e.g. the desktop app).
    if request.harness == "opencode" && std::env::var_os("OPENCODE_DB").is_none() {
        command.env("OPENCODE_DB", "orb-local.db");
    }
    if request.harness == "opencode" {
        command.env("OPENCODE_PERMISSION", r#"{"*":"allow"}"#);
    }
    command.envs(env.iter().map(|(key, value)| (key, value)));
    if request.harness == "opencode" {
        if let Some(wake_command) = crate::local_wakeups::command(&request.id) {
            let raw = env
                .iter()
                .find(|(k, _)| k == "OPENCODE_CONFIG_CONTENT")
                .map(|(_, v)| v.clone())
                .or_else(|| std::env::var("OPENCODE_CONFIG_CONTENT").ok());
            let mut config: Value = raw
                .and_then(|v| serde_json::from_str(&v).ok())
                .unwrap_or_else(|| json!({}));
            config["mcp"]["orb-wakeups"] =
                json!({"type":"local","command":wake_command,"enabled":true});
            command.env("OPENCODE_CONFIG_CONTENT", config.to_string());
        }
    }
    command.env("NO_COLOR", "1");
    let mut child = command
        .current_dir(&request.cwd)
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("failed to start {}: {e}", request.harness))?;
    pipe_output(
        child.stdout.take(),
        child.stderr.take(),
        text,
        error,
        parse_json,
        Some(Arc::clone(session_id)),
        (request.harness == "opencode").then(|| (request.bin.clone(), request.cwd.clone())),
    );
    Ok(child)
}

fn stream_plain(reader: &mut impl Read, output: &Output) {
    let mut pending = Vec::new();
    let mut bytes = [0u8; 4096];
    while let Ok(n) = reader.read(&mut bytes) {
        if n == 0 {
            break;
        }
        pending.extend_from_slice(&bytes[..n]);
        loop {
            match std::str::from_utf8(&pending) {
                Ok(text) => {
                    output.append(text);
                    pending.clear();
                    break;
                }
                Err(error) => {
                    let valid = error.valid_up_to();
                    output.append(std::str::from_utf8(&pending[..valid]).unwrap());
                    pending.drain(..valid);
                    if let Some(invalid) = error.error_len() {
                        output.append("�");
                        pending.drain(..invalid);
                    } else {
                        break;
                    }
                }
            }
        }
    }
    output.append(&String::from_utf8_lossy(&pending));
}

// Terminal styling is not meaningful inside a desktop error card.
fn strip_terminal_codes(text: &str) -> String {
    let mut result = String::new();
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' && chars.peek() == Some(&'[') {
            chars.next();
            for code in chars.by_ref() {
                if ('@'..='~').contains(&code) {
                    break;
                }
            }
        } else {
            result.push(ch);
        }
    }
    result
}

fn opencode_final_answer(value: &Value) -> Option<String> {
    let messages = value["messages"].as_array()?;
    let start = messages.iter().rposition(|m| m["info"]["role"] == "user")?;
    let message = messages[start + 1..]
        .iter()
        .rev()
        .find(|m| m["info"]["role"] == "assistant" && m["info"]["finish"] == "stop")?;
    let text = message["parts"]
        .as_array()?
        .iter()
        .filter(|p| p["type"] == "text")
        .filter_map(|p| p["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n\n");
    (!text.trim().is_empty()).then_some(text)
}

fn pipe_output(
    stdout: Option<std::process::ChildStdout>,
    stderr: Option<std::process::ChildStderr>,
    text: &Arc<Output>,
    error: &Arc<Mutex<Option<String>>>,
    parse_json: bool,
    session_id: Option<Arc<Mutex<Option<String>>>>,
    recovery: Option<(String, String)>,
) {
    let text_out = Arc::clone(text);
    let error_out = Arc::clone(error);
    let protocol_error = Arc::clone(error);
    if let Some(stdout) = stdout {
        let guard = text.reader();
        thread::spawn(move || {
            let _guard = guard;
            let mut reader = BufReader::new(stdout);
            if !parse_json {
                stream_plain(&mut reader, &text_out);
                return;
            }
            for line in reader.lines() {
                let Ok(line) = line else { break };
                if let Some(slot) = &session_id {
                    if let Ok(event) = serde_json::from_str::<Value>(&line) {
                        if let Some(id) = event
                            .get("sessionID")
                            .and_then(Value::as_str)
                            .filter(|id| id.starts_with("ses_"))
                            .or_else(|| {
                                (event["type"] == "init")
                                    .then(|| event["session_id"].as_str())
                                    .flatten()
                                    .filter(|id| !id.is_empty())
                            })
                            .or_else(|| {
                                event["sessionId"]
                                    .as_str()
                                    .filter(|id| uuid::Uuid::parse_str(id).is_ok())
                            })
                        {
                            if let Ok(mut slot) = slot.lock() {
                                *slot = Some(id.to_string());
                            }
                        }
                    }
                }
                if let Ok(value) = serde_json::from_str::<Value>(&line) {
                    text_out.native_activity(&value);
                    if matches!(
                        value["type"].as_str(),
                        Some("tool_use" | "tool_call" | "tool_call_update")
                    ) {
                        text_out.publish_activities();
                    }
                    if value["type"] == "error" {
                        let message = value
                            .pointer("/error/data/message")
                            .or_else(|| value.pointer("/error/message"))
                            .or_else(|| value.get("message"))
                            .and_then(Value::as_str)
                            .unwrap_or("Harness reported a protocol error");
                        if let Ok(mut slot) = protocol_error.lock() {
                            *slot = Some(message.chars().take(1000).collect());
                        }
                    }
                }
                let piece = if parse_json {
                    extract_text(&line)
                } else {
                    Some(line)
                };
                if let Some(piece) = piece.filter(|s| !s.is_empty()) {
                    text_out.append(&piece);
                }
            }
            // OpenCode can persist a final text part without emitting it on
            // its CLI JSON stream. Reconcile before releasing the reader guard.
            if let (Some((bin, cwd)), Some(slot)) = (recovery, session_id) {
                let id = slot.lock().ok().and_then(|id| id.clone());
                if let Some(id) = id {
                    let mut command = Command::new(bin);
                    command
                        .args(["export", &id])
                        .current_dir(cwd)
                        .stdin(Stdio::null());
                    if std::env::var_os("OPENCODE_DB").is_none() {
                        command.env("OPENCODE_DB", "orb-local.db");
                    }
                    if let Ok(result) = command.output() {
                        if result.status.success() {
                            if let Ok(value) = serde_json::from_slice::<Value>(&result.stdout) {
                                if let Some(answer) = opencode_final_answer(&value) {
                                    text_out.replace(answer);
                                }
                            }
                        }
                    }
                }
            }
        });
    }
    if let Some(stderr) = stderr {
        let guard = text.reader();
        thread::spawn(move || {
            let _guard = guard;
            let mut buf = String::new();
            let _ = BufReader::new(stderr).read_to_string(&mut buf);
            let clean = strip_terminal_codes(&buf);
            let trimmed = clean.trim();
            if !trimmed.is_empty() {
                if let Ok(mut slot) = error_out.lock() {
                    if slot.is_none() {
                        *slot = Some(trimmed.chars().take(500).collect());
                    }
                }
            }
        });
    }
}

fn spawn_codex(
    request: &StartRequest,
    text: &Arc<Output>,
    session_out: &Arc<Mutex<Option<String>>>,
    error: &Arc<Mutex<Option<String>>>,
    done: &Arc<AtomicBool>,
    env: &[(String, String)],
) -> Result<Child, String> {
    let mut command = mission_command(request, env);
    // Apply the same full-access policy before app-server startup and thread creation.
    command.args([
        "-c",
        "approval_policy=\"never\"",
        "-c",
        "sandbox_mode=\"danger-full-access\"",
    ]);
    if let Some(args) = crate::local_wakeups::command(&request.id) {
        command.arg("-c").arg(format!(
            "mcp_servers.orb-wakeups.command={}",
            json!(args[0])
        ));
        command
            .arg("-c")
            .arg(format!("mcp_servers.orb-wakeups.args={}", json!(args[1..])));
        // This private, mission-bound MCP must work under approvalPolicy=never,
        // just like the common sandboxed MCP installed by the launcher.
        command
            .arg("-c")
            .arg("mcp_servers.orb-wakeups.default_tools_approval_mode=\"approve\"");
    }
    let mut child = command
        .current_dir(&request.cwd)
        .arg("app-server")
        .args(["--enable", "goals"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("failed to start Codex: {e}"))?;
    let mut stdin = child.stdin.take().ok_or("codex stdin missing")?;
    let stdout = child.stdout.take().ok_or("codex stdout missing")?;
    let stderr = child.stderr.take();
    let prompt = request.prompt.clone();
    let mission_id = crate::interactions::session(&request.id);
    let image_paths = request.image_paths.clone();
    let cyber_access = request.cyber_access.unwrap_or_default();
    let model = request.model.clone();
    let cwd = request.cwd.clone();
    let resume = request.session_id.clone().filter(|s| !s.is_empty());
    let text_bg = Arc::clone(text);
    let session_bg = Arc::clone(session_out);
    let error_bg = Arc::clone(error);
    let done_bg = Arc::clone(done);
    if let Some(stderr) = stderr {
        thread::spawn(move || {
            // Diagnostics are not turn outcomes. In particular app-server shutdown
            // can emit rollout warnings after a successful turn.
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                eprintln!("Codex diagnostic: {}", strip_terminal_codes(&line));
            }
        });
    }
    let guard = text.reader();
    thread::spawn(move || {
        let _guard = guard;
        let mut reader = BufReader::new(stdout);
        let result = drive_codex(
            &mut stdin,
            &mut reader,
            &prompt,
            &image_paths,
            model.as_deref(),
            cyber_access,
            &cwd,
            resume.as_deref(),
            &text_bg,
            &session_bg,
            &mission_id,
        );
        crate::interactions::finish(&mission_id);
        if let Err(message) = result {
            eprintln!("Codex run failed: {message}");
            if let Ok(mut slot) = error_bg.lock() {
                *slot = Some(if busy_thread(&message) {
                    format!("Codex thread is busy: {message}")
                } else {
                    message
                });
            }
        }
        done_bg.store(true, Ordering::SeqCst);
    });
    Ok(child)
}

fn busy_thread(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("busy")
        || lower.contains("already")
        || lower.contains("in progress")
        || lower.contains("in use")
}

// Native Codex caps goals at 4,000 characters. Keep oversized instructions
// verbatim in a durable file rather than silently truncating their requirements.
fn codex_goal_objective(objective: &str, cwd: &str) -> Result<String, String> {
    if objective.len() <= 4000 {
        return Ok(objective.to_string());
    }
    let path = std::path::Path::new(cwd).join(format!(".orb-goal-{}.md", uuid::Uuid::new_v4()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|e| format!("Could not preserve full goal: {e}"))?;
    file.write_all(objective.as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|e| format!("Could not preserve full goal: {e}"))?;
    let goal = format!("Complete the full user objective stored in {}. Read that file before acting. It contains the authoritative requirements and acceptance criteria, all of which must be satisfied before marking this goal complete. Preserve the file for continuation turns.", path.display());
    if goal.len() > 4000 {
        return Err("Workspace path is too long for a native Codex goal".into());
    }
    Ok(goal)
}

fn drive_codex(
    stdin: &mut impl Write,
    reader: &mut impl BufRead,
    prompt: &str,
    image_paths: &[String],
    model: Option<&str>,
    cyber_access: crate::cyber_access::Mode,
    cwd: &str,
    resume: Option<&str>,
    text: &Output,
    session_out: &Mutex<Option<String>>,
    mission_id: &crate::interactions::Session,
) -> Result<(), String> {
    rpc(
        stdin,
        reader,
        "initialize",
        json!({
            "clientInfo": {"name": "orb", "version": "0.1.0"},
            "capabilities": {"experimentalApi": true}
        }),
    )?;
    let _ = write_line(stdin, &json!({"method": "initialized"}).to_string());
    let params = json!({
        "model": model,
        "cwd": cwd,
        "approvalPolicy": "never",
        "sandbox": "danger-full-access"
    });
    let started = if let Some(thread_id) = resume {
        let mut resume_params = params.clone();
        resume_params["threadId"] = json!(thread_id);
        rpc(stdin, reader, "thread/resume", resume_params)?
    } else {
        rpc(stdin, reader, "thread/start", params)?
    };
    let thread_id = started
        .pointer("/thread/id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "codex did not return a thread id".to_string())?
        .to_string();
    if let Ok(mut slot) = session_out.lock() {
        *slot = Some(thread_id.clone());
    }
    let resolved_model = model.or_else(|| started.get("model").and_then(Value::as_str));
    let goal_objective = prompt
        .trim()
        .strip_prefix("/goal")
        .filter(|rest| rest.starts_with(char::is_whitespace))
        .map(str::trim)
        .filter(|rest| !rest.is_empty());
    let cyber_program = cyber_access.native(resolved_model.unwrap_or(""))?;
    if let Some(program) = cyber_program {
        let account = rpc(stdin, reader, "account/read", json!({"refreshToken":false}))?;
        if account.pointer("/account/type").and_then(Value::as_str) != Some("chatgpt")
            || started["modelProvider"].as_str() != Some("openai")
        {
            return Err("unsupported_access_program: explicit cyber selection requires a native ChatGPT connection. Choose Automatic explicitly for this connection.".into());
        }
        let catalog = rpc(
            stdin,
            reader,
            "model/list",
            json!({"includeHidden":true,"limit":100}),
        )?;
        let accepted = catalog["data"]
            .as_array()
            .and_then(|models| {
                models
                    .iter()
                    .find(|m| m["model"].as_str() == resolved_model)
            })
            .and_then(|m| m.pointer("/availableAccessPrograms/cyber"))
            .and_then(|v| v.as_array());
        if accepted.is_none() {
            return Err("unsupported_access_program: this connection does not advertise cyber capabilities for this model. No turn was started.".into());
        }
        if !accepted.is_some_and(|values| values.iter().any(|v| v.as_str() == Some(program))) {
            return Err("access_program_not_enabled: the selected account does not advertise this cyber program for this model. No turn was started.".into());
        }
        if goal_objective.is_some() {
            return Err("unsupported_access_program: native goal continuations do not confirm per-turn cyber selection. Choose Automatic explicitly for this goal.".into());
        }
    }
    let mut goal_mode = goal_objective.is_some();
    let plan_prompt = prompt
        .trim()
        .strip_prefix("/plan")
        .filter(|rest| rest.is_empty() || rest.starts_with(char::is_whitespace));
    let mut planning = plan_prompt.is_some();
    let mut input =
        vec![json!({"type":"text", "text":plan_prompt.map(str::trim).unwrap_or(prompt)})];
    input.extend(
        image_paths
            .iter()
            .map(|path| json!({"type":"localImage", "path":path})),
    );
    let mut pending = Vec::new();
    if let Some(objective) = goal_objective {
        if !image_paths.is_empty() {
            return Err("Goal launches with images are not supported yet; include file paths in the objective.".into());
        }
        let objective = codex_goal_objective(objective, cwd)?;
        rpc_collect(
            stdin,
            reader,
            "thread/goal/set",
            json!({"threadId":thread_id,"objective":objective}),
            &mut pending,
        )?;
    } else {
        if resume.is_some() {
            let goal = rpc_collect(
                stdin,
                reader,
                "thread/goal/get",
                json!({"threadId":thread_id}),
                &mut pending,
            )?;
            goal_mode = goal.pointer("/goal/status").and_then(Value::as_str) == Some("active");
            if cyber_program.is_some() && goal_mode {
                return Err("unsupported_access_program: choose Automatic explicitly to resume a native goal.".into());
            }
        }
        let _ = rpc_collect(
            stdin,
            reader,
            "turn/start",
            json!({
                "threadId": thread_id,
                "cyberAccessProgram": cyber_program,
                "input": input,
                "collaborationMode": {"mode": if planning {"plan"} else {"default"}, "settings": {"model":resolved_model.ok_or("Codex did not resolve a model for collaboration mode")?, "reasoning_effort":null, "developer_instructions":null}}
            }),
            &mut pending,
        )?;
    }
    let mut pending: std::collections::VecDeque<Value> = pending.into();
    let mut items = crate::local_stream::CodexText::default();
    let mut line = String::new();
    loop {
        let value = if let Some(event) = pending.pop_front() {
            event
        } else {
            line.clear();
            let n = reader.read_line(&mut line).map_err(|e| e.to_string())?;
            if n == 0 {
                return Err("Codex stream closed before the turn completed".into());
            }
            let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
                continue;
            };
            value
        };
        // App-server also emits notifications for child agents. Their output,
        // errors and turn completion must never terminate this thread.
        if value
            .pointer("/params/threadId")
            .or_else(|| value.pointer("/params/thread_id"))
            .and_then(Value::as_str)
            .is_some_and(|id| id != thread_id)
        {
            continue;
        }
        if let Some(message) = value
            .get("error")
            .and_then(|e| e.get("message"))
            .and_then(|m| m.as_str())
        {
            return Err(message.to_string());
        }
        let method = value.get("method").and_then(|m| m.as_str()).unwrap_or("");
        if let Some(id) = value.get("id").filter(|_| !method.is_empty()) {
            if method == "item/tool/requestUserInput" || method == "tool/requestUserInput" {
                let answer =
                    crate::interactions::ask(mission_id, "questions", value["params"].clone())?;
                write_line(stdin, &json!({"id":id,"result":answer}).to_string())?;
            } else {
                // Never treat an unknown request as an approval.
                write_line(stdin, &json!({"id":id,"error":{"code":-32601,"message":"Unsupported interactive request"}}).to_string())?;
            }
            continue;
        }
        if method == "error"
            && value.pointer("/params/willRetry").and_then(Value::as_bool) == Some(true)
        {
            text.codex_reconnecting(
                value
                    .pointer("/params/error/message")
                    .and_then(Value::as_str),
            );
            continue;
        }
        if matches!(
            method,
            "item/started" | "item/agentMessage/delta" | "turn/completed" | "turn/complete"
        ) {
            text.codex_reconnecting(None);
        }
        if method == "error" {
            if let Some(message) = value
                .pointer("/params/error/message")
                .and_then(Value::as_str)
            {
                return Err(message.to_string());
            }
        }
        if method == "turn/completed" || method == "turn/complete" {
            if value.pointer("/params/turn/status").and_then(Value::as_str) == Some("failed") {
                return Err(value
                    .pointer("/params/turn/error/message")
                    .and_then(Value::as_str)
                    .unwrap_or("Codex turn failed")
                    .to_owned());
            }
            if planning
                && value.pointer("/params/turn/status").and_then(Value::as_str)
                    != Some("interrupted")
            {
                let answer =
                    crate::interactions::ask(mission_id, "plan", json!({"plan":text.snapshot()}))?;
                planning = answer["action"] != "accept";
                let followup = if planning {
                    answer["feedback"].as_str().unwrap_or("Revise the plan.")
                } else {
                    "Implement the approved plan."
                };
                let mut early = Vec::new();
                let next = rpc_collect(
                    stdin,
                    reader,
                    "turn/start",
                    json!({"threadId":thread_id,"cyberAccessProgram":cyber_program,"input":[{"type":"text","text":followup}],"collaborationMode":{"mode":if planning {"plan"} else {"default"},"settings":{"model":resolved_model.ok_or("Codex did not resolve a model for collaboration mode")?,"reasoning_effort":null,"developer_instructions":null}}}),
                    &mut early,
                );
                next?;
                pending.extend(early);
                continue;
            }
            if goal_mode
                && value.pointer("/params/turn/status").and_then(Value::as_str)
                    != Some("interrupted")
            {
                let mut early = Vec::new();
                let goal = rpc_collect(
                    stdin,
                    reader,
                    "thread/goal/get",
                    json!({"threadId":thread_id}),
                    &mut early,
                )?;
                pending.extend(early);
                if goal.pointer("/goal/status").and_then(Value::as_str) == Some("active") {
                    continue;
                }
            }
            break;
        }
        text.native_activity(&value);
        if matches!(method, "item/started" | "item/completed") {
            text.publish_activities();
        }
        items.apply(&value, text);
    }
    Ok(())
}

fn rpc(
    stdin: &mut impl Write,
    reader: &mut impl BufRead,
    method: &str,
    params: Value,
) -> Result<Value, String> {
    rpc_collect(stdin, reader, method, params, &mut Vec::new())
}

fn rpc_collect(
    stdin: &mut impl Write,
    reader: &mut impl BufRead,
    method: &str,
    params: Value,
    pending: &mut Vec<Value>,
) -> Result<Value, String> {
    let id = format!("orb-{method}");
    write_line(
        stdin,
        &json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}).to_string(),
    )?;
    let mut line = String::new();
    loop {
        line.clear();
        let n = reader.read_line(&mut line).map_err(|e| e.to_string())?;
        if n == 0 {
            return Err(format!("{method} closed the stream"));
        }
        let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        if value.get("id").and_then(Value::as_str) == Some(id.as_str())
            && value.get("method").is_none()
        {
            if let Some(error) = value.get("error") {
                return Err(format!(
                    "{method}: {}",
                    error["message"].as_str().unwrap_or("Codex RPC failed")
                ));
            }
            return Ok(value.get("result").cloned().unwrap_or(Value::Null));
        }
        pending.push(value);
    }
}

fn write_line(stdin: &mut impl Write, line: &str) -> Result<(), String> {
    stdin
        .write_all(line.as_bytes())
        .map_err(|e| e.to_string())?;
    stdin.write_all(b"\n").map_err(|e| e.to_string())?;
    stdin.flush().map_err(|e| e.to_string())
}

/// How long an agent waits on the same background tasks before Orb asks it
/// again whether they are still wanted. The last delay repeats.
const RECHECK_DELAYS: [Duration; 3] = [
    Duration::from_secs(3600),
    Duration::from_secs(4 * 3600),
    Duration::from_secs(12 * 3600),
];

fn recheck_delays(_id: &str) -> Vec<Duration> {
    #[cfg(test)]
    if let Some(delays) = tests::recheck_delays().lock().unwrap().get(_id) {
        return delays.clone();
    }
    RECHECK_DELAYS.to_vec()
}

#[derive(Clone)]
struct BackgroundTask {
    id: String,
    kind: String,
    label: String,
    output: Option<PathBuf>,
    started: Instant,
}
impl BackgroundTask {
    fn new(id: &str, event: &Value, known: Option<&BackgroundTask>) -> Self {
        let field = |name: &str, known: Option<&String>| {
            event[name]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(|s| s.chars().take(240).collect())
                .or_else(|| known.cloned())
                .unwrap_or_default()
        };
        Self {
            id: id.into(),
            kind: field("task_type", known.map(|t| &t.kind)),
            label: field("description", known.map(|t| &t.label)),
            output: known.and_then(|t| t.output.clone()),
            started: known.map_or_else(Instant::now, |t| t.started),
        }
    }
    /// A command ends only when its process does, unlike an agent.
    fn shell(&self) -> bool {
        self.kind == "local_bash"
    }
    fn describe(&self) -> String {
        let kind = match self.kind.as_str() {
            "local_bash" => "shell command",
            "local_agent" => "agent",
            "" => "task",
            other => other,
        };
        let minutes = self.started.elapsed().as_secs() / 60;
        let age = if minutes < 60 {
            format!("{minutes} min")
        } else {
            format!("{} h {} min", minutes / 60, minutes % 60)
        };
        let label = if self.label.is_empty() {
            "(no description)"
        } else {
            &self.label
        };
        let mut text = format!("- {label} ({kind}, id {}, running for {age})", self.id);
        let Some(path) = &self.output else {
            return text;
        };
        text.push_str(&format!("\n  output file: {}", path.display()));
        match output_tail(path) {
            Some(lines) if lines.is_empty() => text.push_str("\n  it has printed nothing"),
            Some(lines) => {
                text.push_str("\n  last output:");
                for line in lines {
                    text.push_str(&format!("\n    {line}"));
                }
            }
            None => {}
        }
        text
    }
}

fn strings<'a>(value: &'a Value, found: &mut Vec<&'a str>) {
    match value {
        Value::String(text) => found.push(text),
        Value::Array(items) => items.iter().for_each(|item| strings(item, found)),
        Value::Object(fields) => fields.values().for_each(|item| strings(item, found)),
        _ => {}
    }
}

/// The path in "… written to: <path>/tasks/<id>.output. You will …", with the
/// separators of any system. A path may hold spaces.
fn output_path<'a>(text: &'a str, id: &str) -> Option<&'a str> {
    let end = ['/', '\\'].iter().find_map(|separator| {
        let name = format!("tasks{separator}{id}.output");
        text.find(&name).map(|at| at + name.len())
    })?;
    let before = &text[..end];
    let start = before
        .rfind(": ")
        .map(|at| at + 2)
        .or_else(|| before.rfind(char::is_whitespace).map(|at| at + 1))
        .unwrap_or(0);
    Some(&before[start..])
}

/// The last lines a background command printed.
fn output_tail(path: &Path) -> Option<Vec<String>> {
    use std::io::{Seek, SeekFrom};
    let mut file = std::fs::File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(size.saturating_sub(4096))).ok()?;
    let mut bytes = Vec::new();
    file.take(4096).read_to_end(&mut bytes).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    let mut lines: Vec<String> = text
        .lines()
        .rev()
        .filter(|line| !line.trim().is_empty())
        .take(5)
        .map(|line| line.trim_end().chars().take(200).collect())
        .collect();
    lines.reverse();
    Some(lines)
}

/// Prefer the CLI's authoritative live task snapshot; older CLIs expose edges.
#[derive(Default)]
struct ClaudeBackground {
    tasks: HashMap<String, BackgroundTask>,
    has_snapshot: bool,
    /// Commands the agent was already asked about.
    checked: std::collections::HashSet<String>,
}
impl ClaudeBackground {
    fn consume(&mut self, event: &Value) {
        if event["type"] != "system" {
            return;
        }
        match event["subtype"].as_str() {
            Some("background_tasks_changed") => {
                if let Some(tasks) = event["tasks"].as_array() {
                    self.has_snapshot = true;
                    self.tasks = tasks
                        .iter()
                        .filter(|t| t["ambient"] != true)
                        .filter_map(|t| {
                            let id = t["task_id"].as_str()?;
                            Some((id.into(), BackgroundTask::new(id, t, self.tasks.get(id))))
                        })
                        .collect();
                }
            }
            Some("task_started") if event["ambient"] != true => {
                if let Some(id) = event["task_id"].as_str() {
                    // A snapshot decides which tasks run; this only names them.
                    if !self.has_snapshot || self.tasks.contains_key(id) {
                        let task = BackgroundTask::new(id, event, self.tasks.get(id));
                        self.tasks.insert(id.into(), task);
                    }
                }
            }
            Some("task_notification") if !self.has_snapshot => {
                if let Some(id) = event["task_id"].as_str() {
                    self.tasks.remove(id);
                }
            }
            _ => {}
        }
    }
    /// The CLI names a command's output file in the tool result that started it.
    fn note_output(&mut self, event: &Value) {
        if event["type"] != "user" || self.tasks.values().all(|t| t.output.is_some()) {
            return;
        }
        let mut texts = Vec::new();
        strings(&event["message"]["content"], &mut texts);
        for task in self.tasks.values_mut() {
            if task.output.is_none() && task.shell() {
                task.output = texts
                    .iter()
                    .find_map(|text| output_path(text, &task.id))
                    .map(PathBuf::from)
                    .filter(|path| path.is_absolute());
            }
        }
    }
    fn running(&self) -> bool {
        !self.tasks.is_empty()
    }
    fn list(&self) -> Vec<BackgroundTask> {
        let mut tasks: Vec<_> = self.tasks.values().cloned().collect();
        tasks.sort_by_key(|task| task.started);
        tasks
    }
    /// What to ask an agent that ended its turn with commands it was not asked
    /// about yet. Agents it started end by themselves and are not questioned.
    fn unchecked(&mut self) -> Option<String> {
        let tasks: Vec<_> = self
            .list()
            .into_iter()
            .filter(|task| task.shell() && !self.checked.contains(&task.id))
            .collect();
        if tasks.is_empty() {
            return None;
        }
        self.checked
            .extend(tasks.iter().map(|task| task.id.clone()));
        Some(background_question(
            "Your turn ended while these background commands still run:",
            &tasks,
        ))
    }
}

fn background_question(title: &str, tasks: &[BackgroundTask]) -> String {
    let list: Vec<_> = tasks.iter().map(BackgroundTask::describe).collect();
    format!(
        "[Automatic check from Orb, not a message from the user]\n{title}\n{}\n\n\
         The conversation stays busy until every one of them exits. Keep a task only if you \
         wait for its result and it can still finish: you are woken when it exits. Stop with \
         TaskStop each task that is stuck, that loops without a way to end, or whose result \
         you no longer need. Do not start new work. Reply in one short sentence.",
        list.join("\n")
    )
}

/// Asks the agent again about background tasks it has waited on for long.
#[derive(Default)]
struct Recheck(Mutex<RecheckState>, std::sync::Condvar);
#[derive(Default)]
struct RecheckState {
    waiting: Option<(Instant, Vec<BackgroundTask>)>,
    asked: usize,
    closed: bool,
}
impl Recheck {
    fn waiting(&self, tasks: Option<Vec<BackgroundTask>>) {
        let mut state = self.0.lock().unwrap();
        let since = state.waiting.as_ref().map(|(since, _)| *since);
        if tasks.is_none() && since.is_none() {
            return;
        }
        state.waiting = tasks.map(|tasks| (since.unwrap_or_else(Instant::now), tasks));
        self.1.notify_all();
    }
    /// The tasks changed; how long the agent has waited did not.
    fn refresh(&self, tasks: Vec<BackgroundTask>) {
        if let Some((_, waiting)) = &mut self.0.lock().unwrap().waiting {
            *waiting = tasks;
        }
    }
    /// New tasks start from the first delay.
    fn restart(&self) {
        self.0.lock().unwrap().asked = 0;
        // The timer may already sleep for the longer delay of the old tasks.
        self.1.notify_all();
    }
    fn close(&self) {
        self.0.lock().unwrap().closed = true;
        self.1.notify_all();
    }
    fn run(&self, stdin: &Mutex<std::process::ChildStdin>, delays: &[Duration]) {
        let mut state = self.0.lock().unwrap();
        while !state.closed {
            let Some((since, _)) = &state.waiting else {
                state = self.1.wait(state).unwrap();
                continue;
            };
            let delay = delays[state.asked.min(delays.len() - 1)];
            let left = delay.saturating_sub(since.elapsed());
            if !left.is_zero() {
                state = self.1.wait_timeout(state, left).unwrap().0;
                continue;
            }
            // The answer is a turn of its own: the next delay counts from its end.
            // Written under the lock, so that it names the tasks that run now:
            // the reader cannot change them meanwhile. Only the send is outside,
            // where a full pipe must not hold the reader.
            let (_, tasks) = state.waiting.take().unwrap();
            state.asked += 1;
            let question = background_question("These background tasks still run:", &tasks);
            drop(state);
            let line = json!({"type":"user","message":{"role":"user","content":question}});
            if write_line(&mut *stdin.lock().unwrap(), &line.to_string()).is_err() {
                return;
            }
            state = self.0.lock().unwrap();
        }
    }
}

/// Text deltas have no separator between independent Claude messages. Preserve
/// protocol boundaries without inserting whitespace between token fragments.
#[derive(Default)]
struct ClaudeText {
    emitted: bool,
    boundary: bool,
    message_emitted: bool,
    message_id: Option<String>,
}

impl ClaudeText {
    fn consume(&mut self, value: &Value) -> Option<String> {
        if value["type"] == "result" && value["is_error"] != true && !self.emitted {
            let text = value["result"]
                .as_str()
                .filter(|text| !text.trim().is_empty())?;
            self.emitted = true;
            return Some(text.to_owned());
        }
        let id = if value["type"] == "assistant" {
            value["message"]["id"].as_str()
        } else {
            value["event"]["message"]["id"].as_str()
        };
        if let Some(id) = id {
            if self.message_id.as_deref() != Some(id) {
                self.message_id = Some(id.to_owned());
                self.message_emitted = false;
            }
        }
        if value["type"] == "assistant" && !self.message_emitted {
            let text = value["message"]["content"]
                .as_array()?
                .iter()
                .filter(|block| block["type"] == "text")
                .filter_map(|block| block["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n\n");
            if text.is_empty() {
                return None;
            }
            let result = if self.emitted {
                format!("\n\n{text}")
            } else {
                text
            };
            self.emitted = true;
            self.message_emitted = true;
            self.boundary = false;
            return Some(result);
        }
        if value["type"] != "stream_event" {
            return None;
        }
        let event = &value["event"];
        match event["type"].as_str() {
            Some("message_start") => {
                self.boundary = self.emitted;
                self.message_emitted = false;
            }
            Some("content_block_start") if event["content_block"]["type"] == "text" => {
                self.boundary = self.emitted;
            }
            _ => {}
        }
        if event["delta"]["type"] != "text_delta" {
            return None;
        }
        let text = event["delta"]["text"].as_str()?;
        if text.is_empty() {
            return None;
        }
        let result = if self.boundary {
            format!("\n\n{text}")
        } else {
            text.to_owned()
        };
        self.boundary = false;
        self.emitted = true;
        self.message_emitted = true;
        Some(result)
    }
}

// Consume only protocol events representing new assistant output. Recursive
// text extraction also captures user items, tool arguments and final snapshots.
fn extract_text(line: &str) -> Option<String> {
    let value: Value = serde_json::from_str(line).ok()?;
    let text = if let Some(method) = value["method"].as_str() {
        match method {
            "item/agentMessage/delta" => value.pointer("/params/delta")?.as_str(),
            _ => None,
        }
    } else {
        match value["type"].as_str()? {
            "stream_event" if value.pointer("/event/delta/type")?.as_str()? == "text_delta" => {
                value.pointer("/event/delta/text")?.as_str()
            }
            "text" => value
                .pointer("/part/text")
                .or_else(|| value.get("data"))?
                .as_str(), // OpenCode or Grok
            _ => None,
        }
    }?;
    (!text.is_empty()).then(|| text.to_owned())
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

// Conservative floors: these are the versions exercised by the native
// round-trip tests, not merely a CLI binary being present on PATH.
fn native_plan_supported(id: &str, version: &str) -> bool {
    let minimum = match id {
        "codex" => (0, 155, 0),
        "claudecode" => (2, 1, 278),
        _ => return false,
    };
    version
        .split_whitespace()
        .find_map(|part| {
            let mut pieces = part.split('.');
            Some((
                pieces.next()?.parse::<u32>().ok()?,
                pieces.next()?.parse::<u32>().ok()?,
                pieces.next()?.parse::<u32>().ok()?,
            ))
        })
        .is_some_and(|v| v >= minimum)
}

fn version_of(path: &Path) -> Option<String> {
    let mut child = Command::new(path)
        .arg("--version")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .ok()?;
    let start = Instant::now();
    loop {
        if start.elapsed() > Duration::from_secs(3) {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        match child.try_wait() {
            Ok(Some(status)) if status.success() => {
                let mut out = String::new();
                if let Some(mut stdout) = child.stdout.take() {
                    let _ = stdout.read_to_string(&mut out);
                }
                if out.trim().is_empty() {
                    if let Some(mut stderr) = child.stderr.take() {
                        let _ = stderr.read_to_string(&mut out);
                    }
                }
                return out
                    .lines()
                    .next()
                    .map(|line| line.trim().to_string())
                    .filter(|s| !s.is_empty());
            }
            Ok(Some(_)) => return None,
            Ok(None) => thread::sleep(Duration::from_millis(40)),
            Err(_) => return None,
        }
    }
}

fn workspace_root() -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME is unset".to_string())?;
    Ok(PathBuf::from(home).join(".orb").join("local-workspaces"))
}

fn safe_slug(slug: &str) -> Result<String, String> {
    let slug = slug.trim();
    if slug.is_empty() || slug.contains('/') || slug.contains("..") || slug.contains('\\') {
        return Err("project slug is not a single path segment".into());
    }
    Ok(slug.to_string())
}

pub(crate) fn safe_rel(rel: &str) -> Result<PathBuf, String> {
    let rel = rel.trim().trim_start_matches("./");
    if rel.is_empty() || rel.contains('\\') || rel.chars().any(char::is_control) {
        return Err("attachment path is required".into());
    }
    let mut out = PathBuf::new();
    for component in Path::new(rel).components() {
        match component {
            Component::Normal(part) => out.push(part),
            _ => return Err("path must be relative with no '..' components".into()),
        }
    }
    Ok(out)
}

pub(crate) fn is_secret_path(rel: &str) -> bool {
    let lower = rel.replace('\\', "/").to_ascii_lowercase();
    let name = lower.rsplit('/').next().unwrap_or(&lower);
    if lower.split('/').any(|part| {
        matches!(part, ".git" | ".ssh" | ".aws" | ".codex" | ".claude")
            || part == ".env"
            || part.starts_with(".env.")
    }) {
        return true;
    }
    name == ".env"
        || name.starts_with(".env.")
        || name.ends_with(".pem")
        || name.ends_with(".key")
        || name == "id_rsa"
        || name.starts_with("id_rsa.")
        || name.starts_with("id_ed25519")
        || name.contains("credentials")
        || name == "auth.json"
        || name == "secrets"
        || name == "secrets.yaml"
        || name == "secrets.yml"
        || name == "secrets.json"
        || name.ends_with(".p12")
        || name.ends_with(".pfx")
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    #[test]
    fn retired_gemini_cannot_be_launched_from_saved_requests() {
        assert!(!HARNESSES.iter().any(|(id, _)| *id == "gemini"));
        let request = StartRequest {
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
        };
        let error = spawn_harness(
            &request,
            &Arc::new(Output::default()),
            &Arc::new(Mutex::new(None)),
            &Arc::new(Mutex::new(None)),
            &Arc::new(AtomicBool::new(false)),
            &[],
        )
        .unwrap_err();
        assert_eq!(error, "unknown local harness gemini");
    }

    #[test]
    fn antigravity_unbound_attempt_survives_retry_and_allows_known_resume() {
        let root = tempfile::tempdir().unwrap();
        let marker = claim_antigravity_attempt(root.path(), "mission", root.path(), None)
            .unwrap()
            .unwrap();
        assert!(marker.is_file());
        let destination = tempfile::tempdir().unwrap();
        assert!(
            claim_antigravity_attempt(root.path(), "mission", destination.path(), None).is_ok()
        );
        assert!(claim_antigravity_attempt(root.path(), "mission", root.path(), None).is_err());
        assert!(claim_antigravity_attempt(root.path(), "mission", root.path(), Some("")).is_err());
        assert!(
            claim_antigravity_attempt(root.path(), "mission", root.path(), Some("native-id"))
                .unwrap()
                .is_none()
        );
        assert!(claim_antigravity_attempt(root.path(), "other", root.path(), None).is_ok());
    }

    #[test]
    fn antigravity_process_requires_terminal_result_and_preserves_resume() {
        use std::os::unix::fs::PermissionsExt;
        for outcome in ["SUCCESS", "MISSING", "ERROR"] {
            let success = outcome == "SUCCESS";
            let dir = tempfile::tempdir().unwrap();
            let bin = dir.path().join("agy-fixture");
            let mut script = String::from("#!/bin/sh\nprintf '%s\\n' '{\"event\":\"init\",\"conversation_id\":\"native-session\"}'\n");
            if success {
                script.push_str("printf '%s\\n' '{\"event\":\"result\",\"result\":{\"conversation_id\":\"native-session\",\"status\":\"SUCCESS\",\"response\":\"Ready\"}}'\n");
            }
            if outcome == "ERROR" {
                script.push_str("printf '%s\\n' 'AGY_ERROR: {\"short_error\":\"read: no route to host\",\"status\":\"UNKNOWN\",\"error_code\":2,\"code_kind\":\"grpc\",\"retryable\":true}' >&2\n");
                script.push_str("printf '%s\\n' '{\"event\":\"result\",\"result\":{\"conversation_id\":\"native-session\",\"status\":\"ERROR\",\"error\":\"There was a network issue connecting to the server, please try again.\",\"response\":\"Partial answer\"}}'\n");
            }
            std::fs::write(&bin, script).unwrap();
            std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
            let request = StartRequest {
                effort: None,
                cyber_revision: None,
                cyber_access: None,
                image_paths: vec![],
                id: "antigravity-fixture".into(),
                harness: "antigravity".into(),
                bin: bin.to_string_lossy().into_owned(),
                cwd: dir.path().to_string_lossy().into_owned(),
                prompt: "hello".into(),
                model: Some("agy-demo".into()),
                session_id: Some("native-session".into()),
            };
            let output = Arc::new(Output::default());
            let session = Arc::new(Mutex::new(None));
            let error = Arc::new(Mutex::new(None));
            let mut child = spawn_harness(
                &request,
                &output,
                &session,
                &error,
                &Arc::new(AtomicBool::new(false)),
                &[],
            )
            .unwrap();
            let status = child.wait().unwrap();
            if outcome != "ERROR" {
                assert!(status.success());
            }
            assert!(output.wait_drained(Some(Duration::from_secs(2))));
            assert_eq!(session.lock().unwrap().as_deref(), Some("native-session"));
            assert_eq!(error.lock().unwrap().is_none(), success);
            assert_eq!(output.retryable(), outcome == "ERROR");
            if outcome == "ERROR" {
                let message = error.lock().unwrap().clone().unwrap();
                assert!(message.contains(
                    "There was a network issue connecting to the server, please try again."
                ));
                assert!(message.contains("read: no route to host"));
            }
            if success {
                assert_eq!(output.snapshot(), "Ready");
            }
        }
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

    use super::*;

    #[test]
    fn claude_final_result_fills_missing_stream_without_duplicates() {
        let mut text = ClaudeText::default();
        let result = json!({"type":"result","is_error":false,"result":"Recovered final"});
        assert_eq!(text.consume(&result).as_deref(), Some("Recovered final"));
        assert!(text.consume(&result).is_none());
        let mut failed = ClaudeText::default();
        assert!(failed
            .consume(&json!({"type":"result","is_error":true,"result":"Rate limited"}))
            .is_none());
    }

    #[test]
    fn claude_snapshot_without_deltas_is_not_lost() {
        let mut text = ClaudeText::default();
        let event = json!({"type":"assistant","message":{"id":"a","content":[{"type":"text","text":"Final answer"}]}});
        assert_eq!(text.consume(&event).as_deref(), Some("Final answer"));
        assert!(text.consume(&event).is_none());
        let next = json!({"type":"assistant","message":{"id":"b","content":[{"type":"text","text":"Next answer"}]}});
        assert_eq!(text.consume(&next).as_deref(), Some("\n\nNext answer"));
    }

    #[test]
    fn claude_text_preserves_tokens_and_separates_message_blocks() {
        let mut text = ClaudeText::default();
        let mut output = String::new();
        for event in [
            json!({"type":"message_start"}),
            json!({"type":"content_block_start","content_block":{"type":"text"}}),
            json!({"delta":{"type":"text_delta","text":"Bon"}}),
            json!({"delta":{"type":"text_delta","text":"jour."}}),
            json!({"type":"content_block_start","content_block":{"type":"tool_use"}}),
            json!({"type":"message_start"}),
            json!({"type":"content_block_start","content_block":{"type":"text"}}),
            json!({"delta":{"type":"text_delta","text":""}}),
            json!({"delta":{"type":"text_delta","text":"La suite."}}),
            json!({"type":"content_block_start","content_block":{"type":"text"}}),
            json!({"delta":{"type":"text_delta","text":"```rust\nfn main() {}\n```"}}),
        ] {
            if let Some(piece) = text.consume(&json!({"type":"stream_event","event":event})) {
                output.push_str(&piece);
            }
        }
        assert_eq!(
            output,
            "Bonjour.\n\nLa suite.\n\n```rust\nfn main() {}\n```"
        );
        assert!(text.consume(&json!({"type":"assistant","message":{"content":[{"type":"text","text":"duplicate"}]}})).is_none());
    }

    #[test]
    fn rejects_parent_and_secret_paths() {
        assert!(safe_rel("../etc/passwd").is_err());
        assert!(safe_rel("/abs").is_err());
        assert!(is_secret_path(".env"));
        assert!(is_secret_path("notes/id_rsa"));
        assert!(!is_secret_path("notes/foo.md"));
        assert_eq!(
            safe_rel("notes/foo.md").unwrap(),
            PathBuf::from("notes/foo.md")
        );
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

    #[test]
    fn opencode_export_recovers_only_latest_turn_final_answer() {
        let user = json!({"info":{"role":"user"},"parts":[]});
        let answer = |text: &str, finish: &str| json!({"info":{"role":"assistant","finish":finish},"parts":[{"type":"text","text":text}]});
        let export = json!({"messages":[user,answer("Old answer","stop"),user,answer("......","tool-calls"),answer("Full final answer","stop")]});
        assert_eq!(
            opencode_final_answer(&export).as_deref(),
            Some("Full final answer")
        );
        let incomplete =
            json!({"messages":[user,answer("Old answer","stop"),user,answer(".","tool-calls")]});
        assert_eq!(opencode_final_answer(&incomplete), None);
    }

    #[test]
    fn grok_and_opencode_args_match_the_pinned_flags() {
        let fresh = StartRequest {
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            image_paths: vec![],
            id: "1".into(),
            harness: "opencode".into(),
            bin: "opencode".into(),
            cwd: "/tmp".into(),
            prompt: "hi".into(),
            model: Some("xai/grok".into()),
            session_id: None,
        };
        let mut grok = fresh.clone();
        grok.harness = "grok".into();
        grok.model = None;
        assert_eq!(
            grok_args(&grok),
            vec![
                "--always-approve",
                "--no-plan",
                "--output-format",
                "streaming-json",
                "-p",
                "hi"
            ]
        );
        grok.model = Some("grok-4.7".into());
        grok.session_id = Some("existing-session".into());
        assert_eq!(
            grok_args(&grok),
            vec![
                "--always-approve",
                "--no-plan",
                "--output-format",
                "streaming-json",
                "--model",
                "grok-4.7",
                "--resume",
                "existing-session",
                "-p",
                "hi"
            ]
        );
        assert_eq!(
            opencode_args(&fresh),
            vec!["run", "--format", "json", "--dir", "/tmp", "--model", "xai/grok", "hi"]
                .into_iter()
                .map(str::to_string)
                .collect::<Vec<_>>()
        );
        let smart = StartRequest {
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            model: Some("builtin/smart".into()),
            ..fresh.clone()
        };
        assert!(opencode_args(&smart).contains(&"sandboxed-sh/builtin/smart".to_string()));
        let resumed = StartRequest {
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            session_id: Some("ses_abc".into()),
            ..fresh
        };
        assert!(opencode_args(&resumed)
            .windows(2)
            .any(|pair| pair == ["--session".to_string(), "ses_abc".to_string()]));
    }

    #[test]
    fn output_excludes_user_echoes_snapshots_and_tools() {
        let events = [
            json!({"method":"item/started","params":{"item":{"type":"userMessage","content":[{"type":"text","text":"PROMPT"}]}}}),
            json!({"method":"item/completed","params":{"item":{"type":"userMessage","content":[{"type":"text","text":"PROMPT"}]}}}),
            json!({"method":"item/agentMessage/delta","params":{"delta":"Hello"}}),
            json!({"method":"item/completed","params":{"item":{"type":"agentMessage","text":"Hello"}}}),
            json!({"method":"item/commandExecution/outputDelta","params":{"delta":"TOOL"}}),
            json!({"type":"user","message":{"content":[{"type":"text","text":"PROMPT"}]}}),
            json!({"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}),
        ];
        let text: String = events
            .iter()
            .filter_map(|e| extract_text(&e.to_string()))
            .collect();
        assert_eq!(text, "Hello");
        assert_eq!(
            extract_text(r#"{"type":"text","part":{"text":"OpenCode"}}"#).as_deref(),
            Some("OpenCode")
        );
    }

    #[test]
    fn cyber_access_goal_guard_uses_the_native_command_boundary() {
        for prompt in ["/goal", "/goalkeeper", "/goal Work"] {
            let events = [
                json!({"id":"orb-initialize","result":{}}),
                json!({"id":"orb-thread/start","result":{"model":"gpt-6.1-sol","modelProvider":"openai","thread":{"id":"thread"}}}),
                json!({"id":"orb-account/read","result":{"account":{"type":"chatgpt"}}}),
                json!({"id":"orb-model/list","result":{"data":[{"model":"gpt-6.1-sol","availableAccessPrograms":{"cyber":["standard"]}}]}}),
                json!({"id":"orb-turn/start","result":{}}),
                json!({"method":"turn/completed","params":{"turn":{"status":"completed"}}}),
            ];
            let input = events
                .iter()
                .map(Value::to_string)
                .collect::<Vec<_>>()
                .join("\n")
                + "\n";
            let mut sent = Vec::new();
            let result = drive_codex(
                &mut sent,
                &mut std::io::Cursor::new(input),
                prompt,
                &[],
                Some("gpt-6.1-sol"),
                crate::cyber_access::Mode::Standard,
                "/tmp",
                None,
                &Output::default(),
                &Mutex::new(None),
                &crate::interactions::begin("cyber-goal-boundary"),
            );
            let sent = String::from_utf8(sent).unwrap();
            if prompt == "/goal Work" {
                assert!(result.unwrap_err().contains("unsupported_access_program"));
                assert!(!sent.contains("turn/start"));
            } else {
                result.unwrap();
                assert!(sent.contains("turn/start"));
                assert!(!sent.contains("thread/goal/set"));
            }
        }
    }

    #[test]
    fn cyber_access_denial_does_not_start_or_substitute_a_turn() {
        let events = [
            json!({"id":"orb-initialize","result":{}}),
            json!({"id":"orb-thread/start","result":{"model":"gpt-6.1-sol","modelProvider":"openai","thread":{"id":"thread"}}}),
            json!({"id":"orb-account/read","result":{"account":{"type":"chatgpt"}}}),
            json!({"id":"orb-model/list","result":{"data":[{"model":"gpt-6.1-sol","availableAccessPrograms":{"cyber":["standard"]}}]}}),
        ];
        let input = events
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        let mut sent = Vec::new();
        let session = Mutex::new(None);
        let error = drive_codex(
            &mut sent,
            &mut std::io::Cursor::new(input),
            "Reply OK",
            &[],
            Some("gpt-6.1-sol"),
            crate::cyber_access::Mode::Daybreak,
            "/tmp",
            None,
            &Output::default(),
            &session,
            &crate::interactions::begin("cyber-denial-test"),
        )
        .unwrap_err();
        assert!(error.contains("access_program_not_enabled"));
        assert_eq!(session.lock().unwrap().as_deref(), Some("thread"));
        let sent = String::from_utf8(sent).unwrap();
        assert!(!sent.contains("turn/start"));
        assert!(!sent.contains("gpt-daybreak-blue-latest"));
    }

    #[test]
    fn codex_keeps_early_deltas_and_reconciles_final_items() {
        let events = [
            json!({"id":"orb-initialize","result":{}}),
            json!({"id":"orb-thread/start","result":{"model":"test-model","thread":{"id":"thread"}}}),
            json!({"method":"item/agentMessage/delta","params":{"itemId":"a","delta":"Early"}}),
            json!({"id":"orb-turn/start","result":{}}),
            json!({"method":"item/agentMessage/delta","params":{"threadId":"child","itemId":"child","delta":"Wrong thread"}}),
            json!({"method":"turn/completed","params":{"threadId":"child","turn":{"status":"completed"}}}),
            json!({"method":"error","params":{"threadId":"child","error":{"message":"child failure"}}}),
            json!({"method":"item/completed","params":{"item":{"type":"agentMessage","id":"a","text":"Early answer"}}}),
            json!({"method":"turn/completed","params":{"turn":{"status":"completed"}}}),
        ];
        let input = events
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        let output = Output::default();
        let mut requests = Vec::new();
        drive_codex(
            &mut requests,
            &mut std::io::Cursor::new(input),
            "prompt",
            &["/tmp/pasted.png".into()],
            None,
            crate::cyber_access::Mode::Automatic,
            "/tmp",
            None,
            &output,
            &Mutex::new(None),
            &crate::interactions::begin("test-codex"),
        )
        .unwrap();
        assert_eq!(output.snapshot(), "Early answer");
        let sent: Vec<Value> = String::from_utf8(requests)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let turn = sent
            .iter()
            .find(|event| event["method"] == "turn/start")
            .unwrap();
        assert_eq!(
            turn["params"]["input"][1],
            json!({"type":"localImage", "path":"/tmp/pasted.png"})
        );
    }

    #[test]
    fn oversized_codex_goal_preserves_every_requirement() {
        let dir = tempfile::tempdir().unwrap();
        let objective = "Évaluer toutes les exigences. ".repeat(300);
        let goal = codex_goal_objective(&objective, dir.path().to_str().unwrap()).unwrap();
        assert!(goal.len() <= 4000);
        let path = std::fs::read_dir(dir.path())
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert!(goal.contains(path.to_str().unwrap()));
        assert_eq!(std::fs::read_to_string(path).unwrap(), objective);
        assert_eq!(
            codex_goal_objective("Short objective", "/missing").unwrap(),
            "Short objective"
        );
    }

    #[test]
    fn codex_rpc_only_accepts_its_own_response() {
        let events = concat!(
            "{\"id\":\"other\",\"result\":{\"wrong\":true}}\n",
            "{\"id\":\"orb-thread/goal/get\",\"result\":{\"goal\":null}}\n"
        );
        let mut pending = Vec::new();
        let result = rpc_collect(
            &mut Vec::new(),
            &mut std::io::Cursor::new(events),
            "thread/goal/get",
            json!({}),
            &mut pending,
        )
        .unwrap();
        assert_eq!(result, json!({"goal":null}));
        assert_eq!(pending.len(), 1);
    }

    #[test]
    fn codex_non_retryable_error_still_fails() {
        let events = [
            json!({"id":"orb-initialize","result":{}}),
            json!({"id":"orb-thread/start","result":{"model":"test","thread":{"id":"root"}}}),
            json!({"id":"orb-thread/goal/set","result":{}}),
            json!({"method":"error","params":{"threadId":"root","willRetry":false,"error":{"message":"Retry limit reached"}}}),
        ];
        let input = events
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        let result = drive_codex(
            &mut Vec::new(),
            &mut std::io::Cursor::new(input),
            "/goal Work",
            &[],
            None,
            crate::cyber_access::Mode::Automatic,
            "/tmp",
            None,
            &Output::default(),
            &Mutex::new(None),
            &crate::interactions::begin("terminal-error-test"),
        );
        assert_eq!(result.unwrap_err(), "Retry limit reached");
    }

    #[test]
    fn codex_goal_uses_native_api_and_waits_across_turns() {
        let events = [
            json!({"id":"orb-initialize","result":{}}),
            json!({"id":"orb-thread/start","result":{"model":"test-model","thread":{"id":"root"}}}),
            json!({"id":"orb-thread/goal/set","result":{"goal":{"status":"active"}}}),
            json!({"method":"error","params":{"threadId":"root","willRetry":true,"error":{"message":"Reconnecting... 2/5"}}}),
            json!({"method":"turn/completed","params":{"threadId":"root","turn":{"status":"completed"}}}),
            json!({"id":"orb-thread/goal/get","result":{"goal":{"status":"active"}}}),
            json!({"method":"item/agentMessage/delta","params":{"threadId":"root","itemId":"a","delta":"Continued"}}),
            json!({"method":"turn/completed","params":{"threadId":"root","turn":{"status":"completed"}}}),
            json!({"id":"orb-thread/goal/get","result":{"goal":{"status":"complete"}}}),
        ];
        let input = events
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        let mut requests = Vec::new();
        let output = Output::default();
        drive_codex(
            &mut requests,
            &mut std::io::Cursor::new(input),
            "/goal Finish the work",
            &[],
            None,
            crate::cyber_access::Mode::Automatic,
            "/tmp",
            None,
            &output,
            &Mutex::new(None),
            &crate::interactions::begin("native-goal-test"),
        )
        .unwrap();
        let sent = String::from_utf8(requests).unwrap();
        assert!(sent.contains("thread/goal/set"));
        assert!(sent.contains("Finish the work"));
        assert!(!sent.contains("turn/start"));
        assert_eq!(output.snapshot(), "Continued");
    }

    #[test]
    fn plain_stream_does_not_wait_for_newlines_and_preserves_utf8() {
        struct Bytes<'a> {
            bytes: &'a [u8],
            output: &'a Output,
            index: usize,
        }
        impl Read for Bytes<'_> {
            fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
                if self.index == 1 {
                    assert_eq!(self.output.snapshot(), "A");
                }
                if self.index == self.bytes.len() {
                    return Ok(0);
                }
                buf[0] = self.bytes[self.index];
                self.index += 1;
                Ok(1)
            }
        }
        let output = Output::default();
        stream_plain(
            &mut Bytes {
                bytes: "Aé🙂".as_bytes(),
                output: &output,
                index: 0,
            },
            &output,
        );
        assert_eq!(output.snapshot(), "Aé🙂");
    }

    #[cfg(unix)]
    #[test]
    fn argument_prompt_harnesses_receive_eof_on_stdin() {
        let request = StartRequest {
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            id: "stdin-test".into(),
            harness: "opencode".into(),
            bin: "/bin/sh".into(),
            cwd: "/tmp".into(),
            prompt: "hello".into(),
            model: None,
            session_id: None,
            image_paths: vec![],
        };
        let output = Arc::new(Output::default());
        let mut child = spawn_piped(
            &request,
            vec!["-c".into(), "cat >/dev/null".into()],
            &output,
            &Arc::new(Mutex::new(None)),
            false,
            &Arc::new(Mutex::new(None)),
            &[],
        )
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("harness waited forever for stdin EOF");
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[cfg(unix)]
    #[test]
    fn ordinary_claude_turn_allows_tools_without_prompting() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("claude-fixture");
        std::fs::write(&bin, r#"#!/bin/sh
[ "$1" = --version ] && { echo 'claude 1.0.0'; exit 0; }
read -r init
read -r prompt
printf '%s\n' '{"type":"control_request","request_id":"permission-1","request":{"subtype":"can_use_tool","tool_name":"Read","input":{"file_path":"/outside/AGENTS.md"}}}'
read -r answer
printf '%s' "$answer" > answer.json
printf '%s\n' '{"type":"result"}'
"#).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
        let id = format!("claude-permission-{}", uuid_like());
        local_agents_start(StartRequest {
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            id: id.clone(),
            harness: "claudecode".into(),
            bin: bin.to_string_lossy().into_owned(),
            cwd: dir.path().to_string_lossy().into_owned(),
            prompt: "Read the repository instructions".into(),
            model: None,
            session_id: Some("existing-session".into()),
            image_paths: vec![],
        })
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !local_agents_poll(id.clone()).unwrap().done {
            assert!(crate::interactions::local_interaction(id.clone())
                .unwrap()
                .is_none());
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(10));
        }
        let answer: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.path().join("answer.json")).unwrap())
                .unwrap();
        assert_eq!(answer["response"]["response"]["behavior"], "allow");
        runs().lock().unwrap().remove(&id);
    }

    #[test]
    fn claude_background_snapshots_replace_edges_and_ignore_ambient_tasks() {
        let mut state = ClaudeBackground::default();
        state.consume(&json!({"type":"system","subtype":"task_started","task_id":"old"}));
        assert!(state.running());
        state.consume(&json!({"type":"system","subtype":"task_notification","task_id":"old"}));
        assert!(!state.running());
        state.consume(&json!({"type":"system","subtype":"task_started","task_id":"stale"}));
        state.consume(&json!({"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"watch","ambient":true}]}));
        assert!(!state.running());
        state.consume(&json!({"type":"system","subtype":"task_started","task_id":"stale"}));
        assert!(!state.running());
    }

    /// Shorter delays for the run of one test.
    pub(super) fn recheck_delays() -> &'static Mutex<HashMap<String, Vec<Duration>>> {
        static DELAYS: OnceLock<Mutex<HashMap<String, Vec<Duration>>>> = OnceLock::new();
        DELAYS.get_or_init(Default::default)
    }

    #[test]
    fn claude_background_asks_once_about_each_command_and_never_about_agents() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("tasks").join("loop.output");
        std::fs::create_dir_all(log.parent().unwrap()).unwrap();
        std::fs::write(&log, "one\n\ntwo\n").unwrap();
        let mut state = ClaudeBackground::default();
        state.consume(
            &json!({"type":"system","subtype":"background_tasks_changed","tasks":[
            {"task_id":"loop","task_type":"local_bash","description":"Wait for release builds"},
            {"task_id":"explore","task_type":"local_agent","description":"Explore importer"},
            {"task_id":"watch","task_type":"local_bash","ambient":true}]}),
        );
        state.note_output(&json!({"type":"user","message":{"content":[{"type":"tool_result","content":format!("Output is being written to: {}. You will be notified", log.display())}]}}));
        let question = state.unchecked().unwrap();
        assert!(
            question
                .contains("- Wait for release builds (shell command, id loop, running for 0 min)"),
            "{question}"
        );
        assert!(
            question.contains(&format!("output file: {}\n", log.display())),
            "{question}"
        );
        assert!(
            question.contains("last output:\n    one\n    two\n"),
            "{question}"
        );
        assert!(
            !question.contains("Explore importer") && !question.contains("watch"),
            "{question}"
        );
        assert!(state.unchecked().is_none());
        // The snapshot after its answer still lists the command: it keeps its age and file.
        state.consume(
            &json!({"type":"system","subtype":"background_tasks_changed","tasks":[
            {"task_id":"loop","task_type":"local_bash","description":"Wait for release builds"},
            {"task_id":"build","task_type":"local_bash","description":"Build"}]}),
        );
        assert_eq!(state.list()[0].output.as_deref(), Some(log.as_path()));
        let question = state.unchecked().unwrap();
        assert!(
            question.contains("id build") && !question.contains("id loop"),
            "{question}"
        );
        state.consume(
            &json!({"type":"system","subtype":"background_tasks_changed","tasks":[
            {"task_id":"explore","task_type":"local_agent","description":"Explore importer"}]}),
        );
        assert!(state.running() && state.unchecked().is_none());
    }

    #[test]
    fn claude_output_path_keeps_spaces_and_the_separators_of_the_system() {
        let unix = "Command running in background with ID: b1. Output is being written to: /private/tmp/My Runs/tasks/b1.output. You will be notified";
        assert_eq!(
            output_path(unix, "b1"),
            Some("/private/tmp/My Runs/tasks/b1.output")
        );
        assert_eq!(output_path(unix, "b2"), None);
        let windows = r"Output is being written to: C:\Users\Jane Doe\AppData\tasks\b1.output. You";
        assert_eq!(
            output_path(windows, "b1"),
            Some(r"C:\Users\Jane Doe\AppData\tasks\b1.output")
        );
    }

    #[cfg(unix)]
    #[test]
    fn claude_is_asked_about_a_command_it_left_running_then_again_after_the_delay() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("claude-fixture");
        std::fs::write(&bin, r#"#!/bin/sh
read -r init
read -r prompt
printf '%s\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"loop","task_type":"local_bash","description":"Wait for release builds"}]}'
printf '%s\n' '{"type":"assistant","message":{"id":"a","content":[{"type":"text","text":"Released."}]}}'
printf '%s\n' '{"type":"result"}'
read -r first || exit 21
printf '%s\n' "$first" > first.json
printf '%s\n' '{"type":"assistant","message":{"id":"b","content":[{"type":"text","text":"Still waiting."}]}}'
printf '%s\n' '{"type":"result"}'
printf '%s\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"build","task_type":"local_bash","description":"Build the installers"}]}'
read -r second || exit 22
printf '%s\n' "$second" > second.json
printf '%s\n' '{"type":"assistant","message":{"id":"c","content":[{"type":"text","text":"Stopped it."}]}}'
printf '%s\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[]}'
printf '%s\n' '{"type":"result"}'
"#).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
        let id = format!("claude-recheck-{}", uuid_like());
        recheck_delays()
            .lock()
            .unwrap()
            .insert(id.clone(), vec![Duration::from_millis(150)]);
        let started = Instant::now();
        local_agents_start(StartRequest {
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            id: id.clone(),
            harness: "claudecode".into(),
            bin: bin.to_string_lossy().into_owned(),
            cwd: dir.path().to_string_lossy().into_owned(),
            prompt: "Release".into(),
            model: None,
            session_id: None,
            image_paths: vec![],
        })
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut waited = false;
        loop {
            let state = local_agents_poll(id.clone()).unwrap();
            waited |= state.waiting_since.is_some();
            if state.done {
                assert!(state.text.contains("Stopped it."), "{}", state.text);
                break;
            }
            assert!(Instant::now() < deadline, "Claude did not finish");
            thread::sleep(Duration::from_millis(10));
        }
        assert!(waited);
        assert!(started.elapsed() >= Duration::from_millis(150));
        let read = |name: &str| -> Value {
            serde_json::from_str(&std::fs::read_to_string(dir.path().join(name)).unwrap()).unwrap()
        };
        let first = read("first.json")["message"]["content"]
            .as_str()
            .unwrap()
            .to_owned();
        assert!(first.contains("Your turn ended while these background commands still run:\n- Wait for release builds"), "{first}");
        let second = read("second.json")["message"]["content"]
            .as_str()
            .unwrap()
            .to_owned();
        assert!(
            second.contains("These background tasks still run:\n- Build the installers")
                && !second.contains("Wait for release builds"),
            "{second}"
        );
        recheck_delays().lock().unwrap().remove(&id);
        runs().lock().unwrap().remove(&id);
    }

    #[cfg(unix)]
    #[test]
    fn claude_background_result_keeps_question_and_plan_channel_open() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("claude-fixture");
        std::fs::write(&bin, r#"#!/bin/sh
read -r init
read -r prompt
printf '%s\n' '{"type":"system","subtype":"task_started","task_id":"a","description":"Explore"}'
printf '%s\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a"}]}'
printf '%s\n' '{"type":"result","result":"Waiting for agent"}'
sleep 0.05
printf '%s\n' '{"type":"system","subtype":"task_notification","task_id":"a","status":"completed"}'
printf '%s\n' '{"type":"system","subtype":"background_tasks_changed","tasks":[]}'
printf '%s\n' '{"type":"control_request","request_id":"q","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[]}}}'
read -r answer || exit 21
printf '%s\n' '{"type":"control_request","request_id":"p","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"The plan"}}}'
read -r answer || exit 22
printf '%s\n' '{"type":"result"}'
read -r mode || exit 23
read -r execute || exit 24
printf '%s\n' '{"type":"assistant","message":{"id":"final","content":[{"type":"text","text":"Implemented"}]}}'
printf '%s\n' '{"type":"result"}'
"#).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
        let id = format!("claude-background-{}", uuid_like());
        local_agents_start(StartRequest {
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            id: id.clone(),
            harness: "claudecode".into(),
            bin: bin.to_string_lossy().into_owned(),
            cwd: dir.path().to_string_lossy().into_owned(),
            prompt: "/plan Explore with background agents".into(),
            model: None,
            session_id: None,
            image_paths: vec![],
        })
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut methods = Vec::new();
        loop {
            if let Some(request) = crate::interactions::local_interaction(id.clone()).unwrap() {
                methods.push(request.method.clone());
                crate::interactions::local_interaction_answer(
                    id.clone(),
                    request.id,
                    if request.method == "plan" {
                        json!({"action":"accept"})
                    } else {
                        json!({"answers":{}})
                    },
                )
                .unwrap();
            }
            let state = local_agents_poll(id.clone()).unwrap();
            if state.done {
                assert!(state.text.contains("Implemented"), "{}", state.text);
                break;
            }
            assert!(Instant::now() < deadline, "Claude did not finish");
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(methods, vec!["claude_questions", "plan"]);
        runs().lock().unwrap().remove(&id);
    }

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

    #[test]
    fn errors_do_not_include_terminal_color_sequences() {
        assert_eq!(
            strip_terminal_codes("\u{1b}[91m\u{1b}[1mError: \u{1b}[0mFailed query"),
            "Error: Failed query"
        );
    }

    #[cfg(unix)]
    #[test]
    fn completed_local_run_can_be_replaced_by_a_followup() {
        let request = StartRequest {
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            image_paths: vec![],
            id: format!("followup-test-{}", uuid_like()),
            harness: "grok".into(),
            bin: "/usr/bin/true".into(),
            cwd: "/tmp".into(),
            prompt: "test".into(),
            model: None,
            session_id: None,
        };
        local_agents_start(request.clone()).unwrap();
        let initial_generation = native_generation(&request.id).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !local_agents_poll(request.id.clone()).unwrap().done {
            assert!(Instant::now() < deadline, "fixture did not complete");
            thread::sleep(Duration::from_millis(10));
        }
        local_agents_start(request.clone()).expect("a finished run must not block a new turn");
        assert!(
            poll_generation(&request.id, Some(&initial_generation)).is_err(),
            "initial-origin sync must not consume the follow-up's output"
        );
        local_agents_stop(request.id).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn stale_transfer_heartbeat_cannot_stop_a_new_native_generation() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("agent");
        std::fs::write(&bin, "#!/bin/sh\nsleep 10\n").unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
        let id = format!("generation-test-{}", uuid_like());
        local_agents_start(StartRequest {
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            id: id.clone(),
            harness: "grok".into(),
            bin: bin.to_string_lossy().into_owned(),
            cwd: dir.path().to_string_lossy().into_owned(),
            prompt: "test".into(),
            model: None,
            session_id: None,
            image_paths: vec![],
        })
        .unwrap();
        let generation = native_generation(&id).unwrap();
        assert!(poll_generation(&id, Some("old-generation")).is_err());
        assert!(poll_generation(&id, Some(&generation)).is_ok());
        stop_generation(&id, Some("old-generation")).unwrap();
        assert!(!local_agents_poll(id.clone()).unwrap().done);
        stop_generation(&id, Some(&generation)).unwrap();
        assert!(local_agents_poll(id.clone()).unwrap().done);
        runs().lock().unwrap().remove(&id);
    }

    #[cfg(unix)]
    #[test]
    fn stop_closes_output_held_by_codex_and_claude_launcher_children() {
        use std::os::unix::fs::PermissionsExt;
        for harness in ["codex", "claudecode"] {
            let dir = tempfile::tempdir().unwrap();
            let bin = dir.path().join("launcher");
            std::fs::write(&bin, "#!/bin/sh\n[ \"$1\" = --version ] && { echo launcher 1.0.0; exit 0; }\nsleep 30 &\necho $! > child.pid\nwait\n").unwrap();
            std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
            let id = format!("stop-launcher-{}", uuid_like());
            local_agents_start(StartRequest {
                effort: None,
                cyber_revision: None,
                cyber_access: None,
                id: id.clone(),
                harness: harness.into(),
                bin: bin.to_string_lossy().into_owned(),
                cwd: dir.path().to_string_lossy().into_owned(),
                prompt: "test".into(),
                model: None,
                session_id: None,
                image_paths: vec![],
            })
            .unwrap();
            let deadline = Instant::now() + Duration::from_secs(5);
            while !dir.path().join("child.pid").exists() {
                assert!(Instant::now() < deadline, "launcher did not start");
                thread::sleep(Duration::from_millis(10));
            }
            let run = runs().lock().unwrap().get(&id).unwrap().clone();
            let pid = run.child.lock().unwrap().id() as i32;
            let group = unsafe { libc::getpgid(pid) };
            // Clean up even when checking the pre-fix implementation.
            if group != pid {
                if let Ok(child) = std::fs::read_to_string(dir.path().join("child.pid")) {
                    if let Ok(child) = child.trim().parse::<i32>() {
                        unsafe {
                            libc::kill(child, libc::SIGKILL);
                        }
                    }
                }
            }
            let stopped = local_agents_stop(id.clone());
            assert_eq!(group, pid, "{harness} inherited Orb's process group");
            stopped.unwrap();
            assert!(
                run.text.drained(),
                "{harness} left a reader waiting for EOF"
            );
            assert!(local_agents_poll(id.clone()).unwrap().done);
            runs().lock().unwrap().remove(&id);
        }
    }

    #[cfg(unix)]
    #[test]
    fn resumed_claude_session_keeps_the_reply_after_its_empty_first_result() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let events = dir.path().join("events.jsonl");
        std::fs::write(&events, concat!(
            r#"{"type":"system","subtype":"task_notification","task_id":"stale","status":"stopped"}"#, "\n",
            r#"{"type":"control_response","response":{"subtype":"success","request_id":"orb-init"}}"#, "\n",
            r#"{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":""}"#, "\n",
            r#"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Resumed reply."}]}}"#, "\n",
            r#"{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"Resumed reply."}"#, "\n",
        )).unwrap();
        let bin = dir.path().join("claude");
        // The real CLI keeps working only while its input stays open.
        std::fs::write(&bin, format!("#!/bin/sh\n[ \"$1\" = --version ] && {{ echo 'claude 1.0.0'; exit 0; }}\nhead -3 '{0}'\nif read -r line && read -r line && sleep 0.3 && read -r -t 1 line; then :; fi\ntail -2 '{0}'\ncat >/dev/null\n", events.display())).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
        let id = format!("resumed-{}", uuid_like());
        local_agents_start(StartRequest {
            effort: None,
            cyber_revision: None,
            cyber_access: None,
            id: id.clone(),
            harness: "claudecode".into(),
            bin: bin.to_string_lossy().into_owned(),
            cwd: dir.path().to_string_lossy().into_owned(),
            prompt: "test".into(),
            model: None,
            session_id: Some("00000000-0000-0000-0000-000000000001".into()),
            image_paths: vec![],
        })
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let state = loop {
            let state = local_agents_poll(id.clone()).unwrap();
            if state.done || Instant::now() > deadline {
                break state;
            }
            thread::sleep(Duration::from_millis(20));
        };
        runs().lock().unwrap().remove(&id);
        assert!(state.done, "the run did not finish");
        assert_eq!(state.text, "Resumed reply.");
    }

    #[cfg(unix)]
    #[test]
    fn a_zero_turn_result_still_ends_a_fresh_or_started_turn() {
        use std::os::unix::fs::PermissionsExt;
        for (resume, events) in [
            (None, concat!(r#"{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":""}"#, "\n").to_string()),
            (Some("00000000-0000-0000-0000-000000000002"), concat!(
                r#"{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":""}"#, "\n",
                r#"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Reply."}]}}"#, "\n",
                r#"{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":""}"#, "\n",
            ).to_string()),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let file = dir.path().join("events.jsonl");
            std::fs::write(&file, events).unwrap();
            let bin = dir.path().join("claude");
            // Like the real CLI, it exits only once its input is closed.
            std::fs::write(&bin, format!("#!/bin/sh\n[ \"$1\" = --version ] && {{ echo 'claude 1.0.0'; exit 0; }}\ncat '{}'\ncat >/dev/null\n", file.display())).unwrap();
            std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
            let id = format!("zero-turn-{}", uuid_like());
            local_agents_start(StartRequest { effort: None, cyber_revision: None, cyber_access: None,
                id: id.clone(),
                harness: "claudecode".into(),
                bin: bin.to_string_lossy().into_owned(),
                cwd: dir.path().to_string_lossy().into_owned(),
                prompt: "test".into(),
                model: None,
                session_id: resume.map(Into::into),
                image_paths: vec![],
            })
            .unwrap();
            let deadline = Instant::now() + Duration::from_secs(10);
            while !local_agents_poll(id.clone()).unwrap().done {
                assert!(Instant::now() < deadline, "the run never ended (resume={resume:?})");
                thread::sleep(Duration::from_millis(20));
            }
            let _ = local_agents_stop(id.clone());
            runs().lock().unwrap().remove(&id);
        }
    }

    #[test]
    fn extract_text_reads_claude_deltas() {
        let line = r#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hi"}}}"#;
        assert_eq!(extract_text(line).as_deref(), Some("Hi"));
    }
}

/// Only live harnesses launched by this Orb instance (not unrelated terminals).
pub fn active_pids() -> Vec<u32> {
    let Ok(all) = runs().lock() else {
        return Vec::new();
    };
    all.values()
        .filter(|r| !r.done.load(Ordering::SeqCst))
        .filter_map(|r| r.child.try_lock().ok().map(|c| c.id()))
        .collect()
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
        local_agents_start(StartRequest { effort: None, cyber_revision: None, cyber_access: None,id:id.clone(),harness,bin:std::env::var("ORB_PLAN_BIN").unwrap(),cwd:cwd.to_string_lossy().into(),model:None,session_id:None,image_paths:vec![],prompt:"/plan Plan creating hello.txt containing hello. First ask me one question using your native question tool: should it say hello or bonjour? Then present a short plan for approval. Do not delegate. After approval implement it.".into()}).unwrap();
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

pub fn workspace_busy(root: &std::path::Path) -> Result<bool, String> {
    let root = root.canonicalize().map_err(|e| e.to_string())?;
    Ok(runs()
        .lock()
        .map_err(|e| e.to_string())?
        .values()
        .any(|run| {
            !run.done.load(Ordering::SeqCst) && run.cwd.canonicalize().ok().as_ref() == Some(&root)
        }))
}

pub fn native_generation(id: &str) -> Option<String> {
    runs()
        .lock()
        .ok()?
        .get(id)
        .map(|run| run.generation.clone())
}

pub fn clear_subscriptions() {
    if let Ok(runs) = runs().lock() {
        for run in runs.values() {
            run.text.clear_subscriptions();
        }
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
                ..request
            },
            &[],
        );
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
