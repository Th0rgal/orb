//! Remote harness planning and launch command construction.

use super::*;

/// Terminal bookkeeping shared by the sync (`/execute`) and async (job) remote
/// paths: log the final assistant message, flip the mission to
/// completed/failed with `status_reason`, and broadcast the status change.
#[derive(Clone)]
pub(crate) struct RemoteMissionOwner {
    pub(super) mission_store: Arc<dyn MissionStore>,
    pub(super) events_tx: Option<broadcast::Sender<AgentEvent>>,
}

impl RemoteMissionOwner {
    pub(super) fn live(control: &ControlState) -> Self {
        Self {
            mission_store: Arc::clone(&control.mission_store),
            events_tx: Some(control.events_tx.clone()),
        }
    }

    pub(super) fn offline(mission_store: Arc<dyn MissionStore>) -> Self {
        Self {
            mission_store,
            events_tx: None,
        }
    }

    /// Native streaming events have one persistence owner. Live events are
    /// saved in broadcast order by the session logger; direct writes would
    /// race queued deltas and place them after the canonical assistant message.
    /// Recovery without a live session still needs durable events.
    pub(super) async fn publish_native(&self, event: AgentEvent) {
        if self.events_tx.is_none() {
            if let Some(id) = event.mission_id() {
                let _ = self.mission_store.log_event(id, &event).await;
            }
        }
        self.send(event);
    }

    pub(super) fn send(&self, event: AgentEvent) {
        if let Some(events_tx) = &self.events_tx {
            let _ = events_tx.send(event);
        }
    }
}

/// Harnesses a remote node can run for a typed launch. Nodes ship the
/// `claude`, `opencode`, and native `grok` CLIs. Other harnesses are rejected
/// before the mission exists instead of being silently swapped.
pub(crate) const REMOTE_NODE_HARNESSES: &[&str] = &[
    "claudecode",
    "opencode",
    "grok",
    "codex",
    "antigravity",
    "vibe",
];

/// Stable prefixes of the plain-text `400` bodies a typed remote launch can
/// return before any mission exists. Clients match on the prefix, not the
/// prose.
pub(crate) const REMOTE_HARNESS_UNSUPPORTED: &str = "REMOTE_HARNESS_UNSUPPORTED";
pub(crate) const REMOTE_PROMPT_REQUIRED: &str = "REMOTE_PROMPT_REQUIRED";
pub(crate) const REMOTE_MODEL_REQUIRED: &str = "REMOTE_MODEL_REQUIRED";

/// Capability block advertised on `GET /api/remote-nodes` so clients can tell
/// a backend that plans typed launches server-side from one that still
/// requires a raw `remote_command` (the field is absent there).
pub(crate) fn remote_launch_capabilities() -> crate::remote_node::RemoteLaunchCapabilities {
    crate::remote_node::RemoteLaunchCapabilities {
        typed: true,
        requires_proxy_harnesses: vec![
            "claudecode".into(),
            "opencode".into(),
            "codex".into(),
            "vibe".into(),
        ],
        harnesses: REMOTE_NODE_HARNESSES
            .iter()
            .map(|h| h.to_string())
            .collect(),
        raw_command: true,
        proxy_url_configured: super::super::mission_runner::public_api_base_url_from_env()
            .is_some(),
        error_prefixes: vec![
            REMOTE_HARNESS_UNSUPPORTED.to_string(),
            REMOTE_PROMPT_REQUIRED.to_string(),
            REMOTE_MODEL_REQUIRED.to_string(),
            "REMOTE_GOAL_UNSUPPORTED".to_string(),
            remote_grok::REMOTE_AUTH_REQUIRED.to_string(),
        ],
    }
}

