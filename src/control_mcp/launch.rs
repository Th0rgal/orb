//! Per-process native MCP overlays. Two harnesses sharing a checkout must never
//! overwrite each other's identity or the user's existing MCP configuration.
use super::{client::Client, Role};
use serde_json::{json, Value};
use std::{collections::HashMap, path::Path};

/// Runtime entry points must not silently launch a native mission without its
/// scoped MCP identity. Offline workspace/config generation may omit an owner.
pub fn require_runtime_owner(
    harness: &str,
    user: Option<&crate::api::auth::AuthUser>,
) -> Result<(), String> {
    if matches!(
        harness,
        "codex" | "claudecode" | "opencode" | "grok" | "antigravity" | "vibe"
    ) && user.is_none_or(|user| user.id.trim().is_empty())
    {
        return Err("Cannot launch native mission without its authenticated MCP owner".into());
    }
    Ok(())
}

/// Arguments, environment and optional settings written for a harness launch.
type HarnessLaunch = (Vec<String>, HashMap<String, String>, Option<Value>);
pub fn overlays(
    harness: &str,
    binary: &str,
    api_url: &str,
    credential: &str,
    mission_id: &str,
    existing: &HashMap<String, String>,
    settings_file: &str,
) -> Result<HarnessLaunch, String> {
    let args = vec![
        "--api-url",
        api_url,
        "--token-file",
        credential,
        "--mission-id",
        mission_id,
        "--profile",
        "executor",
    ];
    let server = json!({"command":binary,"args":args});
    let mut cli = vec![];
    let mut env = HashMap::new();
    let mut file = None;
    match harness {
        "codex" => {
            for (key, value) in [
                ("command", json!(binary)),
                ("args", json!(args)),
                ("startup_timeout_sec", json!(30)),
                ("tool_timeout_sec", json!(60)),
                ("enabled", json!(true)),
                // This launcher has already checked the mission-scoped
                // executor grant. Core authorizes every mutation; unattended
                // Codex must not reject all of them under approval=never.
                ("default_tools_approval_mode", json!("approve")),
            ] {
                cli.extend(["-c".into(), format!("mcp_servers.sandboxed.{key}={value}")]);
            }
        }
        "claudecode" => {
            file = Some(json!({"mcpServers":{"sandboxed":server}}));
            cli.extend(["--mcp-config".into(), settings_file.into()]);
        }
        "opencode" => {
            let mut config: Value = serde_json::from_str(
                existing
                    .get("OPENCODE_CONFIG_CONTENT")
                    .map(String::as_str)
                    .unwrap_or("{}"),
            )
            .map_err(|_| "Invalid existing OpenCode inline config")?;
            if !config.is_object() {
                return Err("OpenCode inline config must be an object".into());
            }
            if config.get("permission").is_none() {
                config["permission"] = json!({
                    "*": "allow",
                    "external_directory": { "*": "allow" },
                    "doom_loop": "allow",
                    "read": { "*": "allow" }
                });
            }
            if config.get("mcp").is_none() {
                config["mcp"] = json!({})
            }
            if !config["mcp"].is_object() {
                return Err("OpenCode mcp config must be an object".into());
            }
            let mut command = vec![json!(binary)];
            command.extend(args.iter().map(|s| json!(s)));
            config["mcp"]["sandboxed"] =
                json!({"type":"local","command":command,"enabled":true,"timeout":60000});
            env.insert("OPENCODE_CONFIG_CONTENT".into(), config.to_string());
        }
        "vibe" => {
            let mut servers: Vec<Value> = existing
                .get("VIBE_MCP_SERVERS")
                .map(|value| serde_json::from_str(value))
                .transpose()
                .map_err(|_| "Invalid Vibe MCP configuration")?
                .unwrap_or_default();
            servers.retain(|server| server["name"] != "sandboxed");
            servers.push(
                json!({"name":"sandboxed", "transport":"stdio", "command":[binary], "args":args}),
            );
            env.insert(
                "VIBE_MCP_SERVERS".into(),
                serde_json::to_string(&servers)
                    .map_err(|_| "Cannot encode Vibe MCP configuration")?,
            );
        }
        "grok" => {
            // Grok 1.x intentionally excludes MCP definitions from GROK_CONFIG's
            // soft-settings allowlist. ACP session/new and session/load own
            // per-session servers; never edit the shared GROK_HOME instead.
            file = Some(json!({"name":"sandboxed","command":binary,"args":args,"env":[]}));
        }
        "antigravity" => {
            file = Some(json!({"mcpServers":{"sandboxed":server}}));
        }
        _ => return Err("Harness does not support the unified MCP launcher".into()),
    }
    Ok((cli, env, file))
}

