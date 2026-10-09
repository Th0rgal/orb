use super::{persist_and_publish_native_session, TurnContext};
use crate::agents::{AgentResult, TerminalReason};
use crate::api::control::AgentEvent;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

pub(crate) async fn run(ctx: TurnContext<'_>) -> AgentResult {
    if !crate::backend::vibe::core_auth_configured(ctx.app_working_dir).await {
        return AgentResult::failure(
            "Connect an enabled Mistral provider in Core before starting Mistral Vibe",
            0,
        );
    }
    let Some(store) = ctx.mission_store.as_ref() else {
        return AgentResult::failure("Vibe requires durable session storage", 0);
    };
    let claim = uuid::Uuid::new_v4();
    let run = super::session_update_run();
    match store.claim_native_prompt(ctx.mission_id, "vibe", ctx.session_id, run.as_ref(), claim).await {
        Ok(true) => {},
        _ => return AgentResult::failure("Vibe has an unresolved or superseded launch; recover its native session before retrying", 0).with_terminal_reason(TerminalReason::NativeContinuityRequired),
    }
    let release =
        |bound| release_unbound_claim(store.as_ref(), ctx.mission_id, run.as_ref(), claim, bound);
    let cli = crate::api::mission_runner::get_backend_string_setting("vibe", "cli_path")
        .unwrap_or_else(|| "vibe-acp".into());
    let current_message = match ctx.extras {
        super::TurnExtras::Vibe { current_message } => current_message,
        _ => ctx.message,
    };
    let plan = crate::vibe::plan_mode(ctx.agent, current_message);
    let model = ctx.model.unwrap_or("mistral/mistral-vibe-cli-latest");
    let args = crate::vibe::args(
        &cli,
        &ctx.mission_id.to_string(),
        Some(model),
        ctx.session_id,
        ctx.message,
        plan,
        true,
    );
    let port = std::env::var("PORT").unwrap_or_else(|_| "3000".into());
    let env = std::collections::HashMap::from([
        (
            "SANDBOXED_VIBE_PROXY_URL".into(),
            format!(
                "http://{}:{port}/v1",
                ctx.workspace.host_ip_from_workspace()
            ),
        ),
        (
            "SANDBOXED_VIBE_PROXY_KEY".into(),
            std::env::var("SANDBOXED_PROXY_SECRET").unwrap_or_default(),
        ),
    ]);
    let exec = crate::workspace_exec::WorkspaceExec::new(ctx.workspace.clone());
    let cwd = crate::workspace::configured_project_dir(ctx.workspace, ctx.work_dir);
    let mut child = match exec.spawn_streaming(&cwd, "python3", &args, env).await {
        Ok(child) => child,
        Err(error) => {
            if error
                .downcast_ref::<crate::workspace_exec::ConfirmedNoLaunch>()
                .is_some()
            {
                let _ = store
                    .release_native_prompt_no_launch(ctx.mission_id, "vibe", run.as_ref(), claim)
                    .await;
            }
            return AgentResult::failure(format!("Cannot start Vibe: {error}"), 0);
        }
    };
    let mut stdin = child.stdin.take();
    let prompt = format!("{}\n", serde_json::json!({"prompt":ctx.message}));
    if let Some(input) = stdin.as_mut() {
        if input.write_all(prompt.as_bytes()).await.is_err() {
            stop(&mut child).await;
            release(false).await;
            return AgentResult::failure("Cannot deliver Vibe prompt", 0);
        }
    }
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let stderr = child.stderr.take().unwrap();
    let drain = tokio::spawn(async move {
        let mut reader = BufReader::new(stderr);
        let _ = tokio::io::copy(&mut reader, &mut tokio::io::sink()).await;
    });
    let mut stream = crate::vibe::Stream {
        session: ctx.session_id.map(str::to_string),
        ..Default::default()
    };
    let mut bound = false;
    loop {
        let line = tokio::select! {
            _ = ctx.cancel.cancelled() => {
                finish_thinking(&ctx.events_tx, ctx.mission_id, &mut stream);
                stop(&mut child).await; drain.abort();
                release(bound).await;
                return AgentResult::failure(stream.text, 0).with_terminal_reason(TerminalReason::Cancelled);
            },
            line = lines.next_line() => line,
        };
        let line = match line {
            Ok(Some(line)) => line,
            Ok(None) => break,
            Err(_) => {
                stream.error = Some("Cannot read Vibe output".into());
                break;
            }
        };
        let Ok(event) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        let old_text = stream.text.len();
        let old_thinking = stream.thinking.len();
        let tools = stream.feed(&event);
        if stream.error.is_some() {
            stop(&mut child).await;
            break;
        }
        if !bound && event["type"] == "session" {
            if let Some(id) = &stream.session {
                if let Err(result) = persist_and_publish_native_session(
                    Some(store),
                    ctx.mission_id,
                    "vibe",
                    id,
                    &ctx.events_tx,
                )
                .await
                {
                    stop(&mut child).await;
                    drain.abort();
                    release(false).await;
                    return *result;
                }
                // After identity persistence, a partial acknowledgement is ambiguous:
                // retain the session/claim so a retry resumes the same conversation.
                bound = true;
                if let Some(mut input) = stdin.take() {
                    if input.write_all(b"{\"continue\":true}\n").await.is_err() {
                        stream.error = Some("Vibe identity acknowledgement failed".into());
                        stop(&mut child).await;
                        break;
                    }
                }
            }
        }
        if stream.text.len() != old_text {
            let _ = ctx.events_tx.send(AgentEvent::TextDelta {
                content: stream.text.clone(),
                mission_id: Some(ctx.mission_id),
            });
        }
        if stream.thinking.len() != old_thinking {
            let _ = ctx.events_tx.send(AgentEvent::Thinking {
                content: stream.thinking.clone(),
                done: false,
                mission_id: Some(ctx.mission_id),
            });
        }
        for tool in tools {
            let id = tool["toolCallId"].as_str().unwrap_or_default().to_string();
            let name = tool["name"].as_str().unwrap_or("Vibe tool").to_string();
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
                    result: tool,
                    mission_id: Some(ctx.mission_id),
                }
            };
            let _ = ctx.events_tx.send(event);
        }
    }
    finish_thinking(&ctx.events_tx, ctx.mission_id, &mut stream);
    let status = tokio::select! {
        _ = ctx.cancel.cancelled() => {
            stop(&mut child).await; drain.abort();
            release(bound).await;
            return AgentResult::failure(stream.text, 0).with_terminal_reason(TerminalReason::Cancelled);
        },
        status = child.wait() => status,
    };
    drain.abort();
    release(bound).await;
    match stream.finish() {
        Ok(()) if status.is_ok_and(|status| status.success()) => {
            AgentResult::success(stream.text, 0)
                .with_model(model)
                .with_terminal_reason(TerminalReason::TurnComplete)
        }
        result => AgentResult::failure(
            result.err().unwrap_or_else(|| "Vibe process failed".into()),
            0,
        )
        .with_terminal_reason(if bound {
            TerminalReason::NativeContinuityRequired
        } else {
            TerminalReason::LlmError
        }),
    }
}