/// What a remote mission will execute on its node, decided by the server
/// from the client's selection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RemoteHarnessPlan {
    Vibe {
        plan: bool,
        model: Option<String>,
        prompt: String,
        resume_session_id: Option<String>,
    },
    Antigravity {
        effort: Option<String>,
        model: Option<String>,
        prompt: String,
        resume_session_id: Option<String>,
    },
    Codex {
        effort: Option<String>,
        fast_mode: bool,
        service_tier: Option<crate::codex_speed::Tier>,
        model: String,
        prompt: String,
        resume_session_id: Option<String>,
    },
    Grok {
        model: Option<String>,
        prompt: String,
        resume_session_id: Option<String>,
        new_session_id: Option<String>,
    },
    /// Explicit `remote_command` compatibility: runs verbatim, own auth.
    Raw { command: String },
    /// Claude Code CLI on the node, model routed through this core's proxy.
    ClaudeCode {
        resume_session_id: Option<String>,
        model: Option<String>,
        prompt: String,
    },
    /// OpenCode CLI on the node, model routed through this core's
    /// OpenAI-compatible proxy endpoint.
    OpenCode {
        model: Option<String>,
        prompt: String,
        resume_session_id: Option<String>,
    },
}

impl RemoteHarnessPlan {
    pub(crate) fn uses_core_proxy(&self) -> bool {
        matches!(
            self,
            RemoteHarnessPlan::ClaudeCode { .. }
                | RemoteHarnessPlan::Vibe { .. }
                | RemoteHarnessPlan::OpenCode { .. }
                | RemoteHarnessPlan::Codex { .. }
        )
    }

    pub(crate) fn label(&self) -> String {
        match self {
            RemoteHarnessPlan::Antigravity { model, .. } => format!(
                "antigravity/{}",
                model.as_deref().unwrap_or("account default")
            ),
            RemoteHarnessPlan::Codex { model, .. } => format!("codex/{model}"),
            RemoteHarnessPlan::Vibe { model, .. } => format!(
                "vibe/{}",
                model
                    .as_deref()
                    .unwrap_or("mistral/mistral-vibe-cli-latest")
            ),
            RemoteHarnessPlan::Raw { .. } => "raw command".to_string(),
            RemoteHarnessPlan::Grok { model, .. } => {
                format!("grok/{}", model.as_deref().unwrap_or("node default model"))
            }
            RemoteHarnessPlan::ClaudeCode { model, .. } => format!(
                "claudecode/{}",
                model.as_deref().unwrap_or("node default model")
            ),
            RemoteHarnessPlan::OpenCode { model, .. } => format!(
                "opencode/{}",
                model.as_deref().unwrap_or("node default model")
            ),
        }
    }
}

pub(super) async fn validate_remote_vibe_auth(
    working_dir: &std::path::Path,
    plan: &RemoteHarnessPlan,
) -> Result<(), String> {
    if matches!(plan, RemoteHarnessPlan::Vibe { .. })
        && !crate::backend::vibe::core_auth_configured(working_dir).await
    {
        return Err(
            "Connect an enabled Mistral provider in Core before starting remote Mistral Vibe"
                .into(),
        );
    }
    Ok(())
}

