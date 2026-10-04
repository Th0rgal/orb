//! Native OAuth belongs to agy and the execution user, never the provider proxy.
use super::{persist_and_publish_native_session, TurnContext};
use crate::agents::{AgentResult, TerminalReason};
use crate::antigravity::Stream;
use crate::api::control::AgentEvent;
use tokio::io::{AsyncBufReadExt, BufReader};

async fn fresh_transfer_prompt(ctx: &TurnContext<'_>) -> Result<Option<String>, String> {
    let Some(store) = ctx.mission_store.as_ref() else {
        return Ok(None);
    };
    let Some(transfer) =
        crate::api::control::machine_transfer::committed(store, ctx.mission_id).await?
    else {
        return Ok(None);
    };
    if transfer.destination != crate::api::mission_store::transfer::Machine::Core {
        return Ok(None);
    }
    let current_message = match &ctx.extras {
        super::TurnExtras::Antigravity { current_message } => *current_message,
        _ => ctx.message,
    };
    crate::api::control::machine_transfer::context(
        store,
        ctx.mission_id,
        current_message.to_string(),
        None,
    )
    .await
    .map(Some)
}

pub(crate) async fn run(ctx: TurnContext<'_>) -> AgentResult {
    let Some(store) = ctx.mission_store.as_ref() else {
        return AgentResult::failure("Antigravity requires durable native identity storage", 0);
    };
    if ctx.session_id.is_none() {
        match store
            .native_prompt_attempted(ctx.mission_id, "antigravity")
            .await
        {
            Ok(false) => {}
            Ok(true) => return AgentResult::failure(
                "Prior Antigravity attempt has no durable identity; reconcile it before retrying",
                0,
            )
            .with_terminal_reason(TerminalReason::NativeContinuityRequired),
            Err(error) => return AgentResult::failure(error, 0),
        }
    }
    let transferred_prompt = if ctx.session_id.is_none() {
        match fresh_transfer_prompt(&ctx).await {
            Ok(prompt) => prompt,
            Err(error) => return AgentResult::failure(error, 0),
        }
    } else {
        None
    };
    let prompt = transferred_prompt.as_deref().unwrap_or(ctx.message);
    if let Err(error) = crate::antigravity::validate_prompt(prompt) {
        return AgentResult::failure(error, 0);
    }
    let cli = crate::api::mission_runner::get_backend_string_setting("antigravity", "cli_path")
        .unwrap_or_else(|| "agy".into());
    let args = crate::antigravity::args(ctx.model, ctx.session_id, prompt);
    let exec = crate::workspace_exec::WorkspaceExec::new(ctx.workspace.clone());
    let cwd = crate::workspace::configured_project_dir(ctx.workspace, ctx.work_dir);
    let claim = uuid::Uuid::new_v4();
    let run = super::session_update_run();
    match store
        .claim_native_prompt(
            ctx.mission_id,
            "antigravity",
            ctx.session_id,
            run.as_ref(),
            claim,
        )
        .await
    {
        Ok(true) => {}
        Ok(false) => {
            return AgentResult::failure(
                "Antigravity native launch was superseded or has an unresolved prior attempt",
                0,
            )
            .with_terminal_reason(TerminalReason::NativeContinuityRequired)
        }
        Err(error) => return AgentResult::failure(error, 0),
    }
    let mut child = match exec
        .spawn_streaming(&cwd, &cli, &args, Default::default())
        .await
    {
        Ok(child) => child,
        Err(e) => {
            if e.downcast_ref::<crate::workspace_exec::ConfirmedNoLaunch>()
                .is_some()
            {
                let _ = store
                    .release_native_prompt_no_launch(
                        ctx.mission_id,
                        "antigravity",
                        run.as_ref(),
                        claim,
                    )
                    .await;
            }
            return AgentResult::failure(format!("Cannot start Antigravity: {e}"), 0);
        }
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
                    result: tool.clone(),
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
