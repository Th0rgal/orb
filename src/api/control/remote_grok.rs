//! Native Grok Build CLI as a typed remote launch.
//!
//! A `backend: "grok"` launch runs the real `grok` CLI on the node (not an
//! OpenCode stand-in): `grok --output-format streaming-json --always-approve
//! [--model <id>] (--session-id <new> | --resume <existing>) -p <prompt>` under the node's raw job
//! executor, which clears the environment and sets `HOME` to the per-mission
//! job directory. Three things distinguish it from the Claude/OpenCode plans:
//!
//! - **Auth is node-managed.** Grok >= 1.0 authenticates through its own
//!   cached login (`$GROK_HOME/auth.json`), not a proxy key, so the job asks
//!   the node for the `grok` managed-auth profile by *name*
//!   (`JobPayload::RawCommand::managed_auth`). The node exports
//!   `GROK_HOME=<its configured trusted dir>`; no credential and no path is
//!   ever in the payload, the job database, the command line or the logs.
//!   The command still fails closed (exit 78) on a node that ignores the
//!   field, instead of hanging on the CLI's interactive sign-in.
//! - **Events stream.** The observer reads the job log incrementally
//!   (`GET /jobs/:id/log?offset=`), parses the CLI's streaming-json lines and
//!   broadcasts `Thinking`/`TextDelta`/`SessionIdUpdate` like the local
//!   runner. New session UUIDs are persisted under the run generation before
//!   dispatch, so interruption before the `end` event remains resumable.
//! - **Goals are native.** Grok 1.0.34 executes literal `/goal <objective>`
//!   through planning, implementation and verification. A paused native goal
//!   continues with `--resume <session> -p '/goal resume'`. The host never
//!   wraps prompts in sentinels or launches its own iteration loop.
//!
//! Resume/continuation of an existing remote Grok mission submits a new job
//! on the same node with `--resume`; other remote harnesses (and a node that
//! is no longer configured) are reported as needing a replacement mission.

use std::collections::{HashSet, VecDeque};
use std::sync::{Arc, LazyLock, Mutex};

use axum::http::StatusCode;
use uuid::Uuid;

use super::{
    positional_prompt, resolve_grok_default_model, shell_single_quote, AgentEvent, ControlState,
    MissionStatus, RemoteExecution, RemoteHarnessPlan, RemoteMissionOwner,
};
use crate::api::mission_store::{Mission, MissionStore, SessionUpdateRun};
use crate::api::routes::AppState;
use crate::api::runners::grok::{
    grok_event_is_error, grok_event_model, grok_event_reasoning, grok_event_session_id,
    grok_event_text, grok_line_requests_interactive_login,
};
use crate::remote_node::{
    self, JobLogChunk, NodeJobStatus, RemoteNodeClient, RemoteNodeConfig, RemoteNodeError,
};

/// Backend id of the Grok Build harness.
pub(crate) const GROK_BACKEND: &str = "grok";
/// Managed-auth profile the node must provide (see `crate::node::managed_auth`).
pub(crate) const MANAGED_AUTH_PROFILE: &str = crate::node::managed_auth::PROFILE_GROK;
/// Exit status of the job wrapper when the node did not inject `GROK_HOME`
/// (a node predating managed auth, or one whose profile went away between
/// the heartbeat and the job).
pub(crate) const MISSING_MANAGED_AUTH_EXIT: i32 = 78;
/// Stable `400` prefix: the selected node advertises no `grok` managed auth.
pub(crate) const REMOTE_AUTH_REQUIRED: &str = "REMOTE_AUTH_REQUIRED";
/// Stable `409` prefix: the mission cannot be continued on its node and a
/// replacement mission must be created instead.
pub(crate) const REMOTE_RESUME_REQUIRES_REPLACEMENT: &str = "REMOTE_RESUME_REQUIRES_REPLACEMENT";
/// Stable `409` prefix: the node job of this mission is still live.
pub(crate) const REMOTE_JOB_STILL_RUNNING: &str = "REMOTE_JOB_STILL_RUNNING";

/// Arguments verified with native Grok 1.0.34 on DGX.
pub(crate) const GROK_HEADLESS_ARGS: &[&str] = &[
    "--output-format",
    "streaming-json",
    "--always-approve",
    "--no-plan",
];

/// Source tag on user messages a remote resume injects.
const RESUME_SOURCE: &str = "remote_grok:resume";
/// Bound on the diagnostic (non-JSON) log lines kept for a failure report.
const DIAGNOSTIC_LINES: usize = 40;
/// Log chunks fetched per poll tick before yielding to the state poll.
const MAX_CHUNKS_PER_TICK: usize = 8;

// ─── Plan / execution ────────────────────────────────────────────────────────

/// Preserve native slash commands verbatim, including `/goal` and its budget.
pub(crate) fn plan(model: Option<String>, prompt: String) -> RemoteHarnessPlan {
    RemoteHarnessPlan::Grok {
        model: Some(model.unwrap_or_else(resolve_grok_default_model)),
        prompt,
        resume_session_id: None,
        new_session_id: Some(Uuid::new_v4().to_string()),
    }
}

/// Node job for a Grok plan. The command fails closed (exit 127 / 78) when
/// the CLI or the managed auth environment is missing, so an unsupported
/// node produces a fast, explicit failure instead of an interactive login
/// prompt that blocks until the job timeout.
pub(crate) fn execution(
    model: Option<&str>,
    prompt: &str,
    resume_session_id: Option<&str>,
    new_session_id: Option<&str>,
    label: String,
) -> RemoteExecution {
    let mut command = String::from(
        "command -v grok >/dev/null 2>&1 || { echo 'grok is not installed on this node' >&2; exit 127; }; \
         [ -n \"${GROK_HOME:-}\" ] && [ -r \"${GROK_HOME}/auth.json\" ] || { echo 'grok managed auth is not available in this job: the node must set SANDBOXED_NODE_GROK_HOME to a directory logged in with `grok login --device-auth` (see docs/REMOTE_NODES.md)' >&2; exit ",
    );
    command.push_str(&MISSING_MANAGED_AUTH_EXIT.to_string());
    command.push_str("; }; exec grok");
    for arg in GROK_HEADLESS_ARGS {
        command.push(' ');
        command.push_str(arg);
    }
    if let Some(model) = model.map(str::trim).filter(|m| !m.is_empty()) {
        command.push_str(" --model ");
        command.push_str(&shell_single_quote(model));
    }
    if let Some(session) = resume_session_id.map(str::trim).filter(|s| !s.is_empty()) {
        command.push_str(" --resume ");
        command.push_str(&shell_single_quote(session));
    }
    if resume_session_id.is_none() {
        if let Some(session) = new_session_id {
            command.push_str(" --session-id ");
            command.push_str(&shell_single_quote(session));
        }
    }
    command.push_str(" --cwd \"$PWD\" -p ");
    command.push_str(&shell_single_quote(&positional_prompt(prompt)));
    RemoteExecution {
        command,
        env: Some(std::collections::HashMap::from([(
            "NO_COLOR".to_string(),
            "1".to_string(),
        )])),
        managed_auth: vec![MANAGED_AUTH_PROFILE.to_string()],
        label,
    }
}

/// Planning-time check of node-specific prerequisites. Vibe uses a fresh
/// capability probe (CLI plus Python); managed-auth harnesses use their profile.
/// A node whose last heartbeat lacks the profile is refused with
/// [`REMOTE_AUTH_REQUIRED`] before any mission exists; a node without any
/// cached heartbeat is probed once. Missing capability evidence fails closed.
pub(crate) async fn require_node_managed_auth(
    state: &AppState,
    node_id: &str,
    plan: &RemoteHarnessPlan,
) -> Result<(), String> {
    if matches!(plan, RemoteHarnessPlan::Vibe { .. }) {
        let unavailable = format!("REMOTE_HARNESS_UNAVAILABLE: remote node '{node_id}' is not ready for Mistral Vibe; install vibe-acp and Python 3.9+ as the node execution user");
        let capabilities = super::machine_transfer::node_transfer_capabilities(state, node_id)
            .await
            .map_err(|(_, reason)| format!("{unavailable}. {reason}"))?;
        return if capabilities["harnesses"]
            .as_array()
            .is_some_and(|harnesses| harnesses.iter().any(|harness| harness == "vibe"))
        {
            Ok(())
        } else {
            Err(unavailable)
        };
    }
    let profile = match plan {
        RemoteHarnessPlan::Grok { .. } => "grok",
        RemoteHarnessPlan::Antigravity { .. } => "antigravity",
        _ => return Ok(()),
    };
    let Some(node) = state.config.remote_nodes.node(node_id) else {
        return Ok(());
    };
    if profile == "antigravity" {
        // One Google sign-in: hand the node the routing login first. Older
        // nodes and nodes keeping their own sign-in fall back to the heartbeat.
        match crate::api::antigravity_native::sync_node(state, node_id).await {
            Ok(crate::api::antigravity_native::NodeSync::Ready) => {
                let client = RemoteNodeClient::default();
                remote_node::probe_node(&state.fleet, &client, node).await;
            }
            Ok(_) => {}
            Err(error) => {
                tracing::warn!(node = %node_id, "Antigravity sign-in not pushed: {error}")
            }
        }
    }
    if state
        .fleet
        .get(node_id)
        .and_then(|cached| cached.last_heartbeat)
        .is_none()
    {
        let client = RemoteNodeClient::default();
        remote_node::probe_node(&state.fleet, &client, node).await;
    }
    let Some(heartbeat) = state
        .fleet
        .get(node_id)
        .and_then(|cached| cached.last_heartbeat)
    else {
        return Err(format!("{REMOTE_AUTH_REQUIRED}: remote node '{node_id}' has no verified managed-auth heartbeat; check node connectivity and upgrade/configure sandboxed-node"));
    };
    if profile == "grok" {
        heartbeat_supports_grok(&heartbeat.managed_auth, node_id)
    } else if heartbeat.managed_auth.iter().any(|p| p == profile) {
        Ok(())
    } else {
        Err(format!("{REMOTE_AUTH_REQUIRED}: remote node '{node_id}' has no verified {profile} login; authenticate the CLI as the node execution user and configure its managed-auth profile"))
    }
}

pub(crate) fn heartbeat_supports_grok(
    managed_auth: &[String],
    node_id: &str,
) -> Result<(), String> {
    if managed_auth
        .iter()
        .any(|profile| profile == MANAGED_AUTH_PROFILE)
    {
        Ok(())
    } else {
        Err(format!(
            "{REMOTE_AUTH_REQUIRED}: remote node '{node_id}' advertises no managed grok auth; \
             install the grok CLI there, set SANDBOXED_NODE_GROK_HOME on the node service and run \
             `GROK_HOME=<that dir> grok login --device-auth` as the node service account (advertised profiles: [{}])",
            managed_auth.join(", ")
        ))
    }
}

// ─── streaming-json parser ───────────────────────────────────────────────────

/// What one fed chunk changed, for the observer to broadcast.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum StreamUpdate {
    GoalStatus {
        status: String,
        objective: String,
    },
    GoalIteration(u64),
    Text,
    Thinking,
    TextSnapshot(String),
    NativeText(serde_json::Value),
    ThinkingSnapshot(String),
    SessionId(String),
    End,
    AuthRequired,
    Error(String),
    Tool {
        update: serde_json::Value,
        completed: bool,
    },
}

/// Incremental parser over the CLI's `--output-format streaming-json` lines
/// (`{"type":"text","data":…}`, `{"type":"thought","data":…}`,
/// `{"type":"end","stopReason":…,"sessionId":…}`), tolerant of the older
/// shapes the local runner accepts, plus the interactive-login sniffer for
/// non-JSON (stderr) lines.
#[derive(Debug, Default)]
pub(crate) struct GrokStream {
    antigravity: Option<crate::antigravity::Stream>,
    vibe: Option<crate::vibe::Stream>,
    claude: bool,
    claude_message_streamed: bool,
    claude_boundary: bool,
    partial: String,
    dropping_line: bool,
    text_segment: String,
    thinking_active: bool,
    pub(crate) text: String,
    pub(crate) thinking: String,
    pub(crate) session_id: Option<String>,
    pub(crate) model: Option<String>,
    pub(crate) stop_reason: Option<String>,
    pub(crate) ended: bool,
    pub(crate) native_goal_status: Option<String>,
    /// Explicit decision from the native driver after reading the persisted goal.
    /// Missing receipts retain the legacy fail-closed goal classification.
    codex_ordinary_turn: bool,
    pub(crate) auth_required: bool,
    pub(crate) error: Option<String>,
    native_activity: bool,
    pub(crate) json_events: u64,
    progress: bool,
    pub(crate) diagnostics: VecDeque<String>,
    /// OpenCode: byte offset in `text` where the turn's latest answer segment
    /// starts. Text parts before the last tool call are progress narration.
    opencode_answer_start: usize,
    /// OpenCode: the next text part starts a new answer segment.
    opencode_segment_closed: bool,
    /// OpenCode: message id of the latest text part and the offset in `text`
    /// where that message's text began (separator included).
    opencode_last_message: Option<(Option<String>, usize)>,
    /// OpenCode: part id of the first text part of the open segment, the
    /// identity of its durable bubble once a tool call closes it.
    opencode_segment_part: Option<String>,
    /// OpenCode: byte offset in `text` up to which narration is already
    /// durable as its own bubble.
    opencode_flushed: usize,
    /// OpenCode: part id of the latest tool call. Part ids sort by creation
    /// time, and a step's tool parts are printed before its text part.
    opencode_last_tool_part: Option<String>,
    /// OpenCode: tokens summed over the job's `step_finish` parts.
    pub(crate) opencode_usage: Option<crate::cost::TokenUsage>,
}

impl GrokStream {
    pub(crate) fn feed(&mut self, chunk: &str) -> Vec<StreamUpdate> {
        let mut updates = Vec::new();
        for part in chunk.split_inclusive('\n') {
            let complete = part.ends_with('\n');
            if !self.dropping_line && self.partial.len() + part.len() <= 1024 * 1024 {
                self.partial.push_str(part);
            } else {
                self.partial.clear();
                self.dropping_line = true;
            }
            if complete {
                if !self.dropping_line {
                    let line = std::mem::take(&mut self.partial);
                    self.feed_line(line.trim_end_matches('\n'), &mut updates);
                }
                self.dropping_line = false;
            }
        }
        self.snapshot_pending(&mut updates);
        updates
    }

    /// Flush a trailing partial line at end of log.
    pub(crate) fn finish(&mut self) -> Vec<StreamUpdate> {
        let mut updates = Vec::new();
        if !self.partial.is_empty() {
            let line = std::mem::take(&mut self.partial);
            self.feed_line(&line, &mut updates);
        }
        self.snapshot_pending(&mut updates);
        updates
    }

    // Materialize once per contiguous output segment, never once per delta.
    // Boundaries preserve the exact position of tool events within each chunk.
    fn snapshot_pending(&self, updates: &mut [StreamUpdate]) {
        if let Some(last) = updates.last_mut() {
            match last {
                StreamUpdate::Text => *last = StreamUpdate::TextSnapshot(self.text.clone()),
                StreamUpdate::Thinking => {
                    *last = StreamUpdate::ThinkingSnapshot(self.thinking.clone())
                }
                _ => {}
            }
        }
    }

    /// The turn's answer: the text after its last tool call. OpenCode reports
    /// every text part of a turn, so earlier parts are progress narration.
    pub(crate) fn final_text(&self) -> &str {
        let answer = self
            .text
            .get(self.opencode_answer_start..)
            .unwrap_or_default();
        if answer.trim().is_empty() {
            &self.text
        } else {
            answer
        }
    }

    /// One finished OpenCode text part (`run --format json` emits each once,
    /// when it ends). Auto-compaction writes its summary as an assistant text
    /// part and then a synthetic `compaction_continue` user part; neither is
    /// something the model said to the operator.
    fn feed_opencode_text(&mut self, part: &serde_json::Value, updates: &mut Vec<StreamUpdate>) {
        let Some(text) = part["text"].as_str() else {
            return;
        };
        if part["synthetic"].as_bool() == Some(true) {
            if part["metadata"]["compaction_continue"].as_bool() == Some(true) {
                if let Some((_, start)) = self.opencode_last_message.take() {
                    self.text.truncate(start);
                    self.opencode_answer_start = self.opencode_answer_start.min(start);
                    self.opencode_flushed = self.opencode_flushed.min(start);
                }
                // Only a tool call closes the answer. After a compaction the
                // model often adds a closing line; it must extend the answer,
                // not replace it (/btw 412e22b7 seq 422 kept only "Everything
                // has been explained…" and dropped the 3.8 KB answer).
            }
            return;
        }
        if text.trim().is_empty() {
            return;
        }
        // Written before a tool call already seen: it introduces that call,
        // so it is narration (Gemini runs printed "J'exécute `cat`…" after the
        // bash part, and it ended up in the final answer).
        if let (Some(id), Some(tool)) =
            (part["id"].as_str(), self.opencode_last_tool_part.as_deref())
        {
            if id < tool {
                if !self.text.is_empty() {
                    self.text.push_str("\n\n");
                }
                self.text.push_str(text);
                self.opencode_answer_start = self.text.len();
                self.opencode_flushed = self.text.len();
                self.opencode_segment_closed = true;
                updates.push(StreamUpdate::NativeText(serde_json::json!({
                    "bubble_id": format!("opencode:{}:{id}", self.session_id.as_deref().unwrap_or("unknown")),
                    "ops": [{"type":"snapshot","text":text.trim(),"revision":1},{"type":"finalize"}],
                })));
                return;
            }
        }
        let message = part["messageID"].as_str().map(str::to_string);
        let start = self.text.len();
        if !self.text.is_empty() {
            self.text.push_str("\n\n");
        }
        if self.opencode_segment_closed || start == 0 {
            self.opencode_answer_start = self.text.len();
            self.opencode_segment_closed = false;
            self.opencode_segment_part = part["id"].as_str().map(str::to_string);
        }
        if self
            .opencode_last_message
            .as_ref()
            .is_none_or(|(id, _)| message.is_none() || *id != message)
        {
            self.opencode_last_message = Some((message, start));
        }
        self.text.push_str(text);
        // Each part arrives complete. Narration becomes its own durable bubble
        // when a tool call closes its segment, and the answer is the turn's
        // final message; a turn-wide live snapshot would show both twice.
    }

    /// Text of the open segment, once a tool call proves it is narration:
    /// a finalized bubble placed before that tool, so a long turn keeps what
    /// the agent said between its tool calls (mission 4ad4bc01 showed 1,771
    /// tool calls and none of its 605 narration parts).
    fn flush_opencode_narration(&mut self, updates: &mut Vec<StreamUpdate>) {
        if self.opencode_segment_closed {
            return;
        }
        let start = self.opencode_answer_start.max(self.opencode_flushed);
        let Some(segment) = self.text.get(start..).map(str::trim) else {
            return;
        };
        if !segment.is_empty() {
            let bubble = format!(
                "opencode:{}:{}",
                self.session_id.as_deref().unwrap_or("unknown"),
                self.opencode_segment_part
                    .clone()
                    .unwrap_or_else(|| start.to_string())
            );
            updates.push(StreamUpdate::NativeText(serde_json::json!({
                "bubble_id": bubble,
                "ops": [{"type":"snapshot","text":segment,"revision":1},{"type":"finalize"}],
            })));
        }
        self.opencode_flushed = self.text.len();
    }

    /// OpenCode text not yet durable as a narration bubble.
    pub(crate) fn opencode_unflushed_text(&self) -> &str {
        self.text.get(self.opencode_flushed..).unwrap_or_default()
    }

    fn requires_error_cancellation(&self) -> bool {
        // A recoverable result can precede the CLI's own next attempt. Killing
        // the process here used to turn response-length errors into cancellation.
        self.auth_required
            || self.antigravity.as_ref().is_some_and(|native| {
                !native.cron_handoff
                    && self.error.as_deref().is_some_and(|error| {
                        !native.is_retryable()
                            && super::usage_limit_wait::antigravity_resumable_interruption(error)
                                .is_none()
                    })
            })
    }