/// Decide the node execution for a remote launch. An explicit raw command
/// wins (compatibility with scripted callers). Otherwise the selected
/// backend must be one nodes can run and the prompt must be present; a
/// selection nodes cannot honour is an explicit error naming what is
/// supported, never a fallback to a different harness.
pub(crate) fn plan_remote_harness(
    remote_command: Option<&str>,
    backend: &str,
    model_override: Option<&str>,
    prompt: Option<&str>,
) -> Result<RemoteHarnessPlan, String> {
    if let Some(command) = remote_command.map(str::trim).filter(|c| !c.is_empty()) {
        return Ok(RemoteHarnessPlan::Raw {
            command: command.to_string(),
        });
    }
    let prompt = prompt
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .ok_or_else(|| {
            format!("{REMOTE_PROMPT_REQUIRED}: a remote launch needs a prompt (or an explicit remote_command)")
        })?
        .to_string();
    let model = model_override
        .map(str::trim)
        .filter(|m| !m.is_empty())
        .map(str::to_string);
    match backend {
        "vibe" => Ok(RemoteHarnessPlan::Vibe { plan: crate::vibe::plan_mode(None, &prompt), model, prompt, resume_session_id: None }),
        "codex" => Ok(RemoteHarnessPlan::Codex {
            effort: None,
            fast_mode: false,
            service_tier: None,
            model: model.ok_or_else(|| format!("{REMOTE_MODEL_REQUIRED}: a Codex remote launch needs model_override"))?,
            prompt,
            resume_session_id: None,
        }),
        "grok" => Ok(remote_grok::plan(model, prompt)),
        "antigravity" => {
            crate::antigravity::validate_prompt(&prompt)?;
            Ok(RemoteHarnessPlan::Antigravity { effort: None, model, prompt, resume_session_id: None })
        }
        "claudecode" => Ok(RemoteHarnessPlan::ClaudeCode {
            resume_session_id: None,
            // Claude Code expects bare model ids.
            model: model.map(|m| {
                m.strip_prefix("anthropic/")
                    .map(str::to_string)
                    .unwrap_or(m)
            }),
            prompt,
        }),
        "opencode" => {
            // A node has no authenticated default provider: the only model
            // that can run there is the one this core registers and routes.
            // The exact id is the provider map key; a client-supplied
            // `builtin/` prefix is the local runner's argument shape, not
            // part of the id.
            let model = model
                .map(|m| m.trim_start_matches("builtin/").to_string())
                .filter(|m| !m.is_empty())
                .ok_or_else(|| {
                    format!(
                        "{REMOTE_MODEL_REQUIRED}: an OpenCode remote launch needs model_override (provider/model, e.g. xai/grok-4.6); nodes have no authenticated default model"
                    )
                })?;
            Ok(RemoteHarnessPlan::OpenCode {
                resume_session_id: None,
                model: Some(model),
                prompt,
            })
        }
        other => Err(format!(
            "{REMOTE_HARNESS_UNSUPPORTED}: backend '{other}' cannot run on remote nodes: only {} are installed there. \
             Pick one of those, \
             or pass an explicit remote_command.",
            REMOTE_NODE_HARNESSES.join(" or ")
        )),
    }
}

/// Concrete node job for a plan: the shell command plus the environment the
/// node injects into it (proxy URL/key never appear in the command line).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemoteExecution {
    pub(crate) managed_auth: Vec<String>,
    pub(crate) command: String,
    pub(crate) env: Option<HashMap<String, String>>,
    pub(crate) label: String,
}

pub(super) fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// Env var the node job receives the per-mission proxy key in. The OpenCode
/// config references it (`{env:…}`) so neither the config nor the command
/// line ever contains the secret.
pub(crate) const REMOTE_PROXY_KEY_ENV: &str = "SANDBOXED_PROXY_API_KEY";
/// OpenCode reads an inline JSON config from this env var (verified with the
/// installed 1.18 CLI), so the job never writes into or overwrites a cwd
/// `opencode.json`.
pub(crate) const REMOTE_OPENCODE_CONFIG_ENV: &str = "OPENCODE_CONFIG_CONTENT";

/// Prompts are positional CLI arguments; one starting with `-` would be
/// parsed as an option (and yargs' `--` terminator swallows the message on
/// `opencode run`, verified). A leading space is inert for the model and
/// keeps the argument positional on every CLI version.
/// Linux caps one argv/env string at 128 KiB (MAX_ARG_STRLEN) and the whole
/// argv+envp at ARG_MAX (usually 2 MiB). Node jobs run `bash -lc <command>`,
/// so a forked conversation inlined as a positional prompt failed with
/// "Argument list too long" (fork 0a9943ec, 370 KB).
pub(super) const INLINE_PROMPT_LIMIT: usize = 96 * 1024;
pub(super) const STDIN_PROMPT_CHUNK: usize = 96 * 1024;
pub(super) const STDIN_PROMPT_LIMIT: usize = 1024 * 1024;
pub(super) const STDIN_PROMPT_ENV: &str = "SANDBOXED_PROMPT_PART_";

