//! MCP runtime registry - manages connections and tool execution.
//!
//! Supports both HTTP and stdio transports:
//! - HTTP: JSON-RPC over HTTP POST requests
//! - Stdio: JSON-RPC over stdin/stdout with spawned child processes

use std::collections::HashMap;
use std::path::Path;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use dashmap::{DashMap, DashSet};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command};
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use super::config::McpConfigStore;
use super::types::*;
use crate::util::current_service_companion_binary_path;

/// MCP protocol version we support
const MCP_PROTOCOL_VERSION: &str = "2024-11-05";

/// Sanitize MCP server name to create a valid function name prefix.
///
/// Converts names like "filesystem" or "My Server" to lowercase alphanumeric.
fn sanitize_mcp_prefix(name: &str) -> String {
    name.chars()
        .filter(|c| c.is_alphanumeric() || *c == '_' || *c == '-')
        .collect::<String>()
        .to_lowercase()
        .replace('-', "_")
}

fn command_exists(command: &str) -> bool {
    if command.trim().is_empty() {
        return false;
    }

    let path = Path::new(command);
    if path.is_absolute() || command.contains('/') {
        return path.exists();
    }

    let Some(paths) = std::env::var_os("PATH") else {
        return false;
    };

    for dir in std::env::split_paths(&paths) {
        let candidate = dir.join(command);
        if candidate.is_file() {
            return true;
        }
        #[cfg(windows)]
        {
            for ext in ["exe", "cmd", "bat"] {
                if candidate.with_extension(ext).is_file() {
                    return true;
                }
            }
        }
    }

    false
}

fn is_builtin_workspace_mcp(config: &McpServerConfig, working_dir: &Path) -> bool {
    if config.name != "workspace" {
        return false;
    }

    let McpTransport::Stdio { command, args, .. } = &config.transport else {
        return false;
    };
    if !args.is_empty() {
        return false;
    }

    let command_path = Path::new(command);
    let scoped_workspace_mcp = current_service_companion_binary_path("workspace-mcp");
    command == "workspace-mcp"
        || command_path == Path::new("/usr/local/bin/workspace-mcp")
        || scoped_workspace_mcp
            .as_deref()
            .is_some_and(|path| command_path == path)
        || command_path == working_dir.join("target/release/workspace-mcp")
        || command_path == working_dir.join("target/debug/workspace-mcp")
}

/// Reconcile the implicit full-environment grant for the trusted built-in
/// workspace proxy. A config merely named `workspace` is not trusted: an
/// operator may have repointed it to an unrelated executable.
fn reconcile_workspace_mcp_env_trust(config: &mut McpServerConfig, working_dir: &Path) -> bool {
    if config.name != "workspace" {
        return false;
    }

    if is_builtin_workspace_mcp(config, working_dir) {
        if config.workspace_env_allowlist == ["*".to_string()] {
            return false;
        }
        config.workspace_env_allowlist = vec!["*".to_string()];
        return true;
    }

    let original_len = config.workspace_env_allowlist.len();
    config
        .workspace_env_allowlist
        .retain(|entry| entry.trim() != "*");
    config.workspace_env_allowlist.len() != original_len
}

const MCP_STDIO_CHANNEL_CAPACITY: usize = 64;
const MCP_STDIO_STDERR_LINE_CAP: usize = 4096;

enum McpStdioCommand {
    Request {
        id: u64,
        payload: String,
        resp_tx: oneshot::Sender<anyhow::Result<serde_json::Value>>,
    },
    Notify {
        payload: String,
    },
}

/// Lock-free handle to a per-server [`McpStdioActor`].
#[derive(Clone)]
struct McpStdioHandle {
    cmd_tx: mpsc::Sender<McpStdioCommand>,
    cancel_token: CancellationToken,
    generation: u64,
    stopped: CancellationToken,
}

impl McpStdioHandle {
    async fn request_with_timeout(
        &self,
        id: u64,
        payload: String,
        timeout: Duration,
    ) -> anyhow::Result<serde_json::Value> {
        let (resp_tx, resp_rx) = oneshot::channel();
        tokio::time::timeout(
            timeout,
            self.cmd_tx.send(McpStdioCommand::Request {
                id,
                payload,
                resp_tx,
            }),
        )
        .await
        .map_err(|_| anyhow::anyhow!("Timeout queueing MCP request"))?
        .map_err(|_| anyhow::anyhow!("MCP stdio actor closed"))?;

        match tokio::time::timeout(timeout, resp_rx).await {
            Ok(Ok(res)) => res,
            Ok(Err(_)) => anyhow::bail!("MCP process closed before responding"),
            Err(_) => anyhow::bail!("Timeout waiting for MCP response"),
        }
    }

    async fn request(&self, id: u64, payload: String) -> anyhow::Result<serde_json::Value> {
        self.request_with_timeout(id, payload, MCP_REQUEST_TIMEOUT)
            .await
    }

    async fn notify(&self, payload: String) -> anyhow::Result<()> {
        self.cmd_tx
            .send(McpStdioCommand::Notify { payload })
            .await
            .map_err(|_| anyhow::anyhow!("MCP stdio actor closed"))
    }

    /// Trigger immediate actor cancellation and process kill in nanoseconds
    /// without waiting on any in-flight tool calls.
    #[inline]
    fn kill(&self) {
        self.cancel_token.cancel();
    }

    async fn kill_and_wait(&self) -> anyhow::Result<()> {
        self.kill();
        tokio::time::timeout(MCP_STDIO_REAP_TIMEOUT, self.stopped.cancelled())
            .await
            .map_err(|_| anyhow::anyhow!("Timeout reaping MCP stdio process"))
    }
}

/// Drain an MCP server's stderr pipe with a bounded line buffer so even multi-MB
/// diagnostic output (>64 KB OS pipe buffer) can never deadlock the child process.
async fn drain_mcp_stderr(
    mut stderr: ChildStderr,
    server_label: String,
    cancel: CancellationToken,
) {
    let mut chunk = [0u8; 4096];
    let mut line_buf: Vec<u8> = Vec::with_capacity(512);
    loop {
        let read_res = tokio::select! {
            biased;
            _ = cancel.cancelled() => break,
            res = stderr.read(&mut chunk) => res,
        };
        match read_res {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                for &b in &chunk[..n] {
                    if b == b'\n' {
                        let line = String::from_utf8_lossy(&line_buf);
                        let trimmed = line.trim();
                        if !trimmed.is_empty() {
                            tracing::debug!(mcp = %server_label, stderr = %trimmed, "MCP stdio stderr");
                        }
                        line_buf.clear();
                    } else if line_buf.len() < MCP_STDIO_STDERR_LINE_CAP {
                        line_buf.push(b);
                    } else if line_buf.len() == MCP_STDIO_STDERR_LINE_CAP {
                        let line = String::from_utf8_lossy(&line_buf);
                        tracing::debug!(
                            mcp = %server_label,
                            stderr = %line,
                            "MCP stdio stderr (truncated chunk)"
                        );
                        line_buf.clear();
                    }
                }
            }
        }
    }
    if !line_buf.is_empty() {
        let line = String::from_utf8_lossy(&line_buf);
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            tracing::debug!(mcp = %server_label, stderr = %trimmed, "MCP stdio stderr");
        }
    }
}

fn extract_jsonrpc_id(value: &serde_json::Value) -> Option<u64> {
    value
        .get("id")
        .and_then(|v| v.as_u64().or_else(|| v.as_str()?.parse::<u64>().ok()))
}

fn dispatch_mcp_stdout_line(
    trimmed: &str,
    pending: &mut HashMap<u64, oneshot::Sender<anyhow::Result<serde_json::Value>>>,
) {
    if trimmed.is_empty() {
        return;
    }
    match serde_json::from_str::<serde_json::Value>(trimmed) {
        Ok(val) => {
            // Server notifications or server-initiated requests carry
            // a `method` field or lack a matching request `id`.
            let is_server_method = val.get("method").is_some();
            if !is_server_method {
                if let Some(req_id) = extract_jsonrpc_id(&val) {
                    if let Some(resp_tx) = pending.remove(&req_id) {
                        let outcome = if let Some(err_val) =
                            val.get("error").filter(|v| !v.is_null())
                        {
                            if let Ok(err) = serde_json::from_value::<JsonRpcError>(err_val.clone())
                            {
                                Err(anyhow::anyhow!(
                                    "JSON-RPC error {}: {}",
                                    err.code,
                                    err.message
                                ))
                            } else {
                                Err(anyhow::anyhow!("JSON-RPC error: {}", err_val))
                            }
                        } else if let Some(result) = val.get("result") {
                            Ok(result.clone())
                        } else {
                            Err(anyhow::anyhow!("No result in response"))
                        };
                        let _ = resp_tx.send(outcome);
                    } else {
                        tracing::debug!(
                            id = req_id,
                            "Ignoring MCP stdio response for unknown or expired id"
                        );
                    }
                }
            } else {
                tracing::debug!("Ignoring server-initiated MCP stdio message");
            }
        }
        Err(err) => {
            tracing::debug!(
                error = %err,
                "Ignoring non-JSON line on MCP stdio stdout"
            );
        }
    }
}

/// Per-server actor owning `Child`, `ChildStdin`, and `BufReader<ChildStdout>`.
/// Multiplexes JSON-RPC responses by `"id"` while ignoring server notifications.
async fn run_mcp_stdio_actor(
    mut child: Child,
    mut stdin: ChildStdin,
    stdout: ChildStdout,
    stderr_task: Option<tokio::task::JoinHandle<()>>,
    mut cmd_rx: mpsc::Receiver<McpStdioCommand>,
    cancel_token: CancellationToken,
) -> String {
    let mut stdout_reader = BufReader::new(stdout);
    let mut line = String::new();
    let mut pending: HashMap<u64, oneshot::Sender<anyhow::Result<serde_json::Value>>> =
        HashMap::new();
    let mut child_exited: Option<std::io::Result<std::process::ExitStatus>> = None;

    let exit_reason: &'static str = loop {
        tokio::select! {
            biased;
            _ = cancel_token.cancelled() => {
                break "MCP server killed";
            }
            read_res = stdout_reader.read_line(&mut line) => {
                match read_res {
                    Ok(0) => break "MCP process closed stdout",
                    Ok(_) => {
                        dispatch_mcp_stdout_line(line.trim(), &mut pending);
                        line.clear();
                    }
                    Err(err) => {
                        for (_, tx) in pending.drain() {
                            let _ = tx.send(Err(anyhow::anyhow!("Read error: {}", err)));
                        }
                        break "MCP stdout read error";
                    }
                }
            }
            status = child.wait() => {
                child_exited = Some(status);
                if !pending.is_empty() {
                    let drain_deadline = tokio::time::Instant::now() + Duration::from_millis(50);
                    while !pending.is_empty() {
                        let read_res = tokio::select! {
                            biased;
                            _ = cancel_token.cancelled() => break,
                            res = tokio::time::timeout_at(drain_deadline, stdout_reader.read_line(&mut line)) => {
                                match res {
                                    Ok(r) => r,
                                    Err(_) => break,
                                }
                            }
                        };
                        match read_res {
                            Ok(0) | Err(_) => break,
                            Ok(_) => {
                                dispatch_mcp_stdout_line(line.trim(), &mut pending);
                                line.clear();
                            }
                        }
                    }
                }
                break "MCP child exited";
            }
            cmd = cmd_rx.recv() => {
                match cmd {
                    Some(McpStdioCommand::Request { id, payload, resp_tx }) => {
                        if pending.len() >= 64 {
                            pending.retain(|_, tx| !tx.is_closed());
                        }
                        let write_outcome = tokio::select! {
                            biased;
                            _ = cancel_token.cancelled() => {
                                let _ = resp_tx.send(Err(anyhow::anyhow!("MCP server killed")));
                                break "MCP server killed";
                            }
                            status = child.wait() => {
                                child_exited = Some(status);
                                let _ = resp_tx.send(Err(anyhow::anyhow!("MCP child exited")));
                                break "MCP child exited";
                            }
                            res = async {
                                stdin.write_all(payload.as_bytes()).await?;
                                stdin.write_all(b"\n").await?;
                                stdin.flush().await
                            } => res,
                        };
                        if let Err(err) = write_outcome {
                            let _ = resp_tx.send(Err(anyhow::anyhow!("Stdin write error: {}", err)));
                            break "MCP stdin write error";
                        }
                        pending.insert(id, resp_tx);
                    }
                    Some(McpStdioCommand::Notify { payload }) => {
                        let write_outcome = tokio::select! {
                            biased;
                            _ = cancel_token.cancelled() => {
                                break "MCP server killed";
                            }
                            status = child.wait() => {
                                child_exited = Some(status);
                                break "MCP child exited";
                            }
                            res = async {
                                stdin.write_all(payload.as_bytes()).await?;
                                stdin.write_all(b"\n").await?;
                                stdin.flush().await
                            } => res,
                        };
                        if let Err(err) = write_outcome {
                            tracing::debug!(error = %err, "MCP stdio notification write failed");
                            break "MCP stdin write error";
                        }
                    }
                    None => {
                        break "MCP stdio handle dropped";
                    }
                }
            }
        }
    };

    drop(stdin);
    drop(stdout_reader);
    cancel_token.cancel();
    for (_, tx) in pending.drain() {
        let _ = tx.send(Err(anyhow::anyhow!("{}", exit_reason)));
    }
    let exit_status = if let Some(wait_res) = child_exited {
        wait_res.ok()
    } else {
        match child.try_wait() {
            Ok(Some(status)) => Some(status),
            _ => {
                let _ = child.start_kill();
                tokio::time::timeout(MCP_STDIO_REAP_TIMEOUT, child.wait())
                    .await
                    .ok()
                    .and_then(Result::ok)
            }
        }
    };
    if let Some(task) = stderr_task {
        task.abort();
    }
    match exit_status {
        Some(status) => format!("{exit_reason} ({status})"),
        None => exit_reason.to_string(),
    }
}

