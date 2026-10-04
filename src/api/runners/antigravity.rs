//! Native OAuth belongs to agy and the execution user, never the provider proxy.
use super::{persist_and_publish_native_session, TurnContext};
use crate::agents::{AgentResult, TerminalReason};
use crate::antigravity::Stream;
use crate::api::control::AgentEvent;
use tokio::io::{AsyncBufReadExt, BufReader};

pub(crate) async fn run(ctx: TurnContext<'_>) -> AgentResult {
    if ctx.is_continuation && ctx.session_id.is_none() {
        return AgentResult::failure(
            "Antigravity continuation requires its original conversation ID",
            0,
        )
        .with_terminal_reason(TerminalReason::NativeContinuityRequired);
    }
    let cli = crate::api::mission_runner::get_backend_string_setting("antigravity", "cli_path")
        .unwrap_or_else(|| "agy".into());
    let args = crate::antigravity::args(ctx.model, ctx.session_id, ctx.message);
    let exec = crate::workspace_exec::WorkspaceExec::new(ctx.workspace.clone());
    let cwd = crate::workspace::configured_project_dir(ctx.workspace, ctx.work_dir);
    let mut child = match exec
        .spawn_streaming(&cwd, &cli, &args, Default::default())
        .await
    {
        Ok(child) => child,
        Err(e) => return AgentResult::failure(format!("Cannot start Antigravity: {e}"), 0),
    };
    drop(child.stdin.take());
    let stderr = child.stderr.take().unwrap();
    let drain = tokio::spawn(async move {
        let mut lines = BufReader::new(stderr).lines();
        // Drain stderr without retaining OAuth URLs or other account diagnostics.
        while let Ok(Some(_)) = lines.next_line().await {}
    });
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let mut stream = Stream::default();
    let mut bound = false;
    loop {
        let line = tokio::select! {
            _ = ctx.cancel.cancelled() => {
                stop(&mut child).await;
                drain.abort();
                return AgentResult::failure(stream.text, 0).with_terminal_reason(TerminalReason::Cancelled);
            }
            line = lines.next_line() => line,
        };
        let line = match line {
            Ok(Some(line)) => line,
            Ok(None) => break,
            Err(_) => {
                stream.error = Some("Cannot read Antigravity event stream".into());
                break;
            }
        };
        let Ok(value) = serde_json::from_str(&line) else {
            continue;
        };
        let tools = stream.feed(&value);
        if stream.error.is_some() {
            stop(&mut child).await;
            break;
        }
        if !bound {
            if let Some(id) = &stream.session {
                if ctx.session_id.is_some_and(|expected| expected != id) {
                    stop(&mut child).await;
                    drain.abort();
                    return AgentResult::failure("Antigravity resumed a different conversation", 0)
                        .with_terminal_reason(TerminalReason::NativeContinuityRequired);
                }
                if let Err(result) = persist_and_publish_native_session(
                    ctx.mission_store.as_ref(),
                    ctx.mission_id,
                    "antigravity",
                    id,
                    &ctx.events_tx,
                )
                .await
                {
                    stop(&mut child).await;
                    drain.abort();
                    return *result;
                }
                bound = true;
            }
        }
        let _ = ctx.events_tx.send(AgentEvent::TextDelta {
            content: stream.text.clone(),
            mission_id: Some(ctx.mission_id),
        });
        for tool in tools {
            let id = tool["toolCallId"].as_str().unwrap_or_default().to_string();
            let name = tool["name"].as_str().unwrap_or("tool").to_string();
            let event = if tool["type"] == "tool_call" {
                AgentEvent::ToolCall {
                    tool_call_id: id,
                    name,
                    args: tool["rawInput"].clone(),
                    mission_id: Some(ctx.mission_id),
                }
            } else {
                AgentEvent::ToolResult {
                    tool_call_id: id,
                    name,
                    result: tool["output"].clone(),
                    mission_id: Some(ctx.mission_id),
                }
            };
            let _ = ctx.events_tx.send(event);
        }
    }
    let status = tokio::select! {
        _ = ctx.cancel.cancelled() => { stop(&mut child).await; drain.abort(); return AgentResult::failure(stream.text, 0).with_terminal_reason(TerminalReason::Cancelled); }
        status = child.wait() => status,
    };
    drain.abort();
    let mut result = match stream.finish() {
        Ok(()) if status.is_ok_and(|s| s.success()) => {
            AgentResult::success(stream.text, 0).with_terminal_reason(TerminalReason::TurnComplete)
        }
        Ok(()) => AgentResult::failure("Antigravity process failed after its result", 0),
        Err(error) => AgentResult::failure(error, 0)
            .with_terminal_reason(TerminalReason::NativeContinuityRequired),
    };
    result = result.with_usage(crate::cost::TokenUsage {
        input_tokens: stream.input_tokens,
        output_tokens: stream.output_tokens,
        cache_creation_input_tokens: None,
        cache_read_input_tokens: Some(stream.cache_read_tokens),
    });
    if let Some(model) = ctx.model {
        result = result.with_model(model.to_string());
    }
    result
}

/// Let the scoped MCP supervisor terminate its child group and restore config.
async fn stop(child: &mut tokio::process::Child) {
    #[cfg(unix)]
    if let Some(pid) = child.id() {
        unsafe {
            libc::kill(pid as i32, libc::SIGTERM);
        }
    }
    if tokio::time::timeout(std::time::Duration::from_secs(7), child.wait())
        .await
        .is_err()
    {
        let _ = child.kill().await;
    }
}
