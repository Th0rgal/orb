//! Ask assistant — a fast, read-mostly sidecar co-pilot that rides alongside a
//! running mission. It can read the mission history and run bash in the live
//! workspace, answering operator questions **without** touching the working
//! agent's turn loop, queue, or harness lock.
//!
//! This module hosts:
//! - the persistent [`store`] (separate `ask.db`, never merged into mission
//!   history),
//! - the OpenAI-compatible tool-calling [`client`],
//! - the in-process agentic [`run_ask_turn`] loop, and
//! - the global [`ask_store`] accessor.
//!
//! See `docs/archive/ASK_ASSISTANT_DESIGN.md` for the full design.

pub mod btw;
pub mod client;
pub mod http;
pub mod inbox;
pub mod store;

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::Serialize;
use serde_json::{json, Value};
use tokio::sync::mpsc::Sender;
use tokio::sync::OnceCell;
use uuid::Uuid;

use crate::api::mission_store::MissionStore;
use crate::api::proxy_keys::SharedProxyApiKeyStore;
use crate::api::runners::{effective_mid_turn_kind, MidTurnKind};
use crate::workspace::{use_nspawn_for_workspace, SharedWorkspaceStore, WorkspaceType};
use crate::workspace_exec::WorkspaceExec;

pub use client::AskClient;
pub use store::{AskMessage, AskStore, AskThread, OperatorNote};

/// Hard cap on tool-calling iterations per turn — keeps cost/latency bounded.
/// When the cap is hit mid-investigation, a final tools-disabled pass still
/// forces a synthesized answer (see the loops below), so this bounds *tool*
/// rounds rather than guaranteeing a dead end.
const MAX_ITERATIONS: usize = 10;
/// Max bytes of any single tool result fed back to the model.
const MAX_TOOL_RESULT_BYTES: usize = 8_000;
/// Number of recent mission events seeded into the system prompt.
const SEED_EVENT_COUNT: usize = 40;
/// How far back to scan when looking for the latest goal_status event. One
/// fetch serves both this scan and the [`SEED_EVENT_COUNT`] seed.
const GOAL_SCAN_EVENT_COUNT: usize = 200;

/// Nudge appended before the forced, tools-disabled synthesis pass. MiniMax-M3
/// tends to free-style another tool call here (emitting raw `<invoke>`/`<tool_call>`
/// markup wrapped in its interleave sentinels); this pushes it to answer in prose
/// instead. `finalize_answer` strips any markup that leaks through regardless.
const FINAL_SYNTHESIS_NUDGE: &str = "You have no tools available for this reply. Do NOT emit any tool call, function call, or XML markup such as <invoke> or <tool_call>. Answer the operator directly in prose, using only what you already gathered from the tool results above.";

/// Shown when the turn produced no usable prose (tool-call limit hit, or the
/// model emitted only tool-call markup that was stripped away).
const TOOL_LIMIT_FALLBACK: &str =
    "(The assistant reached the tool-call limit without a final answer.)";

/// Clean a final answer before it is shown/persisted: strip reasoning blocks
/// (`<think>`/`<mm:think>`) like the mission path does, then strip any tool-call
/// markup the model leaked into prose. The text tool-call parser only runs when
/// tools are offered, so the tools-disabled synthesis pass can otherwise leak
/// raw `]<]minimax[>[<invoke …>` markup verbatim into the chat (observed in prod
/// on mission cd6cfe3f). Falls back to a canned notice when nothing but markup
/// remains.
fn finalize_answer(raw: &str) -> String {
    let stripped = crate::api::mission_runner::strip_think_tags(raw);
    let cleaned = client::strip_leaked_tool_markup(&stripped);
    if cleaned.is_empty() {
        TOOL_LIMIT_FALLBACK.to_string()
    } else {
        cleaned
    }
}

static ASK_STORE: OnceCell<Arc<AskStore>> = OnceCell::const_new();
static ASK_WORKING_DIR: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
static SANDBOX_GC: OnceCell<()> = OnceCell::const_new();
static LIVE_SANDBOXES: std::sync::OnceLock<std::sync::Mutex<HashMap<PathBuf, SandboxLockGuard>>> =
    std::sync::OnceLock::new();

struct SandboxLockGuard {
    lock_path: PathBuf,
    file: std::fs::File,
}

impl Drop for SandboxLockGuard {
    fn drop(&mut self) {
        if !self.lock_path.as_os_str().is_empty() {
            let _ = std::fs::remove_file(&self.lock_path);
        }
        let _ = fs2::FileExt::unlock(&self.file);
    }
}

fn live_sandboxes() -> &'static std::sync::Mutex<HashMap<PathBuf, SandboxLockGuard>> {
    LIVE_SANDBOXES.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

fn sandbox_lock_path(sandbox: &Path) -> PathBuf {
    let mut os = sandbox.as_os_str().to_os_string();
    os.push(".lock");
    PathBuf::from(os)
}

fn acquire_sandbox_lock(sandbox: &Path) -> std::io::Result<SandboxLockGuard> {
    if let Some(parent) = sandbox.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let lock_path = sandbox_lock_path(sandbox);
    let mut options = std::fs::OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
        options.mode(0o666);
        let file = options.open(&lock_path)?;
        let _ = file.set_permissions(std::fs::Permissions::from_mode(0o666));
        fs2::FileExt::try_lock_exclusive(&file)?;
        if !same_file_inode(&file, &lock_path) {
            return Err(std::io::Error::other("Ask sandbox lock was replaced"));
        }
        Ok(SandboxLockGuard { lock_path, file })
    }
    #[cfg(not(unix))]
    {
        let file = options.open(&lock_path)?;
        fs2::FileExt::try_lock_exclusive(&file)?;
        Ok(SandboxLockGuard { lock_path, file })
    }
}

fn register_live_sandbox(sandbox: &Path) -> std::io::Result<()> {
    let guard = acquire_sandbox_lock(sandbox)?;
    live_sandboxes()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(sandbox.to_path_buf(), guard);
    Ok(())
}

enum SandboxCleanupTarget {
    Local {
        exec: Box<WorkspaceExec>,
        base_work_dir: PathBuf,
    },
    Remote(RemoteAskTarget),
}

pub struct SandboxCleanupGuard {
    path: PathBuf,
    target: Option<SandboxCleanupTarget>,
    heartbeat: Option<tokio::task::JoinHandle<()>>,
}

impl SandboxCleanupGuard {
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub async fn cleanup(mut self) {
        if let Some(task) = self.start_cleanup() {
            let _ = task.await;
        }
    }

    fn start_cleanup(&mut self) -> Option<tokio::task::JoinHandle<()>> {
        let target = self.target.take()?;
        if let Some(heartbeat) = self.heartbeat.take() {
            heartbeat.abort();
        }
        let path = self.path.clone();
        let release = matches!(target, SandboxCleanupTarget::Local { .. })
            .then(|| SandboxReleaseGuard(path.clone()));
        match tokio::runtime::Handle::try_current() {
            Ok(runtime) => Some(runtime.spawn(async move {
                let _release = release;
                let cleanup = async {
                    match target {
                        SandboxCleanupTarget::Local {
                            exec,
                            base_work_dir,
                        } => {
                            cleanup_sandbox(&exec, &base_work_dir, &path).await;
                        }
                        SandboxCleanupTarget::Remote(target) => {
                            cleanup_remote_sandbox(&target, &path.to_string_lossy()).await;
                        }
                    }
                };
                let _ = tokio::time::timeout(std::time::Duration::from_secs(120), cleanup).await;
            })),
            Err(_) => {
                let _ = std::thread::Builder::new()
                    .name("ask-sandbox-cleanup".into())
                    .spawn(move || {
                        let _release = release;
                        if let Ok(rt) = tokio::runtime::Builder::new_current_thread()
                            .enable_all()
                            .build()
                        {
                            rt.block_on(async {
                                let cleanup = async {
                                    match target {
                                        SandboxCleanupTarget::Local {
                                            exec,
                                            base_work_dir,
                                        } => {
                                            cleanup_sandbox(&exec, &base_work_dir, &path).await;
                                        }
                                        SandboxCleanupTarget::Remote(target) => {
                                            cleanup_remote_sandbox(
                                                &target,
                                                &path.to_string_lossy(),
                                            )
                                            .await;
                                        }
                                    }
                                };
                                let _ = tokio::time::timeout(
                                    std::time::Duration::from_secs(120),
                                    cleanup,
                                )
                                .await;
                            });
                        }
                    });
                None
            }
        }
    }
}

impl Drop for SandboxCleanupGuard {
    fn drop(&mut self) {
        self.start_cleanup();
    }
}

struct SandboxReleaseGuard(PathBuf);

impl Drop for SandboxReleaseGuard {
    fn drop(&mut self) {
        release_live_sandbox(&self.0);
    }
}

fn release_live_sandbox(sandbox: &Path) {
    let guard = live_sandboxes()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(sandbox);
    drop(guard);
}

#[cfg(unix)]
fn same_file_inode(file: &std::fs::File, path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (file.metadata(), std::fs::symlink_metadata(path)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
        _ => false,
    }
}

#[cfg(not(unix))]
fn same_file_inode(_file: &std::fs::File, path: &Path) -> bool {
    path.exists()
}

const REMOTE_SANDBOX_LEASE_SECS: u64 = 300;

fn remote_sandbox_lease_is_live(file: &std::fs::File) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::FileExt;
        let mut marker = [0; 32];
        let marker_ok = match file.read_at(&mut marker, 0) {
            Ok(len) => marker[..len].trim_ascii() == b"ask-remote-lease",
            Err(_) => return true,
        };
        if !marker_ok {
            return false;
        }
        let mtime = match file.metadata().and_then(|m| m.modified()) {
            Ok(mtime) => mtime,
            Err(_) => return true,
        };
        match mtime.elapsed() {
            Ok(age) => age <= std::time::Duration::from_secs(REMOTE_SANDBOX_LEASE_SECS),
            Err(_) => false,
        }
    }
    #[cfg(not(unix))]
    {
        let _ = file;
        true
    }
}

fn try_lock_stale_sandbox_for_gc(lock_path: &Path) -> Option<SandboxLockGuard> {
    let mut options = std::fs::OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
        options.mode(0o666);
        let file = match options.open(lock_path) {
            Ok(f) => f,
            Err(err) => {
                tracing::warn!(
                    lock_path = %lock_path.display(),
                    %err,
                    "Skipping Ask sandbox GC candidate: failed to open lock file"
                );
                return None;
            }
        };
        let _ = file.set_permissions(std::fs::Permissions::from_mode(0o666));
        if fs2::FileExt::try_lock_exclusive(&file).is_err() {
            return None;
        }
        if !same_file_inode(&file, lock_path) || remote_sandbox_lease_is_live(&file) {
            let _ = fs2::FileExt::unlock(&file);
            return None;
        }
        Some(SandboxLockGuard {
            lock_path: lock_path.to_path_buf(),
            file,
        })
    }
    #[cfg(not(unix))]
    {
        let file = options.open(lock_path).ok()?;
        if fs2::FileExt::try_lock_exclusive(&file).is_err() || remote_sandbox_lease_is_live(&file) {
            let _ = fs2::FileExt::unlock(&file);
            return None;
        }
        Some(SandboxLockGuard {
            lock_path: lock_path.to_path_buf(),
            file,
        })
    }
}

fn gc_stale_sandboxes_sync(root: &Path) {
    let live: HashSet<PathBuf> = live_sandboxes()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .keys()
        .cloned()
        .collect();
    gc_stale_sandboxes_with_observer(root, &live, |_| {});
}

fn gc_stale_sandboxes_with_observer<F>(root: &Path, live: &HashSet<PathBuf>, mut before_inspect: F)
where
    F: FnMut(&Path),
{
    let entries = match std::fs::read_dir(root) {
        Ok(entries) => entries,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return,
        Err(err) => {
            tracing::warn!(root = %root.display(), %err, "Failed to read sandbox root during Ask GC");
            return;
        }
    };
    let mut lock_candidates = Vec::new();
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(err) => {
                tracing::warn!(root = %root.display(), %err, "Skipping unreadable entry during Ask sandbox GC");
                continue;
            }
        };
        let path = entry.path();
        before_inspect(&path);
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if !name_str.starts_with("ask-sandbox-") {
            continue;
        }
        if name_str.ends_with(".lock") {
            lock_candidates.push(path);
            continue;
        }
        if live.contains(&path) {
            continue;
        }
        let file_type = match entry.file_type() {
            Ok(ft) => ft,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
            Err(err) => {
                tracing::warn!(path = %path.display(), %err, "Failed to inspect entry during Ask sandbox GC");
                continue;
            }
        };
        if !file_type.is_dir() {
            continue;
        }
        let lock_path = sandbox_lock_path(&path);
        let Some(mut lock_guard) = try_lock_stale_sandbox_for_gc(&lock_path) else {
            continue;
        };
        if live_sandboxes()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains_key(&path)
        {
            continue;
        }
        if let Err(err) = std::fs::remove_dir_all(&path) {
            if err.kind() != std::io::ErrorKind::NotFound {
                tracing::warn!(path = %path.display(), %err, "Failed to GC stale Ask sandbox");
                lock_guard.lock_path.clear();
            }
        }
    }

    for lock_path in lock_candidates {
        let Some(stem) = lock_path
            .file_name()
            .and_then(|n| n.to_str())
            .and_then(|s| s.strip_suffix(".lock"))
        else {
            continue;
        };
        let sandbox_path = root.join(stem);
        if live.contains(&sandbox_path) || sandbox_path.exists() {
            continue;
        }
        let Some(mut lock_guard) = try_lock_stale_sandbox_for_gc(&lock_path) else {
            continue;
        };
        if sandbox_path.exists() {
            lock_guard.lock_path.clear();
            continue;
        }
    }
}

async fn gc_stale_sandboxes(root: &Path) {
    let root = root.to_path_buf();
    if let Err(err) = tokio::task::spawn_blocking(move || gc_stale_sandboxes_sync(&root)).await {
        tracing::warn!(%err, "Ask sandbox GC task panicked");
    }
}

async fn initialize_sandbox_gc() {
    SANDBOX_GC
        .get_or_init(|| gc_stale_sandboxes(Path::new("/tmp")))
        .await;
}

async fn initialize_ask_store(
    cell: &OnceCell<Arc<AskStore>>,
    working_dir: &Path,
) -> Result<Arc<AskStore>, String> {
    ask_store_in_cell(cell, working_dir, Some(Path::new("/tmp"))).await
}

pub(crate) async fn ask_store_in_cell(
    cell: &OnceCell<Arc<AskStore>>,
    working_dir: &Path,
    sandbox_root: Option<&Path>,
) -> Result<Arc<AskStore>, String> {
    cell.get_or_try_init(|| async {
        match sandbox_root {
            Some(root) if root == Path::new("/tmp") => initialize_sandbox_gc().await,
            Some(root) => gc_stale_sandboxes(root).await,
            None => {}
        }
        let base = working_dir.join(".sandboxed-sh/missions");
        tokio::fs::create_dir_all(&base)
            .await
            .map_err(|e| e.to_string())?;
        AskStore::open(base.join("ask.db")).await.map(Arc::new)
    })
    .await
    .map(Arc::clone)
}

