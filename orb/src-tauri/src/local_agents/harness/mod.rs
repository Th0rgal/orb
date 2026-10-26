//! One module per native protocol. Each `spawn` starts the CLI, wires its
//! pipes to the run's `RunCtx` and returns the child for the exit watcher.

use super::*;

pub(crate) mod antigravity;
pub(crate) mod claude;
pub(crate) mod claude_models;
pub(crate) mod codex;
pub(crate) mod piped;
pub(crate) mod vibe;

pub(crate) fn spawn_harness(
    request: &StartRequest,
    ctx: &RunCtx,
    env: &[(String, String)],
    recheck_delays: &[Duration],
) -> Result<Child, String> {
    match request.harness.as_str() {
        "antigravity" => antigravity::spawn(request, ctx, env),
        "vibe" => vibe::spawn(request, ctx, env),
        "claudecode" => claude::spawn(request, ctx, env, recheck_delays),
        "codex" => codex::spawn(request, ctx, env),
        "grok" => piped::spawn(request, &piped::Grok, ctx, env),
        "opencode" => piped::spawn(request, &piped::OpenCode, ctx, env),
        other => Err(format!("unknown local harness {other}")),
    }
}
