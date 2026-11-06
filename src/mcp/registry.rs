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

    let exit_reason: &'static str = loop {
        tokio::select! {
            biased;
            _ = cancel_token.cancelled() => {
                break "MCP server killed";
            }
            _ = child.wait() => break "MCP child exited",
            read_res = stdout_reader.read_line(&mut line) => {
                match read_res {
                    Ok(0) => break "MCP process closed stdout",
                    Ok(_) => {
                        let trimmed = line.trim();
                        if !trimmed.is_empty() {
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
                                                    if let Ok(err) = serde_json::from_value::<JsonRpcError>(err_val.clone()) {
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
            cmd = cmd_rx.recv() => {
                match cmd {
                    Some(McpStdioCommand::Request { id, payload, resp_tx }) => {
                        if pending.len() >= 64 {
                            pending.retain(|_, tx| !tx.is_closed());
                        }
                        if let Err(err) = async {
                            stdin.write_all(payload.as_bytes()).await?;
                            stdin.write_all(b"\n").await?;
                            stdin.flush().await
                        }
                        .await
                        {
                            let _ = resp_tx.send(Err(anyhow::anyhow!("Stdin write error: {}", err)));
                            break "MCP stdin write error";
                        }
                        pending.insert(id, resp_tx);
                    }
                    Some(McpStdioCommand::Notify { payload }) => {
                        if let Err(err) = async {
                            stdin.write_all(payload.as_bytes()).await?;
                            stdin.write_all(b"\n").await?;
                            stdin.flush().await
                        }
                        .await
                        {
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
    let exit_status = match child.try_wait() {
        Ok(Some(status)) => Some(status),
        _ => {
            let _ = child.start_kill();
            tokio::time::timeout(MCP_STDIO_REAP_TIMEOUT, child.wait())
                .await
                .ok()
                .and_then(Result::ok)
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
    ) -> anyhow::Result<()> {
        Self::reconcile_stdio_exit(
            &self.states,
            &self.stdio_processes,
            id,
            process.generation,
            error,
        );
        process.kill_and_wait().await
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
                if state.status != McpStatus::Disabled {
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
    async fn spawn_stdio_process(
        &self,
        id: Uuid,
        command: &str,
        args: &[String],
        env: &HashMap<String, String>,
    ) -> anyhow::Result<McpStdioHandle> {
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
        if let Some(previous) = self.stdio_processes.insert(id, handle.clone()) {
            previous.kill();
        }
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

        Ok(handle)
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
        // Kill stdio process immediately without blocking on in-flight tool calls
        if let Some((_, handle)) = self.stdio_processes.remove(&id) {
            handle.kill();
        }

        // Remove from persistent store
        self.config_store.remove(id).await?;

        // Remove from states
        self.states.remove(&id);

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
        // Kill stdio process immediately without blocking on in-flight tool calls
        if let Some((_, handle)) = self.stdio_processes.remove(&id) {
            handle.kill();
        }

        // Update persistent config
        let config = self.config_store.disable(id).await?;

        // Update runtime state
        if let Some(mut state) = self.states.get_mut(&id) {
            state.config = config;
            state.status = McpStatus::Disabled;
            state.error = None;
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
        // Kill existing stdio process if transport might change
        if req.transport.is_some() {
            if let Some((_, handle)) = self.stdio_processes.remove(&id) {
                handle.kill();
            }
        }

        // Update persistent config
        let config = self
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
            .await?;

        // Update runtime state
        if let Some(mut state) = self.states.get_mut(&id) {
            state.config = config;
            // Reset status if transport changed
            if req.transport.is_some() {
                state.status = if state.config.enabled {
                    McpStatus::Disconnected
                } else {
                    McpStatus::Disabled
                };
                state.error = None;
            }
        }

        self.get(id)
            .await
            .ok_or_else(|| anyhow::anyhow!("MCP not found"))
    }

    /// Helper to update state with error
    async fn update_state_error(&self, id: Uuid, error_msg: String) {
        if let Some(mut state) = self.states.get_mut(&id) {
            state.status = McpStatus::Error;
            state.error = Some(error_msg);
        }
    }

    /// Helper to update state with success
    async fn update_state_success(
        &self,
        id: Uuid,
        tool_descriptors: Vec<McpToolDescriptor>,
        server_version: Option<String>,
    ) {
        let tool_names: Vec<String> = tool_descriptors.iter().map(|t| t.name.clone()).collect();
        if let Some(mut state) = self.states.get_mut(&id) {
            state.config.tools = tool_names;
            state.config.tool_descriptors = tool_descriptors;
            state.config.version = server_version;
            state.config.last_connected_at = Some(chrono::Utc::now());
            state.status = McpStatus::Connected;
            state.error = None;
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
                                c.tools = tool_names.clone();
                                c.tool_descriptors = tool_descriptors.clone();
                                c.version = server_version.clone();
                                c.last_connected_at = Some(chrono::Utc::now());
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
            Ok(p) => p,
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
                    self.cleanup_failed_stdio_process(id, &process, error.clone())
                        .await?;
                    anyhow::bail!(error);
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
                    let still_current = self
                        .stdio_processes
                        .get(&id)
                        .is_some_and(|entry| entry.generation == process.generation);
                    if !still_current {
                        let _ = process.kill_and_wait().await;
                        anyhow::bail!("MCP stdio process exited or was superseded during refresh");
                    }

                    let tool_descriptors = tools_response.tools;
                    let tool_names: Vec<String> =
                        tool_descriptors.iter().map(|t| t.name.clone()).collect();

                    let _ = self
                        .config_store
                        .update(id, |c| {
                            c.tools = tool_names.clone();
                            c.tool_descriptors = tool_descriptors.clone();
                            c.version = server_version.clone();
                            c.last_connected_at = Some(chrono::Utc::now());
                        })
                        .await;

                    if let Some(entry) = self.stdio_processes.get(&id) {
                        if entry.generation == process.generation {
                            self.update_state_success(id, tool_descriptors, server_version)
                                .await;
                        } else {
                            drop(entry);
                            let _ = process.kill_and_wait().await;
                            anyhow::bail!("MCP stdio process superseded during refresh");
                        }
                    } else {
                        anyhow::bail!("MCP stdio process exited during refresh");
                    }
                }
                Err(e) => {
                    let error = format!("Failed to parse tools: {e}");
                    self.cleanup_failed_stdio_process(id, &process, error.clone())
                        .await?;
                    anyhow::bail!(error);
                }
            },
            Err(e) => {
                let error = format!("tools/list failed: {e}");
                self.cleanup_failed_stdio_process(id, &process, error.clone())
                    .await?;
                anyhow::bail!(error);
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
        let handle = registry
            .spawn_stdio_process(
                Uuid::new_v4(),
                "python3",
                &["-u".to_string(), "-c".to_string(), script.to_string()],
                &HashMap::new(),
            )
            .await
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

        let err = registry
            .refresh(id)
            .await
            .expect_err("refresh_stdio should fail when tools/list payload is malformed");
        assert!(err.to_string().contains("Failed to parse tools"));
        assert!(!registry.stdio_processes.contains_key(&id));

        let state = registry.get(id).await.unwrap();
        assert_eq!(state.status, McpStatus::Error);
        assert!(state
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

        let err2 = registry
            .refresh(id2)
            .await
            .expect_err("refresh_stdio should fail when tools/list returns JSON-RPC error");
        assert!(err2.to_string().contains("tools/list failed"));
        assert!(!registry.stdio_processes.contains_key(&id2));

        let state2 = registry.get(id2).await.unwrap();
        assert_eq!(state2.status, McpStatus::Error);

        let pid2: u32 = tokio::fs::read_to_string(&rpc_err_pid_file)
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert!(!pid_is_alive_or_zombie(pid2));
    }
}
