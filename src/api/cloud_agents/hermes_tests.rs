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
