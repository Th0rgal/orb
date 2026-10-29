use super::speed_proxy;
use crate::api::{
    mission_store::{create_mission_store, MissionStoreType},
    oauth_owner::CliProxyEndpoint,
};
use crate::codex_speed::Tier;
use axum::{
    body::Bytes,
    http::{HeaderMap, StatusCode},
};

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

#[test]
fn codex_scope_binds_caller_model_tier_and_revokes_at_turn_end() {
    let mission = uuid::Uuid::new_v4();
    let endpoint = CliProxyEndpoint {
        base_url: "http://proxy.test".into(),
        api_key: "never-exposed".into(),
        identity_url: None,
    };
    for tier in [Tier::Standard, Tier::Ultrafast] {
        let (guard, scoped) = speed_proxy::register(
            "http://core.test",
            "gpt-6.1-sol",
            tier,
            mission,
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
        headers.insert("x-sandboxed-mission-id", "forged".parse().unwrap());
        let wrong = Bytes::from_static(br#"{"model":"other","input":[]}"#);
        assert_eq!(
            speed_proxy::prepare_request(&headers, &wrong, "core-secret")
                .unwrap_err()
                .status(),
            StatusCode::BAD_REQUEST
        );
        let wrong_tier = Bytes::from(
            serde_json::to_vec(&serde_json::json!({
                "model": "gpt-6.1-sol", "input": [],
                "service_tier": if tier == Tier::Standard { "ultrafast" } else { "default" }
            }))
            .unwrap(),
        );
        assert_eq!(
            speed_proxy::prepare_request(&headers, &wrong_tier, "core-secret")
                .unwrap_err()
                .status(),
            StatusCode::BAD_REQUEST
        );
        let body = Bytes::from_static(br#"{"model":"gpt-6.1-sol","input":[]}"#);
        let (trusted, payload, cancel) =
            speed_proxy::prepare_request(&headers, &body, "core-secret").unwrap();
        assert_eq!(trusted["authorization"], "Bearer core-secret");
        assert_eq!(trusted["x-sandboxed-codex-subscription-only"], "true");
        assert_eq!(trusted["x-sandboxed-mission-id"], mission.to_string());
        assert_eq!(trusted["x-sandboxed-codex-speed"], tier.wire());
        let request: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(request["model"], "gpt-6.1-sol");
        assert_eq!(request["service_tier"], tier.wire());
        let stateful = Bytes::from_static(
            br#"{"model":"gpt-6.1-sol","previous_response_id":"opaque","input":[]}"#,
        );
        assert_eq!(
            speed_proxy::prepare_request(&headers, &stateful, "core-secret")
                .unwrap_err()
                .status(),
            StatusCode::BAD_REQUEST
        );
        drop(guard);
        assert!(cancel.is_cancelled());
        assert_eq!(
            speed_proxy::prepare_request(&headers, &body, "core-secret")
                .unwrap_err()
                .status(),
            StatusCode::UNAUTHORIZED
        );
    }
}