    fn feed_line(&mut self, raw: &str, updates: &mut Vec<StreamUpdate>) {
        let line = raw.trim_end_matches('\r');
        if line.trim().is_empty() {
            return;
        }
        // Only JSON objects are harness protocol events. A raw command that
        // prints a bare number or string (`nproc`, `echo true`) must stay a
        // plain diagnostic line, or it would masquerade as a stream event.
        let Some(value) = serde_json::from_str::<serde_json::Value>(line)
            .ok()
            .filter(serde_json::Value::is_object)
        else {
            if let Some(stream) = self.antigravity.as_mut() {
                stream.observe_stderr(line);
                if stream.error.is_some() {
                    self.error = stream.finish().err().or_else(|| stream.error.clone());
                }
            }
            if grok_line_requests_interactive_login(line) && !self.auth_required {
                self.snapshot_pending(updates);
                self.auth_required = true;
                updates.push(StreamUpdate::AuthRequired);
            }
            if self.diagnostics.len() >= DIAGNOSTIC_LINES {
                self.diagnostics.pop_front();
            }
            let mut diagnostic = line.to_string();
            if diagnostic.len() > 4096 {
                let mut cut = 4096;
                while !diagnostic.is_char_boundary(cut) {
                    cut -= 1;
                }
                diagnostic.truncate(cut);
            }
            self.diagnostics.push_back(diagnostic);
            return;
        };
        self.native_activity |= value["type"].is_string() || value["event"].is_string();
        if let Some(stream) = self.vibe.as_mut() {
            let tools = stream.feed(&value);
            if stream.session != self.session_id {
                self.session_id = stream.session.clone();
                if let Some(id) = &self.session_id {
                    updates.push(StreamUpdate::SessionId(id.clone()));
                }
            }
            if self.text != stream.text {
                self.text = stream.text.clone();
                updates.push(StreamUpdate::TextSnapshot(self.text.clone()));
            }
            if self.thinking != stream.thinking {
                self.thinking = stream.thinking.clone();
                updates.push(StreamUpdate::ThinkingSnapshot(self.thinking.clone()));
            }
            self.progress = true;
            self.ended = stream.success;
            self.stop_reason = stream.success.then(|| "end_turn".into());
            self.error = stream.error.clone();
            for tool in tools {
                updates.push(StreamUpdate::Tool {
                    completed: tool["type"] == "tool_call_update",
                    update: tool,
                });
            }
            return;
        }
        if let Some(stream) = self.antigravity.as_mut() {
            if value["event"] == "thought_update" {
                if value["conversation_id"].as_str() != stream.session.as_deref() {
                    return;
                }
                if let Some(text) = value["text"].as_str().filter(|s| s.len() <= 256 * 1024) {
                    self.thinking = text.into();
                    self.progress = true;
                    updates.push(StreamUpdate::ThinkingSnapshot(self.thinking.clone()));
                }
                return;
            }

            let prev_iterations = stream.goal_iterations;
            let tools = stream.feed(&value);
            self.progress |= !tools.is_empty() || !stream.text.is_empty();
            if stream.session != self.session_id {
                self.session_id = stream.session.clone();
                if let Some(id) = &self.session_id {
                    updates.push(StreamUpdate::SessionId(id.clone()));
                }
            }
            if stream.goal_mode && stream.goal_iterations > prev_iterations {
                updates.push(StreamUpdate::GoalIteration(u64::from(
                    stream.goal_iterations,
                )));
            }
            if let Some(status) = stream.goal_status {
                self.native_goal_status = Some(status.to_string());
            }
            self.text = stream.text.clone();
            self.ended = stream.success;
            self.stop_reason = stream.success.then(|| "end_turn".into());
            self.error = if stream.error.is_some() {
                stream.finish().err().or_else(|| stream.error.clone())
            } else {
                None
            };
            for tool in tools {
                if tool["type"] == "text_op" {
                    updates.push(StreamUpdate::NativeText(tool));
                    continue;
                }
                let completed = tool["type"] == "tool_call_update";
                updates.push(StreamUpdate::Tool {
                    update: tool,
                    completed,
                });
            }
            return;
        }
        if self.claude {
            self.feed_claude(&value, updates);
            return;
        }
        // Codex exec emits native thread/turn/item events. Keep the thread id
        // for continuation on the same node and preserve tool/text ordering.
        let kind = value["type"].as_str().unwrap_or_default();
        if kind == "execution.mode" {
            self.codex_ordinary_turn = value["mode"].as_str() == Some("turn");
            return;
        }
        if kind == "goal.status" {
            if let Some(status) = value["status"].as_str() {
                self.native_goal_status = Some(status.to_string());
                updates.push(StreamUpdate::GoalStatus {
                    status: status.to_string(),
                    objective: value["objective"].as_str().unwrap_or_default().to_string(),
                });
            }
            return;
        }
        if kind == "session.recovered" {
            // The saved thread had no rollout; the driver continues on a fresh
            // thread seeded with history. Keep the reason in the transcript.
            tracing::warn!(previous = ?value["previous_thread_id"], reason = ?value["reason"], "remote codex thread could not be resumed; continuing on a fresh seeded thread");
            updates.push(StreamUpdate::Tool {
                update: serde_json::json!({
                    "toolCallId": "session-recovered",
                    "name": "session_recovered",
                    "rawInput": {"previous_thread_id": value["previous_thread_id"]},
                    "output": format!(
                        "Previous Codex session could not be resumed ({}); continuing in a fresh session seeded with the conversation history.",
                        value["reason"].as_str().unwrap_or("unknown reason")
                    ),
                    "status": "completed",
                }),
                completed: true,
            });
            return;
        }
        if kind == "goal.iteration" {
            if let Some(iteration) = value["iteration"].as_u64() {
                updates.push(StreamUpdate::GoalIteration(iteration));
            }
            return;
        }
        if matches!(
            kind,
            "thread.started"
                | "turn.started"
                | "turn.completed"
                | "turn.failed"
                | "item.started"
                | "item.updated"
                | "item.completed"
        ) {
            self.snapshot_pending(updates);
            self.json_events += 1;
            if kind == "thread.started" {
                if let Some(session) = value["thread_id"].as_str() {
                    self.session_id = Some(session.to_string());
                    updates.push(StreamUpdate::SessionId(session.to_string()));
                }
            } else if kind == "turn.completed" {
                // Codex can emit retry diagnostics before a successful turn.
                self.error = None;
                self.ended = true;
                self.stop_reason = Some("end_turn".to_string());
                updates.push(StreamUpdate::End);
            } else if kind == "turn.failed" {
                let error = value["error"]["message"]
                    .as_str()
                    .unwrap_or("Codex turn failed")
                    .to_string();
                self.error = Some(error.clone());
                updates.push(StreamUpdate::Error(error));
            } else if kind.starts_with("item.") {
                self.progress = true;
                let item = &value["item"];
                match item["type"].as_str() {
                    Some("agent_message") if kind == "item.completed" => {
                        if let Some(text) = item["text"].as_str() {
                            if !self.text.is_empty() {
                                self.text.push_str("\n\n");
                            }
                            self.text.push_str(text);
                            updates.push(StreamUpdate::TextSnapshot(self.text.clone()));
                        }
                    }
                    Some("reasoning") if kind == "item.completed" => {
                        if let Some(text) = item["text"].as_str() {
                            self.thinking = text.to_string();
                            updates.push(StreamUpdate::ThinkingSnapshot(self.thinking.clone()));
                        }
                    }
                    Some("command_execution" | "file_change" | "mcp_tool_call" | "web_search")
                        if kind != "item.updated" =>
                    {
                        updates.push(StreamUpdate::Tool {
                                update: serde_json::json!({
                                    "toolCallId": item["id"], "name": item["type"],
                                    "rawInput": item, "output": item["aggregated_output"],
                                    "status": if item["status"] == "failed" { "failed" } else { "completed" },
                                }),
                                completed: kind == "item.completed",
                            });
                    }
                    _ => {}
                }
            }
            return;
        }
        // OpenCode emits full text/tool parts and a native sessionID on every event.
        if let Some(session) = value.get("sessionID").and_then(|v| v.as_str()) {
            self.snapshot_pending(updates);
            self.json_events += 1;
            self.progress = true;
            if self.session_id.as_deref() != Some(session) {
                self.session_id = Some(session.to_string());
                updates.push(StreamUpdate::SessionId(session.to_string()));
            }
            let part = &value["part"];
            match value["type"].as_str() {
                Some("text") => self.feed_opencode_text(part, updates),
                Some("reasoning") => {
                    if let Some(text) = part["text"].as_str().filter(|t| !t.is_empty()) {
                        self.thinking = text.to_string();
                        updates.push(StreamUpdate::ThinkingSnapshot(self.thinking.clone()));
                    }
                }
                Some("tool_use") => {
                    self.flush_opencode_narration(updates);
                    self.opencode_segment_closed = true;
                    if let Some(id) = part["id"].as_str() {
                        if self
                            .opencode_last_tool_part
                            .as_deref()
                            .is_none_or(|last| id > last)
                        {
                            self.opencode_last_tool_part = Some(id.to_string());
                        }
                    }
                    // OpenCode's callID is the provider's per-response index for
                    // Gemini and other OpenAI-compatible models (`call_0` 1,371
                    // times in mission 4ad4bc01), and clients pair tool rows by
                    // id. The part id is unique per call.
                    let call_id = match (part["id"].as_str(), part["callID"].as_str()) {
                        (Some(part_id), Some(call)) => {
                            serde_json::json!(format!("{part_id}:{call}"))
                        }
                        (Some(part_id), None) => serde_json::json!(part_id),
                        _ => part["callID"].clone(),
                    };
                    let update = serde_json::json!({
                        "toolCallId": call_id, "name": part["tool"],
                        "rawInput": part["state"]["input"], "status": if part["state"]["status"] == "error" { serde_json::json!("failed") } else { part["state"]["status"].clone() },
                        "error": part["state"]["error"],
                        "output": part["state"]["output"],
                    });
                    updates.push(StreamUpdate::Tool {
                        update: update.clone(),
                        completed: false,
                    });
                    updates.push(StreamUpdate::Tool {
                        update,
                        completed: true,
                    });
                }
                Some("step_finish") => {
                    let tokens = &part["tokens"];
                    if tokens.is_object() {
                        let usage = self.opencode_usage.get_or_insert_with(Default::default);
                        usage.input_tokens += tokens["input"].as_u64().unwrap_or(0);
                        usage.output_tokens += tokens["output"].as_u64().unwrap_or(0)
                            + tokens["reasoning"].as_u64().unwrap_or(0);
                        *usage.cache_read_input_tokens.get_or_insert(0) +=
                            tokens["cache"]["read"].as_u64().unwrap_or(0);
                        *usage.cache_creation_input_tokens.get_or_insert(0) +=
                            tokens["cache"]["write"].as_u64().unwrap_or(0);
                    }
                    if let Some(reason) = part["reason"].as_str() {
                        if matches!(reason, "stop" | "end_turn" | "EndTurn") {
                            self.ended = true;
                            self.stop_reason = Some("end_turn".to_string());
                            updates.push(StreamUpdate::End);
                        } else {
                            self.ended = false;
                            self.stop_reason = Some(reason.to_string());
                        }
                    }
                }
                Some("error") => {
                    self.error = Some(value["error"].to_string());
                }
                _ => {}
            }
            return;
        }
        let is_text = grok_event_text(&value).is_some() && grok_event_reasoning(&value).is_none();
        let is_thinking = grok_event_reasoning(&value).is_some();
        if !matches!(updates.last(), Some(StreamUpdate::Text) if is_text)
            && !matches!(updates.last(), Some(StreamUpdate::Thinking) if is_thinking)
        {
            self.snapshot_pending(updates);
        }
        self.json_events += 1;
        if let Some(model) = grok_event_model(&value) {
            self.model = Some(model);
        }
        if let Some(session) = grok_event_session_id(&value) {
            if self.session_id.as_deref() != Some(session.as_str()) {
                self.snapshot_pending(updates);
                self.session_id = Some(session.clone());
                updates.push(StreamUpdate::SessionId(session));
            }
        }
        let kind = value
            .get("type")
            .and_then(|t| t.as_str())
            .map(|t| t.to_ascii_lowercase());
        if matches!(kind.as_deref(), Some("tool_call" | "tool_call_update")) {
            self.snapshot_pending(updates);
            // Text after a tool belongs to a new assistant segment. Native
            // goals emit several such segments before their final snapshot.
            // Keep accumulated output, but compare snapshots only to the
            // current segment (available_commands does not end a segment).
            self.text_segment.clear();
            self.thinking_active = false;
            self.progress = true;
            let update = value
                .get("data")
                .filter(|data| data.is_object())
                .unwrap_or(&value)
                .clone();
            let completed = kind.as_deref() == Some("tool_call_update");
            updates.push(StreamUpdate::Tool { update, completed });
            return;
        }
        if grok_event_is_error(&value) {
            self.snapshot_pending(updates);
            let message = value
                .get("error")
                .map(|e| match e.as_str() {
                    Some(s) => s.to_string(),
                    None => e.to_string(),
                })
                .or_else(|| grok_event_text(&value))
                .unwrap_or_else(|| line.to_string());
            self.error = Some(message.clone());
            updates.push(StreamUpdate::Error(message));
            return;
        }
        if kind.as_deref() == Some("end") {
            self.snapshot_pending(updates);
            self.ended = true;
            self.progress = true;
            self.stop_reason = value
                .get("stopReason")
                .or_else(|| value.get("stop_reason"))
                .and_then(|v| v.as_str())
                .map(str::to_string);
            updates.push(StreamUpdate::End);
            return;
        }
        if let Some(reasoning) = grok_event_reasoning(&value) {
            if !reasoning.is_empty() {
                self.progress = true;
                if !self.thinking_active {
                    self.thinking.clear();
                    self.thinking_active = true;
                }
                append_bounded(&mut self.thinking, &reasoning);
                if !matches!(updates.last(), Some(StreamUpdate::Thinking)) {
                    updates.push(StreamUpdate::Thinking);
                }
            }
            return;
        }
        if let Some(text) = grok_event_text(&value) {
            if !text.is_empty() {
                self.thinking_active = false;
                self.progress = true;
                // Native CLI emits deltas followed by the same full text snapshot.
                if text == self.text_segment && !self.text_segment.is_empty() {
                    self.text_segment.clear();
                } else if !self.text_segment.is_empty() && text.starts_with(&self.text_segment) {
                    let suffix = &text[self.text_segment.len()..];
                    append_bounded(&mut self.text, suffix);
                    self.text_segment.clear();
                    if !matches!(updates.last(), Some(StreamUpdate::Text)) {
                        updates.push(StreamUpdate::Text);
                    }
                } else {
                    append_bounded(&mut self.text, &text);
                    append_bounded(&mut self.text_segment, &text);
                    if !matches!(updates.last(), Some(StreamUpdate::Text)) {
                        updates.push(StreamUpdate::Text);
                    }
                }
            }
        }
    }

    fn diagnostics_text(&self) -> String {
        self.diagnostics
            .iter()
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn append_bounded(target: &mut String, text: &str) {
    target.push_str(text);
    const LIMIT: usize = 1024 * 1024;
    if target.len() > LIMIT {
        let mut cut = target.len() - LIMIT;
        while !target.is_char_boundary(cut) {
            cut += 1;
        }
        target.drain(..cut);
    }
}

fn is_goal_turn(mission: &Mission, antigravity: Option<&crate::antigravity::Stream>) -> bool {
    match antigravity {
        Some(stream) => mission.goal_mode && stream.goal_mode,
        None => mission.goal_mode,
    }
}

fn goal_objective(mission: &Mission) -> Option<String> {
    if !mission.goal_mode {
        return None;
    }
    mission
        .goal_objective
        .as_deref()
        .map(str::trim)
        .filter(|objective| !objective.is_empty())
        .map(str::to_string)
}

// ─── Observer (attached to the poll loop) ────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LogStreaming {
    Unknown,
    Supported,
    /// The node answered 404: it predates `GET /jobs/:id/log`. Only the
    /// terminal `log_tail` is available.
    Unsupported,
}

/// Terminal decision the poll loop applies for a native Grok job.
#[derive(Debug)]
pub(crate) struct TerminalVerdict {
    pub(crate) success: bool,
    pub(crate) content: String,
    /// Reason recorded on the mission/lease when the mission is finalized.
    pub(crate) status_reason: &'static str,
    /// The error the harness itself reported, when it reported one. Failure
    /// classification reads this rather than the whole report, whose
    /// diagnostics quote arbitrary output.
    pub(crate) cli_error: Option<String>,
}

pub(crate) struct NativeGrokObserver {
    mission_id: Uuid,
    job_id: Uuid,
    owner: RemoteMissionOwner,
    mission: Mission,
    log_offset: u64,
    log_len: u64,
    streaming: LogStreaming,
    stream: GrokStream,
    thinking_open: bool,
    thinking_snapshot: String,
    session_persisted: Option<String>,
    auth_cancel_requested: bool,
    running_since: Option<std::time::Instant>,
    /// Node log length when `running_since` was last reset: raw output the
    /// parser does not recognise (stderr, compaction notices) still proves life.
    startup_log_len: u64,
    startup_failure: Option<String>,
    /// The latest `pump` itself read the log to its current end.
    pumped_to_end: bool,
    /// Log bytes whose events an earlier Core process already published. They
    /// are fed to the parser (to rebuild its state) but not published again.
    replay_until: u64,
    /// Offset reached at a past instant, saved once it is old enough that the
    /// event logger has stored everything below it.
    offset_checkpoint: Option<(u64, std::time::Instant)>,
    /// A native Antigravity `schedule` already became a Core wake-up.
    native_wakeup_registered: bool,
    /// A recurring Antigravity `schedule` became a Core schedule and the node
    /// job was asked to stop so the conversation can continue unblocked.
    cron_handoff_requested: bool,
}

/// Jobs that allocated their Claude session (`--session-id`) rather than
/// resuming one. Process memory only: after a restart an eventless failure
/// keeps the session, which is the safe direction.
static ALLOCATED_CLAUDE_SESSIONS: LazyLock<Mutex<HashSet<Uuid>>> = LazyLock::new(Default::default);

pub(crate) fn note_allocated_claude_session(job_id: Uuid) {
    ALLOCATED_CLAUDE_SESSIONS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .insert(job_id);
}

fn take_allocated_claude_session(job_id: Uuid) -> bool {
    ALLOCATED_CLAUDE_SESSIONS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(&job_id)
}

/// Marks an assistant message Core persisted from the streamed text of a turn
/// that was stopped before its native final message (`completion_evidence`).
pub(crate) const PARTIAL_TURN_CLASSIFICATION: &str = "partial_turn_interrupted";

/// The durable copy of an interrupted turn's streamed text. Without it the
/// text exists only as the mutable `text_delta_latest` row, which the next
/// turn overwrites, so a reload lost (or, replayed from SSE, duplicated) it.
pub(crate) fn partial_turn_message(
    mission_id: Uuid,
    job_id: Uuid,
    text: &str,
) -> Option<AgentEvent> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    Some(AgentEvent::AssistantMessage {
        // One id per job: a retried terminal pass updates the same row.
        id: Uuid::new_v5(&job_id, b"partial-turn"),
        content: text.to_string(),
        success: true,
        cost_cents: 0,
        cost_source: crate::agents::CostSource::Unknown,
        usage: None,
        model: None,
        model_normalized: None,
        mission_id: Some(mission_id),
        shared_files: None,
        resumable: false,
        completion_evidence: Some(crate::agents::CompletionEvidence {
            terminal_reason: Some(crate::agents::TerminalReason::Cancelled),
            completion_signal: crate::agents::CompletionSignal::Unknown,
            completion_confidence: crate::agents::CompletionConfidence::Low,
            native_terminal_seen: false,
            pending_tools: None,
            transport_failure_stage: None,
            provider_error_source: None,
            failure_class: None,
            classification_source: PARTIAL_TURN_CLASSIFICATION.into(),
        }),
    })
}

impl NativeGrokObserver {
    /// Streamed assistant text of this job when it was stopped mid-turn.
    /// Antigravity keeps its own native bubbles, which are already durable.
    pub(crate) fn partial_turn_message(&self) -> Option<AgentEvent> {
        if self.stream.antigravity.is_some() {
            return None;
        }
        if self.mission.backend == "opencode" {
            // Narration already has its own bubbles; only the open tail is lost.
            return partial_turn_message(
                self.mission_id,
                self.job_id,
                self.stream.opencode_unflushed_text(),
            );
        }
        partial_turn_message(self.mission_id, self.job_id, &self.stream.text)
    }

    /// Host goal driver for a successful goal turn of a harness without a
    /// native goal loop (see `host_goal`). Returns the `goal_status` to
    /// report, or `None` when the user's Stop disarmed the goal.
    async fn drive_host_goal(&self, objective: &str, content: &mut String) -> Option<String> {
        use super::host_goal::{self, Outcome};
        let store = &self.owner.mission_store;
        // Re-read: a Stop during the turn disarmed goal mode after attach.
        let armed = store
            .get_mission(self.mission_id)
            .await
            .ok()
            .flatten()
            .is_some_and(|m| m.goal_mode);
        let rows = store
            .get_mission_automations(self.mission_id)
            .await
            .unwrap_or_default();
        let (continuation_pending, wakeup_armed) = host_goal::pending(&rows);
        let (prior_no_progress, prior_continuations) = host_goal::prior_counters(&rows, objective);
        let mut outcome = host_goal::decide(&host_goal::Input {
            text: self.stream.final_text(),
            armed,
            continuation_pending,
            wakeup_armed,
            made_progress: self.stream.opencode_last_tool_part.is_some(),
            prior_no_progress,
            prior_continuations,
            max_no_progress: host_goal::max_no_progress(),
            max_continuations: host_goal::max_continuations(),
        });
        match &outcome {
            Outcome::Continue {
                no_progress,
                continuations,
            } => {
                let variables = host_goal::variables(
                    objective,
                    "Host goal loop: continue after the previous turn",
                    format!("host-goal:{}", self.job_id),
                    *no_progress,
                    *continuations,
                );
                if let Err(error) = crate::api::mission_runner::register_core_wakeup(
                    self.mission_id,
                    host_goal::continuation_delay_secs(),
                    host_goal::continuation_prompt(objective),
                    variables,
                )
                .await
                {
                    tracing::warn!(mission_id = %self.mission_id, job_id = %self.job_id, %error,
                        "Host goal continuation could not be queued; goal paused");
                    content.push_str(&format!(
                        "\n\nGoal paused: the automatic continuation could not be queued ({error})."
                    ));
                    outcome = Outcome::Paused;
                } else {
                    tracing::info!(mission_id = %self.mission_id, job_id = %self.job_id,
                        continuations, no_progress, "Host goal continuation queued");
                }
            }
            Outcome::Stalled { turns } => {
                tracing::warn!(mission_id = %self.mission_id, turns, "Host goal paused: no progress");
                content.push_str("\n\n");
                content.push_str(&host_goal::stalled_notice(*turns));
            }
            Outcome::BudgetLimited => {
                content.push_str("\n\nGoal stopped: the automatic continuation budget is spent.");
            }
            _ => {}
        }
        outcome.status()
    }

    pub(crate) fn usage(&self) -> Option<crate::cost::TokenUsage> {
        self.stream
            .antigravity
            .as_ref()
            .map(|stream| crate::cost::TokenUsage {
                input_tokens: stream.input_tokens,
                output_tokens: stream.output_tokens,
                cache_read_input_tokens: Some(stream.cache_read_tokens),
                cache_creation_input_tokens: None,
            })
            // OpenCode reports tokens per step; its turns had no usage at all.
            .or_else(|| self.stream.opencode_usage.clone())
    }

