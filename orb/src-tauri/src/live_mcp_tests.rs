//! Opt-in live regression through Orb's real native launch and polling path.
//! No mocked Core or CLI. Credentials and receipts stay in private files.
use crate::{local_agents, local_origin, run_recovery::Connection};
use serde_json::json;
use std::{
    os::unix::fs::OpenOptionsExt,
    path::Path,
    time::{Duration, Instant},
};

fn receipt(path: &Path, value: &serde_json::Value) {
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .unwrap();
    file.write_all(serde_json::to_string_pretty(value).unwrap().as_bytes())
        .unwrap();
}

struct Stop(String);
impl Drop for Stop {
    fn drop(&mut self) {
        let _ = local_agents::local_agents_stop(self.0.clone());
    }
}

#[test]
#[ignore = "Requires explicit live-test connection, harness and binary; launches one dedicated mission"]
fn live_native_mcp_roundtrip() {
    let config = std::path::PathBuf::from(
        std::env::var("ORB_MCP_LIVE_CONNECTION_FILE").expect("private connection file required"),
    );
    let connection: Connection = serde_json::from_slice(&std::fs::read(&config).unwrap()).unwrap();
    let harness = std::env::var("ORB_MCP_LIVE_HARNESS").unwrap();
    assert!(["codex", "claudecode", "opencode", "grok"].contains(&harness.as_str()));
    let output = config
        .parent()
        .unwrap()
        .join(format!("{harness}-receipt.json"));
    let prompt = "Call sandboxed get_capabilities exactly once. Report ORB_MCP_LIVE_OK, then the role and mission_id from the actual tool result. Do not call other tools, change files, or start missions.".to_string();
    tauri::async_runtime::block_on(async {
        let started = local_origin::local_origin_launch(
            local_agents::StartRequest {
                id: String::new(),
                harness: harness.clone(),
                bin: std::env::var("ORB_MCP_LIVE_BINARY").unwrap(),
                cwd: String::new(),
                prompt: prompt.clone(),
                model: std::env::var("ORB_MCP_LIVE_MODEL")
                    .ok()
                    .filter(|s| !s.is_empty()),
                session_id: None,
                image_paths: vec![],
            },
            local_origin::Draft {
                key: uuid::Uuid::new_v4().to_string(),
                title: format!("Orb MCP live validation: {harness}"),
                project: "unified-mcp-validation".into(),
                prompt,
                tags: vec![],
            },
            connection.clone(),
        )
        .await
        .expect("Orb launch failed before creating a receipt");
        receipt(&output, &started);
        assert_ne!(
            started["status"], "failed",
            "Launch failed; inspect private receipt"
        );
        let id = started["id"].as_str().unwrap().to_string();
        let _stop = Stop(id.clone());
        let deadline = Instant::now() + Duration::from_secs(150);
        loop {
            let poll = local_agents::local_agents_poll(id.clone()).unwrap();
            receipt(
                &output,
                &json!({"mission_id":id,"harness":harness,"poll":poll}),
            );
            if poll.done {
                assert!(
                    poll.error.is_none(),
                    "Native failure; inspect private receipt"
                );
                assert!(
                    poll.exit_code.is_none_or(|code| code == 0),
                    "Native CLI failed"
                );
                assert!(
                    poll.text.contains("ORB_MCP_LIVE_OK")
                        && poll.text.contains("executor")
                        && poll.text.contains(&id),
                    "Missing live MCP identity in response"
                );
                assert!(
                    poll.activities
                        .iter()
                        .any(|a| a.label.contains("get_capabilities") && a.done && !a.failed),
                    "No completed native MCP tool activity"
                );
                // Let the native-origin outbox publish its terminal snapshot.
                tokio::time::sleep(Duration::from_secs(3)).await;
                println!("Orb native MCP validated: {harness} {id}");
                break;
            }
            assert!(
                Instant::now() < deadline,
                "Native CLI timed out; inspect private receipt"
            );
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    });
}

#[test]
#[ignore = "Requires a completed dedicated live-test receipt; resumes only that test mission"]
fn live_native_mcp_resume() {
    let config = std::path::PathBuf::from(std::env::var("ORB_MCP_LIVE_CONNECTION_FILE").unwrap());
    let connection: Connection = serde_json::from_slice(&std::fs::read(&config).unwrap()).unwrap();
    let harness = std::env::var("ORB_MCP_LIVE_HARNESS").unwrap();
    let prior: serde_json::Value = serde_json::from_slice(
        &std::fs::read(
            config
                .parent()
                .unwrap()
                .join(format!("{harness}-receipt.json")),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(prior["harness"], harness);
    assert_eq!(prior["poll"]["done"], true);
    let id = prior["mission_id"].as_str().unwrap().to_string();
    let session = prior["poll"]["session_id"].as_str().unwrap().to_string();
    let bindings = crate::local_bindings(None, None).unwrap();
    let binding = &bindings[&id];
    let cwd = binding["cwd"].as_str().unwrap();
    // Never allow this opt-in test to resume an ordinary user mission.
    assert!(std::path::Path::new(cwd)
        .components()
        .any(|part| part.as_os_str() == "local-runs"));
    assert_eq!(binding["harness"], harness);
    let output = config
        .parent()
        .unwrap()
        .join(format!("{harness}-resume-receipt.json"));
    tauri::async_runtime::block_on(async {
        crate::run_recovery::local_run_launch(local_agents::StartRequest {
            id: id.clone(), harness: harness.clone(), bin: binding["bin"].as_str().unwrap().into(),
            cwd: cwd.into(), session_id: Some(session.clone()), model: binding["model"].as_str().map(str::to_string),
            prompt: "Call sandboxed get_capabilities once again. Report the marker from your previous answer, followed by the role and mission_id from the new tool result. Do not change files or start missions.".into(), image_paths: vec![],
        }, connection).await.expect("Orb resume failed");
        let _stop = Stop(id.clone());
        let deadline = Instant::now() + Duration::from_secs(150);
        loop {
            let poll = local_agents::local_agents_poll(id.clone()).unwrap();
            receipt(
                &output,
                &json!({"mission_id":id,"harness":harness,"poll":poll}),
            );
            if poll.done {
                assert!(
                    poll.error.is_none() && poll.exit_code.is_none_or(|c| c == 0),
                    "Native resume failed; inspect private receipt"
                );
                assert!(poll.resumed);
                assert_eq!(
                    poll.session_id.as_deref(),
                    Some(session.as_str()),
                    "Native session changed"
                );
                assert!(
                    poll.text.contains("ORB_MCP_LIVE_OK")
                        && poll.text.contains("executor")
                        && poll.text.contains(&id),
                    "Native history or MCP identity missing"
                );
                assert!(poll
                    .activities
                    .iter()
                    .any(|a| a.label.contains("get_capabilities") && a.done && !a.failed));
                tokio::time::sleep(Duration::from_secs(3)).await;
                println!("Orb native MCP resume validated: {harness} {id}");
                break;
            }
            assert!(Instant::now() < deadline, "Native resume timed out");
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    });
}