/// Runtime registry for MCP servers.
pub struct McpRegistry {
    /// Persistent configuration store
    config_store: Arc<McpConfigStore>,
    /// Runtime state for each MCP (keyed by ID)
    states: Arc<DashMap<Uuid, McpServerState>>,
    /// HTTP client for HTTP MCP requests
    http_client: reqwest::Client,
    /// Stdio actor handles for stdio MCPs (keyed by ID)
    stdio_processes: Arc<DashMap<Uuid, McpStdioHandle>>,
    /// Latest published stdio process generation per MCP ID (fenced under `stdio_processes` entry lock)
    last_stdio_generations: Arc<DashMap<Uuid, u64>>,
    /// Disabled tools (by name)
    disabled_tools: DashSet<String>,
    /// Request ID counter for JSON-RPC
    request_id: AtomicU64,
    process_generation: AtomicU64,
}

const MCP_REQUEST_TIMEOUT: Duration = Duration::from_secs(600);
const MCP_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const MCP_STDIO_REAP_TIMEOUT: Duration = Duration::from_secs(2);

impl McpRegistry {
    /// Create a new MCP registry.
    pub async fn new(working_dir: &Path) -> Self {
        let config_store = Arc::new(McpConfigStore::new(working_dir).await);

        // Initialize states from configs
        let mut configs = config_store.list().await;
        configs = Self::ensure_defaults(&config_store, configs, working_dir).await;
        let states = DashMap::new();
        for config in configs {
            states.insert(config.id, McpServerState::from_config(config));
        }

        // Use generous timeouts for long-running MCP tools (e.g., Minecraft launches)
        let http_client = reqwest::Client::builder()
            .timeout(MCP_REQUEST_TIMEOUT)
            .connect_timeout(MCP_CONNECT_TIMEOUT)
            .build()
            .unwrap_or_default();

        Self {
            config_store,
            states: Arc::new(states),
            http_client,
            stdio_processes: Arc::new(DashMap::new()),
            last_stdio_generations: Arc::new(DashMap::new()),
            disabled_tools: DashSet::new(),
            request_id: AtomicU64::new(1),
            process_generation: AtomicU64::new(1),
        }
    }

    /// Return the raw MCP configs (for workspace opencode.json generation).
    pub async fn list_configs(&self) -> Vec<McpServerConfig> {
        self.config_store.list().await
    }

    fn default_configs(working_dir: &Path) -> Vec<McpServerConfig> {
        let mut desktop_env = HashMap::new();
        if let Ok(res) = std::env::var("DESKTOP_RESOLUTION") {
            if !res.trim().is_empty() {
                desktop_env.insert("DESKTOP_RESOLUTION".to_string(), res);
            }
        } else {
            desktop_env.insert("DESKTOP_RESOLUTION".to_string(), "1920x1080".to_string());
        }

        let desktop_command = {
            let release = working_dir
                .join("target")
                .join("release")
                .join("desktop-mcp");
            let debug = working_dir.join("target").join("debug").join("desktop-mcp");
            if release.exists() {
                release.to_string_lossy().to_string()
            } else if debug.exists() {
                debug.to_string_lossy().to_string()
            } else {
                "desktop-mcp".to_string()
            }
        };
        let mut desktop = McpServerConfig::new_stdio(
            "desktop".to_string(),
            desktop_command,
            Vec::new(),
            desktop_env,
        );
        desktop.scope = McpScope::Workspace;
        desktop.default_enabled = true;

        let workspace_command = {
            let release = working_dir
                .join("target")
                .join("release")
                .join("workspace-mcp");
            let debug = working_dir
                .join("target")
                .join("debug")
                .join("workspace-mcp");
            if release.exists() {
                release.to_string_lossy().to_string()
            } else if debug.exists() {
                debug.to_string_lossy().to_string()
            } else {
                "workspace-mcp".to_string()
            }
        };
        let mut workspace = McpServerConfig::new_stdio(
            "workspace".to_string(),
            workspace_command,
            Vec::new(),
            HashMap::new(),
        );
        workspace.scope = McpScope::Workspace;
        workspace.default_enabled = true;
        // workspace-mcp is a trusted compatibility shell/file proxy. It needs
        // the same environment as the workspace commands it executes. Native
        // harness bash remains the default for ordinary missions.
        workspace.workspace_env_allowlist = vec!["*".to_string()];
        // Prefer bunx (Bun) when present, but fall back to npx for compatibility.
        let js_runner = if command_exists("bunx") {
            "bunx"
        } else {
            "npx"
        };
        let mut playwright = McpServerConfig::new_stdio(
            "playwright".to_string(),
            js_runner.to_string(),
            vec![
                "@playwright/mcp@latest".to_string(),
                "--headless".to_string(),
                "--isolated".to_string(),
                "--no-sandbox".to_string(),
            ],
            HashMap::new(),
        );
        playwright.scope = McpScope::Workspace;
        playwright.default_enabled = true;

        let orchestrator_command = {
            let release = working_dir
                .join("target")
                .join("release")
                .join("sandboxed-mcp");
            let debug = working_dir
                .join("target")
                .join("debug")
                .join("sandboxed-mcp");
            if release.exists() {
                release.to_string_lossy().to_string()
            } else if debug.exists() {
                debug.to_string_lossy().to_string()
            } else if let Some(scoped) =
                current_service_companion_binary_path("sandboxed-mcp").filter(|path| path.exists())
            {
                scoped.to_string_lossy().to_string()
            } else {
                "sandboxed-mcp".to_string()
            }
        };
        let mut orchestrator = McpServerConfig::new_stdio(
            "sandboxed".to_string(),
            orchestrator_command,
            Vec::new(),
            HashMap::new(),
        );
        orchestrator.scope = McpScope::Workspace;
        orchestrator.default_enabled = true;

        let automation_manager_command = std::env::var("AUTOMATION_MANAGER_MCP_BIN")
            .ok()
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| {
                let release = working_dir
                    .join("target")
                    .join("release")
                    .join("automation-manager-mcp");
                let debug = working_dir
                    .join("target")
                    .join("debug")
                    .join("automation-manager-mcp");
                if release.exists() {
                    release.to_string_lossy().to_string()
                } else if debug.exists() {
                    debug.to_string_lossy().to_string()
                } else {
                    "automation-manager-mcp".to_string()
                }
            });
        let mut automation_manager_env = HashMap::new();
        if let Ok(api_url) = std::env::var("API_URL") {
            if !api_url.trim().is_empty() {
                automation_manager_env.insert("API_URL".to_string(), api_url);
            }
        }
        let mut automation_manager = McpServerConfig::new_stdio(
            "automation-manager".to_string(),
            automation_manager_command,
            Vec::new(),
            automation_manager_env,
        );
        automation_manager.scope = McpScope::Workspace;
        automation_manager.default_enabled = false;

        let mut engram = McpServerConfig::new_stdio(
            "engram".to_string(),
            "engram".to_string(),
            vec!["mcp".to_string()],
            HashMap::new(),
        );
        engram.scope = McpScope::Workspace;
        engram.default_enabled = false;