pub(super) struct StdinPrompt {
    /// Shell that reassembles the prompt on fd 3 and drops the parts from the
    /// environment, so the harness and its tools do not inherit them.
    pub(super) prelude: String,
    pub(super) env: HashMap<String, String>,
}

/// Stage a long prompt for stdin delivery; `None` keeps it inline.
pub(super) fn stdin_prompt(prompt: &str) -> Option<StdinPrompt> {
    // Measure what lands in argv: quoting expands each `'` to four bytes.
    if shell_single_quote(&positional_prompt(prompt)).len() <= INLINE_PROMPT_LIMIT {
        return None;
    }
    let prompt = prompt.replace('\0', "");
    let prompt = if prompt.len() > STDIN_PROMPT_LIMIT {
        // Keep the objective at the head and the latest turns at the tail.
        let marker = "\n\n[Middle of this prompt omitted: it exceeded the remote launch limit. Inspect workspace evidence as needed.]\n\n";
        let mut head = STDIN_PROMPT_LIMIT / 4;
        while !prompt.is_char_boundary(head) {
            head -= 1;
        }
        let mut tail = prompt.len() - (STDIN_PROMPT_LIMIT - head - marker.len());
        while !prompt.is_char_boundary(tail) {
            tail += 1;
        }
        format!("{}{marker}{}", &prompt[..head], &prompt[tail..])
    } else {
        prompt
    };
    let mut env = HashMap::new();
    let mut names = Vec::new();
    let mut rest = prompt.as_str();
    while !rest.is_empty() {
        let mut end = rest.len().min(STDIN_PROMPT_CHUNK);
        while !rest.is_char_boundary(end) {
            end -= 1;
        }
        let name = format!("{STDIN_PROMPT_ENV}{}", names.len());
        env.insert(name.clone(), rest[..end].to_string());
        names.push(name);
        rest = &rest[end..];
    }
    let parts: Vec<String> = names.iter().map(|name| format!("\"${name}\"")).collect();
    let prelude = format!(
        "sandboxed_prompt=\"$(mktemp)\" || exit 1; printf %s {} > \"$sandboxed_prompt\" || exit 1; \
         exec 3< \"$sandboxed_prompt\"; rm -f -- \"$sandboxed_prompt\"; unset sandboxed_prompt {}; ",
        parts.join(" "),
        names.join(" "),
    );
    Some(StdinPrompt { prelude, env })
}

pub(super) fn positional_prompt(prompt: &str) -> String {
    if prompt.starts_with('-') {
        format!(" {prompt}")
    } else {
        prompt.to_string()
    }
}

/// OpenCode on a node reaches this core exactly like a local OpenCode
/// mission does: a `builtin` provider (`@ai-sdk/openai-compatible`, base URL
/// `<core>/v1`) whose model map carries the exact requested id, so the proxy
/// receives `xai/grok-4.6` (or any `provider/model`) unchanged and applies
/// its own chain/passthrough resolution. The stock `openai` provider only
/// advertises OpenAI's catalog and would reject non-GPT ids before any
/// request.
/// Conservative window for proxy-routed models: every chain member offers at least this.
pub(super) const REMOTE_OPENCODE_CONTEXT_LIMIT: u64 = 200_000;
pub(super) const REMOTE_OPENCODE_OUTPUT_LIMIT: u64 = 32_000;

