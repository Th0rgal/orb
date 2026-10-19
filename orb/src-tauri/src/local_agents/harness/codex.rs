//! Codex `app-server`: JSON-RPC over stdio. One process per turn; the
//! thread is resumed by id, and goals and plans continue across turns.

use super::*;
use std::io::{BufRead, BufReader, Write};

pub(crate) fn speed_options(model: &str, account: &Value, catalog: &Value) -> Value {
    let subscription = account.pointer("/account/type").and_then(Value::as_str) == Some("chatgpt");
    let plan = account.pointer("/account/planType").and_then(Value::as_str);
    let tiers = [crate::codex_speed::Tier::Standard, crate::codex_speed::Tier::Fast, crate::codex_speed::Tier::Ultrafast].map(|tier| {
        let available = tier == crate::codex_speed::Tier::Standard || (subscription && tier.supports_model(model)
            && (tier != crate::codex_speed::Tier::Ultrafast || crate::codex_speed::eligible_ultrafast_plan(plan))
            && crate::codex_speed::catalog_advertises(catalog, model, tier));
        json!({"id":tier,"available":available,"reason":if available { None } else { Some("The signed-in Codex subscription does not advertise this speed for this model.") }})
    });
    json!({"tiers":tiers})
}

/// Ask a short-lived app-server which speeds this account may use.
pub(crate) fn probe_speed_options(bin: &str, model: &str) -> Result<Value, String> {
    let mut child = Command::new(bin)
        .arg("app-server")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| e.to_string())?;
    let mut stdin = child.stdin.take().ok_or("Codex stdin unavailable")?;
    let mut reader = BufReader::new(child.stdout.take().ok_or("Codex stdout unavailable")?);
    let child = Arc::new(Mutex::new(child));
    let watchdog = Arc::clone(&child);
    let (finished, waiting) = std::sync::mpsc::channel::<()>();
    thread::spawn(move || {
        if waiting.recv_timeout(Duration::from_secs(20)).is_err() {
            let _ = crate::sync_util::lock(&watchdog).kill();
        }
    });
    let result = (|| {
        rpc(
            &mut stdin,
            &mut reader,
            "initialize",
            json!({"clientInfo":{"name":"orb","version":"0.1.0"},"capabilities":{"experimentalApi":true}}),
        )?;
        write_line(&mut stdin, &json!({"method":"initialized"}).to_string())?;
        let account = rpc(
            &mut stdin,
            &mut reader,
            "account/read",
            json!({"refreshToken":false}),
        )?;
        let catalog = rpc(
            &mut stdin,
            &mut reader,
            "model/list",
            json!({"includeHidden":true,"limit":100}),
        )?;
        Ok(speed_options(model, &account, &catalog))
    })();
    let _ = finished.send(());
    reap(&mut crate::sync_util::lock(&child), "", "codex speed probe");
    result
}

/// What one Codex turn asks for.
#[derive(Clone, Copy)]
pub(crate) struct Turn<'a> {
    pub(crate) prompt: &'a str,
    pub(crate) image_paths: &'a [String],
    pub(crate) model: Option<&'a str>,
    pub(crate) cyber_access: crate::cyber_access::Mode,
    pub(crate) service_tier: crate::codex_speed::Tier,
    pub(crate) cwd: &'a str,
    pub(crate) resume: Option<&'a str>,
}

