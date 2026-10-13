use super::speed_proxy;
use crate::api::{
    mission_store::{create_mission_store, MissionStoreType},
    oauth_owner::CliProxyEndpoint,
};
use crate::codex_speed::Tier;
use axum::{
    body::Bytes,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::post,
    Router,
};
use std::sync::{Arc, Mutex};

#[tokio::test]
async fn codex_service_tier_survives_store_reopen_and_legacy_clear() {
    for kind in [
        MissionStoreType::Memory,
        MissionStoreType::File,
        MissionStoreType::Sqlite,
    ] {
        let root = tempfile::tempdir().unwrap();
        let store = create_mission_store(kind, root.path().into(), "speed-test")
            .await
            .unwrap();
        let mission = store
            .create_mission(
                None,
                None,
                None,
                Some("gpt-6.1-sol"),
                None,
                Some("codex"),
                None,
            )
            .await
            .unwrap();
        store
            .update_mission_run_settings(
                mission.id,
                None,
                None,
                None,
                None,
                None,
                Some(Tier::Ultrafast),
                None,
                "native-thread",
            )
            .await
            .unwrap();
        assert_eq!(
            store
                .get_mission(mission.id)
                .await
                .unwrap()
                .unwrap()
                .service_tier,
            Some(Tier::Ultrafast)
        );
        assert_eq!(
            store.list_missions(10, 0).await.unwrap()[0].service_tier,
            Some(Tier::Ultrafast)
        );
        if kind != MissionStoreType::Memory {
            let reopened = create_mission_store(kind, root.path().into(), "speed-test")
                .await
                .unwrap();
            assert_eq!(
                reopened
                    .get_mission(mission.id)
                    .await
                    .unwrap()
                    .unwrap()
                    .service_tier,
                Some(Tier::Ultrafast)
            );
        }
        let cleared = store
            .update_mission_run_settings(
                mission.id,
                None,
                None,
                None,
                None,
                Some(false),
                None,
                None,
                "native-thread",
            )
            .await
            .unwrap();
        assert_eq!(cleared.service_tier, Some(Tier::Standard));
        assert!(!cleared.fast_mode);
    }
}

#[tokio::test]
async fn codex_speed_scope_rotates_compatible_accounts_and_revokes_at_turn_end() {
    let requests = Arc::new(Mutex::new(Vec::<String>::new()));
    let captured = requests.clone();
    let app=Router::new().route("/v1/responses",post(move |headers:HeaderMap,body:Bytes|{
        let captured=captured.clone();async move {
            assert_eq!(headers["authorization"],"Bearer proxy-fixture-key");
            let request:serde_json::Value=serde_json::from_slice(&body).unwrap();
            assert_eq!(request["service_tier"],"ultrafast");
            let model=request["model"].as_str().unwrap().to_string();captured.lock().unwrap().push(model.clone());
            if model.starts_with("first/"){return (StatusCode::TOO_MANY_REQUESTS,"quota exceeded").into_response();}
            (StatusCode::OK,[("content-type","text/event-stream")],"data: {\"type\":\"response.completed\",\"response\":{\"service_tier\":\"ultrafast\"}}\n\n").into_response()
        }
    }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let endpoint = CliProxyEndpoint {
        base_url: format!("http://{addr}"),
        api_key: "proxy-fixture-key".into(),
        identity_url: None,
    };
    let (guard, scoped) = speed_proxy::register(
        "http://core.test",
        "gpt-6.1-sol",
        Tier::Ultrafast,
        vec!["first".into(), "second".into()],
        endpoint.clone(),
    )
    .unwrap();
    assert_eq!(
        scoped.identity_url.as_deref(),
        Some(endpoint.base_url.as_str())
    );
    let mut headers = HeaderMap::new();
    headers.insert(
        "authorization",
        format!("Bearer {}", scoped.api_key).parse().unwrap(),
    );
    let wrong =
        Bytes::from_static(br#"{"model":"gpt-6.1-sol","service_tier":"default","input":[]}"#);
    assert_eq!(
        speed_proxy::responses(headers.clone(), wrong)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    assert!(requests.lock().unwrap().is_empty());
    let body = Bytes::from_static(br#"{"model":"gpt-6.1-sol","input":[]}"#);
    let response = speed_proxy::responses(headers.clone(), body.clone()).await;
    assert_eq!(response.status(), StatusCode::OK);
    let text = axum::body::to_bytes(response.into_body(), 4096)
        .await
        .unwrap();
    assert!(String::from_utf8_lossy(&text).contains("ultrafast"));
    assert_eq!(
        *requests.lock().unwrap(),
        vec!["first/gpt-6.1-sol", "second/gpt-6.1-sol"]
    );
    drop(guard);
    assert_eq!(
        speed_proxy::responses(headers, body).await.status(),
        StatusCode::UNAUTHORIZED
    );
    server.abort();
}