/// Get (lazily initializing) the global Ask store, placed next to the mission
/// databases under the working directory.
pub async fn ask_store(config: &crate::config::Config) -> Result<Arc<AskStore>, String> {
    let _ = ASK_WORKING_DIR.set(config.working_dir.clone());
    initialize_ask_store(&ASK_STORE, &config.working_dir).await
}

pub(crate) async fn initialize_on_startup(config: &crate::config::Config) {
    let _ = ASK_WORKING_DIR.set(config.working_dir.clone());
    if let Err(err) = ask_store(config).await {
        tracing::warn!(%err, "Failed to eagerly initialize Ask store on startup; will retry lazily");
    }
}

pub async fn ask_store_for_midturn() -> Result<Arc<AskStore>, String> {
    ask_store_for_midturn_in(&ASK_STORE, ASK_WORKING_DIR.get().map(PathBuf::as_path)).await
}

async fn ask_store_for_midturn_in(
    cell: &OnceCell<Arc<AskStore>>,
    configured_working_dir: Option<&Path>,
) -> Result<Arc<AskStore>, String> {
    if let Some(store) = cell.get() {
        return Ok(Arc::clone(store));
    }
    if let Some(working_dir) = configured_working_dir {
        return initialize_ask_store(cell, working_dir).await;
    }
    let config = crate::config::Config::from_env().map_err(|err| err.to_string())?;
    initialize_ask_store(cell, &config.working_dir).await
}

pub fn ask_store_if_initialized() -> Option<Arc<AskStore>> {
    ASK_STORE.get().cloned()
}

/// Remote `orb-node` (`sandboxed-node`) placement for an Ask turn whose
/// mission workspace lives on a remote/managed VM instead of Core's local host
/// filesystem.
#[derive(Clone)]
pub struct RemoteAskTarget {
    pub node: crate::remote_node::RemoteNodeConfig,
    pub secret: String,
    pub workspace_mission_id: Uuid,
    /// Optional explicit directory override (e.g. a transferred workspace root
    /// or an isolated `/tmp/ask-sandbox-<uuid>` worktree on the remote node).
    pub cwd_override: Option<String>,
    /// Display path shown in the Ask system prompt.
    pub display_cwd: String,
    /// Whether the remote placement had a live job handle when Ask started.
    pub live: bool,
}

/// Everything the Ask loop needs for one turn.
pub struct AskTurn {
    pub ask_store: Arc<AskStore>,
    pub mission_store: Arc<dyn MissionStore>,
    pub workspace_exec: WorkspaceExec,
    pub work_dir: PathBuf,
    pub remote_target: Option<RemoteAskTarget>,
    pub llm: AskClient,
    pub mission_id: Uuid,
    pub thread_id: Uuid,
    /// When true, `work_dir` is an isolated sandbox copy of the workspace, so
    /// writes are throwaway and we skip the operator-note bridge entirely.
    pub sandbox: bool,
    /// Workspace store + the mission's workspace id, for the workspace-env
    /// tools (list/set env vars that get injected into the harness).
    pub workspaces: SharedWorkspaceStore,
    pub workspace_id: Uuid,
    /// Proxy API key store, for answering "is the key the operator issued
    /// actually being used?" with `last_used_at` facts.
    pub proxy_keys: SharedProxyApiKeyStore,
    /// Command channel into the user's control session, for the steering tools
    /// (`stop_agent` / `send_to_agent`). Same channel the dashboard's Stop
    /// button and composer use.
    pub control_cmd_tx: tokio::sync::mpsc::Sender<crate::api::control::ControlCommand>,
    /// Event broadcast for the control session. Events sent here reach live
    /// viewers AND the persistent event logger — used to leave a durable audit
    /// record when the Copilot stops the working agent.
    pub events_tx: tokio::sync::broadcast::Sender<crate::api::control::AgentEvent>,
}

/// Run one Ask turn: persist the operator message, drive the tool loop, persist
/// the assistant answer, and return the final text.
pub async fn run_ask_turn(turn: &AskTurn, user_content: &str) -> Result<String, String> {
    // Persist the operator's message first.
    turn.ask_store
        .append_message(turn.thread_id, "user", user_content, None, None, None)
        .await?;

    // Assemble the OpenAI message array: system + prior turns + this message.
    // Replay prior user/assistant turns for continuity (tool details are kept in
    // the store for the UI but not replayed to the model — the final answers
    // carry what matters). `prior` already includes the message just appended.
    let (system, prior) = tokio::join!(
        build_system_prompt(turn, user_content),
        turn.ask_store.list_messages(turn.thread_id),
    );
    let prior = prior?;
    let mut messages: Vec<Value> = vec![json!({ "role": "system", "content": system })];
    for m in &prior {
        match m.role.as_str() {
            "user" => messages.push(json!({ "role": "user", "content": m.content })),
            "assistant" => messages.push(json!({ "role": "assistant", "content": m.content })),
            _ => {}
        }
    }

    let tools = tool_definitions();
    let mut final_answer = String::new();
    let mut total_tokens: u64 = 0;

    for _ in 0..MAX_ITERATIONS {
        let completion = turn.llm.complete(&messages, &tools).await?;
        total_tokens += completion.total_tokens.unwrap_or(0);

        if completion.tool_calls.is_empty() {
            final_answer = completion.content.unwrap_or_default();
            break;
        }

        // Reflect the assistant's tool-calling turn into the live context.
        let assistant_tool_calls: Vec<Value> = completion
            .tool_calls
            .iter()
            .map(|tc| {
                json!({
                    "id": tc.id,
                    "type": "function",
                    "function": { "name": tc.name, "arguments": tc.arguments },
                })
            })
            .collect();
        messages.push(json!({
            "role": "assistant",
            "content": completion.content.clone().unwrap_or_default(),
            "tool_calls": assistant_tool_calls,
        }));

        for tc in &completion.tool_calls {
            turn.ask_store
                .append_message(
                    turn.thread_id,
                    "tool_call",
                    &tc.arguments,
                    Some(tc.name.clone()),
                    Some(tc.id.clone()),
                    None,
                )
                .await?;

            let result = execute_tool(turn, &tc.name, &tc.arguments).await;
            let result = truncate_tool_result(&result);

            turn.ask_store
                .append_message(
                    turn.thread_id,
                    "tool_result",
                    &result,
                    Some(tc.name.clone()),
                    Some(tc.id.clone()),
                    None,
                )
                .await?;

            messages.push(json!({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": result,
            }));
        }
    }

    if final_answer.is_empty() {
        // The loop ended on a tool-calling turn — the model never volunteered a
        // final answer. Give it one more pass with tools disabled so it must
        // synthesize from the results it already gathered, rather than bailing
        // with a canned "tool-call limit" message.
        messages.push(json!({ "role": "user", "content": FINAL_SYNTHESIS_NUDGE }));
        match turn.llm.complete(&messages, &[]).await {
            Ok(c) => {
                total_tokens += c.total_tokens.unwrap_or(0);
                final_answer = c.content.unwrap_or_default();
            }
            Err(e) => tracing::warn!("[Ask] forced final-answer pass failed: {e}"),
        }
    }

    final_answer = finalize_answer(&final_answer);

    turn.ask_store
        .append_message(
            turn.thread_id,
            "assistant",
            &final_answer,
            None,
            None,
            Some(json!({ "model": turn.llm.model(), "total_tokens": total_tokens })),
        )
        .await?;

    Ok(final_answer)
}

/// An incremental event from the streaming Ask loop, serialized into SSE.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AskStreamEvent {
    /// A fragment of the assistant's visible answer.
    Delta { content: String },
    /// The assistant invoked a tool.
    ToolCall {
        tool_call_id: String,
        name: String,
        args: String,
    },
    /// A tool returned a result.
    ToolResult {
        tool_call_id: String,
        name: String,
        result: String,
    },
    /// Terminal: the turn finished. Carries the thread id (new threads) and the
    /// final answer so the client can reconcile.
    Done { thread_id: Uuid, answer: String },
    /// Terminal error.
    Error { message: String },
}

/// Streaming variant of [`run_ask_turn`]: drives the same agentic loop but emits
/// [`AskStreamEvent`]s on `tx` as tokens, tool calls, and results arrive.
/// Returns `true` if the turn completed successfully (a `done` event was sent),
/// `false` if it failed (an `error` event was sent instead).
pub async fn run_ask_turn_streaming(
    turn: &AskTurn,
    user_content: &str,
    tx: Sender<AskStreamEvent>,
) -> bool {
    match run_ask_turn_streaming_inner(turn, user_content, &tx).await {
        Ok(()) => true,
        Err(e) => {
            let _ = tx.send(AskStreamEvent::Error { message: e }).await;
            false
        }
    }
}

async fn run_ask_turn_streaming_inner(
    turn: &AskTurn,
    user_content: &str,
    tx: &Sender<AskStreamEvent>,
) -> Result<(), String> {
    turn.ask_store
        .append_message(turn.thread_id, "user", user_content, None, None, None)
        .await?;

    let (system, prior) = tokio::join!(
        build_system_prompt(turn, user_content),
        turn.ask_store.list_messages(turn.thread_id),
    );
    let prior = prior?;
    let mut messages: Vec<Value> = vec![json!({ "role": "system", "content": system })];
    for m in &prior {
        match m.role.as_str() {
            "user" => messages.push(json!({ "role": "user", "content": m.content })),
            "assistant" => messages.push(json!({ "role": "assistant", "content": m.content })),
            _ => {}
        }
    }

    let tools = tool_definitions();
    let mut final_answer = String::new();
    let mut total_tokens: u64 = 0;

    for _ in 0..MAX_ITERATIONS {
        let txc = tx.clone();
        let completion = turn
            .llm
            .complete_stream(&messages, &tools, |frag| {
                let _ = txc.try_send(AskStreamEvent::Delta {
                    content: frag.to_string(),
                });
            })
            .await?;
        total_tokens += completion.total_tokens.unwrap_or(0);

        if completion.tool_calls.is_empty() {
            final_answer = completion.content.unwrap_or_default();
            break;
        }

        let assistant_tool_calls: Vec<Value> = completion
            .tool_calls
            .iter()
            .map(|tc| {
                json!({
                    "id": tc.id,
                    "type": "function",
                    "function": { "name": tc.name, "arguments": tc.arguments },
                })
            })
            .collect();
        messages.push(json!({
            "role": "assistant",
            "content": completion.content.clone().unwrap_or_default(),
            "tool_calls": assistant_tool_calls,
        }));

        for tc in &completion.tool_calls {
            let _ = tx
                .send(AskStreamEvent::ToolCall {
                    tool_call_id: tc.id.clone(),
                    name: tc.name.clone(),
                    args: tc.arguments.clone(),
                })
                .await;
            turn.ask_store
                .append_message(
                    turn.thread_id,
                    "tool_call",
                    &tc.arguments,
                    Some(tc.name.clone()),
                    Some(tc.id.clone()),
                    None,
                )
                .await?;

            let result = execute_tool(turn, &tc.name, &tc.arguments).await;
            let result = truncate_tool_result(&result);
            let _ = tx
                .send(AskStreamEvent::ToolResult {
                    tool_call_id: tc.id.clone(),
                    name: tc.name.clone(),
                    result: result.clone(),
                })
                .await;
            turn.ask_store
                .append_message(
                    turn.thread_id,
                    "tool_result",
                    &result,
                    Some(tc.name.clone()),
                    Some(tc.id.clone()),
                    None,
                )
                .await?;
            messages.push(json!({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": result,
            }));
        }
    }

    let mut synthesized = false;
    if final_answer.is_empty() {
        // Same forced synthesis as the non-streaming path: one more pass with
        // tools disabled. Unlike the in-loop turns, this pass is NOT streamed
        // live — a tools-disabled MiniMax pass may free-style raw tool-call
        // markup, which would flash into the UI before the post-stream
        // reconcile. We collect it, clean it, and emit the result as one delta.
        messages.push(json!({ "role": "user", "content": FINAL_SYNTHESIS_NUDGE }));
        synthesized = true;
        match turn.llm.complete_stream(&messages, &[], |_| {}).await {
            Ok(c) => {
                total_tokens += c.total_tokens.unwrap_or(0);
                final_answer = c.content.unwrap_or_default();
            }
            Err(e) => tracing::warn!("[Ask] forced final-answer pass (stream) failed: {e}"),
        }
    }

    final_answer = finalize_answer(&final_answer);

    // The synthesis pass was suppressed above; surface its cleaned text so the
    // operator sees an answer before `onDone` reconciles against the store.
    if synthesized {
        let _ = tx
            .send(AskStreamEvent::Delta {
                content: final_answer.clone(),
            })
            .await;
    }

    turn.ask_store
        .append_message(
            turn.thread_id,
            "assistant",
            &final_answer,
            None,
            None,
            Some(json!({ "model": turn.llm.model(), "total_tokens": total_tokens })),
        )
        .await?;

    let _ = tx
        .send(AskStreamEvent::Done {
            thread_id: turn.thread_id,
            answer: final_answer,
        })
        .await;
    Ok(())
}