pub(crate) fn remote_opencode_config(model: &str, api_base_url: &str) -> serde_json::Value {
    serde_json::json!({
        "$schema": "https://opencode.ai/config.json",
        "permission": {
            "*": "allow",
            "external_directory": { "*": "allow" },
            "doom_loop": "allow",
            "read": { "*": "allow" }
        },
        "provider": {
            "builtin": {
                "npm": "@ai-sdk/openai-compatible",
                "name": "Builtin",
                // A declared window lets OpenCode compact before the prompt outgrows the
                // smallest member of a chain (mission 64619ac7 overflowed the Spark's 262k
                // window with 32k output reserved and no limit known, then hung).
                "models": { model: { "name": model, "limit": { "context": REMOTE_OPENCODE_CONTEXT_LIMIT, "output": REMOTE_OPENCODE_OUTPUT_LIMIT } } },
                "options": {
                    "baseURL": format!("{}/v1", api_base_url.trim_end_matches('/')),
                    "apiKey": format!("{{env:{REMOTE_PROXY_KEY_ENV}}}")
                }
            }
        }
    })
}

/// `--model` argument for the node: `builtin/<exact id>` (the local runner's
/// `opencode_model_argument` shape for proxy-routed models).
pub(super) fn remote_opencode_model_argument(model: &str) -> String {
    match model.strip_prefix("builtin/") {
        Some(_) => model.to_string(),
        None => format!("builtin/{model}"),
    }
}