fn harness_arguments(
    program: &str,
    args: &[String],
    flags: &[String],
) -> Result<Vec<String>, String> {
    if flags.is_empty() {
        return Ok(args.to_vec());
    }
    let name = Path::new(program)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(program);
    match name {
        "sh" | "bash"
            if args.len() >= 4
                && args[0] == "-c"
                && args[1] == "cat | \"$@\""
                && args[2] == "orb-native-plan" =>
        {
            let mut result = args[..4].to_vec();
            result.extend(harness_arguments(&args[3], &args[4..], flags)?);
            Ok(result)
        }
        "sh" | "bash" => Err(
            "MCP CLI flags require a native executable or the supported plan-mode wrapper".into(),
        ),
        "node" | "bun" => {
            let script = args
                .first()
                .filter(|s| !s.starts_with('-'))
                .ok_or("MCP launch requires an explicit CLI script after node or bun")?;
            let mut result = vec![script.clone()];
            result.extend_from_slice(flags);
            result.extend_from_slice(&args[1..]);
            Ok(result)
        }
        _ => {
            let mut result = flags.to_vec();
            result.extend_from_slice(args);
            Ok(result)
        }
    }
}

pub async fn run(args: &[String]) -> Result<(), String> {
    let separator = args
        .iter()
        .position(|arg| arg == "--")
        .ok_or("launch requires -- before the harness command")?;
    let header = &args[..separator];
    let command = &args[separator + 1..];
    let program = command.first().ok_or("Missing harness executable")?;
    if !header.len().is_multiple_of(2) {
        return Err("Launcher options require values".into());
    }
    let mut options = HashMap::new();
    for [key, value] in header.as_chunks::<2>().0 {
        if !matches!(
            key.as_str(),
            "--harness" | "--api-url" | "--token-file" | "--mission-id"
        ) {
            return Err("Unknown launcher option".into());
        }
        if options.insert(key.as_str(), value.as_str()).is_some() {
            return Err("Duplicate launcher option".into());
        }
    }
    let harness = *options.get("--harness").ok_or("Missing --harness")?;
    let grok_acp = harness == "grok" && command.windows(2).any(|pair| pair == ["agent", "stdio"]);
    let api_url = options
        .get("--api-url")
        .map(|s| s.to_string())
        .or_else(|| std::env::var("SANDBOXED_MCP_API_URL").ok())
        .ok_or("Missing Core MCP URL")?;
    let token_file = options
        .get("--token-file")
        .map(|path| std::path::PathBuf::from(*path));
    let token = std::env::var("SANDBOXED_MCP_TOKEN").unwrap_or_default();
    // The explicit standalone login file is read only by this trusted parent.
    // Core/node/Orb environment injection must already carry a scoped grant.
    if token_file.is_none() && !token.starts_with("mcp1.") {
        return Err(
            "Harness launch requires a scoped MCP session or an explicit login file".into(),
        );
    }
    let mission_id = options
        .get("--mission-id")
        .map(|s| s.to_string())
        .or_else(|| {
            std::env::var("SANDBOXED_SH_MISSION_ID")
                .or_else(|_| std::env::var("MISSION_ID"))
                .ok()
        })
        .ok_or("Missing mission identity")?;
    let id = uuid::Uuid::parse_str(&mission_id).map_err(|_| "Invalid mission identity")?;
    let client = Client::new(api_url.clone(), token, token_file, Role::Executor, Some(id))?;
    let capabilities = client.preflight().await?;
    if capabilities["identity"]["mission_id"] != mission_id
        || capabilities["identity"]["role"] != "executor"
    {
        return Err("MCP session identity does not match this harness launch".into());
    }
    let dir = tempfile::Builder::new()
        .prefix("sandboxed-mcp-")
        .tempdir()
        .map_err(|_| "Cannot create MCP runtime directory")?;
    let credential = dir.path().join("credential");
    write_private(&credential, client.token().await?.as_bytes())?;
    let settings = dir.path().join("settings.json");
    let binary = std::env::current_exe().map_err(|_| "Cannot locate sandboxed-mcp")?;
    let (mut flags, env, file) = overlays(
        harness,
        &binary.to_string_lossy(),
        &api_url,
        &credential.to_string_lossy(),
        &mission_id,
        &std::env::vars().collect(),
        &settings.to_string_lossy(),
    )?;
    if let Some(file) = &file {
        write_private(&settings, file.to_string().as_bytes())?;
    }
    if harness == "grok" && !grok_acp {
        if command.iter().any(|arg| {
            matches!(arg.as_str(), "--agent" | "--agents")
                || arg.starts_with("--agent=")
                || arg.starts_with("--agents=")
        }) {
            return Err("A custom Grok agent requires ACP launch to preserve its profile while injecting MCP".into());
        }
        let profile = dir.path().join("agent.md");
        let definition = grok_headless_profile(file.as_ref().ok_or("Missing Grok MCP server")?);
        write_private(&profile, definition.as_bytes())?;
        flags.extend(["--agent".into(), profile.to_string_lossy().into_owned()]);
    }
    let overlay = if harness == "antigravity" {
        Some(super::antigravity::Overlay::install(
            &std::env::current_dir().map_err(|_| "Cannot resolve workspace")?,
            file.as_ref().ok_or("Missing Antigravity MCP config")?,
        )?)
    } else {
        None
    };
    let mut process = tokio::process::Command::new(program);
    process
        .args(harness_arguments(program, &command[1..], &flags)?)
        .envs(env);
    // These control-plane credentials are never part of a harness environment.
    for name in [
        "JWT_SECRET",
        "API_SERVER_KEY",
        "HERMES_SANDBOXED_API_TOKEN",
        "SANDBOXED_API_TOKEN",
        "OPEN_AGENT_API_TOKEN",
        "API_TOKEN",
        "SANDBOXED_MCP_TOKEN",
        "SANDBOXED_MCP_TOKEN_FILE",
    ] {
        process.env_remove(name);
    }
    process.env_remove("SANDBOXED_MCP_WRAPPER");
    if grok_acp {
        process.stdin(std::process::Stdio::piped());
    }
    process.kill_on_drop(true);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        process.as_std_mut().process_group(0);
        // The harness runs in its own process group. On a PTY that group must
        // be the terminal's foreground group, or the first read of its input
        // (the stdin pipe of a stream-json session) stops it with SIGTTIN.
        unsafe {
            process.pre_exec(|| {
                if libc::isatty(0) == 1 {
                    let previous = libc::signal(libc::SIGTTOU, libc::SIG_IGN);
                    libc::tcsetpgrp(0, libc::getpgrp());
                    libc::signal(libc::SIGTTOU, previous);
                }
                Ok(())
            });
        }
    }
    let mut child = process
        .spawn()
        .map_err(|_| "Could not start configured harness")?;
    let forwarding_failed = tokio_util::sync::CancellationToken::new();
    let forwarding = if grok_acp {
        let input = tokio::io::BufReader::new(tokio::io::stdin());
        let output = child.stdin.take().ok_or("Missing Grok ACP input")?;
        let server = file.ok_or("Missing Grok ACP server")?;
        let failed = forwarding_failed.clone();
        Some(tokio::spawn(async move {
            if forward_grok_acp(input, output, &server).await.is_err() {
                failed.cancel();
            }
        }))
    } else {
        None
    };
    #[cfg(unix)]
    let status = {
        use tokio::signal::unix::{signal, SignalKind};
        let mut terminate = signal(SignalKind::terminate())
            .map_err(|_| "Cannot install harness termination handler")?;
        let mut interrupt = signal(SignalKind::interrupt())
            .map_err(|_| "Cannot install harness interrupt handler")?;
        tokio::select! {
            status=child.wait()=>status.map_err(|_|"Cannot wait for harness")?,
            _=async{tokio::select!{_=terminate.recv()=>{},_=interrupt.recv()=>{},_=forwarding_failed.cancelled()=>{}}}=>{
                if let Some(pid)=child.id(){unsafe{libc::kill(-(pid as i32),libc::SIGTERM);}}
                match tokio::time::timeout(std::time::Duration::from_secs(5),child.wait()).await {
                    Ok(status)=>status.map_err(|_|"Cannot reap stopped harness")?,
                    Err(_)=>{if let Some(pid)=child.id(){unsafe{libc::kill(-(pid as i32),libc::SIGKILL);}}child.wait().await.map_err(|_|"Cannot reap killed harness")?}
                }
            }
        }
    };
    #[cfg(not(unix))]
    let status = child.wait().await.map_err(|_| "Cannot wait for harness")?;
    if let Some(task) = forwarding {
        task.abort();
    }
    drop(dir);
    if forwarding_failed.is_cancelled() {
        eprintln!("Grok ACP input could not be forwarded safely");
        std::process::exit(1);
    }
    if grok_acp {
        // Tokio stdin may still own a blocking OS read after abort. The child
        // is reaped and private files removed; do not hang runtime shutdown.
        std::process::exit(status.code().unwrap_or(1));
    }
    drop(overlay);
    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }
    Ok(())
}

