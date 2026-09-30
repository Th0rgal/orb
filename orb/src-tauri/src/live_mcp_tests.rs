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
    let wakeup = std::env::var("ORB_MCP_LIVE_WAKEUP").as_deref() == Ok("1");
    let prompt = if wakeup {
        format!("Call sandboxed get_capabilities once, then orb-wakeups schedule_wakeup once with request_id=\"native-smoke-{}\", delay_seconds=3600, prompt=\"Reply WAKE_NATIVE_OK\", reason=\"Orb native scheduling smoke\". Report ORB_MCP_LIVE_OK, the role and mission_id from get_capabilities, and the real scheduling receipt. Do not call other tools, change files, sleep or start missions.", uuid::Uuid::new_v4())
    } else {
        "Call sandboxed get_capabilities exactly once. Report ORB_MCP_LIVE_OK, then the role and mission_id from the actual tool result. Do not call other tools, change files, or start missions.".to_string()
    };
    let workdir = config
        .parent()
        .unwrap()
        .join("local-runs")
        .join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir_all(&workdir).unwrap();
    tauri::async_runtime::block_on(async {
        let started = local_origin::local_origin_launch(
            local_agents::StartRequest {
                id: String::new(),
                harness: harness.clone(),
                bin: std::env::var("ORB_MCP_LIVE_BINARY").unwrap(),
                cwd: workdir.to_string_lossy().into_owned(),
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
                if wakeup {
                    assert!(
                        poll.activities
                            .iter()
                            .any(|a| a.label.contains("schedule_wakeup") && a.done && !a.failed),
                        "No completed native wake-up tool call"
                    );
                    let synced = crate::local_wakeups::local_wakeups_sync(connection.clone())
                        .await
                        .unwrap();
                    assert_eq!(synced["pending"], json!([]), "Local wake-up did not sync");
                    let http = reqwest::Client::new();
                    let url = format!("{}/api/control/missions/{id}", connection.api_url);
                    let mission: serde_json::Value = http
                        .get(&url)
                        .bearer_auth(&connection.token)
                        .send()
                        .await
                        .unwrap()
                        .json()
                        .await
                        .unwrap();
                    assert_eq!(mission["continuation"]["items"][0]["state"], "scheduled");
                    crate::local_wakeups::local_wakeups_cancel(
                        connection.clone(),
                        id.clone(),
                        None,
                    )
                    .await
                    .unwrap();
                    crate::local_wakeups::local_wakeups_sync(connection.clone())
                        .await
                        .unwrap();
                    let cancelled: serde_json::Value = http
                        .get(&url)
                        .bearer_auth(&connection.token)
                        .send()
                        .await
                        .unwrap()
                        .json()
                        .await
                        .unwrap();
                    assert!(cancelled["continuation"].is_null());
                    receipt(
                        &config
                            .parent()
                            .unwrap()
                            .join(format!("{harness}-wakeup-receipt.json")),
                        &json!({"mission_id":id,"harness":harness,"registered":mission["continuation"],"cancelled":true}),
                    );
                }
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

#[test]
#[ignore = "Requires a dedicated live-test mission receipt and connection; invokes the real local helper and Core"]
fn live_native_wakeup_transport() {
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
    let id = prior["mission_id"].as_str().unwrap().to_string();
    let bindings = crate::local_bindings(None, None).unwrap();
    let cwd = bindings[&id]["cwd"].as_str().unwrap();
    assert!(Path::new(cwd)
        .components()
        .any(|part| part.as_os_str() == "local-runs"));
    let mut request = local_agents::StartRequest {
        id: id.clone(),
        harness: harness.clone(),
        bin: String::new(),
        cwd: cwd.into(),
        prompt: String::new(),
        model: None,
        session_id: None,
        image_paths: vec![],
    };
    crate::local_wakeups::prepare(&mut request, &connection).unwrap();
    let command = crate::local_wakeups::command(&id).unwrap();
    let rejected_key = format!("invalid-job-{}", uuid::Uuid::new_v4());
    let invalid = std::process::Command::new(&command[0]).args(&command[1..])
        .arg("schedule_job_wakeup")
        .arg(json!({"request_id":rejected_key,"job_id":uuid::Uuid::new_v4(),"prompt":"Never run this invalid job wake-up","reason":"Reject then continue smoke"}).to_string())
        .output().unwrap();
    assert!(invalid.status.success());
    let output = std::process::Command::new(&command[0]).args(&command[1..]).arg("schedule_wakeup").arg(json!({"request_id":format!("native-transport-{}", uuid::Uuid::new_v4()),"delay_seconds":3600,"prompt":"Reply WAKE_NATIVE_OK","reason":"Native transport smoke"}).to_string()).output().unwrap();
    assert!(output.status.success(), "Local helper failed");
    assert!(String::from_utf8(output.stdout)
        .unwrap()
        .contains("pending_sync"));
    tauri::async_runtime::block_on(async {
        let synced = crate::local_wakeups::local_wakeups_sync(connection.clone())
            .await
            .unwrap();
        assert_eq!(synced["pending"].as_array().unwrap().len(), 1);
        assert_eq!(synced["pending"][0]["source"], "orb-local-rejected");
        crate::local_wakeups::local_wakeups_discard(connection.clone(), id.clone(), rejected_key)
            .await
            .unwrap();
        assert_eq!(
            crate::local_wakeups::local_wakeups_sync(connection.clone())
                .await
                .unwrap()["pending"],
            json!([])
        );
        let http = reqwest::Client::new();
        let url = format!("{}/api/control/missions/{id}", connection.api_url);
        let registered: serde_json::Value = http
            .get(&url)
            .bearer_auth(&connection.token)
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap();
        // Cancel before assertions so a failed check cannot leave a live timer.
        crate::local_wakeups::local_wakeups_cancel(connection.clone(), id.clone(), None)
            .await
            .unwrap();
        crate::local_wakeups::local_wakeups_sync(connection.clone())
            .await
            .unwrap();
        assert_eq!(registered["continuation"]["items"][0]["state"], "scheduled");
        let cancelled: serde_json::Value = http
            .get(&url)
            .bearer_auth(&connection.token)
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap();
        assert!(cancelled["continuation"].is_null());
        receipt(
            &config
                .parent()
                .unwrap()
                .join("native-transport-receipt.json"),
            &json!({"mission_id":id,"registered":registered["continuation"],"cancelled":true,"invalid_job_quarantined_and_dismissed":true}),
        );
    });
}