pub(crate) fn spawn(
    request: &StartRequest,
    ctx: &RunCtx,
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
    if request
        .service_tier
        .is_some_and(|tier| tier != crate::codex_speed::Tier::Standard)
    {
        command.arg("-c").arg(
            if request.service_tier == Some(crate::codex_speed::Tier::Ultrafast) {
                "features.ultrafast_mode=true"
            } else {
                "features.fast_mode=true"
            },
        );
    }
    let mut child = command
        .current_dir(&request.cwd)
        .arg("-c")
        .arg(crate::harness_attribution::CODEX_CONFIG_OVERRIDE)
        .arg("app-server")
        .args(["--enable", "goals"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn_logged(ctx)
        .map_err(|e| format!("failed to start Codex: {e}"))?;
    let mut stdin = child.stdin.take().ok_or("codex stdin missing")?;
    let stdout = child.stdout.take().ok_or("codex stdout missing")?;
    if let Some(stderr) = child.stderr.take() {
        // Diagnostics are not turn outcomes. In particular app-server shutdown
        // can emit rollout warnings after a successful turn.
        drain_stderr(stderr, ctx, StderrPolicy::CodexLog);
    }
    let request = request.clone();
    let ctx = ctx.clone();
    let guard = ctx.output.reader();
    thread::spawn(move || {
        let _guard = guard;
        let mission_id = crate::interactions::session(&request.id);
        let mut reader = BufReader::new(stdout);
        let resume = request.session_id.as_deref().filter(|s| !s.is_empty());
        let turn = Turn {
            prompt: &request.prompt,
            image_paths: &request.image_paths,
            model: request.model.as_deref(),
            cyber_access: request.cyber_access.unwrap_or_default(),
            service_tier: request.service_tier.unwrap_or_default(),
            cwd: &request.cwd,
            resume,
        };
        let result = drive_codex(
            &mut stdin,
            &mut reader,
            turn,
            &ctx.output,
            &mut |id| ctx.bind_session(id),
            &mission_id,
        );
        crate::interactions::finish(&mission_id);
        if let Err(message) = result {
            crate::orb_log!(
                error,
                "codex_run_failed",
                mission = ctx.mission,
                harness = ctx.harness,
                extra = json!({"error": message.chars().take(1000).collect::<String>()})
            );
            ctx.error.set(if busy_thread(&message) {
                format!("Codex thread is busy: {message}")
            } else {
                message
            });
        }
        // The exit watcher marks the run done once app-server is reaped.
    });
    Ok(child)
}

pub(crate) fn busy_thread(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("busy")
        || lower.contains("already")
        || lower.contains("in progress")
        || lower.contains("in use")
}

// Native Codex caps goals at 4,000 characters. Keep oversized instructions
// verbatim in a durable file rather than silently truncating their requirements.
pub(crate) fn codex_goal_objective(objective: &str, cwd: &str) -> Result<String, String> {
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

pub(crate) fn drive_codex(
    stdin: &mut impl Write,
    reader: &mut impl BufRead,
    turn: Turn<'_>,
    text: &Output,
    bind_session: &mut dyn FnMut(String),
    mission_id: &crate::interactions::Session,
) -> Result<(), String> {
    let Turn {
        prompt,
        image_paths,
        model,
        cyber_access,
        service_tier,
        cwd,
        resume,
    } = turn;
    rpc(
        stdin,
        reader,
        "initialize",
        json!({
            "clientInfo": {"name": "orb", "version": "0.1.0"},
            "capabilities": {"experimentalApi": true}
        }),
    )?;
    // The notification has no reply; a broken pipe surfaces on the next RPC.
    if let Err(error) = write_line(stdin, &json!({"method": "initialized"}).to_string()) {
        crate::orb_log!(
            warn,
            "codex_rpc_failed",
            mission = mission_id.mission,
            harness = "codex",
            extra = json!({"method": "initialized", "error": error})
        );
    }
    if service_tier != crate::codex_speed::Tier::Standard {
        let model = model.ok_or("Choose an explicit model before enabling accelerated speed.")?;
        let account = rpc(stdin, reader, "account/read", json!({"refreshToken":false}))?;
        let catalog = rpc(
            stdin,
            reader,
            "model/list",
            json!({"includeHidden":true,"limit":100}),
        )?;
        let available = speed_options(model, &account, &catalog);
        if !available["tiers"].as_array().is_some_and(|options| {
            options
                .iter()
                .any(|option| option["id"] == json!(service_tier) && option["available"] == true)
        }) {
            return Err("unsupported_service_tier: the signed-in subscription cannot use the selected speed. No thread or turn was started.".into());
        }
    }
    let params = json!({
        "model": model,
        "serviceTier": service_tier.wire(),
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
    bind_session(thread_id.clone());
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
        rpc_collect(
            stdin,
            reader,
            "turn/start",
            json!({
                "threadId": thread_id,
                "cyberAccessProgram": cyber_program,
                "serviceTier": service_tier.wire(),
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
        if matches!(
            method,
            "item/started" | "item/completed" | "turn/plan/updated"
        ) {
            text.publish_activities();
        }
        items.apply(&value, text);
    }
    Ok(())
}

pub(crate) fn rpc(
    stdin: &mut impl Write,
    reader: &mut impl BufRead,
    method: &str,
    params: Value,
) -> Result<Value, String> {
    rpc_collect(stdin, reader, method, params, &mut Vec::new())
}

pub(crate) fn rpc_collect(
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
            crate::orb_log!(
                warn,
                "codex_rpc_failed",
                harness = "codex",
                extra = json!({"method": method, "error": "stream closed"})
            );
            return Err(format!("{method} closed the stream"));
        }
        let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        if value.get("id").and_then(Value::as_str) == Some(id.as_str())
            && value.get("method").is_none()
        {
            if let Some(error) = value.get("error") {
                let message = error["message"].as_str().unwrap_or("Codex RPC failed");
                crate::orb_log!(
                    warn,
                    "codex_rpc_failed",
                    harness = "codex",
                    extra = json!({"method": method, "code": error["code"], "error": message})
                );
                return Err(format!("{method}: {message}"));
            }
            return Ok(value.get("result").cloned().unwrap_or(Value::Null));
        }
        pending.push(value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_speed_requires_account_capability_and_an_unambiguous_plan() {
        use serde_json::json;
        let catalog = json!({"data":[{"id":"gpt-6.1-sol","serviceTiers":[{"id":"priority"},{"id":"ultrafast"}]}]});
        let supports = |plan: &str| {
            super::speed_options(
                "gpt-6.1-sol",
                &json!({"account":{"type":"chatgpt","planType":plan}}),
                &catalog,
            )
        };
        assert_eq!(supports("promax")["tiers"][2]["available"], true);
        assert_eq!(supports("pro")["tiers"][2]["available"], false);
        assert_eq!(supports("pro")["tiers"][1]["available"], true);
        assert_eq!(
            super::speed_options(
                "gpt-6.1-sol",
                &json!({"account":{"type":"apiKey"}}),
                &catalog
            )["tiers"][1]["available"],
            false
        );
        assert_eq!(
            super::speed_options(
                "gpt-6-luna",
                &json!({"account":{"type":"chatgpt","planType":"promax"}}),
                &catalog
            )["tiers"][2]["available"],
            false
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
                Turn {
                    prompt,
                    image_paths: &[],
                    model: Some("gpt-6.1-sol"),
                    cyber_access: crate::cyber_access::Mode::Standard,
                    service_tier: crate::codex_speed::Tier::Standard,
                    cwd: "/tmp",
                    resume: None,
                },
                &Output::default(),
                &mut |_| {},
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
        let session = Slot::default();
        let error = drive_codex(
            &mut sent,
            &mut std::io::Cursor::new(input),
            Turn {
                prompt: "Reply OK",
                image_paths: &[],
                model: Some("gpt-6.1-sol"),
                cyber_access: crate::cyber_access::Mode::Daybreak,
                service_tier: crate::codex_speed::Tier::Standard,
                cwd: "/tmp",
                resume: None,
            },
            &Output::default(),
            &mut |id| session.set(id),
            &crate::interactions::begin("cyber-denial-test"),
        )
        .unwrap_err();
        assert!(error.contains("access_program_not_enabled"));
        assert_eq!(session.get().as_deref(), Some("thread"));
        let sent = String::from_utf8(sent).unwrap();
        assert!(!sent.contains("turn/start"));
        assert!(!sent.contains("gpt-daybreak-"));
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
            Turn {
                prompt: "prompt",
                image_paths: &["/tmp/pasted.png".into()],
                model: None,
                cyber_access: crate::cyber_access::Mode::Automatic,
                service_tier: crate::codex_speed::Tier::Standard,
                cwd: "/tmp",
                resume: None,
            },
            &output,
            &mut |_| {},
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
            Turn {
                prompt: "/goal Work",
                image_paths: &[],
                model: None,
                cyber_access: crate::cyber_access::Mode::Automatic,
                service_tier: crate::codex_speed::Tier::Standard,
                cwd: "/tmp",
                resume: None,
            },
            &Output::default(),
            &mut |_| {},
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
            Turn {
                prompt: "/goal Finish the work",
                image_paths: &[],
                model: None,
                cyber_access: crate::cyber_access::Mode::Automatic,
                service_tier: crate::codex_speed::Tier::Standard,
                cwd: "/tmp",
                resume: None,
            },
            &output,
            &mut |_| {},
            &crate::interactions::begin("native-goal-test"),
        )
        .unwrap();
        let sent = String::from_utf8(requests).unwrap();
        assert!(sent.contains("thread/goal/set"));
        assert!(sent.contains("Finish the work"));
        assert!(!sent.contains("turn/start"));
        assert_eq!(output.snapshot(), "Continued");
    }
}
