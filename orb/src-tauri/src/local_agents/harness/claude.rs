//! Claude Code in print mode with stream-json on both pipes: permission
//! requests, plan approval, questions and background tasks over stdio.

use super::*;
use crate::sync_util::lock;
use std::io::Read;
use std::ops::ControlFlow;

pub(crate) const STOPPED_WITHOUT_RESULT: &str = "Claude stopped without a final result";

pub(crate) fn spawn(
    request: &StartRequest,
    ctx: &RunCtx,
    env: &[(String, String)],
    recheck_delays: &[Duration],
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
    // Never stamp commits/PRs with Claude attribution, whatever the user's
    // ~/.claude settings say (CLI settings outrank them).
    cmd.arg("--settings")
        .arg(crate::harness_attribution::claude_settings_arg());
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
    } else {
        let fresh = uuid_like();
        cmd.arg("--session-id").arg(&fresh);
        ctx.bind_session(fresh);
    }
    if let Some(command) = crate::local_wakeups::command(&request.id) {
        cmd.arg("--mcp-config").arg(
            json!({"mcpServers":{"orb-wakeups":{"command":command[0],"args":command[1..]}}})
                .to_string(),
        );
    }
    let mut child = cmd
        .spawn_logged(ctx)
        .map_err(|e| format!("failed to start Claude Code: {e}"))?;
    let stdin = Arc::new(Mutex::new(
        child.stdin.take().ok_or("Claude stdin missing")?,
    ));
    let stdout = child.stdout.take().ok_or("Claude stdout missing")?;
    let recheck = Arc::new(Recheck::default());
    {
        let recheck = Arc::clone(&recheck);
        let stdin = Arc::clone(&stdin);
        let delays = recheck_delays.to_vec();
        thread::spawn(move || recheck.run(&stdin, &delays));
    }
    spawn_line_reader(
        stdout,
        &ctx.output,
        Turn {
            stdin,
            recheck,
            ctx: ctx.clone(),
            mission_id: crate::interactions::session(&request.id),
            resumed: request.session_id.as_deref().is_some_and(|s| !s.is_empty()),
            wakeup_command: crate::local_wakeups::command(&request.id),
            prompt: plan.unwrap_or(&request.prompt).to_owned(),
            execution_approved: plan.is_none(),
            implement_after_result: false,
            claude_text: ClaudeText::default(),
            background: ClaudeBackground::default(),
            request_started: false,
            stale_result_skipped: false,
            completed: false,
            answered: false,
            wakeups: HashMap::new(),
        },
    );
    if let Some(stderr) = child.stderr.take() {
        // Drain the entire pipe, retaining only a bounded prefix. Never
        // publish diagnostic text as an assistant reply or a live error.
        drain_stderr(stderr, ctx, StderrPolicy::ClaudeDiagnostic);
    }
    Ok(child)
}

/// One Claude process: the protocol state its stdout reader keeps.
pub(crate) struct Turn {
    stdin: Arc<Mutex<std::process::ChildStdin>>,
    recheck: Arc<Recheck>,
    ctx: RunCtx,
    mission_id: crate::interactions::Session,
    resumed: bool,
    wakeup_command: Option<Vec<String>>,
    prompt: String,
    execution_approved: bool,
    implement_after_result: bool,
    claude_text: ClaudeText,
    background: ClaudeBackground,
    request_started: bool,
    stale_result_skipped: bool,
    completed: bool,
    /// The turn gave its result and only background tasks remain.
    answered: bool,
    wakeups: HashMap<String, Value>,
}