        vec![
            workspace,
            desktop,
            playwright,
            orchestrator,
            automation_manager,
            engram,
        ]
    }

    async fn ensure_defaults(
        config_store: &McpConfigStore,
        mut configs: Vec<McpServerConfig>,
        working_dir: &Path,
    ) -> Vec<McpServerConfig> {
        fn resolve_local_binary(working_dir: &Path, name: &str) -> Option<String> {
            let release = working_dir.join("target").join("release").join(name);
            if release.exists() {
                return Some(release.to_string_lossy().to_string());
            }
            let debug = working_dir.join("target").join("debug").join(name);
            if debug.exists() {
                return Some(debug.to_string_lossy().to_string());
            }
            if let Some(scoped) =
                current_service_companion_binary_path(name).filter(|path| path.exists())
            {
                return Some(scoped.to_string_lossy().to_string());
            }
            None
        }

        // Retire the built-in orchestrator descriptor in the same rollout.
        // An unrelated user-configured executable with that name is preserved.
        for config in &mut configs {
            // The legacy automation control MCP requires a signing secret and
            // bypasses the executor role boundary. Keep custom executables,
            // but never revive the old built-in through persisted enablement.
            let legacy_automation = config.name == "automation-manager"
                && matches!(&config.transport, McpTransport::Stdio { command, .. }
                    if Path::new(command).file_name().and_then(|s| s.to_str())
                        .is_some_and(|s| matches!(s, "automation-manager-mcp" | "automation-manager-mcp-dev")));
            if legacy_automation {
                config.default_enabled = false;
                if let McpTransport::Stdio { env, .. } = &mut config.transport {
                    env.remove("JWT_SECRET");
                }
                let updated = config.clone();
                let _ = config_store
                    .update(config.id, move |entry| *entry = updated)
                    .await;
            }
            let builtin = config.name == "orchestrator"
                && matches!(&config.transport,
                McpTransport::Stdio { command, .. } if Path::new(command).file_name().and_then(|s|s.to_str()).is_some_and(|s|matches!(s,"orchestrator-mcp"|"orchestrator-mcp-dev")));
            if builtin {
                config.name = "sandboxed".into();
                if let McpTransport::Stdio { command, args, env } = &mut config.transport {
                    *command = resolve_local_binary(working_dir, "sandboxed-mcp")
                        .unwrap_or_else(|| "sandboxed-mcp".into());
                    *args = vec!["--profile".into(), "executor".into()];
                    for key in ["JWT_SECRET", "API_TOKEN", "SANDBOXED_API_TOKEN"] {
                        env.remove(key);
                    }
                }
                let updated = config.clone();
                let _ = config_store
                    .update(config.id, move |entry| *entry = updated)
                    .await;
            }
        }

        // Remove duplicate MCPs by name (keep the first one).
        // This handles corrupted configs where the same MCP name appears twice.
        let mut seen_names = std::collections::HashSet::new();
        let mut duplicates = Vec::new();
        for config in &configs {
            if !seen_names.insert(config.name.clone()) {
                duplicates.push(config.id);
                tracing::warn!(
                    "Removing duplicate MCP '{}' (id: {})",
                    config.name,
                    config.id
                );
            }
        }
        for dup_id in duplicates {
            let _ = config_store.remove(dup_id).await;
            configs.retain(|c| c.id != dup_id);
        }

        let defaults = Self::default_configs(working_dir);
        for config in defaults {
            if configs.iter().any(|c| c.name == config.name) {
                continue;
            }
            match config_store.add(config.clone()).await {
                Ok(saved) => configs.push(saved),
                Err(e) => tracing::warn!("Failed to add default MCP {}: {}", config.name, e),
            }
        }
        // Ensure Playwright MCP runs in isolated mode and without sandboxing
        // so it can launch browsers under root.
        for config in configs.iter_mut() {
            if config.name != "playwright" {
                continue;
            }

            if config.scope != McpScope::Workspace {
                config.scope = McpScope::Workspace;
                let id = config.id;
                let _ = config_store
                    .update(id, |c| {
                        c.scope = McpScope::Workspace;
                    })
                    .await;
            }

            let missing_flags: Vec<&str> = match &config.transport {
                McpTransport::Stdio { args, .. } => ["--headless", "--isolated", "--no-sandbox"]
                    .iter()
                    .copied()
                    .filter(|flag| !args.iter().any(|arg| arg == *flag))
                    .collect(),
                McpTransport::Http { .. } => Vec::new(),
            };

            if missing_flags.is_empty() {
                continue;
            }

            if let McpTransport::Stdio { args, .. } = &mut config.transport {
                for flag in &missing_flags {
                    args.push((*flag).to_string());
                }
            }

            let id = config.id;
            let _ = config_store
                .update(id, |c| {
                    if let McpTransport::Stdio { args, .. } = &mut c.transport {
                        for flag in ["--headless", "--isolated", "--no-sandbox"] {
                            if !args.iter().any(|arg| arg == flag) {
                                args.push(flag.to_string());
                            }
                        }
                    }
                })
                .await;
        }

        // Ensure workspace/desktop/orchestrator MCPs have correct scope (migrate old configs).
        // This must run even if the binary doesn't exist locally.
        for config in configs.iter_mut() {
            if !matches!(config.name.as_str(), "workspace" | "desktop" | "sandboxed") {
                continue;
            }

            if config.scope != McpScope::Workspace {
                config.scope = McpScope::Workspace;
                let id = config.id;
                let _ = config_store
                    .update(id, |c| {
                        c.scope = McpScope::Workspace;
                    })
                    .await;
            }
        }

        // Ensure built-in MCPs have default_enabled = true (migrate old configs).
        for config in configs.iter_mut() {
            if !matches!(
                config.name.as_str(),
                "workspace" | "desktop" | "playwright" | "sandboxed"
            ) {
                continue;
            }

            if !config.default_enabled {
                config.default_enabled = true;
                let id = config.id;
                let _ = config_store
                    .update(id, |c| {
                        c.default_enabled = true;
                    })
                    .await;
            }
        }

        // workspace-mcp is the only built-in compatibility proxy that needs
        // the full workspace environment for commands it executes. Persist
        // that trust decision explicitly so all other MCPs stay deny-by-default.
        for config in configs
            .iter_mut()
            .filter(|config| config.name == "workspace")
        {
            if reconcile_workspace_mcp_env_trust(config, working_dir) {
                let id = config.id;
                let allowlist = config.workspace_env_allowlist.clone();
                let _ = config_store
                    .update(id, move |c| {
                        c.workspace_env_allowlist = allowlist;
                    })
                    .await;
            }
        }

        // Prefer repo-local MCP binaries for workspace/desktop (debug or release),
        // so default configs work without installing to PATH.
        for config in configs.iter_mut() {
            let binary_name = match config.name.as_str() {
                "workspace" => Some("workspace-mcp"),
                "desktop" => Some("desktop-mcp"),
                "sandboxed" => Some("sandboxed-mcp"),
                _ => None,
            };

            let Some(binary_name) = binary_name else {
                continue;
            };
            let Some(resolved) = resolve_local_binary(working_dir, binary_name) else {
                continue;
            };

            if let McpTransport::Stdio { command, .. } = &mut config.transport {
                if command != &resolved {
                    *command = resolved.clone();
                    let id = config.id;
                    let _ = config_store
                        .update(id, |c| {
                            if let McpTransport::Stdio { command, .. } = &mut c.transport {
                                *command = resolved.clone();
                            }
                        })
                        .await;
                }
            }
        }

        configs
    }

    /// Get the next request ID for JSON-RPC
    fn next_request_id(&self) -> u64 {
        self.request_id.fetch_add(1, Ordering::SeqCst)
    }

    fn next_process_generation(&self) -> u64 {
        self.process_generation.fetch_add(1, Ordering::SeqCst)
    }

    async fn cleanup_failed_stdio_process(
        &self,
        id: Uuid,
        process: &McpStdioHandle,
        error: String,
    ) {
        {
            let entry = self.stdio_processes.entry(id);
            if let Some(mut state) = self.states.get_mut(&id) {
                let matches_latest_generation = self
                    .last_stdio_generations
                    .get(&id)
                    .is_some_and(|g| *g == process.generation);
                if matches_latest_generation
                    && state.config.enabled
                    && state.status != McpStatus::Disabled
                {
                    state.status = McpStatus::Error;
                    state.error = Some(error);
                }
            }
            if let dashmap::mapref::entry::Entry::Occupied(occ) = entry {
                if occ.get().generation == process.generation {
                    occ.remove();
                }
            }
        }
        if let Err(error) = process.kill_and_wait().await {
            tracing::warn!(%id, generation = process.generation, %error, "Failed to reap MCP stdio process");
        }
    }

    fn reconcile_stdio_exit(
        states: &DashMap<Uuid, McpServerState>,
        stdio_processes: &DashMap<Uuid, McpStdioHandle>,
        id: Uuid,
        generation: u64,
        exit_diagnostic: String,
    ) {
        if let dashmap::mapref::entry::Entry::Occupied(entry) = stdio_processes.entry(id) {
            if entry.get().generation != generation {
                return;
            }
            if let Some(mut state) = states.get_mut(&id) {
                if state.config.enabled && state.status != McpStatus::Disabled {
                    state.status = McpStatus::Error;
                    state.error = Some(exit_diagnostic);
                }
            }
            entry.remove();
        }
    }

    /// Send a JSON-RPC request via HTTP
    async fn send_jsonrpc_http(
        &self,
        endpoint: &str,
        method: &str,
        params: Option<serde_json::Value>,
        headers: &HashMap<String, String>,
    ) -> anyhow::Result<serde_json::Value> {
        let request = JsonRpcRequest::new(self.next_request_id(), method, params);

        let mut req_builder = self
            .http_client
            .post(endpoint)
            .header("Content-Type", "application/json");

        // Add custom headers
        for (key, value) in headers {
            req_builder = req_builder.header(key.as_str(), value.as_str());
        }

        let response = req_builder.json(&request).send().await?;

        if !response.status().is_success() {
            anyhow::bail!("HTTP {}", response.status());
        }

        let json_response: JsonRpcResponse = response.json().await?;

        if let Some(error) = json_response.error {
            anyhow::bail!("JSON-RPC error {}: {}", error.code, error.message);
        }

        json_response
            .result
            .ok_or_else(|| anyhow::anyhow!("No result in response"))
    }

    async fn send_jsonrpc_stdio_with_timeout(
        &self,
        process: &McpStdioHandle,
        method: &str,
        params: Option<serde_json::Value>,
        timeout: Duration,
    ) -> anyhow::Result<serde_json::Value> {
        let id = self.next_request_id();
        let request = JsonRpcRequest::new(id, method, params);
        let request_json = serde_json::to_string(&request)?;
        process
            .request_with_timeout(id, request_json, timeout)
            .await
    }

    async fn send_jsonrpc_stdio(
        &self,
        process: &McpStdioHandle,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> anyhow::Result<serde_json::Value> {
        let id = self.next_request_id();
        let request = JsonRpcRequest::new(id, method, params);
        process.request(id, serde_json::to_string(&request)?).await
    }

    /// Spawn a stdio MCP process managed by a bounded per-server [`McpStdioActor`].
    /// Returns `Ok(None)` if the server was concurrently disabled or removed before
    /// the spawned process could be published into `stdio_processes`.
    async fn spawn_stdio_process(
        &self,
        id: Uuid,
        command: &str,
        args: &[String],
        env: &HashMap<String, String>,
    ) -> anyhow::Result<Option<McpStdioHandle>> {
        let mut cmd = Command::new(command);
        cmd.args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        // Add environment variables
        for (key, value) in env {
            cmd.env(key, value);
        }

        let mut child = cmd.spawn()?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow::anyhow!("Failed to capture stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow::anyhow!("Failed to capture stdout"))?;
        let stderr = child.stderr.take();

        let generation = self.next_process_generation();
        let cancel_token = CancellationToken::new();
        let stopped = CancellationToken::new();
        let server_label = command.to_string();
        let stderr_cancel = cancel_token.clone();
        let stderr_task = stderr
            .map(|err_pipe| tokio::spawn(drain_mcp_stderr(err_pipe, server_label, stderr_cancel)));

        let (cmd_tx, cmd_rx) = mpsc::channel(MCP_STDIO_CHANNEL_CAPACITY);
        let actor_cancel = cancel_token.clone();
        let actor_stopped = stopped.clone();
        let states = Arc::downgrade(&self.states);
        let stdio_processes = Arc::downgrade(&self.stdio_processes);
        let handle = McpStdioHandle {
            cmd_tx,
            cancel_token,
            generation,
            stopped,
        };
        tokio::spawn(async move {
            let exit_diagnostic =
                run_mcp_stdio_actor(child, stdin, stdout, stderr_task, cmd_rx, actor_cancel).await;
            if let (Some(states), Some(stdio_processes)) =
                (states.upgrade(), stdio_processes.upgrade())
            {
                Self::reconcile_stdio_exit(
                    &states,
                    &stdio_processes,
                    id,
                    generation,
                    exit_diagnostic,
                );
            }
            actor_stopped.cancel();
        });

        let (published, superseded) = {
            let entry = self.stdio_processes.entry(id);
            let active = self
                .states
                .get(&id)
                .is_some_and(|s| s.config.enabled && s.status != McpStatus::Disabled);
            if active {
                self.last_stdio_generations.insert(id, generation);
                let prev = match entry {
                    dashmap::mapref::entry::Entry::Occupied(mut occ) => {
                        Some(occ.insert(handle.clone()))
                    }
                    dashmap::mapref::entry::Entry::Vacant(vac) => {
                        vac.insert(handle.clone());
                        None
                    }
                };
                (true, prev)
            } else {
                (false, None)
            }
        };
        if let Some(prev) = superseded {
            prev.kill();
        }

        if !published {
            if let Err(error) = handle.kill_and_wait().await {
                tracing::warn!(
                    %id,
                    generation = handle.generation,
                    %error,
                    "Failed to reap unpublished MCP stdio process"
                );
            }
            return Ok(None);
        }

        Ok(Some(handle))
    }

    /// Initialize connection with an MCP server (HTTP)
    async fn initialize_mcp_http(
        &self,
        endpoint: &str,
        headers: &HashMap<String, String>,
    ) -> anyhow::Result<InitializeResult> {
        let params = InitializeParams {
            protocol_version: MCP_PROTOCOL_VERSION.to_string(),
            capabilities: ClientCapabilities::default(),
            client_info: ClientInfo {
                name: "open-agent".to_string(),
                version: env!("CARGO_PKG_VERSION").to_string(),
            },
        };

        let result = self
            .send_jsonrpc_http(
                endpoint,
                "initialize",
                Some(serde_json::to_value(params)?),
                headers,
            )
            .await?;

        let init_result: InitializeResult = serde_json::from_value(result)?;

        // Send initialized notification (no response expected, but some servers require it)
        let mut req_builder = self
            .http_client
            .post(endpoint)
            .header("Content-Type", "application/json");

        for (key, value) in headers {
            req_builder = req_builder.header(key.as_str(), value.as_str());
        }

        let _ = req_builder
            .json(&serde_json::json!({
                "jsonrpc": "2.0",
                "method": "notifications/initialized"
            }))
            .send()
            .await;

        Ok(init_result)
    }

    /// Initialize connection with an MCP server (stdio)
    async fn initialize_mcp_stdio(
        &self,
        process: &McpStdioHandle,
    ) -> anyhow::Result<InitializeResult> {
        let params = InitializeParams {
            protocol_version: MCP_PROTOCOL_VERSION.to_string(),
            capabilities: ClientCapabilities::default(),
            client_info: ClientInfo {
                name: "open-agent".to_string(),
                version: env!("CARGO_PKG_VERSION").to_string(),
            },
        };

        let result = self
            .send_jsonrpc_stdio_with_timeout(
                process,
                "initialize",
                Some(serde_json::to_value(params)?),
                MCP_CONNECT_TIMEOUT,
            )
            .await?;

        let init_result: InitializeResult = serde_json::from_value(result)?;

        let notification = serde_json::json!({
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        });
        let notification_json = serde_json::to_string(&notification)?;
        process.notify(notification_json).await?;

        Ok(init_result)
    }

    /// List all MCP servers with their current state.
    pub async fn list(&self) -> Vec<McpServerState> {
        self.states
            .iter()
            .map(|entry| entry.value().clone())
            .collect()
    }

    /// Get a specific MCP server state.
    pub async fn get(&self, id: Uuid) -> Option<McpServerState> {
        self.states.get(&id).map(|entry| entry.value().clone())
    }

    /// Add a new MCP server.
    /// Note: This does NOT automatically attempt to connect. Use refresh() after adding.
    pub async fn add(&self, req: AddMcpRequest) -> anyhow::Result<McpServerState> {
        let mut config = match &req.transport {
            McpTransport::Http { endpoint, .. } => {
                McpServerConfig::new(req.name.clone(), endpoint.clone())
            }
            McpTransport::Stdio { command, args, env } => McpServerConfig::new_stdio(
                req.name.clone(),
                command.clone(),
                args.clone(),
                env.clone(),
            ),
        };
        config.description = req.description;
        if let Some(scope) = req.scope {
            config.scope = scope;
        }
        if let Some(default_enabled) = req.default_enabled {
            config.default_enabled = default_enabled;
        }
        config.workspace_env_allowlist = req.workspace_env_allowlist;

        // Save to persistent store
        let config = self.config_store.add(config).await?;
        let id = config.id;

        // Create runtime state
        let state = McpServerState::from_config(config.clone());

        // Add to states
        self.states.insert(id, state.clone());

        // Return immediately - user should call refresh() to connect
        Ok(state)
    }

    /// Remove an MCP server.
    pub async fn remove(&self, id: Uuid) -> anyhow::Result<()> {
        // Atomically detach any active stdio handle and fence runtime state under
        // stdio_processes -> states -> last_stdio_generations lock order BEFORE
        // awaiting config_store I/O so concurrent refresh/spawn tasks immediately
        // observe removal and cannot resolve Ok(...) with stale state.
        let (detached_handle, prev_state, prev_generation) = {
            let entry = self.stdio_processes.entry(id);
            let removed_state = self.states.remove(&id).map(|(_, s)| s);
            let removed_gen = self.last_stdio_generations.remove(&id).map(|(_, g)| g);
            let handle = match entry {
                dashmap::mapref::entry::Entry::Occupied(occ) => Some(occ.remove()),
                dashmap::mapref::entry::Entry::Vacant(_) => None,
            };
            (handle, removed_state, removed_gen)
        };
        if let Some(handle) = detached_handle {
            handle.kill();
        }

        // Remove from persistent store; reconcile runtime state if persistence fails
        if let Err(err) = self.config_store.remove(id).await {
            let config_still_exists = self.config_store.get(id).await;
            if let Some(persisted_cfg) = config_still_exists {
                let entry = self.stdio_processes.entry(id);
                self.states.entry(id).or_insert_with(|| {
                    if let Some(gen) = prev_generation {
                        self.last_stdio_generations.entry(id).or_insert(gen);
                    }
                    if let Some(mut restored) = prev_state {
                        restored.config = persisted_cfg;
                        if restored.config.enabled {
                            restored.status = McpStatus::Disconnected;
                            restored.error = None;
                        } else {
                            restored.status = McpStatus::Disabled;
                            restored.error = None;
                        }
                        restored
                    } else {
                        McpServerState::from_config(persisted_cfg)
                    }
                });
                drop(entry);
            }
            return Err(err);
        }

        // Sweep under stdio_processes -> states -> last_stdio_generations lock order
        // in case a concurrent operation touched the maps while config_store was awaited.
        let late_handle = {
            let entry = self.stdio_processes.entry(id);
            self.states.remove(&id);
            self.last_stdio_generations.remove(&id);
            match entry {
                dashmap::mapref::entry::Entry::Occupied(occ) => Some(occ.remove()),
                dashmap::mapref::entry::Entry::Vacant(_) => None,
            }
        };
        if let Some(handle) = late_handle {
            handle.kill();
        }

        Ok(())
    }

    /// Enable an MCP server.
    /// Note: This does NOT automatically attempt to connect. Use refresh() after enabling.
    pub async fn enable(&self, id: Uuid) -> anyhow::Result<McpServerState> {
        // Update persistent config
        let config = self.config_store.enable(id).await?;

        // Update runtime state
        if let Some(mut state) = self.states.get_mut(&id) {
            state.config = config;
            state.status = McpStatus::Disconnected;
            state.error = None;
        }

        self.get(id)
            .await
            .ok_or_else(|| anyhow::anyhow!("MCP not found"))
    }

    /// Disable an MCP server.
    pub async fn disable(&self, id: Uuid) -> anyhow::Result<McpServerState> {
        // Fence runtime state to Disabled and detach stdio handle atomically under
        // stdio_processes -> states lock order BEFORE killing the actor or awaiting
        // config_store I/O so an in-flight refresh_stdio cannot observe enabled=true.
        let (detached_handle, prev_enabled_status) = {
            let entry = self.stdio_processes.entry(id);
            let prev = if let Some(mut state) = self.states.get_mut(&id) {
                let was_enabled = state.config.enabled;
                let prev_status = state.status;
                let prev_error = state.error.clone();
                state.config.enabled = false;
                state.status = McpStatus::Disabled;
                state.error = None;
                Some((was_enabled, prev_status, prev_error))
            } else {
                None
            };
            let handle = match entry {
                dashmap::mapref::entry::Entry::Occupied(occ) => Some(occ.remove()),
                dashmap::mapref::entry::Entry::Vacant(_) => None,
            };
            (handle, prev)
        };
        if let Some(ref handle) = detached_handle {
            handle.kill();
        }

        // Update persistent config; reconcile runtime state if persistence fails
        let config = match self.config_store.disable(id).await {
            Ok(config) => config,
            Err(err) => {
                if let Some(persisted_cfg) = self.config_store.get(id).await {
                    let entry = self.stdio_processes.entry(id);
                    if let Some(mut state) = self.states.get_mut(&id) {
                        state.config = persisted_cfg;
                        if state.config.enabled {
                            if detached_handle.is_some() {
                                state.status = McpStatus::Disconnected;
                                state.error = None;
                            } else if let Some((true, prev_status, prev_error)) =
                                prev_enabled_status
                            {
                                state.status = if prev_status == McpStatus::Connected {
                                    McpStatus::Disconnected
                                } else {
                                    prev_status
                                };
                                state.error = prev_error;
                            } else {
                                state.status = McpStatus::Disconnected;
                                state.error = None;
                            }
                        } else {
                            state.status = McpStatus::Disabled;
                            state.error = None;
                        }
                    }
                    drop(entry);
                }
                return Err(err);
            }
        };

        // Reconcile runtime state under stdio_processes -> states lock order so an
        // in-flight spawn_stdio_process cannot leave a live handle while Disabled.
        let late_handle = {
            let entry = self.stdio_processes.entry(id);
            if let Some(mut state) = self.states.get_mut(&id) {
                state.config = config;
                state.status = McpStatus::Disabled;
                state.error = None;
            }
            match entry {
                dashmap::mapref::entry::Entry::Occupied(occ) => Some(occ.remove()),
                dashmap::mapref::entry::Entry::Vacant(_) => None,
            }
        };
        if let Some(handle) = late_handle {
            handle.kill();
        }

        self.get(id)
            .await
            .ok_or_else(|| anyhow::anyhow!("MCP not found"))
    }

    /// Update an MCP server configuration (name, description, transport/env).
    /// Note: If transport changes, a refresh is recommended.
    pub async fn update(
        &self,
        id: Uuid,
        req: super::types::UpdateMcpRequest,
    ) -> anyhow::Result<McpServerState> {
        // Fence runtime state and detach existing stdio process under
        // stdio_processes -> states lock order BEFORE killing the actor or awaiting
        // config_store I/O if transport might change or MCP is being disabled.
        let (detached_handle, prev_enabled_status) =
            if req.transport.is_some() || req.enabled == Some(false) {
                let entry = self.stdio_processes.entry(id);
                let prev = if let Some(mut state) = self.states.get_mut(&id) {
                    let was_enabled = state.config.enabled;
                    let prev_status = state.status;
                    let prev_error = state.error.clone();
                    if req.enabled == Some(false) {
                        state.config.enabled = false;
                        state.status = McpStatus::Disabled;
                        state.error = None;
                    } else if state.config.enabled && state.status != McpStatus::Disabled {
                        state.status = McpStatus::Disconnected;
                        state.error = None;
                    }
                    Some((was_enabled, prev_status, prev_error))
                } else {
                    None
                };
                let handle = match entry {
                    dashmap::mapref::entry::Entry::Occupied(occ) => Some(occ.remove()),
                    dashmap::mapref::entry::Entry::Vacant(_) => None,
                };
                (handle, prev)
            } else {
                (None, None)
            };
        if let Some(ref handle) = detached_handle {
            handle.kill();
        }

        // Update persistent config; reconcile runtime state if persistence fails
        let config = match self
            .config_store
            .update(id, |c| {
                if let Some(name) = &req.name {
                    c.name = name.clone();
                }
                if let Some(description) = &req.description {
                    c.description = Some(description.clone());
                }
                if let Some(enabled) = req.enabled {
                    c.enabled = enabled;
                }
                if let Some(scope) = req.scope {
                    c.scope = scope;
                }
                if let Some(transport) = &req.transport {
                    c.transport = transport.clone();
                }
                if let Some(default_enabled) = req.default_enabled {
                    c.default_enabled = default_enabled;
                }
                if let Some(workspace_env_allowlist) = &req.workspace_env_allowlist {
                    c.workspace_env_allowlist = workspace_env_allowlist.clone();
                }
            })
            .await
        {
            Ok(config) => config,
            Err(err) => {
                if req.transport.is_some() || req.enabled == Some(false) {
                    if let Some(persisted_cfg) = self.config_store.get(id).await {
                        let entry = self.stdio_processes.entry(id);
                        if let Some(mut state) = self.states.get_mut(&id) {
                            state.config = persisted_cfg;
                            if state.config.enabled {
                                if detached_handle.is_some() {
                                    state.status = McpStatus::Disconnected;
                                    state.error = None;
                                } else if let Some((true, prev_status, prev_error)) =
                                    prev_enabled_status
                                {
                                    state.status = if prev_status == McpStatus::Connected {
                                        McpStatus::Disconnected
                                    } else {
                                        prev_status
                                    };
                                    state.error = prev_error;
                                } else {
                                    state.status = McpStatus::Disconnected;
                                    state.error = None;
                                }
                            } else {
                                state.status = McpStatus::Disabled;
                                state.error = None;
                            }
                        }
                        drop(entry);
                    }
                }
                return Err(err);
            }
        };

        // Update runtime state under stdio_processes -> states lock order
        let late_handle = {
            let entry = self.stdio_processes.entry(id);
            if let Some(mut state) = self.states.get_mut(&id) {
                state.config = config;
                if !state.config.enabled {
                    state.status = McpStatus::Disabled;
                    state.error = None;
                } else if req.transport.is_some()
                    || (req.enabled == Some(true) && state.status == McpStatus::Disabled)
                {
                    state.status = McpStatus::Disconnected;
                    state.error = None;
                }
            }
            if req.transport.is_some() || req.enabled == Some(false) {
                match entry {
                    dashmap::mapref::entry::Entry::Occupied(occ) => Some(occ.remove()),
                    dashmap::mapref::entry::Entry::Vacant(_) => None,
                }
            } else {
                None
            }
        };
        if let Some(handle) = late_handle {
            handle.kill();
        }

        self.get(id)
            .await
            .ok_or_else(|| anyhow::anyhow!("MCP not found"))
    }

    /// Helper to update state with error without overwriting a concurrently disabled server.
    async fn update_state_error(&self, id: Uuid, error_msg: String) {
        if let Some(mut state) = self.states.get_mut(&id) {
            if state.config.enabled && state.status != McpStatus::Disabled {
                state.status = McpStatus::Error;
                state.error = Some(error_msg);
            }
        }
    }

    /// Helper to update state with success without overwriting a concurrently disabled server.
    async fn update_state_success(
        &self,
        id: Uuid,
        tool_descriptors: Vec<McpToolDescriptor>,
        server_version: Option<String>,
    ) {
        let tool_names: Vec<String> = tool_descriptors.iter().map(|t| t.name.clone()).collect();
        if let Some(mut state) = self.states.get_mut(&id) {
            if state.config.enabled && state.status != McpStatus::Disabled {
                state.config.tools = tool_names;
                state.config.tool_descriptors = tool_descriptors;
                state.config.version = server_version;
                state.config.last_connected_at = Some(chrono::Utc::now());
                state.status = McpStatus::Connected;
                state.error = None;
            }
        }
    }

    /// Refresh an MCP server - reconnect and discover tools.
    pub async fn refresh(&self, id: Uuid) -> anyhow::Result<McpServerState> {
        let state = self
            .get(id)
            .await
            .ok_or_else(|| anyhow::anyhow!("MCP not found"))?;

        if !state.config.enabled {
            return Ok(state);
        }

        match &state.config.transport {
            McpTransport::Http { endpoint, headers } => {
                self.refresh_http(id, endpoint.clone(), headers.clone())
                    .await
            }
            McpTransport::Stdio { command, args, env } => {
                self.refresh_stdio(id, command.clone(), args.clone(), env.clone())
                    .await
            }
        }
    }

    /// Refresh an HTTP MCP server
    async fn refresh_http(
        &self,
        id: Uuid,
        endpoint: String,
        headers: HashMap<String, String>,
    ) -> anyhow::Result<McpServerState> {
        let endpoint = endpoint.trim_end_matches('/').to_string();

        // Step 1: Initialize the MCP connection with JSON-RPC
        let init_result = match self.initialize_mcp_http(&endpoint, &headers).await {
            Ok(result) => result,
            Err(e) => {
                self.update_state_error(id, format!("Initialize failed: {}", e))
                    .await;
                return self
                    .get(id)
                    .await
                    .ok_or_else(|| anyhow::anyhow!("MCP not found"));
            }
        };

        // Extract server version if available
        let server_version = init_result
            .server_info
            .as_ref()
            .and_then(|s| s.version.clone());

        // Step 2: List tools using JSON-RPC
        match self
            .send_jsonrpc_http(&endpoint, "tools/list", None, &headers)
            .await
        {
            Ok(result) => {
                match serde_json::from_value::<McpToolsResponse>(result) {
                    Ok(tools_response) => {
                        let tool_descriptors = tools_response.tools;
                        let tool_names: Vec<String> =
                            tool_descriptors.iter().map(|t| t.name.clone()).collect();

                        // Update config with discovered tools
                        let _ = self
                            .config_store
                            .update(id, |c| {
                                if c.enabled {
                                    c.tools = tool_names.clone();
                                    c.tool_descriptors = tool_descriptors.clone();
                                    c.version = server_version.clone();
                                    c.last_connected_at = Some(chrono::Utc::now());
                                }
                            })
                            .await;

                        // Update runtime state
                        self.update_state_success(id, tool_descriptors, server_version)
                            .await;
                    }
                    Err(e) => {
                        self.update_state_error(id, format!("Failed to parse tools: {}", e))
                            .await;
                    }
                }
            }
            Err(e) => {
                self.update_state_error(id, format!("tools/list failed: {}", e))
                    .await;
            }
        }

        self.get(id)
            .await
            .ok_or_else(|| anyhow::anyhow!("MCP not found"))
    }

    /// Refresh a stdio MCP server
    async fn refresh_stdio(
        &self,
        id: Uuid,
        command: String,
        args: Vec<String>,
        env: HashMap<String, String>,
    ) -> anyhow::Result<McpServerState> {
        if let Some((_, handle)) = self.stdio_processes.remove(&id) {
            handle.kill();
        }

        let process = match self.spawn_stdio_process(id, &command, &args, &env).await {
            Ok(Some(p)) => p,
            Ok(None) => {
                return self
                    .get(id)
                    .await
                    .ok_or_else(|| anyhow::anyhow!("MCP not found"));
            }
            Err(e) => {
                self.update_state_error(id, format!("Failed to spawn process: {}", e))
                    .await;
                return self
                    .get(id)
                    .await
                    .ok_or_else(|| anyhow::anyhow!("MCP not found"));
            }
        };

        let init_result =
            match tokio::time::timeout(MCP_CONNECT_TIMEOUT, self.initialize_mcp_stdio(&process))
                .await
                .unwrap_or_else(|_| Err(anyhow::anyhow!("Initialize timeout")))
            {
                Ok(result) => result,
                Err(e) => {
                    let error = format!("Initialize failed: {e}");
                    self.cleanup_failed_stdio_process(id, &process, error).await;
                    return self
                        .get(id)
                        .await
                        .ok_or_else(|| anyhow::anyhow!("MCP not found"));
                }
            };

        // Extract server version if available
        let server_version = init_result
            .server_info
            .as_ref()
            .and_then(|s| s.version.clone());

        match self
            .send_jsonrpc_stdio_with_timeout(&process, "tools/list", None, MCP_CONNECT_TIMEOUT)
            .await
        {
            Ok(result) => match serde_json::from_value::<McpToolsResponse>(result) {
                Ok(tools_response) => {
                    let still_active_before_persist = {
                        let proc_guard = self.stdio_processes.get(&id);
                        proc_guard.is_some_and(|entry| entry.generation == process.generation)
                            && self.states.get(&id).is_some_and(|s| {
                                s.config.enabled && s.status != McpStatus::Disabled
                            })
                    };
                    if !still_active_before_persist {
                        self.cleanup_failed_stdio_process(
                            id,
                            &process,
                            "MCP stdio process exited or was superseded during refresh".to_string(),
                        )
                        .await;
                        return self
                            .get(id)
                            .await
                            .ok_or_else(|| anyhow::anyhow!("MCP not found"));
                    }

                    let tool_descriptors = tools_response.tools;
                    let tool_names: Vec<String> =
                        tool_descriptors.iter().map(|t| t.name.clone()).collect();

                    let _ = self
                        .config_store
                        .update(id, |c| {
                            if c.enabled {
                                c.tools = tool_names.clone();
                                c.tool_descriptors = tool_descriptors.clone();
                                c.version = server_version.clone();
                                c.last_connected_at = Some(chrono::Utc::now());
                            }
                        })
                        .await;

                    let transitioned = {
                        let proc_guard = self.stdio_processes.get(&id);
                        if proc_guard
                            .as_ref()
                            .is_some_and(|entry| entry.generation == process.generation)
                        {
                            if let Some(mut state) = self.states.get_mut(&id) {
                                if state.config.enabled && state.status != McpStatus::Disabled {
                                    state.config.tools = tool_names;
                                    state.config.tool_descriptors = tool_descriptors;
                                    state.config.version = server_version;
                                    state.config.last_connected_at = Some(chrono::Utc::now());
                                    state.status = McpStatus::Connected;
                                    state.error = None;
                                    true
                                } else {
                                    false
                                }
                            } else {
                                false
                            }
                        } else {
                            false
                        }
                    };

                    if !transitioned {
                        self.cleanup_failed_stdio_process(
                            id,
                            &process,
                            "MCP stdio process exited or was superseded during refresh".to_string(),
                        )
                        .await;
                    }
                }
                Err(e) => {
                    let error = format!("Failed to parse tools: {e}");
                    self.cleanup_failed_stdio_process(id, &process, error).await;
                }
            },
            Err(e) => {
                let error = format!("tools/list failed: {e}");
                self.cleanup_failed_stdio_process(id, &process, error).await;
            }
        }

        self.get(id)
            .await
            .ok_or_else(|| anyhow::anyhow!("MCP not found"))
    }

    /// Refresh all MCP servers concurrently.
    /// When `skip_workspace` is true, workspace-scoped MCPs (e.g. orchestrator)
    /// are skipped because they require per-mission context unavailable at startup.
    pub async fn refresh_all(&self, skip_workspace: bool) {
        let ids: Vec<Uuid> = self
            .states
            .iter()
            .filter(|entry| !skip_workspace || entry.value().config.scope != McpScope::Workspace)
            .map(|entry| *entry.key())
            .collect();

        // Refresh all MCPs concurrently using join_all
        let futures: Vec<_> = ids.iter().map(|id| self.refresh(*id)).collect();
        futures::future::join_all(futures).await;
    }

    /// Call a tool on an MCP server.
    pub async fn call_tool(
        &self,
        mcp_id: Uuid,
        tool_name: &str,
        arguments: serde_json::Value,
    ) -> anyhow::Result<String> {
        // Check if tool is disabled
        if self.disabled_tools.contains(tool_name) {
            anyhow::bail!("Tool {} is disabled", tool_name);
        }

        let state = self
            .get(mcp_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("MCP not found"))?;

        if !state.config.enabled {
            anyhow::bail!("MCP {} is disabled", state.config.name);
        }

        if state.status != McpStatus::Connected {
            anyhow::bail!("MCP {} is not connected", state.config.name);
        }

        let params = serde_json::json!({
            "name": tool_name,
            "arguments": arguments
        });

        let result = match &state.config.transport {
            McpTransport::Http { endpoint, headers } => {
                let endpoint = endpoint.trim_end_matches('/');
                self.send_jsonrpc_http(endpoint, "tools/call", Some(params), headers)
                    .await
            }
            McpTransport::Stdio { .. } => {
                // Clone the lightweight actor handle and drop the DashMap guard
                // immediately so zero locks are held across the 600s tool call.
                let process = self
                    .stdio_processes
                    .get(&mcp_id)
                    .map(|entry| entry.value().clone())
                    .ok_or_else(|| anyhow::anyhow!("No stdio process for MCP {}", mcp_id))?;
                self.send_jsonrpc_stdio(&process, "tools/call", Some(params))
                    .await
            }
        };

        match result {
            Ok(result) => {
                let response: McpCallToolResponse = serde_json::from_value(result)?;

                // Increment counters
                if let Some(mut state) = self.states.get_mut(&mcp_id) {
                    if response.is_error {
                        state.tool_errors += 1;
                    } else {
                        state.tool_calls += 1;
                    }
                }

                if response.is_error {
                    let error_text = response
                        .content
                        .iter()
                        .filter_map(|c| c.text.as_deref())
                        .collect::<Vec<_>>()
                        .join("\n");
                    anyhow::bail!("Tool error: {}", error_text);
                }

                // Combine text content
                let output = response
                    .content
                    .iter()
                    .filter_map(|c| c.text.as_deref())
                    .collect::<Vec<_>>()
                    .join("\n");

                Ok(output)
            }
            Err(e) => {
                // Increment error counter
                if let Some(mut state) = self.states.get_mut(&mcp_id) {
                    state.tool_errors += 1;
                }
                anyhow::bail!("Tool call failed: {}", e);
            }
        }
    }

    /// List all tools from all connected MCPs.
    ///
    /// Tool names are prefixed with the MCP server name to avoid conflicts
    /// with built-in tools (e.g., `filesystem_read_file` instead of `read_file`).
    pub async fn list_tools(&self) -> Vec<McpTool> {
        let mut tools = Vec::new();
        for entry in self.states.iter() {
            let state = entry.value();
            if state.config.enabled && state.status == McpStatus::Connected {
                // Derive prefix from MCP server name (sanitized for function names)
                let prefix = sanitize_mcp_prefix(&state.config.name);

                for descriptor in &state.config.tool_descriptors {
                    // Prefix tool name with MCP server name to avoid conflicts
                    let prefixed_name = format!("{}_{}", prefix, descriptor.name);
                    let prefixed_description =
                        format!("[{}] {}", state.config.name, descriptor.description);

                    tools.push(McpTool {
                        name: prefixed_name.clone(),
                        description: prefixed_description,
                        parameters_schema: descriptor.input_schema.clone(),
                        mcp_id: state.config.id,
                        enabled: !self.disabled_tools.contains(&descriptor.name)
                            && !self.disabled_tools.contains(&prefixed_name),
                    });
                }
            }
        }
        tools
    }

    /// Enable a tool.
    pub async fn enable_tool(&self, name: &str) {
        self.disabled_tools.remove(name);
    }

    /// Disable a tool.
    pub async fn disable_tool(&self, name: &str) {
        self.disabled_tools.insert(name.to_string());
    }

    /// Check if a tool is enabled.
    pub async fn is_tool_enabled(&self, name: &str) -> bool {
        !self.disabled_tools.contains(name)
    }

    /// Find a tool by name (prefixed) and return its MCP ID if found.
    ///
    /// Tool names should be in prefixed format (e.g., `filesystem_read_file`).
    pub async fn find_tool(&self, name: &str) -> Option<McpTool> {
        for entry in self.states.iter() {
            let state = entry.value();
            if state.config.enabled && state.status == McpStatus::Connected {
                let prefix = sanitize_mcp_prefix(&state.config.name);

                for descriptor in &state.config.tool_descriptors {
                    let prefixed_name = format!("{}_{}", prefix, descriptor.name);

                    if prefixed_name == name
                        && !self.disabled_tools.contains(&descriptor.name)
                        && !self.disabled_tools.contains(&prefixed_name)
                    {
                        return Some(McpTool {
                            name: prefixed_name,
                            description: format!(
                                "[{}] {}",
                                state.config.name, descriptor.description
                            ),
                            parameters_schema: descriptor.input_schema.clone(),
                            mcp_id: state.config.id,
                            enabled: true,
                        });
                    }
                }
            }
        }
        None
    }

    /// Get the original (unprefixed) tool name for an MCP call.
    ///
    /// When calling the MCP server, we need to use the original tool name.
    pub fn strip_prefix(prefixed_name: &str) -> String {
        // Find the first underscore and return everything after it
        if let Some(idx) = prefixed_name.find('_') {
            prefixed_name[idx + 1..].to_string()
        } else {
            prefixed_name.to_string()
        }
    }
}

impl Drop for McpRegistry {
    fn drop(&mut self) {
        for entry in self.stdio_processes.iter() {
            entry.value().kill();
        }
        self.stdio_processes.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_workspace_mcp_receives_full_workspace_environment() {
        let mut config = McpServerConfig::new_stdio(
            "workspace".to_string(),
            "/usr/local/bin/workspace-mcp".to_string(),
            Vec::new(),
            HashMap::new(),
        );

        assert!(reconcile_workspace_mcp_env_trust(
            &mut config,
            Path::new("/srv/sandboxed")
        ));
        assert_eq!(config.workspace_env_allowlist, ["*"]);
        assert!(!reconcile_workspace_mcp_env_trust(
            &mut config,
            Path::new("/srv/sandboxed")
        ));
    }

    #[test]
    fn repointed_workspace_mcp_loses_implicit_wildcard_grant() {
        let mut config = McpServerConfig::new_stdio(
            "workspace".to_string(),
            "/opt/third-party/server".to_string(),
            Vec::new(),
            HashMap::new(),
        );
        config.workspace_env_allowlist = vec!["PATH".to_string(), "*".to_string()];

        assert!(reconcile_workspace_mcp_env_trust(
            &mut config,
            Path::new("/srv/sandboxed")
        ));
        assert_eq!(config.workspace_env_allowlist, ["PATH"]);
        assert!(!reconcile_workspace_mcp_env_trust(
            &mut config,
            Path::new("/srv/sandboxed")
        ));
    }

    #[test]
    fn same_basename_at_an_unknown_path_is_not_trusted() {
        let mut config = McpServerConfig::new_stdio(
            "workspace".to_string(),
            "/opt/third-party/workspace-mcp".to_string(),
            Vec::new(),
            HashMap::new(),
        );
        config.workspace_env_allowlist = vec!["*".to_string()];

        assert!(reconcile_workspace_mcp_env_trust(
            &mut config,
            Path::new("/srv/sandboxed")
        ));
        assert!(config.workspace_env_allowlist.is_empty());
    }

    #[tokio::test]
    async fn stdio_actor_drains_large_stderr_multiplexes_ids_and_kills_instantly() {
        let dir = tempfile::tempdir().unwrap();
        let registry = McpRegistry::new(dir.path()).await;
        // Python one-liner MCP mock: floods 256 KB to stderr, emits a notification,
        // replies out-of-order for id=10 and id=11, and hangs on id=99 until killed.
        let script = r#"
import sys, json
sys.stderr.write("E" * (256 * 1024) + "\n")
sys.stderr.flush()
req1 = json.loads(sys.stdin.readline())
req2 = json.loads(sys.stdin.readline())
sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {"ok": True}}) + "\n")
sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req2["id"], "result": {"echo": req2["method"]}}) + "\n")
sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req1["id"], "result": {"echo": req1["method"]}}) + "\n")
sys.stdout.flush()
for line in sys.stdin:
    pass