    /// Whether this job runs a goal turn. Antigravity says so itself: `agy`
    /// expands its native `/goal` command only for a `/goal` prompt, so a
    /// plain reply in a mission that once had a goal is an ordinary turn and
    /// must not report (and re-persist) the old goal's status.
    fn goal_turn(&self) -> bool {
        is_goal_turn(&self.mission, self.stream.antigravity.as_ref())
    }

    /// Attach to a native Grok job without a host goal driver.
    pub(crate) async fn attach(
        owner: &RemoteMissionOwner,
        _node_id: &str,
        mission_id: Uuid,
        job_id: Uuid,
    ) -> Option<Self> {
        let mission = match owner.mission_store.get_mission(mission_id).await {
            Ok(Some(mission))
                if matches!(
                    mission.backend.as_str(),
                    GROK_BACKEND | "opencode" | "codex" | "antigravity" | "vibe"
                ) || (mission.backend == "claudecode" && mission.session_id.is_some()) =>
            {
                mission
            }
            _ => return None,
        };
        Some(Self {
            mission_id,
            job_id,
            owner: owner.clone(),
            session_persisted: mission.session_id.clone(),
            stream: GrokStream {
                claude: mission.backend == "claudecode",
                vibe: (mission.backend == "vibe").then(|| crate::vibe::Stream {
                    session: mission.session_id.clone(),
                    ..Default::default()
                }),
                antigravity: (mission.backend == "antigravity").then(|| {
                    let mut stream = crate::antigravity::Stream::default();
                    stream.expected_session = mission.session_id.clone();
                    stream.turn_id = job_id.to_string();
                    stream
                }),
                ..Default::default()
            },
            mission,
            log_offset: 0,
            log_len: 0,
            streaming: LogStreaming::Unknown,
            thinking_open: false,
            thinking_snapshot: String::new(),
            auth_cancel_requested: false,
            running_since: None,
            startup_log_len: 0,
            startup_failure: None,
            pumped_to_end: false,
            replay_until: owner
                .mission_store
                .get_remote_log_offset(job_id)
                .await
                .unwrap_or(0),
            offset_checkpoint: None,
            native_wakeup_registered: false,
            cron_handoff_requested: false,
        })
    }

    /// Fetch and apply new log output. Called on every successful status
    /// observation (terminal ones included, so the tail is never lost).
    pub(crate) async fn pump(
        &mut self,
        client: &RemoteNodeClient,
        node: &RemoteNodeConfig,
        shared_token: &str,
    ) {
        self.pumped_to_end = false;
        if self.streaming == LogStreaming::Unsupported {
            return;
        }
        for _ in 0..MAX_CHUNKS_PER_TICK {
            let chunk = match client
                .get_job_log(node, shared_token, self.job_id, self.log_offset)
                .await
            {
                Ok(chunk) => chunk,
                Err(error) if error.is_not_found() && self.streaming == LogStreaming::Unknown => {
                    tracing::warn!(
                        mission_id = %self.mission_id,
                        job_id = %self.job_id,
                        node = %node.id,
                        "node has no job log route; grok output is only available from the terminal log tail"
                    );
                    self.streaming = LogStreaming::Unsupported;
                    return;
                }
                Err(error) => {
                    tracing::debug!(mission_id = %self.mission_id, job_id = %self.job_id, ?error, "remote grok log chunk fetch failed; retrying next tick");
                    return;
                }
            };
            self.streaming = LogStreaming::Supported;
            let caught_up = chunk.next_offset >= chunk.log_len;
            self.apply_chunk(&chunk, client, node, shared_token).await;
            if caught_up || chunk.data.is_empty() {
                self.pumped_to_end = caught_up;
                return;
            }
        }
    }

    /// Bound silent login/startup hangs without limiting a running native goal.
    ///
    /// A silent log is not proof of a hang: `opencode run --format json`
    /// prints nothing until its first part completes, and a resumed session of
    /// several hundred thousand tokens can spend minutes (compaction included)
    /// before that. The job counts as alive while the proxy is serving a model
    /// request for this mission, or while the node log grows at all.
    pub(crate) async fn check_startup(
        &mut self,
        status: &NodeJobStatus,
        client: &RemoteNodeClient,
        node: &RemoteNodeConfig,
        token: &str,
    ) {
        if status.state != "running" || self.stream.progress || self.stream.native_activity {
            return;
        }
        let proxy_active = crate::api::proxy_liveness::is_active(
            self.mission_id,
            std::time::Duration::from_secs(startup_proxy_recent_secs()),
        );
        let resumed = self.session_persisted.is_some();
        if !startup_watchdog_should_cancel(
            &mut self.running_since,
            &mut self.startup_log_len,
            self.log_len,
            proxy_active,
            std::time::Duration::from_secs(startup_watchdog_secs(resumed)),
        ) {
            return;
        }
        let secs = startup_watchdog_secs(resumed);
        tracing::warn!(
            mission_id = %self.mission_id,
            job_id = %self.job_id,
            node = %node.id,
            secs,
            resumed,
            "remote job silent with no proxy activity; startup watchdog cancels it"
        );
        self.startup_failure = Some(format!("Cancelled by startup watchdog: no native protocol activity, node output, or model traffic within {secs} seconds of running. The turn was interrupted and is resumed automatically once."));
        if !self.auth_cancel_requested {
            self.auth_cancel_requested = client
                .cancel_job_with_reason(
                    node,
                    token,
                    self.job_id,
                    "startup_watchdog",
                    &format!("No native protocol activity, node output, or model traffic within {secs} seconds"),
                )
                .await
                .is_ok();
        }
    }

    pub(crate) fn caught_up(&self) -> bool {
        self.streaming == LogStreaming::Unsupported || self.log_offset >= self.log_len
    }

    /// When a remote node restarts while a job is running in its transient
    /// systemd scope, the node marks its SQLite row `lost`, yet the CLI in
    /// the surviving scope may still write its terminal result event to the
    /// log file. Synthesize a terminal `NodeJobStatus` once the streamed log
    /// has caught up and recorded a native completion or error.
    pub(crate) fn synthesize_lost_terminal(&self, status: &NodeJobStatus) -> Option<NodeJobStatus> {
        if status.state != "lost" || !self.caught_up() {
            return None;
        }
        let stream_finished = self.stream.ended
            || self.stream.error.is_some()
            || self.stream.auth_required
            || self
                .stream
                .antigravity
                .as_ref()
                .is_some_and(|s| s.success || s.error.is_some());
        if !stream_finished {
            return None;
        }
        let succeeded = self.stream.ended
            && self.stream.error.is_none()
            && !self.stream.auth_required
            && self
                .stream
                .antigravity
                .as_ref()
                .is_none_or(|s| s.finish().is_ok());
        let mut recovered = status.clone();
        recovered.state = if succeeded {
            "succeeded".to_string()
        } else {
            "failed".to_string()
        };
        recovered.exit_code = Some(if succeeded { 0 } else { 1 });
        if succeeded {
            recovered.error = None;
        }
        Some(recovered)
    }

    /// Parse a chunk and return the updates to publish. After a Core restart,
    /// bytes below `replay_until` were already published by the previous
    /// process: they rebuild the parser state silently.
    fn absorb(&mut self, chunk: &JobLogChunk) -> Vec<StreamUpdate> {
        self.log_len = chunk.log_len;
        let start = self.log_offset;
        self.log_offset = chunk.next_offset;
        let silent = self
            .replay_until
            .saturating_sub(start)
            .min(chunk.data.len() as u64) as usize;
        if silent == 0 {
            self.stream.feed(&chunk.data)
        } else if silent >= chunk.data.len() {
            let replayed = self.stream.feed(&chunk.data);
            self.restore_state(&replayed);
            Vec::new()
        } else if chunk.data.is_char_boundary(silent) {
            let replayed = self.stream.feed(&chunk.data[..silent]);
            self.restore_state(&replayed);
            self.stream.feed(&chunk.data[silent..])
        } else {
            // Never split a character: skip this chunk's events to stay unique.
            let replayed = self.stream.feed(&chunk.data);
            self.restore_state(&replayed);
            Vec::new()
        }
    }

    /// Apply already-published updates to the observer's own state without
    /// publishing them: an open thinking block must still be closed (and
    /// persisted) by the next boundary after a restart.
    fn restore_state(&mut self, replayed: &[StreamUpdate]) {
        for update in replayed {
            match update {
                StreamUpdate::ThinkingSnapshot(content) => {
                    self.thinking_open = true;
                    self.thinking_snapshot = content.clone();
                }
                StreamUpdate::Tool { .. }
                | StreamUpdate::NativeText(_)
                | StreamUpdate::TextSnapshot(_)
                | StreamUpdate::End => {
                    self.thinking_open = false;
                    self.thinking_snapshot.clear();
                }
                _ => {}
            }
        }
    }

    async fn apply_chunk(
        &mut self,
        chunk: &JobLogChunk,
        client: &RemoteNodeClient,
        node: &RemoteNodeConfig,
        shared_token: &str,
    ) {
        if chunk.next_offset < self.log_offset {
            // The node restarted its log (or the job was re-run); start over
            // rather than parse from a stale offset.
            self.close_thinking();
            self.log_offset = 0;
            self.replay_until = 0;
            self.log_len = chunk.log_len;
            self.stream = GrokStream {
                claude: self.mission.backend == "claudecode",
                vibe: (self.mission.backend == "vibe").then(|| crate::vibe::Stream {
                    session: self.session_persisted.clone(),
                    ..Default::default()
                }),
                antigravity: (self.mission.backend == "antigravity").then(|| {
                    let mut stream = crate::antigravity::Stream::default();
                    stream.expected_session = self.session_persisted.clone();
                    stream.turn_id = self.job_id.to_string();
                    stream
                }),
                ..Default::default()
            };
            return;
        }
        let updates = self.absorb(chunk);
        self.broadcast(updates).await;
        // Publishing only queues events for the logger, which stores them a
        // moment later. Save an offset reached at least 3 s ago, never the
        // current one, so a crash cannot skip events that were not stored.
        match self.offset_checkpoint {
            Some((offset, at)) if at.elapsed() >= std::time::Duration::from_secs(3) => {
                if offset > self.replay_until {
                    self.owner
                        .mission_store
                        .set_remote_log_offset(self.job_id, offset)
                        .await;
                }
                self.offset_checkpoint = Some((self.log_offset, std::time::Instant::now()));
            }
            None => {
                self.offset_checkpoint = Some((self.log_offset, std::time::Instant::now()));
            }
            Some(_) => {}
        }
        self.hand_off_native_cron(client, node, shared_token).await;
        if self.stream.requires_error_cancellation() && !self.auth_cancel_requested {
            // Stop interactive login or a non-retryable native failure instead
            // of burning the job timeout. Recoverable results keep the CLI alive.
            if let Err(error) = client
                .cancel_job_with_reason(
                    node,
                    shared_token,
                    self.job_id,
                    "provider_error",
                    "Native CLI reported a non-retryable failure",
                )
                .await
            {
                tracing::warn!(mission_id = %self.mission_id, job_id = %self.job_id, ?error, "remote grok job cancellation after interactive login prompt failed; poll loop will retry");
            } else {
                self.auth_cancel_requested = true;
            }
        }
    }

    /// agy holds every step after an `ACTIVE` recurring `schedule` until it
    /// exits (see `crate::antigravity::NativeCron`), so the turn would go
    /// silent while the CLI keeps working. Core takes the schedule over, then
    /// ends the job; the verdict resumes the conversation unblocked.
    async fn hand_off_native_cron(
        &mut self,
        client: &RemoteNodeClient,
        node: &RemoteNodeConfig,
        shared_token: &str,
    ) {
        if self.cron_handoff_requested || self.session_persisted.is_none() {
            return;
        }
        let Some(cron) = self
            .stream
            .antigravity
            .as_ref()
            .and_then(|s| s.blocking_cron())
            .cloned()
        else {
            return;
        };
        if let Err(error) = crate::api::mission_runner::register_native_cron(
            self.mission_id,
            &cron.expression,
            &cron.prompt,
        )
        .await
        {
            tracing::warn!(mission_id = %self.mission_id, job_id = %self.job_id, %error,
                "Antigravity recurring schedule could not become a Core schedule; retrying");
            return;
        }
        match client
            .cancel_job_with_reason(
                node,
                shared_token,
                self.job_id,
                NATIVE_SCHEDULE_ACTOR,
                "Antigravity recurring schedule handed off to Core",
            )
            .await
        {
            Ok(_) => {
                self.cron_handoff_requested = true;
                if let Some(stream) = self.stream.antigravity.as_mut() {
                    stream.cron_handoff = true;
                }
            }
            Err(error) => {
                tracing::warn!(mission_id = %self.mission_id, job_id = %self.job_id, ?error,
                    "Antigravity schedule handoff could not stop the node job; retrying")
            }
        }
    }