impl Turn {
    fn send(&self, line: Value) -> Result<(), String> {
        write_line(&mut *lock(&self.stdin), &line.to_string())
    }
    fn say(&self, text: &str) -> Result<(), String> {
        self.send(json!({"type":"user","message":{"role":"user","content":text}}))
    }
    /// The turn has answered and only waits for its background tasks, or it
    /// works again.
    fn waiting(&self, waiting: bool) {
        self.ctx.output.waiting_on_background(waiting);
        self.recheck
            .waiting(waiting.then(|| self.background.list()));
    }
    fn note_wakeups(&mut self, event: &Value) -> Result<(), String> {
        let Some(blocks) = event["message"]["content"].as_array() else {
            return Ok(());
        };
        for block in blocks {
            if event["type"] == "assistant"
                && block["type"] == "tool_use"
                && block["name"] == "ScheduleWakeup"
            {
                if let Some(id) = block["id"].as_str() {
                    self.wakeups.insert(id.into(), block["input"].clone());
                }
            } else if event["type"] == "user" && block["type"] == "tool_result" {
                if let Some(id) = block["tool_use_id"].as_str() {
                    if let Some(mut args) = self.wakeups.remove(id) {
                        if block["is_error"] != true {
                            args["request_id"] = json!(format!("claude-native:{id}"));
                            crate::local_wakeups::capture(self.wakeup_command.as_deref(), args)?;
                        }
                    }
                }
            }
        }
        Ok(())
    }
    fn permission(&mut self, event: &Value) -> Result<Value, String> {
        let tool = event["request"]["tool_name"].as_str().unwrap_or("");
        let input = event["request"]["input"].clone();
        Ok(if tool == "AskUserQuestion" {
            let answers =
                crate::interactions::ask(&self.mission_id, "claude_questions", input.clone())?;
            let mut updated = input;
            updated["answers"] = answers["answers"].clone();
            json!({"behavior":"allow","updatedInput":updated})
        } else if tool == "ExitPlanMode" {
            let answer = crate::interactions::ask(&self.mission_id, "plan", input.clone())?;
            if answer["action"] == "accept" {
                self.implement_after_result = true;
                self.execution_approved = true;
                json!({"behavior":"allow","updatedInput":input})
            } else {
                json!({"behavior":"deny","message":answer["feedback"].as_str().unwrap_or("Please revise the plan.")})
            }
        } else if self.execution_approved {
            json!({"behavior":"allow","updatedInput":input})
        } else {
            let answer = crate::interactions::ask(
                &self.mission_id,
                "permission",
                json!({"tool":tool,"input":input}),
            )?;
            if answer["action"] == "accept" {
                json!({"behavior":"allow","updatedInput":input})
            } else {
                json!({"behavior":"deny","message":"The user declined this action."})
            }
        })
    }
    fn result(&mut self, event: &Value) -> Result<ControlFlow<()>, String> {
        // A resumed session first settles what the previous process
        // left behind (a stopped background task) and reports it as
        // an empty result of zero turns. The request has not run yet.
        // Only that leading result is skipped: any later one ends the
        // turn as usual, or the run would wait forever.
        if self.resumed
            && !self.request_started
            && !self.stale_result_skipped
            && event["num_turns"] == 0
            && event["is_error"] != true
            && event["result"]
                .as_str()
                .is_none_or(|text| text.trim().is_empty())
        {
            self.stale_result_skipped = true;
            return Ok(ControlFlow::Continue(()));
        }
        if let Some(piece) = self.claude_text.consume(event) {
            self.ctx.output.append(&piece);
        }
        if event["is_error"] == true {
            return Err(event["result"]
                .as_str()
                .unwrap_or("Claude ended with an error")
                .to_owned());
        }
        // A result ends one turn, not the session: background agents
        // can trigger more turns and permission requests afterwards.
        if self.background.running() {
            self.answered = true;
            self.waiting(true);
            // Only the agent knows whether it still waits for a
            // command it left running: it is asked once per command.
            if let Some(question) = self.background.unchecked() {
                self.recheck.restart();
                self.say(&question)?;
            }
            return Ok(ControlFlow::Continue(()));
        }
        if self.implement_after_result {
            self.implement_after_result = false;
            self.send(
                json!({"type":"control_request","request_id":"orb-execute","request":{"subtype":"set_permission_mode","mode":"bypassPermissions"}}),
            )?;
            self.say("Implement the approved plan.")?;
            return Ok(ControlFlow::Continue(()));
        }
        self.completed = true;
        Ok(ControlFlow::Break(()))
    }
}

impl LineHandler for Turn {
    fn start(&mut self) -> Result<(), String> {
        self.send(
            json!({"type":"control_request","request_id":"orb-init","request":{"subtype":"initialize"}}),
        )?;
        self.say(&self.prompt)
    }