"#;
        let id = add_python_stdio_mcp(&registry, "multiplex-test", script, HashMap::new()).await;
        let handle = registry
            .spawn_stdio_process(
                id,
                "python3",
                &["-u".to_string(), "-c".to_string(), script.to_string()],
                &HashMap::new(),
            )
            .await
            .unwrap()
            .unwrap();

        let h1 = handle.clone();
        let h2 = handle.clone();
        let (r1, r2) = tokio::join!(
            h1.request(
                10,
                serde_json::json!({"jsonrpc":"2.0","id":10,"method":"first"}).to_string()
            ),
            h2.request(
                11,
                serde_json::json!({"jsonrpc":"2.0","id":11,"method":"second"}).to_string()
            ),
        );
        assert_eq!(r1.unwrap()["echo"], "first");
        assert_eq!(r2.unwrap()["echo"], "second");

        // Start an in-flight request that never receives a response, then kill() handle.
        let h_hang = handle.clone();
        let inflight = tokio::spawn(async move {
            h_hang
                .request(
                    99,
                    serde_json::json!({"jsonrpc":"2.0","id":99,"method":"hang"}).to_string(),
                )
                .await
        });
        tokio::time::sleep(Duration::from_millis(20)).await;
        let started = std::time::Instant::now();
        handle.kill();
        assert!(started.elapsed() < Duration::from_millis(50));
        let aborted = tokio::time::timeout(Duration::from_secs(2), inflight)
            .await
            .expect("inflight resolves promptly on kill")
            .unwrap();
        assert!(aborted.is_err());
    }

    fn pid_is_alive_or_zombie(pid: u32) -> bool {
        #[cfg(target_os = "linux")]
        {
            std::path::Path::new(&format!("/proc/{pid}")).exists()
        }
        #[cfg(not(target_os = "linux"))]
        {
            std::process::Command::new("kill")
                .args(["-0", &pid.to_string()])
                .status()
                .is_ok_and(|s| s.success())
        }
    }

    async fn add_python_stdio_mcp(
        registry: &McpRegistry,
        name: &str,
        script: &str,
        env: HashMap<String, String>,
    ) -> Uuid {
        let added = registry
            .add(AddMcpRequest {
                name: name.to_string(),
                transport: McpTransport::Stdio {
                    command: "python3".to_string(),
                    args: vec!["-u".to_string(), "-c".to_string(), script.to_string()],
                    env,
                },
                description: None,
                scope: Some(McpScope::Global),
                default_enabled: Some(false),
                workspace_env_allowlist: Vec::new(),
            })
            .await
            .unwrap();
        added.config.id
    }

    #[tokio::test]
    async fn unexpected_stdio_child_exit_transitions_state_and_removes_process() {
        let dir = tempfile::tempdir().unwrap();
        let pid_file = dir.path().join("child.pid");
        let registry = McpRegistry::new(dir.path()).await;

        let script = r#"
import json, os, sys
with open(os.environ["PID_FILE"], "w") as f:
    f.write(str(os.getpid()))
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    req_id = msg.get("id")
    if method == "initialize":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "mock", "version": "1.0.0"}
            }
        }) + "\n")
        sys.stdout.flush()
    elif method == "tools/list":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": [{"name": "ping", "description": "ping", "inputSchema": {}}]}
        }) + "\n")
        sys.stdout.flush()
    elif method == "tools/call":
        sys.exit(42)