async fn build_system_prompt(turn: &AskTurn, user_content: &str) -> String {
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut seed = String::new();
    let (mission_res, events_res) = tokio::join!(
        turn.mission_store.get_mission(turn.mission_id),
        turn.mission_store
            .get_latest_events(turn.mission_id, GOAL_SCAN_EVENT_COUNT),
    );
    if let Ok(Some(mission)) = mission_res {
        if let Some(title) = &mission.title {
            seed.push_str(&format!("Mission title: {title}\n"));
        }
        seed.push_str(&format!(
            "Mission status: {:?} (last updated {})\n",
            mission.status, mission.updated_at
        ));
        if let Some(desc) = &mission.short_description {
            seed.push_str(&format!("Mission summary: {desc}\n"));
        }
        seed.push_str(&format!("Mission backend: {}\n", mission.backend));
    }

    // One slightly deeper fetch serves both the goal-status scan and the seed.
    if let Ok(events) = events_res {
        if let Some(goal) = events
            .iter()
            .rev()
            .find(|ev| ev.event_type == "goal_status")
        {
            seed.push_str(&format!(
                "\nLatest goal status [{} {}]: {}\n",
                goal.sequence,
                goal.timestamp,
                truncate(&goal.content, 600)
            ));
        }
        // Latest plan snapshot (Claude Code TodoWrite / Codex update_plan /
        // OpenCode todowrite): the working agent's own task board is the
        // single best "where are we" signal — surface the newest one.
        if let Some(plan) = events.iter().rev().find(|ev| {
            ev.event_type == "tool_call"
                && matches!(
                    ev.tool_name.as_deref(),
                    Some("TodoWrite") | Some("update_plan") | Some("todowrite")
                )
        }) {
            seed.push_str(&format!(
                "\nWorking agent's latest task board [{} {}]:\n{}\n",
                plan.sequence,
                plan.timestamp,
                truncate(&plan.content, 1500)
            ));
        }
        if let Some(iter_ev) = events
            .iter()
            .rev()
            .find(|ev| ev.event_type == "goal_iteration")
        {
            seed.push_str(&format!(
                "\nLatest loop/wakeup marker [{} {}]: {}\n",
                iter_ev.sequence,
                iter_ev.timestamp,
                truncate(&iter_ev.content, 400)
            ));
        }
        let start = events.len().saturating_sub(SEED_EVENT_COUNT);
        seed.push_str("\nRecent mission events (newest last):\n");
        for ev in &events[start..] {
            let tool = ev
                .tool_name
                .as_deref()
                .map(|t| format!(" {t}"))
                .unwrap_or_default();
            seed.push_str(&format!(
                "[{} {}] {}{}: {}\n",
                ev.sequence,
                ev.timestamp,
                ev.event_type,
                tool,
                truncate(&ev.content, 300)
            ));
        }
    }

    // Worker fleet: for orchestrator missions, list child missions so the
    // co-pilot can answer "what is running right now" without grepping.
    if let Ok(children) = turn.mission_store.get_child_missions(turn.mission_id).await {
        if !children.is_empty() {
            seed.push_str("\nWorker missions (children):\n");
            for c in children.iter().rev().take(12) {
                seed.push_str(&format!(
                    "- {} [{} {}] {:?} {}\n",
                    c.id,
                    c.backend,
                    c.model_override.as_deref().unwrap_or("-"),
                    c.status,
                    truncate(c.title.as_deref().unwrap_or("untitled"), 80)
                ));
            }
        }
    }
    // Pending wakeups: when the next scheduled turn fires and why.
    if let Ok(autos) = turn
        .mission_store
        .get_mission_automations(turn.mission_id)
        .await
    {
        for a in autos.iter().filter(|a| a.active) {
            seed.push_str(&format!(
                "\nPending automation: trigger={:?} last_triggered={:?}\n",
                a.trigger, a.last_triggered_at
            ));
        }
    }

    let secret_note = if message_mentions_secret(user_content) {
        "\n\n⚠ The operator's latest message contains what looks like a credential \
         (API key / token). Persist it NOW with set_workspace_env under the variable \
         name the mission's tooling expects (check its scripts/docs, or ask), then \
         refer to it only by variable name. Never echo the full value back: chat \
         context does not survive compaction, workspace env vars do."
    } else {
        ""
    };

    let cwd = turn
        .remote_target
        .as_ref()
        .map(|rt| {
            format!(
                "{} (on remote node {})",
                rt.cwd_override
                    .as_deref()
                    .unwrap_or(rt.display_cwd.as_str()),
                rt.node.id
            )
        })
        .unwrap_or_else(|| {
            turn.workspace_exec
                .translate_path_for_container(&turn.work_dir)
        });
    format!(
        "You are the Ask co-pilot for an autonomous coding mission. A separate \
         \"working agent\" is doing the real work in this same workspace; you are a \
         read-mostly assistant helping the operator understand and occasionally nudge \
         what's happening.\n\n\
         Current UTC time: {now}. Mission events and files carry timestamps — compare \
         them against the current time and date your claims (\"as of 14:32Z\"); never \
         present a snapshot from hours ago as the present state.\n\n\
         Recency first: when asked where the mission stands, check the newest data \
         before summarizing — `ls -lt` on results/output dirs, `tail` on logs and \
         journals, `git log --oneline -10`, and read_history. Research logs and \
         journals are append-only: the END of the file is the current state, the \
         beginning is history.\n\n\
         Tool results are capped at 8KB; a truncation notice reports the full size. \
         For big files use read_file with offset/limit or tail/sed line ranges — \
         never assume you saw the whole file.\n\n\
         Your bash tool runs in `{cwd}` — this is the mission's workspace and the \
         working agent's project root. Commands start there and relative paths \
         resolve against it, so you can `ls`, `cat`, or `git log` directly without \
         hunting for the project first.\n\n\
         Prefer reading (history, files, logs) over writing. You MAY write to the \
         workspace with the bash tool, but anything you change is reported to the \
         working agent, so keep writes minimal and intentional. The full mission \
         history may be large — retrieve what you need with read_history / bash \
         (grep, rg, cat) rather than assuming it is all provided.\n\n\
         Secrets: if the operator shares a credential, persist it immediately with \
         set_workspace_env — workspace env vars are injected into the working \
         agent's process environment from its next turn onward and survive restarts \
         and context compaction, unlike anything pasted in chat. Confirm by variable \
         name and never repeat the value. Use list_workspace_env and \
         proxy_key_status to answer \"is the key set / is it being used?\" with \
         facts instead of guesses.\n\n\
         Steering authority: you can stop the working agent (stop_agent) and send \
         it steering messages (send_to_agent) — the same controls the operator has. \
         send_to_agent has three modes: default queues for the next turn boundary; \
         immediate=true injects the message INTO the agent's current turn (received \
         within ~5s, no turn-end, no cancel) — prefer this for a quick mid-flight \
         course-correction; interrupt=true cancels the current turn so it restarts \
         on the message. These are interventions, not observations: use them when \
         the operator asks you to stop/steer/redirect the agent, or when it is \
         burning resources in a clearly harmful loop. Otherwise, propose the \
         steering message and let the operator decide. When you do steer, make the \
         message self-contained and bounded (what to stop, what to do instead, when \
         to stop doing it) — the working agent has no access to this conversation.\n\n\
         Starting new work: you can spin up an independent mission with \
         start_mission (pass agent='orchestrator' for a boss mission that manages \
         its own workers) — give the operator the returned link so they can open \
         it. Use it when the operator asks you to kick off a new piece of work as \
         its own mission, not to fix the current one.\n\n\
         You are strictly reactive: you run only when the operator sends a \
         message, and you cannot watch, poll, or follow up on your own. Never \
         promise to \"keep an eye on\" or \"let you know when\" something \
         happens — instead tell the operator what to ask about next time, or \
         queue a steering note for the working agent.\n\n\
         Be concise and concrete. Cite event sequence numbers or file paths when \
         relevant. When you identify a blocker the operator could fix through \
         configuration (missing env var, unused key), propose the concrete fix — \
         and apply it with your tools when the operator asks.{secret_note}\n\n\
         === Mission context ===\n{seed}"
    )
}

fn tool_definitions() -> Vec<Value> {
    vec![
        json!({
            "type": "function",
            "function": {
                "name": "bash",
                "description": "Run a bash command in the mission's live workspace. Full read+write. Use for grep/rg/cat/ls/git status/git log to inspect the current state.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "command": { "type": "string", "description": "The bash command to run." }
                    },
                    "required": ["command"]
                }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "read_history",
                "description": "Fetch the most recent mission events (the working agent's transcript: messages, tool calls/results, errors). Each event carries its timestamp.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "limit": { "type": "integer", "description": "How many recent events (default 60, max 300)." }
                    }
                }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "read_file",
                "description": "Read a file from the mission workspace by path. Always reports total lines/bytes first. For big files pass offset/limit to read a line range (e.g. the tail of a long log).",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": { "type": "string", "description": "Path to the file (absolute or relative to the workspace root)." },
                        "offset": { "type": "integer", "description": "1-based line number to start reading from (omit to start at the top)." },
                        "limit": { "type": "integer", "description": "Number of lines to read (omit to read to the end)." }
                    },
                    "required": ["path"]
                }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "list_workspace_env",
                "description": "List the workspace environment variables injected into the working agent's process environment (names + masked values). Use to check whether a credential or config var is already set.",
                "parameters": { "type": "object", "properties": {} }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "set_workspace_env",
                "description": "Persist a workspace environment variable. It is injected into the working agent's environment from its next turn onward and survives restarts — the durable channel for credentials the operator shares in chat. The working agent is notified by name (never by value).",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string", "description": "POSIX env var name (e.g. DEFAULT_HARNESS_API_KEY)." },
                        "value": { "type": "string", "description": "The value to store." }
                    },
                    "required": ["name", "value"]
                }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "proxy_key_status",
                "description": "List the gateway's proxy API keys (name, prefix, created_at, last_used_at). Use to answer whether a key the operator issued is valid/actually being used.",
                "parameters": { "type": "object", "properties": {} }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "stop_agent",
                "description": "Interrupt the working agent's current turn (same as the operator's Stop button). The mission becomes interrupted/awaiting until resumed or steered. Use only when the operator asked you to stop it, or when it is clearly stuck in a harmful loop.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "reason": { "type": "string", "description": "One-line reason, recorded for the operator." }
                    },
                    "required": ["reason"]
                }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "send_to_agent",
                "description": "Send a steering message to the working agent. By default, when a turn is actually running, Claude Code with stream input injects it mid-turn within ~5s without cancelling; other harnesses queue it for the next turn boundary (in-flight work preserved). If the agent is idle, a new turn starts on the message now. Set interrupt=true only to cancel the current turn first and restart on the message, losing in-flight work. Use only when the operator asked you to steer/redirect the agent.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "message": { "type": "string", "description": "The steering instructions for the working agent. Be specific: what to stop doing, what to do instead, and any bounds." },
                        "immediate": { "type": "boolean", "description": "Legacy hint for mid-turn delivery. Non-interrupt sends already use the best available tier: mid-turn for capable active harnesses, next-turn otherwise, or start a turn if idle." },
                        "interrupt": { "type": "boolean", "description": "Cancel the agent's current turn before delivering, so the steer applies now instead of after the turn ends. Default false. Takes precedence over immediate." }
                    },
                    "required": ["message"]
                }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "start_mission",
                "description": "Create and START a brand-new mission, then return its dashboard link for the operator. The new mission runs independently of this one. Use when the operator asks you to kick off a new piece of work as its own mission — including a BOSS/orchestrator mission (pass agent='orchestrator') that will plan tasks and spawn its own worker missions. Always give the link back to the operator so they can open it.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "title": { "type": "string", "description": "Short, specific mission title." },
                        "prompt": { "type": "string", "description": "The full initial instruction/goal for the new mission's agent: scope, success criteria, verification, and any bounds. This is the first message the agent receives and what kicks off its first turn." },
                        "agent": { "type": "string", "description": "Optional library agent name. Pass 'orchestrator' to make this a boss mission that manages a worker fleet; omit for a plain single agent." },
                        "backend": { "type": "string", "description": "Optional backend: 'claudecode' (default), 'codex', or 'opencode'." },
                        "workspace_id": { "type": "string", "description": "Optional workspace UUID. Defaults to THIS mission's workspace." }
                    },
                    "required": ["title", "prompt"]
                }
            }
        }),
    ]
}

