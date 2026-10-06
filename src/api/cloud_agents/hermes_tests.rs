use super::*;
use crate::api::mission_store::SqliteMissionStore;
use axum::{
    routing::{get, post},
    Router,
};
use std::sync::atomic::{AtomicUsize, Ordering};

#[tokio::test]
async fn lost_acceptance_replays_same_turn_and_recovery_does_not_duplicate_text() {
    let requests = Arc::new(std::sync::Mutex::new(Vec::<(String, Value)>::new()));
    let calls = Arc::new(AtomicUsize::new(0));
    let recorded = requests.clone();
    let submitted = calls.clone();
    let app = Router::new()
        .route("/v1/capabilities", get(|| async { Json(json!({"features":{"runs_idempotency":{"durable":true},"run_events_replay":true}})) }))
        .route("/v1/runs", post(move |headers: axum::http::HeaderMap, Json(body): Json<Value>| {
            let recorded = recorded.clone(); let submitted = submitted.clone();
            async move {
                recorded.lock().unwrap().push((headers["idempotency-key"].to_str().unwrap().into(), body));
                if submitted.fetch_add(1, Ordering::SeqCst) == 0 {
                    (StatusCode::BAD_GATEWAY, Json(json!({}))) // accepted remotely, acknowledgement lost
                } else { (StatusCode::ACCEPTED, Json(json!({"run_id":"run_one"}))) }
            }
        }))
        .route("/v1/runs/run_one", get(|| async {Json(json!({"status":"running","session_id":"continuation_one"}))}))
        .route("/v1/runs/run_one/events", get(|axum::extract::Query(q): axum::extract::Query<std::collections::HashMap<String,String>>| async move {
            Json(if q.get("after").map(String::as_str)==Some("0") {
                json!({"events":[{"id":"1","data":{"event":"message.delta","delta":"Hello"}}],"cursor":"1","has_more":false})
            } else {json!({"events":[],"cursor":"1","has_more":false})})
        }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let h = Hermes {
        client: reqwest::Client::new(),
        url,
        key: "fixture".into(),
    };
    let dir = tempfile::tempdir().unwrap();
    let store: Arc<dyn MissionStore> = Arc::new(
        SqliteMissionStore::new(dir.path().into(), "hermes-test")
            .await
            .unwrap(),
    );
    let e = Execution {
        mission_id: Uuid::new_v4(),
        parent_mission_id: None,
        request_key: "key".into(),
        request_signature: "sig".into(),
        revision: 0,
        selection: Selection {
            provider: Provider::Hermes,
            account: "paloma".into(),
            repository: None,
            git_ref: None,
            model: Some("configured-alias".into()),
            model_params: vec![],
        },
        external_id: None,
        external_url: None,
        turns: vec![Turn::new("first".into(), "hello".into())],
    };
    let mut e = store
        .save_cloud_execution(e, None, None, None, vec![])
        .await
        .unwrap();
    assert!(observe_with_client(&store, &mut e, 0, &h).await.is_err());
    // Reload only persisted state, as a replacement Core process would.
    let mut recovered = store.cloud_executions().await.unwrap().remove(0);
    assert_eq!(recovered.turns[0].phase, Phase::Submitting);
    observe_with_client(&store, &mut recovered, 0, &h)
        .await
        .unwrap();
    worker::receipt(&store, recovered, 0).await.unwrap();
    let mut recovered = store.cloud_executions().await.unwrap().remove(0);
    observe_with_client(&store, &mut recovered, 0, &h)
        .await
        .unwrap();
    assert_eq!(recovered.turns[0].result.as_deref(), Some("Hello"));
    assert_eq!(
        recovered.turns[0].session_id.as_deref(),
        Some("continuation_one")
    );
    assert_eq!(store.cloud_events(e.mission_id).await.unwrap().len(), 1);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    let requests = requests.lock().unwrap();
    assert_eq!(requests[0], requests[1]);
    assert_eq!(
        requests[0].1["session_id"],
        format!("orb_{}", e.mission_id.simple())
    );
    drop(requests);
    // An expired ambiguous submission must never create another run.
    let mut uncertain = store.cloud_executions().await.unwrap().remove(0);
    uncertain.turns[0].external_id = None;
    uncertain.turns[0].cursor = Some("submission:0".into());
    assert!(observe_with_client(&store, &mut uncertain, 0, &h)
        .await
        .is_err());
    assert_eq!(uncertain.turns[0].phase, Phase::SubmissionUncertain);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    server.abort();
}

#[test]
fn remote_run_identity_cannot_change_request_path() {
    for id in [
        "",
        "../other",
        "run?secret=1",
        "run/approval",
        "run#fragment",
    ] {
        assert!(run_path(id, "/events").is_err());
    }
    assert_eq!(
        run_path("run_123", "/stop").unwrap(),
        "/v1/runs/run_123/stop"
    );
}

#[tokio::test]
async fn stalled_hermes_probe_does_not_hold_other_accounts_for_the_request_timeout() {
    let app = Router::new().route(
        "/v1/capabilities",
        get(|| async {
            tokio::time::sleep(Duration::from_secs(10)).await;
            Json(json!({}))
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let h = Hermes {
        client: reqwest::Client::new(),
        url,
        key: "fixture".into(),
    };
    let started = std::time::Instant::now();
    assert!(probe(&h).await.unwrap_err().contains("not responding"));
    assert!(started.elapsed() < Duration::from_secs(2));
    server.abort();
}

#[test]
fn hermes_options_includes_builtin_and_custom_router_chains() {
    let now = chrono::Utc::now();
    let chains = vec![
        crate::provider_health::ModelChain {
            id: "builtin/smart".into(),
            name: "Smart (Default)".into(),
            entries: vec![],
            is_default: true,
            strip_thinking: false,
            created_at: now,
            updated_at: now,
        },
        crate::provider_health::ModelChain {
            id: "private".into(),
            name: "Private".into(),
            entries: vec![],
            is_default: false,
            strip_thinking: false,
            created_at: now,
            updated_at: now,
        },
    ];
    let models = json!({
        "data": [
            {"id": "hermes-agent"},
            {"id": "builtin/smart"},
            {"id": "configured-alias"}
        ]
    });
    let out = hermes_model_options(&chains, &models);
    assert_eq!(
        out["models"]["items"],
        json!([
            {"id": "", "name": "Profile default"},
            {"id": "builtin/smart", "name": "Smart (Default) · builtin/smart"},
            {"id": "builtin/private", "name": "Private · builtin/private"},
            {"id": "configured-alias", "name": "configured-alias"}
        ])
    );
    assert!(out["efforts"].is_array());
}

#[test]
fn hermes_options_with_catalog_includes_all_direct_router_models() {
    let chains = vec![];
    let models = json!({"data": [{"id": "builtin/private"}]});
    let direct = vec![
        crate::api::providers::CatalogModelOption {
            provider_id: "anthropic".into(),
            provider_name: "Anthropic".into(),
            id: "claude-opus-4-6".into(),
            value: "anthropic/claude-opus-4-6".into(),
            name: "Claude Opus 4.6".into(),
            description: None,
            configured: true,
        },
        crate::api::providers::CatalogModelOption {
            provider_id: "zai".into(),
            provider_name: "Z.AI".into(),
            id: "glm-5.1".into(),
            value: "zai/glm-5.1".into(),
            name: "GLM-5.1".into(),
            description: None,
            configured: true,
        },
    ];
    let out = hermes_model_options_with_catalog(&chains, &models, &direct);
    assert_eq!(
        out["models"]["items"],
        json!([
            {"id": "", "name": "Profile default"},
            {"id": "builtin/private", "name": "builtin/private"},
            {"id": "anthropic/claude-opus-4-6", "name": "Claude Opus 4.6 · anthropic/claude-opus-4-6"},
            {"id": "zai/glm-5.1", "name": "GLM-5.1 · zai/glm-5.1"}
        ])
    );
}

#[tokio::test]
async fn observe_forwards_reasoning_effort_and_records_thought_and_tool_steps() {
    let recorded_body = Arc::new(std::sync::Mutex::new(Value::Null));
    let recorded_clone = recorded_body.clone();
    let app = Router::new()
        .route(
            "/v1/capabilities",
            get(|| async {
                Json(json!({"features":{"runs_idempotency":{"durable":true},"run_events_replay":true}}))
            }),
        )
        .route(
            "/v1/runs",
            post(move |Json(body): Json<Value>| {
                let recorded_clone = recorded_clone.clone();
                async move {
                    *recorded_clone.lock().unwrap() = body;
                    (StatusCode::ACCEPTED, Json(json!({"run_id":"run_two"})))
                }
            }),
        )
        .route(
            "/v1/runs/run_two",
            get(|| async {
                Json(json!({"status":"completed","session_id":"sess_two","output":"Final answer here."}))
            }),
        )
        .route(
            "/v1/runs/run_two/events",
            get(|| async {
                Json(json!({
                    "events": [
                        {"id": "1", "data": {"event": "reasoning.available", "text": "Let me check the workspace first."}},
                        {"id": "2", "data": {"event": "tool.started", "tool": "terminal", "preview": "ls -la"}},
                        {"id": "3", "data": {"event": "tool.completed", "tool": "terminal", "preview": "README.md", "duration": 0.4}},
                        {"id": "4", "data": {"event": "reasoning.available", "text": "Final answer here."}},
                        {"id": "5", "data": {"event": "message.delta", "delta": "Final answer here."}}
                    ],
                    "cursor": "5",
                    "has_more": false
                }))
            }),
        )
        .route(
            "/api/sessions/sess_two/messages",
            get(|| async {
                Json(json!({
                    "messages": [
                        {"role": "user", "content": "check workspace"},
                        {"role": "assistant", "content": "", "reasoning_content": "Deep provider reasoning trace."}
                    ]
                }))
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let h = Hermes {
        client: reqwest::Client::new(),
        url,
        key: "fixture".into(),
    };
    let dir = tempfile::tempdir().unwrap();
    let store: Arc<dyn MissionStore> = Arc::new(
        SqliteMissionStore::new(dir.path().into(), "hermes-steps-test")
            .await
            .unwrap(),
    );
    let mut turn = Turn::new("t1".into(), "check workspace".into());
    turn.model = Some("builtin/private".into());
    turn.model_params = vec![ModelParam {
        id: "effort".into(),
        value: "high".into(),
    }];
    let e = Execution {
        mission_id: Uuid::new_v4(),
        parent_mission_id: None,
        request_key: "key".into(),
        request_signature: "sig".into(),
        revision: 0,
        selection: Selection {
            provider: Provider::Hermes,
            account: "paloma".into(),
            repository: None,
            git_ref: None,
            model: Some("builtin/smart".into()),
            model_params: vec![],
        },
        external_id: None,
        external_url: None,
        turns: vec![turn],
    };
    let mut e = store
        .save_cloud_execution(e, None, None, None, vec![])
        .await
        .unwrap();
    observe_with_client(&store, &mut e, 0, &h).await.unwrap();
    let posted = recorded_body.lock().unwrap().clone();
    assert_eq!(posted["model"], "builtin/private");
    assert_eq!(
        posted["model_options"]["reasoning"],
        json!({"enabled": true, "effort": "high"})
    );
    assert_eq!(e.turns[0].phase, Phase::ResponseComplete);
    assert_eq!(e.turns[0].result.as_deref(), Some("Final answer here."));
    // Should contain session reasoning, interim reasoning, and completed tool step,
    // and NOT duplicate the final answer as a thought step.
    assert_eq!(e.turns[0].steps.len(), 3);
    assert_eq!(e.turns[0].steps[0]["kind"], "think");
    assert_eq!(
        e.turns[0].steps[0]["text"],
        "Deep provider reasoning trace."
    );
    assert_eq!(e.turns[0].steps[1]["kind"], "think");
    assert_eq!(
        e.turns[0].steps[1]["text"],
        "Let me check the workspace first."
    );
    assert_eq!(e.turns[0].steps[2]["kind"], "tool");
    assert_eq!(e.turns[0].steps[2]["name"], "terminal");
    assert_eq!(e.turns[0].steps[2]["status"], "completed");
    assert_eq!(e.turns[0].steps[2]["output"], "README.md");
    server.abort();
}

#[tokio::test]
async fn mid_mission_model_and_effort_switch_preserves_session_without_fork_and_matches_hermes_runtime(
) {
    let recorded_runs = Arc::new(std::sync::Mutex::new(Vec::<Value>::new()));
    let recorded_clone = recorded_runs.clone();
    let app = Router::new()
        .route(
            "/v1/capabilities",
            get(|| async {
                Json(json!({
                    "features": {
                        "runs_idempotency": {"durable": true},
                        "run_events_replay": true
                    }
                }))
            }),
        )
        .route(
            "/v1/runs",
            post(move |Json(body): Json<Value>| {
                let recorded_clone = recorded_clone.clone();
                async move {
                    let mut runs = recorded_clone.lock().unwrap();
                    runs.push(body);
                    let run_id = format!("run_turn_{}", runs.len());
                    Json(json!({"run_id": run_id, "status": "started"}))
                }
            }),
        )
        .route(
            "/v1/runs/run_turn_1",
            get(|| async {
                Json(json!({
                    "run_id": "run_turn_1",
                    "session_id": "orb_same_session",
                    "status": "completed",
                    "output": "Turn 1 completed on builtin/private (medium)."
                }))
            }),
        )
        .route(
            "/v1/runs/run_turn_1/events",
            get(|| async {
                Json(json!({
                    "events": [
                        {"id": "1", "data": {"event": "message.delta", "delta": "Turn 1 completed on builtin/private (medium)."}}
                    ],
                    "cursor": "1",
                    "has_more": false
                }))
            }),
        )
        .route(
            "/v1/runs/run_turn_2",
            get(|| async {
                Json(json!({
                    "run_id": "run_turn_2",
                    "session_id": "orb_same_session",
                    "status": "completed",
                    "output": "Turn 2 completed on openai/gpt-5.4 (high) in the same session."
                }))
            }),
        )
        .route(
            "/v1/runs/run_turn_2/events",
            get(|| async {
                Json(json!({
                    "events": [
                        {"id": "1", "data": {"event": "message.delta", "delta": "Turn 2 completed on openai/gpt-5.4 (high) in the same session."}}
                    ],
                    "cursor": "1",
                    "has_more": false
                }))
            }),
        )
        .route(
            "/api/sessions/orb_same_session/messages",
            get(|| async { Json(json!({"messages": []})) }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let h = Hermes {
        client: reqwest::Client::new(),
        url,
        key: "fixture".into(),
    };
    let dir = tempfile::tempdir().unwrap();
    let store: Arc<dyn MissionStore> = Arc::new(
        SqliteMissionStore::new(dir.path().into(), "hermes-switch-test")
            .await
            .unwrap(),
    );
    let mission_id = Uuid::new_v4();
    let expected_session = format!("orb_{}", mission_id.simple());
    let mut turn1 = Turn::new("t1".into(), "Start mission on private router chain".into());
    turn1.model = Some("builtin/private".into());
    turn1.model_params = vec![ModelParam {
        id: "effort".into(),
        value: "medium".into(),
    }];
    let e = Execution {
        mission_id,
        parent_mission_id: None,
        request_key: "key".into(),
        request_signature: "sig".into(),
        revision: 0,
        selection: Selection {
            provider: Provider::Hermes,
            account: "paloma".into(),
            repository: None,
            git_ref: None,
            model: Some("builtin/private".into()),
            model_params: vec![ModelParam {
                id: "effort".into(),
                value: "medium".into(),
            }],
        },
        external_id: None,
        external_url: None,
        turns: vec![turn1],
    };
    let mut e = store
        .save_cloud_execution(e, None, None, None, vec![])
        .await
        .unwrap();
    observe_with_client(&store, &mut e, 0, &h).await.unwrap();
    worker::receipt(&store, e.clone(), 0).await.unwrap();
    e = store
        .cloud_executions()
        .await
        .unwrap()
        .into_iter()
        .find(|row| row.mission_id == mission_id)
        .unwrap();
    assert_eq!(e.external_id.as_deref(), Some(expected_session.as_str()));
    assert_eq!(e.turns[0].phase, Phase::ResponseComplete);

    // Follow-up turn switches model to openai/gpt-5.4 and effort to high in-place without forking
    let mut turn2 = Turn::new("t2".into(), "Switch model and effort mid-mission".into());
    turn2.model = Some("openai/gpt-5.4".into());
    turn2.model_params = vec![ModelParam {
        id: "effort".into(),
        value: "high".into(),
    }];
    e.selection.model = Some("openai/gpt-5.4".into());
    e.selection.model_params = vec![ModelParam {
        id: "effort".into(),
        value: "high".into(),
    }];
    e.turns.push(turn2);
    e = worker::save(&store, e).await.unwrap();
    observe_with_client(&store, &mut e, 1, &h).await.unwrap();
    worker::receipt(&store, e.clone(), 1).await.unwrap();
    e = store
        .cloud_executions()
        .await
        .unwrap()
        .into_iter()
        .find(|row| row.mission_id == mission_id)
        .unwrap();

    assert_eq!(e.external_id.as_deref(), Some(expected_session.as_str()));
    assert_eq!(e.selection.model.as_deref(), Some("openai/gpt-5.4"));
    assert_eq!(e.selection.model_params[0].value, "high");
    assert_eq!(e.turns[1].phase, Phase::ResponseComplete);

    let runs = recorded_runs.lock().unwrap().clone();
    assert_eq!(runs.len(), 2);
    assert_eq!(runs[0]["session_id"], expected_session);
    assert_eq!(runs[0]["model"], "builtin/private");
    assert_eq!(
        runs[0]["model_options"]["reasoning"],
        json!({"enabled": true, "effort": "medium"})
    );
    assert_eq!(runs[1]["session_id"], expected_session);
    assert_eq!(runs[1]["model"], "openai/gpt-5.4");
    assert_eq!(
        runs[1]["model_options"]["reasoning"],
        json!({"enabled": true, "effort": "high"})
    );

    // If the production Hermes gateway runtime is installed on this host, verify that its
    // exact request parser (`_request_agent_overrides` + `_request_reasoning_config`) accepts
    // both payloads on the same session_id without conflict.
    let hermes_py = std::path::Path::new("/usr/local/lib/hermes-agent/venv/bin/python3");
    if hermes_py.exists() {
        let payload_json = serde_json::to_string(&runs).unwrap();
        let out = std::process::Command::new(hermes_py)
            .env("PYTHONPATH", "/usr/local/lib/hermes-agent")
            .args([
                "-c",
                "import json, sys; \
                 from gateway.platforms.api_server import _request_agent_overrides, _request_reasoning_config; \
                 runs = json.loads(sys.argv[1]); \
                 r0 = _request_agent_overrides(runs[0], virtual_model='hermes-agent'); \
                 r1 = _request_agent_overrides(runs[1], virtual_model='hermes-agent'); \
                 c0 = _request_reasoning_config(r0.get('model_options')); \
                 c1 = _request_reasoning_config(r1.get('model_options')); \
                 assert r0['requested_model'] == 'builtin/private', r0; \
                 assert r1['requested_model'] == 'openai/gpt-5.4', r1; \
                 assert c0 == {'enabled': True, 'effort': 'medium'}, c0; \
                 assert c1 == {'enabled': True, 'effort': 'high'}, c1; \
                 assert runs[0]['session_id'] == runs[1]['session_id']; \
                 print('HERMES_RUNTIME_VERIFIED')",
                &payload_json,
            ])
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "Hermes runtime check failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(String::from_utf8_lossy(&out.stdout).contains("HERMES_RUNTIME_VERIFIED"));
    }
    server.abort();
}