"#;

        let mut env = HashMap::new();
        env.insert(
            "PID_FILE".to_string(),
            pid_file.to_string_lossy().to_string(),
        );
        let id = add_python_stdio_mcp(&registry, "exit-watch", script, env).await;

        let connected = registry.refresh(id).await.unwrap();
        assert_eq!(connected.status, McpStatus::Connected);
        assert!(registry.stdio_processes.contains_key(&id));

        let pid: u32 = tokio::fs::read_to_string(&pid_file)
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();

        let call_res = registry.call_tool(id, "ping", serde_json::json!({})).await;
        assert!(call_res.is_err());

        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let state = registry.get(id).await.unwrap();
                if state.status != McpStatus::Connected
                    && !registry.stdio_processes.contains_key(&id)
                    && !pid_is_alive_or_zombie(pid)
                {
                    assert_eq!(state.status, McpStatus::Error);
                    assert!(state.error.as_deref().unwrap_or_default().contains("42"));
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("dead stdio child reconciled out of Connected and reaped");
    }

    #[tokio::test]
    async fn stale_stdio_generation_exit_does_not_clobber_reconnected_generation() {
        let dir = tempfile::tempdir().unwrap();
        let pid_log = dir.path().join("pids.log");
        let registry = McpRegistry::new(dir.path()).await;

        let script = r#"
import json, os, signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: None)
with open(os.environ["PID_LOG"], "a") as f:
    f.write(str(os.getpid()) + "\n")
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    req_id = msg.get("id")
    if method == "initialize":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "mock", "version": "1.0.0"}
            }
        }) + "\n")
        sys.stdout.flush()
    elif method == "tools/list":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": [{"name": "whoami", "description": "pid", "inputSchema": {}}]}
        }) + "\n")
        sys.stdout.flush()
    elif method == "tools/call":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"content": [{"type": "text", "text": str(os.getpid())}]}
        }) + "\n")
        sys.stdout.flush()