async fn execute_tool(turn: &AskTurn, name: &str, arguments: &str) -> String {
    let args: Value = serde_json::from_str(arguments).unwrap_or_else(|_| json!({}));
    match name {
        "bash" => {
            let cmd = args["command"].as_str().unwrap_or("").to_string();
            if cmd.trim().is_empty() {
                return "Error: empty command".to_string();
            }
            // In sandbox mode the writes land in a throwaway copy, so there's
            // nothing to report to the working agent. Otherwise snapshot the
            // working tree before/after for the operator-note bridge.
            if turn.sandbox {
                return run_bash(turn, &cmd).await;
            }
            let baseline = capture_write_baseline(turn).await;
            let result = run_bash(turn, &cmd).await;
            record_writes(turn, &cmd, baseline).await;
            result
        }
        "read_file" => {
            let path = args["path"].as_str().unwrap_or("");
            if path.trim().is_empty() {
                return "Error: empty path".to_string();
            }
            let offset = args["offset"].as_u64().map(|v| v.max(1));
            let limit = args["limit"].as_u64().filter(|v| *v > 0);
            let read_cmd = match (offset, limit) {
                (Some(o), Some(l)) => {
                    format!("sed -n '{o},{}p' -- \"$f\"", o.saturating_add(l - 1))
                }
                (Some(o), None) => format!("tail -n +{o} -- \"$f\""),
                (None, Some(l)) => format!("head -n {l} -- \"$f\""),
                (None, None) => "cat -- \"$f\"".to_string(),
            };
            // Lead with the file's true size so the model knows what fraction
            // it is seeing (the 8KB tool-result cap truncates silently otherwise).
            let cmd = format!(
                "f={path}; if [ ! -f \"$f\" ]; then echo \"Error: no such file: $f\" >&2; exit 1; fi; \
                 printf '[%s: %s lines, %s bytes total]\\n' \"$f\" \"$(wc -l < \"$f\")\" \"$(wc -c < \"$f\")\"; {read_cmd}",
                path = single_quote(path),
            );
            run_bash(turn, &cmd).await
        }
        "read_history" => {
            let limit = args["limit"].as_u64().unwrap_or(60).clamp(1, 300) as usize;
            match turn
                .mission_store
                .get_latest_events(turn.mission_id, limit)
                .await
            {
                Ok(events) => {
                    let mut out = String::new();
                    for ev in &events {
                        let tool = ev
                            .tool_name
                            .as_deref()
                            .map(|t| format!(" {t}"))
                            .unwrap_or_default();
                        out.push_str(&format!(
                            "[{} {}] {}{}: {}\n",
                            ev.sequence,
                            ev.timestamp,
                            ev.event_type,
                            tool,
                            truncate(&ev.content, 400)
                        ));
                    }
                    if out.is_empty() {
                        "(no events)".to_string()
                    } else {
                        out
                    }
                }
                Err(e) => format!("Error reading history: {e}"),
            }
        }
        "list_workspace_env" => match turn.workspaces.get(turn.workspace_id).await {
            Some(ws) => {
                if ws.env_vars.is_empty() {
                    "(no workspace env vars configured)".to_string()
                } else {
                    let mut entries: Vec<_> = ws.env_vars.iter().collect();
                    entries.sort_by(|a, b| a.0.cmp(b.0));
                    entries
                        .into_iter()
                        .map(|(k, v)| format!("{k} = {}", mask_value(v)))
                        .collect::<Vec<_>>()
                        .join("\n")
                }
            }
            None => "Error: workspace not found".to_string(),
        },
        "set_workspace_env" => {
            if turn.sandbox {
                return "Error: set_workspace_env is disabled in sandbox mode (it would \
                        change the live workspace configuration)."
                    .to_string();
            }
            let env_name = args["name"].as_str().unwrap_or("").trim().to_string();
            let value = args["value"].as_str().unwrap_or("").to_string();
            if env_name.is_empty() || value.is_empty() {
                return "Error: name and value are required".to_string();
            }
            if !crate::api::workspaces::is_valid_env_name(&env_name) {
                return format!(
                    "Error: '{env_name}' is not a valid POSIX env var name \
                     (letters, digits, underscores; cannot start with a digit)"
                );
            }
            if value.contains('\0') {
                return "Error: value contains a NUL byte".to_string();
            }
            match turn.workspaces.get(turn.workspace_id).await {
                Some(mut ws) => {
                    let replaced = ws
                        .env_vars
                        .insert(env_name.clone(), value.clone())
                        .is_some();
                    if !turn.workspaces.update(ws).await {
                        return "Error: failed to persist the workspace env var".to_string();
                    }
                    // Tell the working agent the variable exists — by name only,
                    // so the value never lands in mission history.
                    let note = format!(
                        "The operator configured the workspace environment variable \
                         `{env_name}` via the Ask assistant (value withheld). It is \
                         injected into your process environment from your next turn \
                         onward — read it from the environment by name instead of \
                         asking for the value or inlining it in commands."
                    );
                    if let Err(e) = turn
                        .ask_store
                        .enqueue_operator_note(turn.mission_id, &note, Some(turn.thread_id))
                        .await
                    {
                        tracing::warn!("[Ask] failed to enqueue env-var operator note: {e}");
                    }
                    format!(
                        "{} workspace env var `{env_name}` ({} chars). It is injected into \
                         the working agent's environment from its next turn onward; an \
                         operator note was queued so the agent knows it is available.",
                        if replaced { "Updated" } else { "Set" },
                        value.chars().count()
                    )
                }
                None => "Error: workspace not found".to_string(),
            }
        }
        "stop_agent" => {
            let reason = args["reason"].as_str().unwrap_or("").trim().to_string();
            if reason.is_empty() {
                return "Error: a reason is required".to_string();
            }
            match cancel_working_agent(turn).await {
                Ok(()) => {
                    record_copilot_stop(turn, &reason).await;
                    format!(
                        "Interrupted the working agent's current turn (reason: {reason}). \
                         The reason was recorded in the mission transcript. The mission \
                         will settle as interrupted/awaiting; use send_to_agent to \
                         redirect it, or the operator can resume it from the dashboard."
                    )
                }
                Err(e) => format!("Error stopping the agent: {e}"),
            }
        }
        "send_to_agent" => {
            let message = args["message"].as_str().unwrap_or("").trim().to_string();
            if message.is_empty() {
                return "Error: message is empty".to_string();
            }
            let interrupt = args["interrupt"].as_bool().unwrap_or(false);
            let _immediate = args["immediate"].as_bool().unwrap_or(false);
            // Track whether the requested interrupt actually landed — a failed
            // cancel (timeout, control error) must not be reported as "delivered
            // after interrupting" when the agent may still be mid-turn.
            let mut interrupt_error: Option<String> = None;
            if interrupt {
                if let Err(e) = cancel_working_agent(turn).await {
                    tracing::info!(
                        mission_id = %turn.mission_id,
                        "[Ask] interrupt before steer did not cancel anything: {e}"
                    );
                    interrupt_error = Some(e);
                } else {
                    record_copilot_stop(turn, &format!("steering: {message}")).await;
                }
            } else {
                let mission = match turn.mission_store.get_mission(turn.mission_id).await {
                    Ok(Some(mission)) => mission,
                    Ok(None) => return "Error: mission not found".to_string(),
                    Err(error) => return format!("Error loading mission: {error}"),
                };
                // Mid-turn injection is only correct when BOTH hold:
                //   (a) a turn is genuinely in flight for this mission — confirmed
                //       with the control session, not the DB status, which can lag
                //       a restart (Active row, no runner) and would otherwise leave
                //       the note queued with nothing to deliver it; and
                //   (b) the harness can accept mid-turn input.
                // The operator-note bridge does not start a turn, so anything else
                // (idle mission, or a running mission on a harness that can't take
                // mid-turn input) falls through to the authoritative UserMessage
                // path below — which starts a turn when idle and queues for the
                // next boundary when running, and reports honestly either way.
                let stream_input_enabled =
                    crate::util::env_var_bool("SANDBOXED_SH_CLAUDE_STREAM_INPUT", true);
                let capable = matches!(
                    effective_mid_turn_kind(
                        &mission.backend,
                        stream_input_enabled,
                        mission.goal_mode,
                    ),
                    MidTurnKind::StreamJsonStdin | MidTurnKind::CodexAppServer
                );
                if capable && !turn.sandbox && mission_has_live_turn(turn).await {
                    let content = format_steer_message(&message);
                    if let Err(error) = turn
                        .ask_store
                        .enqueue_operator_note(turn.mission_id, &content, Some(turn.thread_id))
                        .await
                    {
                        return format!("Error queuing steer: {error}");
                    }
                    // Capability is the best case; the runner still makes the
                    // final per-turn call (a /goal loop or a Claude argv-fallback
                    // turn disables mid-turn polling), so name the next-turn
                    // fallback rather than guaranteeing ~5s. No work is lost.
                    return "Steering message queued for the active mission. If the current turn \
                            can accept mid-turn input it is injected within ~5s without cancelling \
                            or losing in-flight work; otherwise (e.g. a /goal loop or a fallback \
                            turn) it is delivered at the next turn boundary. No work is lost \
                            either way."
                        .to_string();
                }
            }
            let content = format_steer_message(&message);
            let (tx, rx) = tokio::sync::oneshot::channel();
            let send = turn
                .control_cmd_tx
                .send(crate::api::control::ControlCommand::UserMessage {
                    id: Uuid::new_v4(),
                    content,
                    agent: None,
                    target_mission_id: Some(turn.mission_id),
                    strict: false,
                    source: None,
                    respond: tx,
                })
                .await;
            if send.is_err() {
                return "Error: the control session is unavailable".to_string();
            }
            use crate::api::control::UserMessageAck;
            match tokio::time::timeout(std::time::Duration::from_secs(15), rx).await {
                Ok(Ok(UserMessageAck::Queued | UserMessageAck::Continued { queued: true, .. })) => {
                    match (interrupt, &interrupt_error) {
                        (true, None) => {
                            "Steering message delivered after interrupting the current turn — \
                         the agent will act on it as soon as the cancellation settles."
                                .to_string()
                        }
                        (true, Some(err)) => format!(
                            "Steering message queued, but the requested interrupt FAILED \
                         ({err}) — the agent may still be mid-turn and will only act on \
                         the message at the next turn boundary. Verify with read_history; \
                         retry stop_agent if it must stop now."
                        ),
                        (false, _) => {
                            "Steering message queued — the working agent is mid-turn and will \
                         act on it at the next turn boundary. Pass interrupt=true if it \
                         must take effect immediately."
                                .to_string()
                        }
                    }
                }
                Ok(Ok(
                    UserMessageAck::Delivered | UserMessageAck::Continued { queued: false, .. },
                )) => "Steering message delivered — a turn is starting on it now.".to_string(),
                Ok(Ok(UserMessageAck::Dropped)) => {
                    "Error: the steering message was DROPPED — it never reached the \
                     working agent (parallel mission cap, mission load failure, or a \
                     rejected goal kickoff). Check read_history for the error event, \
                     resolve the cause, then retry."
                        .to_string()
                }
                Ok(Ok(UserMessageAck::Rejected(reason))) => {
                    format!("Error: the steering message was rejected: {reason}")
                }
                Ok(Err(_)) | Err(_) => {
                    // The control loop accepted the command but never confirmed —
                    // the message is most likely in flight; don't claim failure.
                    "Steering message submitted (no delivery confirmation received). \
                     Check read_history shortly to confirm the agent saw it."
                        .to_string()
                }
            }
        }
        "proxy_key_status" => {
            let keys = turn.proxy_keys.list().await;
            if keys.is_empty() {
                "(no proxy API keys)".to_string()
            } else {
                keys.iter()
                    .map(|k| {
                        format!(
                            "{} ({}…) created {} — last used: {}",
                            k.name,
                            k.key_prefix,
                            k.created_at
                                .to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                            k.last_used_at
                                .map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
                                .unwrap_or_else(|| "never".to_string())
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("\n")
            }
        }
        "start_mission" => {
            let title = args["title"].as_str().unwrap_or("").trim().to_string();
            let prompt = args["prompt"].as_str().unwrap_or("").trim().to_string();
            if title.is_empty() || prompt.is_empty() {
                return "Error: start_mission requires non-empty 'title' and 'prompt'".to_string();
            }
            let agent = args["agent"]
                .as_str()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string);
            let backend = args["backend"]
                .as_str()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string);
            // Default to THIS mission's workspace unless the operator names another.
            let workspace_id = args["workspace_id"]
                .as_str()
                .and_then(|s| Uuid::parse_str(s.trim()).ok())
                .unwrap_or(turn.workspace_id);

            // 1) Create the mission record.
            let (tx, rx) = tokio::sync::oneshot::channel();
            if turn
                .control_cmd_tx
                .send(crate::api::control::ControlCommand::CreateMission {
                    title: Some(title.clone()),
                    workspace_id: Some(workspace_id),
                    agent,
                    model_override: None,
                    model_effort: None,
                    fast_mode: false,
                    service_tier: None,
                    backend,
                    config_profile: None,
                    parent_mission_id: None,
                    working_directory: None,
                    scheduling: Default::default(),
                    requires_local_disk: true,
                    estimated_disk_gib: None,
                    admission_tags: Vec::new(),
                    respond: tx,
                })
                .await
                .is_err()
            {
                return "Error: the control session is unavailable".to_string();
            }
            let mission = match tokio::time::timeout(std::time::Duration::from_secs(30), rx).await {
                Ok(Ok(Ok(m))) => m,
                Ok(Ok(Err(e))) => return format!("Error creating mission: {e}"),
                Ok(Err(_)) => return "Error: mission creation did not respond".to_string(),
                Err(_) => return "Error: mission creation timed out".to_string(),
            };

            // 2) Start it by delivering the initial prompt — a UserMessage to a
            // brand-new mission auto-starts its first turn.
            let (tx2, rx2) = tokio::sync::oneshot::channel();
            let _ = turn
                .control_cmd_tx
                .send(crate::api::control::ControlCommand::UserMessage {
                    id: Uuid::new_v4(),
                    content: prompt,
                    agent: None,
                    target_mission_id: Some(mission.id),
                    strict: false,
                    source: None,
                    respond: tx2,
                })
                .await;
            let started = matches!(
                tokio::time::timeout(std::time::Duration::from_secs(15), rx2).await,
                Ok(Ok(_))
            );

            // 3) Build the operator-facing link.
            let base = std::env::var("SANDBOXED_PUBLIC_URL")
                .ok()
                .map(|s| s.trim_end_matches('/').to_string())
                .filter(|s| !s.is_empty());
            let link = match &base {
                Some(b) => format!("{b}/control?mission={}", mission.id),
                None => format!("/control?mission={}", mission.id),
            };
            format!(
                "{verb} mission '{title}' (id {id}){caveat}. Give the operator this link: {link}",
                verb = if started { "Started" } else { "Created" },
                title = title,
                id = mission.id,
                caveat = if started {
                    ""
                } else {
                    " — created, but the start signal wasn't confirmed; it may need a nudge"
                },
                link = link,
            )
        }
        other => format!("Error: unknown tool '{other}'"),
    }
}

/// Cancel the working agent's current turn through the control session — the
/// same `CancelMission` path the dashboard's Stop button uses.
async fn cancel_working_agent(turn: &AskTurn) -> Result<(), String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    turn.control_cmd_tx
        .send(crate::api::control::ControlCommand::CancelMission {
            mission_id: turn.mission_id,
            min_idle: None,
            keep_remote_queue: false,
            respond: tx,
        })
        .await
        .map_err(|_| "the control session is unavailable".to_string())?;
    match tokio::time::timeout(std::time::Duration::from_secs(15), rx).await {
        Ok(Ok(result)) => result.map(|_| ()),
        Ok(Err(_)) => Err("the control session dropped the request".to_string()),
        Err(_) => Err("timed out waiting for the cancellation to be acknowledged".to_string()),
    }
}

/// Ask the control session whether this mission has a turn **actually in
/// flight** right now (main or a parallel runner). This is the authoritative
/// signal: the DB `MissionStatus::Active` can lag reality — a restart leaves the
/// row `Active` with no runner attached until autoresume re-attaches — so it must
/// not be used as a proxy for "a turn is executing" when choosing between
/// mid-turn injection (needs a live turn to drain the note) and starting a turn.
/// On any failure we return `false`, degrading to the authoritative UserMessage
/// path (which starts a turn when idle and queues when running).
async fn mission_has_live_turn(turn: &AskTurn) -> bool {
    if turn.remote_target.is_some() {
        // Local `ask_store` operator notes are only drained by local
        // `mission_runner` turns; remote missions must fall through to the
        // authoritative `ControlCommand::UserMessage` outbox path.
        return false;
    }
    if let Ok(Some(run)) = turn
        .mission_store
        .get_latest_mission_run(turn.mission_id)
        .await
    {
        if !run.execution_state.is_terminal() {
            return true;
        }
    }
    let (tx, rx) = tokio::sync::oneshot::channel();
    if turn
        .control_cmd_tx
        .send(crate::api::control::ControlCommand::ListRunning { respond: tx })
        .await
        .is_err()
    {
        return false;
    }
    match tokio::time::timeout(std::time::Duration::from_secs(10), rx).await {
        Ok(Ok(list)) => list.iter().any(|m| m.mission_id == turn.mission_id),
        _ => false,
    }
}

/// Execute a bash command on a remote `orb-node` (`sandboxed-node`) daemon in
/// the mission's remote workspace using a `side_lane` lease (falling back to
/// managed VM `provider.exec` if an un-upgraded remote node rejects with 429
/// because a main job is occupying its sole main slot).
pub async fn exec_remote_ask_command(
    target: &RemoteAskTarget,
    command: &str,
) -> Result<(i32, String, String), String> {
    let wrapped = match target.cwd_override.as_deref() {
        Some(cwd) if !cwd.is_empty() => {
            format!("cd -- {} || exit 78; {command}", single_quote(cwd))
        }
        _ => command.to_string(),
    };
    let claims = crate::remote_node::LeaseClaims {
        mission_id: target.workspace_mission_id,
        node_id: target.node.id.clone(),
        scope: crate::remote_node::SCOPE_MISSION_EXECUTE.into(),
        expires_at: (chrono::Utc::now() + chrono::Duration::minutes(5)).timestamp(),
        job_id: None,
    };
    let token = crate::remote_node::create_lease_token(&claims, &target.secret)
        .map_err(|_| "cannot issue remote node lease token".to_string())?;
    let request = crate::remote_node::LeaseRequest {
        mission_id: target.workspace_mission_id,
        node_id: target.node.id.clone(),
        lease_token: token,
        command: wrapped.clone(),
        side_lane: true,
    };
    match crate::remote_node::RemoteNodeClient::default()
        .execute(&target.node, &target.secret, &request)
        .await
    {
        Ok(res) if res.accepted => Ok((res.exit_code.unwrap_or(-1), res.stdout, res.stderr)),
        Ok(_) => Err("remote node refused Ask workspace command".to_string()),
        Err(err) => {
            let err_msg = err.to_string();
            // Legacy remote nodes before `side_lane` support return HTTP 429 when
            // the main worker slot is busy. For managed VMs, fall back to direct
            // provider exec inside the mission workspace as `orbnode`.
            if err_msg.contains("429") || err_msg.contains("at capacity") {
                if let Some(manager) = crate::managed::global() {
                    if let Some(machine) = manager.get(&target.node.id).await {
                        if let (Some(provider), Some(provider_id)) = (
                            manager.provider_for(&machine.provider),
                            machine.provider_id.as_deref(),
                        ) {
                            let mid = target.workspace_mission_id.to_string();
                            let script = format!(
                                "for d in /var/lib/orb-node/work/{mid} /var/lib/sandboxed-node/work/{mid}; do \
                                   if [ -d \"$d\" ]; then cd -- \"$d\" && break; fi; \
                                 done; {wrapped}"
                            );
                            let cmd = format!(
                                "if id orbnode >/dev/null 2>&1; then su -s /bin/bash orbnode -c {}; else /bin/bash -lc {}; fi",
                                single_quote(&script),
                                single_quote(&script),
                            );
                            let val = provider.exec(provider_id, &cmd, 60).await?;
                            let code = val
                                .get("exit_code")
                                .or_else(|| val.get("exitCode"))
                                .and_then(Value::as_i64)
                                .and_then(|c| i32::try_from(c).ok())
                                .unwrap_or(0);
                            let stdout = val
                                .get("stdout")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string();
                            let stderr = val
                                .get("stderr")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string();
                            return Ok((code, stdout, stderr));
                        }
                    }
                }
            }
            Err(err_msg)
        }
    }
}