    fn line(&mut self, line: &str) -> Result<ControlFlow<()>, String> {
        let Ok(event) = serde_json::from_str::<Value>(line) else {
            return Ok(ControlFlow::Continue(()));
        };
        self.note_wakeups(&event)?;
        let output = Arc::clone(&self.ctx.output);
        output.claude_activity(&event);
        if matches!(event["type"].as_str(), Some("assistant" | "stream_event")) {
            self.request_started = true;
            self.answered = false;
            self.waiting(false);
        }
        if event["type"] != "stream_event"
            || matches!(
                event["event"]["type"].as_str(),
                Some("content_block_start" | "content_block_stop")
            )
        {
            output.publish_activities();
        }
        self.background.consume(&event);
        self.background.note_output(&event);
        // Waiting ends with the last background task, or with a
        // question: what follows is the agent's own turn.
        if !self.background.running() || event["type"] == "control_request" {
            self.waiting(false);
        } else if event["type"] == "system" {
            // Tasks end and start during the wait: the next question
            // is about the ones that run then.
            self.recheck.refresh(self.background.list());
        }
        if self.implement_after_result
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
            self.implement_after_result = false;
        }
        if event["type"] == "control_response" && event["response"]["subtype"] == "error" {
            return Err(format!(
                "Claude control request failed: {}",
                event["response"]["error"]
            ));
        }
        if event["type"] == "control_request" && event["request"]["subtype"] == "can_use_tool" {
            let response = self.permission(&event)?;
            self.send(
                json!({"type":"control_response","response":{"subtype":"success","request_id":event["request_id"],"response":response}}),
            )?;
            // Answered, by the user or by itself: the wait goes on.
            if self.answered && self.background.running() {
                self.waiting(true);
            }
        } else if event["type"] == "result" {
            return self.result(&event);
        } else if let Some(piece) = self.claude_text.consume(&event) {
            output.append(&piece);
        }
        Ok(ControlFlow::Continue(()))
    }

    fn end(self, read: Result<(), String>) {
        let result = read.and_then(|()| {
            if self.completed {
                Ok(())
            } else {
                Err(STOPPED_WITHOUT_RESULT.to_string())
            }
        });
        self.recheck.close();
        crate::interactions::finish(&self.mission_id);
        if let Err(e) = result {
            self.ctx.error.set(e);
        }
    }
}

/// How long an agent waits on the same background tasks before Orb asks it
/// again whether they are still wanted. The last delay repeats.
pub(crate) const RECHECK_DELAYS: [Duration; 3] = [
    Duration::from_secs(3600),
    Duration::from_secs(4 * 3600),
    Duration::from_secs(12 * 3600),
];

#[derive(Clone)]
pub(crate) struct BackgroundTask {
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

pub(crate) fn strings<'a>(value: &'a Value, found: &mut Vec<&'a str>) {
    match value {
        Value::String(text) => found.push(text),
        Value::Array(items) => items.iter().for_each(|item| strings(item, found)),
        Value::Object(fields) => fields.values().for_each(|item| strings(item, found)),
        _ => {}
    }
}