fn grok_headless_profile(server: &Value) -> String {
    // Grok 1.0.41 accepts MCP definitions in an explicit agent file while
    // deliberately excluding them from GROK_CONFIG. Extend preserves its base
    // system prompt, native tools, skills and AGENTS.md discovery. No auth or
    // session directory is copied, and --session-id/--resume remain native.
    let profile = json!({"name":"sandboxed-runtime","description":"Native harness with mission-scoped tools","promptMode":"extend","mcpServers":[server]});
    format!("---\n{profile}\n---\n")
}

async fn forward_grok_acp<R, W>(mut input: R, mut output: W, server: &Value) -> Result<(), String>
where
    R: tokio::io::AsyncBufRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    use tokio::io::AsyncWriteExt;
    while let Some(frame) = super::protocol::read_frame(&mut input)
        .await
        .map_err(|_| "Cannot read ACP input")?
    {
        let mut frame = frame.map_err(|_| "ACP input exceeds 1 MiB")?;
        if let Ok(mut request) = serde_json::from_slice::<Value>(&frame) {
            if matches!(
                request["method"].as_str(),
                Some("session/new" | "session/load")
            ) {
                let params = request
                    .get_mut("params")
                    .and_then(Value::as_object_mut)
                    .ok_or("Invalid ACP session parameters")?;
                let servers = params
                    .entry("mcpServers")
                    .or_insert(json!([]))
                    .as_array_mut()
                    .ok_or("Invalid ACP MCP servers")?;
                servers
                    .retain(|entry| entry.get("name").and_then(Value::as_str) != Some("sandboxed"));
                servers.push(server.clone());
                frame = serde_json::to_vec(&request).map_err(|_| "Cannot encode ACP session")?;
            }
        }
        output
            .write_all(&frame)
            .await
            .map_err(|_| "Cannot forward ACP input")?;
        output
            .write_all(b"\n")
            .await
            .map_err(|_| "Cannot forward ACP newline")?;
        output.flush().await.map_err(|_| "Cannot flush ACP input")?;
    }
    output
        .shutdown()
        .await
        .map_err(|_| "Cannot close ACP input".to_string())
}
fn write_private(path: &Path, contents: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .map_err(|_| "Cannot create MCP runtime file")?;
    file.write_all(contents)
        .map_err(|_| "Cannot write MCP runtime file".into())
}