/// Prepare an isolated sandbox directory (`/tmp/ask-sandbox-<uuid>`) on a
/// remote `orb-node` for `sandbox: true` Ask turns.
pub async fn prepare_remote_sandbox(target: &RemoteAskTarget) -> Option<SandboxCleanupGuard> {
    let target = target.clone();
    tokio::spawn(async move { prepare_remote_sandbox_in(&target, Path::new("/tmp")).await })
        .await
        .ok()
        .flatten()
}

const REMOTE_SANDBOX_LEASE_HELPER: &str = r#"import fcntl, os, stat, subprocess, sys
mode, path = sys.argv[1:3]
flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
if mode == 'setup':
    flags |= os.O_CREAT | os.O_EXCL
fd = os.open(path, flags, 0o666)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    opened = os.fstat(fd)
    named = os.lstat(path)
    if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
        raise RuntimeError('Ask sandbox lock was replaced')
    if mode == 'setup':
        os.fchmod(fd, 0o666)
        os.write(fd, b'ask-remote-lease\n')
        result = subprocess.run(['/bin/bash', '-c', sys.argv[3]], pass_fds=(fd,))
        if result.returncode:
            sys.exit(result.returncode)
    elif os.read(fd, 32).strip() != b'ask-remote-lease':
        raise RuntimeError('Invalid Ask sandbox lease')
    os.utime(fd, None)
    named = os.lstat(path)
    if (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
        raise RuntimeError('Ask sandbox lock was replaced')
finally:
    os.close(fd)
"#;

const REMOTE_SANDBOX_GC_HELPER: &str = r#"import fcntl, os, shutil, stat, subprocess, sys, time
root = sys.argv[1]
lease_secs = int(sys.argv[2])
now = time.time()
prefix = 'ask-sandbox-'
try:
    names = os.listdir(root)
except OSError:
    sys.exit(0)

def reclaim_lock(lock_path, remove_dir):
    try:
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o666)
    except OSError:
        return False
    try:
        try:
            os.fchmod(fd, 0o666)
        except OSError:
            pass
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False
        opened = os.fstat(fd)
        try:
            named = os.lstat(lock_path)
        except OSError:
            return False
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
            return False
        marker = os.read(fd, 32).strip()
        if marker == b'ask-remote-lease':
            age = now - opened.st_mtime
            if 0 <= age <= lease_secs:
                return False
        if remove_dir is not None:
            try:
                st_dir = os.lstat(remove_dir)
                if stat.S_ISLNK(st_dir.st_mode):
                    return False
                if stat.S_ISDIR(st_dir.st_mode):
                    try:
                        subprocess.run(
                            ['git', 'worktree', 'remove', '--force', remove_dir],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                        )
                    except OSError:
                        pass
                    if os.path.isdir(remove_dir) and not os.path.islink(remove_dir):
                        shutil.rmtree(remove_dir)
            except OSError:
                return False
        try:
            os.unlink(lock_path)
        except OSError:
            pass
        return True
    finally:
        os.close(fd)

reclaimed_any_dir = False
lock_candidates = []
for name in names:
    if not name.startswith(prefix):
        continue
    path = os.path.join(root, name)
    if name.endswith('.lock'):
        lock_candidates.append((name, path))
        continue
    try:
        st = os.lstat(path)
    except OSError:
        continue
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        continue
    if reclaim_lock(path + '.lock', path):
        reclaimed_any_dir = True

for name, path in lock_candidates:
    stem = name[:-5]
    sandbox = os.path.join(root, stem)
    try:
        exists = os.path.lexists(sandbox)
    except OSError:
        exists = True
    if exists:
        continue
    reclaim_lock(path, None)

if reclaimed_any_dir:
    try:
        subprocess.run(
            ['git', 'worktree', 'prune'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass
"#;

fn remote_sandbox_lease_command(lock_path: &str, setup: Option<&str>) -> String {
    format!(
        "python3 -c {} {} {} {}",
        single_quote(REMOTE_SANDBOX_LEASE_HELPER),
        if setup.is_some() { "setup" } else { "refresh" },
        single_quote(lock_path),
        single_quote(setup.unwrap_or_default()),
    )
}

fn remote_sandbox_gc_command(sandbox_root: &str) -> String {
    format!(
        "python3 -c {} {} {}",
        single_quote(REMOTE_SANDBOX_GC_HELPER),
        single_quote(sandbox_root),
        REMOTE_SANDBOX_LEASE_SECS,
    )
}

async fn prepare_remote_sandbox_in(
    target: &RemoteAskTarget,
    sandbox_root: &Path,
) -> Option<SandboxCleanupGuard> {
    if sandbox_root == Path::new("/tmp") {
        initialize_sandbox_gc().await;
    } else {
        gc_stale_sandboxes(sandbox_root).await;
    }
    let sandbox_root_str = sandbox_root.to_string_lossy().into_owned();
    let _ = exec_remote_ask_command(target, &remote_sandbox_gc_command(&sandbox_root_str)).await;
    let sandbox_path = sandbox_root.join(format!("ask-sandbox-{}", Uuid::new_v4()));
    let sandbox_dir = sandbox_path.to_string_lossy().into_owned();
    let mut guard = SandboxCleanupGuard {
        path: sandbox_path,
        target: Some(SandboxCleanupTarget::Remote(target.clone())),
        heartbeat: None,
    };
    let lock_dir = format!("{sandbox_dir}.lock");
    let setup = "set -e; rm -rf -- \"$s\"; \
         if git rev-parse --git-dir >/dev/null 2>&1; then \
           git worktree add --detach \"$s\" HEAD >/dev/null; \
         else \
           mkdir -p -- \"$s\"; \
           if command -v rsync >/dev/null 2>&1; then \
             rsync -a --exclude .git --exclude .lake --exclude node_modules --exclude target --exclude .next -- ./ \"$s\"/; \
           else \
             tar --exclude .git --exclude .lake --exclude node_modules --exclude target --exclude .next -cf - . | (cd -- \"$s\" && tar -xf -); \
           fi; \
         fi";
    let script = format!(
        "set -e; export s={s}; python3 -c 'import fcntl, os, stat, subprocess; assert hasattr(os, \"O_NOFOLLOW\") and os.utime in os.supports_fd' >/dev/null 2>&1; \
         {lease}; echo SANDBOX_OK",
        s = single_quote(&sandbox_dir),
        lease = remote_sandbox_lease_command(&lock_dir, Some(setup)),
    );
    match exec_remote_ask_command(target, &script).await {
        Ok((0, stdout, _)) if stdout.contains("SANDBOX_OK") => {
            let hb_target = target.clone();
            let hb_cmd = remote_sandbox_lease_command(&lock_dir, None);
            guard.heartbeat = Some(tokio::spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
                interval.tick().await;
                loop {
                    interval.tick().await;
                    let _ = exec_remote_ask_command(&hb_target, &hb_cmd).await;
                }
            }));
            Some(guard)
        }
        _ => {
            guard.cleanup().await;
            None
        }
    }
}

/// Clean up a remote sandbox created by [`prepare_remote_sandbox`].
pub async fn cleanup_remote_sandbox(base_target: &RemoteAskTarget, sandbox_dir: &str) {
    let cmd = format!(
        "git worktree remove --force {s} 2>/dev/null || rm -rf -- {s}; \
         rm -f -- {l}; git worktree prune 2>/dev/null || true",
        s = single_quote(sandbox_dir),
        l = single_quote(&format!("{sandbox_dir}.lock")),
    );
    let _ = exec_remote_ask_command(base_target, &cmd).await;
}

async fn run_turn_command_raw(
    turn: &AskTurn,
    command: &str,
) -> Result<(i32, String, String), String> {
    if let Some(rt) = &turn.remote_target {
        return exec_remote_ask_command(rt, command).await;
    }
    let args = vec!["-lc".to_string(), command.to_string()];
    let output = turn
        .workspace_exec
        .output(&turn.work_dir, "/bin/bash", &args, HashMap::new())
        .await
        .map_err(|e| e.to_string())?;
    Ok((
        output.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    ))
}

/// Leave a durable audit record of a Copilot-initiated stop in the mission
/// transcript. Broadcast on `events_tx` so live viewers see it AND the
/// persistent event logger writes it to mission events.
async fn record_copilot_stop(turn: &AskTurn, reason: &str) {
    let _ = turn.events_tx.send(crate::api::control::AgentEvent::Error {
        message: format!(
            "⏹ The Copilot stopped the working agent's turn (operator-authorized). \
                 Reason: {}",
            truncate(reason, 400)
        ),
        mission_id: Some(turn.mission_id),
        resumable: true,
    });
}

/// Wrap a Copilot steering message so the working agent (and the mission
/// transcript) can tell it came through the co-pilot acting on the operator's
/// behalf, not from the operator typing directly.
fn format_steer_message(message: &str) -> String {
    format!("[Steering from the operator via the Copilot]\n{message}")
}

/// Mask an env var value for display: short prefix + length, never the value.
fn mask_value(v: &str) -> String {
    let prefix: String = v.chars().take(4).collect();
    format!("{prefix}… ({} chars)", v.chars().count())
}

async fn run_bash(turn: &AskTurn, command: &str) -> String {
    match run_turn_command_raw(turn, command).await {
        Ok((code, stdout, stderr)) => {
            let mut out = String::new();
            if !stdout.trim().is_empty() {
                out.push_str(stdout.trim_end());
            }
            if !stderr.trim().is_empty() {
                if !out.is_empty() {
                    out.push('\n');
                }
                out.push_str("[stderr] ");
                out.push_str(stderr.trim_end());
            }
            if code != 0 {
                out.push_str(&format!("\n[exit code {code}]"));
            }
            if out.is_empty() {
                "(no output)".to_string()
            } else {
                out
            }
        }
        Err(e) => format!("Error running command: {e}"),
    }
}

/// Snapshot `git status --porcelain` (tracked + untracked) as a set of lines.
/// Returns `None` when the workspace is not a git repo (no detection possible).
async fn git_status_set(turn: &AskTurn) -> Option<HashSet<String>> {
    let (code, stdout, _) = run_turn_command_raw(
        turn,
        "git status --porcelain=v1 --untracked-files=all 2>/dev/null",
    )
    .await
    .ok()?;
    if code != 0 {
        return None; // not a git repo (or git unavailable)
    }
    Some(stdout.lines().map(|l| l.to_string()).collect())
}

/// Baseline of the working tree captured before an Ask bash command, used to
/// detect writes afterwards. Git workspaces use a porcelain snapshot; non-git
/// workspaces fall back to an mtime cutoff.
enum WriteBaseline {
    Git(HashSet<String>),
    /// Epoch seconds, for `find -newermt @epoch` detection.
    Mtime(String),
    None,
}

async fn capture_write_baseline(turn: &AskTurn) -> WriteBaseline {
    if let Some(set) = git_status_set(turn).await {
        return WriteBaseline::Git(set);
    }
    // Non-git fallback: capture an epoch marker for mtime-based detection.
    if let Ok((0, stdout, _)) = run_turn_command_raw(turn, "date +%s").await {
        let epoch = stdout.trim().to_string();
        if !epoch.is_empty() && epoch.chars().all(|c| c.is_ascii_digit()) {
            return WriteBaseline::Mtime(epoch);
        }
    }
    WriteBaseline::None
}

/// After an Ask bash command, diff the working tree against the `baseline` and
/// enqueue an operator-note describing any new/changed paths so the working
/// agent learns about edits it didn't make.
async fn record_writes(turn: &AskTurn, command: &str, baseline: WriteBaseline) {
    let mut changed: Vec<String> = match baseline {
        WriteBaseline::Git(before) => {
            let Some(after) = git_status_set(turn).await else {
                return;
            };
            // New porcelain lines that weren't present before — predominantly
            // this command's writes (the window is a single command).
            after
                .difference(&before)
                .map(|l| l.trim().to_string())
                .collect()
        }
        WriteBaseline::Mtime(epoch) => {
            let cmd = format!(
                "find . -type f -newermt @{epoch} \
                 -not -path './.git/*' -not -path './node_modules/*' \
                 -not -path './target/*' 2>/dev/null | head -50"
            );
            match run_turn_command_raw(turn, &cmd).await {
                Ok((_, stdout, _)) => stdout
                    .lines()
                    .map(|l| l.trim().to_string())
                    .filter(|l| !l.is_empty())
                    .collect(),
                Err(_) => return,
            }
        }
        WriteBaseline::None => return,
    };

    if changed.is_empty() {
        return;
    }
    changed.sort();
    changed.dedup();

    let body = format!(
        "While you were working, the operator made out-of-band changes to this \
         workspace via the Ask assistant (not by you), running `{}`:\n{}\n\
         If relevant, re-read these files before continuing; do not assume your \
         previous view of them is current.",
        truncate(command, 200),
        changed
            .iter()
            .map(|l| format!("- {l}"))
            .collect::<Vec<_>>()
            .join("\n")
    );

    if let Err(e) = turn
        .ask_store
        .enqueue_operator_note(turn.mission_id, &body, Some(turn.thread_id))
        .await
    {
        tracing::warn!("[Ask] failed to enqueue operator note: {e}");
    }
}

/// Flush any pending operator-notes for a mission into the working agent's next
/// turn by prepending a tagged block to its `user_message`. Returns the message
/// unchanged when there are no pending notes.
///
/// This is the **delivery** half of the operator-note bridge, called from each
/// backend's turn-prep (see `mission_runner`). Notes are passive: this only ever
/// runs when a turn is already about to execute — it never starts one.
pub async fn prepend_pending_operator_notes(
    store: &AskStore,
    mission_id: Uuid,
    user_message: String,
) -> (String, usize) {
    let notes = match store.take_pending_operator_notes(mission_id).await {
        Ok(n) if !n.is_empty() => n,
        _ => return (user_message, 0),
    };
    let count = notes.len();
    let mut block = String::from("<operator-note>\n");
    for note in &notes {
        block.push_str(&note.body);
        block.push('\n');
    }
    block.push_str("</operator-note>\n\n");
    block.push_str(&user_message);
    (block, count)
}

