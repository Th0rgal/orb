//! Explicit live canary: ignored by normal tests; uses a dedicated persistent DB.
use super::*;
use crate::api::mission_store::{MissionStore, SqliteMissionStore};
use std::sync::Arc;

#[tokio::test]
#[ignore = "requires a user Cursor key and explicitly selected isolated canary directory"]
async fn live_cursor_restart_and_followup() {
    let dir = std::env::var("CURSOR_CLOUD_CANARY_DIR").expect("Set an isolated canary directory");
    let store: Arc<dyn MissionStore> = Arc::new(
        SqliteMissionStore::new(dir.into(), "cursor-canary")
            .await
            .unwrap(),
    );
    let adapter = cursor::Cursor::from_account("cursor-default").unwrap();
    adapter.availability().await.unwrap();
    let mut rows = store.cloud_executions().await.unwrap();
    if rows.is_empty() {
        let execution = Execution {
            parent_mission_id: None,
            mission_id: Uuid::new_v4(), request_key: "cursor-live-canary-v1".into(),
            request_signature: "cursor-live-canary-v1".into(), revision: 0,
            selection: Selection { provider: Provider::CursorCloud, account: "cursor-default".into(), repository: None, git_ref: None, model_params: vec![], model: None },
            external_id: None, external_url: None,
            turns: vec![Turn::new("first".into(), "This is a bounded Orb integration test. Do not use tools, modify files, access repositories, or create a PR. Remember the marker ORB_CANARY_7341 for this conversation. Reply only ORB_CANARY_7341.".into())],
        };
        store
            .save_cloud_execution(execution, None, Some("Orb API canary".into()), None, vec![])
            .await
            .unwrap();
        rows = store.cloud_executions().await.unwrap();
    }
    assert_eq!(rows.len(), 1);
    let mission_id = rows[0].mission_id;
    eprintln!("Canary mission: {mission_id}");
    let submit_only = std::env::var("CURSOR_CLOUD_CANARY_STEP").as_deref() == Ok("submit");
    for _ in 0..90 {
        let mut row = store.cloud_executions().await.unwrap().remove(0);
        assert_eq!(row.mission_id, mission_id);
        if row.turns.last().unwrap().phase == Phase::ResponseComplete {
            assert!(
                row.turns
                    .last()
                    .unwrap()
                    .result
                    .as_deref()
                    .unwrap_or("")
                    .contains("ORB_CANARY_7341"),
                "Conversation marker absent"
            );
            if row.turns.len() == 2 {
                assert_eq!(store.list_missions(10, 0).await.unwrap().len(), 1);
                assert_ne!(row.turns[0].external_id, row.turns[1].external_id);
                eprintln!(
                    "Canary passed: same agent, distinct runs, preserved response; {}",
                    row.external_id.unwrap()
                );
                return;
            }
            row.enqueue("followup".into(), "Without using tools, reply only with the marker I asked you to remember in my previous message.".into()).unwrap();
            row.enqueue("followup".into(), "Without using tools, reply only with the marker I asked you to remember in my previous message.".into()).unwrap();
            assert_eq!(row.turns.len(), 2);
            row = worker::save(&store, row).await.unwrap();
        }
        let last = row.turns.last().unwrap();
        // Initial creation can be reconciled by its deterministic agent ID.
        // An ambiguous follow-up has no such provider-enforced identity.
        let reconcilable_initial = row.turns.len() == 1
            && last.phase == Phase::SubmissionUncertain
            && last.external_id.is_none();
        assert!(
            reconcilable_initial
                || !matches!(
                    last.phase,
                    Phase::Failed
                        | Phase::Cancelled
                        | Phase::Incompatible
                        | Phase::ReconnectRequired
                        | Phase::SubmissionUncertain
                ),
            "Canary held: {:?} {:?}",
            last.phase,
            last.detail
        );
        worker::tick(&store, row).await.unwrap();
        let saved = store.cloud_executions().await.unwrap().remove(0);
        eprintln!(
            "Observed {:?}; agent={:?}; run={:?}",
            saved.turns.last().unwrap().phase,
            saved.external_id,
            saved.turns.last().unwrap().external_id
        );
        if submit_only {
            assert!(
                saved.external_id.is_some(),
                "Initial submission did not produce a receipt: {:?}",
                saved.turns[0].detail
            );
            return;
        }
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    }
    panic!("Canary observation deadline reached; rerun with the SAME directory to reconcile, never create another agent");
}