time.sleep(0.15)
"#;

        let mut env = HashMap::new();
        env.insert("PID_LOG".to_string(), pid_log.to_string_lossy().to_string());
        let id = add_python_stdio_mcp(&registry, "gen-fence", script, env).await;

        let state1 = registry.refresh(id).await.unwrap();
        assert_eq!(state1.status, McpStatus::Connected);
        let gen1_handle = registry.stdio_processes.get(&id).unwrap().value().clone();
        assert_eq!(gen1_handle.generation, 1);

        let state2 = registry.refresh(id).await.unwrap();
        assert_eq!(state2.status, McpStatus::Connected);
        let gen2_handle = registry.stdio_processes.get(&id).unwrap().value().clone();
        assert_eq!(gen2_handle.generation, 2);

        tokio::time::timeout(Duration::from_secs(2), gen1_handle.stopped.cancelled())
            .await
            .expect("gen=1 actor exited and ran reconcile_stdio_exit");

        let after = registry.get(id).await.unwrap();
        assert_eq!(after.status, McpStatus::Connected);
        assert_eq!(registry.stdio_processes.get(&id).unwrap().generation, 2);

        let pids: Vec<u32> = tokio::fs::read_to_string(&pid_log)
            .await
            .unwrap()
            .lines()
            .map(|l| l.trim().parse().unwrap())
            .collect();
        assert_eq!(pids.len(), 2);
        assert!(!pid_is_alive_or_zombie(pids[0]));

        let whoami = registry
            .call_tool(id, "whoami", serde_json::json!({}))
            .await
            .unwrap();
        assert_eq!(whoami.trim().parse::<u32>().unwrap(), pids[1]);
    }

    #[tokio::test]
    async fn refresh_stdio_tools_list_failure_reaps_child_and_clears_process_map() {
        let dir = tempfile::tempdir().unwrap();
        let pid_file = dir.path().join("bad_tools.pid");
        let registry = McpRegistry::new(dir.path()).await;

        let bad_schema_script = r#"
import json, os, sys, time
with open(os.environ["PID_FILE"], "w") as f:
    f.write(str(os.getpid()))
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    req_id = msg.get("id")
    if method == "initialize":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "broken", "version": "1.0.0"}
            }
        }) + "\n")
        sys.stdout.flush()
    elif method == "tools/list":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": "not-an-array"}
        }) + "\n")
        sys.stdout.flush()
        time.sleep(60)
"#;

        let mut env = HashMap::new();
        env.insert(
            "PID_FILE".to_string(),
            pid_file.to_string_lossy().to_string(),
        );
        let id = add_python_stdio_mcp(&registry, "bad-tools-parse", bad_schema_script, env).await;

        let state = registry.refresh(id).await.expect(
            "refresh_stdio should return Ok(Error state) when tools/list payload is malformed",
        );
        assert_eq!(state.status, McpStatus::Error);
        assert!(state
            .error
            .as_deref()
            .unwrap_or_default()
            .contains("Failed to parse tools"));
        assert!(!registry.stdio_processes.contains_key(&id));

        let fetched_state = registry.get(id).await.unwrap();
        assert_eq!(fetched_state.status, McpStatus::Error);
        assert!(fetched_state
            .error
            .as_deref()
            .unwrap_or_default()
            .contains("Failed to parse tools"));

        let pid: u32 = tokio::fs::read_to_string(&pid_file)
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert!(!pid_is_alive_or_zombie(pid));

        let rpc_err_pid_file = dir.path().join("rpc_err_tools.pid");
        let rpc_err_script = r#"
import json, os, sys, time
with open(os.environ["PID_FILE"], "w") as f:
    f.write(str(os.getpid()))
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    req_id = msg.get("id")
    if method == "initialize":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "broken-rpc", "version": "1.0.0"}
            }
        }) + "\n")
        sys.stdout.flush()
    elif method == "tools/list":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32603, "message": "boom"}
        }) + "\n")
        sys.stdout.flush()
        time.sleep(60)