/// Prepare an isolated sandbox copy of the workspace for "Ask in isolated copy"
/// mode, using a detached git worktree (cheap, shares history, no full copy).
/// Returns the sandbox path, or `None` if the workspace isn't a git repo (we
/// deliberately do NOT `cp -a` a possibly-huge non-git tree). The caller treats
/// `None` for an explicit sandbox request as an error rather than silently
/// running against the live tree.
pub async fn prepare_sandbox(
    exec: &WorkspaceExec,
    base_work_dir: &Path,
) -> Option<SandboxCleanupGuard> {
    let exec = exec.clone();
    let base_work_dir = base_work_dir.to_path_buf();
    tokio::spawn(async move { prepare_sandbox_inner(&exec, &base_work_dir).await })
        .await
        .ok()
        .flatten()
}

async fn prepare_sandbox_inner(
    exec: &WorkspaceExec,
    base_work_dir: &Path,
) -> Option<SandboxCleanupGuard> {
    initialize_sandbox_gc().await;
    let sandbox_guest = PathBuf::from(format!("/tmp/ask-sandbox-{}", Uuid::new_v4()));
    let sandbox_host = sandbox_host_path(exec, &sandbox_guest);
    let sandbox_for_lock = sandbox_host.clone();
    let lock_res = tokio::task::spawn_blocking(move || register_live_sandbox(&sandbox_for_lock))
        .await
        .map_err(|e| std::io::Error::other(e.to_string()))
        .and_then(|r| r);
    if let Err(err) = lock_res {
        tracing::warn!(
            sandbox = %sandbox_host.display(),
            %err,
            "Failed to acquire cross-process lock for Ask sandbox"
        );
        return None;
    }
    let guard = SandboxCleanupGuard {
        path: sandbox_host.clone(),
        target: Some(SandboxCleanupTarget::Local {
            exec: Box::new(exec.clone()),
            base_work_dir: base_work_dir.to_path_buf(),
        }),
        heartbeat: None,
    };
    // Shell snippets execute in the workspace context. For nspawn workspaces,
    // interpolating host paths here makes both `git -C` and `test -d` point at
    // paths that do not exist in the guest, so every sandbox request fails.
    let base_str = exec.translate_path_for_container(base_work_dir);
    let sandbox_str = sandbox_guest.to_string_lossy().to_string();
    let is_git_cmd = format!(
        "git -C {b} rev-parse --git-dir >/dev/null 2>&1",
        b = single_quote(&base_str)
    );
    let args = vec!["-lc".to_string(), is_git_cmd];
    let is_git = exec
        .output(base_work_dir, "/bin/bash", &args, HashMap::new())
        .await
        .map(|out| out.status.success())
        .unwrap_or(false);

    if !is_git {
        let copy_cmd = format!(
            "set -e; test -d {b}; rm -rf {s}; mkdir -p {s}; \
             if command -v rsync >/dev/null 2>&1; then \
               rsync -a --exclude .git --exclude .lake --exclude node_modules --exclude target --exclude .next -- {b}/ {s}/; \
             else \
               (cd {b} && tar --exclude .git --exclude .lake --exclude node_modules --exclude target --exclude .next -cf - .) | (cd {s} && tar -xf -); \
             fi; echo SANDBOX_OK",
            b = single_quote(&base_str),
            s = single_quote(&sandbox_str)
        );
        let args = vec!["-lc".to_string(), copy_cmd];
        return match exec
            .output(base_work_dir, "/bin/bash", &args, HashMap::new())
            .await
        {
            Ok(out)
                if out.status.success()
                    && String::from_utf8_lossy(&out.stdout).contains("SANDBOX_OK") =>
            {
                Some(guard)
            }
            Ok(out) => {
                log_sandbox_command_failure("copy", &out);
                // The copy command creates the destination before filling it,
                // so a failure part-way through (a full `/tmp` is the usual
                // one) strands a partial tree that nothing else will ever
                // collect — the caller only tears down sandboxes it was
                // handed. That turns one failed Ask into permanently lost
                // scratch space, which makes the next Ask likelier to fail.
                guard.cleanup().await;
                None
            }
            Err(error) => {
                tracing::warn!(stage = "copy", %error, "Ask sandbox command failed to start");
                guard.cleanup().await;
                None
            }
        };
    }

    let cmd = format!(
        "git -C {b} rev-parse --git-dir >/dev/null 2>&1 && \
         git -C {b} worktree add --detach {s} HEAD >/dev/null && \
         echo SANDBOX_OK",
        b = single_quote(&base_str),
        s = single_quote(&sandbox_str)
    );
    let args = vec!["-lc".to_string(), cmd];
    match exec
        .output(base_work_dir, "/bin/bash", &args, HashMap::new())
        .await
    {
        Ok(out)
            if out.status.success()
                && String::from_utf8_lossy(&out.stdout).contains("SANDBOX_OK") =>
        {
            Some(guard)
        }
        Ok(out) => {
            log_sandbox_command_failure("git-worktree", &out);
            guard.cleanup().await;
            None
        }
        Err(error) => {
            tracing::warn!(stage = "git-worktree", %error, "Ask sandbox command failed to start");
            guard.cleanup().await;
            None
        }
    }
}

fn sandbox_host_path(exec: &WorkspaceExec, guest_path: &Path) -> PathBuf {
    sandbox_host_path_for_context(
        &exec.workspace.path,
        exec.workspace.workspace_type == WorkspaceType::Container
            && use_nspawn_for_workspace(&exec.workspace),
        guest_path,
    )
}

fn sandbox_host_path_for_context(
    workspace_root: &Path,
    nspawn_container: bool,
    guest_path: &Path,
) -> PathBuf {
    if nspawn_container {
        workspace_root.join(guest_path.strip_prefix("/").unwrap_or(guest_path))
    } else {
        guest_path.to_path_buf()
    }
}

fn log_sandbox_command_failure(stage: &str, output: &std::process::Output) {
    // Keep diagnostics bounded: command stderr can contain large git output,
    // while paths and exit status are enough to diagnose sandbox preparation.
    let stderr = truncate(String::from_utf8_lossy(&output.stderr).trim(), 2_000);
    tracing::warn!(
        stage,
        status = ?output.status,
        stderr,
        "Ask sandbox preparation failed"
    );
}

/// Tear down a sandbox created by [`prepare_sandbox`]. Best-effort: removes the
/// git worktree if it is one, otherwise `rm -rf`s the copy.
pub async fn cleanup_sandbox(exec: &WorkspaceExec, base_work_dir: &Path, sandbox: &Path) {
    let base_str = exec.translate_path_for_container(base_work_dir);
    let sandbox_str = exec.translate_path_for_container(sandbox);
    // `prune` matters for the failure path: a `worktree add` that died partway
    // leaves an admin entry in `.git/worktrees` that `rm -rf` alone cannot
    // clear, and which then blocks re-using that path. It only drops entries
    // whose directory is already gone, so healthy worktrees are untouched.
    let cmd = format!(
        "git -C {b} worktree remove --force {s} 2>/dev/null || rm -rf {s}; \
         git -C {b} worktree prune 2>/dev/null || true",
        b = single_quote(&base_str),
        s = single_quote(&sandbox_str)
    );
    let args = vec!["-lc".to_string(), cmd];
    let _ = exec
        .output(base_work_dir, "/bin/bash", &args, HashMap::new())
        .await;
    let sandbox_owned = sandbox.to_path_buf();
    let _ = tokio::task::spawn_blocking(move || release_live_sandbox(&sandbox_owned)).await;
}

fn single_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn truncate(s: &str, max_bytes: usize) -> String {
    if s.len() <= max_bytes {
        return s.to_string();
    }
    let mut end = max_bytes;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}… (truncated)", &s[..end])
}

/// Truncate a tool result at [`MAX_TOOL_RESULT_BYTES`], appending an explicit
/// notice with the full size so the model knows it saw a partial view and how
/// to fetch the rest (instead of silently mistaking the prefix for the whole).
fn truncate_tool_result(s: &str) -> String {
    if s.len() <= MAX_TOOL_RESULT_BYTES {
        return s.to_string();
    }
    let mut end = MAX_TOOL_RESULT_BYTES;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    format!(
        "{}\n… [truncated: showing first {} of {} bytes — use read_file with \
         offset/limit, or tail/sed line ranges, to view the rest]",
        &s[..end],
        end,
        s.len()
    )
}