    async fn broadcast(&mut self, updates: Vec<StreamUpdate>) {
        for update in updates {
            match update {
                StreamUpdate::GoalStatus { status, objective } => {
                    self.owner
                        .publish_native(AgentEvent::GoalStatus {
                            status,
                            objective,
                            mission_id: Some(self.mission_id),
                        })
                        .await;
                }
                StreamUpdate::GoalIteration(iteration) => {
                    self.owner
                        .publish_native(AgentEvent::GoalIteration {
                            iteration: iteration as u32,
                            objective: goal_objective(&self.mission).unwrap_or_default(),
                            mission_id: Some(self.mission_id),
                        })
                        .await;
                }
                StreamUpdate::Tool { update, completed } => {
                    self.close_thinking();
                    let id = update
                        .get("toolCallId")
                        .or_else(|| update.get("id"))
                        .and_then(|v| v.as_str());
                    if let Some(id) = id {
                        let name = update
                            .get("title")
                            .or_else(|| update.get("name"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("tool")
                            .to_string();
                        let event = if completed {
                            if !matches!(
                                update.get("status").and_then(|v| v.as_str()),
                                Some("completed" | "failed" | "cancelled")
                            ) {
                                continue;
                            }
                            AgentEvent::ToolResult {
                                tool_call_id: id.to_string(),
                                name,
                                result: update,
                                mission_id: Some(self.mission_id),
                            }
                        } else {
                            AgentEvent::ToolCall {
                                tool_call_id: id.to_string(),
                                name,
                                args: update
                                    .get("rawInput")
                                    .or_else(|| update.get("arguments"))
                                    .cloned()
                                    .unwrap_or_default(),
                                mission_id: Some(self.mission_id),
                            }
                        };
                        self.owner.publish_native(event).await;
                    }
                }
                StreamUpdate::ThinkingSnapshot(content) => {
                    self.thinking_open = true;
                    self.thinking_snapshot = content.clone();
                    self.owner.send(AgentEvent::Thinking {
                        content,
                        done: false,
                        mission_id: Some(self.mission_id),
                    });
                }
                StreamUpdate::NativeText(value) => {
                    self.close_thinking();
                    if let Ok(ops) = serde_json::from_value(value["ops"].clone()) {
                        self.owner
                            .publish_native(AgentEvent::TextOp {
                                mission_id: self.mission_id,
                                bubble_id: value["bubble_id"].as_str().unwrap_or_default().into(),
                                ops,
                            })
                            .await;
                    }
                }
                StreamUpdate::TextSnapshot(content) => {
                    self.close_thinking();
                    self.owner.send(AgentEvent::TextDelta {
                        content,
                        mission_id: Some(self.mission_id),
                    });
                }
                StreamUpdate::Text | StreamUpdate::Thinking => {
                    unreachable!("unmaterialized stream snapshot")
                }
                StreamUpdate::SessionId(session_id) => {
                    self.persist_session(&session_id).await;
                }
                StreamUpdate::End => {
                    self.close_thinking();
                }
                StreamUpdate::AuthRequired => {
                    tracing::warn!(mission_id = %self.mission_id, job_id = %self.job_id, "remote grok job printed an interactive sign-in prompt; managed auth on the node is not usable");
                }
                StreamUpdate::Error(message) => {
                    tracing::warn!(mission_id = %self.mission_id, job_id = %self.job_id, %message, "remote grok job reported an error event");
                }
            }
        }
    }

    fn close_thinking(&mut self) {
        if self.thinking_open {
            self.thinking_open = false;
            let content = std::mem::take(&mut self.thinking_snapshot);
            self.owner
                .send(super::super::mission_runner::thinking_final_event(
                    content,
                    self.mission_id,
                ));
        }
    }

    /// Persist the CLI session id as the mission's native identity, fenced
    /// by this job's run lease, and broadcast it.
    async fn persist_session(&mut self, session_id: &str) {
        if self.session_persisted.as_deref() == Some(session_id) {
            return;
        }
        let run = match self
            .owner
            .mission_store
            .get_latest_mission_run(self.mission_id)
            .await
        {
            Ok(Some(run)) if run.owner_actor_id == super::remote_job_lease_owner(self.job_id) => {
                Some(SessionUpdateRun::from(&run))
            }
            _ => return,
        };
        match self
            .owner
            .mission_store
            .update_mission_session_id(
                self.mission_id,
                session_id,
                &self.mission.backend,
                run.as_ref(),
            )
            .await
        {
            Ok(true) => {
                self.session_persisted = Some(session_id.to_string());
                self.mission.session_id = Some(session_id.to_string());
                self.owner.send(AgentEvent::SessionIdUpdate {
                    run,
                    backend: self.mission.backend.clone(),
                    session_id: session_id.to_string(),
                    mission_id: self.mission_id,
                });
            }
            Ok(false) => {
                tracing::warn!(mission_id = %self.mission_id, job_id = %self.job_id, "remote grok session id rejected as stale; continuation will not resume this session");
            }
            Err(error) => {
                tracing::warn!(mission_id = %self.mission_id, job_id = %self.job_id, %error, "remote grok session id could not be persisted");
            }
        }
    }

    /// The session id is published before submission, but Claude only creates
    /// it once it starts. A launch that died first (fork 0a9943ec: "Argument
    /// list too long") left every follow-up failing with "No conversation
    /// found with session ID". Forget such a session so the next turn starts
    /// fresh with the conversation replayed as context.
    /// A resumed session that fails silently (wrapper, timeout) is kept.
    async fn forget_unstarted_claude_session(&mut self, allocated: bool) {
        let missing = self
            .stream
            .error
            .as_deref()
            .is_some_and(|error| error.contains("No conversation found with session ID"));
        // No event is proof Claude never started only when the whole log was
        // read from offset zero and the terminal fetch itself reached its end
        // (a failed fetch leaves stale offsets that look caught up).
        let complete_log = self.streaming == LogStreaming::Supported && self.pumped_to_end;
        if !(missing || allocated && complete_log && self.stream.json_events == 0) {
            return;
        }
        let Some(session_id) = self.mission.session_id.clone() else {
            return;
        };
        let run = match self
            .owner
            .mission_store
            .get_latest_mission_run(self.mission_id)
            .await
        {
            Ok(Some(run)) if run.owner_actor_id == super::remote_job_lease_owner(self.job_id) => {
                SessionUpdateRun::from(&run)
            }
            _ => return,
        };
        match self
            .owner
            .mission_store
            .clear_unsubmitted_session_id(self.mission_id, &session_id, "claudecode", &run)
            .await
        {
            Ok(true) => {
                self.mission.session_id = None;
                self.session_persisted = None;
            }
            Ok(false) => {}
            Err(error) => {
                tracing::warn!(mission_id = %self.mission_id, job_id = %self.job_id, %error, "unstarted Claude session could not be cleared");
            }
        }
    }

    async fn release_unstarted_vibe_claim(&self, status: &NodeJobStatus) {
        // A missing identity is proof only after reading the complete terminal
        // log. A lost node or truncated tail may hide an admitted native session.
        if self.streaming != LogStreaming::Supported
            || !self.pumped_to_end
            || !matches!(status.state.as_str(), "succeeded" | "failed" | "cancelled")
            || self.session_persisted.is_some()
            || self
                .stream
                .vibe
                .as_ref()
                .is_none_or(|s| s.session.is_some())
        {
            return;
        }
        let run = match self
            .owner
            .mission_store
            .get_latest_mission_run(self.mission_id)
            .await
        {
            Ok(Some(run)) if run.owner_actor_id == super::remote_job_lease_owner(self.job_id) => {
                SessionUpdateRun::from(&run)
            }
            _ => return,
        };
        if let Err(error) = self
            .owner
            .mission_store
            .release_native_prompt_no_launch(self.mission_id, "vibe", Some(&run), self.job_id)
            .await
        {
            tracing::warn!(mission_id = %self.mission_id, job_id = %self.job_id, %error,
                "Could not release unstarted remote Vibe claim");
        }
    }

    /// Terminal decision for the job. Flushes the parser, closes an open
    /// thinking block, and reports the native CLI outcome.
    pub(crate) async fn verdict(
        &mut self,
        status: &NodeJobStatus,
        node_id: &str,
    ) -> TerminalVerdict {
        let flushed = self.stream.finish();
        self.broadcast(flushed).await;
        self.close_thinking();
        if self.stream.session_id.is_none() {
            // Some CLI versions only print the session in the `end` event;
            // if the log route was unavailable, try the terminal tail.
            if self.streaming != LogStreaming::Supported {
                if let Some(tail) = status.log_tail.as_deref() {
                    let updates = self.stream.feed(tail);
                    let flushed = self.stream.finish();
                    self.broadcast(updates).await;
                    self.broadcast(flushed).await;
                    self.close_thinking();
                }
            }
        }

        // Stop provenance outranks the generic "interrupted" emitted when the
        // process receives SIGTERM. It survives observer/Core restarts on new nodes.
        if let Some(cause) = self.startup_failure.clone().or_else(|| {
            status
                .cancellation
                .as_ref()
                .filter(|cause| {
                    cause.actor != "provider_error" && cause.actor != NATIVE_SCHEDULE_ACTOR
                })
                .map(|cause| format!("Cancelled by {}: {}", cause.actor, cause.reason))
        }) {
            self.stream.error = Some(cause);
        }
        // A deliberate recurring-schedule handoff survives Core restarts
        // through the node's cancellation provenance.
        if status
            .cancellation
            .as_ref()
            .is_some_and(|cause| cause.actor == NATIVE_SCHEDULE_ACTOR)
        {
            if let Some(stream) = self.stream.antigravity.as_mut() {
                stream.cron_handoff = stream.native_cron.is_some();
            }
        }
        let native_cron = self
            .stream
            .antigravity
            .as_ref()
            .filter(|s| s.cron_handoff)
            .and_then(|s| s.native_cron.clone());
        if native_cron.is_some() && self.startup_failure.is_none() {
            // The `interrupted` result is the handoff itself; identity errors
            // are re-derived from the native stream below.
            self.stream.error = None;
        }
        let exit = status.exit_code;
        let succeeded = status.state == "succeeded" && exit.unwrap_or(0) == 0;
        let auth_required = self.stream.auth_required || exit == Some(MISSING_MANAGED_AUTH_EXIT);
        let native_end = self.stream.ended
            && matches!(
                self.stream.stop_reason.as_deref(),
                Some("end_turn" | "EndTurn")
            );
        let codex_goal = self.mission.backend == "codex"
            && (self.stream.native_goal_status.is_some()
                || (self.mission.goal_mode && !self.stream.codex_ordinary_turn));
        // Raw remote commands predate stream-json. Require a Claude result only
        // after the native protocol has actually been observed.
        let legacy_claude = self.stream.claude && self.stream.json_events == 0;
        // A resume that dies before its first event used to surface only as
        // "identity was not durably persisted" (a configuration failure), which
        // hid the real exit and stopped automatic recovery.
        let native_label = if self.stream.antigravity.is_some() {
            Some("Antigravity")
        } else if self.stream.vibe.is_some() {
            Some("Vibe")
        } else {
            None
        };
        let exited_before_output = native_label.is_some()
            && !succeeded
            && self.stream.error.is_none()
            && self.stream.json_events == 0
            && self.stream.session_id.is_none();
        if exited_before_output {
            self.stream.error = Some(exited_before_output_message(
                native_label.unwrap_or_default(),
                exit,
                self.session_persisted.as_deref(),
            ));
        }
        let native_schedule = self
            .stream
            .antigravity
            .as_ref()
            .and_then(|s| s.native_schedule.clone())
            .filter(|_| self.stream.error.is_none() && !auth_required);
        if self.stream.antigravity.is_some()
            && self.stream.error.is_none()
            && (succeeded || native_schedule.is_some() || native_cron.is_some())
            && (self.stream.session_id.is_none()
                || self.session_persisted != self.stream.session_id)
        {
            self.stream.error =
                Some("Antigravity conversation identity was not durably persisted".into());
        }
        if let Some(err) = self
            .stream
            .antigravity
            .as_ref()
            .and_then(|s| s.finish().err())
        {
            if self.stream.error.is_none() {
                self.stream.error = Some(err);
            }
        }
        if let Some(stream) = &self.stream.vibe {
            if self.stream.error.is_none() {
                self.stream.error = stream.finish().err();
            }
            if !exited_before_output && self.session_persisted != stream.session {
                self.stream.error = Some("Vibe identity was not durably persisted".into());
            }
        }
        // Headless `agy -p` exits after its native `schedule` tool instead of
        // sleeping. Turn that into a durable Core wake-up so the turn is a clean
        // wait; if registration fails, the error asks recovery to resume the
        // conversation when the schedule is due.
        if let Some(schedule) = native_schedule
            .as_ref()
            .filter(|_| self.stream.error.is_none())
        {
            if !self.native_wakeup_registered {
                match crate::api::mission_runner::register_claude_builtin_wakeup(
                    self.mission_id,
                    format!("antigravity-schedule:{}:{}", self.job_id, schedule.step),
                    schedule.delay_seconds,
                    schedule.prompt.clone(),
                    "Antigravity native schedule tool".to_string(),
                )
                .await
                {
                    Ok(_) => self.native_wakeup_registered = true,
                    Err(error) => {
                        tracing::warn!(mission_id = %self.mission_id, job_id = %self.job_id, %error,
                            "Antigravity native schedule could not become a Core wake-up; recovery will resume it");
                        self.stream.error =
                            Some(native_schedule_error(schedule.delay_seconds, &error));
                    }
                }
            }
        }
        // Resume the conversation right after a recurring-schedule handoff.
        if let Some(cron) = native_cron.as_ref().filter(|_| self.stream.error.is_none()) {
            if !self.native_wakeup_registered {
                match crate::api::mission_runner::register_native_cron_resume(
                    self.mission_id,
                    self.job_id,
                    cron,
                )
                .await
                {
                    Ok(_) => self.native_wakeup_registered = true,
                    Err(error) => {
                        self.stream.error = Some(format!(
                            "Antigravity recurring schedule was handed off but its resume could not be scheduled: {error}"
                        ))
                    }
                }
            }
        }
        let scheduled_end =
            (native_schedule.is_some() || native_cron.is_some()) && self.native_wakeup_registered;
        // Before the native protocol starts, the CLI can only report setup
        // failures through stderr and the node's terminal process status.
        let startup_evidence = if !succeeded && self.stream.json_events == 0 {
            format!(
                "{}\n{}",
                status.error.as_deref().unwrap_or_default(),
                self.stream.diagnostics_text()
            )
        } else {
            String::new()
        };
        let failure = super::remote_failure::classify(
            self.stream.error.as_deref().unwrap_or(&startup_evidence),
        );
        let success = (succeeded || scheduled_end)
            && self
                .stream
                .antigravity
                .as_ref()
                .is_none_or(|s| s.finish().is_ok())
            && (!self.stream.claude || legacy_claude || self.stream.ended)
            && !auth_required
            && self.stream.error.is_none()
            && (!self.goal_turn() || legacy_claude || native_end)
            && (!codex_goal || self.stream.native_goal_status.as_deref() == Some("complete"));
        let allocated = take_allocated_claude_session(self.job_id);
        if self.stream.claude && !success {
            self.forget_unstarted_claude_session(allocated).await;
        }
        if !success {
            self.release_unstarted_vibe_claim(status).await;
        }
        let mut content = self
            .stream
            .antigravity
            .as_ref()
            .map(|s| s.summary())
            .unwrap_or_else(|| self.stream.final_text().to_string())
            .trim()
            .to_string();
        if legacy_claude && success {
            content = format!(
                "Remote job {} on node '{}' finished with state 'succeeded'",
                self.job_id, node_id
            );
            let output = self.stream.diagnostics_text();
            if !output.is_empty() {
                content.push_str(&format!("\n\n{output}"));
            }
        }
        let status_reason: &'static str = if status
            .error
            .as_deref()
            .is_some_and(|error| error.starts_with("timed out after "))
        {
            "remote_node_timeout"
        } else if codex_goal && !success {
            "native_goal_stopped"
        } else if auth_required {
            "remote_grok_auth_required"
        } else if !success {
            match failure.kind {
                super::remote_failure::FailureKind::Transport => "remote_transport_error",
                super::remote_failure::FailureKind::Authentication => "remote_auth_required",
                super::remote_failure::FailureKind::ProviderPolicy => "remote_provider_policy",
                super::remote_failure::FailureKind::Configuration => "remote_configuration",
                super::remote_failure::FailureKind::Quota => "remote_quota",
                super::remote_failure::FailureKind::Cancelled => "remote_job_cancelled",
                super::remote_failure::FailureKind::StartupStall => "remote_startup_stalled",
                super::remote_failure::FailureKind::Unknown => "remote_node_job",
            }
        } else {
            "remote_node_job"
        };
        if !success {
            let mut report = String::new();
            if codex_goal && succeeded && self.stream.error.is_none() {
                report.push_str(&format!(
                    "Native Codex goal stopped with status '{}'; the objective and counters are preserved. Resume after resolving that stop.",
                    self.stream.native_goal_status.as_deref().unwrap_or("unconfirmed")
                ));
            } else if exit == Some(super::btw_context::SNAPSHOT_MISSING_EXIT) {
                report.push_str(&format!(
                    "The /btw conversation snapshot is not on node '{node_id}'. Ask the side question again so Orb uploads a fresh one there."
                ));
            } else if auth_required {
                report.push_str(
                    "The selected CLI could not authenticate on the node. Reconnect its account in Providers or repair the node's managed credentials, then resume this mission.",
                );
            } else {
                report.push_str(&format!(
                    "Remote {} job {} on node '{}' finished with state '{}' (exit {:?}){}.",
                    self.mission.backend,
                    self.job_id,
                    node_id,
                    status.state,
                    exit,
                    status
                        .error
                        .as_deref()
                        .map(|e| format!("; error: {e}"))
                        .unwrap_or_default()
                ));
                if let Some(error) = &self.stream.error {
                    if failure.kind == super::remote_failure::FailureKind::Transport {
                        report.push_str(&format!("\n{}", failure.summary));
                    } else {
                        report.push_str(&format!("\nCLI error: {error}"));
                    }
                }
            }
            let diagnostics = self.stream.diagnostics_text();
            if !diagnostics.is_empty() {
                report.push_str("\n\ndiagnostics:\n");
                report.push_str(&diagnostics);
            } else if content.is_empty() && self.streaming != LogStreaming::Supported {
                if let Some(tail) = status.log_tail.as_deref() {
                    report.push_str("\n\nlog tail:\n");
                    report.push_str(tail);
                }
            }
            if content.is_empty() {
                content = report;
            } else {
                content.push_str("\n\n");
                content.push_str(&report);
            }
        } else if content.is_empty() {
            content = format!(
                "Remote {} job {} on node '{}' finished without assistant text (stop reason: {}).",
                self.mission.backend,
                self.job_id,
                node_id,
                self.stream.stop_reason.as_deref().unwrap_or("unknown")
            );
        }

        if let Some(objective) = goal_objective(&self.mission)
            .filter(|_| self.mission.backend != "codex" && self.goal_turn())
        {
            let status = if success {
                match self.stream.native_goal_status.clone() {
                    Some(status) => Some(status),
                    // OpenCode has no native goal state: its run ending only
                    // means the model stopped for now. Core drives the loop
                    // (4ad4bc01 was marked complete at 13:38Z and stopped).
                    None if super::host_goal::host_drives_goal(&self.mission.backend) => {
                        self.drive_host_goal(&objective, &mut content).await
                    }
                    None => Some("complete".to_string()),
                }
            } else {
                Some("paused".to_string())
            };
            if let Some(status) = status {
                let event = AgentEvent::GoalStatus {
                    status,
                    objective,
                    mission_id: Some(self.mission_id),
                };
                self.owner.publish_native(event).await;
            }
        }

        if success && scheduled_end {
            if let Some(cron) = &native_cron {
                content.push_str(&format!(
                    "\n\nAntigravity's recurring schedule is now a Core schedule ({}): {}",
                    crate::api::mission_runner::describe_cron(&cron.expression),
                    cron.prompt
                ));
            }
            if let Some(schedule) = &native_schedule {
                content.push_str(&format!(
                    "\n\nAntigravity scheduled a wake-up: this mission resumes in {}s with: {}",
                    schedule.delay_seconds, schedule.prompt
                ));
            }
        }

        TerminalVerdict {
            success,
            content,
            status_reason,
            cli_error: self.stream.error.clone(),
        }
    }
}

/// Startup watchdog for a fresh turn (`SANDBOXED_REMOTE_STARTUP_WATCHDOG_SECS`).
const STARTUP_WATCHDOG_SECS: u64 = 300;
/// Startup watchdog for a resumed session, whose first event can wait for a
/// large context to be compacted and re-read
/// (`SANDBOXED_REMOTE_STARTUP_WATCHDOG_RESUMED_SECS`).
const STARTUP_WATCHDOG_RESUMED_SECS: u64 = 900;
/// Proxy traffic this recent counts as the job talking to a model
/// (`SANDBOXED_REMOTE_STARTUP_PROXY_RECENT_SECS`).
const STARTUP_PROXY_RECENT_SECS: u64 = 180;

fn env_secs(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(default)
}

pub(crate) fn startup_watchdog_secs(resumed: bool) -> u64 {
    if resumed {
        env_secs(
            "SANDBOXED_REMOTE_STARTUP_WATCHDOG_RESUMED_SECS",
            STARTUP_WATCHDOG_RESUMED_SECS,
        )
    } else {
        env_secs(
            "SANDBOXED_REMOTE_STARTUP_WATCHDOG_SECS",
            STARTUP_WATCHDOG_SECS,
        )
    }
}

fn startup_proxy_recent_secs() -> u64 {
    env_secs(
        "SANDBOXED_REMOTE_STARTUP_PROXY_RECENT_SECS",
        STARTUP_PROXY_RECENT_SECS,
    )
}

/// Decide one startup-watchdog tick. Any liveness signal restarts the
/// silence clock; only a job silent on every signal for `threshold` is
/// cancelled. A job the proxy shows talking to a model is never cancelled.
pub(crate) fn startup_watchdog_should_cancel(
    running_since: &mut Option<std::time::Instant>,
    seen_log_len: &mut u64,
    log_len: u64,
    proxy_active: bool,
    threshold: std::time::Duration,
) -> bool {
    if proxy_active || log_len > *seen_log_len {
        *seen_log_len = log_len.max(*seen_log_len);
        *running_since = Some(std::time::Instant::now());
        return false;
    }
    running_since
        .get_or_insert_with(std::time::Instant::now)
        .elapsed()
        >= threshold
}

/// Marker shared with recovery: a resume that died before any event.
pub(crate) const EXITED_BEFORE_OUTPUT: &str = "before producing output (resume of conversation ";

fn exited_before_output_message(label: &str, exit: Option<i32>, resumed: Option<&str>) -> String {
    let code = exit.map_or_else(
        || "without an exit code".to_string(),
        |code| format!("with code {code}"),
    );
    match resumed.filter(|s| !s.trim().is_empty()) {
        Some(session) => format!("{label} exited {code} {EXITED_BEFORE_OUTPUT}{session})"),
        None => format!("{label} exited {code} before producing output (new conversation)"),
    }
}

/// Marker shared with recovery: a native schedule Core could not register.
pub(crate) const NATIVE_SCHEDULE_PREFIX: &str = "Antigravity scheduled a native wake-up in ";

/// Cancellation actor of a deliberate recurring-schedule handoff.
const NATIVE_SCHEDULE_ACTOR: &str = "native_schedule";

fn native_schedule_error(delay_seconds: u64, error: &str) -> String {
    format!("{NATIVE_SCHEDULE_PREFIX}{delay_seconds}s; Core could not register it ({error})")
}

fn mission_model(mission: &Mission) -> Option<String> {
    Some(
        mission
            .model_override
            .as_deref()
            .map(str::trim)
            .filter(|m| !m.is_empty())
            .map(str::to_string)
            .unwrap_or_else(resolve_grok_default_model),
    )
}

/// Persist a user-visible message for the prompt of a continuation turn.
async fn persist_turn_prompt(
    owner: &RemoteMissionOwner,
    mission_id: Uuid,
    prompt: &str,
    source: &str,
    message_id: Option<Uuid>,
) -> Result<(), String> {
    let event = AgentEvent::UserMessage {
        id: message_id.unwrap_or_else(Uuid::new_v4),
        content: prompt.to_string(),
        queued: false,
        mission_id: Some(mission_id),
        source: Some(source.to_string()),
    };
    owner.mission_store.log_event(mission_id, &event).await?;
    owner.send(event);
    Ok(())
}

// ─── Placement + remote continuation of existing missions ────────────────────

/// Where a mission's remote job lives (or lived).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemotePlacement {
    pub(crate) node_id: String,
    pub(crate) job_id: Uuid,
    /// A ledger handle is still open: the job has not been observed terminal.
    pub(crate) live: bool,
}

/// Grace between a run lease turning terminal and Core asking the node to
/// finalize a job that still reports `running` for it.
const ORPHANED_NODE_JOB_GRACE_SECS: i64 = 60;
/// Minimum spacing between finalize requests for the same node job.
const ORPHANED_NODE_JOB_RETRY: std::time::Duration = std::time::Duration::from_secs(30);

static ORPHAN_FINALIZE_ATTEMPTS: LazyLock<
    Mutex<std::collections::HashMap<Uuid, std::time::Instant>>,
> = LazyLock::new(Default::default);

/// Whether the mission's latest run lease is terminal (operator cancelled or
/// finished) for `job_id` long enough that a node still reporting the job
/// `running` must be told to finalize it.
pub(crate) fn run_lease_orphans_job(
    run: Option<&crate::api::mission_store::MissionRun>,
    job_id: Uuid,
    now: chrono::DateTime<chrono::Utc>,
) -> bool {
    let Some(run) = run else { return false };
    if !run.execution_state.is_terminal()
        || run.owner_actor_id.strip_prefix("remote-job:") != Some(job_id.to_string().as_str())
    {
        return false;
    }
    run.ended_at
        .as_deref()
        .and_then(|at| chrono::DateTime::parse_from_rfc3339(at).ok())
        .is_some_and(|ended| {
            now.signed_duration_since(ended.with_timezone(&chrono::Utc))
                >= chrono::Duration::seconds(ORPHANED_NODE_JOB_GRACE_SECS)
        })
}

/// A live placement whose run lease Core already closed is a ghost: ask the
/// node to finalize (cancel) that job so queued follow-ups can be delivered
/// once the node confirms a terminal state. Returns whether a request was sent.
pub(crate) async fn finalize_orphaned_node_job(
    state: &Arc<AppState>,
    store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
    placement: &RemotePlacement,
) -> bool {
    if !placement.live || placement.job_id.is_nil() {
        return false;
    }
    let run = match store.get_latest_mission_run(mission_id).await {
        Ok(run) => run,
        Err(error) => {
            tracing::debug!(%mission_id, %error, "cannot read run lease for orphaned node job check");
            return false;
        }
    };
    if !run_lease_orphans_job(run.as_ref(), placement.job_id, chrono::Utc::now()) {
        return false;
    }
    {
        let mut attempts = ORPHAN_FINALIZE_ATTEMPTS
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        attempts.retain(|_, at| at.elapsed() < ORPHANED_NODE_JOB_RETRY);
        if attempts.contains_key(&placement.job_id) {
            return false;
        }
        attempts.insert(placement.job_id, std::time::Instant::now());
    }
    let Some(node) = state.config.remote_nodes.node(&placement.node_id) else {
        return false;
    };
    let Ok(token) = crate::remote_node::node_token(&node.token_env) else {
        return false;
    };
    match RemoteNodeClient::default()
        .cancel_job_with_reason(
            node,
            &token,
            placement.job_id,
            "core",
            "Core run lease is terminal; finalize the orphaned node job",
        )
        .await
    {
        Ok(response) => {
            tracing::warn!(%mission_id, job_id = %placement.job_id, node = %placement.node_id,
                node_state = %response.state, cancel_requested = response.cancel_requested,
                "asked node to finalize a job whose run lease is already terminal");
            true
        }
        Err(error) => {
            tracing::warn!(%mission_id, job_id = %placement.job_id, %error,
                "finalize request for orphaned node job failed");
            false
        }
    }
}

/// Remote placement of a mission from the durable ledger, falling back to
/// the (possibly settled) `remote-job:*` run lease. `None` means the mission
/// never dispatched a raw/typed remote job.
pub(crate) async fn placement(
    ledger_dir: &std::path::Path,
    store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
) -> Result<Option<RemotePlacement>, String> {
    if let Some(t) = super::machine_transfer::committed(store, mission_id).await? {
        match t.destination {
            crate::api::mission_store::transfer::Machine::Node { id } => {
                let run = store.get_latest_mission_run(mission_id).await?;
                let job = run
                    .as_ref()
                    .filter(|r| r.generation > t.generation)
                    .and_then(|r| r.owner_actor_id.strip_prefix("remote-job:"))
                    .and_then(|s| Uuid::parse_str(s).ok());
                return Ok(Some(RemotePlacement {
                    node_id: id,
                    job_id: job.unwrap_or(Uuid::nil()),
                    live: run.is_some_and(|r| {
                        r.generation > t.generation && !r.execution_state.is_terminal()
                    }),
                }));
            }
            _ => return Ok(None),
        }
    }
    use remote_node::job_ledger::JobHandleKind;
    let handles = remote_node::job_ledger::load(ledger_dir)
        .await
        .map_err(|e| e.to_string())?;
    if let Some(handle) = handles
        .iter()
        .filter(|handle| {
            handle.mission_id == mission_id
                && (handle.kind == JobHandleKind::Mission
                    || (handle.kind == JobHandleKind::Tentative && handle.identity.is_none()))
        })
        .max_by_key(|handle| (handle.submission_sequence, handle.started_at))
    {
        return Ok(Some(RemotePlacement {
            node_id: handle.node_id.clone(),
            job_id: handle.job_id,
            live: true,
        }));
    }
    let unknown = match store.get_mission(mission_id).await? {
        Some(mission) if !mission.requires_local_disk => Some(RemotePlacement {
            node_id: "unknown".into(),
            job_id: Uuid::nil(),
            live: false,
        }),
        _ => None,
    };
    let Some(run) = store.get_latest_mission_run(mission_id).await? else {
        return Ok(unknown);
    };
    let Some(job_id) = run
        .owner_actor_id
        .strip_prefix("remote-job:")
        .and_then(|id| Uuid::parse_str(id).ok())
    else {
        return Ok(unknown);
    };
    let node_id = run
        .scope_unit
        .as_deref()
        .and_then(|scope| scope.strip_prefix("remote-node:"))
        .unwrap_or("unknown")
        .to_string();
    Ok(Some(RemotePlacement {
        node_id,
        job_id,
        live: !run.execution_state.is_terminal(),
    }))
}

/// Every message entry point must fail closed before starting a Core runner.
pub(crate) async fn reject_local_followup(
    ledger_dir: &std::path::Path,
    store: &Arc<dyn MissionStore>,
    mission_id: Uuid,
) -> Result<(), String> {
    if let Some(placement) = placement(ledger_dir, store, mission_id).await? {
        let mission = store
            .get_mission(mission_id)
            .await?
            .ok_or("mission not found")?;
        return Err(local_resume_refusal(&mission, &placement));
    }
    Ok(())
}

/// Why a local resume of a remotely placed mission is refused. Used by
/// `resume_mission_impl` so internal callers (watchdog, MCP) never start a
/// local harness beside — or instead of — the node job.
pub(crate) fn local_resume_refusal(mission: &Mission, placement: &RemotePlacement) -> String {
    if matches!(
        mission.backend.as_str(),
        GROK_BACKEND | "opencode" | "codex" | "antigravity" | "vibe" | "claudecode"
    ) {
        format!(
            "{REMOTE_RESUME_REQUIRES_REPLACEMENT}: mission {} runs natively on remote node '{}'; \
             resume it through POST /api/control/missions/{}/resume (which continues it on the node) or create a replacement mission with remote_node_id",
            mission.id, placement.node_id, mission.id
        )
    } else {
        format!(
            "{REMOTE_RESUME_REQUIRES_REPLACEMENT}: mission {} ran '{}' on remote node '{}'; that harness keeps no resumable node session — \
             create a replacement mission (supersedes_mission_id={}) with remote_node_id instead of resuming locally",
            mission.id, mission.backend, placement.node_id, mission.id
        )
    }
}

/// Continue a remotely placed mission on its node with a new turn.
///
/// - Grok and OpenCode continue using their recorded native CLI session.
///   Other harnesses get a
///   [`REMOTE_RESUME_REQUIRES_REPLACEMENT`] conflict.
/// - A live node job ([`REMOTE_JOB_STILL_RUNNING`]) and an unconfigured
///   node are conflicts too; nothing is started locally in any case.
///
fn goal_resume_prompt(objective: &str) -> String {
    // Recovery markers can be legitimate user text. Never infer a migration
    // boundary from prose; generated envelopes are kept out of stored goals.
    format!("/goal {objective}\n\n{}", super::INTERRUPTED_RESUME_PROMPT)
}

/// Explicit content is passed verbatim; a goal resumes with `/goal resume`.
pub(crate) async fn continue_on_node(
    state: &Arc<AppState>,
    control: &ControlState,
    user_id: &str,
    mission_id: Uuid,
    placement: RemotePlacement,
    content: Option<String>,
    message_id: Option<Uuid>,
) -> Result<Mission, (StatusCode, String)> {
    continue_inner(
        state, control, user_id, mission_id, placement, content, message_id, false,
    )
    .await
}

pub(super) async fn deliver_queued(
    state: &Arc<AppState>,
    control: &ControlState,
    user_id: &str,
    mission_id: Uuid,
    placement: RemotePlacement,
    id: Uuid,
) -> Result<Mission, (StatusCode, String)> {
    continue_inner(
        state,
        control,
        user_id,
        mission_id,
        placement,
        None,
        Some(id),
        true,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn continue_inner(
    state: &Arc<AppState>,
    control: &ControlState,
    user_id: &str,
    mission_id: Uuid,
    _placement: RemotePlacement,
    mut content: Option<String>,
    message_id: Option<Uuid>,
    queued: bool,
) -> Result<Mission, (StatusCode, String)> {
    // Node I/O may time out. Never hold global admission while observing a
    // previously submitted job; its queue identity is revalidated below.
    let observed_job = if queued {
        let snapshot = super::remote_queue::waiting(&state.projects, Some(user_id))
            .map_err(internal)?
            .into_iter()
            .find(|entry| {
                entry.message.id == message_id.unwrap()
                    && entry.message.mission_id == Some(mission_id)
            });
        if let Some(entry) = snapshot.filter(|entry| entry.job_id.is_some()) {
            let job = entry.job_id.unwrap();
            let node = state.config.remote_nodes.node(&entry.node_id).ok_or((
                StatusCode::CONFLICT,
                "Queued message node is no longer configured".into(),
            ))?;
            let token = crate::remote_node::node_token(&node.token_env).map_err(internal)?;
            Some((
                job,
                RemoteNodeClient::default().get_job(node, &token, job).await,
            ))
        } else {
            None
        }
    } else {
        None
    };
    let _admission = super::DISPATCH_ADMISSION.lock().await;
    let _file_guard = super::dispatch_admission::durable_lock(&state.config)
        .await
        .map_err(internal)?;
    let store = control.mission_store.clone();
    super::machine_transfer::guard(&store, mission_id)
        .await
        .map_err(internal)?;
    let mission = store
        .get_mission(mission_id)
        .await
        .map_err(internal)?
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                format!("Mission {mission_id} not found"),
            )
        })?;
    // Refresh under the admission lock: an HTTP/timer placement snapshot may
    // precede another dispatch or the completion of the previous generation.
    let placement = placement(&state.config.working_dir, &store, mission_id)
        .await
        .map_err(internal)?
        .ok_or((StatusCode::CONFLICT, "Remote placement disappeared".into()))?;
    if queued {
        let entry = super::remote_queue::validate(
            &state.projects,
            user_id,
            message_id.unwrap(),
            &mission,
            &placement.node_id,
        )
        .map_err(|e| (StatusCode::CONFLICT, e))?;
        if let Some(job) = entry.job_id {
            // A crash may occur between node acceptance and the prompt event.
            // Ask about the bound job, never create a second job for that ID.
            let accepted = {
                let (_, observation) = observed_job
                    .filter(|(observed, _)| *observed == job)
                    .ok_or((
                        StatusCode::CONFLICT,
                        "Queued job changed during recovery; retrying its current identity".into(),
                    ))?;
                match observation {
                    Ok(status) if status.job_id == job && status.mission_id == mission_id => {
                        if status.started_at.is_none()
                            && status.state != "succeeded"
                        {
                            if matches!(status.state.as_str(), "cancelled" | "failed" | "lost") {
                                super::remote_queue::allow_abandon(&state.projects, user_id, message_id.unwrap()).map_err(internal)?;
                            }
                            return Err((StatusCode::CONFLICT,
                                "The remote job is unconfirmed: delivery paused before confirmed execution. Your message is preserved. If the job ended, remove this queued message before retrying.".into()));
                        }
                        true
                    },
                    Ok(_) => {
                        return Err((StatusCode::CONFLICT, "Remote job identity mismatch".into()))
                    }
                    Err(error) if error.is_not_found() => return Err((StatusCode::CONFLICT,"Cannot confirm whether the previous job accepted this message. Delivery is paused to avoid sending it twice.".into())),
                    Err(error) => return Err(internal(error)),
                }
            };
            if accepted {
                persist_turn_prompt(
                    &RemoteMissionOwner::live(control),
                    mission_id,
                    entry.message.content.trim(),
                    &format!("api:{user_id}"),
                    message_id,
                )
                .await
                .map_err(internal)?;
                super::remote_queue::finish(
                    &state.projects,
                    user_id,
                    message_id.unwrap(),
                    "accepted",
                )
                .map_err(internal)?;
                return Ok(mission);
            }
        }
        content = Some(entry.message.content);
    } else if super::remote_queue::waiting(&state.projects, Some(user_id))
        .map_err(internal)?
        .iter()
        .any(|row| row.message.mission_id == Some(mission_id))
    {
        return Err((
            StatusCode::CONFLICT,
            "Remote follow-ups are already queued".into(),
        ));
    }
    if let Some(id) = message_id {
        // The process may have died after accepted dispatch but before writing
        // the prompt event or replying to the scheduler. The persisted binding
        // plus node acceptance is enough to acknowledge that same delivery.
        if let Some((job, accepted)) = store
            .scheduled_remote_delivery(mission_id, id)
            .await
            .map_err(internal)?
        {
            let accepted = accepted
                || crate::remote_node::job_ledger::load(&state.config.working_dir)
                    .await
                    .map_err(internal)?
                    .iter()
                    .any(|handle| {
                        handle.mission_id == mission_id
                            && handle.job_id == job
                            && handle.kind == crate::remote_node::job_ledger::JobHandleKind::Mission
                            && handle.accepted_at.is_some()
                    });
            if accepted {
                if queued {
                    persist_turn_prompt(
                        &RemoteMissionOwner::live(control),
                        mission_id,
                        content.as_deref().unwrap_or_default().trim(),
                        &format!("api:{user_id}"),
                        message_id,
                    )
                    .await
                    .map_err(internal)?;
                }
                if queued {
                    super::remote_queue::finish(&state.projects, user_id, id, "accepted")
                        .map_err(internal)?;
                }
                return Ok(mission);
            }
        }
        let expected = id.to_string();
        if store
            .get_events(mission_id, Some(&["user_message"]), None, None)
            .await
            .map_err(internal)?
            .iter()
            .any(|event| event.event_id.as_deref() == Some(expected.as_str()))
        {
            if queued {
                super::remote_queue::finish(&state.projects, user_id, id, "accepted")
                    .map_err(internal)?;
            }
            return Ok(mission);
        }
    }
    // A live job must never produce a replacement hint, even for a harness
    // or track that cannot resume. Clients act on that hint by creating a job.
    let job_running = placement.live || mission.status == MissionStatus::Active;
    if job_running && placement.live {
        // Never block forever on a node job Core already closed. The request
        // runs in the background; the caller's retry (or the remote queue)
        // delivers once the node confirms a terminal state.
        let (state, store, placement) = (Arc::clone(state), store.clone(), placement.clone());
        tokio::spawn(async move {
            finalize_orphaned_node_job(&state, &store, mission_id, &placement).await;
        });
    }
    if job_running {
        return Err((
            StatusCode::CONFLICT,
            format!(
                "{REMOTE_JOB_STILL_RUNNING}: mission {} still owns job {} on remote node '{}'; wait for it to finish or cancel the mission first",
                mission.id, placement.job_id, placement.node_id
            ),
        ));
    }
    // Create absorbs project missions under a generated track, including Orb
    // requests with no writer flag. Re-admit that same identity and capability;
    // PR bindings and explicit tracks still require full create admission.
    let replacement = || {
        (StatusCode::CONFLICT, format!("{REMOTE_RESUME_REQUIRES_REPLACEMENT}: PR missions and closed or missing tracks need create admission; create a remote replacement with supersedes_mission_id={mission_id}"))
    };
    if crate::api::mission_horizon::superseded_by(&mission).is_some() {
        return Err((
            StatusCode::CONFLICT,
            format!(
                "{REMOTE_RESUME_REQUIRES_REPLACEMENT}: mission {mission_id} has been superseded; create a remote replacement with supersedes_mission_id={mission_id}"
            ),
        ));
    }
    // A PR binding needs create admission (PR ownership). A writer on its own
    // track does not: the track lease below re-admits it, so a follow-up keeps
    // the native session instead of replaying history into a replacement.
    if mission.project.github_pr.is_some() {
        return Err(replacement());
    }
    let track_claim = if let Some(track) = mission.project.track.as_deref() {
        let slug = mission.project.project.as_deref().ok_or_else(replacement)?;
        let canonical = state
            .projects
            .track(slug, track)
            .map_err(internal)?
            .ok_or_else(replacement)?;
        if canonical.track != track
            || matches!(
                canonical.status.as_deref(),
                Some("cancelled" | "done" | "satisfied")
            )
        {
            return Err(replacement());
        }
        // Preserve the generated-track restriction against another owner, but
        // allow our own still-live writer lease to be renewed on continuation.
        // A conflicting writer lease is a temporary lock, not a permanent
        // identity mismatch: keep queued follow-ups waiting until it expires.
        if state
            .projects
            .live_leases(Some(slug))
            .map_err(internal)?
            .iter()
            .any(|lease| {
                lease.track_id == canonical.id
                    && lease.mode == "writer"
                    && lease.attempt_id != mission_id.to_string()
            })
        {
            if queued {
                return Err((
                    StatusCode::CONFLICT,
                    format!(
                        "Track '{track}' on project '{slug}' is currently leased by another writer"
                    ),
                ));
            }
            return Err(replacement());
        }
        let writer = super::mission_is_pr_writer_in_store(&store, &mission)
            .await
            .map_err(internal)?;
        let mode = crate::api::track_leases::lease_mode(
            writer.then_some(true),
            &mission.project.tags,
            mission.project.intent.as_deref(),
        );
        Some(crate::api::track_leases::lease_request(
            slug,
            track,
            &mission_id.to_string(),
            mode,
            None,
        ))
    } else {
        None
    };
    if !matches!(
        mission.backend.as_str(),
        GROK_BACKEND | "opencode" | "codex" | "antigravity" | "vibe" | "claudecode"
    ) {
        return Err((
            StatusCode::CONFLICT,
            local_resume_refusal(&mission, &placement),
        ));
    }
    if job_running {
        return Err((
            StatusCode::CONFLICT,
            format!(
                "{REMOTE_JOB_STILL_RUNNING}: mission {} still owns job {} on remote node '{}'; wait for it to finish or cancel the mission first",
                mission.id, placement.job_id, placement.node_id
            ),
        ));
    }
    let _node = state
        .config
        .remote_nodes
        .node(&placement.node_id)
        .cloned()
        .ok_or_else(|| {
            (
                StatusCode::CONFLICT,
                format!(
                    "{REMOTE_RESUME_REQUIRES_REPLACEMENT}: remote node '{}' is no longer configured; create a replacement mission on another node",
                    placement.node_id
                ),
            )
        })?;
    if !state.config.remote_nodes.enabled {
        return Err((
            StatusCode::CONFLICT,
            format!(
                "{REMOTE_RESUME_REQUIRES_REPLACEMENT}: {}",
                RemoteNodeError::Disabled
            ),
        ));
    }
    let owner = RemoteMissionOwner::live(control);