async fn release_unbound_claim(
    store: &dyn crate::api::mission_store::MissionStore,
    mission_id: uuid::Uuid,
    run: Option<&crate::api::mission_store::SessionUpdateRun>,
    claim: uuid::Uuid,
    bound: bool,
) {
    if !bound {
        if let Err(error) = store
            .release_native_prompt_no_launch(mission_id, "vibe", run, claim)
            .await
        {
            tracing::warn!(%mission_id, %error, "Could not release Vibe pre-prompt claim");
        }
    }
}

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

fn finish_thinking(
    events_tx: &tokio::sync::broadcast::Sender<AgentEvent>,
    mission_id: uuid::Uuid,
    stream: &mut crate::vibe::Stream,
) {
    if !stream.thinking.is_empty() {
        let _ = events_tx.send(AgentEvent::Thinking {
            content: std::mem::take(&mut stream.thinking),
            done: true,
            mission_id: Some(mission_id),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn missing_core_credentials_rejects_launch_before_claiming_a_prompt() {
        use crate::api::mission_store::{InMemoryMissionStore, MissionStore};
        use std::sync::Arc;

        let directory = tempfile::tempdir().unwrap();
        let workspace = crate::workspace::Workspace::default_host(directory.path().into());
        let store = Arc::new(InMemoryMissionStore::new());
        let mission = store
            .create_mission(None, None, None, None, None, Some("vibe"), None)
            .await
            .unwrap();
        let (events_tx, _) = tokio::sync::broadcast::channel(4);
        let result = run(TurnContext {
            mission_store: Some(store.clone()),
            workspace: &workspace,
            work_dir: directory.path(),
            message: "Do not execute this prompt",
            model: None,
            model_effort: None,
            fast_mode: false,
            agent: None,
            mission_id: mission.id,
            events_tx,
            cancel: tokio_util::sync::CancellationToken::new(),
            app_working_dir: directory.path(),
            session_id: None,
            is_continuation: false,
            extras: super::super::TurnExtras::None,
        })
        .await;
        assert!(!result.success);
        assert!(result
            .output
            .contains("Connect an enabled Mistral provider"));
        assert!(store
            .claim_native_prompt(mission.id, "vibe", None, None, uuid::Uuid::new_v4())
            .await
            .unwrap());
    }

    #[tokio::test]
    async fn vibe_startup_failure_releases_only_an_unbound_claim() {
        use crate::api::mission_store::{
            FileMissionStore, InMemoryMissionStore, MissionStore, SqliteMissionStore,
        };
        use std::sync::Arc;
        for kind in ["memory", "file", "sqlite"] {
            let dir = tempfile::tempdir().unwrap();
            let store: Arc<dyn MissionStore> = match kind {
                "file" => Arc::new(
                    FileMissionStore::new(dir.path().into(), "vibe")
                        .await
                        .unwrap(),
                ),
                "sqlite" => Arc::new(
                    SqliteMissionStore::new(dir.path().into(), "vibe")
                        .await
                        .unwrap(),
                ),
                _ => Arc::new(InMemoryMissionStore::new()),
            };
            let mission = store
                .create_mission(None, None, None, None, None, Some("vibe"), None)
                .await
                .unwrap();
            let first = uuid::Uuid::new_v4();
            assert!(store
                .claim_native_prompt(mission.id, "vibe", None, None, first)
                .await
                .unwrap());
            release_unbound_claim(store.as_ref(), mission.id, None, first, false).await;
            let retry = uuid::Uuid::new_v4();
            assert!(
                store
                    .claim_native_prompt(mission.id, "vibe", None, None, retry)
                    .await
                    .unwrap(),
                "{kind}: startup can retry"
            );
            release_unbound_claim(store.as_ref(), mission.id, None, retry, true).await;
            assert!(
                !store
                    .claim_native_prompt(mission.id, "vibe", None, None, uuid::Uuid::new_v4())
                    .await
                    .unwrap(),
                "{kind}: admitted prompt cannot be duplicated"
            );
        }
    }

    // Intermediate snapshots must be cumulative; completion is the durable row.
    #[test]
    fn thinking_snapshot_contains_all_chunks() {
        let mut stream = crate::vibe::Stream::default();
        stream.feed(&serde_json::json!({"type":"session","session_id":"native"}));
        for chunk in ["first ", "second"] {
            stream.feed(&serde_json::json!({"type":"update","update":{"sessionUpdate":"agent_thought_chunk","content":{"text":chunk}}}));
        }
        let (events, mut receiver) = tokio::sync::broadcast::channel(4);
        let mission_id = uuid::Uuid::new_v4();
        finish_thinking(&events, mission_id, &mut stream);
        assert!(
            matches!(receiver.try_recv().unwrap(), AgentEvent::Thinking { content, done: true, mission_id: Some(id) } if content == "first second" && id == mission_id)
        );
        finish_thinking(&events, mission_id, &mut stream);
        assert!(
            receiver.try_recv().is_err(),
            "Only one terminal snapshot should persist"
        );
    }
}