/// Heuristic detection of credential-shaped tokens in an operator message, used
/// to nudge the model into persisting them via `set_workspace_env` instead of
/// letting them live (and die) in chat context.
fn message_mentions_secret(text: &str) -> bool {
    use std::sync::OnceLock;
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        regex::Regex::new(
            r"(?x)
            \b(
                sk-[A-Za-z0-9_-]{12,}                       # OpenAI / proxy-style keys
              | (ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}      # GitHub tokens
              | github_pat_[A-Za-z0-9_]{20,}
              | AKIA[0-9A-Z]{16}                            # AWS access key id
              | xox[abprs]-[A-Za-z0-9-]{10,}                # Slack tokens
              | AIza[0-9A-Za-z_-]{30,}                      # Google API keys
              | eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,} # JWT
            )",
        )
        .expect("static secret-detection regex must compile")
    });
    re.is_match(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nspawn_sandbox_keeps_distinct_host_and_guest_paths() {
        let root = Path::new("/srv/containers/demo");
        let guest = Path::new("/tmp/ask-sandbox-test");

        // The old implementation returned the guest path as the host cwd.
        // WorkspaceExec cannot relativize it to the container root and would
        // therefore translate it to `/`.
        let old_relative = guest.strip_prefix(root).unwrap_or_else(|_| Path::new(""));
        let old_translation = if old_relative.as_os_str().is_empty() {
            "/".to_string()
        } else {
            format!("/{}", old_relative.display())
        };
        assert_eq!(old_translation, "/");

        let host = sandbox_host_path_for_context(root, true, guest);
        assert_eq!(host, root.join("tmp/ask-sandbox-test"));
        assert_eq!(
            format!("/{}", host.strip_prefix(root).unwrap().display()),
            guest.display().to_string()
        );
    }

    #[test]
    fn host_sandbox_uses_the_execution_path_directly() {
        let guest = Path::new("/tmp/ask-sandbox-test");
        assert_eq!(
            sandbox_host_path_for_context(Path::new("/ignored"), false, guest),
            guest
        );
    }

    async fn temp_store() -> Arc<AskStore> {
        let path = std::env::temp_dir().join(format!("ask-bridge-{}.db", Uuid::new_v4()));
        Arc::new(AskStore::open(path).await.unwrap())
    }

    #[tokio::test]
    async fn operator_notes_prepend_then_drain() {
        let store = temp_store().await;
        let mission = Uuid::new_v4();

        // No pending notes → message is returned unchanged.
        let (msg, n) = prepend_pending_operator_notes(&store, mission, "Continue.".into()).await;
        assert_eq!(n, 0);
        assert_eq!(msg, "Continue.");

        store
            .enqueue_operator_note(mission, "Added scripts/probe.sh", None)
            .await
            .unwrap();

        let (msg, n) = prepend_pending_operator_notes(&store, mission, "Continue.".into()).await;
        assert_eq!(n, 1);
        assert!(msg.starts_with("<operator-note>"));
        assert!(msg.contains("Added scripts/probe.sh"));
        assert!(msg.trim_end().ends_with("Continue."));

        // Flushed exactly once — the next turn sees no note.
        let (msg, n) = prepend_pending_operator_notes(&store, mission, "Continue.".into()).await;
        assert_eq!(n, 0);
        assert_eq!(msg, "Continue.");
    }

    #[test]
    fn tool_result_truncation_reports_full_size() {
        let small = "ok";
        assert_eq!(truncate_tool_result(small), "ok");

        let big = "x".repeat(MAX_TOOL_RESULT_BYTES + 500);
        let out = truncate_tool_result(&big);
        assert!(out.contains(&format!(
            "showing first {} of {} bytes",
            MAX_TOOL_RESULT_BYTES,
            big.len()
        )));
        assert!(out.contains("read_file with"));
    }

    #[test]
    fn secret_detection_matches_common_token_shapes() {
        // Synthetic values only — shaped like real tokens, never actual ones.
        assert!(message_mentions_secret(
            "try sk-proxy-0123456789abcdef0123456789abcdef and tell me"
        ));
        assert!(message_mentions_secret(
            "token: ghp_0123456789abcdefghijABCDEFGHIJ0123"
        ));
        assert!(message_mentions_secret("AKIAIOSFODNN7EXAMPLE"));
        // Plain prose, short ids, and tactic punctuation must not trip it.
        assert!(!message_mentions_secret("what is the mission status?"));
        assert!(!message_mentions_secret("the sk-learn library"));
        assert!(!message_mentions_secret("commit 381a865f is on master"));
    }

    #[test]
    fn steer_messages_carry_a_copilot_attribution() {
        let msg = format_steer_message("Stop rewriting orchestrator-state.json.");
        assert!(msg.starts_with("[Steering from the operator via the Copilot]"));
        assert!(msg.ends_with("Stop rewriting orchestrator-state.json."));
    }

    #[test]
    fn env_value_masking_never_leaks() {
        let masked = mask_value("sk-proxy-0123456789abcdef0123456789abcdef");
        assert_eq!(masked, "sk-p… (41 chars)");
        assert!(!masked.contains("0123456789"));
    }

    #[tokio::test]
    async fn cancelled_remote_setup_keeps_lock_until_cleanup() {
        use crate::remote_node::{ExecuteResponse, LeaseRequest, RemoteNodeConfig};
        use axum::{routing::post, Json, Router};

        let root = tempfile::tempdir().unwrap();
        let (created_tx, mut created_rx) = tokio::sync::mpsc::channel(1);
        let resume = Arc::new(tokio::sync::Notify::new());
        let handler_resume = Arc::clone(&resume);
        let app = Router::new().route(
            "/execute",
            post(move |Json(req): Json<LeaseRequest>| {
                let created_tx = created_tx.clone();
                let resume = Arc::clone(&handler_resume);
                async move {
                    let out = tokio::process::Command::new("/bin/bash")
                        .arg("-lc")
                        .arg(&req.command)
                        .output()
                        .await
                        .unwrap();
                    if req.command.contains("SANDBOX_OK") {
                        let path = req
                            .command
                            .split("s='")
                            .nth(1)
                            .unwrap()
                            .split('\'')
                            .next()
                            .unwrap();
                        created_tx.send(PathBuf::from(path)).await.unwrap();
                        resume.notified().await;
                    }
                    Json(ExecuteResponse {
                        accepted: true,
                        exit_code: out.status.code(),
                        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
                        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
                    })
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let target = RemoteAskTarget {
            node: RemoteNodeConfig {
                id: "ask-test".into(),
                base_url: format!("http://{address}"),
                token_env: "ASK_TEST_TOKEN".into(),
                labels: None,
            },
            secret: "test-secret".into(),
            workspace_mission_id: Uuid::new_v4(),
            cwd_override: Some(root.path().to_string_lossy().into_owned()),
            display_cwd: root.path().to_string_lossy().into_owned(),
            live: false,
        };
        let request = tokio::spawn(async move { prepare_remote_sandbox(&target).await });
        let path = tokio::time::timeout(std::time::Duration::from_secs(10), created_rx.recv())
            .await
            .unwrap()
            .unwrap();
        request.abort();
        let _ = request.await;
        assert!(path.exists());
        gc_stale_sandboxes_with_observer(Path::new("/tmp"), &HashSet::new(), |_| {});
        assert!(path.exists());
        resume.notify_one();
        tokio::time::timeout(std::time::Duration::from_secs(10), async {
            loop {
                if !path.exists()
                    && !sandbox_lock_path(&path).exists()
                    && !live_sandboxes().lock().unwrap().contains_key(&path)
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        server.abort();
    }

    #[tokio::test]
    async fn dropped_sandbox_guard_cleans_directory_and_lock() {
        let root = tempfile::tempdir().unwrap();
        let exec = WorkspaceExec::new(crate::workspace::Workspace::default_host(
            root.path().into(),
        ));
        let guard = prepare_sandbox(&exec, root.path()).await.unwrap();
        let path = guard.path().to_path_buf();
        assert!(path.exists());
        assert!(sandbox_lock_path(&path).exists());
        drop(guard);
        tokio::time::timeout(std::time::Duration::from_secs(10), async {
            loop {
                if !path.exists()
                    && !sandbox_lock_path(&path).exists()
                    && !live_sandboxes().lock().unwrap().contains_key(&path)
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn startup_gc_removes_stale_ask_sandboxes_only() {
        let root = tempfile::tempdir().unwrap();
        let stale = root.path().join("ask-sandbox-stale");
        let live = root.path().join("ask-sandbox-live");
        let keep_dir = root.path().join("other-worktree");
        let keep_file = root.path().join("ask-sandbox-not-a-dir");
        tokio::fs::create_dir_all(stale.join("nested"))
            .await
            .unwrap();
        tokio::fs::write(stale.join("nested/file.txt"), "stale")
            .await
            .unwrap();
        tokio::fs::create_dir_all(live.join("nested"))
            .await
            .unwrap();
        tokio::fs::write(live.join("nested/file.txt"), "live")
            .await
            .unwrap();
        tokio::fs::create_dir_all(&keep_dir).await.unwrap();
        tokio::fs::write(&keep_file, "keep").await.unwrap();

        let live_guard = acquire_sandbox_lock(&live).unwrap();

        let cell = OnceCell::new();
        let work_dir = tempfile::tempdir().unwrap();
        let _store = ask_store_in_cell(&cell, work_dir.path(), Some(root.path()))
            .await
            .unwrap();

        assert!(!stale.exists());
        assert!(live.exists());
        assert!(sandbox_lock_path(&live).exists());
        assert!(keep_dir.exists());
        assert!(keep_file.exists());
        drop(live_guard);
        gc_stale_sandboxes(root.path()).await;
        assert!(!live.exists());
        assert!(!sandbox_lock_path(&live).exists());
    }

    #[tokio::test]
    async fn cross_handle_flock_prevents_gc_of_other_process_sandbox() {
        let root = tempfile::tempdir().unwrap();
        let remote_live = root.path().join("ask-sandbox-other-proc");
        let stale_unlocked = root.path().join("ask-sandbox-crashed-proc");
        let stale_orphan_lock = root.path().join("ask-sandbox-orphan.lock");

        tokio::fs::create_dir_all(remote_live.join("sub"))
            .await
            .unwrap();
        tokio::fs::write(remote_live.join("sub/data.txt"), "active")
            .await
            .unwrap();
        tokio::fs::create_dir_all(stale_unlocked.join("sub"))
            .await
            .unwrap();
        tokio::fs::write(stale_unlocked.join("sub/data.txt"), "crashed")
            .await
            .unwrap();

        let crashed_lock_path = sandbox_lock_path(&stale_unlocked);
        tokio::fs::write(&crashed_lock_path, "").await.unwrap();
        tokio::fs::write(&stale_orphan_lock, "").await.unwrap();

        let external_lock_path = sandbox_lock_path(&remote_live);
        let external_file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&external_lock_path)
            .unwrap();
        fs2::FileExt::try_lock_exclusive(&external_file).unwrap();
        assert!(!live_sandboxes()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains_key(&remote_live));

        gc_stale_sandboxes(root.path()).await;

        assert!(remote_live.join("sub/data.txt").exists());
        assert!(external_lock_path.exists());
        assert!(!stale_unlocked.exists());
        assert!(!crashed_lock_path.exists());
        assert!(!stale_orphan_lock.exists());

        fs2::FileExt::unlock(&external_file).unwrap();
        drop(external_file);
        gc_stale_sandboxes(root.path()).await;
        assert!(!remote_live.exists());
        assert!(!external_lock_path.exists());
    }

    #[tokio::test]
    async fn remote_sandbox_holds_host_lock_against_colocated_gc_and_cleans_up_on_drop() {
        let work_root = tempfile::tempdir().unwrap();
        let src_file = work_root.path().join("hello.txt");
        tokio::fs::write(&src_file, "remote-sandbox-ok")
            .await
            .unwrap();
        let work_dir = work_root.path().to_path_buf();

        let execute_router = axum::Router::new().route(
            "/execute",
            axum::routing::post(
                move |axum::Json(req): axum::Json<crate::remote_node::LeaseRequest>| {
                    let work_dir = work_dir.clone();
                    async move {
                        let out = tokio::process::Command::new("/bin/bash")
                            .arg("-lc")
                            .arg(&req.command)
                            .current_dir(&work_dir)
                            .output()
                            .await
                            .unwrap();
                        axum::Json(crate::remote_node::ExecuteResponse {
                            accepted: true,
                            exit_code: Some(out.status.code().unwrap_or(-1)),
                            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
                            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
                        })
                    }
                },
            ),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, execute_router).await;
        });

        let target = RemoteAskTarget {
            node: crate::remote_node::RemoteNodeConfig {
                id: "colocated-node".into(),
                base_url: format!("http://{addr}"),
                token_env: "TEST_TOKEN".into(),
                labels: None,
            },
            secret: "test-secret".into(),
            workspace_mission_id: Uuid::new_v4(),
            cwd_override: None,
            display_cwd: work_root.path().display().to_string(),
            live: true,
        };

        let guard = prepare_remote_sandbox(&target)
            .await
            .expect("remote sandbox should be prepared");
        let sandbox_path = guard.path().to_path_buf();
        let lock_path = sandbox_lock_path(&sandbox_path);

        assert!(sandbox_path.join("hello.txt").exists());
        assert!(lock_path.exists());

        // Simulate a co-located second Core process scanning `/tmp` without
        // sharing this process's in-memory `LIVE_SANDBOXES` map.
        let empty_other_proc_live = HashSet::new();
        gc_stale_sandboxes_with_observer(Path::new("/tmp"), &empty_other_proc_live, |_| {});
        assert!(
            sandbox_path.join("hello.txt").exists(),
            "remote lease lock must protect live co-located remote sandbox from GC"
        );
        assert!(lock_path.exists());

        // Simulate request drop / SSE disconnect without explicit `.cleanup().await`.
        drop(guard);
        for _ in 0..50 {
            if !sandbox_path.exists() && !lock_path.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        assert!(!sandbox_path.exists());
        assert!(!lock_path.exists());

        server.abort();
    }

    #[tokio::test]
    async fn local_sandbox_cleans_up_when_guard_is_dropped() {
        let ws_root = tempfile::tempdir().unwrap();
        tokio::fs::write(ws_root.path().join("marker.txt"), "local-ok")
            .await
            .unwrap();
        let exec = WorkspaceExec::new(crate::workspace::Workspace::default_host(
            ws_root.path().to_path_buf(),
        ));

        let guard = prepare_sandbox(&exec, ws_root.path())
            .await
            .expect("local sandbox should be prepared");
        let sandbox_path = guard.path().to_path_buf();
        let lock_path = sandbox_lock_path(&sandbox_path);

        assert!(sandbox_path.join("marker.txt").exists());
        assert!(lock_path.exists());
        assert!(live_sandboxes()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains_key(&sandbox_path));

        drop(guard);
        for _ in 0..50 {
            if !sandbox_path.exists()
                && !lock_path.exists()
                && !live_sandboxes()
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .contains_key(&sandbox_path)
            {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        assert!(!sandbox_path.exists());
        assert!(!lock_path.exists());
        assert!(!live_sandboxes()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains_key(&sandbox_path));
    }

    #[test]
    fn gc_tolerates_disappearing_entries_during_scan() {
        let root = tempfile::tempdir().unwrap();
        let vanishing = root.path().join("ask-sandbox-vanishing");
        let stale = root.path().join("ask-sandbox-stale-survivor");
        std::fs::create_dir_all(vanishing.join("inner")).unwrap();
        std::fs::create_dir_all(stale.join("inner")).unwrap();

        let empty_live = HashSet::new();
        gc_stale_sandboxes_with_observer(root.path(), &empty_live, |seen_path| {
            if seen_path == vanishing {
                let _ = std::fs::remove_dir_all(seen_path);
            }
        });

        assert!(!vanishing.exists());
        assert!(!stale.exists());
    }

    #[tokio::test]
    async fn midturn_store_uses_configured_working_dir_without_env_divergence() {
        let configured_dir = tempfile::tempdir().unwrap();
        let cell = OnceCell::new();

        let store = ask_store_for_midturn_in(&cell, Some(configured_dir.path()))
            .await
            .unwrap();
        let mission = Uuid::new_v4();
        store
            .enqueue_operator_note(mission, "configured-dir-note", None)
            .await
            .unwrap();

        assert!(configured_dir
            .path()
            .join(".sandboxed-sh/missions/ask.db")
            .exists());

        let same_store = ask_store_for_midturn_in(&cell, None).await.unwrap();
        assert!(Arc::ptr_eq(&store, &same_store));
        let notes = same_store
            .take_pending_operator_notes(mission)
            .await
            .unwrap();
        assert_eq!(notes.len(), 1);
        assert_eq!(notes[0].body, "configured-dir-note");
    }

    #[tokio::test]
    async fn peek_and_mark_operator_notes_preserve_identity_and_order() {
        let db_path = std::env::temp_dir().join(format!("ask-order-{}.db", Uuid::new_v4()));
        let store = Arc::new(AskStore::open(db_path.clone()).await.unwrap());
        let mission = Uuid::new_v4();
        let id1 = Uuid::new_v4();
        let id2 = Uuid::new_v4();
        let ts1 = "2026-11-06T09:00:00Z";
        let ts2 = "2026-11-06T09:00:01Z";
        {
            let conn = rusqlite::Connection::open(&db_path).unwrap();
            for (id, body, ts) in [(id1, "first", ts1), (id2, "second", ts2)] {
                conn.execute(
                    "INSERT INTO operator_notes (id, mission_id, body, source_thread_id, created_at, flushed_at) \
                     VALUES (?1, ?2, ?3, NULL, ?4, NULL)",
                    rusqlite::params![id.to_string(), mission.to_string(), body, ts],
                )
                .unwrap();
            }
        }

        let peeked = store.peek_unflushed_operator_notes(mission).await.unwrap();
        assert_eq!(
            peeked
                .iter()
                .map(|n| (n.id, n.created_at.as_str()))
                .collect::<Vec<_>>(),
            vec![(id1, ts1), (id2, ts2)]
        );

        let peeked_again = store.peek_unflushed_operator_notes(mission).await.unwrap();
        assert_eq!(
            peeked_again
                .iter()
                .map(|n| (n.id, n.created_at.as_str()))
                .collect::<Vec<_>>(),
            vec![(id1, ts1), (id2, ts2)]
        );

        store
            .mark_operator_notes_flushed(mission, &[id1, id2], "2026-11-06T09:00:02Z")
            .await
            .unwrap();
        assert!(store
            .peek_unflushed_operator_notes(mission)
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn separate_host_remote_sandbox_survives_remote_gc_and_cleans_up() {
        use crate::remote_node::{ExecuteResponse, LeaseRequest, RemoteNodeConfig};
        use axum::{routing::post, Json, Router};

        let remote_work = tempfile::tempdir().unwrap();
        tokio::fs::write(remote_work.path().join("remote.txt"), "distinct-host")
            .await
            .unwrap();
        let core_tmp = tempfile::tempdir().unwrap();
        let remote_tmp = tempfile::tempdir().unwrap();
        let core_root = core_tmp.path().to_path_buf();
        let remote_root = remote_tmp.path().to_path_buf();
        let work_dir = remote_work.path().to_path_buf();

        let app = Router::new().route(
            "/execute",
            post(move |Json(req): Json<LeaseRequest>| {
                let core_prefix = core_root.to_string_lossy().into_owned();
                let remote_prefix = remote_root.to_string_lossy().into_owned();
                let work_dir = work_dir.clone();
                async move {
                    let rewritten = req.command.replace(&core_prefix, &remote_prefix);
                    let out = tokio::process::Command::new("/bin/bash")
                        .arg("-lc")
                        .arg(&rewritten)
                        .current_dir(&work_dir)
                        .output()
                        .await
                        .unwrap();
                    Json(ExecuteResponse {
                        accepted: true,
                        exit_code: out.status.code(),
                        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
                        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
                    })
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let target = RemoteAskTarget {
            node: RemoteNodeConfig {
                id: "separate-remote".into(),
                base_url: format!("http://{addr}"),
                token_env: "ASK_REMOTE_TOKEN".into(),
                labels: None,
            },
            secret: "test-secret".into(),
            workspace_mission_id: Uuid::new_v4(),
            cwd_override: None,
            display_cwd: remote_work.path().to_string_lossy().into_owned(),
            live: true,
        };

        let abandoned_remote = remote_tmp.path().join("ask-sandbox-abandoned");
        let abandoned_lock = sandbox_lock_path(&abandoned_remote);
        tokio::fs::create_dir_all(abandoned_remote.join("sub"))
            .await
            .unwrap();
        tokio::fs::write(abandoned_remote.join("sub/leaked.txt"), "stale")
            .await
            .unwrap();
        tokio::fs::write(&abandoned_lock, "ask-remote-lease\n")
            .await
            .unwrap();
        let orphan_lock = remote_tmp.path().join("ask-sandbox-orphan-remote.lock");
        tokio::fs::write(&orphan_lock, "ask-remote-lease\n")
            .await
            .unwrap();
        let age_out = std::process::Command::new("python3")
            .args([
                "-c",
                "import os, sys; os.utime(sys.argv[1], (1577836800, 1577836800), follow_symlinks=False); os.utime(sys.argv[2], (1577836800, 1577836800), follow_symlinks=False)",
            ])
            .arg(&abandoned_lock)
            .arg(&orphan_lock)
            .status()
            .unwrap();
        assert!(age_out.success());

        let symlink_victim = remote_tmp.path().join("victim.txt");
        tokio::fs::write(&symlink_victim, "keep-victim")
            .await
            .unwrap();
        #[cfg(unix)]
        {
            let symlink_sandbox = remote_tmp.path().join("ask-sandbox-symlink-remote");
            tokio::fs::create_dir_all(&symlink_sandbox).await.unwrap();
            std::os::unix::fs::symlink(&symlink_victim, sandbox_lock_path(&symlink_sandbox))
                .unwrap();
        }

        let guard = prepare_remote_sandbox_in(&target, core_tmp.path())
            .await
            .expect("remote sandbox should be prepared");
        let name = guard.path().file_name().unwrap();
        let remote_sandbox = remote_tmp.path().join(name);
        let remote_lock = sandbox_lock_path(&remote_sandbox);

        assert!(!abandoned_remote.exists());
        assert!(!abandoned_lock.exists());
        assert!(!orphan_lock.exists());
        assert_eq!(
            std::fs::read_to_string(&symlink_victim).unwrap(),
            "keep-victim"
        );
        assert!(remote_sandbox.join("remote.txt").exists());
        assert!(remote_lock.exists());
        assert!(!live_sandboxes()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains_key(&remote_sandbox));

        let guard2 = prepare_remote_sandbox_in(&target, core_tmp.path())
            .await
            .expect("second remote sandbox should be prepared while first is live");
        assert!(
            remote_sandbox.join("remote.txt").exists(),
            "active heartbeated remote sandbox must survive remote target GC sweep"
        );
        assert!(remote_lock.exists());
        guard2.cleanup().await;

        gc_stale_sandboxes_with_observer(remote_tmp.path(), &HashSet::new(), |_| {});
        assert!(
            remote_sandbox.join("remote.txt").exists(),
            "remote lease marker must protect remote sandbox from unshared-filesystem GC"
        );
        assert!(remote_lock.exists());

        guard.cleanup().await;
        assert!(!remote_sandbox.exists());
        assert!(!remote_lock.exists());
        assert!(core_tmp.path().read_dir().unwrap().count() == 0);
        server.abort();
    }

    #[test]
    fn sandbox_guard_dropped_outside_tokio_runtime_cleans_up_without_leak() {
        let ws_root = tempfile::tempdir().unwrap();
        std::fs::write(ws_root.path().join("sync.txt"), "no-runtime").unwrap();
        let exec = WorkspaceExec::new(crate::workspace::Workspace::default_host(
            ws_root.path().to_path_buf(),
        ));

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let guard = rt
            .block_on(prepare_sandbox(&exec, ws_root.path()))
            .expect("sandbox prepared");
        drop(rt);
        assert!(tokio::runtime::Handle::try_current().is_err());

        let sandbox_path = guard.path().to_path_buf();
        let lock_path = sandbox_lock_path(&sandbox_path);
        assert!(sandbox_path.join("sync.txt").exists());
        assert!(lock_path.exists());

        drop(guard);
        for _ in 0..100 {
            if !sandbox_path.exists()
                && !lock_path.exists()
                && !live_sandboxes()
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .contains_key(&sandbox_path)
            {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }

        assert!(!sandbox_path.exists());
        assert!(!lock_path.exists());
        assert!(!live_sandboxes()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains_key(&sandbox_path));
    }

    #[cfg(unix)]
    #[test]
    fn remote_sandbox_lease_reads_are_idempotent_across_calls() {
        let dir = tempfile::tempdir().unwrap();
        let lease_path = dir.path().join("ask-sandbox-lease.lock");
        std::fs::write(&lease_path, "ask-remote-lease\n").unwrap();
        let file = std::fs::File::open(&lease_path).unwrap();
        assert!(remote_sandbox_lease_is_live(&file));
        assert!(remote_sandbox_lease_is_live(&file));
        assert!(remote_sandbox_lease_is_live(&file));

        let plain_path = dir.path().join("ask-sandbox-plain.lock");
        std::fs::write(&plain_path, "").unwrap();
        let plain = std::fs::File::open(&plain_path).unwrap();
        assert!(!remote_sandbox_lease_is_live(&plain));
        assert!(!remote_sandbox_lease_is_live(&plain));
    }

    #[cfg(unix)]
    #[test]
    fn local_lock_and_gc_reject_symlinks_without_touching_victim() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let victim = dir.path().join("victim.txt");
        std::fs::write(&victim, "untouched-secret").unwrap();
        std::fs::set_permissions(&victim, std::fs::Permissions::from_mode(0o600)).unwrap();

        let sandbox = dir.path().join("ask-sandbox-symlink-local");
        std::fs::create_dir_all(&sandbox).unwrap();
        let lock_path = sandbox_lock_path(&sandbox);
        std::os::unix::fs::symlink(&victim, &lock_path).unwrap();

        assert!(acquire_sandbox_lock(&sandbox).is_err());
        assert!(try_lock_stale_sandbox_for_gc(&lock_path).is_none());
        gc_stale_sandboxes_with_observer(dir.path(), &HashSet::new(), |_| {});

        assert!(sandbox.exists());
        assert_eq!(
            std::fs::read_to_string(&victim).unwrap(),
            "untouched-secret"
        );
        assert_eq!(
            std::fs::metadata(&victim).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[cfg(unix)]
    #[test]
    fn remote_lease_setup_and_refresh_reject_symlink_attacks_and_preserve_victim() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let dir = tempfile::tempdir().unwrap();
        let victim = dir.path().join("victim.txt");
        std::fs::write(&victim, "victim-original").unwrap();
        std::fs::set_permissions(&victim, std::fs::Permissions::from_mode(0o600)).unwrap();
        let victim_mtime_before = std::fs::metadata(&victim).unwrap().mtime();

        let pre_symlink_sandbox = dir.path().join("ask-sandbox-pre-symlink");
        let pre_symlink_lock = sandbox_lock_path(&pre_symlink_sandbox);
        std::os::unix::fs::symlink(&victim, &pre_symlink_lock).unwrap();
        let pre_cmd = remote_sandbox_lease_command(
            &pre_symlink_lock.to_string_lossy(),
            Some("mkdir -p -- \"$s\""),
        );
        let pre_out = std::process::Command::new("/bin/bash")
            .arg("-lc")
            .arg(&pre_cmd)
            .env("s", &pre_symlink_sandbox)
            .output()
            .unwrap();
        assert!(!pre_out.status.success());
        assert!(!pre_symlink_sandbox.exists());

        let swap_sandbox = dir.path().join("ask-sandbox-mid-swap");
        let swap_lock = sandbox_lock_path(&swap_sandbox);
        let swap_setup = format!(
            "mkdir -p -- \"$s\"; rm -f -- {l}; ln -s -- {v} {l}",
            l = single_quote(&swap_lock.to_string_lossy()),
            v = single_quote(&victim.to_string_lossy()),
        );
        let swap_cmd =
            remote_sandbox_lease_command(&swap_lock.to_string_lossy(), Some(&swap_setup));
        let swap_out = std::process::Command::new("/bin/bash")
            .arg("-lc")
            .arg(&swap_cmd)
            .env("s", &swap_sandbox)
            .output()
            .unwrap();
        assert!(!swap_out.status.success());

        let ok_sandbox = dir.path().join("ask-sandbox-valid");
        let ok_lock = sandbox_lock_path(&ok_sandbox);
        let ok_cmd = remote_sandbox_lease_command(
            &ok_lock.to_string_lossy(),
            Some("mkdir -p -- \"$s\"; printf 'ok' > \"$s/probe.txt\""),
        );
        let ok_out = std::process::Command::new("/bin/bash")
            .arg("-lc")
            .arg(&ok_cmd)
            .env("s", &ok_sandbox)
            .output()
            .unwrap();
        assert!(ok_out.status.success());
        assert_eq!(
            std::fs::read_to_string(&ok_lock).unwrap(),
            "ask-remote-lease\n"
        );
        assert_eq!(
            std::fs::metadata(&ok_lock).unwrap().permissions().mode() & 0o777,
            0o666
        );
        gc_stale_sandboxes_with_observer(dir.path(), &HashSet::new(), |_| {});
        assert!(ok_sandbox.join("probe.txt").exists());

        let old_ts = std::process::Command::new("python3")
            .args([
                "-c",
                "import os, sys, time; ts = int(time.time()) - 400; os.utime(sys.argv[1], (ts, ts), follow_symlinks=False)",
            ])
            .arg(&ok_lock)
            .status()
            .unwrap();
        assert!(old_ts.success());
        let stale_mtime = std::fs::metadata(&ok_lock).unwrap().mtime();

        let refresh_cmd = remote_sandbox_lease_command(&ok_lock.to_string_lossy(), None);
        let refresh_out = std::process::Command::new("/bin/bash")
            .arg("-lc")
            .arg(&refresh_cmd)
            .output()
            .unwrap();
        assert!(refresh_out.status.success());
        assert!(std::fs::metadata(&ok_lock).unwrap().mtime() > stale_mtime);

        gc_stale_sandboxes_with_observer(dir.path(), &HashSet::new(), |_| {});
        assert!(ok_sandbox.join("probe.txt").exists());
        assert!(ok_lock.exists());

        let expired_ts = std::process::Command::new("python3")
            .args([
                "-c",
                "import os, sys; os.utime(sys.argv[1], (1577836800, 1577836800), follow_symlinks=False)",
            ])
            .arg(&ok_lock)
            .status()
            .unwrap();
        assert!(expired_ts.success());

        gc_stale_sandboxes_with_observer(dir.path(), &HashSet::new(), |_| {});
        assert!(!ok_sandbox.exists());
        assert!(!ok_lock.exists());

        std::os::unix::fs::symlink(&victim, &ok_lock).unwrap();
        let symlink_refresh_out = std::process::Command::new("/bin/bash")
            .arg("-lc")
            .arg(&refresh_cmd)
            .output()
            .unwrap();
        assert!(!symlink_refresh_out.status.success());

        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "victim-original");
        let victim_meta = std::fs::metadata(&victim).unwrap();
        assert_eq!(victim_meta.permissions().mode() & 0o777, 0o600);
        assert_eq!(victim_meta.mtime(), victim_mtime_before);
    }

    #[tokio::test]
    async fn remote_sandbox_setup_fails_closed_when_python_probe_fails() {
        use crate::remote_node::{ExecuteResponse, LeaseRequest, RemoteNodeConfig};
        use axum::{routing::post, Json, Router};

        let root = tempfile::tempdir().unwrap();
        let app = Router::new().route(
            "/execute",
            post(|Json(req): Json<LeaseRequest>| async move {
                let rewritten = format!("python3() {{ return 1; }}; {}", req.command);
                let out = tokio::process::Command::new("/bin/bash")
                    .arg("-lc")
                    .arg(&rewritten)
                    .output()
                    .await
                    .unwrap();
                Json(ExecuteResponse {
                    accepted: true,
                    exit_code: out.status.code(),
                    stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
                    stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
                })
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        let target = RemoteAskTarget {
            node: RemoteNodeConfig {
                id: "no-python".into(),
                base_url: format!("http://{address}"),
                token_env: "ASK_TEST_TOKEN".into(),
                labels: None,
            },
            secret: "test-secret".into(),
            workspace_mission_id: Uuid::new_v4(),
            cwd_override: Some(root.path().to_string_lossy().into_owned()),
            display_cwd: root.path().to_string_lossy().into_owned(),
            live: false,
        };

        assert!(prepare_remote_sandbox_in(&target, root.path())
            .await
            .is_none());
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
        server.abort();
    }

    #[cfg(unix)]
    #[test]
    fn future_mtime_remote_sandbox_lease_is_reclaimed_by_same_host_and_remote_gc() {
        let set_mtime = |path: &Path, offset_secs: i64| {
            let status = std::process::Command::new("python3")
                .args([
                    "-c",
                    "import os, sys, time; ts = int(time.time()) + int(sys.argv[2]); os.utime(sys.argv[1], (ts, ts), follow_symlinks=False)",
                ])
                .arg(path)
                .arg(offset_secs.to_string())
                .status()
                .unwrap();
            assert!(status.success());
        };

        let local_root = tempfile::tempdir().unwrap();
        let future_local = local_root.path().join("ask-sandbox-future-local");
        let future_local_lock = sandbox_lock_path(&future_local);
        std::fs::create_dir_all(&future_local).unwrap();
        std::fs::write(future_local.join("probe.txt"), "future").unwrap();
        std::fs::write(&future_local_lock, "ask-remote-lease\n").unwrap();
        set_mtime(&future_local_lock, 3600);

        let future_orphan_lock = local_root
            .path()
            .join("ask-sandbox-future-orphan-local.lock");
        std::fs::write(&future_orphan_lock, "ask-remote-lease\n").unwrap();
        set_mtime(&future_orphan_lock, 3600);

        let within_ttl_local = local_root.path().join("ask-sandbox-within-ttl-local");
        let within_ttl_local_lock = sandbox_lock_path(&within_ttl_local);
        std::fs::create_dir_all(&within_ttl_local).unwrap();
        std::fs::write(within_ttl_local.join("probe.txt"), "live").unwrap();
        std::fs::write(&within_ttl_local_lock, "ask-remote-lease\n").unwrap();
        set_mtime(&within_ttl_local_lock, -120);

        let future_file = std::fs::File::open(&future_local_lock).unwrap();
        assert!(!remote_sandbox_lease_is_live(&future_file));
        drop(future_file);

        let within_ttl_file = std::fs::File::open(&within_ttl_local_lock).unwrap();
        assert!(remote_sandbox_lease_is_live(&within_ttl_file));
        drop(within_ttl_file);

        gc_stale_sandboxes_with_observer(local_root.path(), &HashSet::new(), |_| {});
        assert!(!future_local.exists());
        assert!(!future_local_lock.exists());
        assert!(!future_orphan_lock.exists());
        assert!(within_ttl_local.join("probe.txt").exists());
        assert!(within_ttl_local_lock.exists());

        let remote_root = tempfile::tempdir().unwrap();
        let future_remote = remote_root.path().join("ask-sandbox-future-remote");
        let future_remote_lock = sandbox_lock_path(&future_remote);
        std::fs::create_dir_all(&future_remote).unwrap();
        std::fs::write(future_remote.join("probe.txt"), "future").unwrap();
        std::fs::write(&future_remote_lock, "ask-remote-lease\n").unwrap();
        set_mtime(&future_remote_lock, 3600);

        let future_remote_orphan_lock = remote_root
            .path()
            .join("ask-sandbox-future-orphan-remote.lock");
        std::fs::write(&future_remote_orphan_lock, "ask-remote-lease\n").unwrap();
        set_mtime(&future_remote_orphan_lock, 3600);

        let within_ttl_remote = remote_root.path().join("ask-sandbox-within-ttl-remote");
        let within_ttl_remote_lock = sandbox_lock_path(&within_ttl_remote);
        std::fs::create_dir_all(&within_ttl_remote).unwrap();
        std::fs::write(within_ttl_remote.join("probe.txt"), "live").unwrap();
        std::fs::write(&within_ttl_remote_lock, "ask-remote-lease\n").unwrap();
        set_mtime(&within_ttl_remote_lock, -120);

        let gc_cmd = remote_sandbox_gc_command(&remote_root.path().to_string_lossy());
        let gc_out = std::process::Command::new("/bin/bash")
            .arg("-lc")
            .arg(&gc_cmd)
            .output()
            .unwrap();
        assert!(gc_out.status.success());
        assert!(!future_remote.exists());
        assert!(!future_remote_lock.exists());
        assert!(!future_remote_orphan_lock.exists());
        assert!(within_ttl_remote.join("probe.txt").exists());
        assert!(within_ttl_remote_lock.exists());
    }
}