    let content = content
        .map(|c| c.trim().to_string())
        .filter(|c| !c.is_empty());
    // Jobs launched before OpenCode streaming was enabled have a placeholder
    // session id. Recover the native identity from that exact job's log.
    let mut native_session = mission.session_id.clone();
    let transferred = super::machine_transfer::committed(&store, mission_id)
        .await
        .map_err(internal)?
        .is_some();
    if !transferred
        && mission.backend == "opencode"
        && !native_session
            .as_deref()
            .is_some_and(|s| s.starts_with("ses_"))
    {
        let token = crate::remote_node::node_token(&_node.token_env).map_err(internal)?;
        let client = RemoteNodeClient::default();
        let mut stream = GrokStream::default();
        let mut offset = 0;
        for _ in 0..MAX_CHUNKS_PER_TICK {
            let chunk = client
                .get_job_log(&_node, &token, placement.job_id, offset)
                .await
                .map_err(internal)?;
            stream.feed(&chunk.data);
            if stream.session_id.is_some() {
                break;
            }
            if chunk.next_offset <= offset || chunk.next_offset >= chunk.log_len {
                break;
            }
            offset = chunk.next_offset;
        }
        native_session = stream.session_id;
    }
    let session_id = native_session.filter(|s| !s.trim().is_empty());
    if session_id.is_none() && !transferred {
        return Err((
            StatusCode::CONFLICT,
            format!("{REMOTE_RESUME_REQUIRES_REPLACEMENT}: mission {mission_id} has no recorded native session; create a remote replacement with supersedes_mission_id={mission_id}"),
        ));
    }
    let prompt = content.clone().unwrap_or_else(|| {
        if mission.goal_mode {
            if matches!(
                mission.backend.as_str(),
                "antigravity" | "opencode" | "claudecode"
            ) {
                if let Some(objective) = mission.goal_objective.as_ref() {
                    return goal_resume_prompt(objective);
                }
            }
            "/goal resume".to_string()
        } else {
            super::INTERRUPTED_RESUME_PROMPT.to_string()
        }
    });
    let history_prompt = prompt.clone();
    let prompt =
        super::machine_transfer::context(&store, mission_id, prompt, session_id.as_deref())
            .await
            .map_err(internal)?;
    // Generated resumes are transport instructions, not a new user objective.
    // Parsing them used to append the entire resume envelope on every retry.
    if let Some(objective) = content.as_deref().and_then(super::parse_goal_objective) {
        if objective == "clear" {
            store
                .update_mission_goal(mission.id, false, None)
                .await
                .map_err(internal)?;
        } else if !matches!(objective.as_str(), "resume" | "pause" | "status") {
            store
                .update_mission_goal(mission.id, true, Some(&objective))
                .await
                .map_err(internal)?;
        }
    }
    let source = if content.is_some() {
        format!("api:{user_id}")
    } else {
        RESUME_SOURCE.to_string()
    };
    let plan = if mission.backend == "vibe" {
        vibe_continuation_plan(
            mission.agent.as_deref(),
            mission.model_override.clone(),
            &history_prompt,
            prompt.clone(),
            session_id.clone(),
        )
    } else if mission.backend == "antigravity" {
        RemoteHarnessPlan::Antigravity {
            effort: mission.model_effort.clone(),
            model: mission.model_override.clone(),
            prompt: prompt.clone(),
            resume_session_id: session_id.clone(),
        }
    } else if mission.backend == "codex" {
        RemoteHarnessPlan::Codex {
            effort: mission.model_effort.clone(),
            fast_mode: mission.fast_mode,
            service_tier: mission.service_tier,
            model: mission.model_override.clone().ok_or_else(|| {
                (
                    StatusCode::CONFLICT,
                    "Codex remote session has no recorded model".to_string(),
                )
            })?,
            prompt: prompt.clone(),
            resume_session_id: session_id.clone(),
            fallback_prompt: None,
        }
    } else if mission.backend == "claudecode" {
        RemoteHarnessPlan::ClaudeCode {
            model: mission
                .model_override
                .as_deref()
                .map(|m| m.strip_prefix("anthropic/").unwrap_or(m).to_string()),
            prompt: prompt.clone(),
            resume_session_id: session_id.clone(),
        }
    } else if mission.backend == "opencode" {
        RemoteHarnessPlan::OpenCode {
            model: mission
                .model_override
                .as_deref()
                .map(|m| m.strip_prefix("builtin/").unwrap_or(m).to_string()),
            prompt: prompt.clone(),
            resume_session_id: session_id.clone(),
        }
    } else {
        RemoteHarnessPlan::Grok {
            model: mission_model(&mission),
            prompt: prompt.clone(),
            resume_session_id: session_id.clone(),
            new_session_id: if session_id.is_none() {
                Some(Uuid::new_v4().to_string())
            } else {
                None
            },
        }
    };
    require_node_managed_auth(state, &placement.node_id, &plan)
        .await
        .map_err(|message| (StatusCode::BAD_REQUEST, message))?;
    // Terminal cleanup may have released the original claim. Reacquire and
    // revalidate it under admission locks before making the mission runnable.
    if let Some(request) = track_claim.as_ref() {
        let lease_conflict = |error: String| {
            if queued {
                (StatusCode::CONFLICT, error)
            } else {
                replacement()
            }
        };
        state
            .projects
            .acquire_track_lease(request)
            .map_err(|e| lease_conflict(e.to_string()))?;
        state
            .projects
            .revalidate_track_lease(request)
            .map_err(lease_conflict)?;
    }
    // Acquiring a run requires Pending/Active. Under admission locks, mark
    // the mission remote before moving it to Pending so no local scheduler
    // can claim the activation window. Dispatch then fences before submit.
    let previous = crate::api::mission_store::MissionStatusSnapshot::capture(&mission);
    store
        .set_mission_requires_local_disk(mission.id, false)
        .await
        .map_err(internal)?;
    store
        .update_mission_status(mission.id, MissionStatus::Pending)
        .await
        .map_err(internal)?;
    let resumed = match super::dispatch_remote_job(
        state,
        control,
        &mission,
        &placement.node_id,
        &plan,
        Some((message_id, placement.job_id)),
        queued.then(|| (user_id, message_id.unwrap())),
    )
    .await
    {
        Ok(resumed) => resumed,
        Err(message) => {
            store
                .restore_mission_status(mission.id, &previous)
                .await
                .map_err(internal)?;
            return Err((StatusCode::CONFLICT, message));
        }
    };
    persist_turn_prompt(&owner, mission.id, &history_prompt, &source, message_id)
        .await
        .map_err(internal)?;
    if queued {
        super::remote_queue::finish(&state.projects, user_id, message_id.unwrap(), "accepted")
            .map_err(internal)?;
    }
    Ok(resumed)
}

fn internal(error: impl std::fmt::Display) -> (StatusCode, String) {
    (StatusCode::INTERNAL_SERVER_ERROR, error.to_string())
}

fn vibe_continuation_plan(
    agent: Option<&str>,
    model: Option<String>,
    raw_prompt: &str,
    prompt: String,
    session: Option<String>,
) -> RemoteHarnessPlan {
    RemoteHarnessPlan::Vibe {
        plan: crate::vibe::plan_mode(agent, raw_prompt),
        model,
        prompt,
        resume_session_id: session,
    }
}

#[cfg(test)]
mod tests {

    /// 4ad4bc01 (opencode, resumed 325k-token session): the node log stayed
    /// empty for 300 s while the proxy streamed Gemini for the mission's
    /// `remote-launch:` key. Such a job must survive the watchdog.
    #[test]
    fn startup_watchdog_spares_silent_job_with_proxy_activity() {
        let mission = Uuid::new_v4();
        crate::api::proxy_liveness::note_activity(mission);
        let active = crate::api::proxy_liveness::is_active(
            mission,
            std::time::Duration::from_secs(startup_proxy_recent_secs()),
        );
        assert!(active);
        let mut since = Some(std::time::Instant::now() - std::time::Duration::from_secs(3600));
        let mut seen = 0;
        assert!(!startup_watchdog_should_cancel(
            &mut since,
            &mut seen,
            0,
            active,
            std::time::Duration::ZERO,
        ));
        // A request still in flight (no first byte yet) counts too.
        let other = Uuid::new_v4();
        let _guard = crate::api::proxy_liveness::begin_request(other);
        assert!(crate::api::proxy_liveness::is_active(
            other,
            std::time::Duration::ZERO
        ));
        // Raw node output the parser does not recognise also proves life.
        let mut since = Some(std::time::Instant::now() - std::time::Duration::from_secs(3600));
        assert!(!startup_watchdog_should_cancel(
            &mut since,
            &mut seen,
            42,
            false,
            std::time::Duration::from_secs(300),
        ));
        assert_eq!(seen, 42);
    }