"#;

        let mut env2 = HashMap::new();
        env2.insert(
            "PID_FILE".to_string(),
            rpc_err_pid_file.to_string_lossy().to_string(),
        );
        let id2 = add_python_stdio_mcp(&registry, "bad-tools-rpc", rpc_err_script, env2).await;

        let state2 = registry.refresh(id2).await.expect(
            "refresh_stdio should return Ok(Error state) when tools/list returns JSON-RPC error",
        );
        assert_eq!(state2.status, McpStatus::Error);
        assert!(state2
            .error
            .as_deref()
            .unwrap_or_default()
            .contains("tools/list failed"));
        assert!(!registry.stdio_processes.contains_key(&id2));

        let fetched_state2 = registry.get(id2).await.unwrap();
        assert_eq!(fetched_state2.status, McpStatus::Error);

        let pid2: u32 = tokio::fs::read_to_string(&rpc_err_pid_file)
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert!(!pid_is_alive_or_zombie(pid2));
    }

    #[tokio::test]
    async fn wedged_stdin_write_all_cancels_and_reaps_promptly() {
        let dir = tempfile::tempdir().unwrap();
        let pid_file = dir.path().join("wedged_stdin.pid");
        let registry = McpRegistry::new(dir.path()).await;

        let script = r#"
import os, time
with open(os.environ["PID_FILE"], "w") as f:
    f.write(str(os.getpid()))
time.sleep(60)
"#;
        let mut env = HashMap::new();
        env.insert(
            "PID_FILE".to_string(),
            pid_file.to_string_lossy().to_string(),
        );
        let id = add_python_stdio_mcp(&registry, "wedged-stdin", script, env.clone()).await;
        let handle = registry
            .spawn_stdio_process(
                id,
                "python3",
                &["-u".to_string(), "-c".to_string(), script.to_string()],
                &env,
            )
            .await
            .unwrap()
            .unwrap();

        tokio::time::timeout(Duration::from_secs(2), async {
            while !pid_file.exists() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("wedged child wrote pid");

        let pid: u32 = tokio::fs::read_to_string(&pid_file)
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();

        let huge_payload = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "flood",
            "params": { "blob": "X".repeat(2 * 1024 * 1024) }
        })
        .to_string();

        let req_handle = handle.clone();
        let inflight = tokio::spawn(async move { req_handle.request(1, huge_payload).await });
        tokio::time::sleep(Duration::from_millis(50)).await;

        let started = std::time::Instant::now();
        handle
            .kill_and_wait()
            .await
            .expect("kill_and_wait must interrupt backpressured stdin write_all and reap child");
        assert!(started.elapsed() < MCP_STDIO_REAP_TIMEOUT);
        assert!(!pid_is_alive_or_zombie(pid));

        let req_res = tokio::time::timeout(Duration::from_secs(1), inflight)
            .await
            .expect("inflight request resolves after kill_and_wait")
            .unwrap();
        assert!(req_res.is_err());
    }

    #[tokio::test]
    async fn wedged_child_exit_during_stdin_write_all_unblocks_and_reaps() {
        let dir = tempfile::tempdir().unwrap();
        let pid_file = dir.path().join("wedged_exit.pid");
        let registry = McpRegistry::new(dir.path()).await;

        let script = r#"
import os, sys, time
with open(os.environ["PID_FILE"], "w") as f:
    f.write(str(os.getpid()))
time.sleep(0.1)
os._exit(17)
"#;
        let mut env = HashMap::new();
        env.insert(
            "PID_FILE".to_string(),
            pid_file.to_string_lossy().to_string(),
        );
        let id = add_python_stdio_mcp(&registry, "wedged-exit", script, env.clone()).await;
        let handle = registry
            .spawn_stdio_process(
                id,
                "python3",
                &["-u".to_string(), "-c".to_string(), script.to_string()],
                &env,
            )
            .await
            .unwrap()
            .unwrap();

        let huge_payload = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "flood",
            "params": { "blob": "Y".repeat(2 * 1024 * 1024) }
        })
        .to_string();

        let res = tokio::time::timeout(Duration::from_secs(2), handle.request(1, huge_payload))
            .await
            .expect("actor unblocks promptly when child exits during backpressured write_all");
        assert!(res.is_err());

        tokio::time::timeout(Duration::from_secs(2), handle.stopped.cancelled())
            .await
            .expect("actor stops cleanly without double-waiting child");

        let pid: u32 = tokio::fs::read_to_string(&pid_file)
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert!(!pid_is_alive_or_zombie(pid));
    }

    #[tokio::test]
    async fn concurrent_disable_and_remove_during_refresh_stdio_reap_child_without_clobbering() {
        let dir = tempfile::tempdir().unwrap();
        let registry = Arc::new(McpRegistry::new(dir.path()).await);

        // Case 1: disable(id) races while refresh_stdio is in flight (with SIGTERM ignored so tools/list reply succeeds after disable)
        let sigterm_ignore_script = r#"
import json, os, signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: None)
with open(os.environ["PID_FILE"], "w") as f:
    f.write(str(os.getpid()))
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    req_id = msg.get("id")
    if method == "initialize":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "slow-refresh", "version": "1.0.0"}
            }
        }) + "\n")
        sys.stdout.flush()
    elif method == "tools/list":
        with open(os.environ["READY_FILE"], "w") as f:
            f.write("ready")
        while not os.path.exists(os.environ["RELEASE_FILE"]):
            time.sleep(0.01)
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": [{"name": "ping", "description": "ping", "inputSchema": {}}]}
        }) + "\n")
        sys.stdout.flush()
        time.sleep(60)
"#;
        let pid_file_1 = dir.path().join("disable_race.pid");
        let ready_file_1 = dir.path().join("disable_race.ready");
        let release_file_1 = dir.path().join("disable_race.release");
        let mut env1 = HashMap::new();
        env1.insert(
            "PID_FILE".to_string(),
            pid_file_1.to_string_lossy().to_string(),
        );
        env1.insert(
            "READY_FILE".to_string(),
            ready_file_1.to_string_lossy().to_string(),
        );
        env1.insert(
            "RELEASE_FILE".to_string(),
            release_file_1.to_string_lossy().to_string(),
        );
        let id1 =
            add_python_stdio_mcp(&registry, "disable-race", sigterm_ignore_script, env1).await;

        let reg_refresh = Arc::clone(&registry);
        let refresh_task = tokio::spawn(async move { reg_refresh.refresh(id1).await });

        tokio::time::timeout(Duration::from_secs(2), async {
            while !ready_file_1.exists() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("refresh reached tools/list");

        let disabled = registry.disable(id1).await.unwrap();
        assert_eq!(disabled.status, McpStatus::Disabled);
        assert!(!disabled.config.enabled);

        // Wait for refresh_task directly: disable(id1) cancelled the actor so
        // refresh_stdio's tools/list unblocks immediately with an error and must
        // preserve McpStatus::Disabled instead of clobbering it with Error.
        let refresh_res = tokio::time::timeout(Duration::from_secs(3), refresh_task)
            .await
            .expect("refresh finished promptly after disable")
            .unwrap()
            .unwrap();
        assert_eq!(refresh_res.status, McpStatus::Disabled);
        assert!(!refresh_res.config.enabled);
        assert!(!registry.stdio_processes.contains_key(&id1));

        let final_state = registry.get(id1).await.unwrap();
        assert_eq!(final_state.status, McpStatus::Disabled);
        assert!(!final_state.config.enabled);

        let pid1: u32 = tokio::fs::read_to_string(&pid_file_1)
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            while pid_is_alive_or_zombie(pid1) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("disabled server child process reaped");

        // Case 1b: disable(id) races AFTER tools/list returned Ok(...) while refresh_stdio is persisting config
        let fast_tools_script = r#"
import json, os, signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: None)
with open(os.environ["PID_FILE"], "w") as f:
    f.write(str(os.getpid()))
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    req_id = msg.get("id")
    if method == "initialize":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "fast-refresh", "version": "1.0.0"}
            }
        }) + "\n")
        sys.stdout.flush()
    elif method == "tools/list":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": [{"name": "ping", "description": "ping", "inputSchema": {}}]}
        }) + "\n")
        sys.stdout.flush()
        with open(os.environ["LISTED_FILE"], "w") as f:
            f.write("listed")
        time.sleep(60)