/// The path in "… written to: <path>/tasks/<id>.output. You will …", with the
/// separators of any system. A path may hold spaces.
pub(crate) fn output_path<'a>(text: &'a str, id: &str) -> Option<&'a str> {
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
pub(crate) fn output_tail(path: &Path) -> Option<Vec<String>> {
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
pub(crate) struct ClaudeBackground {
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

pub(crate) fn background_question(title: &str, tasks: &[BackgroundTask]) -> String {
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
pub(crate) struct Recheck(Mutex<RecheckState>, std::sync::Condvar);
#[derive(Default)]
pub(crate) struct RecheckState {
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
pub(crate) struct ClaudeText {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn claude_diagnostic_warning_does_not_fail_success_and_real_failures_remain_visible() {
        use std::os::unix::fs::PermissionsExt;
        let warning = "⚠ claude.ai connectors are disabled because ANTHROPIC_API_KEY or another auth source is set and takes precedence over your claude.ai login · Unset it to load your organization's connectors";
        for (name, result, code, expected) in [
            (
                "warning-success",
                r#"{"type":"result","is_error":false,"result":"Finished the task."}"#,
                0,
                None,
            ),
            (
                "protocol-error",
                r#"{"type":"result","is_error":true,"result":"Authentication failed"}"#,
                0,
                Some("Authentication failed"),
            ),
            (
                "process-failure",
                r#"{"type":"result","is_error":false,"result":"Partial work."}"#,
                9,
                Some("Claude process failed"),
            ),
            (
                "missing-result",
                "",
                0,
                Some("Claude stopped without a final result"),
            ),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let bin = dir.path().join("claude-fixture");
            let warning = warning.replace('\'', "'\\''");
            let script = format!("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo '2.1.295 (Claude Code)'; exit; fi\nread -r init\nread -r prompt\nprintf '%s\\n' '{warning}' >&2\nprintf '%s\\n' '{result}'\nexit {code}\n");
            std::fs::write(&bin, script).unwrap();
            std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
            let id = format!("claude-diagnostic-{name}-{}", uuid_like());
            local_agents_start(StartRequest {
                id: id.clone(),
                harness: "claudecode".into(),
                bin: bin.to_string_lossy().into_owned(),
                cwd: dir.path().to_string_lossy().into_owned(),
                prompt: "Continue".into(),
                ..Default::default()
            })
            .unwrap();
            {
                let state = wait_for_terminal(&id, Duration::from_secs(5));
                {
                    assert_eq!(state.exit_code, Some(code));
                    match expected {
                        Some(message) => assert!(
                            state.error.as_deref().unwrap_or("").contains(message),
                            "{name}: {:?}",
                            state.error
                        ),
                        None => {
                            assert!(state.error.is_none(), "{:?}", state.error);
                            assert_eq!(state.text, "Finished the task.");
                        }
                    }
                    assert!(!state.text.contains("connectors are disabled"));
                }
            }
            runs().lock().unwrap().remove(&id);
        }
    }

    /// Each case feeds events in order; `expected` is what each one yields.
    #[test]
    fn claude_text_cases() {
        let stream = |event: Value| json!({"type":"stream_event","event":event});
        let delta = |text: &str| stream(json!({"delta":{"type":"text_delta","text":text}}));
        let text_block =
            || stream(json!({"type":"content_block_start","content_block":{"type":"text"}}));
        let snapshot = |id: &str, text: &str| json!({"type":"assistant","message":{"id":id,"content":[{"type":"text","text":text}]}});
        let ok_result = |text: &str| json!({"type":"result","is_error":false,"result":text});
        type Steps<'a> = Vec<(Value, Option<&'a str>)>;
        let cases: Vec<(&str, Steps)> = vec![
            (
                "a final result fills a missing stream once",
                vec![
                    (ok_result("Recovered final"), Some("Recovered final")),
                    (ok_result("Recovered final"), None),
                ],
            ),
            (
                "an error result is never text",
                vec![(
                    json!({"type":"result","is_error":true,"result":"Rate limited"}),
                    None,
                )],
            ),
            (
                "a snapshot without deltas is kept, once per message",
                vec![
                    (snapshot("a", "Final answer"), Some("Final answer")),
                    (snapshot("a", "Final answer"), None),
                    (snapshot("b", "Next answer"), Some("\n\nNext answer")),
                ],
            ),
            (
                "deltas keep tokens and messages are separated",
                vec![
                    (stream(json!({"type":"message_start"})), None),
                    (text_block(), None),
                    (delta("Bon"), Some("Bon")),
                    (delta("jour."), Some("jour.")),
                    (
                        stream(
                            json!({"type":"content_block_start","content_block":{"type":"tool_use"}}),
                        ),
                        None,
                    ),
                    (stream(json!({"type":"message_start"})), None),
                    (text_block(), None),
                    (delta(""), None),
                    (delta("La suite."), Some("\n\nLa suite.")),
                    (text_block(), None),
                    (
                        delta("```rust\nfn main() {}\n```"),
                        Some("\n\n```rust\nfn main() {}\n```"),
                    ),
                    // The snapshot of a streamed message is a duplicate.
                    (
                        json!({"type":"assistant","message":{"content":[{"type":"text","text":"duplicate"}]}}),
                        None,
                    ),
                ],
            ),
            (
                "a result after streamed text is not repeated",
                vec![
                    (delta("Streamed"), Some("Streamed")),
                    (ok_result("Streamed"), None),
                ],
            ),
        ];
        for (name, steps) in cases {
            let mut text = ClaudeText::default();
            for (index, (event, expected)) in steps.into_iter().enumerate() {
                assert_eq!(
                    text.consume(&event).as_deref(),
                    expected,
                    "{name}, event {index}"
                );
            }
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
            service_tier: None,
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
            shared_cwd_with: None,
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
        let started = Instant::now();
        start_with_options(
            StartRequest {
                service_tier: None,
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
                shared_cwd_with: None,
            },
            &[],
            None,
            &[Duration::from_millis(150)],
        )
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
            service_tier: None,
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
            shared_cwd_with: None,
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
            service_tier: None,
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
            shared_cwd_with: None,
        })
        .unwrap();
        let state = wait_for_terminal(&id, Duration::from_secs(10));
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
            local_agents_start(StartRequest {
                service_tier: None, effort: None, cyber_revision: None, cyber_access: None,
                id: id.clone(),
                harness: "claudecode".into(),
                bin: bin.to_string_lossy().into_owned(),
                cwd: dir.path().to_string_lossy().into_owned(),
                prompt: "test".into(),
                model: None,
                session_id: resume.map(Into::into),
                image_paths: vec![], shared_cwd_with: None, })
            .unwrap();
            let state = wait_for_terminal(&id, Duration::from_secs(10));
            assert!(state.done, "the run never ended (resume={resume:?})");
            let _ = local_agents_stop(id.clone());
            runs().lock().unwrap().remove(&id);
        }
    }
}