    #[test]
    fn startup_watchdog_still_cancels_a_dead_job() {
        let mission = Uuid::new_v4();
        let active = crate::api::proxy_liveness::is_active(
            mission,
            std::time::Duration::from_secs(startup_proxy_recent_secs()),
        );
        assert!(!active);
        let mut since = None;
        let mut seen = 0;
        // First tick starts the clock; nothing elapsed yet.
        assert!(!startup_watchdog_should_cancel(
            &mut since,
            &mut seen,
            0,
            active,
            std::time::Duration::from_secs(300),
        ));
        since = Some(std::time::Instant::now() - std::time::Duration::from_secs(301));
        assert!(startup_watchdog_should_cancel(
            &mut since,
            &mut seen,
            0,
            active,
            std::time::Duration::from_secs(300),
        ));
        assert!(startup_watchdog_secs(true) > startup_watchdog_secs(false));
    }

    #[test]
    fn terminal_run_lease_orphans_its_node_job_after_grace() {
        use crate::api::mission_store::{MissionExecutionState, MissionRun};
        let job = Uuid::new_v4();
        let now = chrono::Utc::now();
        let run = |state, owner: String, ended: Option<chrono::DateTime<chrono::Utc>>| MissionRun {
            run_id: Uuid::new_v4(),
            mission_id: Uuid::new_v4(),
            generation: 1,
            execution_state: state,
            owner_actor_id: owner,
            scope_unit: Some("remote-node:ashur".into()),
            started_at: now.to_rfc3339(),
            heartbeat_at: now.to_rfc3339(),
            stopping_at: None,
            ended_at: ended.map(|at| at.to_rfc3339()),
            terminal_reason: Some("operator_cancelled_detached_run".into()),
        };
        let owner = format!("remote-job:{job}");
        let old = Some(now - chrono::Duration::minutes(5));
        assert!(run_lease_orphans_job(
            Some(&run(MissionExecutionState::Terminal, owner.clone(), old)),
            job,
            now
        ));
        // Within the grace period the node may still be reporting its exit.
        assert!(!run_lease_orphans_job(
            Some(&run(
                MissionExecutionState::Terminal,
                owner.clone(),
                Some(now)
            )),
            job,
            now
        ));
        // A live lease, or a lease owned by another job, never orphans it.
        assert!(!run_lease_orphans_job(
            Some(&run(MissionExecutionState::WaitingRemoteJob, owner, old)),
            job,
            now
        ));
        assert!(!run_lease_orphans_job(
            Some(&run(
                MissionExecutionState::Terminal,
                format!("remote-job:{}", Uuid::new_v4()),
                old
            )),
            job,
            now
        ));
        assert!(!run_lease_orphans_job(None, job, now));
    }

    use super::*;

    #[test]
    fn vibe_transfer_turn_keeps_raw_plan_intent_and_portable_history() {
        let wrapped = "Transferred history\n\n/plan Inspect only".to_string();
        let RemoteHarnessPlan::Vibe {
            plan,
            prompt,
            resume_session_id,
            ..
        } = vibe_continuation_plan(
            Some("build"),
            None,
            "/plan Inspect only",
            wrapped.clone(),
            None,
        )
        else {
            panic!("Vibe plan expected")
        };
        assert!(plan);
        assert_eq!(prompt, wrapped);
        assert_eq!(resume_session_id, None);
        let RemoteHarnessPlan::Vibe { plan, .. } = vibe_continuation_plan(
            Some("build"),
            None,
            "Implement",
            "/plan old history".into(),
            Some("native".into()),
        ) else {
            panic!("Vibe plan expected")
        };
        assert!(!plan);
    }

    #[test]
    fn antigravity_idle_wait_interruption_does_not_cancel_the_job() {
        let mut stream = GrokStream {
            antigravity: Some(Default::default()),
            ..Default::default()
        };
        stream.feed("{\"event\":\"init\",\"conversation_id\":\"same\"}\n");
        stream.feed(
            "diagnostics: root agent idle; waiting up to 30m0s for 1 background task(s)\nerror: interrupted\n",
        );
        let error = stream
            .error
            .clone()
            .expect("idle-wait interruption recorded");
        assert!(error.contains(crate::antigravity::IDLE_WAIT_INTERRUPTED_MARKER));
        assert!(!stream.requires_error_cancellation());
        assert_eq!(
            super::super::usage_limit_wait::antigravity_resumable_interruption(&error),
            Some(super::super::usage_limit_wait::IDLE_WAIT_INTERRUPTED)
        );
    }

    #[test]
    fn antigravity_remote_thoughts_require_matching_native_identity() {
        let mut stream = GrokStream {
            antigravity: Some(Default::default()),
            ..Default::default()
        };
        stream.feed("{\"event\":\"init\",\"conversation_id\":\"same\"}\n");
        assert!(stream
            .feed(
                "{\"event\":\"thought_update\",\"conversation_id\":\"other\",\"text\":\"wrong\"}\n"
            )
            .is_empty());
        let updates = stream.feed("{\"event\":\"thought_update\",\"conversation_id\":\"same\",\"text\":\"Checking the build.\",\"done\":true}\n");
        assert_eq!(
            updates,
            vec![StreamUpdate::ThinkingSnapshot("Checking the build.".into())]
        );
        assert!(stream.text.is_empty());
    }

    #[test]
    fn antigravity_remote_stream_records_progress_and_rejects_wrong_resume() {
        let mut stream = GrokStream {
            antigravity: Some(Default::default()),
            ..Default::default()
        };
        stream.feed(include_str!(
            "../../../tests/fixtures/antigravity_turn.jsonl"
        ));
        stream.finish();
        assert!(stream.progress);
        assert!(stream.ended);
        assert!(stream.antigravity.as_ref().unwrap().finish().is_ok());
        let mut native = crate::antigravity::Stream::default();
        native.expected_session = Some("expected".into());
        let mut resumed = GrokStream {
            antigravity: Some(native),
            ..Default::default()
        };
        resumed.feed("{\"event\":\"init\",\"conversation_id\":\"wrong\"}\n");
        assert!(resumed.error.is_some());
        assert_ne!(resumed.session_id.as_deref(), Some("wrong"));
    }

    #[test]
    fn antigravity_recoverable_result_does_not_cancel_native_retries() {
        let mut stream = GrokStream {
            antigravity: Some(Default::default()),
            ..Default::default()
        };
        stream.feed("{\"event\":\"init\",\"conversation_id\":\"same-session\"}\n");
        for error in [
            "Your previous response was cut off because it exceeded the output token limit",
            "UNAVAILABLE (code 503)",
            "The stream was interrupted",
        ] {
            stream.feed(&format!("{}\n", serde_json::json!({"event":"result","result":{"conversation_id":"same-session","status":"ERROR","error":error}})));
            assert!(!stream.requires_error_cancellation(), "{error}");
        }
        stream.feed("{\"event\":\"result\",\"result\":{\"conversation_id\":\"same-session\",\"status\":\"SUCCESS\"}}\n");
        assert!(stream.error.is_none());
        assert!(stream.ended);
        stream.auth_required = true;
        assert!(stream.requires_error_cancellation());
        stream.auth_required = false;
        stream.feed("{\"event\":\"init\",\"conversation_id\":\"wrong-session\"}\n");
        assert!(stream.requires_error_cancellation());
    }

    #[test]
    fn raw_command_scalar_output_is_not_a_stream_event() {
        let mut stream = GrokStream {
            claude: true,
            ..Default::default()
        };
        stream.feed("managed-e2e-ok\n2\ntrue\n\"text\"\nLake version 5.0.0\n");
        assert_eq!(stream.json_events, 0, "bare JSON scalars are plain output");
        assert!(stream.diagnostics_text().contains("2"));
        stream.feed("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s\"}\n");
        assert!(stream.json_events >= 1);
    }