/// Called only by Core's trusted workspace launcher. The owner JWT stays in
/// this process and is exchanged for a mission-scoped credential.
pub async fn bootstrap(
    mission: uuid::Uuid,
    user: &crate::api::auth::AuthUser,
) -> Result<(String, String), String> {
    let port = std::env::var("PORT").unwrap_or_else(|_| "3000".into());
    let secret =
        std::env::var("JWT_SECRET").map_err(|_| "MCP launch requires Core authentication")?;
    let token = crate::api::auth::issue_jwt(&secret, 1, user)
        .map_err(|_| "Cannot authenticate MCP bootstrap")?
        .0;
    let url = format!("http://127.0.0.1:{port}");
    let client = Client::new(url, token, None, Role::Executor, Some(mission))?;
    let scoped = client.token().await?;
    let public = std::env::var("SANDBOXED_PUBLIC_URL")
        .or_else(|_| std::env::var("PUBLIC_BASE_URL"))
        .unwrap_or_else(|_| format!("http://127.0.0.1:{port}"));
    Ok((public, scoped))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vibe_scoped_mcp_preserves_other_servers_without_storing_credentials() {
        let existing = HashMap::from([(
            "VIBE_MCP_SERVERS".into(),
            json!([{"name":"other","transport":"stdio","command":"other-mcp"}]).to_string(),
        )]);
        let (args, env, file) = overlays(
            "vibe",
            "/bin/sandboxed-mcp",
            "https://core.test",
            "/private/credential",
            "mission",
            &existing,
            "/private/settings",
        )
        .unwrap();
        assert!(args.is_empty());
        assert!(file.is_none());
        let servers: Value = serde_json::from_str(&env["VIBE_MCP_SERVERS"]).unwrap();
        assert_eq!(servers[0]["name"], "other");
        assert_eq!(servers[1]["name"], "sandboxed");
        assert_eq!(servers[1]["command"], json!(["/bin/sandboxed-mcp"]));
        assert!(servers[1]["args"]
            .as_array()
            .unwrap()
            .contains(&json!("/private/credential")));
    }

    #[test]
    fn grok_headless_profile_extends_native_prompt_with_scoped_server() {
        let server = json!({"name":"sandboxed","command":"/mcp","args":["--token-file","/private/credential"],"env":[]});
        let profile = grok_headless_profile(&server);
        let parsed: Value = serde_yaml::from_str(
            profile
                .trim_start_matches("---\n")
                .trim_end_matches("---\n"),
        )
        .unwrap();
        assert_eq!(parsed["promptMode"], "extend");
        assert_eq!(parsed["mcpServers"], json!([server]));
        assert!(parsed.get("promptBody").is_none());
    }

    #[test]
    fn native_runtime_requires_owner_without_inventing_a_default_identity() {
        for harness in [
            "codex",
            "claudecode",
            "opencode",
            "grok",
            "antigravity",
            "vibe",
        ] {
            assert!(require_runtime_owner(harness, None).is_err());
            for id in ["", "  "] {
                let user = crate::api::auth::AuthUser {
                    id: id.into(),
                    username: "operator".into(),
                };
                assert!(require_runtime_owner(harness, Some(&user)).is_err());
            }
            let user = crate::api::auth::AuthUser {
                id: "actual-owner".into(),
                username: "operator".into(),
            };
            assert!(require_runtime_owner(harness, Some(&user)).is_ok());
        }
        assert!(require_runtime_owner("chatgpt_ui", None).is_ok());
    }

    #[tokio::test]
    async fn grok_acp_injects_new_and_resumed_sessions_without_changing_other_frames() {
        let server = json!({"name":"sandboxed","command":"/mcp","args":[],"env":[]});
        let initialize = r#"{"id":1,"method":"initialize","params":{"protocolVersion":1}}"#;
        let requests = format!(
            "{initialize}\n{}\n{}\n",
            json!({"id":2,"method":"session/new","params":{"cwd":"/work","mcpServers":[{"name":"other","command":"existing"},{"name":"sandboxed","command":"stale"}]}}),
            json!({"id":3,"method":"session/load","params":{"sessionId":"keep-session","cwd":"/work"}})
        );
        let mut output = Vec::new();
        forward_grok_acp(requests.as_bytes(), &mut output, &server)
            .await
            .unwrap();
        let output = String::from_utf8(output).unwrap();
        let lines: Vec<_> = output.lines().collect();
        assert_eq!(lines[0], initialize);
        let new: Value = serde_json::from_str(lines[1]).unwrap();
        assert_eq!(
            new["params"]["mcpServers"],
            json!([{"name":"other","command":"existing"},server])
        );
        let resumed: Value = serde_json::from_str(lines[2]).unwrap();
        assert_eq!(resumed["params"]["sessionId"], "keep-session");
        assert_eq!(resumed["params"]["mcpServers"], json!([server]));
    }

    #[tokio::test]
    async fn grok_acp_rejects_malformed_session_and_oversized_frames() {
        let server = json!({"name":"sandboxed"});
        for input in [
            r#"{"method":"session/new","params":{"mcpServers":false}}"#.to_string(),
            "x".repeat(1024 * 1024 + 1),
        ] {
            let mut output = Vec::new();
            assert!(forward_grok_acp(input.as_bytes(), &mut output, &server)
                .await
                .is_err());
            assert!(output.is_empty());
        }
    }
    #[test]
    fn flags_reach_the_cli_through_bun_and_native_plan_shell() {
        let flags = vec!["--mcp-config".into(), "/private/mcp.json".into()];
        let args = vec![
            "-c".into(),
            "cat | \"$@\"".into(),
            "orb-native-plan".into(),
            "/usr/bin/bun".into(),
            "/opt/claude.js".into(),
            "--print".into(),
        ];
        assert_eq!(
            harness_arguments("/bin/sh", &args, &flags).unwrap(),
            vec![
                "-c",
                "cat | \"$@\"",
                "orb-native-plan",
                "/usr/bin/bun",
                "/opt/claude.js",
                "--mcp-config",
                "/private/mcp.json",
                "--print"
            ]
        );
        assert!(
            harness_arguments("/bin/sh", &["-c".into(), "unknown script".into()], &flags).is_err()
        );
    }
    #[test]
    fn native_overlays_keep_existing_mcp_and_provider_settings() {
        let existing = HashMap::from([
            (
                "OPENCODE_CONFIG_CONTENT".into(),
                json!({"mcp":{"other":{"enabled":true}},"provider":{"custom":{"name":"existing"}}})
                    .to_string(),
            ),
            (
                "GROK_CONFIG".into(),
                json!({"mcp_servers":{"other":{"command":"existing"}}}).to_string(),
            ),
        ]);
        for harness in ["codex", "claudecode", "opencode", "grok", "antigravity"] {
            let (args, env, file) = overlays(
                harness,
                "/bin/sandboxed-mcp",
                "https://core.test",
                "/private/credential",
                "00000000-0000-0000-0000-000000000001",
                &existing,
                "/private/settings.json",
            )
            .unwrap();
            assert!(!format!("{args:?}{env:?}{file:?}").contains("mcp1."));
            if harness == "codex" {
                assert!(args
                    .iter()
                    .any(|arg| arg
                        == "mcp_servers.sandboxed.default_tools_approval_mode=\"approve\""));
                assert!(!args.iter().any(|arg| arg.starts_with("approval_policy=")));
            }
            if harness == "opencode" {
                let v: Value = serde_json::from_str(&env["OPENCODE_CONFIG_CONTENT"]).unwrap();
                assert_eq!(v["provider"]["custom"]["name"], "existing");
                assert_eq!(v["mcp"]["other"]["enabled"], true);
            }
            if harness == "grok" {
                assert!(!env.contains_key("GROK_CONFIG"));
                assert_eq!(file.as_ref().unwrap()["name"], "sandboxed");
                assert_eq!(file.as_ref().unwrap()["env"], json!([]));
            }
        }
    }
}

/// Only the mission launcher sets these variables; ordinary durable jobs do
/// not gain an implicit second harness or an MCP identity.
pub fn wrap_command(
    program: &str,
    args: &[String],
    env: &HashMap<String, String>,
) -> (String, Vec<String>) {
    match (
        env.get("SANDBOXED_MCP_WRAPPER"),
        env.get("SANDBOXED_MCP_HARNESS"),
    ) {
        (Some(wrapper), Some(harness)) => {
            let mut wrapped = vec![
                "launch".into(),
                "--harness".into(),
                harness.clone(),
                "--".into(),
                program.into(),
            ];
            wrapped.extend_from_slice(args);
            (wrapper.clone(), wrapped)
        }
        _ => (program.into(), args.into()),
    }
}
