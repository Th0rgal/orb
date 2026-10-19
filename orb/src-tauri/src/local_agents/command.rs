//! Building harness commands and probing installed CLIs.

use super::harness::vibe::vibe_python;
use super::*;
use std::io::Read;

pub(crate) const HARNESSES: &[(&str, &str)] = &[
    ("claudecode", "claude"),
    ("codex", "codex"),
    ("grok", "grok"),
    ("opencode", "opencode"),
    ("antigravity", "agy"),
    ("vibe", "vibe-acp"),
];

/// Human name of a harness, for user-facing messages.
pub(crate) fn harness_label(harness: &str) -> &'static str {
    match harness {
        "claudecode" => "Claude",
        "codex" => "Codex",
        "grok" => "Grok",
        "opencode" => "OpenCode",
        "antigravity" => "Antigravity",
        "vibe" => "Vibe",
        _ => "The harness",
    }
}

pub(crate) fn scan_local_agents(request: ScanRequest) -> Vec<ScanRow> {
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
            let interpreter_error = if *id == "vibe" {
                path.as_ref()
                    .and_then(|p| vibe_python(&p.to_string_lossy()).err())
            } else {
                None
            };
            ScanRow {
                models: vec![],
                auth_error: interpreter_error.clone(),
                id: (*id).to_string(),
                bin: (*bin).to_string(),
                // A slow version probe must not hide an installed CLI.
                installed: path.is_some() && interpreter_error.is_none(),
                plan_supported: version
                    .as_deref()
                    .is_some_and(|v| native_plan_supported(id, v)),
                path: path.map(|p| p.display().to_string()),
                version,
            }
        })
        .collect()
}

/// Launchers (notably Codex's Node shim) spawn another process. Stop must
/// address a dedicated group, never the desktop's inherited process group.
pub(crate) fn harness_command(bin: &str) -> Command {
    // Operator provisioning is outside project files. This also covers local
    // missions whose cwd is an existing checkout outside ~/.orb.
    let identity = std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(".config/sandboxed-sh/development-identity/launch"));
    harness_command_with_identity(bin, identity.as_deref())
}

pub(crate) fn harness_command_with_identity(bin: &str, identity: Option<&Path>) -> Command {
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

pub(crate) fn mission_command(request: &StartRequest, env: &[(String, String)]) -> Command {
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

// Conservative floors: these are the versions exercised by the native
// round-trip tests, not merely a CLI binary being present on PATH.
pub(crate) fn native_plan_supported(id: &str, version: &str) -> bool {
    let minimum = match id {
        "codex" => (0, 155, 0),
        "claudecode" => (2, 1, 278),
        "vibe" => (2, 19, 1),
        "antigravity" => (1, 2, 0),
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

pub(crate) fn version_of(path: &Path) -> Option<String> {
    command_output(Command::new(path).arg("--version"))
}

pub(crate) fn command_output(command: &mut Command) -> Option<String> {
    let mut child = command
        .stdin(Stdio::null())
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

/// The shape of a command line, safe to log: the program's file name, the
/// flag names and how many other arguments there are. Values (prompts,
/// config overrides, MCP definitions) and the environment are never logged.
pub(crate) fn argv_shape(command: &Command) -> Value {
    let program = Path::new(command.get_program())
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut flags = Vec::new();
    let mut values = 0usize;
    for arg in command.get_args() {
        let arg = arg.to_string_lossy();
        if arg.starts_with('-') && arg.len() > 1 && arg.len() <= 64 {
            flags.push(arg.split('=').next().unwrap_or_default().to_owned());
        } else {
            values += 1;
        }
    }
    json!({"program": program, "flags": flags, "values": values})
}

/// `Command::spawn` that logs the launch (or its failure) for the run.
pub(crate) trait SpawnLogged {
    fn spawn_logged(&mut self, ctx: &RunCtx) -> std::io::Result<Child>;
}

impl SpawnLogged for Command {
    fn spawn_logged(&mut self, ctx: &RunCtx) -> std::io::Result<Child> {
        let shape = argv_shape(self);
        let spawned = self.spawn();
        match &spawned {
            Ok(child) => crate::orb_log!(
                info,
                "spawn",
                mission = ctx.mission,
                harness = ctx.harness,
                pid = child.id(),
                extra = json!({"argv": shape})
            ),
            Err(error) => crate::orb_log!(
                error,
                "spawn_failed",
                mission = ctx.mission,
                harness = ctx.harness,
                extra = json!({"argv": shape, "error": error.to_string()})
            ),
        }
        spawned
    }
}

#[cfg(test)]
mod shape_tests {
    use super::*;

    #[test]
    fn argv_shape_names_flags_but_never_values() {
        let mut command = Command::new("/opt/bin/claude");
        command
            .args(["--print", "--model", "opus", "-c", "token=secret"])
            .arg("--settings={\"key\":\"v\"}")
            .arg("Write the secret plan")
            .env("API_KEY", "sk-live");
        let shape = argv_shape(&command);
        assert_eq!(shape["program"], "claude");
        assert_eq!(
            shape["flags"],
            json!(["--print", "--model", "-c", "--settings"])
        );
        assert_eq!(shape["values"], 3);
        let text = shape.to_string();
        assert!(!text.contains("secret") && !text.contains("sk-live") && !text.contains("opus"));
    }
}