    async fn resumed_antigravity_observer(session: &str) -> (NativeGrokObserver, Uuid, Uuid) {
        use crate::api::mission_store::{MissionStore, SqliteMissionStore};
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.keep().join("missions"), "agy-resume")
                .await
                .unwrap(),
        );
        let mission = store
            .create_mission(
                Some("resume"),
                None,
                None,
                None,
                None,
                Some("antigravity"),
                None,
            )
            .await
            .unwrap();
        store
            .update_mission_session_id(mission.id, session, "antigravity", None)
            .await
            .unwrap();
        let owner = RemoteMissionOwner {
            mission_store: store,
            events_tx: None,
        };
        let job_id = Uuid::new_v4();
        let mut observer = NativeGrokObserver::attach(&owner, "babylon", mission.id, job_id)
            .await
            .unwrap();
        observer.streaming = LogStreaming::Supported;
        (observer, mission.id, job_id)
    }

    #[tokio::test]
    async fn empty_failed_resume_reports_the_exit_instead_of_identity_persistence() {
        let (mut observer, mission_id, job_id) = resumed_antigravity_observer("87d01cec").await;
        let status: NodeJobStatus = serde_json::from_value(serde_json::json!({"job_id":job_id,"mission_id":mission_id,"state":"failed","exit_code":1,"created_at":"2026-10-18T06:52:05Z"})).unwrap();
        let verdict = observer.verdict(&status, "babylon").await;
        assert!(!verdict.success);
        assert_eq!(
            verdict.cli_error.as_deref(),
            Some("Antigravity exited with code 1 before producing output (resume of conversation 87d01cec)")
        );
        assert!(!verdict.content.contains("durably persisted"));
        assert_eq!(verdict.status_reason, "remote_node_job");
    }

    #[tokio::test]
    async fn trailing_native_schedule_is_not_an_interrupted_turn() {
        let (mut observer, mission_id, job_id) = resumed_antigravity_observer("c").await;
        observer.stream.feed(&format!("{}\n{}\n",
            serde_json::json!({"event":"init","conversation_id":"c"}),
            serde_json::json!({"event":"step_update","step_update":{"conversation_id":"c","step_index":7,
                "state":"DONE","step_type":"tool","tool_name":"schedule","tool_info":{"parameters":
                {"DurationSeconds":1800,"Prompt":"30-minute supervision check-in"}}}})));
        let status: NodeJobStatus = serde_json::from_value(serde_json::json!({"job_id":job_id,"mission_id":mission_id,"state":"failed","exit_code":null,"created_at":"2026-10-18T06:52:05Z"})).unwrap();
        let verdict = observer.verdict(&status, "babylon").await;
        // Without a reachable Core API the wake-up cannot be registered, so
        // the verdict asks recovery to resume when the schedule is due.
        assert!(!verdict.success);
        let error = verdict.cli_error.unwrap();
        assert!(error.starts_with(NATIVE_SCHEDULE_PREFIX), "{error}");
        assert_eq!(
            crate::api::control::usage_limit_wait::native_schedule_delay(&error),
            Some(1800)
        );
        assert!(!error.contains("without a SUCCESS result"));
    }

    /// Captured agy stream: a recurring `schedule` stalls the stream; the
    /// handoff's own cancellation is not a user stop nor a native failure.
    #[tokio::test]
    async fn recurring_schedule_handoff_is_not_a_cancelled_or_interrupted_turn() {
        let fixture = include_str!("../../../tests/fixtures/antigravity_cron_schedule.jsonl");
        let session = "fd68616d-2d82-4199-bace-1286e5216688";
        let (mut observer, mission_id, job_id) = resumed_antigravity_observer(session).await;
        let mut lines = fixture.lines();
        let head: Vec<&str> = lines.by_ref().take(4).collect();
        observer.stream.feed(&format!("{}\n", head.join("\n")));
        let cron = observer
            .stream
            .antigravity
            .as_ref()
            .unwrap()
            .blocking_cron()
            .cloned()
            .unwrap();
        assert_eq!(cron.expression, "*/30 * * * *");
        observer
            .stream
            .feed(&format!("{}\n", lines.collect::<Vec<_>>().join("\n")));
        let status: NodeJobStatus = serde_json::from_value(serde_json::json!({"job_id":job_id,"mission_id":mission_id,"state":"cancelled","exit_code":null,"created_at":"2026-10-24T10:42:00Z",
            "cancellation":{"actor":NATIVE_SCHEDULE_ACTOR,"reason":"Antigravity recurring schedule handed off to Core","requested_at":"2026-10-24T10:42:01Z"}})).unwrap();
        let verdict = observer.verdict(&status, "old-agent").await;
        // Without a reachable Core API the resume wake-up cannot be created;
        // the failure names that, never a cancellation or `interrupted`.
        let error = verdict.cli_error.unwrap();
        assert!(error.contains("resume could not be scheduled"), "{error}");
        assert!(
            !error.contains("Cancelled by") && !error.contains("interrupted"),
            "{error}"
        );
    }

    #[tokio::test]
    async fn antigravity_startup_error_survives_remote_verdict_without_identity() {
        use crate::api::mission_store::{MissionStore, SqliteMissionStore};
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().join("missions"), "agy-startup")
                .await
                .unwrap(),
        );
        let mission = store
            .create_mission(
                Some("startup"),
                None,
                None,
                None,
                None,
                Some("antigravity"),
                None,
            )
            .await
            .unwrap();
        let owner = RemoteMissionOwner {
            mission_store: store,
            events_tx: None,
        };
        let job_id = Uuid::new_v4();
        let mut observer = NativeGrokObserver::attach(&owner, "old-agent", mission.id, job_id)
            .await
            .unwrap();
        observer.streaming = LogStreaming::Supported;
        observer
            .stream
            .feed("AGY_ERROR: {\"short_error\":\"read: no route to host\",\"retryable\":true}\n");
        observer.stream.feed(&format!("{}\n", serde_json::json!({"event":"result","result":{"conversation_id":"","status":"ERROR","error":"agy-demo requires --effort"}})));
        let status: NodeJobStatus = serde_json::from_value(serde_json::json!({"job_id":job_id,"mission_id":mission.id,"state":"failed","exit_code":1,"created_at":"2026-10-06T06:52:05Z"})).unwrap();
        let verdict = observer.verdict(&status, "old-agent").await;
        assert!(!verdict.success);
        assert!(verdict.content.contains("agy-demo requires --effort"));
        assert!(verdict.content.contains("read: no route to host"));
        assert!(!verdict
            .content
            .contains("identity was not durably persisted"));
    }

    #[tokio::test]
    async fn restart_replays_published_log_silently() {
        use crate::api::mission_store::{MissionStore, SqliteMissionStore};
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().join("missions"), "replay")
                .await
                .unwrap(),
        );
        let mission = store
            .create_mission(Some("r"), None, None, None, None, Some("antigravity"), None)
            .await
            .unwrap();
        let owner = RemoteMissionOwner {
            mission_store: Arc::clone(&store),
            events_tx: None,
        };
        let job_id = Uuid::new_v4();
        let line = |i: u64| {
            format!(
                "{}\n",
                serde_json::json!({"event":"step_update","step_update":{"conversation_id":"c","step_index":i,
                    "state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command"}}})
            )
        };
        let first: String = (1..=5).map(line).collect();
        let second: String = (6..=7).map(line).collect();
        let chunk = |offset: u64, data: &str, len: u64| JobLogChunk {
            job_id,
            offset,
            next_offset: offset + data.len() as u64,
            log_len: len,
            data: data.to_string(),
            state: "running".into(),
        };
        let total = (first.len() + second.len()) as u64;

        // First process: publishes steps 1-5 and records how far it got.
        let mut before = NativeGrokObserver::attach(&owner, "node", mission.id, job_id)
            .await
            .unwrap();
        assert!(!before
            .absorb(&chunk(0, &first, first.len() as u64))
            .is_empty());
        store.set_remote_log_offset(job_id, before.log_offset).await;

        // After a restart the whole log is read again in one chunk: only the
        // new steps 6-7 are published.
        let mut after = NativeGrokObserver::attach(&owner, "node", mission.id, job_id)
            .await
            .unwrap();
        assert_eq!(after.replay_until, first.len() as u64);
        let all = format!("{first}{second}");
        let published = after.absorb(&chunk(0, &all, total));
        let fresh = NativeGrokObserver::attach(
            &RemoteMissionOwner {
                mission_store: Arc::clone(&store),
                events_tx: None,
            },
            "node",
            mission.id,
            Uuid::new_v4(),
        )
        .await
        .unwrap()
        .absorb(&chunk(0, &second, second.len() as u64));
        assert!(!after.thinking_open, "tool steps close thinking");
        // The resumed parser already knows the session; a fresh one reports it.
        let fresh: Vec<_> = fresh
            .into_iter()
            .filter(|u| !matches!(u, StreamUpdate::SessionId(_)))
            .collect();
        assert_eq!(published, fresh, "only steps 6-7 are published again");
        assert!(!published.is_empty());
    }

    const SPARK_STREAM: &str =
        include_str!("../../../tests/fixtures/native_grok_goal_resume.jsonl");
    const SPARK_TEXT: &str = include_str!("../../../tests/fixtures/native_grok_goal_resume.txt");

    #[tokio::test]
    async fn vibe_remote_startup_claim_requires_complete_terminal_log_without_identity() {
        use crate::api::mission_store::SqliteMissionStore;
        for (streaming, caught_up, state, identity, release) in [
            (LogStreaming::Supported, true, "failed", false, true),
            (LogStreaming::Supported, true, "cancelled", false, true),
            (LogStreaming::Supported, false, "failed", false, false),
            (LogStreaming::Unsupported, true, "failed", false, false),
            (LogStreaming::Supported, true, "lost", false, false),
            (LogStreaming::Supported, true, "running", false, false),
            (LogStreaming::Supported, true, "failed", true, false),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let store: Arc<dyn MissionStore> = Arc::new(
                SqliteMissionStore::new(dir.path().into(), "vibe-remote-claim")
                    .await
                    .unwrap(),
            );
            let mission = store
                .create_mission(None, None, None, None, None, Some("vibe"), None)
                .await
                .unwrap();
            let job_id = Uuid::new_v4();
            let run = store
                .begin_mission_run(
                    mission.id,
                    &super::super::remote_job_lease_owner(job_id),
                    None,
                )
                .await
                .unwrap();
            let fence = SessionUpdateRun::from(&run);
            assert!(store
                .claim_native_prompt(mission.id, "vibe", None, Some(&fence), job_id)
                .await
                .unwrap());
            let owner = RemoteMissionOwner {
                mission_store: store.clone(),
                events_tx: None,
            };
            let mut observer = NativeGrokObserver::attach(&owner, "node", mission.id, job_id)
                .await
                .unwrap();
            observer.streaming = streaming;
            observer.pumped_to_end = caught_up;
            if identity {
                observer.stream.vibe.as_mut().unwrap().session = Some("native-session".into());
            }
            let status: NodeJobStatus = serde_json::from_value(serde_json::json!({
                "job_id":job_id, "mission_id":mission.id, "state":state,
                "exit_code":1, "created_at":"2026-10-09T00:00:00Z"
            }))
            .unwrap();
            let verdict = observer.verdict(&status, "node").await;
            assert!(!verdict.success);
            assert_eq!(
                !store
                    .native_prompt_attempted(mission.id, "vibe")
                    .await
                    .unwrap(),
                release,
                "streaming={streaming:?} caught_up={caught_up} state={state} identity={identity}"
            );
            assert_eq!(
                store
                    .claim_native_prompt(mission.id, "vibe", None, Some(&fence), Uuid::new_v4())
                    .await
                    .unwrap(),
                release
            );
        }
    }

    #[tokio::test]
    async fn cancellation_provenance_outranks_native_interrupted() {
        use crate::api::mission_store::{MissionStore, SqliteMissionStore};
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().join("missions"), "cancel-cause")
                .await
                .unwrap(),
        );
        let mission = store
            .create_mission(
                Some("test"),
                None,
                None,
                None,
                None,
                Some("antigravity"),
                None,
            )
            .await
            .unwrap();
        let owner = RemoteMissionOwner {
            mission_store: store,
            events_tx: None,
        };
        let job = Uuid::new_v4();
        let mut observer = NativeGrokObserver::attach(&owner, "node", mission.id, job)
            .await
            .unwrap();
        observer.stream.error = Some("interrupted".into());
        let status: NodeJobStatus = serde_json::from_value(serde_json::json!({
            "job_id":job,"mission_id":mission.id,"state":"cancelled","created_at":"2026-10-10T00:00:00Z",
            "cancellation":{"actor":"startup_watchdog","reason":"No native activity","requested_at":"2026-10-10T00:05:00Z"}
        })).unwrap();
        let verdict = observer.verdict(&status, "node").await;
        assert!(!verdict.success);
        assert_eq!(verdict.status_reason, "remote_startup_stalled");
        assert!(verdict.cli_error.unwrap().contains("startup_watchdog"));
    }

    /// Shape of the /btw side turns that showed narration, a compaction
    /// summary and the answer glued into one message (missions 412e22b7 and
    /// d9f08eac on prod, opencode builtin/smart on a remote node).
    #[test]
    fn opencode_answer_excludes_narration_and_compaction_summary() {
        let mut stream = GrokStream::default();
        let fixture = include_str!("../../../tests/fixtures/opencode_btw_compaction.jsonl");
        for line in fixture.lines() {
            stream.feed(&format!("{line}\n"));
        }
        assert!(stream.ended);
        assert_eq!(
            stream.final_text(),
            "Voici l'analyse sur pièces : la campagne utilise bien `research-governor rank`.\n\nVeux-tu que je corrige l'instrumentation ?"
        );
        assert!(!stream.text.contains("## Objective"));
        assert!(!stream.text.contains("Continue if you have next steps"));
        // Narration stays in the live stream, separated by paragraph breaks.
        assert!(stream.text.starts_with(
            "Je vais lire le skill `research-boss` et inspecter les fichiers du workspace.\n\nInspectons"
        ));
        assert!(stream.text.contains("principale.\n\nRegardons maintenant"));
    }

    #[test]
    fn opencode_answer_without_tools_is_the_whole_reply() {
        let mut stream = GrokStream::default();
        stream.feed(concat!(
            "{\"type\":\"text\",\"sessionID\":\"s\",\"part\":{\"messageID\":\"m\",\"text\":\"One\"}}\n",
            "{\"type\":\"text\",\"sessionID\":\"s\",\"part\":{\"messageID\":\"m\",\"text\":\"Two\"}}\n",
            "{\"type\":\"tool_use\",\"sessionID\":\"s\",\"part\":{\"callID\":\"c\",\"tool\":\"bash\",\"state\":{\"status\":\"completed\"}}}\n",
        ));
        // A turn that ends on a tool keeps everything it said.
        assert_eq!(stream.final_text(), "One\n\nTwo");
    }

    /// Mission 4ad4bc01: Gemini through the proxy numbers tool calls per
    /// response, so OpenCode reported `call_0` for most of 1,771 calls and the
    /// transcript collapsed them into five rows; its narration never reached
    /// history at all.
    #[test]
    fn opencode_tool_ids_are_unique_and_narration_becomes_durable_bubbles() {
        let mut stream = GrokStream::default();
        let mut updates = Vec::new();
        let fixture = include_str!("../../../tests/fixtures/opencode_btw_compaction.jsonl");
        for line in fixture.lines() {
            updates.extend(stream.feed(&format!("{line}\n")));
        }
        updates.extend(stream.feed(concat!(
            "{\"type\":\"tool_use\",\"sessionID\":\"ses_btw\",\"part\":{\"id\":\"prt_x1\",\"callID\":\"call_0\",\"tool\":\"read\",\"state\":{\"status\":\"completed\"}}}\n",
            "{\"type\":\"tool_use\",\"sessionID\":\"ses_btw\",\"part\":{\"id\":\"prt_x2\",\"callID\":\"call_0\",\"tool\":\"read\",\"state\":{\"status\":\"completed\"}}}\n",
        )));
        let ids: Vec<String> = updates
            .iter()
            .filter_map(|u| match u {
                StreamUpdate::Tool {
                    update,
                    completed: false,
                } => Some(update["toolCallId"].as_str().unwrap().to_string()),
                _ => None,
            })
            .collect();
        let unique: std::collections::HashSet<_> = ids.iter().collect();
        assert_eq!(unique.len(), ids.len(), "{ids:?}");
        assert!(ids.contains(&"prt_x1:call_0".to_string()));
        let bubbles: Vec<(String, String)> = updates
            .iter()
            .filter_map(|u| match u {
                StreamUpdate::NativeText(v) => Some((
                    v["bubble_id"].as_str().unwrap().to_string(),
                    v["ops"][0]["text"].as_str().unwrap().to_string(),
                )),
                _ => None,
            })
            .collect();
        assert_eq!(bubbles[0].0, "opencode:ses_btw:prt_02");
        assert!(bubbles[0].1.starts_with("Je vais lire"));
        assert!(bubbles[1].1.starts_with("Inspectons"));
        assert!(bubbles
            .iter()
            .all(|(_, text)| !text.contains("## Objective")));
        // The answer before the trailing tools is narration too, exactly once.
        assert_eq!(
            bubbles
                .iter()
                .filter(|(_, t)| t.starts_with("Voici l'analyse"))
                .count(),
            1
        );
        assert!(!updates
            .iter()
            .any(|u| matches!(u, StreamUpdate::TextSnapshot(_))));
        assert!(stream.opencode_unflushed_text().trim().is_empty());
    }

    #[test]
    fn opencode_usage_sums_step_tokens() {
        let mut stream = GrokStream::default();
        stream.feed(concat!(
            "{\"type\":\"step_finish\",\"sessionID\":\"s\",\"part\":{\"reason\":\"tool-calls\",\"tokens\":{\"input\":100,\"output\":10,\"reasoning\":5,\"cache\":{\"read\":40,\"write\":0}}}}\n",
            "{\"type\":\"step_finish\",\"sessionID\":\"s\",\"part\":{\"reason\":\"stop\",\"tokens\":{\"input\":200,\"output\":20,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}}}}\n",
        ));
        let usage = stream.opencode_usage.unwrap();
        assert_eq!(usage.input_tokens, 300);
        assert_eq!(usage.output_tokens, 35);
        assert_eq!(usage.cache_read_input_tokens, Some(40));
    }

    /// /btw 412e22b7 job aea7c97e: answer, then a compaction (summary and
    /// `compaction_continue`), then a short closing line.
    #[test]
    fn opencode_closing_line_after_compaction_keeps_the_answer() {
        let mut stream = GrokStream::default();
        let line = |v: serde_json::Value| format!("{v}\n");
        let s = "ses_b";
        for v in [
            serde_json::json!({"type":"text","sessionID":s,"part":{"id":"p1","messageID":"m1","text":"Je regarde les derniers messages."}}),
            serde_json::json!({"type":"tool_use","sessionID":s,"part":{"id":"p2","messageID":"m1","callID":"call_0","tool":"bash","state":{"status":"completed"}}}),
            serde_json::json!({"type":"text","sessionID":s,"part":{"id":"p3","messageID":"m2","text":"Voici le détail exact des **3 contre-exemples**."}}),
            serde_json::json!({"type":"step_finish","sessionID":s,"part":{"messageID":"m2","reason":"stop"}}),
            serde_json::json!({"type":"text","sessionID":s,"part":{"id":"p4","messageID":"m3","text":"## Objective\n- summary"}}),
            serde_json::json!({"type":"step_finish","sessionID":s,"part":{"messageID":"m3","reason":"stop"}}),
            serde_json::json!({"type":"text","sessionID":s,"part":{"id":"p5","messageID":"m4","synthetic":true,"metadata":{"compaction_continue":true},"text":"Continue if you have next steps"}}),
            serde_json::json!({"type":"text","sessionID":s,"part":{"id":"p6","messageID":"m5","text":"Everything has been explained."}}),
            serde_json::json!({"type":"step_finish","sessionID":s,"part":{"messageID":"m5","reason":"stop"}}),
        ] {
            stream.feed(&line(v));
        }
        assert_eq!(
            stream.final_text(),
            "Voici le détail exact des **3 contre-exemples**.\n\nEverything has been explained."
        );
    }

    /// Test mission f2a93461 (gemini-4-argon): the bash part prt_b427a was
    /// printed before the text part prt_b4000 that introduces it.
    #[test]
    fn opencode_text_printed_after_its_tool_is_narration() {
        let mut stream = GrokStream::default();
        let mut updates = Vec::new();
        for v in [
            serde_json::json!({"type":"tool_use","sessionID":"s","part":{"id":"prt_b427a","messageID":"m1","callID":"call_0","tool":"bash","state":{"status":"completed"}}}),
            serde_json::json!({"type":"text","sessionID":"s","part":{"id":"prt_b4000","messageID":"m1","text":"J'exécute `cat note.txt`."}}),
            serde_json::json!({"type":"text","sessionID":"s","part":{"id":"prt_b5000","messageID":"m2","text":"RÉSULTAT: beta"}}),
            serde_json::json!({"type":"step_finish","sessionID":"s","part":{"messageID":"m2","reason":"stop"}}),
        ] {
            updates.extend(stream.feed(&format!("{v}\n")));
        }
        assert_eq!(stream.final_text(), "RÉSULTAT: beta");
        assert!(updates
            .iter()
            .any(|u| matches!(u, StreamUpdate::NativeText(v)
            if v["bubble_id"] == "opencode:s:prt_b4000")));
    }

    async fn opencode_goal_turn_status(text: &str, stop_first: bool) -> Option<String> {
        use crate::api::mission_store::{MissionStore, SqliteMissionStore};
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().join("missions"), "host-goal")
                .await
                .unwrap(),
        );
        let mission = store
            .create_mission(Some("goal"), None, None, None, None, Some("opencode"), None)
            .await
            .unwrap();
        store
            .update_mission_goal(mission.id, true, Some("never stop, report every 30 min"))
            .await
            .unwrap();
        let (tx, mut rx) = tokio::sync::broadcast::channel(64);
        let owner = RemoteMissionOwner {
            mission_store: store.clone(),
            events_tx: Some(tx.clone()),
        };
        let job = Uuid::new_v4();
        let mut observer = NativeGrokObserver::attach(&owner, "old-agent", mission.id, job)
            .await
            .unwrap();
        if stop_first {
            super::super::goal::disarm_goal_on_user_stop(&store, &tx, mission.id)
                .await
                .unwrap();
            while rx.try_recv().is_ok() {}
        }
        let line = serde_json::json!({"type":"text","sessionID":"s","part":{"id":"p1","messageID":"m","text":text}});
        observer.stream.feed(&format!(
            "{line}\n{{\"type\":\"step_finish\",\"sessionID\":\"s\",\"part\":{{\"reason\":\"stop\"}}}}\n"
        ));
        let status: NodeJobStatus = serde_json::from_value(serde_json::json!({
            "job_id":job,"mission_id":mission.id,"state":"succeeded","exit_code":0,
            "created_at":"2026-10-21T13:38:24Z"
        }))
        .unwrap();
        observer.verdict(&status, "old-agent").await;
        let mut goal = None;
        while let Ok(event) = rx.try_recv() {
            if let AgentEvent::GoalStatus { status, .. } = event {
                goal = Some(status);
            }
        }
        goal
    }

    #[tokio::test]
    async fn opencode_goal_marker_completes_and_plain_end_never_does() {
        assert_eq!(
            opencode_goal_turn_status("All done.\n<!-- GOAL_COMPLETE -->", false)
                .await
                .as_deref(),
            Some("complete")
        );
        // No API server in tests, so queuing the continuation fails and the
        // goal pauses; it is never reported complete.
        assert_ne!(
            opencode_goal_turn_status("Progress report at 13:38.", false)
                .await
                .as_deref(),
            Some("complete")
        );
    }

    #[tokio::test]
    async fn opencode_goal_after_user_stop_reports_nothing() {
        assert_eq!(
            opencode_goal_turn_status("Progress report.", true).await,
            None
        );
    }

    #[tokio::test]
    async fn opencode_goal_with_pending_wakeup_is_paused_not_complete() {
        use crate::api::mission_store::{
            self as ms, Automation, AutomationDriver, FreshSession, MissionStore, RetryConfig,
            SqliteMissionStore, StopPolicy, TriggerType,
        };
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().join("missions"), "goal-wake")
                .await
                .unwrap(),
        );
        let mission = store
            .create_mission(Some("goal"), None, None, None, None, Some("opencode"), None)
            .await
            .unwrap();
        store
            .update_mission_goal(mission.id, true, Some("optimise until 06:00"))
            .await
            .unwrap();
        store
            .create_automation(Automation {
                id: Uuid::new_v4(),
                mission_id: mission.id,
                command_source: ms::CommandSource::Inline {
                    content: "deliver the summary".into(),
                },
                trigger: TriggerType::Interval { seconds: 3600 },
                variables: std::collections::HashMap::from([(
                    "__wakeup_source".into(),
                    "automation-manager".into(),
                )]),
                active: true,
                stop_policy: StopPolicy::AfterFirstFire,
                fresh_session: FreshSession::Keep,
                created_at: ms::now_string(),
                last_triggered_at: None,
                retry_config: RetryConfig::default(),
                consecutive_failures: 0,
                driver: AutomationDriver::Scheduler,
            })
            .await
            .unwrap();
        let (tx, mut rx) = tokio::sync::broadcast::channel(64);
        let owner = RemoteMissionOwner {
            mission_store: store,
            events_tx: Some(tx),
        };
        let job = Uuid::new_v4();
        let mut observer = NativeGrokObserver::attach(&owner, "old-agent", mission.id, job)
            .await
            .unwrap();
        observer.stream.feed(concat!(
            "{\"type\":\"text\",\"sessionID\":\"s\",\"part\":{\"id\":\"p1\",\"messageID\":\"m\",\"text\":\"Waiting for 06:00.\"}}\n",
            "{\"type\":\"step_finish\",\"sessionID\":\"s\",\"part\":{\"reason\":\"stop\"}}\n",
        ));
        let status: NodeJobStatus = serde_json::from_value(serde_json::json!({
            "job_id":job,"mission_id":mission.id,"state":"succeeded","exit_code":0,
            "created_at":"2026-10-21T04:46:00Z"
        }))
        .unwrap();
        observer.verdict(&status, "old-agent").await;
        let mut goal = None;
        while let Ok(event) = rx.try_recv() {
            if let AgentEvent::GoalStatus { status, .. } = event {
                goal = Some(status);
            }
        }
        assert_eq!(goal.as_deref(), Some("paused"));
    }

    #[tokio::test]
    async fn opencode_verdict_records_only_the_final_answer() {
        use crate::api::mission_store::{MissionStore, SqliteMissionStore};
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().join("missions"), "btw-final")
                .await
                .unwrap(),
        );
        let mission = store
            .create_mission(Some("btw"), None, None, None, None, Some("opencode"), None)
            .await
            .unwrap();
        let owner = RemoteMissionOwner {
            mission_store: store,
            events_tx: None,
        };
        let job = Uuid::new_v4();
        let mut observer = NativeGrokObserver::attach(&owner, "sepolia", mission.id, job)
            .await
            .unwrap();
        let fixture = include_str!("../../../tests/fixtures/opencode_btw_compaction.jsonl");
        for line in fixture.lines() {
            observer.stream.feed(&format!("{line}\n"));
        }
        let status: NodeJobStatus = serde_json::from_value(serde_json::json!({
            "job_id":job,"mission_id":mission.id,"state":"succeeded","exit_code":0,
            "created_at":"2026-10-20T17:53:54Z"
        }))
        .unwrap();
        let verdict = observer.verdict(&status, "sepolia").await;
        assert!(verdict.success);
        assert!(verdict.content.starts_with("Voici l'analyse sur pièces"));
        assert!(!verdict.content.contains("Je vais lire"));
        assert!(!verdict.content.contains("## Objective"));
    }

    #[tokio::test]
    async fn missing_cli_before_native_protocol_is_a_setup_failure() {
        use crate::api::mission_store::{MissionStore, SqliteMissionStore};
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().join("missions"), "startup")
                .await
                .unwrap(),
        );
        let mission = store
            .create_mission(Some("test"), None, None, None, None, Some("opencode"), None)
            .await
            .unwrap();
        let owner = RemoteMissionOwner {
            mission_store: store,
            events_tx: None,
        };
        let job = Uuid::new_v4();
        let mut observer = NativeGrokObserver::attach(&owner, "node", mission.id, job)
            .await
            .unwrap();
        observer
            .stream
            .feed("OpenCode CLI is not installed on this node\n");
        let status: NodeJobStatus = serde_json::from_value(serde_json::json!({
            "job_id":job,"mission_id":mission.id,"state":"failed","exit_code":127,
            "error":"command exited with Some(127)","created_at":"2026-10-10T00:00:00Z"
        }))
        .unwrap();
        let verdict = observer.verdict(&status, "node").await;
        assert!(!verdict.success);
        assert_eq!(verdict.status_reason, "remote_configuration");
    }

    #[test]
    fn generated_resume_preserves_user_authored_markers() {
        let objective = "Test recovery prompts\n\n[Automatic recovery]\nKeep these instructions\n\nYou were interrupted, resume your work.";
        let prompt = goal_resume_prompt(objective);
        assert_eq!(
            prompt,
            format!(
                "/goal {objective}\n\n{}",
                super::super::INTERRUPTED_RESUME_PROMPT
            )
        );
    }

    #[test]
    fn opencode_error_is_a_terminal_tool_result() {
        let mut stream = GrokStream::default();
        let updates=stream.feed("{\"type\":\"tool_use\",\"sessionID\":\"ses_error\",\"part\":{\"callID\":\"call_error\",\"tool\":\"webfetch\",\"state\":{\"status\":\"error\",\"error\":\"HTTP 403\"}}}\n");
        assert!(updates.iter().any(|u|matches!(u,StreamUpdate::Tool {update,completed:true} if update["status"]=="failed" && update["error"]=="HTTP 403")));
    }

    #[test]
    fn opencode_stream_preserves_session_text_and_tools_across_chunks() {
        let mut stream = GrokStream::default();
        let lines = concat!(
            "{\"type\":\"reasoning\",\"sessionID\":\"ses_test\",\"part\":{\"text\":\"Planning\"}}\n",
            "{\"type\":\"text\",\"sessionID\":\"ses_test\",\"part\":{\"text\":\"Checking files\"}}\n",
            "{\"type\":\"tool_use\",\"sessionID\":\"ses_test\",\"part\":{\"callID\":\"call_1\",\"tool\":\"bash\",\"state\":{\"status\":\"completed\",\"input\":{\"command\":\"pwd\"},\"output\":\"/workspace\"}}}\n",
            "{\"type\":\"step_finish\",\"sessionID\":\"ses_test\",\"part\":{\"reason\":\"tool-calls\"}}\n",
            "{\"type\":\"text\",\"sessionID\":\"ses_test\",\"part\":{\"text\":\"Done\"}}\n",
            "{\"type\":\"step_finish\",\"sessionID\":\"ses_test\",\"part\":{\"reason\":\"stop\"}}\n"
        );
        let mut updates = stream.feed(&lines[..17]);
        updates.extend(stream.feed(&lines[17..]));
        assert_eq!(stream.session_id.as_deref(), Some("ses_test"));
        assert_eq!(stream.thinking, "Planning");
        assert_eq!(stream.text, "Checking files\n\nDone");
        assert_eq!(stream.final_text(), "Done");
        assert!(stream.progress);
        assert!(stream.ended);
        assert_eq!(stream.stop_reason.as_deref(), Some("end_turn"));
        assert!(updates.iter().any(|u| matches!(
            u,
            StreamUpdate::Tool {
                completed: true,
                ..
            }
        )));
        let plan = RemoteHarnessPlan::OpenCode {
            model: Some("smart".into()),
            prompt: "continue".into(),
            resume_session_id: Some("ses_test".into()),
        };
        let execution =
            super::super::remote_execution_for_plan(&plan, "https://core.example", "test-key");
        assert!(execution.command.contains("--session 'ses_test'"));
    }

    #[tokio::test]
    async fn native_finish_preserves_event_order_with_delayed_logger() {
        use crate::api::mission_store::{MissionStore, SqliteMissionStore};
        use std::sync::Arc;

        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().join("missions"), "native-events")
                .await
                .unwrap(),
        );
        let mission = store
            .create_mission(Some("hostname"), None, None, None, None, Some("grok"), None)
            .await
            .unwrap();
        let (tx, mut rx) = tokio::sync::broadcast::channel(1024);
        let owner = RemoteMissionOwner {
            mission_store: store.clone(),
            events_tx: Some(tx),
        };
        let job_id = Uuid::new_v4();
        let mut observer = NativeGrokObserver::attach(&owner, "spark", mission.id, job_id)
            .await
            .unwrap();
        observer.streaming = LogStreaming::Supported;
        // The real hostname canary has one tool invocation, text deltas and
        // a repeated full text snapshot. Hold the logger until after finish
        // to deterministically reproduce the former direct-write race.
        let fixture = include_str!("../../../tests/fixtures/native_grok_fixed_session.jsonl");
        for line in fixture.lines() {
            let updates = observer.stream.feed(&format!("{line}\n"));
            observer.broadcast(updates).await;
        }
        let status: NodeJobStatus = serde_json::from_value(serde_json::json!({
            "job_id":job_id, "mission_id":mission.id, "state":"succeeded",
            "exit_code":0, "created_at":"2026-09-20T00:00:00Z"
        }))
        .unwrap();
        let verdict = observer.verdict(&status, "spark").await;
        assert!(verdict.success);
        let final_text = verdict.content.clone();
        super::super::finalize_remote_mission(
            &owner,
            mission.id,
            None,
            "spark",
            verdict.success,
            verdict.content,
            verdict.status_reason,
            true,
            observer.usage(),
            None,
        )
        .await
        .unwrap();
        assert!(
            store
                .get_events(mission.id, None, None, None)
                .await
                .unwrap()
                .is_empty(),
            "native events must not race the queued logger with direct writes"
        );
        let mut canonical_seen = false;
        let mut canonical_count = 0;
        let mut tool_calls = 0;
        let mut tool_results = 0;
        while let Ok(event) = rx.try_recv() {
            match &event {
                AgentEvent::AssistantMessage { content, .. } => {
                    assert_eq!(content, &final_text);
                    canonical_seen = true;
                    canonical_count += 1;
                }
                AgentEvent::TextDelta { .. } => assert!(
                    !canonical_seen,
                    "no text delta after the canonical assistant message"
                ),
                AgentEvent::ToolCall { .. } => tool_calls += 1,
                AgentEvent::ToolResult { .. } => tool_results += 1,
                _ => {}
            }
            if super::super::should_persist_event(&event) {
                store.log_event(mission.id, &event).await.unwrap();
            }
        }
        assert_eq!(canonical_count, 1);
        assert_eq!(
            tool_calls, 1,
            "observation must not repeat the node invocation"
        );
        assert_eq!(tool_results, 1);
        let saved = store
            .get_events(mission.id, None, None, None)
            .await
            .unwrap();
        let canonical = saved
            .iter()
            .find(|e| e.event_type == "assistant_message")
            .unwrap();
        assert!(saved
            .iter()
            .filter(|e| e.event_type == "text_delta")
            .all(|e| e.sequence < canonical.sequence));
        assert_eq!(
            saved.iter().filter(|e| e.event_type == "tool_call").count(),
            1
        );
        assert_eq!(
            saved
                .iter()
                .filter(|e| e.event_type == "tool_result")
                .count(),
            1
        );
    }

    fn assert_spark_stream(stream: &GrokStream, updates: &[StreamUpdate]) {
        assert_eq!(stream.json_events, 420);
        assert_eq!(stream.text, SPARK_TEXT);
        assert!(stream.ended);
        assert_eq!(stream.stop_reason.as_deref(), Some("end_turn"));
        assert_eq!(
            stream.session_id.as_deref(),
            Some("01a0beb8-9ccf-7a43-bf61-ef87af487088")
        );
        assert!(!stream.auth_required);
        assert!(stream.error.is_none());
        assert!(stream.diagnostics.is_empty());
        assert!(stream.partial.is_empty());
        assert_eq!(
            updates
                .iter()
                .filter(|u| matches!(
                    u,
                    StreamUpdate::Tool {
                        completed: false,
                        ..
                    }
                ))
                .count(),
            35
        );
        assert_eq!(
            updates
                .iter()
                .filter(|u| matches!(
                    u,
                    StreamUpdate::Tool {
                        completed: true,
                        ..
                    }
                ))
                .count(),
            76
        );
        assert_eq!(
            updates
                .iter()
                .filter(|u| matches!(u, StreamUpdate::SessionId(_)))
                .count(),
            1
        );
        assert_eq!(
            updates
                .iter()
                .filter(|u| matches!(u, StreamUpdate::End))
                .count(),
            1
        );
    }

    #[test]
    fn real_spark_goal_resume_stream_preserves_progress_and_deduplicates_snapshot() {
        let mut stream = GrokStream::default();
        let mut updates = Vec::new();
        for line in SPARK_STREAM.lines() {
            updates.extend(stream.feed(line));
            updates.extend(stream.feed("\n"));
            if !stream.ended && !stream.text.is_empty() {
                assert!(updates
                    .iter()
                    .any(|u| matches!(u, StreamUpdate::TextSnapshot(_))));
            }
        }
        updates.extend(stream.finish());
        assert_spark_stream(&stream, &updates);
    }

    #[tokio::test]
    async fn real_spark_stream_survives_bounded_log_cursors_and_unterminated_end() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("stream.jsonl");
        // Exercise finish() as well as lines split across node log chunks.
        std::fs::write(&path, SPARK_STREAM.trim_end_matches('\n')).unwrap();
        for chunk_size in [257, 4096, 65536] {
            let mut stream = GrokStream::default();
            let mut updates = Vec::new();
            let mut offset = 0;
            loop {
                let (data, next, len) =
                    crate::node::read_log_chunk(&path, offset, chunk_size, true)
                        .await
                        .unwrap();
                assert!(next > offset);
                assert!(data.len() <= chunk_size as usize);
                updates.extend(stream.feed(&data));
                assert!(stream.partial.len() <= 1024 * 1024);
                offset = next;
                if offset == len {
                    break;
                }
            }
            assert!(!stream.ended);
            updates.extend(stream.finish());
            assert_spark_stream(&stream, &updates);
        }
    }

    #[test]
    fn stream_coalesces_delta_bursts_without_moving_tools_or_copying_per_delta() {
        let mut stream = GrokStream::default();
        let deltas: String = (0..500)
            .map(|i| format!("{{\"type\":\"text\",\"data\":\"{i},\"}}\n"))
            .collect();
        let segment: String = (0..500).map(|i| format!("{i},")).collect();
        let thought = "{\"type\":\"thought\",\"data\":\"p\"}\n";
        let chunk = format!(
            "{}{}{{\"type\":\"tool_call\",\"toolCallId\":\"t\"}}\n{}",
            thought.repeat(500),
            deltas,
            deltas
        );
        let updates = stream.feed(&chunk);
        assert_eq!(updates.len(), 4, "one snapshot per segment, not per event");
        assert_eq!(updates[0], StreamUpdate::ThinkingSnapshot("p".repeat(500)));
        assert_eq!(updates[1], StreamUpdate::TextSnapshot(segment.clone()));
        assert!(matches!(updates[2], StreamUpdate::Tool { .. }));
        assert_eq!(updates[3], StreamUpdate::TextSnapshot(segment.repeat(2)));
        let copied_bytes: usize = updates
            .iter()
            .map(|u| match u {
                StreamUpdate::TextSnapshot(s) | StreamUpdate::ThinkingSnapshot(s) => s.len(),
                _ => 0,
            })
            .sum();
        assert_eq!(copied_bytes, 500 + segment.len() * 3);
    }

    #[test]
    fn real_fixed_session_fixture_matches_preallocated_cli_identity() {
        let fixture = include_str!("../../../tests/fixtures/native_grok_fixed_session.jsonl");
        let id = "a1778740-4e51-4de4-b8c3-0f16d68b07de";
        let mut stream = GrokStream::default();
        for line in fixture.lines() {
            let value: serde_json::Value = serde_json::from_str(line).unwrap();
            if value["type"] != "end" {
                assert!(grok_event_session_id(&value).is_none());
            }
            stream.feed(&format!("{line}\n"));
        }
        assert_eq!(stream.session_id.as_deref(), Some(id));
        let fresh = execution(None, "/goal objective", None, Some(id), "grok".into());
        assert!(fresh.command.contains(&format!("--session-id '{id}'")));
        assert!(!fresh.command.contains("--resume"));
        let resumed = execution(None, "/goal resume", Some(id), None, "grok".into());
        assert!(resumed.command.contains(&format!("--resume '{id}'")));
        assert!(!resumed.command.contains("--session-id"));
    }

    #[test]
    fn plan_preserves_native_goal_and_pins_a_model() {
        let plan = super::plan(None, "/goal ship the vanity generator".into());
        let RemoteHarnessPlan::Grok {
            model,
            prompt,
            resume_session_id,
            new_session_id,
        } = plan
        else {
            panic!("grok plan");
        };
        assert_eq!(
            model.as_deref(),
            Some(resolve_grok_default_model().as_str())
        );
        assert_eq!(prompt, "/goal ship the vanity generator");
        assert_eq!(resume_session_id, None);

        assert!(Uuid::parse_str(new_session_id.as_deref().unwrap()).is_ok());
        let plain = super::plan(Some("grok-4.6".into()), "say hi".into());
        assert_eq!(
            plain,
            RemoteHarnessPlan::Grok {
                model: Some("grok-4.6".into()),
                prompt: "say hi".into(),
                resume_session_id: None,
                new_session_id: match &plain {
                    RemoteHarnessPlan::Grok { new_session_id, .. } => new_session_id.clone(),
                    _ => unreachable!(),
                }
            }
        );
    }

    #[test]
    fn execution_requests_managed_auth_by_name_and_fails_closed() {
        let exec = execution(
            Some("grok-4.6"),
            "-list files it's here",
            Some("sess-1"),
            None,
            "grok/grok-4.6".into(),
        );
        assert_eq!(exec.managed_auth, vec!["grok".to_string()]);
        let env = exec.env.unwrap();
        assert_eq!(env.get("NO_COLOR").map(String::as_str), Some("1"));
        // No credential-shaped or home-shaped env: the node owns both.
        assert!(env
            .keys()
            .all(|key| !key.starts_with("GROK_") && !key.starts_with("XAI_")));
        let command = &exec.command;
        assert!(
            command.starts_with("command -v grok >/dev/null 2>&1 ||"),
            "{command}"
        );
        assert!(
            command.contains("[ -r \"${GROK_HOME}/auth.json\" ] ||"),
            "{command}"
        );
        assert!(command.contains("exit 78; }; exec grok --output-format streaming-json --always-approve --no-plan --model 'grok-4.6' --resume 'sess-1' --cwd \"$PWD\" -p ' -list files it'\\''s here'"), "{command}");
        assert!(
            !command.contains("auth.json'"),
            "no path literal beyond the guard: {command}"
        );

        let fresh = execution(None, "hi", None, None, "grok".into());
        assert!(fresh.command.ends_with("exec grok --output-format streaming-json --always-approve --no-plan --cwd \"$PWD\" -p 'hi'"), "{}", fresh.command);
        assert!(!fresh.command.contains("--resume"));
        assert!(!fresh.command.contains("--session-id"));
        assert!(!fresh.command.contains("--continue"));
    }

    #[test]
    fn native_goal_resume_and_snapshot_deduplication() {
        let command = execution(
            Some("grok-4.6"),
            "/goal resume",
            Some("native-session"),
            None,
            "grok".into(),
        )
        .command;
        assert!(command.contains("--resume 'native-session'"));
        assert!(command.ends_with("-p '/goal resume'"));
        let mut stream = GrokStream::default();
        for text in ["Hel", "lo 🦀", "Hello 🦀", "Next", " phase", "Next phase"] {
            stream.feed(&format!(
                "{}\n",
                serde_json::json!({"type":"text", "data":text})
            ));
        }
        assert_eq!(stream.text, "Hello 🦀Next phase");
        assert!(!stream.text.contains("goal_complete"));
    }

    #[test]
    fn interrupted_turn_text_is_persisted_once_and_marked_partial() {
        let (mission, job) = (Uuid::new_v4(), Uuid::new_v4());
        assert!(partial_turn_message(mission, job, "  \n").is_none());
        let first = partial_turn_message(mission, job, "step 1 done\nstep 2 done\n").unwrap();
        let again = partial_turn_message(mission, job, "step 1 done\nstep 2 done").unwrap();
        match (&first, &again) {
            (
                AgentEvent::AssistantMessage {
                    id,
                    content,
                    success,
                    completion_evidence,
                    ..
                },
                AgentEvent::AssistantMessage { id: retry, .. },
            ) => {
                assert_eq!(id, retry, "a retried terminal pass reuses the row");
                assert_eq!(content, "step 1 done\nstep 2 done");
                assert!(*success);
                let evidence = completion_evidence.as_ref().unwrap();
                assert_eq!(evidence.classification_source, PARTIAL_TURN_CLASSIFICATION);
                assert_eq!(
                    evidence.terminal_reason,
                    Some(crate::agents::TerminalReason::Cancelled)
                );
            }
            _ => panic!("expected assistant messages"),
        }
        assert_ne!(
            partial_turn_message(mission, Uuid::new_v4(), "x").map(|e| match e {
                AgentEvent::AssistantMessage { id, .. } => id,
                _ => Uuid::nil(),
            }),
            partial_turn_message(mission, job, "x").map(|e| match e {
                AgentEvent::AssistantMessage { id, .. } => id,
                _ => Uuid::nil(),
            }),
        );
    }

    #[test]
    fn oversized_partial_line_is_dropped_then_parser_recovers() {
        let mut stream = GrokStream::default();
        stream.feed(&"x".repeat(1024 * 1024 + 1));
        assert!(stream.partial.is_empty());
        stream.feed("\n{\"type\":\"text\",\"data\":\"ok\"}\n");
        assert_eq!(stream.text, "ok");
    }

    #[test]
    fn heartbeat_gate_names_the_fix() {
        assert!(heartbeat_supports_grok(&["grok".into()], "dgx").is_ok());
        let err = heartbeat_supports_grok(&[], "dgx").unwrap_err();
        assert!(err.starts_with("REMOTE_AUTH_REQUIRED: "), "{err}");
        assert!(err.contains("SANDBOXED_NODE_GROK_HOME"), "{err}");
        assert!(err.contains("grok login --device-auth"), "{err}");
    }

    #[test]
    fn stream_parses_text_thought_end_and_partial_lines() {
        let mut stream = GrokStream::default();
        let mut updates = stream.feed("A new version of Grok Build is available: 0.1.210 -> 1.0.34\n{\"type\":\"thought\",\"data\":\"plan\"}\n{\"type\":\"text\",\"data\":\"Hel\"}\n{\"type\":\"text\",\"da");
        assert_eq!(
            updates,
            vec![
                StreamUpdate::ThinkingSnapshot("plan".into()),
                StreamUpdate::TextSnapshot("Hel".into())
            ]
        );
        assert_eq!(stream.text, "Hel");
        assert_eq!(stream.thinking, "plan");
        updates = stream.feed("ta\":\"lo <goal_continue/>\"}\n{\"type\":\"end\",\"stopReason\":\"EndTurn\",\"sessionId\":\"abc123\",\"requestId\":\"r1\"}\n");
        assert_eq!(
            updates,
            vec![
                StreamUpdate::TextSnapshot("Hello <goal_continue/>".into()),
                StreamUpdate::SessionId("abc123".into()),
                StreamUpdate::End
            ]
        );
        assert_eq!(stream.text, "Hello <goal_continue/>");
        assert!(stream.ended);
        assert_eq!(stream.stop_reason.as_deref(), Some("EndTurn"));
        assert_eq!(stream.session_id.as_deref(), Some("abc123"));
        assert!(!stream.auth_required);
        assert_eq!(stream.diagnostics.len(), 1);
        assert_eq!(stream.json_events, 4);
        assert!(stream.finish().is_empty());
    }

    /// c96df4f9: the saved thread had no rollout. The replacement thread
    /// becomes the session and the reason is kept as a transcript card.
    #[test]
    fn codex_stream_records_recovery_and_binds_the_fresh_thread() {
        let mut stream = GrokStream::default();
        let updates = stream.feed(concat!(
            "{\"type\":\"session.recovered\",\"previous_thread_id\":\"lost\",\"reason\":\"no rollout found for thread id lost\"}\n",
            "{\"type\":\"thread.started\",\"thread_id\":\"fresh\"}\n",
        ));
        match &updates[0] {
            StreamUpdate::Tool { update, completed } => {
                assert!(completed);
                assert_eq!(update["name"], "session_recovered");
                assert!(update["output"]
                    .as_str()
                    .unwrap()
                    .contains("no rollout found"));
            }
            other => panic!("unexpected update {other:?}"),
        }
        assert!(matches!(&updates[1], StreamUpdate::SessionId(id) if id == "fresh"));
        assert!(stream.error.is_none());
    }

    #[test]
    fn codex_stream_preserves_thread_tools_text_and_failure() {
        let mut stream = GrokStream::default();
        let events = concat!(
            "{\"type\":\"thread.started\",\"thread_id\":\"thread-123\"}\n",
            "{\"type\":\"item.started\",\"item\":{\"type\":\"command_execution\",\"id\":\"cmd-1\",\"command\":\"pwd\"}}\n",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"id\":\"cmd-1\",\"status\":\"completed\",\"aggregated_output\":\"/work\"}}\n",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Done\"}}\n",
            "{\"type\":\"turn.completed\",\"usage\":{}}\n",
        );
        let mut updates = stream.feed(&events[..23]);
        updates.extend(stream.feed(&events[23..]));
        assert_eq!(stream.session_id.as_deref(), Some("thread-123"));
        assert_eq!(stream.text, "Done");
        assert!(stream.ended && stream.progress);
        assert!(matches!(
            &updates[1],
            StreamUpdate::Tool {
                completed: false,
                ..
            }
        ));
        assert!(matches!(
            &updates[2],
            StreamUpdate::Tool {
                completed: true,
                ..
            }
        ));
        assert_eq!(updates.last(), Some(&StreamUpdate::End));
        stream.feed("{\"type\":\"turn.failed\",\"error\":{\"message\":\"rate limited\"}}\n");
        assert_eq!(stream.error.as_deref(), Some("rate limited"));
    }

    #[tokio::test]
    async fn codex_followup_verdict_uses_native_execution_mode() {
        use crate::api::mission_store::SqliteMissionStore;

        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().join("missions"), "codex-followup")
                .await
                .unwrap(),
        );
        let mission = store
            .create_mission(
                Some("results?"),
                None,
                None,
                None,
                None,
                Some("codex"),
                None,
            )
            .await
            .unwrap();
        let owner = RemoteMissionOwner {
            mission_store: store,
            events_tx: None,
        };
        // Missing receipts and actual native stop states must remain fail-closed.
        for (mode, goal_status, exit_code, ended, expected_success) in [
            (Some("turn"), None, 0, true, true),
            (Some("turn"), None, 1, true, false),
            (Some("turn"), None, 0, false, false),
            (None, None, 0, true, false),
            (Some("unknown"), None, 0, true, false),
            (Some("goal"), None, 0, true, false),
            (Some("goal"), Some("complete"), 0, true, true),
            (Some("goal"), Some("blocked"), 0, true, false),
            (Some("goal"), Some("paused"), 0, true, false),
            (Some("goal"), Some("budgetLimited"), 0, true, false),
            (Some("goal"), Some("usageLimited"), 0, true, false),
            (Some("turn"), Some("blocked"), 0, true, false),
        ] {
            let job_id = Uuid::new_v4();
            let mut observer = NativeGrokObserver::attach(&owner, "old-agent", mission.id, job_id)
                .await
                .unwrap();
            observer.mission.goal_mode = true;
            observer.streaming = LogStreaming::Supported;
            if let Some(mode) = mode {
                observer.stream.feed(&format!(
                    "{}\n",
                    serde_json::json!({"type":"execution.mode", "mode":mode})
                ));
            }
            if let Some(status) = goal_status {
                observer.stream.feed(&format!(
                    "{}\n",
                    serde_json::json!({"type":"goal.status", "status":status})
                ));
            }
            observer.stream.feed("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"id\":\"answer\",\"text\":\"Both tasks passed.\"}}\n");
            if ended {
                observer.stream.feed("{\"type\":\"turn.completed\"}\n");
            }
            let status: NodeJobStatus = serde_json::from_value(serde_json::json!({
                "job_id":job_id, "mission_id":mission.id, "state":"succeeded",
                "exit_code":exit_code, "created_at":"2026-10-02T21:29:10Z"
            }))
            .unwrap();
            let verdict = observer.verdict(&status, "old-agent").await;
            assert_eq!(
                verdict.success, expected_success,
                "mode={mode:?}, goal={goal_status:?}, exit={exit_code}, ended={ended}"
            );
            if expected_success {
                assert_eq!(verdict.content, "Both tasks passed.");
                assert_eq!(verdict.status_reason, "remote_node_job");
            }
        }
    }

    #[test]
    fn codex_turn_end_never_fabricates_goal_completion() {
        let mut stream = GrokStream::default();
        stream.feed("{\"type\":\"turn.completed\"}\n");
        assert_eq!(stream.native_goal_status, None);
        stream.feed(
            "{\"type\":\"goal.status\",\"status\":\"active\",\"objective\":\"full roadmap\"}\n",
        );
        stream.feed("{\"type\":\"turn.completed\"}\n");
        assert_eq!(stream.native_goal_status.as_deref(), Some("active"));
        let updates = stream.feed(
            "{\"type\":\"goal.status\",\"status\":\"blocked\",\"objective\":\"full roadmap\"}\n",
        );
        assert_eq!(stream.native_goal_status.as_deref(), Some("blocked"));
        assert!(
            matches!(&updates[0], StreamUpdate::GoalStatus { status, .. } if status == "blocked")
        );
    }

    #[test]
    fn stream_flags_interactive_login_and_errors() {
        let mut stream = GrokStream::default();
        let updates = stream.feed("\nSigning in with Grok...\nOpen this URL to sign in:\n  https://auth.x.ai/oauth2/authorize?x=y\n");
        assert_eq!(updates, vec![StreamUpdate::AuthRequired]);
        assert!(stream.auth_required);
        let mut stream = GrokStream::default();
        let updates = stream.feed("{\"type\":\"error\",\"error\":\"model not found\"}\n");
        assert_eq!(updates, vec![StreamUpdate::Error("model not found".into())]);
        assert_eq!(stream.error.as_deref(), Some("model not found"));
        // A JSON line containing the sign-in words is assistant text, not a prompt.
        let mut stream = GrokStream::default();
        stream.feed("{\"type\":\"text\",\"data\":\"do not open this url to sign in\"}\n");
        assert!(!stream.auth_required);
        // A trailing partial line is flushed at finish.
        let mut stream = GrokStream::default();
        assert!(stream
            .feed("{\"type\":\"text\",\"data\":\"tail\"}")
            .is_empty());
        assert_eq!(
            stream.finish(),
            vec![StreamUpdate::TextSnapshot("tail".into())]
        );
        assert_eq!(stream.text, "tail");
    }

    #[test]
    fn antigravity_plain_reply_in_goal_mission_is_not_a_goal_turn() {
        // Prod 3fe5c5a3 / 9304baf4: each plain reply re-emitted the old goal's
        // `goal_status` because the observer trusted the sticky mission flag.
        let mut mission: Mission = serde_json::from_value(serde_json::json!({
            "id": Uuid::nil(),
            "status": "active",
            "workspace_id": Uuid::nil(),
            "backend": "antigravity",
            "history": [],
            "created_at": "",
            "updated_at": "",
        }))
        .unwrap();
        mission.goal_mode = true;
        mission.goal_objective = Some("old goal".into());
        let mut plain = crate::antigravity::Stream::default();
        assert!(!is_goal_turn(&mission, Some(&plain)));
        plain.goal_mode = true; // agy expanded its native `/goal`
        assert!(is_goal_turn(&mission, Some(&plain)));
        mission.goal_mode = false; // finished or stopped
        assert!(!is_goal_turn(&mission, Some(&plain)));
        mission.goal_mode = true;
        mission.backend = "codex".into();
        assert!(is_goal_turn(&mission, None));
    }

    #[test]
    fn local_resume_refusal_distinguishes_grok_from_other_harnesses() {
        let placement = RemotePlacement {
            node_id: "dgx".into(),
            job_id: Uuid::nil(),
            live: false,
        };
        let mut mission: Mission = serde_json::from_value(serde_json::json!({
            "id": Uuid::nil(),
            "status": "failed",
            "workspace_id": Uuid::nil(),
            "backend": "grok",
            "history": [],
            "created_at": "",
            "updated_at": "",
        }))
        .unwrap();
        let grok = local_resume_refusal(&mission, &placement);
        assert!(
            grok.starts_with("REMOTE_RESUME_REQUIRES_REPLACEMENT: "),
            "{grok}"
        );
        assert!(grok.contains("/resume"), "{grok}");
        mission.backend = "codex".into();
        assert!(local_resume_refusal(&mission, &placement).contains("/resume"));
        mission.backend = "claudecode".into();
        let other = local_resume_refusal(&mission, &placement);
        assert!(other.contains("/resume"), "{other}");
    }
}

#[path = "remote_claude.rs"]
mod claude;