"#;
        let pid_file_1b = dir.path().join("disable_after_list.pid");
        let listed_file_1b = dir.path().join("disable_after_list.listed");
        let mut env1b = HashMap::new();
        env1b.insert(
            "PID_FILE".to_string(),
            pid_file_1b.to_string_lossy().to_string(),
        );
        env1b.insert(
            "LISTED_FILE".to_string(),
            listed_file_1b.to_string_lossy().to_string(),
        );
        let id1b =
            add_python_stdio_mcp(&registry, "disable-after-list", fast_tools_script, env1b).await;

        // Hold config_store write lock so refresh_stdio parks right after tools/list Ok(...)
        let reg_refresh_1b = Arc::clone(&registry);
        let refresh_task_1b = tokio::spawn(async move { reg_refresh_1b.refresh(id1b).await });
        tokio::time::timeout(Duration::from_secs(2), async {
            while !listed_file_1b.exists() {
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        })
        .await
        .expect("tools/list response flushed");
        let disabled_1b = registry.disable(id1b).await.unwrap();
        assert_eq!(disabled_1b.status, McpStatus::Disabled);
        let refresh_res_1b = tokio::time::timeout(Duration::from_secs(3), refresh_task_1b)
            .await
            .expect("refresh 1b finished")
            .unwrap()
            .unwrap();
        let after_1b = registry.get(id1b).await.unwrap();
        assert_eq!(after_1b.status, McpStatus::Disabled);
        assert!(!after_1b.config.enabled);
        assert!(!registry.stdio_processes.contains_key(&id1b));
        let _ = refresh_res_1b;
        let pid1b: u32 = tokio::fs::read_to_string(&pid_file_1b)
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            while pid_is_alive_or_zombie(pid1b) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("disabled 1b child reaped");

        // Case 2: spawn_stdio_process sees an already-disabled server and refuses to publish
        let pid_file_unpub = dir.path().join("disabled_spawn.pid");
        let mut env_unpub = HashMap::new();
        env_unpub.insert(
            "PID_FILE".to_string(),
            pid_file_unpub.to_string_lossy().to_string(),
        );
        let unpublished = registry
            .spawn_stdio_process(
                id1,
                "python3",
                &[
                    "-u".to_string(),
                    "-c".to_string(),
                    "import os, time; open(os.environ['PID_FILE'], 'w').write(str(os.getpid())); time.sleep(60)".to_string(),
                ],
                &env_unpub,
            )
            .await
            .unwrap();
        assert!(unpublished.is_none());
        assert!(!registry.stdio_processes.contains_key(&id1));
        assert_eq!(registry.get(id1).await.unwrap().status, McpStatus::Disabled);
        if let Ok(pid_str) = tokio::fs::read_to_string(&pid_file_unpub).await {
            if let Ok(pid_unpub) = pid_str.trim().parse::<u32>() {
                assert!(!pid_is_alive_or_zombie(pid_unpub));
            }
        }

        // Case 3a: remove(id) races while refresh_stdio tools/list is in flight
        let pid_file_2 = dir.path().join("remove_race.pid");
        let ready_file_2 = dir.path().join("remove_race.ready");
        let release_file_2 = dir.path().join("remove_race.release");
        let mut env2 = HashMap::new();
        env2.insert(
            "PID_FILE".to_string(),
            pid_file_2.to_string_lossy().to_string(),
        );
        env2.insert(
            "READY_FILE".to_string(),
            ready_file_2.to_string_lossy().to_string(),
        );
        env2.insert(
            "RELEASE_FILE".to_string(),
            release_file_2.to_string_lossy().to_string(),
        );
        let id2 = add_python_stdio_mcp(&registry, "remove-race", sigterm_ignore_script, env2).await;

        let reg_refresh_2 = Arc::clone(&registry);
        let refresh_task_2 = tokio::spawn(async move { reg_refresh_2.refresh(id2).await });

        tokio::time::timeout(Duration::from_secs(2), async {
            while !ready_file_2.exists() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("refresh 2 reached tools/list");

        registry.remove(id2).await.unwrap();
        assert!(registry.get(id2).await.is_none());
        tokio::fs::write(&release_file_2, "go").await.unwrap();

        let refresh_res_2 = tokio::time::timeout(Duration::from_secs(3), refresh_task_2)
            .await
            .expect("refresh 2 finished promptly after remove")
            .unwrap();
        assert!(refresh_res_2.is_err());
        assert!(registry.get(id2).await.is_none());
        assert!(!registry.stdio_processes.contains_key(&id2));

        let pid2: u32 = tokio::fs::read_to_string(&pid_file_2)
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            while pid_is_alive_or_zombie(pid2) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("removed server child process reaped");

        // Case 3b: remove(id) races right after tools/list response arrives before update_state_success
        let pid_file_2b = dir.path().join("remove_after_list.pid");
        let listed_file_2b = dir.path().join("remove_after_list.listed");
        let mut env2b = HashMap::new();
        env2b.insert(
            "PID_FILE".to_string(),
            pid_file_2b.to_string_lossy().to_string(),
        );
        env2b.insert(
            "LISTED_FILE".to_string(),
            listed_file_2b.to_string_lossy().to_string(),
        );
        let id2b =
            add_python_stdio_mcp(&registry, "remove-after-list", fast_tools_script, env2b).await;

        let slow_remove_id = registry
            .add(AddMcpRequest {
                name: "slow-config-holder".to_string(),
                transport: McpTransport::Http {
                    endpoint: "http://127.0.0.1:9".to_string(),
                    headers: HashMap::new(),
                },
                description: None,
                scope: Some(McpScope::Global),
                default_enabled: Some(false),
                workspace_env_allowlist: Vec::new(),
            })
            .await
            .unwrap()
            .config
            .id;

        let config_store_hold = Arc::clone(&registry.config_store);
        let (hold_ready_tx, hold_ready_rx) = oneshot::channel();
        let (hold_release_tx, hold_release_rx) = std::sync::mpsc::channel();
        let hold_task = tokio::task::spawn_blocking(move || {
            tokio::runtime::Handle::current().block_on(async move {
                let _ = config_store_hold
                    .update(slow_remove_id, |_c| {
                        let _ = hold_ready_tx.send(());
                        let _ = hold_release_rx.recv_timeout(Duration::from_secs(5));
                    })
                    .await;
            });
        });
        hold_ready_rx.await.unwrap();

        let reg_refresh_2b = Arc::clone(&registry);
        let refresh_task_2b = tokio::spawn(async move { reg_refresh_2b.refresh(id2b).await });
        tokio::time::timeout(Duration::from_secs(2), async {
            while !listed_file_2b.exists() {
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        })
        .await
        .expect("tools/list 2b response flushed while config_store write lock held");
        // Let refresh_task_2b deserialize tools/list and park on config_store.update(id2b)
        tokio::time::sleep(Duration::from_millis(25)).await;

        let reg_remove_2b = Arc::clone(&registry);
        let remove_task_2b = tokio::spawn(async move { reg_remove_2b.remove(id2b).await });
        tokio::time::timeout(Duration::from_secs(2), async {
            while registry.get(id2b).await.is_some() {
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        })
        .await
        .expect("remove(id2b) fenced states[id2b] before config_store I/O");

        let _ = hold_release_tx.send(());
        hold_task.await.unwrap();
        remove_task_2b.await.unwrap().unwrap();

        let refresh_res_2b = tokio::time::timeout(Duration::from_secs(3), refresh_task_2b)
            .await
            .expect("refresh 2b finished promptly after remove")
            .unwrap();
        assert!(refresh_res_2b.is_err());
        assert!(registry.get(id2b).await.is_none());
        assert!(registry.config_store.get(id2b).await.is_none());
        assert!(!registry.stdio_processes.contains_key(&id2b));

        let pid2b: u32 = tokio::fs::read_to_string(&pid_file_2b)
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            while pid_is_alive_or_zombie(pid2b) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("removed 2b server child process reaped");
        registry.remove(slow_remove_id).await.unwrap();

        // Case 4: refresh_stdio initialize failure with wedged stdin preserves primary diagnostic and reaps child
        let wedged_init_script = r#"
import os, time
with open(os.environ["PID_FILE"], "w") as f:
    f.write(str(os.getpid()))
time.sleep(60)
"#;
        let pid_file_3 = dir.path().join("wedged_init.pid");
        let mut env3 = HashMap::new();
        env3.insert(
            "PID_FILE".to_string(),
            pid_file_3.to_string_lossy().to_string(),
        );
        let id3 =
            add_python_stdio_mcp(&registry, "wedged-init", wedged_init_script, env3.clone()).await;
        let proc3 = registry
            .spawn_stdio_process(
                id3,
                "python3",
                &[
                    "-u".to_string(),
                    "-c".to_string(),
                    wedged_init_script.to_string(),
                ],
                &env3,
            )
            .await
            .unwrap()
            .unwrap();

        tokio::time::timeout(Duration::from_secs(2), async {
            while !pid_file_3.exists() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("wedged init child wrote pid");

        let flood_payload = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 999,
            "method": "flood",
            "params": { "blob": "Z".repeat(2 * 1024 * 1024) }
        })
        .to_string();
        let proc3_flood = proc3.clone();
        let _flood_task =
            tokio::spawn(async move { proc3_flood.request(999, flood_payload).await });
        tokio::time::sleep(Duration::from_millis(50)).await;

        registry
            .cleanup_failed_stdio_process(
                id3,
                &proc3,
                "Initialize failed: synthetic init error".to_string(),
            )
            .await;

        let state3 = registry.get(id3).await.unwrap();
        assert_eq!(state3.status, McpStatus::Error);
        assert_eq!(
            state3.error.as_deref(),
            Some("Initialize failed: synthetic init error")
        );
        assert!(!registry.stdio_processes.contains_key(&id3));

        let pid3: u32 = tokio::fs::read_to_string(&pid_file_3)
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert!(!pid_is_alive_or_zombie(pid3));
    }

    #[tokio::test]
    async fn refresh_stdio_immediate_child_exit_after_malformed_tools_list_preserves_primary_error()
    {
        let dir = tempfile::tempdir().unwrap();
        let pid_file = dir.path().join("immediate_exit_bad_tools.pid");
        let registry = McpRegistry::new(dir.path()).await;

        let script = r#"
import json, os, sys
with open(os.environ["PID_FILE"], "w") as f:
    f.write(str(os.getpid()))
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    req_id = msg.get("id")
    if method == "initialize":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "immediate-exit", "version": "1.0.0"}
            }
        }) + "\n")
        sys.stdout.flush()
    elif method == "tools/list":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": "not-an-array"}
        }) + "\n")
        sys.stdout.flush()
        sys.exit(0)
"#;

        let mut env = HashMap::new();
        env.insert(
            "PID_FILE".to_string(),
            pid_file.to_string_lossy().to_string(),
        );
        let id = add_python_stdio_mcp(&registry, "immediate-exit-bad-tools", script, env).await;

        for _ in 0..10 {
            let state = registry.refresh(id).await.unwrap();
            assert_eq!(state.status, McpStatus::Error);
            let err_msg = state.error.as_deref().unwrap_or_default();
            assert!(
                err_msg.contains("Failed to parse tools"),
                "expected primary parse error, got: {err_msg}"
            );
            assert!(!registry.stdio_processes.contains_key(&id));

            let fetched = registry.get(id).await.unwrap();
            assert_eq!(fetched.status, McpStatus::Error);
            let fetched_err = fetched.error.as_deref().unwrap_or_default();
            assert!(
                fetched_err.contains("Failed to parse tools"),
                "expected persisted primary parse error in states, got: {fetched_err}"
            );
        }

        let pid: u32 = tokio::fs::read_to_string(&pid_file)
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert!(!pid_is_alive_or_zombie(pid));

        // Also verify a stale generation cleanup cannot overwrite a newer reconnected generation
        let good_script = r#"
import json, sys, time
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    req_id = msg.get("id")
    if method == "initialize":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "good", "version": "1.0.0"}
            }
        }) + "\n")
        sys.stdout.flush()
    elif method == "tools/list":
        sys.stdout.write(json.dumps({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": [{"name": "ok", "description": "ok", "inputSchema": {}}]}
        }) + "\n")
        sys.stdout.flush()
time.sleep(1)
"#;
        registry
            .update(
                id,
                UpdateMcpRequest {
                    name: None,
                    transport: Some(McpTransport::Stdio {
                        command: "python3".to_string(),
                        args: vec!["-u".to_string(), "-c".to_string(), good_script.to_string()],
                        env: HashMap::new(),
                    }),
                    description: None,
                    enabled: Some(true),
                    scope: None,
                    default_enabled: None,
                    workspace_env_allowlist: None,
                },
            )
            .await
            .unwrap();
        let connected = registry.refresh(id).await.unwrap();
        assert_eq!(connected.status, McpStatus::Connected);

        let (dummy_tx, _dummy_rx) = mpsc::channel(1);
        let stale_stopped = CancellationToken::new();
        stale_stopped.cancel();
        let stale_handle = McpStdioHandle {
            cmd_tx: dummy_tx,
            cancel_token: CancellationToken::new(),
            generation: 1,
            stopped: stale_stopped,
        };
        registry
            .cleanup_failed_stdio_process(
                id,
                &stale_handle,
                "Failed to parse tools: stale generation".to_string(),
            )
            .await;
        let still_connected = registry.get(id).await.unwrap();
        assert_eq!(still_connected.status, McpStatus::Connected);
        assert!(still_connected.error.is_none());
    }

    #[tokio::test]
    async fn refresh_http_does_not_persist_tools_when_concurrently_disabled() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        let dir = tempfile::tempdir().unwrap();
        let registry = Arc::new(McpRegistry::new(dir.path()).await);

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (tools_list_entered_tx, tools_list_entered_rx) = oneshot::channel();
        let (tools_list_release_tx, tools_list_release_rx) = oneshot::channel();

        let server_task = tokio::spawn(async move {
            let mut entered_tx = Some(tools_list_entered_tx);
            let mut release_rx = Some(tools_list_release_rx);
            for _ in 0..3 {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };
                let mut buf = vec![0u8; 8192];
                let n = stream.read(&mut buf).await.unwrap_or(0);
                let req_str = String::from_utf8_lossy(&buf[..n]);
                let body = req_str.split("\r\n\r\n").nth(1).unwrap_or("{}");
                let json: serde_json::Value = serde_json::from_str(body).unwrap_or_default();
                let method = json.get("method").and_then(|m| m.as_str()).unwrap_or("");
                let req_id = json.get("id").cloned().unwrap_or(serde_json::json!(1));

                let resp_json = match method {
                    "initialize" => serde_json::json!({
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "protocolVersion": "2024-11-05",
                            "capabilities": {},
                            "serverInfo": {"name": "http-mock", "version": "2.0.0"}
                        }
                    }),
                    "notifications/initialized" => serde_json::json!({"jsonrpc": "2.0"}),
                    "tools/list" => {
                        if let Some(tx) = entered_tx.take() {
                            let _ = tx.send(());
                        }
                        if let Some(rx) = release_rx.take() {
                            let _ = rx.await;
                        }
                        serde_json::json!({
                            "jsonrpc": "2.0",
                            "id": req_id,
                            "result": {
                                "tools": [{"name": "http_ping", "description": "ping", "inputSchema": {}}]
                            }
                        })
                    }
                    _ => serde_json::json!({"jsonrpc": "2.0", "id": req_id, "result": {}}),
                };
                let resp_body = resp_json.to_string();
                let http_resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    resp_body.len(),
                    resp_body
                );
                let _ = stream.write_all(http_resp.as_bytes()).await;
            }
        });

        let added = registry
            .add(AddMcpRequest {
                name: "http-disable-race".to_string(),
                transport: McpTransport::Http {
                    endpoint: format!("http://{addr}"),
                    headers: HashMap::new(),
                },
                description: None,
                scope: Some(McpScope::Global),
                default_enabled: Some(false),
                workspace_env_allowlist: Vec::new(),
            })
            .await
            .unwrap();
        let id = added.config.id;

        let reg_refresh = Arc::clone(&registry);
        let refresh_task = tokio::spawn(async move { reg_refresh.refresh(id).await });

        tools_list_entered_rx.await.unwrap();
        let disabled = registry.disable(id).await.unwrap();
        assert_eq!(disabled.status, McpStatus::Disabled);
        assert!(!disabled.config.enabled);

        let _ = tools_list_release_tx.send(());
        let refresh_state = refresh_task.await.unwrap().unwrap();
        assert_eq!(refresh_state.status, McpStatus::Disabled);
        assert!(!refresh_state.config.enabled);
        assert!(refresh_state.config.tools.is_empty());

        let persisted = registry.config_store.get(id).await.unwrap();
        assert!(!persisted.enabled);
        assert!(persisted.tools.is_empty());
        assert!(persisted.tool_descriptors.is_empty());
        assert!(persisted.last_connected_at.is_none());

        server_task.abort();
    }
}