pub(crate) fn remote_execution_for_plan(
    plan: &RemoteHarnessPlan,
    api_base_url: &str,
    proxy_key: &str,
) -> RemoteExecution {
    let label = plan.label();
    match plan {
        RemoteHarnessPlan::Vibe {
            plan,
            model,
            prompt,
            resume_session_id,
        } => {
            let staged = stdin_prompt(prompt);
            let mut args = crate::vibe::args(
                "vibe-acp",
                "runtime",
                Some(
                    model
                        .as_deref()
                        .unwrap_or("mistral/mistral-vibe-cli-latest"),
                ),
                resume_session_id.as_deref(),
                if staged.is_some() { "" } else { prompt },
                *plan,
                false,
            );
            let mut env = HashMap::from([
                (
                    "SANDBOXED_VIBE_PROXY_URL".into(),
                    format!("{}/v1", api_base_url.trim_end_matches('/')),
                ),
                ("SANDBOXED_VIBE_PROXY_KEY".into(), proxy_key.into()),
            ]);
            let prelude = if let Some(staged) = staged {
                let index = args.iter().position(|arg| arg == "--prompt").unwrap();
                args[index] = "--prompt-file".into();
                args[index + 1] = "/dev/fd/3".into();
                env.extend(staged.env);
                staged.prelude
            } else {
                String::new()
            };
            RemoteExecution {
                managed_auth: Vec::new(),
                command: format!(
                    "{prelude}exec python3 {}",
                    args.iter()
                        .map(|arg| shell_single_quote(arg))
                        .collect::<Vec<_>>()
                        .join(" ")
                ),
                env: Some(env),
                label,
            }
        }

        RemoteHarnessPlan::Codex {
            effort,
            fast_mode,
            service_tier,
            model,
            prompt,
            resume_session_id,
        } => {
            let mut settings = vec![
                "model_provider=\"sandboxed\"".to_string(),
                "model_providers.sandboxed.name=\"Sandboxed\"".to_string(),
                format!(
                    "model_providers.sandboxed.base_url={}",
                    serde_json::to_string(&format!("{}/v1", api_base_url.trim_end_matches('/')))
                        .unwrap()
                ),
                "model_providers.sandboxed.wire_api=\"responses\"".to_string(),
                format!("model_providers.sandboxed.env_key=\"{REMOTE_PROXY_KEY_ENV}\""),
                crate::harness_attribution::CODEX_CONFIG_OVERRIDE.to_string(),
            ];
            if let Some(effort) = effort {
                settings.push(format!(
                    "model_reasoning_effort={}",
                    serde_json::to_string(effort).unwrap()
                ));
            }
            let tier = crate::codex_speed::Tier::from_legacy(*service_tier, *fast_mode);
            settings.push(format!("service_tier=\"{}\"", tier.wire()));
            settings.push(format!(
                "model_providers.sandboxed.http_headers.x-sandboxed-codex-speed=\"{}\"",
                tier.wire()
            ));
            let configuration = serde_json::json!({"model": model, "prompt": prompt, "session": resume_session_id, "settings": settings});
            // Embed the versioned driver in the job; no node install race, no
            // secret in argv. Native app-server owns the goal continuation loop.
            let command = format!(
                "exec python3 -c {} {}",
                shell_single_quote(include_str!("../../../scripts/remote_codex_app_server.py")),
                shell_single_quote(&configuration.to_string())
            );
            RemoteExecution {
                managed_auth: Vec::new(),
                command,
                label,
                env: Some(HashMap::from([
                    (REMOTE_PROXY_KEY_ENV.to_string(), proxy_key.to_string()),
                    ("NO_COLOR".to_string(), "1".to_string()),
                ])),
            }
        }
        RemoteHarnessPlan::Grok {
            model,
            prompt,
            resume_session_id,
            new_session_id,
        } => remote_grok::execution(
            model.as_deref(),
            prompt,
            resume_session_id.as_deref(),
            new_session_id.as_deref(),
            label,
        ),
        RemoteHarnessPlan::Antigravity {
            effort,
            model,
            prompt,
            resume_session_id,
        } => {
            // `/plan …` maps to agy's `--mode plan` (shared args builder, local and remote).
            let plan_body = crate::antigravity::plan_request(prompt);
            let staged = stdin_prompt(plan_body.unwrap_or(prompt));
            let mut args = crate::antigravity::args_with_effort(
                model.as_deref(),
                effort.as_deref(),
                resume_session_id.as_deref(),
                if staged.is_some() { "" } else { prompt },
            );
            if staged.is_some() && plan_body.is_some() {
                let at = args.len() - 1;
                args.splice(at..at, ["--mode".to_string(), "plan".to_string()]);
            }
            let mut env = HashMap::from([("NO_COLOR".into(), "1".into())]);
            let (prelude, quoted_args) = if let Some(staged) = staged {
                let mut quoted: Vec<String> = args[..args.len() - 1]
                    .iter()
                    .map(|arg| shell_single_quote(arg))
                    .collect();
                quoted.push("\"$(cat <&3)\"".into());
                env.extend(staged.env);
                (staged.prelude, quoted.join(" "))
            } else {
                (
                    String::new(),
                    args.iter()
                        .map(|arg| shell_single_quote(arg))
                        .collect::<Vec<_>>()
                        .join(" "),
                )
            };
            RemoteExecution {
                managed_auth: vec!["antigravity".into()],
                // stderr used to go to /dev/null, so a resume that died before
                // its first event left an empty job log. Keep it in the log
                // (Core parses `AGY_ERROR:` markers and shows diagnostics) but
                // drop lines that could carry OAuth URLs or tokens.
                command: format!(
                    "{prelude}exec agy {quoted_args} 2> >({ANTIGRAVITY_STDERR_FILTER} >&2)"
                ),
                env: Some(env),
                label,
            }
        }
        RemoteHarnessPlan::Raw { command } => RemoteExecution {
            managed_auth: Vec::new(),
            command: command.clone(),
            env: None,
            label,
        },
        RemoteHarnessPlan::ClaudeCode {
            model,
            prompt,
            resume_session_id,
        } => {
            let plan_body = strip_remote_plan_prefix(prompt);
            let mut command = String::from(
                "command -v claude >/dev/null 2>&1 || { echo 'claude is not installed on this node' >&2; exit 127; }; \
                 claude -p --dangerously-skip-permissions --output-format stream-json --verbose --include-partial-messages",
            );
            command.push_str(" --settings ");
            command.push_str(&shell_single_quote(
                &crate::harness_attribution::claude_settings_arg(),
            ));
            if plan_body.is_some() {
                command.push_str(" --permission-mode plan");
            }
            if let Some(model) = model {
                command.push_str(" --model ");
                command.push_str(&shell_single_quote(model));
            }
            if let Some(session) = resume_session_id {
                command.push_str(" --resume ");
                command.push_str(&shell_single_quote(session));
            }
            let effective_prompt = plan_body.unwrap_or(prompt.as_str());
            let mut env = HashMap::from([
                ("ANTHROPIC_BASE_URL".to_string(), api_base_url.to_string()),
                ("ANTHROPIC_AUTH_TOKEN".to_string(), proxy_key.to_string()),
                ("NO_COLOR".to_string(), "1".to_string()),
                ("GH_NO_PAGER".to_string(), "1".to_string()),
                ("GH_PROMPT_DISABLED".to_string(), "1".to_string()),
            ]);
            match stdin_prompt(effective_prompt) {
                None => {
                    command.push(' ');
                    command.push_str(&shell_single_quote(&positional_prompt(effective_prompt)));
                }
                Some(staged) => {
                    command = format!("{}{command} <&3", staged.prelude);
                    env.extend(staged.env);
                }
            }
            RemoteExecution {
                managed_auth: Vec::new(),
                command,
                env: Some(env),
                label,
            }
        }
        RemoteHarnessPlan::OpenCode {
            model,
            prompt,
            resume_session_id,
        } => {
            let plan_body = strip_remote_plan_prefix(prompt);
            // Inline config through OPENCODE_CONFIG_CONTENT: nothing is
            // written into the job cwd (the node's per-mission directory,
            // also its HOME), and nothing depends on the service user's home.
            let mut command = String::from(
                "command -v opencode >/dev/null 2>&1 || { echo 'opencode is not installed on this node' >&2; exit 127; }; \
                 opencode run --format json --thinking",
            );
            if plan_body.is_some() {
                command.push_str(" --agent plan");
            }
            let mut env = HashMap::from([
                (REMOTE_PROXY_KEY_ENV.to_string(), proxy_key.to_string()),
                ("NO_COLOR".to_string(), "1".to_string()),
            ]);
            // `plan_remote_harness` guarantees a model for OpenCode; the
            // config registers exactly that id under `builtin`.
            let model = model.as_deref().unwrap_or_default();
            if let Some(session) = resume_session_id {
                command.push_str(" --session ");
                command.push_str(&shell_single_quote(session));
            }
            command.push_str(" --model ");
            command.push_str(&shell_single_quote(&remote_opencode_model_argument(model)));
            env.insert(
                REMOTE_OPENCODE_CONFIG_ENV.to_string(),
                remote_opencode_config(model, api_base_url).to_string(),
            );
            let effective_prompt = plan_body.unwrap_or(prompt.as_str());
            // A transferred conversation can exceed ARG_MAX (E2BIG). `opencode run` appends
            // non-TTY stdin to the message, so long prompts go through the same staged fd 3
            // as the other harnesses instead of argv.
            match stdin_prompt(effective_prompt) {
                None => {
                    command.push(' ');
                    command.push_str(&shell_single_quote(&positional_prompt(effective_prompt)));
                }
                Some(staged) => {
                    command = format!("{}{command} <&3", staged.prelude);
                    env.extend(staged.env);
                }
            }
            RemoteExecution {
                managed_auth: Vec::new(),
                command,
                env: Some(env),
                label,
            }
        }
    }
}

pub(super) fn strip_remote_plan_prefix(prompt: &str) -> Option<&str> {
    let rest = prompt.trim_start().strip_prefix("/plan")?;
    if !rest.is_empty() && !rest.starts_with(char::is_whitespace) {
        return None;
    }
    let body = rest.trim_start();
    Some(if body.is_empty() {
        "Review the conversation and workspace, then propose an implementation plan before making changes."
    } else {
        body
    })
}

/// Name of the per-mission proxy key a typed remote launch mints. Keyed by
/// mission so a re-attached observer or a boot sweep can retire it by name.
pub(crate) fn remote_launch_key_name(mission_id: Uuid) -> String {
    format!("remote-launch:{mission_id}")
}
